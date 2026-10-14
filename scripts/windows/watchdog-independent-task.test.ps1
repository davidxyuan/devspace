$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'watchdog-install-transaction.ps1')
$spec = Get-InstallSupervisorTaskSpec (Join-Path $env:TEMP 'devspace task test')
if ([IO.Path]::GetFileName([string]$spec.executable) -ne 'conhost.exe' -or [string]$spec.arguments -notmatch '^--headless ' -or [string]$spec.arguments -notmatch 'ScheduledSupervisor') { throw 'Supervisor task is not using headless conhost.' }
$script:task = [pscustomobject]@{TaskName=$spec.name;TaskPath='\';Actions=@([pscustomobject]@{Execute=$spec.executable;Arguments=$spec.arguments});Principal=[pscustomobject]@{UserId=$spec.user;LogonType='Interactive';RunLevel='Limited'};Triggers=@();Settings=[pscustomobject]@{Enabled=$true;MultipleInstances='IgnoreNew';ExecutionTimeLimit='PT0S'}}
$script:removed = 0
function Get-ScheduledTask { param($TaskName,$TaskPath) return $script:task }
function Stop-ScheduledTask { param($TaskName,$TaskPath) if ($TaskName -ne $spec.name) { throw 'Wrong task stopped' } }
function Unregister-ScheduledTask { param($TaskName,$TaskPath,$Confirm) $script:removed++ }
Assert-InstallSupervisorTask $script:task $spec
$script:task.Actions[0].Execute=$spec.legacyExecutable; $script:task.Actions[0].Arguments=$spec.legacyArguments
Assert-InstallSupervisorTask $script:task $spec -AllowLegacyAction
$script:task.Actions[0].Execute=$spec.bridgeExecutable; $script:task.Actions[0].Arguments=$spec.bridgeArguments
Assert-InstallSupervisorTask $script:task $spec -AllowLegacyAction
$script:task.Actions[0].Execute=$spec.executable; $script:task.Actions[0].Arguments=$spec.arguments
$script:task.Settings | Add-Member -NotePropertyName RestartCount -NotePropertyValue 3
$script:task.Settings | Add-Member -NotePropertyName RestartInterval -NotePropertyValue 'PT1M'
$script:task.Triggers=@([pscustomobject]@{Enabled=$true;DaysInterval=1;StartBoundary='2026-09-10T00:00:00';CimClass=[pscustomobject]@{CimClassName='MSFT_TaskDailyTrigger'};Repetition=[pscustomobject]@{Interval='PT1M';Duration='P1D';StopAtDurationEnd=$false}})
if (-not (Test-InstallSupervisorRecoveryPolicy $script:task)) { throw 'Minute recovery trigger was not recognized.' }
Assert-InstallSupervisorTask $script:task $spec
$script:task.Triggers[0].Repetition.Interval='PT2M'
try { Assert-InstallSupervisorTask $script:task $spec; throw 'Foreign recovery trigger accepted' } catch { if ($_.Exception.Message -eq 'Foreign recovery trigger accepted') { throw } }
$script:task.Triggers[0].Repetition.Interval='PT1M'
Remove-InstallSupervisorTask (Join-Path $env:TEMP 'devspace task test')
if ($script:removed -ne 1) { throw 'Owned task was not removed' }
foreach ($field in @('Arguments','Execute')) {
    $saved = $script:task.Actions[0].$field
    $script:task.Actions[0].$field += ' foreign'
    $rejected = $false
    try { Remove-InstallSupervisorTask (Join-Path $env:TEMP 'devspace task test') } catch { $rejected = $true }
    if (-not $rejected -or $script:removed -ne 1) { throw 'Changed task was removed' }
    $script:task.Actions[0].$field = $saved
}
$script:task.Principal.UserId = 'S-1-5-18'
try { Assert-InstallSupervisorTask $script:task $spec; throw 'Foreign user accepted' } catch { if ($_.Exception.Message -eq 'Foreign user accepted') { throw } }
$script:task = $null
Remove-InstallSupervisorTask (Join-Path $env:TEMP 'devspace task test')
if ($script:removed -ne 1) { throw 'Absent task was removed' }
Write-Host 'Independent supervisor task: exact identity, cleanup, changed action/user rejection and absent task passed.'
# Exercise legacy supervisor recovery-policy migration without registering a real task.
$script:task = [pscustomobject]@{TaskName=$spec.name;TaskPath='\';Actions=@([pscustomobject]@{Execute=$spec.executable;Arguments=$spec.arguments});Principal=[pscustomobject]@{UserId=$spec.user;LogonType='Interactive';RunLevel='Limited'};Triggers=@();Settings=[pscustomobject]@{Enabled=$true;MultipleInstances='IgnoreNew';ExecutionTimeLimit='PT0S';RestartCount=0;RestartInterval=$null}}
$script:migrationXml=''
function Export-ScheduledTask { param($TaskName,$TaskPath) return '<?xml version="1.0" encoding="UTF-16"?><Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Settings><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy></Settings><Triggers /></Task>' }
function Register-ScheduledTask { param($TaskName,$TaskPath,$Xml,[switch]$Force) $script:migrationXml=$Xml; $script:task.Settings.RestartCount=3; $script:task.Settings.RestartInterval='PT1M'; $script:task.Triggers=@([pscustomobject]@{Enabled=$true;DaysInterval=1;StartBoundary='2026-09-10T00:00:00';CimClass=[pscustomobject]@{CimClassName='MSFT_TaskDailyTrigger'};Repetition=[pscustomobject]@{Interval='PT1M';Duration='P1D';StopAtDurationEnd=$false}}); return $script:task }
$migrated=Ensure-InstallSupervisorRecoveryPolicy (Join-Path $env:TEMP 'devspace task test')
if (-not $migrated.changed -or -not (Test-InstallSupervisorRecoveryPolicy $migrated.task) -or $script:migrationXml -notmatch '<RestartOnFailure>' -or $script:migrationXml -notmatch '<CalendarTrigger>') { throw 'Legacy supervisor recovery policy migration failed.' }
Write-Host 'Supervisor recovery policy migration to minute trigger passed.'
# Exercise actual installer registration and record rollback branches without scheduling anything.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'install-devspace-watchdog-tray.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw $errors[0] }
$create=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '-not $supervisorTask'},$true)
$supervisorSpec=$spec; $supervisorTask=$null; $supervisorTaskCreated=$false; $script:registrations=0; $script:failRegistration=$false
function New-ScheduledTaskAction { param($Execute,$Argument) if ($Execute -ne $spec.executable -or $Argument -cne $spec.arguments) { throw 'Wrong action' }; return @{} }
function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) if ($UserId -ne $spec.user -or $LogonType -ne 'Interactive' -or $RunLevel -ne 'Limited') { throw 'Wrong principal' }; return @{} }
function New-ScheduledTaskSettingsSet { param($ExecutionTimeLimit,$MultipleInstances,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$RestartCount,$RestartInterval) if ($ExecutionTimeLimit -ne [TimeSpan]::Zero -or $MultipleInstances -ne 'IgnoreNew' -or -not $AllowStartIfOnBatteries -or -not $DontStopIfGoingOnBatteries -or $RestartCount -ne 3 -or $RestartInterval -ne (New-TimeSpan -Minutes 1)) { throw 'Wrong settings' }; return @{} }
function Register-ScheduledTask { param($TaskName,$TaskPath,$Action,$Principal,$Settings) if ($script:failRegistration) { throw 'Injected registration failure' }; $script:registrations++ }
Invoke-Expression $create.Extent.Text
if (-not $supervisorTaskCreated -or $script:registrations -ne 1) { throw 'Creation not tracked for rollback' }
$supervisorTask=@{existing=$true}; $supervisorTaskCreated=$false
Invoke-Expression $create.Extent.Text
if ($supervisorTaskCreated -or $script:registrations -ne 1) { throw 'Existing task overwritten' }
$supervisorTask=$null; $script:failRegistration=$true
try { Invoke-Expression $create.Extent.Text; throw 'Failure ignored' } catch { if ($_.Exception.Message -eq 'Failure ignored') { throw } }
if ($supervisorTaskCreated) { throw 'Failed registration marked owned' }
$rollback=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$recordChanged'},$true)
$recordPath=[IO.Path]::GetTempFileName(); $recordChanged=$true
try {
    $previousRecord=[Text.Encoding]::UTF8.GetBytes('{"previous":true}')
    Invoke-Expression $rollback.Extent.Text
    if ([IO.File]::ReadAllText($recordPath) -ne '{"previous":true}') { throw 'Previous record not restored' }
    $previousRecord=$null
    Invoke-Expression $rollback.Extent.Text
    if ([IO.File]::Exists($recordPath)) { throw 'New record not removed on rollback' }
} finally { if ([IO.File]::Exists($recordPath)) { [IO.File]::Delete($recordPath) } }
Write-Host 'Installer task creation/reuse/failure and installation-record rollback passed.'
# Exercise the real Watch dispatch: clear manual pause and start only the verified task.
$dispatchAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'devspace-watchdog-bootstrap.ps1'),[ref]$tokens,[ref]$errors)
$dispatch=$dispatchAst.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq "$('$Mode') -eq 'Watch' -and -not $('$ScheduledSupervisor')"},$true)
$stateDir=[IO.Path]::GetFullPath((Join-Path $env:TEMP ('devspace-dispatch-test-'+[guid]::NewGuid().ToString('N'))))
[void][IO.Directory]::CreateDirectory($stateDir)
$spec=Get-InstallSupervisorTaskSpec $stateDir
$script:task=[pscustomobject]@{TaskName=$spec.name;TaskPath='\';Actions=@([pscustomobject]@{Execute=$spec.executable;Arguments=$spec.arguments});Principal=[pscustomobject]@{UserId=$spec.user;LogonType='Interactive';RunLevel='Limited'};Triggers=@();Settings=[pscustomobject]@{Enabled=$true;MultipleInstances='IgnoreNew';ExecutionTimeLimit='PT0S'}}
$script:starts=0
function Start-ScheduledTask { param($TaskName,$TaskPath) if ($TaskName -ne $spec.name -or $TaskPath -ne '\') { throw 'Wrong task started' }; $script:starts++ }
$Mode='Watch'; $ScheduledSupervisor=$false
try {
    [IO.File]::WriteAllText((Join-Path $stateDir 'watchdog-tray-install.json'), (@{installDir=$stateDir;supervisorTask=$spec.name} | ConvertTo-Json))
    [IO.File]::WriteAllText((Join-Path $stateDir 'watchdog-manual-stop.flag'),'pause')
    Invoke-Expression ($dispatch.Extent.Text.Replace('$PSScriptRoot', ("'" + $PSScriptRoot.Replace("'", "''") + "'")))
    if ($script:starts -ne 1 -or [IO.File]::Exists((Join-Path $stateDir 'watchdog-manual-stop.flag'))) { throw 'Watch did not resume independent task' }
    $ScheduledSupervisor=$true
    Invoke-Expression ($dispatch.Extent.Text.Replace('$PSScriptRoot', ("'" + $PSScriptRoot.Replace("'", "''") + "'")))
    if ($script:starts -ne 1) { throw 'Scheduled Watch recursively dispatched itself' }
} finally {
    [IO.File]::Delete((Join-Path $stateDir 'watchdog-tray-install.json'))
    [IO.File]::Delete((Join-Path $stateDir 'watchdog-manual-stop.flag'))
    [IO.Directory]::Delete($stateDir,$false)
}
Write-Host 'Watch dispatch, manual resume and recursion guard passed.'

# Run/RepairHost launches must not inherit an interactive caller's kill-on-close job.
& {
    $bootstrapAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'devspace-watchdog-bootstrap.ps1'),[ref]$null,[ref]$null)
    $fn=$bootstrapAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-HiddenWatchdogProcess'},$true)
    Invoke-Expression $fn.Extent.Text
    $powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $hostScript=Join-Path $PSScriptRoot 'devspace-watchdog-tray.ps1'
    $trayScript=Join-Path $PSScriptRoot 'devspace-watchdog-tray-ui.ps1'
    $hostHeartbeatPath='host-heartbeat'; $trayHeartbeatPath='tray-heartbeat'
    $ScheduledSupervisor=$false; $script:launches=@(); $script:nativeStarts=0
    function Start-ScheduledWatchdogRole { param($ScriptPath,$ChildMode,$HeartbeatPath,$ExpectedSessionId=-1) $script:launches+=@{path=$ScriptPath;mode=$ChildMode;heartbeat=$HeartbeatPath} }
    function Start-HiddenNativeProcess { $script:nativeStarts++; return 0 }
    Start-HiddenWatchdogProcess $hostScript 'Host'
    Start-HiddenWatchdogProcess $trayScript 'Run'
    if ($script:launches.Count -ne 2 -or $script:nativeStarts -ne 0 -or $script:launches[0].heartbeat -ne $hostHeartbeatPath -or $script:launches[1].heartbeat -ne $trayHeartbeatPath) { throw 'Long-lived roles still inherit the caller job.' }
    Start-HiddenWatchdogProcess $hostScript 'StopHost'
    $ScheduledSupervisor=$true
    Start-HiddenWatchdogProcess $hostScript 'Host'
    if ($script:launches.Count -ne 2 -or $script:nativeStarts -ne 2) { throw 'Stop helper or independent supervisor launch regressed.' }
}

& {
    foreach ($name in @('Convert-NativeArgument','Start-ScheduledWatchdogRole')) {
        $fn=$dispatchAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        Invoke-Expression ($fn.Extent.Text.Replace('$PSScriptRoot', ("'" + $PSScriptRoot.Replace("'", "''") + "'")))
    }
    $RuntimeDirectory=Join-Path $env:TEMP 'role launch fixture'
    $ConfigPath=Join-Path $RuntimeDirectory 'config.json'
    $powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:roleTask=$null; $script:deletes=0; $script:failure=''; $script:probeSession=-2
    function New-ScheduledTaskAction { param($Execute,$Argument) return [pscustomobject]@{Execute=$Execute;Arguments=$Argument} }
    function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) return [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel} }
    function New-ScheduledTaskSettingsSet { param($ExecutionTimeLimit,$MultipleInstances,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries) return [pscustomobject]@{Enabled=$true;ExecutionTimeLimit='PT0S';MultipleInstances=$MultipleInstances;RestartCount=0;RestartInterval=''} }
    function Register-ScheduledTask {
        param($TaskName,$TaskPath,$Action,$Principal,$Settings,[switch]$Force)
        if ($Force) { throw 'A launch must never overwrite an existing task.' }
        if ($script:failure -eq 'register') { throw 'fixture registration failed' }
        $script:roleTask=[pscustomobject]@{TaskName=$TaskName;TaskPath=$TaskPath;Actions=@($Action);Principal=$Principal;Settings=$Settings;Triggers=@()}
    }
    function Get-ScheduledTask { return $script:roleTask }
    function Start-ScheduledTask {
        if ($script:failure -eq 'start') { throw 'fixture start failed' }
        if ($script:failure -eq 'changed') { $script:roleTask.Actions[0].Arguments+=' foreign' }
    }
    function Unregister-ScheduledTask { param($TaskName,$TaskPath,$Confirm) if ($TaskName -ne $script:roleTask.TaskName -or $TaskPath -ne '\') { throw 'Wrong task cleanup' }; $script:deletes++ }
    function Start-Sleep {}
    function Test-RoleHeartbeatFresh { param($Path,$ExpectedSessionId) $script:probeSession=$ExpectedSessionId; return $true }
    function Read-RoleHeartbeat { return [pscustomobject]@{pid=123;timestamp=[DateTimeOffset]::UtcNow} }
    function Write-WatchdogCaptureEvent {}
    Start-ScheduledWatchdogRole (Join-Path $RuntimeDirectory 'tray.ps1') 'Run' 'heartbeat' 7
    if ($script:deletes -ne 1 -or $script:probeSession -ne 7 -or $script:roleTask.Actions[0].Execute -notmatch 'conhost.exe$' -or $script:roleTask.Actions[0].Arguments -notmatch '^--headless ' -or $script:roleTask.Actions[0].Arguments -notmatch '"-STA"') { throw 'Independent role action, session or cleanup failed.' }
    foreach ($failure in @('register','start','changed')) {
        $script:failure=$failure; $before=$script:deletes; $rejected=$false
        try { Start-ScheduledWatchdogRole 'host.ps1' 'Host' 'heartbeat' } catch { $rejected=$true }
        $expected=if ($failure -eq 'start') {1} else {0}
        if (-not $rejected -or $script:deletes -ne ($before+$expected)) { throw "Unsafe launch failure cleanup: $failure" }
    }
}
Write-Host 'Role launch: independent caller handoff, supervisor/stop-helper bypass, exact task cleanup and failure rejection passed.'
