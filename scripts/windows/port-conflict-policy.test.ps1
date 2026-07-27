$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$source = Get-Content (Join-Path $PSScriptRoot "devspace-watchdog.ps1") -Raw
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0].Message }
foreach ($name in @("Is-DevSpaceServe", "Is-HermesServe", "Is-RouterServe", "Test-FixedPortOwnership")) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $functionAst) { throw "Missing $name" }
    Invoke-Expression $functionAst.Extent.Text
}

$script:cliPath = "C:\tested\devspace\dist\cli.js"
$script:hermesServer = "C:\tested\hermes\server.py"
$script:hermesCommand = ""
$script:routerPath = "C:\state\mcp-router.cjs"
$script:owners = @{}
$script:messages = @()

function Get-ListenOwners([int]$listenPort) { @($script:owners.Keys) }
function Get-ProcessInfo([int]$processId) { $script:owners[$processId] }
function Write-WatchdogLog([string]$message) { $script:messages += $message }
function New-Owner([int]$id, [string]$name, [string]$command) {
    [pscustomobject]@{ ProcessId=$id; Name=$name; CommandLine=$command }
}

$script:owners = @{ 101 = New-Owner 101 "other.exe" "other.exe --listen 7676" }
if (Test-FixedPortOwnership 7676 "DevSpace") { throw "Unknown fixed-port owner was accepted." }
if ($script:messages[0] -notmatch "PID 101 \(other.exe\)" -or $script:messages[0] -notmatch "will not move") {
    throw "Conflict diagnostic lacks owner or next-action policy."
}

$script:messages = @()
$script:owners = @{ 102 = New-Owner 102 "node.exe" "node.exe C:\tested\devspace\dist\cli.js serve" }
if (-not (Test-FixedPortOwnership 7676 "DevSpace")) { throw "Managed DevSpace owner was rejected." }

$watchdog = Get-Content (Join-Path $PSScriptRoot "devspace-watchdog.ps1") -Raw
$installer = Get-Content (Join-Path $PSScriptRoot "install-devspace-watchdog.ps1") -Raw
if ($watchdog -notmatch '--web-addr') { throw "ngrok inspection port is not explicitly bound." }
if ($watchdog -match '127\.0\.0\.1:4040/api/tunnels') { throw "ngrok health check still assumes port 4040." }
if ($installer -notmatch 'ngrokInspectorPort') { throw "Selected ngrok inspection port is not persisted." }
if ($installer -notmatch 'Assert-FixedPortOwnership \$RouterPort') { throw "Router fixed-port preflight is missing." }

Write-Host "port conflict policy tests passed."
