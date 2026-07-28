$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $here "update-cloud-endpoint-domain.ps1"

function Assert-True([string]$Name, [bool]$Value) {
    if (-not $Value) {
        throw "$Name failed."
    }
}

function Assert-Equal([string]$Name, $Actual, $Expected) {
    if ($Actual -ne $Expected) {
        throw "$Name failed.`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-Contains([string]$Name, [string]$Text, [string]$Expected) {
    if (-not $Text.Contains($Expected)) {
        throw "$Name failed.`nExpected output to contain: $Expected`nActual:`n$Text"
    }
}

function Assert-NotContains([string]$Name, [string]$Text, [string]$Unexpected) {
    if ($Text.Contains($Unexpected)) {
        throw "$Name failed.`nOutput unexpectedly contained: $Unexpected`nActual:`n$Text"
    }
}

function Write-Utf8Json([string]$Path, $Value) {
    $text = ($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-Fixture([string]$Root) {
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $policyPath = Join-Path $Root "ngrok-cloud-endpoint-tyo.policy.yml"
    $rulePath = Join-Path $Root "ngrok-cloud-endpoint-tyo.rule.yml"
    @"
on_http_request:
  - name: DevSpace tyo router
    expressions:
      - req.url.path.startsWith("/tyo/")
    actions:
      - type: forward-internal
        config:
          url: https://tyo-devspace.internal
          binding: internal
"@ | Set-Content -LiteralPath $policyPath -Encoding ASCII
    @"
- name: DevSpace tyo router
  expressions:
    - req.url.path.startsWith("/tyo/")
  actions:
    - type: forward-internal
      config:
        url: https://tyo-devspace.internal
        binding: internal
"@ | Set-Content -LiteralPath $rulePath -Encoding ASCII

    $watchdog = [ordered]@{
        stateDir = $Root
        machineSlug = "tyo"
        devspaceEnabled = $true
        hermesEnabled = $true
        mcpRoutes = @(
            [ordered]@{ name = "devspace_chatgpt_tyo"; service = "devspace"; prefix = "/tyo/devspace_chatgpt"; targetHost = "127.0.0.1"; targetPort = 7676 },
            [ordered]@{ name = "hermes_chatgpt_tyo"; service = "hermes"; prefix = "/tyo/hermes_chatgpt"; targetHost = "127.0.0.1"; targetPort = 4750 }
        )
        port = 7676
        cliPath = "D:\devspace\dist\cli.js"
        hermesPort = 4750
        routerPath = (Join-Path $Root "mcp-router.cjs")
        routerPort = 8766
        publicUpstreamPort = 8766
        ngrokPath = (Join-Path $Root "ngrok.exe")
        manageNgrok = $true
        publicBaseUrl = "https://old-domain.ngrok-free.app/tyo/devspace_chatgpt"
        ngrokEndpointMode = "CloudEndpoint"
        ngrokAgentBaseUrl = "https://tyo-devspace.internal"
        ngrokBinding = "internal"
        cloudEndpointPolicyPath = $policyPath
        cloudEndpointRulePath = $rulePath
    }
    Write-Utf8Json (Join-Path $Root "devspace-watchdog.config.json") $watchdog
    Write-Utf8Json (Join-Path $Root "config.json") ([ordered]@{
        host = "127.0.0.1"
        port = 7676
        allowedRoots = @("C:\", "D:\")
        publicBaseUrl = "https://old-domain.ngrok-free.app/tyo/devspace_chatgpt"
    })
    Write-Utf8Json (Join-Path $Root "oauth-metadata.json") ([ordered]@{
        issuer = "https://old-domain.ngrok-free.app/tyo/devspace_chatgpt/"
        resource = "https://old-domain.ngrok-free.app/tyo/devspace_chatgpt/mcp"
        hermesResource = "https://old-domain.ngrok-free.app/tyo/hermes_chatgpt/mcp"
    })
    Set-Content -LiteralPath (Join-Path $Root "mcp-router.cjs") -Value "// fixture" -Encoding ASCII
}

function Invoke-Updater([string]$StateDir, [string]$Domain, [string[]]$ExtraArgs = @()) {
    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath,
        "-NewDomain", $Domain,
        "-MachineName", "tyo",
        "-StateDir", $StateDir
    ) + $ExtraArgs
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & powershell.exe @arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("devspace-domain-update-test-" + [Guid]::NewGuid().ToString("N"))
try {
    $fixture = Join-Path $tempRoot "fixture"
    New-Fixture $fixture

    $normal = Invoke-Updater $fixture "new-domain.ngrok-free.app" @("-DryRun")
    Assert-Equal "host normalization succeeds" $normal.ExitCode 0
    Assert-Contains "host normalization" $normal.Output "New domain: https://new-domain.ngrok-free.app"
    Assert-Contains "DevSpace final URL" $normal.Output "https://new-domain.ngrok-free.app/tyo/devspace_chatgpt/mcp"
    Assert-Contains "Hermes final URL" $normal.Output "https://new-domain.ngrok-free.app/tyo/hermes_chatgpt/mcp"

    $origin = Invoke-Updater $fixture "https://new-domain.ngrok-free.app/" @("-DryRun")
    Assert-Equal "HTTPS origin normalization succeeds" $origin.ExitCode 0
    Assert-Contains "HTTPS origin normalization" $origin.Output "New domain: https://new-domain.ngrok-free.app"

    $http = Invoke-Updater $fixture "http://new-domain.ngrok-free.app" @("-DryRun")
    Assert-True "HTTP rejected" ($http.ExitCode -ne 0)
    Assert-Contains "HTTP rejection reason" $http.Output "must use HTTPS"

    foreach ($unsafe in @(
        "https://new-domain.ngrok-free.app/path",
        "https://new-domain.ngrok-free.app?query=1",
        "https://new-domain.ngrok-free.app#fragment",
        "https://user@new-domain.ngrok-free.app"
    )) {
        $rejected = Invoke-Updater $fixture $unsafe @("-DryRun")
        Assert-True "unsafe input rejected: $unsafe" ($rejected.ExitCode -ne 0)
    }

    $watchdogPath = Join-Path $fixture "devspace-watchdog.config.json"
    $configPath = Join-Path $fixture "config.json"
    $beforeWatchdog = [System.IO.File]::ReadAllBytes($watchdogPath)
    $beforeConfig = [System.IO.File]::ReadAllBytes($configPath)
    $dryRun = Invoke-Updater $fixture "new-domain.ngrok-free.app" @("-DryRun")
    Assert-Equal "Dry Run succeeds" $dryRun.ExitCode 0
    Assert-True "Dry Run watchdog unchanged" ([Convert]::ToBase64String($beforeWatchdog) -eq [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($watchdogPath)))
    Assert-True "Dry Run config unchanged" ([Convert]::ToBase64String($beforeConfig) -eq [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($configPath)))
    Assert-True "Dry Run creates no backup" (-not (Test-Path -LiteralPath (Join-Path $fixture "cloud-endpoint-domain-backups")))

    $applied = Invoke-Updater $fixture "new-domain.ngrok-free.app" @("-SkipServiceRestart", "-SkipPublicVerification")
    if ($applied.ExitCode -ne 0) { throw "domain update succeeds failed.`n$($applied.Output)" }
    $updatedWatchdog = Get-Content -LiteralPath $watchdogPath -Raw | ConvertFrom-Json
    $updatedConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $metadata = Get-Content -LiteralPath (Join-Path $fixture "oauth-metadata.json") -Raw
    Assert-Equal "watchdog publicBaseUrl" $updatedWatchdog.publicBaseUrl "https://new-domain.ngrok-free.app/tyo/devspace_chatgpt"
    Assert-Equal "DevSpace publicBaseUrl" $updatedConfig.publicBaseUrl "https://new-domain.ngrok-free.app/tyo/devspace_chatgpt"
    Assert-True "allowed host added" (@($updatedWatchdog.allowedHosts) -contains "new-domain.ngrok-free.app")
    Assert-NotContains "/mcp not duplicated" $updatedWatchdog.publicBaseUrl "/mcp/mcp"
    Assert-True "DevSpace route preserved" (@($updatedWatchdog.mcpRoutes).prefix -contains "/tyo/devspace_chatgpt")
    Assert-True "Hermes route preserved" (@($updatedWatchdog.mcpRoutes).prefix -contains "/tyo/hermes_chatgpt")
    Assert-Contains "metadata origin replaced" $metadata "https://new-domain.ngrok-free.app/tyo/hermes_chatgpt/mcp"
    Assert-NotContains "old metadata removed" $metadata "old-domain.ngrok-free.app"
    Assert-Contains "policy route preserved" (Get-Content -LiteralPath $updatedWatchdog.cloudEndpointPolicyPath -Raw) "/tyo/"
    Assert-Contains "rule route preserved" (Get-Content -LiteralPath $updatedWatchdog.cloudEndpointRulePath -Raw) "/tyo/"
    Assert-True "backup created" ((Get-ChildItem -LiteralPath (Join-Path $fixture "cloud-endpoint-domain-backups") -Directory).Count -eq 1)

    $rollbackFixture = Join-Path $tempRoot "rollback"
    New-Fixture $rollbackFixture
    $rollbackResult = Invoke-Updater $rollbackFixture "rollback-target.example.com" @("-SkipServiceRestart", "-SkipPublicVerification", "-SimulateVerificationFailure")
    Assert-True "simulated failure returns nonzero" ($rollbackResult.ExitCode -ne 0)
    $rolledBack = Get-Content -LiteralPath (Join-Path $rollbackFixture "devspace-watchdog.config.json") -Raw | ConvertFrom-Json
    Assert-Equal "rollback restores old domain" $rolledBack.publicBaseUrl "https://old-domain.ngrok-free.app/tyo/devspace_chatgpt"
    Assert-Contains "rollback output" $rollbackResult.Output "Original files restored"

    $tokenFixture = Join-Path $tempRoot "token"
    New-Fixture $tokenFixture
    $secret = "super-secret-token-" + [Guid]::NewGuid().ToString("N")
    $wrapperPath = Join-Path $tempRoot "token-wrapper.ps1"
    @"
`$token = ConvertTo-SecureString '$secret' -AsPlainText -Force
& '$scriptPath' -NewDomain 'token-target.example.com' -MachineName 'tyo' -StateDir '$tokenFixture' -UpdateNgrokAuthToken `$token -DryRun
"@ | Set-Content -LiteralPath $wrapperPath -Encoding UTF8
    $tokenOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapperPath 2>&1 | Out-String
    Assert-Equal "token Dry Run succeeds" $LASTEXITCODE 0
    Assert-NotContains "token redacted from output" $tokenOutput $secret
    Assert-Contains "token redaction notice" $tokenOutput "value redacted"
    $gitFiles = Get-ChildItem -LiteralPath (Split-Path $here -Parent | Split-Path -Parent) -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git)[\\/]' }
    $tokenInGitFiles = $gitFiles | Select-String -SimpleMatch $secret -ErrorAction SilentlyContinue
    Assert-True "token absent from Git files" (-not $tokenInGitFiles)
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Cloud Endpoint domain update tests passed."
