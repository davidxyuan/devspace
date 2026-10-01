[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ZipPath,
    [string]$WorkRoot = (Join-Path $env:TEMP ('devspace-oneclick-fresh-vm-' + [guid]::NewGuid().ToString('N'))),
    [int]$MaxElapsedSeconds = 720,
    [switch]$KeepArtifacts
)
$ErrorActionPreference = 'Stop'

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') { throw 'This test requires Windows.' }
if ($env:GITHUB_ACTIONS -ne 'true' -and $env:DEVSPACE_ALLOW_FRESH_VM_TEST -ne '1') {
    throw 'Fresh-VM test mutates the current Windows user profile. Run only on an ephemeral VM/Windows Sandbox, or set DEVSPACE_ALLOW_FRESH_VM_TEST=1 explicitly.'
}

$ZipPath = [IO.Path]::GetFullPath($ZipPath)
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
if (-not [IO.File]::Exists($ZipPath)) { throw "One-Click ZIP was not found: $ZipPath" }
if ([IO.Directory]::Exists($WorkRoot)) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }
[void][IO.Directory]::CreateDirectory($WorkRoot)

$extractRoot = Join-Path $WorkRoot 'extracted'
$freshHome = Join-Path $WorkRoot 'fresh-home'
$installDir = Join-Path $freshHome '.devspace'
$hermesDir = Join-Path $freshHome 'hermes-gpt'
$stdoutPath = Join-Path $WorkRoot 'setup.stdout.log'
$stderrPath = Join-Path $WorkRoot 'setup.stderr.log'
$resultPath = Join-Path $WorkRoot 'fresh-vm-result.json'
$fakeNgrokToken = 'fresh-vm-fake-ngrok-token-not-valid-for-network'
$setupProcess = $null
$stopwatch = [Diagnostics.Stopwatch]::StartNew()

function Read-SharedText([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return "" }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object IO.StreamReader($stream)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Read-SetupUrl {
    $text = Read-SharedText $stdoutPath
    $match = [regex]::Match($text, 'DevSpace Stack Setup:\s+(http://127\.0\.0\.1:\d+/)')
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Invoke-SetupJson([string]$Method, [string]$Url, $Body = $null, [hashtable]$Headers = @{}) {
    $parameters = @{
        Uri = $Url
        Method = $Method
        Headers = $Headers
        UseBasicParsing = $true
        TimeoutSec = 30
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = ($Body | ConvertTo-Json -Depth 12 -Compress)
    }
    $response = Invoke-WebRequest @parameters
    if (-not $response.Content) { return $null }
    return $response.Content | ConvertFrom-Json
}

try {
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractRoot -Force
    $packageRoot = Join-Path $extractRoot 'package'
    $bootstrap = Join-Path $packageRoot 'scripts\windows\install-devspace-stack.ps1'
    $manifestPath = Join-Path $packageRoot 'oneclick-payload.json'
    if (-not [IO.File]::Exists((Join-Path $extractRoot 'Install-DevSpace.cmd'))) { throw 'ZIP is missing Install-DevSpace.cmd.' }
    if (-not [IO.File]::Exists($bootstrap)) { throw 'ZIP is missing install-devspace-stack.ps1.' }
    if (-not [IO.File]::Exists($manifestPath)) { throw 'ZIP is missing oneclick-payload.json.' }

    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ([bool]$manifest.dirty) { throw 'Fresh-VM test refuses a dirty package manifest.' }
    if ([string]$manifest.fingerprint -notmatch '^[a-f0-9]{64}$') { throw 'Package fingerprint is invalid.' }

    $setupProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoLogo','-NoProfile','-NonInteractive','-File',$bootstrap,
        '-InstallDir',$installDir,'-NoOpen'
    ) -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -WindowStyle Hidden -PassThru

    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    $baseUrl = $null
    while ([DateTime]::UtcNow -lt $deadline -and -not $baseUrl) {
        if ($setupProcess.HasExited) {
            $stderr = Read-SharedText $stderrPath
            throw "One-Click bootstrap exited before Setup became ready. Exit=$($setupProcess.ExitCode). $stderr"
        }
        Start-Sleep -Milliseconds 500
        $baseUrl = Read-SetupUrl
    }
    if (-not $baseUrl) { throw 'One-Click Setup did not become ready within 3 minutes.' }

    $html = (Invoke-WebRequest -Uri $baseUrl -UseBasicParsing -TimeoutSec 30).Content
    $tokenMatch = [regex]::Match($html, 'const setupToken="([^"]+)"')
    if (-not $tokenMatch.Success) { throw 'Could not read localhost Setup anti-CSRF token.' }
    $setupToken = $tokenMatch.Groups[1].Value
    $origin = $baseUrl.TrimEnd('/')
    $headers = @{ Origin = $origin; 'X-DevSpace-Setup-Token' = $setupToken }

    $status = Invoke-SetupJson 'GET' ($baseUrl + 'api/status')
    if ($status.state -ne 'Fresh') { throw "Expected Fresh state, got $($status.state)." }
    if ([bool]$status.defaults.ngrokAuthTokenConfigured) { throw 'Fresh VM unexpectedly reports a stored ngrok credential.' }

    $payload = [ordered]@{
        configurationFingerprint = [string]$status.configurationFingerprint
        installDevspace = $true
        installHermes = $true
        installTray = $true
        userMode = $true
        noLegacyPoller = $true
        installTools = $true
        npmInsecureTls = $false
        fullAccess = $true
        machineName = 'FreshSandbox'
        mcpNameSuffix = 'freshsandbox'
        allowedRoots = $WorkRoot
        hermesDir = $hermesDir
        endpointMode = 'AgentEndpoint'
        publicDomain = 'https://fresh-sandbox.ngrok-free.dev'
        internalAgentEndpoint = ''
        ngrokAuthToken = ''
        devspaceOwnerToken = ''
    }

    $blankRejected = $false
    try {
        [void](Invoke-SetupJson 'POST' ($baseUrl + 'api/apply') $payload $headers)
    } catch {
        $message = [string]$_.ErrorDetails.Message
        if (-not $message) { $message = [string]$_.Exception.Message }
        if ($message -match 'ngrok Auth Token is required') { $blankRejected = $true }
        else { throw }
    }
    if (-not $blankRejected) { throw 'Fresh Setup accepted an install without an ngrok token.' }

    # The Setup HTTP/token contract is verified above. Stop the localhost Setup process
    # before running the packaged installer core with SkipStart; production Tray readiness
    # is covered by the dedicated lifecycle suite and must not be weakened for CI.
    if ($setupProcess -and -not $setupProcess.HasExited) {
        & taskkill.exe /PID $setupProcess.Id /T /F | Out-Null
        $setupProcess = $null
        Start-Sleep -Seconds 1
    }

    $nodePath = (Get-Command node.exe -ErrorAction Stop | Select-Object -First 1).Source
    $npmPath = (Get-Command npm.cmd -ErrorAction Stop | Select-Object -First 1).Source
    $previousNodeSystemCa = $env:NODE_USE_SYSTEM_CA
    $env:NODE_USE_SYSTEM_CA = '1'
    try {
        Push-Location $packageRoot
        try {
            & $npmPath ci --omit=dev --no-audit --no-fund
            if ($LASTEXITCODE -ne 0) { throw "Fresh package npm ci failed with exit code $LASTEXITCODE." }
            & $nodePath (Join-Path $packageRoot 'dist\cli.js') help | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Fresh package DevSpace CLI probe failed with exit code $LASTEXITCODE." }
        } finally { Pop-Location }
    } finally {
        if ($null -eq $previousNodeSystemCa) { Remove-Item Env:NODE_USE_SYSTEM_CA -ErrorAction SilentlyContinue }
        else { $env:NODE_USE_SYSTEM_CA = $previousNodeSystemCa }
    }

    $setupForCore = [ordered]@{
        components = @('DevSpace','Hermes')
        existing = $false
        changes = @()
        machineName = 'FreshSandbox'
        mcpNameSuffix = 'freshsandbox'
        publicDomain = 'https://fresh-sandbox.ngrok-free.dev'
        endpointMode = 'AgentEndpoint'
        allowedRoots = $WorkRoot
        hermesDir = $hermesDir
        installTray = $false
        installTools = $true
        npmInsecureTls = $false
        userMode = $true
        noLegacyPoller = $false
        fullAccess = $true
        ngrokAuthToken = $fakeNgrokToken
        devspaceOwnerToken = ''
    }
    $setupJsonPath = Join-Path $WorkRoot 'fresh-core-setup.json'
    $parameterPath = Join-Path $WorkRoot 'fresh-core-parameters.json'
    $generatorPath = Join-Path $WorkRoot 'fresh-core-parameters.cjs'
    $setupForCore | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $setupJsonPath -Encoding UTF8
    @'
"use strict";
const fs=require("node:fs");
const apply=require(process.argv[2]);
const setup=JSON.parse(fs.readFileSync(process.argv[3],"utf8").replace(/^\uFEFF/,""));
const params=apply.installerParameters(setup,{installDir:process.argv[4],packageRoot:process.argv[5]});
params.SkipStart=true;
fs.writeFileSync(process.argv[6],JSON.stringify(params));
'@ | Set-Content -LiteralPath $generatorPath -Encoding ASCII
    & $nodePath $generatorPath (Join-Path $packageRoot 'scripts\windows\stack-setup-apply.cjs') $setupJsonPath $installDir $packageRoot $parameterPath
    if ($LASTEXITCODE -ne 0) { throw 'Could not generate production installer parameters from the packaged Setup mapper.' }
    $parameterText = [IO.File]::ReadAllText($parameterPath)
    if ($parameterText.Contains($fakeNgrokToken)) { throw 'ngrok token leaked into installer parameter JSON.' }
    $parameters = $parameterText | ConvertFrom-Json
    if ([string]$parameters.CapabilitySelection -notmatch 'DevSpaceToolMode=full' -or
        [string]$parameters.CapabilitySelection -notmatch 'HermesOwnerMode=On') {
        throw 'Packaged Setup mapper did not generate the production capability preset.'
    }

    $previousNgrokToken = $env:NGROK_AUTHTOKEN
    $env:NGROK_AUTHTOKEN = $fakeNgrokToken
    try {
        & powershell.exe -NoLogo -NoProfile -NonInteractive -File (Join-Path $packageRoot 'scripts\windows\stack-apply-parameters.ps1') -ParameterPath $parameterPath -InstallerPath (Join-Path $packageRoot 'scripts\windows\install-devspace-watchdog.ps1')
        if ($LASTEXITCODE -ne 0) { throw "Packaged installer core failed with exit code $LASTEXITCODE." }
    } finally {
        if ($null -eq $previousNgrokToken) { Remove-Item Env:NGROK_AUTHTOKEN -ErrorAction SilentlyContinue }
        else { $env:NGROK_AUTHTOKEN = $previousNgrokToken }
    }

    foreach ($textFile in @(Get-ChildItem -LiteralPath $installDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.json','.log','.txt','.ps1','.cmd','.yml','.yaml') })) {
        if ((Read-SharedText $textFile.FullName).Contains($fakeNgrokToken)) { throw "ngrok token leaked into installed plaintext file: $($textFile.FullName)" }
    }

    $watchdogPath = Join-Path $installDir 'devspace-watchdog.config.json'
    $configPath = Join-Path $installDir 'config.json'
    $credentialPath = Join-Path $installDir 'ngrok-auth.dpapi.json'
    foreach ($required in @($watchdogPath,$configPath,$credentialPath,(Join-Path $installDir 'watchdog-control-core.ps1'))) {
        if (-not [IO.File]::Exists($required)) { throw "Required installed file is missing: $required" }
    }

    . (Join-Path $installDir 'watchdog-control-core.ps1')
    $watchdog = Read-WatchdogJson $watchdogPath
    $roundTrip = Get-WatchdogNgrokCredential $watchdog
    if ($roundTrip -cne $fakeNgrokToken) { throw 'ngrok DPAPI round-trip did not return the submitted token.' }
    $roundTrip = $null

    $devspaceConfig = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    if (-not [bool]$watchdog.fullAccess) { throw 'Watchdog fullAccess is not enabled.' }
    if ([string]$watchdog.capabilities.devspace.toolMode -ne 'full' -or
        -not [bool]$watchdog.capabilities.devspace.skills -or
        -not [bool]$watchdog.capabilities.devspace.subagents -or
        [string]$watchdog.capabilities.devspace.mcpTransport -ne 'stateless-json') {
        throw 'DevSpace production capability preset was not installed.'
    }
    if (-not [bool]$watchdog.hermesFullAccess -or
        -not [bool]$watchdog.capabilities.hermes.operator -or
        -not [bool]$watchdog.capabilities.hermes.operatorDirect -or
        -not [bool]$watchdog.capabilities.hermes.ownerMode -or
        [string]$watchdog.capabilities.hermes.filesystemScope -ne 'full') {
        throw 'Hermes Owner/direct/full capability preset was not installed.'
    }
    if (-not [IO.File]::Exists([string]$watchdog.hermesPython) -or -not [IO.File]::Exists([string]$watchdog.hermesServer)) {
        throw 'Hermes-GPT runtime was not installed.'
    }
    if (-not [IO.File]::Exists([string]$watchdog.ngrokPath)) { throw 'ngrok agent was not installed.' }
    if (-not [IO.File]::Exists([string]$watchdog.cliPath)) { throw 'DevSpace CLI was not installed.' }
    if (@($devspaceConfig.allowedRoots).Count -eq 0) { throw 'DevSpace allowedRoots is empty.' }

    $stopwatch.Stop()
    if ($MaxElapsedSeconds -gt 0 -and $stopwatch.Elapsed.TotalSeconds -gt $MaxElapsedSeconds) {
        throw ("Fresh One-Click install exceeded the performance budget: {0}s > {1}s." -f [math]::Round($stopwatch.Elapsed.TotalSeconds,1), $MaxElapsedSeconds)
    }
    $result = [ordered]@{
        success = $true
        elapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        packageHead = [string]$manifest.head
        packageFingerprint = [string]$manifest.fingerprint
        state = 'core-installed-skip-start'
        ngrokCredentialRoundTrip = $true
        devspaceProfile = 'full/stateless-json/skills/subagents'
        hermesProfile = 'owner/direct/full'
        hermesPython = [string]$watchdog.hermesPython
        ngrokPath = [string]$watchdog.ngrokPath
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    Write-Host ('FRESH_VM_PASS ' + ($result | ConvertTo-Json -Compress))
}
finally {
    if ($setupProcess -and -not $setupProcess.HasExited) {
        & taskkill.exe /PID $setupProcess.Id /T /F | Out-Null
    }
    if (-not $KeepArtifacts -and [IO.Directory]::Exists($WorkRoot)) {
        Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
