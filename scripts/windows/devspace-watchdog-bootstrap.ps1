[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RuntimeDirectory,
    [ValidateSet("Run", "Watch", "Stop", "CheckStopped", "RepairHost", "RepairOpenCodexTray")]
    [string]$Mode = "Run",
    [switch]$ScheduledSupervisor
)

$ErrorActionPreference = "Stop"
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "devspace-watchdog.config.json" }
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
if (-not $RuntimeDirectory) { $RuntimeDirectory = $PSScriptRoot }
$RuntimeDirectory = [System.IO.Path]::GetFullPath($RuntimeDirectory)
$hostScript = Join-Path $RuntimeDirectory "devspace-watchdog-tray.ps1"
$trayScript = Join-Path $RuntimeDirectory "devspace-watchdog-tray-ui.ps1"
$powershell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
$freshHeartbeatSeconds = 15
. (Join-Path $PSScriptRoot "watchdog-control-core.ps1")
. (Join-Path $PSScriptRoot "stack-operation.ps1")

if (-not [System.IO.File]::Exists($ConfigPath)) { throw "Missing watchdog configuration: $ConfigPath" }
$config = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$stateDirValue = [string]$config.stateDir
if ([string]::IsNullOrWhiteSpace($stateDirValue)) { throw "Watchdog configuration has no stateDir." }
$stateDir = [System.IO.Path]::GetFullPath($stateDirValue)
$hostHeartbeatPath = Join-Path $stateDir "watchdog-host-heartbeat.json"
$trayHeartbeatPath = Join-Path $stateDir "watchdog-tray-heartbeat.json"

if ($Mode -eq 'Watch' -and -not $ScheduledSupervisor) {
    $installRecord = Join-Path $stateDir 'watchdog-tray-install.json'
    if ([IO.File]::Exists($installRecord)) {
        $record = [IO.File]::ReadAllText($installRecord) | ConvertFrom-Json
        if (Get-WatchdogProperty $record 'supervisorTask' '') {
            . (Join-Path $PSScriptRoot 'watchdog-install-transaction.ps1')
            $spec = Get-InstallSupervisorTaskSpec $stateDir
            if ($record.supervisorTask -ne $spec.name -or [IO.Path]::GetFullPath([string]$record.installDir) -ne $stateDir) { throw 'Supervisor installation identity mismatch.' }
            $task = Get-ScheduledTask -TaskName $spec.name -TaskPath '\' -ErrorAction Stop
            Assert-InstallSupervisorTask $task $spec
            [IO.File]::Delete((Join-Path $stateDir 'watchdog-manual-stop.flag'))
            Start-ScheduledTask -TaskName $spec.name -TaskPath '\' -ErrorAction Stop
            return
        }
    }
}

function Convert-NativeArgument([string]$Value) {
    if ($null -eq $Value -or $Value.Contains("`r") -or $Value.Contains("`n") -or $Value.Contains([char]0)) { throw "Invalid native process argument." }
    $builder = New-Object System.Text.StringBuilder
    $slash = [char]92
    $quote = [char]34
    [void]$builder.Append($quote)
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq $slash) { $backslashes++; continue }
        if ($character -eq $quote) {
            if ($backslashes -gt 0) { [void]$builder.Append(($slash.ToString() * ($backslashes * 2))) }
            [void]$builder.Append($slash)
            [void]$builder.Append($quote)
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { [void]$builder.Append(($slash.ToString() * $backslashes)); $backslashes = 0 }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append(($slash.ToString() * ($backslashes * 2))) }
    [void]$builder.Append($quote)
    return $builder.ToString()
}

function Start-HiddenNativeProcess([string]$FilePath, [string[]]$Arguments, [int]$WaitMilliseconds = 0) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (@($Arguments) | ForEach-Object { Convert-NativeArgument ([string]$_) }) -join " "
    $psi.WorkingDirectory = $RuntimeDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    # Host, Thin Tray, and the interactive task bridge must not retain a manager's lease token.
    $psi.EnvironmentVariables.Remove("DEVSPACE_STACK_OPERATION_TOKEN")
    $process = [System.Diagnostics.Process]::Start($psi)
    if (-not $process) { throw "Failed to start $FilePath" }
    try {
        if ($WaitMilliseconds -gt 0) {
            if (-not $process.WaitForExit($WaitMilliseconds)) { throw "$FilePath did not finish within $WaitMilliseconds ms." }
            return [int]$process.ExitCode
        }
        return 0
    } finally { $process.Dispose() }
}

function Start-HiddenWatchdogProcess([string]$ScriptPath, [string]$ChildMode) {
    if (-not [System.IO.File]::Exists($ScriptPath)) { throw "Missing watchdog script: $ScriptPath" }
    if (-not [System.IO.File]::Exists($powershell)) { throw "Windows PowerShell is missing: $powershell" }
    [void](Start-HiddenNativeProcess $powershell @(
        "-NoLogo", "-NoProfile", "-NonInteractive", "-STA",
        "-WindowStyle", "Hidden",
        "-File", $ScriptPath, "-Mode", $ChildMode, "-ConfigPath", $ConfigPath
    ))
}

if (-not ("DevSpaceWatchdogSessionNative" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DevSpaceWatchdogSessionNative {
    [DllImport("kernel32.dll")]
    public static extern uint WTSGetActiveConsoleSessionId();
}
"@
}

function Get-ActiveConsoleSessionId {
    $value = [uint32][DevSpaceWatchdogSessionNative]::WTSGetActiveConsoleSessionId()
    if ($value -eq [uint32]::MaxValue) { return -1 }
    return [int]$value
}

function Start-InteractiveWatchdogTray([int]$ExpectedSessionId) {
    if ($ExpectedSessionId -lt 0 -or [System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq $ExpectedSessionId) {
        Start-HiddenWatchdogProcess $trayScript "Run"
        return
    }
    $schtasks = Join-Path $env:WINDIR "System32\schtasks.exe"
    if (-not [System.IO.File]::Exists($schtasks)) { throw "Task Scheduler CLI is missing: $schtasks" }
    $taskName = "DevSpaceWatchdogTrayInteractive-" + [Guid]::NewGuid().ToString("N")
    # The task action itself is the long-lived Tray PowerShell process. This avoids
    # endpoint-security blocks on WScript spawning PowerShell and stays under the
    # legacy schtasks /TR command-length limit by using short PowerShell switches.
    $taskCommand = "powershell.exe -NoP -Sta -W Hidden -F " + (Convert-NativeArgument $trayScript) + " -ConfigPath " + (Convert-NativeArgument $ConfigPath)
    if ($taskCommand.Length -gt 240) { throw "Interactive Tray task command is unexpectedly long ($($taskCommand.Length) characters)." }
    $startAt = (Get-Date).AddMinutes(2).ToString("HH:mm")
    try {
        $created = Start-HiddenNativeProcess $schtasks @("/Create","/TN",$taskName,"/TR",$taskCommand,"/SC","ONCE","/ST",$startAt,"/RL","LIMITED","/IT","/F") 10000
        if ($created -ne 0) { throw "Could not create interactive Tray launch task (exit $created)." }
        $ran = Start-HiddenNativeProcess $schtasks @("/Run","/TN",$taskName) 10000
        if ($ran -ne 0) { throw "Could not run interactive Tray launch task (exit $ran)." }
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(45)
        do {
            Start-Sleep -Milliseconds 200
            if (Test-RoleHeartbeatFresh $trayHeartbeatPath $ExpectedSessionId) { return }
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
        throw "Interactive Tray did not publish a Session $ExpectedSessionId heartbeat within 45 seconds."
    } finally {
        try { [void](Start-HiddenNativeProcess $schtasks @("/Delete","/TN",$taskName,"/F") 5000) } catch { }
    }
}

function Start-InteractiveOpenCodexTray([int]$ExpectedSessionId) {
    $openCodexHome = [string]$config.openCodexHome
    if ([string]::IsNullOrWhiteSpace($openCodexHome)) { $openCodexHome = Join-Path $env:USERPROFILE ".opencodex" }
    $openCodexTrayScript = Join-Path $openCodexHome "opencodex-tray.ps1"
    if (-not [System.IO.File]::Exists($openCodexTrayScript)) { throw "OpenCodex Tray script is missing: $openCodexTrayScript" }
    if ($ExpectedSessionId -lt 0 -or [System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq $ExpectedSessionId) {
        [void](Start-HiddenNativeProcess $powershell @("-NoP","-Sta","-W","Hidden","-File",$openCodexTrayScript))
        return
    }
    $schtasks = Join-Path $env:WINDIR "System32\schtasks.exe"
    if (-not [System.IO.File]::Exists($schtasks)) { throw "Task Scheduler CLI is missing: $schtasks" }
    $taskName = "DevSpaceWatchdogOpenCodexInteractive-" + [Guid]::NewGuid().ToString("N")
    $taskCommand = "powershell.exe -NoP -Sta -W Hidden -F " + (Convert-NativeArgument $openCodexTrayScript)
    if ($taskCommand.Length -gt 240) { throw "OpenCodex interactive Tray task command is unexpectedly long ($($taskCommand.Length) characters)." }
    $startAt = (Get-Date).AddMinutes(2).ToString("HH:mm")
    try {
        $created = Start-HiddenNativeProcess $schtasks @("/Create","/TN",$taskName,"/TR",$taskCommand,"/SC","ONCE","/ST",$startAt,"/RL","LIMITED","/IT","/F") 10000
        if ($created -ne 0) { throw "Could not create interactive OpenCodex Tray task (exit $created)." }
        $ran = Start-HiddenNativeProcess $schtasks @("/Run","/TN",$taskName) 10000
        if ($ran -ne 0) { throw "Could not run interactive OpenCodex Tray task (exit $ran)." }
        Start-Sleep -Milliseconds 500
    } finally {
        try { [void](Start-HiddenNativeProcess $schtasks @("/Delete","/TN",$taskName,"/F") 5000) } catch { }
    }
}

function Read-RoleHeartbeat([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    try {
        $value = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $rolePid = 0
        if (-not [int]::TryParse([string]$value.pid, [ref]$rolePid) -or $rolePid -le 0) { return $null }
        $timestamp = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$value.timestamp, [ref]$timestamp)) { return $null }
        $sessionId = -1
        [void][int]::TryParse([string](Get-WatchdogProperty $value "sessionId" "-1"), [ref]$sessionId)
        return [pscustomobject]@{ pid=$rolePid; timestamp=$timestamp; sessionId=$sessionId; mutationInProgress=((Get-WatchdogProperty $value "mutationInProgress" $false) -eq $true) }
    } catch { return $null }
}

function Test-RoleHeartbeatFresh([string]$Path, [int]$ExpectedSessionId = -1) {
    $heartbeat = Read-RoleHeartbeat $Path
    if (-not $heartbeat) { return $false }
    $age = ([DateTimeOffset]::UtcNow - $heartbeat.timestamp.ToUniversalTime()).TotalSeconds
    if ($age -lt -5 -or $age -gt $freshHeartbeatSeconds) { return $false }
    $matches = @(Get-RoleProcesses $Path | Where-Object { [int]$_.ProcessId -eq [int]$heartbeat.pid })
    return $matches.Count -eq 1 -and ($ExpectedSessionId -lt 0 -or [int]$matches[0].SessionId -eq $ExpectedSessionId)
}

function Get-RoleProcesses([string]$HeartbeatPath) {
    $isHost = $HeartbeatPath -eq $hostHeartbeatPath
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop)) {
        $command = [string]$process.CommandLine
        if (-not $command) {
            # CIM can retain a process that exited during enumeration. Recheck
            # existence only; a live unreadable process must still block recovery.
            $remaining = Get-Process -Id ([int]$process.ProcessId) -ErrorAction SilentlyContinue
            if (-not $remaining) { continue }
            $remaining.Dispose()
            throw "Cannot verify PowerShell process $($process.ProcessId)."
        }
        if (-not (Test-WatchdogCommandToken $command $ConfigPath)) { continue }
        $matchesHost = (Test-WatchdogCommandToken $command $hostScript) -and $command -match '(?i)(?:^|\s)(?:"-Mode"|-Mode)\s+(?:"Host"|Host)(?=$|\s)'
        $matchesTray = ((Test-WatchdogCommandToken $command $trayScript) -or ((Test-WatchdogCommandToken $command $hostScript) -and -not $matchesHost)) -and
            $command -notmatch '(?i)(?:^|\s)(?:"-Mode"|-Mode)\s+(?:"Stop(?:Host)?"|Stop(?:Host)?)(?=$|\s)'
        if (($isHost -and $matchesHost) -or (-not $isHost -and $matchesTray)) {
            if (-not (Test-WatchdogExecutablePath $process $powershell) -or -not $process.CreationDate) { throw "Cannot verify watchdog process identity $($process.ProcessId)." }
            $process
        }
    }
}

function Test-RoleMutexExists([string]$HeartbeatPath) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ConfigPath.ToLowerInvariant()))).Replace("-", "").Substring(0, 20)
    } finally { $sha.Dispose() }
    $roles = if ($HeartbeatPath -eq $hostHeartbeatPath) { @("Host") } else { @("TrayUi", "Tray") }
    foreach ($role in $roles) {
        $mutex = $null
        try {
            $mutex = [System.Threading.Mutex]::OpenExisting("Local\DevSpaceWatchdog$role-$hash")
            return $true
        } catch [System.Threading.WaitHandleCannotBeOpenedException] { }
        finally { if ($mutex) { $mutex.Dispose() } }
    }
    return $false
}

function Test-RoleRunning([string]$HeartbeatPath) {
    return @(Get-RoleProcesses $HeartbeatPath).Count -gt 0 -or (Test-RoleMutexExists $HeartbeatPath)
}

function Assert-RoleStopped([string]$HeartbeatPath) {
    if (Test-RoleRunning $HeartbeatPath) { throw "Watchdog role is still running; retaining $HeartbeatPath." }
}

function Remove-StaleHeartbeat([string]$Path) {
    try { if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) } } catch { }
}

function Recover-StaleRole([string]$HeartbeatPath, [int]$ExpectedSessionId = -1) {
    if (Test-RoleHeartbeatFresh $HeartbeatPath $ExpectedSessionId) { return $true }
    if (Test-RoleRunning $HeartbeatPath) {
        if (-not (Read-RoleHeartbeat $HeartbeatPath)) { throw "Watchdog role is live without a valid heartbeat; refusing recovery: $HeartbeatPath" }
        if ($HeartbeatPath -eq $hostHeartbeatPath) { Stop-RoleReliably $HeartbeatPath $hostScript "StopHost" }
        else {
            $stopScript = if ([System.IO.File]::Exists($trayScript)) { $trayScript } else { $hostScript }
            Stop-RoleReliably $HeartbeatPath $stopScript "Stop"
        }
    }
    Assert-RoleStopped $HeartbeatPath
    Remove-StaleHeartbeat $HeartbeatPath
    return $false
}

function Stop-RoleFromHeartbeat([string]$HeartbeatPath) {
    $heartbeat = Read-RoleHeartbeat $HeartbeatPath
    if (-not $heartbeat) {
        # A graceful exit removes the heartbeat before PowerShell finishes teardown.
        # Wait for the identity-checked process; never force-kill without its heartbeat.
        foreach ($observed in @(Get-RoleProcesses $HeartbeatPath)) {
            $exiting = Get-Process -Id ([int]$observed.ProcessId) -ErrorAction SilentlyContinue
            if (-not $exiting) { continue }
            try {
                if ([Math]::Abs(($exiting.StartTime.ToUniversalTime() - ([datetime]$observed.CreationDate).ToUniversalTime()).Ticks) -ge 10) { throw 'Watchdog PID was reused; refusing exit proof.' }
                if (-not $exiting.WaitForExit(3000)) { throw "Cannot force-stop watchdog without a valid heartbeat: $HeartbeatPath" }
            } finally { $exiting.Dispose() }
        }
        Assert-RoleStopped $HeartbeatPath
        return
    }
    if ($heartbeat.mutationInProgress) { throw "Watchdog mutation is still draining; retaining $HeartbeatPath." }
    $matches = @(Get-RoleProcesses $HeartbeatPath | Where-Object { [int]$_.ProcessId -eq [int]$heartbeat.pid })
    if ($matches.Count -ne 1) { throw "Cannot prove watchdog heartbeat process identity: $HeartbeatPath" }
    $process = Get-Process -Id ([int]$heartbeat.pid) -ErrorAction Stop
    try {
        if ([Math]::Abs(($process.StartTime.ToUniversalTime() - ([datetime]$matches[0].CreationDate).ToUniversalTime()).Ticks) -ge 10) { throw "Watchdog PID was reused; refusing to stop it." }
        $process.Kill()
        if (-not $process.WaitForExit(3000)) { throw "Watchdog process did not exit after termination." }
    } finally { $process.Dispose() }
    Assert-RoleStopped $HeartbeatPath
}

function Stop-RoleReliably([string]$HeartbeatPath, [string]$ScriptPath, [string]$ChildMode) {
    if (-not (Test-RoleRunning $HeartbeatPath)) { Remove-StaleHeartbeat $HeartbeatPath; return }
    Start-HiddenWatchdogProcess $ScriptPath $ChildMode
    # Give the role enough time to drain HTTP/runspace work after the stop event.
    # Two seconds was too aggressive on production PCs and forced an unnecessary
    # cross-process Kill fallback while the same-user role was still exiting.
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while ((Test-RoleRunning $HeartbeatPath) -and [DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (Test-RoleRunning $HeartbeatPath) { Stop-RoleFromHeartbeat $HeartbeatPath }
    Assert-RoleStopped $HeartbeatPath
    Remove-StaleHeartbeat $HeartbeatPath
}

if ($Mode -eq "CheckStopped") {
    Assert-RoleStopped $trayHeartbeatPath
    Assert-RoleStopped $hostHeartbeatPath
    return
}

if ($Mode -eq "RepairOpenCodexTray") {
    Start-InteractiveOpenCodexTray (Get-ActiveConsoleSessionId)
    return
}

if ($Mode -eq "Stop") {
    $lease = $null
    try {
        $lease = Enter-StackOperation -InstallDir (Split-Path $ConfigPath -Parent)
        [IO.File]::WriteAllText((Join-Path $stateDir 'watchdog-manual-stop.flag'), 'Stopped explicitly or for maintenance')
        [IO.File]::WriteAllText((Join-Path $stateDir 'watchdog-supervisor-generation'), [guid]::NewGuid().ToString('N'))
        # Stop the Thin Tray first and prove it is gone before touching the Host.
        # Otherwise a still-running Tray can auto-repair the Host in the middle of an upgrade.
        $stopScript = if ([System.IO.File]::Exists($trayScript)) { $trayScript } else { $hostScript }
        Stop-RoleReliably $trayHeartbeatPath $stopScript "Stop"
        Stop-RoleReliably $hostHeartbeatPath $hostScript "StopHost"
    } finally { Exit-StackOperation $lease }
    return
}

function Invoke-HostRepair {
    Stop-RoleReliably $hostHeartbeatPath $hostScript "StopHost"
    Assert-RoleStopped $hostHeartbeatPath
    Start-HiddenWatchdogProcess $hostScript "Host"
}

function Invoke-BootstrapRun([string]$RequestedMode) {
    $lease = $null
    try {
        # Acquiring the lock closes the race between cached Tray busy state and a new update.
        $lease = Enter-StackOperation -InstallDir (Split-Path $ConfigPath -Parent)
        if ($RequestedMode -eq "RepairHost") { Invoke-HostRepair; return }
        if (-not (Recover-StaleRole $hostHeartbeatPath)) {
            Start-HiddenWatchdogProcess $hostScript "Host"
        }
        Start-Sleep -Milliseconds 150
        $activeConsoleSession = Get-ActiveConsoleSessionId
        if (-not (Recover-StaleRole $trayHeartbeatPath $activeConsoleSession)) {
            Start-InteractiveWatchdogTray $activeConsoleSession
        }
    } finally { Exit-StackOperation $lease }
}

$pausePath = Join-Path $stateDir 'watchdog-manual-stop.flag'
if ($Mode -in @('Run','Watch')) { [IO.File]::Delete($pausePath) }
if ($Mode -ne 'Watch') { Invoke-BootstrapRun $Mode; return }
$hasher = [Security.Cryptography.SHA256]::Create()
try { $guardName = 'Local\DevSpaceWatchdogSupervisor-' + [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($ConfigPath.ToLowerInvariant()))).Replace('-', '') }
finally { $hasher.Dispose() }
$guard = New-Object Threading.Mutex($false, $guardName)
$ownsGuard = $false
$generationPath = Join-Path $stateDir 'watchdog-supervisor-generation'
$generation = if ([IO.File]::Exists($generationPath)) { [IO.File]::ReadAllText($generationPath) } else { '' }
try {
    try { $ownsGuard = $guard.WaitOne(20000) } catch [Threading.AbandonedMutexException] { $ownsGuard = $true }
    if (-not $ownsGuard) { return }
    while ($true) {
        try {
            $currentGeneration = if ([IO.File]::Exists($generationPath)) { [IO.File]::ReadAllText($generationPath) } else { '' }
            if ($currentGeneration -ne $generation) { break }
            Write-WatchdogAtomicJson (Join-Path $stateDir 'watchdog-supervisor-heartbeat.json') ([pscustomobject]@{pid=$PID;role='supervisor';timestamp=[DateTimeOffset]::UtcNow.ToString('o')})
            if (-not [IO.File]::Exists($pausePath) -and -not (Test-StackOperationBusy -InstallDir (Split-Path $ConfigPath -Parent))) {
                Invoke-BootstrapRun 'Run'
            }
        } catch {
            try { Write-WatchdogEvent $stateDir $config 'supervisor' 'recovery_failed' (Protect-WatchdogText $_.Exception.Message) 'retry later' 'roles preserved' } catch { }
        }
        Start-Sleep -Seconds 15
    }
} finally { if ($ownsGuard) { $guard.ReleaseMutex() }; $guard.Dispose() }
