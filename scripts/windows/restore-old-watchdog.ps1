[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [string]$InstallDir = "$env:USERPROFILE\.devspace",
    [string]$BackupPath = "",
    [switch]$DoNotStartLegacyWatchdog
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'watchdog-install-transaction.ps1')
. (Join-Path $PSScriptRoot 'stack-operation.ps1')

function Get-RestoreFileSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::Open([System.IO.Path]::GetFullPath($Path), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try { return [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace("-", "") }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Test-RestoreCommandToken([string]$CommandLine, [string]$Value) {
    if (-not $CommandLine -or -not $Value) { return $false }
    return [regex]::IsMatch($CommandLine, '(?i)(?:^|\s)"?' + [regex]::Escape($Value) + '"?(?=$|\s)')
}

function Test-RestoreTrayProcessRunning([string]$Directory) {
    $bootstrap = Join-Path $Directory "devspace-watchdog-bootstrap.ps1"
    if ([System.IO.File]::Exists($bootstrap)) {
        & $bootstrap -Mode CheckStopped -ConfigPath (Join-Path $Directory "devspace-watchdog.config.json")
        return $false
    }
    $trayPath = Join-Path $Directory "devspace-watchdog-tray.ps1"
    $configPath = Join-Path $Directory "devspace-watchdog.config.json"
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop)) {
        $command = [string]$process.CommandLine
        if (-not $command) { throw "Cannot verify PowerShell process $($process.ProcessId)." }
        if ((Test-RestoreCommandToken $command $trayPath) -and (Test-RestoreCommandToken $command $configPath)) { return $true }
    }
    return $false
}

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$recordPath = Join-Path $InstallDir "watchdog-tray-install.json"
if (-not $BackupPath) {
    if (-not [System.IO.File]::Exists($recordPath)) { throw "Tray install record is missing; pass -BackupPath explicitly." }
    $record = [System.IO.File]::ReadAllText($recordPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $BackupPath = [string]$record.backupPath
}
$BackupPath = [System.IO.Path]::GetFullPath($BackupPath)
$backupRoot = [System.IO.Path]::GetFullPath((Join-Path $InstallDir "configuration-backups"))
if (-not $BackupPath.StartsWith($backupRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Backup path is outside configuration-backups." }
$manifestPath = Join-Path $BackupPath "manifest.json"
if (-not [System.IO.File]::Exists($manifestPath)) { throw "Backup manifest is missing: $manifestPath" }
$manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
if ([System.IO.Path]::GetFullPath([string]$manifest.installDir) -ne $InstallDir) { throw "Backup targets another install directory." }
if ([string]$manifest.runName -notmatch '^DevSpaceWatchdogTray-[a-f0-9]{12}$') { throw "Backup manifest has an invalid Run value name." }
if ([string]$manifest.legacyTaskName -and [string]$manifest.legacyTaskName -notmatch '^[A-Za-z0-9 _.()-]{1,100}$') { throw "Backup manifest has an invalid task name." }
$retiredNames = @("run-devspace-watchdog-tray-ui-hidden.vbs", "devspace-watchdog-tray-launcher.exe", "devspace-watchdog-tray-launcher.cs")
$installedNames = @($manifest.installedFiles | ForEach-Object { [string]$_.name })
$retiredBackups = @($manifest.overwrittenFiles | Where-Object { [string]$_.name -in $retiredNames -and [string]$_.name -notin $installedNames })
foreach ($original in $retiredBackups) {
    $source = Join-Path (Join-Path $BackupPath "payload") ([string]$original.name)
    $target = Join-Path $InstallDir ([string]$original.name)
    if (-not [System.IO.File]::Exists($source) -or (Get-RestoreFileSha256 $source) -ne [string]$original.sha256) { throw "Retired file backup is missing or corrupt: $source" }
    if ([System.IO.File]::Exists($target) -and (Get-RestoreFileSha256 $target) -ne [string]$original.sha256) { throw "Retired file was replaced after installation; refusing to overwrite $target." }
}
foreach ($item in @($manifest.configBackups)) {
    $targetName = [System.IO.Path]::GetFileName([string]$item.targetName)
    $backupName = [System.IO.Path]::GetFileName([string]$item.backupName)
    if ($targetName -notin @("devspace-watchdog.config.json", "config.json") -or $backupName -ne "pre-install-$targetName") { throw "Backup manifest contains an unsupported configuration target." }
    $source = Join-Path (Join-Path $BackupPath "payload") $backupName
    if (-not [System.IO.File]::Exists($source) -or (Get-RestoreFileSha256 $source) -ne [string]$item.sha256) { throw "Configuration backup is missing or corrupt: $targetName" }
}
$taskName = [string]$manifest.legacyTaskName
$taskXmlPath = ""
if ($taskName -and [string]$manifest.legacyTaskXml) {
    $taskXmlName = [System.IO.Path]::GetFileName([string]$manifest.legacyTaskXml)
    if ($taskXmlName -ne [string]$manifest.legacyTaskXml -or $taskXmlName -ne "$taskName.xml") { throw "Backup manifest contains an unsupported legacy task XML name." }
    $taskXmlPath = Join-Path $BackupPath $taskXmlName
    if (-not [System.IO.File]::Exists($taskXmlPath) -or -not [string]$manifest.legacyTaskXmlSha256 -or (Get-RestoreFileSha256 $taskXmlPath) -ne [string]$manifest.legacyTaskXmlSha256) { throw "Legacy scheduled task XML is missing or corrupt." }
}

if ($PSCmdlet.ShouldProcess($InstallDir, "stop Tray, restore pre-Tray configuration, and re-enable the legacy watchdog")) {
    $restoreLease = Enter-StackOperation $InstallDir
    try {
    $bootstrap = Join-Path $InstallDir "devspace-watchdog-bootstrap.ps1"
    $launcher = Join-Path $InstallDir "run-devspace-watchdog-tray-hidden.vbs"
    if ([System.IO.File]::Exists($bootstrap)) {
        & $bootstrap -Mode Stop -ConfigPath (Join-Path $InstallDir "devspace-watchdog.config.json")
    } elseif ([System.IO.File]::Exists($launcher)) {
        $stopLauncher = Start-Process -FilePath "C:\Windows\System32\wscript.exe" -ArgumentList @("//B", "//NoLogo", "`"$launcher`"", "-Stop") -WindowStyle Hidden -Wait -PassThru
        if ($stopLauncher.ExitCode -ne 0) { throw "Watchdog stop launcher failed (exit $($stopLauncher.ExitCode))." }
    }
    $deadline = [DateTimeOffset]::Now.AddSeconds(10)
    do { $trayStillRunning = Test-RestoreTrayProcessRunning $InstallDir; if ($trayStillRunning) { Start-Sleep -Milliseconds 250 } } while ($trayStillRunning -and [DateTimeOffset]::Now -lt $deadline)
    if ($trayStillRunning) { throw "Tray did not stop within 10 seconds; refusing to restore configuration under a running process." }

    foreach ($original in $retiredBackups) {
        $source = Join-Path (Join-Path $BackupPath "payload") ([string]$original.name)
        $target = Join-Path $InstallDir ([string]$original.name)
        if (-not [System.IO.File]::Exists($source) -or (Get-RestoreFileSha256 $source) -ne [string]$original.sha256) { throw "Retired file backup is missing or corrupt: $source" }
        if ([System.IO.File]::Exists($target)) {
            if ((Get-RestoreFileSha256 $target) -ne [string]$original.sha256) { throw "Retired file was replaced after installation; refusing to overwrite $target." }
        } else { [System.IO.File]::Copy($source, $target, $false) }
    }

    $runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $runProperties = Get-ItemProperty -LiteralPath $runPath -Name ([string]$manifest.runName) -ErrorAction SilentlyContinue
    $currentRun = if ($runProperties -and $runProperties.PSObject.Properties[[string]$manifest.runName]) { [string]$runProperties.PSObject.Properties[[string]$manifest.runName].Value } else { $null }
    if ($currentRun -and $currentRun -ne [string]$manifest.runValue) { throw "Tray autostart changed after installation; refusing to overwrite it." }
    if ($null -ne $manifest.previousRunValue) { Set-ItemProperty -LiteralPath $runPath -Name ([string]$manifest.runName) -Value ([string]$manifest.previousRunValue) }
    else { Remove-ItemProperty -LiteralPath $runPath -Name ([string]$manifest.runName) -ErrorAction SilentlyContinue }

    $safetyPath = Join-Path $BackupPath ("pre-restore-current-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    [void][System.IO.Directory]::CreateDirectory($safetyPath)
    foreach ($item in @($manifest.configBackups)) {
        $targetName = [System.IO.Path]::GetFileName([string]$item.targetName)
        $backupName = [System.IO.Path]::GetFileName([string]$item.backupName)
        if ($targetName -notin @("devspace-watchdog.config.json", "config.json") -or $backupName -ne "pre-install-$targetName") { throw "Backup manifest contains an unsupported configuration target." }
        $source = Join-Path (Join-Path $BackupPath "payload") $backupName
        if (-not [System.IO.File]::Exists($source) -or (Get-RestoreFileSha256 $source) -ne [string]$item.sha256) { throw "Configuration backup is missing or corrupt: $targetName" }
        $target = Join-Path $InstallDir $targetName
        if ([System.IO.File]::Exists($target)) { [System.IO.File]::Copy($target, (Join-Path $safetyPath $targetName), $false) }
        [System.IO.File]::Copy($source, $target, $true)
    }

    $legacyPollerDisableMarker = Join-Path $InstallDir "legacy-watchdog-poller.disabled"
    Remove-Item -LiteralPath $legacyPollerDisableMarker -Force -ErrorAction SilentlyContinue

    if (@($manifest.legacyTasks).Count) {
        Restore-InstallLegacyTaskBackups $manifest $BackupPath $InstallDir -StartPreviouslyRunning:(-not $DoNotStartLegacyWatchdog)
    } elseif ($taskName -and [string]$manifest.legacyTaskXml) {
        $taskXml = [System.IO.File]::ReadAllText($taskXmlPath, [System.Text.Encoding]::UTF8)
        Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force | Out-Null
        if ([bool]$manifest.legacyTaskWasEnabled) { Enable-ScheduledTask -TaskName $taskName | Out-Null }
        if (-not $DoNotStartLegacyWatchdog -and [bool]$manifest.legacyTaskWasEnabled) { Start-ScheduledTask -TaskName $taskName }
    }
    if (-not $DoNotStartLegacyWatchdog -and @($manifest.legacyProcesses).Count) {
        Restart-InstallLegacyProcesses ([pscustomobject]@{installDir=$InstallDir;stoppedLegacyProcesses=@($manifest.legacyProcesses)})
    }

    if (-not $DoNotStartLegacyWatchdog -and [bool]$manifest.legacyTaskWasEnabled) {
        $config = [System.IO.File]::ReadAllText((Join-Path $InstallDir "devspace-watchdog.config.json"), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $ports = @()
        if ($config.devspaceEnabled -ne $false) { $ports += [int]$config.port }
        if ($config.hermesEnabled -and $config.hermesPort) { $ports += [int]$config.hermesPort }
        if ($config.routerPort) { $ports += [int]$config.routerPort }
        if ($config.manageNgrok -and $config.ngrokInspectorPort) { $ports += [int]$config.ngrokInspectorPort }
        $deadline = [DateTimeOffset]::Now.AddSeconds(30)
        do {
            $missing = @($ports | Where-Object { -not (Get-NetTCPConnection -LocalPort $_ -State Listen -ErrorAction SilentlyContinue) })
            if ($missing.Count -eq 0) { break }
            Start-Sleep -Seconds 1
        } while ([DateTimeOffset]::Now -lt $deadline)
        if ($missing.Count) { Write-Warning "Legacy watchdog was started, but these configured listener ports are not yet ready: $($missing -join ', ')" }
    }
    Write-Host "Pre-Tray configuration restored from $BackupPath"
    Write-Host "Tray autostart is disabled and the Tray process was stopped."
    Write-Host "Current files before restore: $safetyPath"
    } finally { Exit-StackOperation $restoreLease }
}
