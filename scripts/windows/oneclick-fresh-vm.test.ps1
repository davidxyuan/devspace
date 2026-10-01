[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ZipPath,
    [string]$WorkRoot = (Join-Path $env:TEMP ('devspace-oneclick-fresh-vm-' + [guid]::NewGuid().ToString('N'))),
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

    $env:DEVSPACE_ONECLICK_TEST_SKIP_START = '1'
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

    $payload.ngrokAuthToken = $fakeNgrokToken
    $apply = Invoke-SetupJson 'POST' ($baseUrl + 'api/apply') $payload $headers
    if (-not $apply.jobId) { throw 'Setup did not return a job ID.' }

    $jobDeadline = [DateTime]::UtcNow.AddMinutes(15)
    $job = $null
    while ([DateTime]::UtcNow -lt $jobDeadline) {
        Start-Sleep -Seconds 2
        $job = Invoke-SetupJson 'GET' ($baseUrl + 'api/job?id=' + $apply.jobId)
        if ($job.phase -in @('completed','failed','rollback_failed')) { break }
    }
    if (-not $job -or $job.phase -notin @('completed','failed','rollback_failed')) { throw 'Fresh install job did not reach a terminal state within 15 minutes.' }
    if ($job.phase -ne 'completed') {
        $logText = @($job.lines | ForEach-Object { "[$($_.source)] $($_.text)" }) -join [Environment]::NewLine
        throw "Fresh install failed: $($job.error)$([Environment]::NewLine)$logText"
    }

    $jobJson = [IO.File]::ReadAllText((Join-Path $installDir ("stack-management\jobs\" + $apply.jobId + ".json")))
    if ($jobJson.Contains($fakeNgrokToken)) { throw 'ngrok token leaked into job JSON.' }
    $parameterPath = Join-Path $installDir ("stack-management\jobs\" + $apply.jobId + ".parameters.json")
    if ([IO.File]::Exists($parameterPath) -and [IO.File]::ReadAllText($parameterPath).Contains($fakeNgrokToken)) { throw 'ngrok token leaked into installer parameter JSON.' }

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
    $result = [ordered]@{
        success = $true
        elapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        packageHead = [string]$manifest.head
        packageFingerprint = [string]$manifest.fingerprint
        jobId = [string]$apply.jobId
        state = [string]$job.phase
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
    Remove-Item Env:DEVSPACE_ONECLICK_TEST_SKIP_START -ErrorAction SilentlyContinue
    if ($setupProcess -and -not $setupProcess.HasExited) {
        & taskkill.exe /PID $setupProcess.Id /T /F | Out-Null
    }
    if (-not $KeepArtifacts -and [IO.Directory]::Exists($WorkRoot)) {
        Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
