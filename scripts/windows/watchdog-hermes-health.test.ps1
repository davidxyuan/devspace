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

$ensureHermesAst = $ast.Find(
    {
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq "Ensure-Hermes"
    },
    $true
)

if (-not $ensureHermesAst) {
    throw "Ensure-Hermes function was not found."
}

Invoke-Expression $ensureHermesAst.Extent.Text

$script:hermesEnabled = $true
$script:hermesPort = 4750
$script:testListeners = @()
$script:testHealthy = $true
$script:startCount = 0
$script:stoppedPids = @()
$script:healthUrls = @()

function Get-ListenOwners([int]$listenPort) {
    Assert-Equal "Hermes listener port" $listenPort $script:hermesPort
    return @($script:testListeners)
}

function Test-HttpOk([string]$url) {
    $script:healthUrls += $url
    return $script:testHealthy
}

function Stop-ProcessTree([int]$processId, [string]$reason) {
    $script:stoppedPids += $processId
}

function Start-Hermes {
    $script:startCount++
}

function Start-Sleep {
    param([int]$Seconds)
}

function Reset-TestState {
    $script:testListeners = @()
    $script:testHealthy = $true
    $script:startCount = 0
    $script:stoppedPids = @()
    $script:healthUrls = @()
}

Reset-TestState
Ensure-Hermes
Assert-Equal "Missing listener starts Hermes" $script:startCount 1
Assert-Equal "Missing listener does not stop a process" $script:stoppedPids.Count 0

Reset-TestState
$script:testListeners = @(101)
$script:testHealthy = $true
Ensure-Hermes
Assert-Equal "Healthy Hermes is not restarted" $script:startCount 0
Assert-Equal "Healthy Hermes is not stopped" $script:stoppedPids.Count 0
Assert-Equal "Healthy Hermes is probed once" $script:healthUrls.Count 1
Assert-Equal "Hermes health endpoint" $script:healthUrls[0] "http://127.0.0.1:4750/mcp"

Reset-TestState
$script:testListeners = @(202)
$script:testHealthy = $false
Ensure-Hermes
Assert-Equal "Hung Hermes is restarted" $script:startCount 1
Assert-Equal "Hung Hermes listener is stopped" $script:stoppedPids.Count 1
Assert-Equal "Hung Hermes PID" $script:stoppedPids[0] 202
Assert-Equal "Hung Hermes is probed once" $script:healthUrls.Count 1

Write-Host "watchdog Hermes health tests passed."
