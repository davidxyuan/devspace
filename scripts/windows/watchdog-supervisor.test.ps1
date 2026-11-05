param([string]$SourceDirectory)
$ErrorActionPreference = 'Stop'
if (-not $SourceDirectory) { $SourceDirectory = $PSScriptRoot }
$stateDir = Join-Path ([IO.Path]::GetTempPath()) ('devspace-supervisor-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($stateDir)
$ConfigPath = Join-Path $stateDir 'config.json'
$Mode = 'Watch'
$script:ticks = 0; $script:runs = 0; $script:busy = $false
function Test-StackOperationBusy { param($InstallDir) return $script:busy }
function Invoke-BootstrapRun { param($RequestedMode) $script:runs++ }
function Write-WatchdogCaptureEvent {}
function Write-WatchdogAtomicJson { param($Path,$Value) if ($Value.role -ne 'supervisor') { throw 'Invalid supervisor heartbeat.' } }
function Wait-SupervisorGeneration {
    param($Path, $Generation)
    $script:ticks++
    switch ($script:ticks) {
        1 { [IO.File]::WriteAllText((Join-Path $stateDir 'watchdog-manual-stop.flag'), 'manual') }
        2 { [IO.File]::Delete((Join-Path $stateDir 'watchdog-manual-stop.flag')); $script:busy=$true }
        3 { $script:busy=$false }
        4 { [IO.File]::WriteAllText((Join-Path $stateDir 'watchdog-supervisor-generation'), 'replacement') }
        default { throw 'Supervisor failed to exit on generation change.' }
    }
}
function Start-Sleep { param($Seconds) Wait-SupervisorGeneration }
try {
    $source = [IO.File]::ReadAllText((Join-Path $SourceDirectory 'devspace-watchdog-bootstrap.ps1'))
    $start = $source.IndexOf("`$pausePath = Join-Path")
    if ($start -lt 0) { throw 'Supervisor loop is missing.' }
    Invoke-Expression $source.Substring($start)
    if ($script:runs -ne 2 -or $script:ticks -ne 4) { throw 'Supervisor did not respect pause, management lock, resume and replacement.' }
    Write-Host 'Supervisor loop: repair, manual pause, management lock, resume and upgrade exit passed.'
} finally {
    $resolved = [IO.Path]::GetFullPath($stateDir)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('devspace-supervisor-test-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

& {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('devspace-supervisor-wake-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $worker = [PowerShell]::Create()
    try {
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
        $wait = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Wait-SupervisorGeneration'}, $true)
        $core = [Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceDirectory 'watchdog-control-core.ps1'), [ref]$null, [ref]$null)
        $read = $core.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-WatchdogText'}, $true)
        [void]$worker.AddScript({
            param($Root, $WaitFunction, $Loop)
            $ErrorActionPreference='Stop'; $stateDir=$Root; $ConfigPath=Join-Path $Root 'config.json'; $Mode='Watch'
            function Test-StackOperationBusy { return $true }
            function Write-WatchdogAtomicJson { param($Path,$Value) [IO.File]::WriteAllText((Join-Path $stateDir 'ready'), 'ready') }
            function Write-WatchdogEvent { throw 'Unexpected supervisor error in isolated wait test.' }
            function Protect-WatchdogText { param($Text) $Text }
            if ($WaitFunction) { Invoke-Expression $WaitFunction }
            Invoke-Expression $Loop
        }).AddArgument($root).AddArgument($(if ($wait) {$read.Extent.Text + "`n" + $wait.Extent.Text} else {''})).AddArgument($source.Substring($source.IndexOf("`$pausePath = Join-Path")))
        $run = $worker.BeginInvoke()
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
        while (-not [IO.File]::Exists((Join-Path $root 'ready')) -and [DateTimeOffset]::UtcNow -lt $deadline) {
            Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 20
        }
        if (-not [IO.File]::Exists((Join-Path $root 'ready'))) { throw 'Isolated supervisor did not start.' }
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 100
        [IO.File]::WriteAllText((Join-Path $root 'watchdog-supervisor-generation'), 'stop')
        if (-not $run.AsyncWaitHandle.WaitOne(2000)) { throw 'Supervisor slept through the stop generation change.' }
        [void]$worker.EndInvoke($run)
        if ($worker.HadErrors) { throw ($worker.Streams.Error | Out-String) }
        Write-Host 'Supervisor stop generation wakes the real wait within two seconds; no native roles launched.'
    } finally {
        $worker.Stop(); $worker.Dispose()
        $resolved = [IO.Path]::GetFullPath($root)
        if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -or
            -not [IO.Path]::GetFileName($resolved).StartsWith('devspace-supervisor-wake-')) { throw 'Unexpected wait-test cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

& {
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
    foreach ($name in @('Get-RoleHeartbeatStatus','Test-RoleHeartbeatFresh','Recover-StaleRole')) {
        $fn = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
        if ($fn) { Invoke-Expression $fn.Extent.Text }
    }
    $freshHeartbeatSeconds=15; $hostHeartbeatPath='fixture-host'; $hostScript='fixture.ps1'
    $started=[DateTimeOffset][datetime]'2026-01-01'
    $fresh=[pscustomobject]@{pid=42;processStartUtc=$started;timestamp=[DateTimeOffset]::UtcNow}
    $stale=[pscustomobject]@{pid=42;processStartUtc=$started;timestamp=[DateTimeOffset]::UtcNow.AddMinutes(-1)}
    $changed=[pscustomobject]@{pid=43;processStartUtc=$started;timestamp=[DateTimeOffset]::UtcNow}
    $reused=[pscustomobject]@{pid=42;processStartUtc=$started.AddSeconds(-1);timestamp=[DateTimeOffset]::UtcNow.AddMinutes(-1)}
    function Read-RoleHeartbeat {
        $value=$script:heartbeats[[Math]::Min($script:reads,$script:heartbeats.Count-1)]
        $script:reads++; return $value
    }
    function Get-RoleProcesses { return [pscustomobject]@{ProcessId=42;SessionId=1;CreationDate=[datetime]'2026-01-01'} }
    function Test-RoleRunning { return $true }
    function Stop-RoleReliably { $script:stops++ }
    function Assert-RoleStopped {}
    function Remove-StaleHeartbeat {}
    function Write-WatchdogEvent($Dir,$Config,$Role,$Event,$Cause) { $script:events += [pscustomobject]@{event=$Event;cause=$Cause} }
    function Check-Recovery([string]$Name, [object[]]$Heartbeats, [int]$ExpectedStops, [int]$Session=-1) {
        $script:reads=0; $script:stops=0; $script:events=@(); $script:heartbeats=$Heartbeats
        $retained=Recover-StaleRole $hostHeartbeatPath $Session
        if ($script:stops -ne $ExpectedStops -or $retained -ne ($ExpectedStops -eq 0)) { throw "$Name failed: stops=$script:stops retained=$retained" }
        if ($ExpectedStops -and -not ($script:events.cause -match 'identity=42:')) { throw "$Name did not record stop evidence." }
    }
    Check-Recovery 'transient read failure followed by fresh evidence' @($null,$fresh,$fresh) 0
    Check-Recovery 'heartbeat refreshed during slow process discovery' @($stale,$fresh) 0
    Check-Recovery 'heartbeat refreshed just before stop' @($stale,$stale,$fresh,$fresh) 0
    Check-Recovery 'unreadable evidence is not a stale role' @($null) 0
    Check-Recovery 'changed heartbeat identity is not stop authority' @($stale,$changed) 0
    Check-Recovery 'old heartbeat cannot authorize recovery of a reused PID' @($reused) 0
    Check-Recovery 'same PID with changed start time during discovery is retained' @($stale,$reused) 0
    Check-Recovery 'confirmed stale identity is recovered once' @($stale) 1
    Check-Recovery 'confirmed wrong interactive session is recovered' @($fresh) 1 2
    Check-Recovery 'correct interactive session is retained' @($fresh) 0 1
    Write-Host 'Supervisor recovery: transient/stale/changed heartbeat and session cases passed; stops require consistent evidence.'
}
