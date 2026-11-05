param([Parameter(Mandatory=$true)][string]$BaselineDirectory, [Parameter(Mandatory=$true)][string]$WorkRoot)
$ErrorActionPreference = 'Stop'
# Never retry the endpoint-security-blocked native experiment on a user machine.
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:RUNNER_OS -cne 'Windows' -or $env:COMPUTERNAME -eq 'C02250073') {
    throw 'This native test requires a disposable GitHub-hosted Windows runner.'
}
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
$tempRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'
if (-not $WorkRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $WorkRoot)) {
    throw 'A new directory below RUNNER_TEMP is required; existing data is preserved.'
}
. (Join-Path $PSScriptRoot 'watchdog-install-transaction.ps1')
. (Join-Path $PSScriptRoot 'stack-operation.ps1')
$files = @('watchdog-control-core.ps1','stack-operation.ps1','stack-host-management.ps1','watchdog-install-transaction.ps1',
    'devspace-watchdog-tray.ps1','devspace-watchdog-tray-ui.ps1','devspace-watchdog-bootstrap.ps1','devspace-control-center.html',
    'run-devspace-watchdog-tray-hidden.vbs','uninstall-devspace-watchdog-tray.ps1','restore-old-watchdog.ps1',
    'devspace-watchdog.ps1','devspace-watchdog-legacy.ps1','mcp-router.cjs')
$runtime = Join-Path $WorkRoot 'runtime'
$broken = Join-Path $WorkRoot 'broken-source'
foreach ($dir in @($runtime, $broken)) { [void][IO.Directory]::CreateDirectory($dir) }
foreach ($name in $files) {
    [IO.File]::Copy((Join-Path $BaselineDirectory $name), (Join-Path $runtime $name), $false)
    [IO.File]::Copy((Join-Path $PSScriptRoot $name), (Join-Path $broken $name), $false)
}
# Exercise the real updater's failed-start rollback, not a mocked readiness result.
[IO.File]::WriteAllText((Join-Path $broken 'devspace-watchdog-tray.ps1'), "throw 'expected native update startup failure'")
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
$configPath = Join-Path $runtime 'devspace-watchdog.config.json'
Write-WatchdogAtomicJson $configPath @{
    stateDir=$runtime; machineSlug='native-ci'; publicBaseUrl='https://validation.invalid';
    devspaceEnabled=$false; hermesEnabled=$false; routerPort=0; manageNgrok=$false;
    nodePath=(Get-Command node.exe).Source; cliPath=(Join-Path $env:GITHUB_WORKSPACE 'dist\cli.js');
    controlCenter=@{dashboardPort=$port}
}
$recordPath = Join-Path $runtime 'watchdog-tray-install.json'
Write-WatchdogAtomicJson $recordPath @{installDir=$runtime; installedFiles=@(foreach ($name in $files[0..10]) {
    @{name=$name; sha256=(Get-WatchdogFileSha256 (Join-Path $runtime $name))}
})}
$configHash = Get-WatchdogFileSha256 $configPath
$spec = Get-InstallSupervisorTaskSpec $runtime
$observed = @{}
$taskCreated = $false
$report = @{startedAt=[DateTimeOffset]::UtcNow.ToString('o'); head=$env:GITHUB_SHA; computer=$env:COMPUTERNAME;
    sessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId; task=$spec.name; passed=$false; stages=@();
    scope='GitHub Windows native task/process/dashboard update and failed-start rollback; backends disabled. Not TYO, rendered desktop, login/reboot or security-policy approval.'}
function Save-Result {
    $report.observedProcesses = @($observed.Values)
    Write-WatchdogAtomicJson (Join-Path $WorkRoot 'result.json') $report 16
}
function Observe-Processes {
    foreach ($p in @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($runtime) })) {
        $key = "$($p.ProcessId):$($p.CreationDate.ToUniversalTime().Ticks)"
        $observed[$key] = @{pid=[int]$p.ProcessId; startedUtc=$p.CreationDate.ToUniversalTime().ToString('o');
            name=$p.Name; parentPid=[int]$p.ParentProcessId; command=$p.CommandLine}
    }
}
function Read-NativeReady {
    Observe-Processes
    $roles = @(foreach ($pair in @(@('host','host','devspace-watchdog-tray.ps1'), @('tray','tray-ui','devspace-watchdog-tray-ui.ps1'), @('supervisor','supervisor','devspace-watchdog-bootstrap.ps1'))) {
        $h = Read-WatchdogJson (Join-Path $runtime "watchdog-$($pair[0])-heartbeat.json")
        if (-not $h -or $h.role -cne $pair[1]) { throw 'Missing role heartbeat.' }
        $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]$h.timestamp).TotalSeconds
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$h.pid)"
        if ($age -lt -5 -or $age -gt 30 -or -not $p -or
            -not $p.CommandLine.Contains((Join-Path $runtime $pair[2])) -or -not $p.CommandLine.Contains($configPath)) {
            throw 'Stale heartbeat or wrong native process identity.'
        }
        if ($pair[0] -ne 'supervisor' -and (-not $h.processStartUtc -or
            [Math]::Abs(($p.CreationDate.ToUniversalTime() - ([DateTimeOffset]$h.processStartUtc).UtcDateTime).Ticks) -ge 10)) {
            throw 'Heartbeat process start mismatch.'
        }
        @{role=$h.role; pid=[int]$h.pid; startedUtc=$p.CreationDate.ToUniversalTime().ToString('o'); sessionId=$p.SessionId; ageSeconds=$age}
    })
    $status = Invoke-RestMethod "http://127.0.0.1:$port/api/status" -TimeoutSec 2
    if (-not $status) { throw 'Dashboard is unavailable.' }
    Assert-InstallSupervisorTask (Get-ScheduledTask -TaskName $spec.name) $spec
    return $roles
}
function Checkpoint([string]$Name) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(45)
    do {
        try { $roles = @(Read-NativeReady); break } catch { $reason = $_.Exception.Message }
        Start-Sleep -Milliseconds 300
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    if (-not $roles) { throw "$Name failed readiness: $reason" }
    $report.stages += @{name=$Name; at=[DateTimeOffset]::UtcNow.ToString('o'); roles=$roles}
    Save-Result
}
function Assert-Payload([string]$Source) {
    foreach ($name in $files) {
        if ((Get-WatchdogFileSha256 (Join-Path $runtime $name)) -ne (Get-WatchdogFileSha256 (Join-Path $Source $name))) {
            throw "Runtime content mismatch: $name"
        }
    }
    $record = Read-WatchdogJson $recordPath
    foreach ($entry in $record.installedFiles) {
        if ($entry.sha256 -ne (Get-WatchdogFileSha256 (Join-Path $runtime $entry.name))) { throw 'Install receipt mismatch.' }
    }
    if ((Get-WatchdogFileSha256 $configPath) -ne $configHash) { throw 'Updater changed configuration.' }
}
try {
    Save-Result
    if (@(Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -EQ $spec.name).Count) { throw 'Native test task already exists.' }
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $spec.name -TaskPath '\' -Action (New-ScheduledTaskAction -Execute $spec.executable -Argument $spec.arguments) -Principal (New-ScheduledTaskPrincipal -UserId $spec.user -LogonType Interactive -RunLevel Limited) -Settings $settings | Out-Null
    $taskCreated = $true
    Export-ScheduledTask -TaskName $spec.name | Set-Content -LiteralPath (Join-Path $WorkRoot 'task.xml')
    Start-ScheduledTask -TaskName $spec.name
    Checkpoint 'baseline-ready'
    & (Join-Path $PSScriptRoot 'update-installed-watchdog-runtime.ps1') -InstallDir $runtime -SourceDir $PSScriptRoot -ExpectedMachineSlug 'native-ci' -Apply
    Checkpoint 'candidate-ready'
    Assert-Payload $PSScriptRoot
    $recordHash = Get-WatchdogFileSha256 $recordPath
    $expectedFailure = $false
    try {
        & (Join-Path $PSScriptRoot 'update-installed-watchdog-runtime.ps1') -InstallDir $runtime -SourceDir $broken -ExpectedMachineSlug 'native-ci' -Apply
    } catch {
        $report.failedStartError = $_.Exception.Message
        $expectedFailure = $report.failedStartError -like 'Runtime update failed and payload was restored:*'
    }
    if (-not $expectedFailure) { throw 'Broken Host did not produce a verified updater rollback.' }
    Checkpoint 'candidate-restored-after-failed-start'
    Assert-Payload $PSScriptRoot
    if ((Get-WatchdogFileSha256 $recordPath) -ne $recordHash) { throw 'Rollback did not restore the exact install receipt.' }
    & (Join-Path $PSScriptRoot 'update-installed-watchdog-runtime.ps1') -InstallDir $runtime -SourceDir $BaselineDirectory -ExpectedMachineSlug 'native-ci' -Apply
    Checkpoint 'baseline-restored'
    Assert-Payload $BaselineDirectory
    $report.legacyBaselineRestored = $true
    $report.passed = $true
} catch {
    $report.error = $_.Exception.Message
    throw
} finally {
    if ($taskCreated) {
        try {
            Observe-Processes
            & (Join-Path $PSScriptRoot 'devspace-watchdog-bootstrap.ps1') -Mode Stop -ConfigPath $configPath -RuntimeDirectory $runtime
            if ($report.legacyBaselineRestored) {
                # The unchanged old baseline still sleeps for 15 seconds; observe its natural exit only in teardown.
                $legacyWait = [Diagnostics.Stopwatch]::StartNew()
                do {
                    $task = Get-ScheduledTask -TaskName $spec.name
                    Assert-InstallSupervisorTask $task $spec
                    if ([string]$task.State -notin @('Running','Queued')) { break }
                    Start-Sleep -Milliseconds 250
                } while ($legacyWait.ElapsedMilliseconds -lt 20000)
                $report.legacyCleanupWaitMilliseconds = $legacyWait.ElapsedMilliseconds
            }
            Wait-InstallSupervisorTaskStopped $runtime
            & (Join-Path $PSScriptRoot 'devspace-watchdog-bootstrap.ps1') -Mode CheckStopped -ConfigPath $configPath -RuntimeDirectory $runtime
            Observe-Processes
            foreach ($item in $observed.Values) {
                $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($item.pid)"
                if ($p -and $p.CreationDate.ToUniversalTime().Ticks -eq ([DateTimeOffset]$item.startedUtc).UtcDateTime.Ticks) {
                    throw "Observed native process has not exited: $($item.pid)"
                }
            }
            Assert-InstallSupervisorTask (Get-ScheduledTask -TaskName $spec.name) $spec
            Unregister-ScheduledTask -TaskName $spec.name -TaskPath '\' -Confirm:$false
            $report.taskRemoved = $true
        } catch { $report.cleanupError = $_.Exception.Message; $report.passed = $false }
    }
    $report.finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Save-Result
}
if (-not $report.passed) { throw 'Native update test incomplete; inspect retained evidence.' }
Write-Output 'PASS native update, failed-start rollback, baseline restore and process/task cleanup.'
