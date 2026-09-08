[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"
if ([Threading.Thread]::CurrentThread.ApartmentState -ne "STA") { throw "Run this test with powershell.exe -STA." }
Add-Type -AssemblyName System.Windows.Forms
function Assert-True([string]$Name, [bool]$Value) { if (-not $Value) { throw "$Name failed." } }
$errors = $null
$sourcePath = Join-Path $PSScriptRoot "devspace-watchdog-tray-ui.ps1"
$source = [IO.File]::ReadAllText($sourcePath)
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$errors)
if ($errors.Count) { throw $errors[0].Message }
$start = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Start-TrayBackgroundWorker" }, $true)
Invoke-Expression $start.Extent.Text
$workerAssignment = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$trayWorkerBody' }, $true)
Invoke-Expression $workerAssignment.Extent.Text
$timerHook = [regex]::Match($source, '(?s)\$timer\.add_Tick\(\{.*?\r?\n\}\)').Value
Assert-True "production UI timer found" ([bool]$timerHook)
Assert-True "timer contains no sleep, file writes, or process launch" ($timerHook -notmatch 'Start-Sleep|Write-WatchdogAtomicJson|Start-Process|Start-Hidden|\[.*File\]')
Assert-True "Repair menu only queues intent" ($source.Contains('$repairHostItem.add_Click({ $script:trayShared.RepairRequested = $true })'))

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("devspace-tray-responsive-" + [guid]::NewGuid().ToString("N"))
$worker = $null; $timer = $null; $finishTimer = $null; $stopEvent = $null
try {
    [void][IO.Directory]::CreateDirectory($tempRoot)
    $corePath = Join-Path $tempRoot "fixture-core.ps1"
    $operationPath = Join-Path $tempRoot "fixture-operation.ps1"
    [IO.File]::WriteAllText($corePath, @'
function ConvertTo-WatchdogIso($Value) { $Value.ToString("o") }
function Write-WatchdogAtomicJson($Path, $Value, $Timeout) {
    $Shared.WriteStarted = $true
    Start-Sleep -Milliseconds 1400
    $Shared.WriteCompleted = $true
}
'@)
    [IO.File]::WriteAllText($operationPath, 'function Test-StackOperationBusy { param($InstallDir) return $false }')
    $script:trayShared = [hashtable]::Synchronized(@{
        Stop=$false; ExitRequested=$false; OpenDashboard=$false; OpenLogs=$false; RepairRequested=$false
        EnsureRequested=$false; ManagementBusy=$true; ChildRunning=$false; StatusText="Checking"; WorkerMessage=""
        WriteStarted=$false; WriteCompleted=$false
    })
    $script:lastStatus = $null; $script:statusFailures = 0
    $script:ticksDuringWrite = 0; $script:totalTicks = 0
    $repairHostItem = [pscustomobject]@{Enabled=$false;Text=""}
    $statusItem = [pscustomobject]@{Text=""}
    function Complete-StatusProbe {
        $script:totalTicks++
        if ($script:trayShared.WriteStarted -and -not $script:trayShared.WriteCompleted) { $script:ticksDuringWrite++ }
    }
    function Start-StatusProbe {}
    $stopEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset)
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 30
    Invoke-Expression $timerHook
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $finishTimer = New-Object Windows.Forms.Timer
    $finishTimer.Interval = 30
    $finishTimer.add_Tick({
        if ($script:trayShared.WriteCompleted -or $watch.ElapsedMilliseconds -gt 5000) { [Windows.Forms.Application]::ExitThread() }
    })
    $worker = Start-TrayBackgroundWorker $script:trayShared $trayWorkerBody @($corePath,$operationPath,(Join-Path $tempRoot "config.json"),(Join-Path $tempRoot "heartbeat.json"),(Join-Path $tempRoot "host.json"),"http://127.0.0.1:1/",$tempRoot,(Join-Path $tempRoot "never-executed.ps1"),$tempRoot,123,1,"fixture")
    $timer.Start(); $finishTimer.Start()
    [Windows.Forms.Application]::Run((New-Object Windows.Forms.ApplicationContext))
    Assert-True "background delayed heartbeat completed" $script:trayShared.WriteCompleted
    Assert-True "real STA timer pumps during slow heartbeat I/O" ($script:ticksDuringWrite -ge 10)
    Assert-True "cached repair state remains usable" $repairHostItem.Enabled
    Write-Host "Tray responsiveness passed: $($script:ticksDuringWrite) UI timer ticks during 1.4s background write; no real role or process launched."
} finally {
    if ($timer) { $timer.Stop(); $timer.Dispose() }
    if ($finishTimer) { $finishTimer.Stop(); $finishTimer.Dispose() }
    if ($worker) {
        $script:trayShared.Stop = $true
        try { [void]$worker.pipeline.EndInvoke($worker.result) } finally { $worker.pipeline.Dispose() }
    }
    if ($stopEvent) { $stopEvent.Dispose() }
    $resolved = [IO.Path]::GetFullPath($tempRoot)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith("devspace-tray-responsive-")) { Remove-Item -LiteralPath $resolved -Force -Recurse }
}
