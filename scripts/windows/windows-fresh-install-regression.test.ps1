$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$installerPath = Join-Path $PSScriptRoot "install-devspace-watchdog.ps1"
$watchdogPath = Join-Path $PSScriptRoot "devspace-watchdog.ps1"
$ngrokInstallPath = Join-Path $PSScriptRoot "ngrok-install.ps1"

$installer = Get-Content -LiteralPath $installerPath -Raw
$watchdog = Get-Content -LiteralPath $watchdogPath -Raw
$ngrokInstall = Get-Content -LiteralPath $ngrokInstallPath -Raw

foreach ($path in @($installerPath, $watchdogPath, $ngrokInstallPath)) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw "PowerShell parser failure in $path`n$($errors | Out-String)" }
}

if ($ngrokInstall -match '\$helpText\s+-match\s+.*--web-addr' -or $ngrokInstall -match '\$helpText\s+-notmatch\s+.*--web-addr') {
    throw "ngrok compatibility helper still depends on removed --web-addr."
}
if ($watchdog -match '\$ngrokArgs\s*\+=\s*@\("--web-addr"') { throw "watchdog still emits removed ngrok --web-addr." }
foreach ($text in @('ngrokConfigPath','--config", $ngrokConfigPath','$ngrokInspectorUrl/api/tunnels','Get-DeterministicFailureClass','Record-DeterministicFailure','watchdog-backoff-','ERR_NGROK_4018','ModuleNotFoundError')) {
    if (-not $watchdog.Contains($text)) { throw "watchdog is missing regression requirement: $text" }
}
if (-not $watchdog.Contains('mcp\.server\.fastmcp')) { throw "watchdog deterministic Hermes dependency classification is missing." }
foreach ($text in @('[string]$NgrokConfigPath','Join-Path $env:LOCALAPPDATA "ngrok\ngrok.yml"','config add-authtoken $effectiveNgrokAuthtoken --config $NgrokConfigPath','config check --config $NgrokConfigPath','ngrokConfigPath = if ($SkipNgrok)','ngrokInspectorPort = if ($SkipNgrok) { 0 } else { 4040 }','$principalLogonType = if ($UserMode -or $NoElevate) { "S4U" } else { "Interactive" }','$settings.Hidden = $true','Assert-InstallationHealth','http://127.0.0.1:$Port/healthz','http://127.0.0.1:$HermesPort/mcp','http://127.0.0.1:$RouterPort/__router/status','http://127.0.0.1:4040/api/tunnels','public-mcp-route:$publicOrigin','/$machineSlug/devspace_chatgpt/* -> http://127.0.0.1:$Port/*','/$machineSlug/hermes_chatgpt/* -> http://127.0.0.1:$HermesPort/*')) {
    if (-not $installer.Contains($text)) { throw "installer is missing regression requirement: $text" }
}
if ($installer -match 'strict-ssl\s+false|strict-ssl=false') { throw "installer must not persist insecure npm strict-ssl=false." }
Write-Host "fresh Windows installer regression tests passed."
