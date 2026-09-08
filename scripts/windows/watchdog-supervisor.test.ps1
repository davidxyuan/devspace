$ErrorActionPreference = 'Stop'
$stateDir = Join-Path ([IO.Path]::GetTempPath()) ('devspace-supervisor-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($stateDir)
$ConfigPath = Join-Path $stateDir 'config.json'
$Mode = 'Watch'
$script:ticks = 0; $script:runs = 0; $script:busy = $false
function Test-StackOperationBusy { param($InstallDir) return $script:busy }
function Invoke-BootstrapRun { param($RequestedMode) $script:runs++ }
function Write-WatchdogAtomicJson { param($Path,$Value) if ($Value.role -ne 'supervisor') { throw 'Invalid supervisor heartbeat.' } }
function Start-Sleep {
    param($Seconds)
    $script:ticks++
    switch ($script:ticks) {
        1 { [IO.File]::WriteAllText((Join-Path $stateDir 'watchdog-manual-stop.flag'), 'manual') }
        2 { [IO.File]::Delete((Join-Path $stateDir 'watchdog-manual-stop.flag')); $script:busy=$true }
        3 { $script:busy=$false }
        4 { [IO.File]::WriteAllText((Join-Path $stateDir 'watchdog-supervisor-generation'), 'replacement') }
        default { throw 'Supervisor failed to exit on generation change.' }
    }
}
try {
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'devspace-watchdog-bootstrap.ps1'))
    $start = $source.IndexOf("`$pausePath = Join-Path")
    if ($start -lt 0) { throw 'Supervisor loop is missing.' }
    Invoke-Expression $source.Substring($start)
    if ($script:runs -ne 2 -or $script:ticks -ne 4) { throw 'Supervisor did not respect pause, management lock, resume and replacement.' }
    Write-Host 'Supervisor loop: repair, manual pause, management lock, resume and upgrade exit passed.'
} finally {
    $resolved = [IO.Path]::GetFullPath($stateDir)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('devspace-supervisor-test-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
