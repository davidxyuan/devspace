[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [string]$InstallDir = "$env:USERPROFILE\.devspace",
    [string]$BackupPath = "",
    [switch]$DoNotStartLegacyWatchdog
)

$ErrorActionPreference = "Stop"

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
    $trayPath = Join-Path $Directory "devspace-watchdog-tray.ps1"
    $configPath = Join-Path $Directory "devspace-watchdog.config.json"
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
        $command = [string]$process.CommandLine
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
    $launcher = Join-Path $InstallDir "run-devspace-watchdog-tray-hidden.vbs"
    if ([System.IO.File]::Exists($launcher)) {
        Start-Process -FilePath "C:\Windows\System32\wscript.exe" -ArgumentList @("//B", "//NoLogo", "`"$launcher`"", "-Stop") -WindowStyle Hidden | Out-Null
    }
    $deadline = [DateTimeOffset]::Now.AddSeconds(10)
    do { $trayStillRunning = Test-RestoreTrayProcessRunning $InstallDir; if ($trayStillRunning) { Start-Sleep -Milliseconds 250 } } while ($trayStillRunning -and [DateTimeOffset]::Now -lt $deadline)
    if ($trayStillRunning) { throw "Tray did not stop within 10 seconds; refusing to restore configuration under a running process." }

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

    if ($taskName -and [string]$manifest.legacyTaskXml) {
        $taskXml = [System.IO.File]::ReadAllText($taskXmlPath, [System.Text.Encoding]::UTF8)
        Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force | Out-Null
        if ([bool]$manifest.legacyTaskWasEnabled) { Enable-ScheduledTask -TaskName $taskName | Out-Null }
        if (-not $DoNotStartLegacyWatchdog -and [bool]$manifest.legacyTaskWasEnabled) { Start-ScheduledTask -TaskName $taskName }
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
}
