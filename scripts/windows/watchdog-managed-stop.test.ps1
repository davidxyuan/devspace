param([switch]$Native)
$ErrorActionPreference = 'Stop'
if ($Native -and ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:RUNNER_OS -cne 'Windows' -or $env:COMPUTERNAME -eq 'C02250073')) {
    throw 'Native stop validation requires a disposable GitHub-hosted Windows runner.'
}
. (Join-Path $PSScriptRoot 'watchdog-control-core.ps1')
function Assert-Stop([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }

# Keep the service, process and lock boundaries inert for the regression cases.
& {
    $fixture = @{ processes=@(); handles=@{}; actions=[Collections.Generic.List[string]]::new(); inventoryFailure=$false; starts=0 }
    $config = @{stateDir='unused-stop-fixture'}
    function Enter-StackOperation { return @{} }
    function Exit-StackOperation { }
    function Get-CimInstance { if ($fixture.inventoryFailure) { throw 'inventory unavailable' }; return $fixture.processes }
    function Get-WatchdogProcessLayer { return @{identityConflict=$false} }
    function Test-WatchdogManagedProcess($Process) { return $Process.ProcessId -eq 42001 }
    function Get-Process {
        param($Id)
        if (-not $fixture.handles.ContainsKey([int]$Id)) {
            throw [Management.Automation.ErrorRecord]::new([ArgumentException]::new('already gone'), 'NoProcessFoundForGivenId', 'ObjectNotFound', $Id)
        }
        return $fixture.handles[[int]$Id]
    }
    function Stop-Process { throw 'PID-only termination is forbidden' }
    function Start-WatchdogManagedService { $fixture.starts++; return @{success=$true} }
    function Reset-StopFixture {
        $fixture.actions.Clear(); $fixture.handles=@{}; $fixture.inventoryFailure=$false; $fixture.starts=0
        $fixture.processes = @(
            [pscustomobject]@{ProcessId=42001;ParentProcessId=0;CreationDate=[datetime]'2026-11-16T00:00:00Z'},
            [pscustomobject]@{ProcessId=42002;ParentProcessId=42001;CreationDate=[datetime]'2026-11-16T00:00:01Z'}
        )
        foreach ($item in $fixture.processes) {
            $process = [pscustomobject]@{Id=$item.ProcessId; Born=$item.CreationDate; Pinned=$false; Denied=$false; HasExited=$false; Exits=$true; Disposed=$false}
            $process | Add-Member ScriptProperty Handle { if ($this.Denied) { throw 'handle denied' }; $this.Pinned=$true; return [IntPtr]1 }
            $process | Add-Member ScriptProperty StartTime { if (-not $this.Pinned) { throw 'identity read before retaining handle' }; return $this.Born }
            $process | Add-Member ScriptMethod Kill { $fixture.actions.Add("kill:$($this.Id)"); $this.HasExited=$this.Exits }
            $process | Add-Member ScriptMethod WaitForExit { param($Timeout) $fixture.actions.Add("wait:$($this.Id)"); return $this.HasExited }
            $process | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
            $fixture.handles[[int]$item.ProcessId] = $process
        }
    }
    Reset-StopFixture
    $fixture.handles[42001].Born = $fixture.handles[42001].Born.AddTicks(7)
    $result = Stop-WatchdogManagedService 'router' $config
    Assert-Stop $result.success "Expected safe stop: $($result.error)"
    Assert-Stop (($fixture.actions -join ',') -eq 'kill:42002,wait:42002,kill:42001,wait:42001') 'Children must exit before parents.'
    Assert-Stop (@($fixture.handles.Values | Where-Object { -not $_.Disposed }).Count -eq 0) 'Handles were not disposed.'
    foreach ($scenario in @('reused-root','reused-child','missing-time','older-child','denied','inventory')) {
        Reset-StopFixture
        switch ($scenario) {
            'reused-root' { $fixture.handles[42001].Born=$fixture.handles[42001].Born.AddSeconds(1) }
            'reused-child' { $fixture.handles[42002].Born=$fixture.handles[42002].Born.AddSeconds(1) }
            'missing-time' { $fixture.processes[1].CreationDate=$null }
            'older-child' { $fixture.processes[1].CreationDate=$fixture.processes[0].CreationDate.AddSeconds(-1) }
            'denied' { $fixture.handles[42001].Denied=$true }
            'inventory' { $fixture.inventoryFailure=$true }
        }
        $result = Stop-WatchdogManagedService 'router' $config
        Assert-Stop (-not $result.success) "$scenario must reject termination."
        Assert-Stop ($fixture.actions.Count -eq 0) "$scenario stopped a process before validating the entire plan."
        Assert-Stop (@($fixture.handles.Values | Where-Object { $_.Pinned -and -not $_.Disposed }).Count -eq 0) "$scenario leaked a process handle."
    }
    Reset-StopFixture
    $fixture.handles[42002].Exits=$false
    $result = Restart-WatchdogManagedService 'router' 'C:\unused\config.json' $config
    Assert-Stop (-not $result.success -and $fixture.starts -eq 0) 'An unconfirmed exit must block restart.'
    Assert-Stop (($fixture.actions -join ',') -eq 'kill:42002,wait:42002') 'Stop must abort when the child has not exited.'
    Reset-StopFixture
    $fixture.handles[42002].HasExited=$true
    $result = Stop-WatchdogManagedService 'router' $config
    Assert-Stop ($result.success -and ($fixture.actions -join ',') -eq 'wait:42002,kill:42001,wait:42001') 'An already exited identity must not be killed again.'
    Reset-StopFixture
    $fixture.handles.Remove(42002)
    $result = Stop-WatchdogManagedService 'router' $config
    Assert-Stop ($result.success -and ($fixture.actions -join ',') -eq 'kill:42001,wait:42001') 'A child gone before opening its handle must not be retargeted.'
    Reset-StopFixture
    $fixture.handles[42002].Born=$fixture.handles[42002].Born.AddSeconds(1)
    $result = Invoke-WatchdogServiceRecovery 'router' 'C:\unused\config.json' $config @{}
    Assert-Stop (-not $result.success -and $fixture.starts -eq 0) 'A changed identity must block automatic recovery.'
}
Write-Output 'PASS managed stop identity, complete preflight, tree order, exit proof and restart refusal.'

if ($Native) {
    $work = Join-Path $env:RUNNER_TEMP ('watchdog-managed-stop-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($work)
    $node = (Get-Command node.exe).Source
    $children = [Collections.Generic.List[object]]::new()
    $report = @{head=$env:GITHUB_SHA; startedAt=[DateTimeOffset]::UtcNow.ToString('o'); passed=$false; processes=@();
        scope='Disposable Windows runner, two inert Node processes; one injected identity mismatch. No TYO or real backend data.'}
    try {
        foreach ($name in @('router.cjs','unrelated.cjs')) {
            $path = Join-Path $work $name
            [IO.File]::WriteAllText($path, 'setInterval(() => {}, 1000);')
            $child = Start-Process -FilePath $node -ArgumentList ('"' + $path + '"') -WindowStyle Hidden -PassThru
            $children.Add($child)
            [void]$child.Handle
            $report.processes += @{pid=$child.Id; startedUtc=$child.StartTime.ToUniversalTime().ToString('o'); name=$name}
        }
        $config = @{stateDir=$work; nodePath=$node; routerPath=(Join-Path $work 'router.cjs'); routerPort=0}
        & {
            function Get-CimInstance {
                $items = @(CimCmdlets\Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object ProcessId,ParentProcessId,CreationDate,ExecutablePath,Name,CommandLine)
                foreach ($item in $items) { if ($item.ProcessId -eq $children[0].Id) { $item.CreationDate=$item.CreationDate.AddSeconds(-1) } }
                return $items
            }
            $result = Stop-WatchdogManagedService 'router' $config
            Assert-Stop (-not $result.success -and $result.error -like 'Process identity changed for PID*' -and
                -not $children[0].HasExited -and -not $children[1].HasExited) "Identity mismatch must preserve both native processes: $($result.error)"
            $report.mismatchRejected=$true
        }
        $result = Stop-WatchdogManagedService 'router' $config
        Assert-Stop ($result.success -and $children[0].WaitForExit(0)) "Native managed process did not exit: $($result.error)"
        Assert-Stop (-not $children[1].HasExited) 'The unrelated native process was stopped.'
        $report.managedExited=$true
        $report.unrelatedPreserved=$true
        $report.passed=$true
    } catch { $report.error=$_.Exception.Message; throw }
    finally {
        foreach ($child in $children) {
            try {
                if (-not $child.HasExited) { $child.Kill() }
                if (-not $child.WaitForExit(3000)) { throw "Test process $($child.Id) did not exit." }
            } catch { $report.cleanupError=$_.Exception.Message; $report.passed=$false }
            finally { $child.Dispose() }
        }
        $report.finishedAt=[DateTimeOffset]::UtcNow.ToString('o')
        Write-WatchdogAtomicJson (Join-Path $env:RUNNER_TEMP 'watchdog-managed-stop.json') $report 10
    }
    Assert-Stop $report.passed 'Native stop validation or cleanup failed.'
    Write-Output 'PASS native managed stop, mismatched identity refusal, unrelated process preservation and cleanup.'
}
