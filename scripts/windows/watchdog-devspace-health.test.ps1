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

$testLocalDevSpaceAst = $ast.Find(
    {
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq "Test-LocalDevSpace"
    },
    $true
)
$ensureDevSpaceAst = $ast.Find(
    {
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq "Ensure-DevSpace"
    },
    $true
)

if (-not $testLocalDevSpaceAst) { throw "Test-LocalDevSpace function was not found." }
if (-not $ensureDevSpaceAst) { throw "Ensure-DevSpace function was not found." }
if (-not $testLocalDevSpaceAst.Extent.Text.Contains('http://127.0.0.1:$port/healthz')) {
    throw "DevSpace watchdog must probe the dedicated /healthz endpoint."
}

Invoke-Expression $ensureDevSpaceAst.Extent.Text

$script:devspaceEnabled = $true
$script:port = 7676
$script:testListeners = @()
$script:testHealthy = $true
$script:startCount = 0
$script:stoppedPids = @()
$script:logMessages = @()

function Stop-RetiredPortListeners {}
function Test-FixedPortOwnership([int]$listenPort, [string]$serviceName) { return $true }
function Get-ListenOwners([int]$listenPort) {
    Assert-Equal "DevSpace listener port" $listenPort $script:port
    return @($script:testListeners)
}
function Get-CimInstance { return @() }
function Test-LocalDevSpace { return $script:testHealthy }
function Stop-ProcessTree([int]$processId, [string]$reason) { $script:stoppedPids += $processId }
function Start-DevSpace { $script:startCount++ }
function Start-Sleep { param([int]$Seconds) }
function Write-WatchdogLog([string]$message) { $script:logMessages += $message }

function Reset-TestState {
    $script:testListeners = @()
    $script:testHealthy = $true
    $script:startCount = 0
    $script:stoppedPids = @()
    $script:logMessages = @()
}

Reset-TestState
Ensure-DevSpace
Assert-Equal "Missing listener starts DevSpace" $script:startCount 1
Assert-Equal "Missing listener does not stop a process" $script:stoppedPids.Count 0

Reset-TestState
$script:testListeners = @(101)
$script:testHealthy = $true
Ensure-DevSpace
Assert-Equal "Healthy DevSpace is not restarted" $script:startCount 0
Assert-Equal "Healthy DevSpace is not stopped" $script:stoppedPids.Count 0

Reset-TestState
$script:testListeners = @(202)
$script:testHealthy = $false
Ensure-DevSpace
Assert-Equal "Busy DevSpace is not restarted" $script:startCount 0
Assert-Equal "Busy DevSpace listener is not stopped" $script:stoppedPids.Count 0
Assert-Equal "Busy DevSpace health failure is logged" $script:logMessages.Count 1

Write-Host "watchdog DevSpace health tests passed."
