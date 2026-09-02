[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [string]$InstallDir = "$env:USERPROFILE\.devspace",
    [switch]$KeepLegacyTaskDisabled
)

$ErrorActionPreference = "Stop"

function Get-TrayFileSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::Open([System.IO.Path]::GetFullPath($Path), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try { return [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace("-", "") }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Test-TrayCommandToken([string]$CommandLine, [string]$Value) {
    if (-not $CommandLine -or -not $Value) { return $false }
    return [regex]::IsMatch($CommandLine, '(?i)(?:^|\s)"?' + [regex]::Escape($Value) + '"?(?=$|\s)')
}

function Test-TrayProcessRunning([string]$Directory) {
    $trayPath = Join-Path $Directory "devspace-watchdog-tray.ps1"
    $configPath = Join-Path $Directory "devspace-watchdog.config.json"
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
        $command = [string]$process.CommandLine
        if ((Test-TrayCommandToken $command $trayPath) -and (Test-TrayCommandToken $command $configPath)) { return $true }
    }
    return $false
}

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$recordPath = Join-Path $InstallDir "watchdog-tray-install.json"
if (-not [System.IO.File]::Exists($recordPath)) { throw "Tray install record is missing: $recordPath" }
$record = [System.IO.File]::ReadAllText($recordPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
if ([System.IO.Path]::GetFullPath([string]$record.installDir) -ne $InstallDir) { throw "Tray install record targets another directory." }
if ([string]$record.runName -notmatch '^DevSpaceWatchdogTray-[a-f0-9]{12}$') { throw "Tray install record has an invalid Run value name." }
$allowedFiles = @("watchdog-control-core.ps1","devspace-watchdog-tray.ps1","devspace-control-center.html","devspace-watchdog-tray-launcher.exe","run-devspace-watchdog-tray-hidden.vbs","uninstall-devspace-watchdog-tray.ps1","restore-old-watchdog.ps1")
foreach ($item in @($record.installedFiles) + @($record.overwrittenFiles)) {
    if ([string]$item.name -notin $allowedFiles -or [System.IO.Path]::GetFileName([string]$item.name) -ne [string]$item.name) { throw "Tray install record contains an unsupported file target." }
}
$backupPath = [System.IO.Path]::GetFullPath([string]$record.backupPath)
$backupRoot = [System.IO.Path]::GetFullPath((Join-Path $InstallDir "configuration-backups"))
if (-not $backupPath.StartsWith($backupRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Tray backup path is outside configuration-backups." }
foreach ($item in @($record.overwrittenFiles)) {
    $source = Join-Path (Join-Path $backupPath "payload") ([string]$item.name)
    if (-not [System.IO.File]::Exists($source) -or (Get-TrayFileSha256 $source) -ne [string]$item.sha256) { throw "Original tray file backup is missing or corrupt: $($item.name)" }
}

if ($PSCmdlet.ShouldProcess($InstallDir, "uninstall DevSpace Watchdog Tray without stopping managed services")) {
    $launcher = Join-Path $InstallDir "run-devspace-watchdog-tray-hidden.vbs"
    if ([System.IO.File]::Exists($launcher)) {
        Start-Process -FilePath "C:\Windows\System32\wscript.exe" -ArgumentList @("//B", "//NoLogo", "`"$launcher`"", "-Stop") -WindowStyle Hidden | Out-Null
    }
    $deadline = [DateTimeOffset]::Now.AddSeconds(10)
    do { $trayStillRunning = Test-TrayProcessRunning $InstallDir; if ($trayStillRunning) { Start-Sleep -Milliseconds 250 } } while ($trayStillRunning -and [DateTimeOffset]::Now -lt $deadline)
    if ($trayStillRunning) { throw "Tray did not stop within 10 seconds; refusing to remove files from a running process." }

    $runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $runProperties = Get-ItemProperty -LiteralPath $runPath -Name ([string]$record.runName) -ErrorAction SilentlyContinue
    $currentRun = if ($runProperties -and $runProperties.PSObject.Properties[[string]$record.runName]) { [string]$runProperties.PSObject.Properties[[string]$record.runName].Value } else { $null }
    if ($currentRun -and $currentRun -ne [string]$record.runValue) { throw "Autostart value changed after installation; refusing to overwrite it." }
    if ($null -ne $record.previousRunValue) { Set-ItemProperty -LiteralPath $runPath -Name ([string]$record.runName) -Value ([string]$record.previousRunValue) }
    else { Remove-ItemProperty -LiteralPath $runPath -Name ([string]$record.runName) -ErrorAction SilentlyContinue }

    $overwrittenNames = @($record.overwrittenFiles | ForEach-Object { [string]$_.name })
    $filesRemaining = @()
    foreach ($installed in @($record.installedFiles)) {
        $name = [string]$installed.name
        $target = Join-Path $InstallDir $name
        if (-not [System.IO.File]::Exists($target)) { continue }
        $currentHash = Get-TrayFileSha256 $target
        if ($currentHash -ne [string]$installed.sha256) { Write-Warning "Leaving modified tray file in place: $target"; $filesRemaining += $name; continue }
        if ($name -in $overwrittenNames) {
            $source = Join-Path (Join-Path $backupPath "payload") $name
            [System.IO.File]::Copy($source, $target, $true)
        } else {
            [System.IO.File]::Delete($target)
        }
    }

    if (-not $KeepLegacyTaskDisabled -and [bool]$record.legacyTaskWasEnabled -and [string]$record.legacyTaskName) {
        Remove-Item -LiteralPath (Join-Path $InstallDir "legacy-watchdog-poller.disabled") -Force -ErrorAction SilentlyContinue
        $task = Get-ScheduledTask -TaskName ([string]$record.legacyTaskName) -ErrorAction SilentlyContinue
        if ($task) { Enable-ScheduledTask -TaskName ([string]$record.legacyTaskName) | Out-Null }
    }
    if ($filesRemaining.Count -eq 0 -and [System.IO.File]::Exists($recordPath)) { [System.IO.File]::Delete($recordPath) }
    elseif ($filesRemaining.Count) { Write-Warning "Install record retained because modified files remain: $($filesRemaining -join ', ')" }
    Write-Host "DevSpace Watchdog Tray uninstalled."
    Write-Host "DevSpace, Hermes, Router, and ngrok were not stopped."
}
