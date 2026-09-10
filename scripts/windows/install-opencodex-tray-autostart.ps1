param(
    [string]$OpenCodexHome = (Join-Path $env:USERPROFILE '.opencodex'),
    [switch]$NoStart,
    [switch]$NoDesktopShortcut
)

$ErrorActionPreference = 'Stop'

function Get-StableTaskSuffix([string]$Path) {
    $normalized = [IO.Path]::GetFullPath($Path).TrimEnd('\','/').ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0,12)
    } finally { $sha.Dispose() }
}

function Test-FreshTrayHeartbeat([string]$HeartbeatPath) {
    if (-not (Test-Path $HeartbeatPath)) { return $false }
    try {
        $hb = Get-Content $HeartbeatPath -Raw | ConvertFrom-Json
        $pidValue = 0
        if (-not [int]::TryParse([string]$hb.pid, [ref]$pidValue) -or $pidValue -le 0) { return $false }
        $age = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [int64]$hb.timestamp
        return $age -ge -5000 -and $age -le 15000 -and [bool](Get-Process -Id $pidValue -ErrorAction SilentlyContinue)
    } catch { return $false }
}

$OpenCodexHome = [IO.Path]::GetFullPath($OpenCodexHome)
$statePath = Join-Path $OpenCodexHome 'tray-state.json'
$heartbeatPath = Join-Path $OpenCodexHome 'tray-heartbeat.json'
$launcherPath = Join-Path $OpenCodexHome 'opencodex-tray-launcher.exe'
$launcherSource = Join-Path $PSScriptRoot 'opencodex-tray-launcher.cs'
if (-not (Test-Path $statePath)) { throw "OpenCodex tray state is missing: $statePath" }
$state = Get-Content $statePath -Raw | ConvertFrom-Json
if ([int]$state.version -ne 1) { throw 'Unsupported OpenCodex tray state version.' }
if ([IO.Path]::GetFullPath([string]$state.opencodexHome) -ne $OpenCodexHome) { throw 'OpenCodex tray state points to a different home.' }
foreach ($required in @([string]$state.script,[string]$state.bun,[string]$state.cli,[string]$state.codexHome)) {
    if (-not (Test-Path $required)) { throw "Required OpenCodex tray path is missing: $required" }
}

$launcherValid = $false
if (Test-Path $launcherPath) {
    try {
        $p = Start-Process -FilePath $launcherPath -ArgumentList '--validate' -PassThru -Wait -WindowStyle Hidden
        $launcherValid = $p.ExitCode -eq 0
        $p.Dispose()
    } catch { $launcherValid = $false }
}
if (-not $launcherValid) {
    if (-not (Test-Path $launcherSource)) { throw "Native OpenCodex Tray launcher source is missing: $launcherSource" }
    $temporaryLauncher = Join-Path $OpenCodexHome ('opencodex-tray-launcher.' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        Add-Type -Path $launcherSource -OutputAssembly $temporaryLauncher -OutputType WindowsApplication -ReferencedAssemblies 'System.Web.Extensions.dll'
        $probe = Start-Process -FilePath $temporaryLauncher -ArgumentList '--validate' -PassThru -Wait -WindowStyle Hidden
        try { if ($probe.ExitCode -ne 0) { throw "Compiled native launcher validation failed with exit code $($probe.ExitCode)." } } finally { $probe.Dispose() }
        if (Test-Path $launcherPath) {
            $backupLauncher = Join-Path $OpenCodexHome ('opencodex-tray-launcher.before-autostart-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.exe')
            Copy-Item $launcherPath $backupLauncher -Force
        }
        Move-Item $temporaryLauncher $launcherPath -Force
    } finally {
        if (Test-Path $temporaryLauncher) { Remove-Item $temporaryLauncher -Force -ErrorAction SilentlyContinue }
    }
}

$suffix = Get-StableTaskSuffix $OpenCodexHome
$taskName = "OpenCodexTraySupervisor-$suffix"
$taskPath = '\'
$userName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$backupDir = Join-Path $OpenCodexHome ('configuration-backups\tray-autostart-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
if ($existingTask) { Export-ScheduledTask -TaskName $taskName -TaskPath $taskPath | Set-Content (Join-Path $backupDir 'task.xml') -Encoding Unicode }

$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'OpenCodex Tray.lnk'
$hadShortcut = Test-Path $shortcutPath
if ($hadShortcut) { Copy-Item $shortcutPath (Join-Path $backupDir 'OpenCodex Tray.lnk') -Force }

try {
    $action = New-ScheduledTaskAction -Execute $launcherPath -WorkingDirectory $OpenCodexHome
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userName
    $minuteTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType Interactive -RunLevel Limited
    $task = New-ScheduledTask -Action $action -Trigger @($logonTrigger,$minuteTrigger) -Settings $settings -Principal $principal -Description 'Keeps the OpenCodex notification-area tray available after logon and recovers it if the tray process exits.'
    Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -InputObject $task -Force | Out-Null

    if (-not $NoDesktopShortcut) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $launcherPath
        $shortcut.WorkingDirectory = $OpenCodexHome
        $shortcut.Description = 'Start OpenCodex Tray'
        $shortcut.Save()
    }

    if (Get-ScheduledTask -TaskName 'OpenCodexTrayStartTemp2' -TaskPath '\' -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName 'OpenCodexTrayStartTemp2' -TaskPath '\' -Confirm:$false
    }

    if (-not $NoStart -and -not (Test-FreshTrayHeartbeat $heartbeatPath)) {
        Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline -and -not (Test-FreshTrayHeartbeat $heartbeatPath)) { Start-Sleep -Milliseconds 250 }
        if (-not (Test-FreshTrayHeartbeat $heartbeatPath)) { throw 'OpenCodex Tray did not publish a fresh heartbeat after installing autostart.' }
    }
} catch {
    $taskBackup = Join-Path $backupDir 'task.xml'
    if (Test-Path $taskBackup) {
        Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Xml (Get-Content $taskBackup -Raw) -Force | Out-Null
    } elseif (Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false
    }
    $shortcutBackup = Join-Path $backupDir 'OpenCodex Tray.lnk'
    if (Test-Path $shortcutBackup) { Copy-Item $shortcutBackup $shortcutPath -Force }
    elseif (-not $hadShortcut -and (Test-Path $shortcutPath)) { Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue }
    throw
}

$installed = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath
$info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath
[pscustomobject]@{
    taskName = $taskName
    state = [string]$installed.State
    triggers = @($installed.Triggers).Count
    action = (@($installed.Actions) | ForEach-Object { $_.Execute + ' ' + $_.Arguments }) -join ' | '
    restartCount = $installed.Settings.RestartCount
    restartInterval = [string]$installed.Settings.RestartInterval
    shortcut = if ($NoDesktopShortcut) { $null } else { $shortcutPath }
    heartbeatFresh = Test-FreshTrayHeartbeat $heartbeatPath
    lastRunTime = $info.LastRunTime
    backup = $backupDir
} | ConvertTo-Json -Compress
