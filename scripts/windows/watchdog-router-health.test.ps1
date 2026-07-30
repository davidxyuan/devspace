[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Equal([string]$name, $actual, $expected) {
    if ($actual -ne $expected) {
        throw "$name failed.`nExpected: $expected`nActual:   $actual"
    }
}

$watchdogPath = Join-Path $PSScriptRoot "devspace-watchdog.ps1"
$watchdogSource = Get-Content -LiteralPath $watchdogPath -Raw
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput(
    $watchdogSource,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    throw "Unable to parse devspace-watchdog.ps1: $($parseErrors[0].Message)"
}

$ensureRouterAst = $ast.Find(
    {
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq "Ensure-Router"
    },
    $true
)

if (-not $ensureRouterAst) { throw "Ensure-Router function was not found." }
Invoke-Expression $ensureRouterAst.Extent.Text

$script:routerPort = 8766
$script:testListeners = @()
$script:testHealthy = $true
$script:startCount = 0
$script:stoppedPids = @()
$script:healthUrls = @()
$script:logMessages = @()

function Test-FixedPortOwnership([int]$listenPort, [string]$serviceName) { return $true }
function Get-ListenOwners([int]$listenPort) {
    Assert-Equal "Router listener port" $listenPort $script:routerPort
    return @($script:testListeners)
}
function Test-HttpOk([string]$url) {
    $script:healthUrls += $url
    return $script:testHealthy
}
function Stop-ProcessTree([int]$processId, [string]$reason) { $script:stoppedPids += $processId }
function Start-Router { $script:startCount++ }
function Start-Sleep { param([int]$Seconds) }
function Write-WatchdogLog([string]$message) { $script:logMessages += $message }

function Reset-TestState {
    $script:testListeners = @()
    $script:testHealthy = $true
    $script:startCount = 0
    $script:stoppedPids = @()
    $script:healthUrls = @()
    $script:logMessages = @()
}

Reset-TestState
Ensure-Router
Assert-Equal "Missing listener starts router" $script:startCount 1
Assert-Equal "Missing listener does not stop a process" $script:stoppedPids.Count 0
Assert-Equal "Missing listener does not probe before next cycle" $script:healthUrls.Count 0

Reset-TestState
$script:testListeners = @(101)
$script:testHealthy = $true
Ensure-Router
Assert-Equal "Healthy router is not restarted" $script:startCount 0
Assert-Equal "Healthy router is not stopped" $script:stoppedPids.Count 0
Assert-Equal "Healthy router is probed once" $script:healthUrls.Count 1
Assert-Equal "Router health endpoint" $script:healthUrls[0] "http://127.0.0.1:8766/__router/status"

Reset-TestState
$script:testListeners = @(202)
$script:testHealthy = $false
Ensure-Router
Assert-Equal "Busy router is not restarted" $script:startCount 0
Assert-Equal "Busy router listener is not stopped" $script:stoppedPids.Count 0
Assert-Equal "Busy router is probed once" $script:healthUrls.Count 1
Assert-Equal "Busy router failure is logged" $script:logMessages.Count 1

Write-Host "watchdog router health tests passed."
