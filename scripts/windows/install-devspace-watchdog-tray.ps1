[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [string]$InstallDir = "$env:USERPROFILE\.devspace",
    [string]$LegacyTaskName = "",
    [int]$StartupTimeoutSeconds = 30,
    [switch]$SkipStart
)

$ErrorActionPreference = "Stop"
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$configPath = Join-Path $InstallDir "devspace-watchdog.config.json"
$recordPath = Join-Path $InstallDir "watchdog-tray-install.json"
$powerShellPath = [System.IO.Path]::GetFullPath("$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe")
$files = @(
    "watchdog-control-core.ps1",
    "devspace-watchdog-tray.ps1",
    "devspace-control-center.html",
    "devspace-watchdog-tray-launcher.exe",
    "run-devspace-watchdog-tray-hidden.vbs",
    "uninstall-devspace-watchdog-tray.ps1",
    "restore-old-watchdog.ps1"
)

function Write-InstallerJson([string]$Path, $Value) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine), $encoding)
}

function Get-InstallerStableHash([string]$Value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "").Substring(0, 12).ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Assert-PowerShellSyntax([string]$Path) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "PowerShell syntax validation failed for $Path`: $($errors[0].Message)" }
}

function Get-LegacyTaskName {
    if ($LegacyTaskName) { return $LegacyTaskName }
    foreach ($name in @("DevSpaceNgrokWatchdogUserPoller", "DevSpaceNgrokWatchdogPoller", "DevSpaceNgrokWatchdog")) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { return $name }
    }
    return ""
}

function Test-InstalledTrayProcess {
    $trayPath = Join-Path $InstallDir "devspace-watchdog-tray.ps1"
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
        $command = [string]$process.CommandLine
        if ((Test-WatchdogExecutablePath $process $powerShellPath) -and
            (Test-WatchdogCommandToken $command $trayPath) -and
            (Test-WatchdogCommandToken $command $configPath)) { return $true }
    }
    return $false
}

function Test-InstallerDashboardStatus([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    $stream = $null
    $reader = $null
    try {
        $connect = $client.ConnectAsync("127.0.0.1", $Port)
        if (-not $connect.Wait(1000) -or -not $client.Connected) { return $false }
        $client.ReceiveTimeout = 1500
        $client.SendTimeout = 1500
        $stream = $client.GetStream()
        $request = [System.Text.Encoding]::ASCII.GetBytes("GET /api/status HTTP/1.1`r`nHost: 127.0.0.1:$Port`r`nConnection: close`r`n`r`n")
        $stream.Write($request, 0, $request.Length)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $false, 1024, $true)
        $response = $reader.ReadToEnd()
        if ($response -notmatch '^HTTP/1\.1 200 OK\r?\n') { return $false }
        $separator = $response.IndexOf("`r`n`r`n")
        if ($separator -lt 0) { return $false }
        $payload = $response.Substring($separator + 4) | ConvertFrom-Json
        return [bool]$payload.overall -and [bool]$payload.services
    } catch { return $false }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
        $client.Dispose()
    }
}

if (-not [System.IO.File]::Exists($configPath)) { throw "Missing watchdog configuration: $configPath" }
if ($StartupTimeoutSeconds -lt 10 -or $StartupTimeoutSeconds -gt 60) { throw "StartupTimeoutSeconds must be from 10 through 60." }
if ($SkipStart) { throw "Tray migration cannot use -SkipStart because the legacy watchdog may be disabled only after live Tray readiness is proven." }
if ($LegacyTaskName -and $LegacyTaskName -notmatch '^[A-Za-z0-9 _.()-]{1,100}$') { throw "LegacyTaskName contains unsupported characters." }
foreach ($name in $files) {
    $source = Join-Path $PSScriptRoot $name
    if (-not [System.IO.File]::Exists($source)) { throw "Missing tray installer source: $source" }
    if ([System.IO.Path]::GetExtension($source) -eq ".ps1") { Assert-PowerShellSyntax $source }
}
. (Join-Path $PSScriptRoot "watchdog-control-core.ps1")
$config = Read-WatchdogJson $configPath
$settings = Get-WatchdogControlSettings $config
$stateDir = [System.IO.Path]::GetFullPath([string]$config.stateDir)
if (-not $stateDir.Equals($InstallDir, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Tray migration requires watchdog stateDir to match InstallDir." }
if ([System.Net.IPAddress]::Loopback.ToString() -ne "127.0.0.1") { throw "Loopback validation failed." }
$dashboardOwners = @(Get-NetTCPConnection -LocalPort $settings.dashboardPort -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
$existingTrayWasRunning = $false
if ($dashboardOwners.Count) {
    $heartbeatPath = Join-Path $InstallDir "watchdog-tray-heartbeat.json"
    if ([System.IO.File]::Exists($heartbeatPath)) {
        try {
            $existingHeartbeat = [System.IO.File]::ReadAllText($heartbeatPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $existingPid = [int]$existingHeartbeat.pid
            $existingProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$existingPid" -ErrorAction SilentlyContinue
            $expectedTrayPath = Join-Path $InstallDir "devspace-watchdog-tray.ps1"
            $existingTrayWasRunning = $existingPid -in $dashboardOwners -and $existingProcess -and
                (Test-WatchdogExecutablePath $existingProcess $powerShellPath) -and
                (Test-WatchdogCommandToken ([string]$existingProcess.CommandLine) $expectedTrayPath) -and
                (Test-WatchdogCommandToken ([string]$existingProcess.CommandLine) $configPath)
        } catch { $existingTrayWasRunning = $false }
    }
    if (-not $existingTrayWasRunning) { throw "Dashboard port $($settings.dashboardPort) is owned by an unrecognized process; installation is blocked." }
}

$legacyName = Get-LegacyTaskName
$legacyTask = if ($legacyName) { Get-ScheduledTask -TaskName $legacyName -ErrorAction SilentlyContinue } else { $null }
$legacyWasEnabled = if ($legacyTask) { [bool]$legacyTask.Settings.Enabled } else { $false }
$runName = "DevSpaceWatchdogTray-" + (Get-InstallerStableHash $InstallDir)
$runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$existingRun = (Get-ItemProperty -LiteralPath $runPath -Name $runName -ErrorAction SilentlyContinue).$runName
$runValue = '"C:\Windows\System32\wscript.exe" //B //NoLogo "' + (Join-Path $InstallDir "run-devspace-watchdog-tray-hidden.vbs") + '"'
$backupRoot = Join-Path $InstallDir "configuration-backups"
$backupPath = Join-Path $backupRoot ("tray-install-" + (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
$payloadPath = Join-Path $backupPath "payload"
$createdTargets = @()
$overwritten = @()
$installed = @()
$configBackups = @()
$runChanged = $false
$taskDisabled = $false
$taskQuiesced = $false

try {
    if (-not $PSCmdlet.ShouldProcess($InstallDir, "install and start DevSpace Watchdog Tray")) { return }
    [void][System.IO.Directory]::CreateDirectory($payloadPath)
    foreach ($name in $files) {
        $target = Join-Path $InstallDir $name
        if ([System.IO.File]::Exists($target)) {
            $backupFile = Join-Path $payloadPath $name
            [System.IO.File]::Copy($target, $backupFile, $false)
            $overwritten += [pscustomobject]@{ name=$name; sha256=(Get-WatchdogFileSha256 $backupFile) }
        } else { $createdTargets += $name }
    }
    foreach ($name in @("devspace-watchdog.config.json", "config.json")) {
        $source = Join-Path $InstallDir $name
        if ([System.IO.File]::Exists($source)) {
            $backupName = "pre-install-" + $name
            $destination = Join-Path $payloadPath $backupName
            [System.IO.File]::Copy($source, $destination, $false)
            $configBackups += [pscustomobject]@{ targetName=$name; backupName=$backupName; sha256=(Get-WatchdogFileSha256 $destination) }
        }
    }
    $taskXmlName = ""
    $taskXmlSha256 = ""
    if ($legacyTask) {
        $taskXmlName = "$legacyName.xml"
        $taskXml = Export-ScheduledTask -TaskName $legacyName
        $taskXmlPath = Join-Path $backupPath $taskXmlName
        [System.IO.File]::WriteAllText($taskXmlPath, $taskXml, (New-Object System.Text.UTF8Encoding($false)))
        $taskXmlSha256 = Get-WatchdogFileSha256 $taskXmlPath
    }

    if ($existingTrayWasRunning) {
        $existingLauncher = Join-Path $InstallDir "run-devspace-watchdog-tray-hidden.vbs"
        Start-Process -FilePath "C:\Windows\System32\wscript.exe" -ArgumentList @("//B", "//NoLogo", "`"$existingLauncher`"", "-Stop") -WindowStyle Hidden | Out-Null
        $deadline = [DateTimeOffset]::Now.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 250
            $remainingOwners = @(Get-NetTCPConnection -LocalPort $settings.dashboardPort -State Listen -ErrorAction SilentlyContinue)
            $trayStillRunning = Test-InstalledTrayProcess
        } while (($remainingOwners.Count -or $trayStillRunning) -and [DateTimeOffset]::Now -lt $deadline)
        if ($remainingOwners.Count -or $trayStillRunning) { throw "Existing Tray did not stop and release dashboard port $($settings.dashboardPort)." }
    }

    foreach ($name in $files) {
        $source = Join-Path $PSScriptRoot $name
        $target = Join-Path $InstallDir $name
        [System.IO.File]::Copy($source, $target, $true)
        $installed += [pscustomobject]@{ name=$name; sha256=(Get-WatchdogFileSha256 $target) }
    }
    Set-ItemProperty -LiteralPath $runPath -Name $runName -Value $runValue
    $runChanged = $true

    $manifest = [pscustomobject][ordered]@{
        schemaVersion=1; timestamp=[DateTimeOffset]::Now.ToString("o"); installDir=$InstallDir; backupPath=$backupPath
        runName=$runName; runValue=$runValue; previousRunValue=$existingRun; legacyTaskName=$legacyName
        legacyTaskWasEnabled=$legacyWasEnabled; legacyTaskXml=$taskXmlName; legacyTaskXmlSha256=$taskXmlSha256; createdTargets=$createdTargets
        overwrittenFiles=$overwritten; installedFiles=$installed; configBackups=$configBackups; dashboardPort=$settings.dashboardPort
    }
    Write-InstallerJson (Join-Path $backupPath "manifest.json") $manifest

    if (-not $SkipStart) {
        $launcher = Join-Path $InstallDir "run-devspace-watchdog-tray-hidden.vbs"
        Start-Process -FilePath "C:\Windows\System32\wscript.exe" -ArgumentList @("//B", "//NoLogo", "`"$launcher`"") -WindowStyle Hidden | Out-Null
        $deadline = [DateTimeOffset]::Now.AddSeconds($StartupTimeoutSeconds)
        $heartbeatPath = Join-Path $InstallDir "watchdog-tray-heartbeat.json"
        $ready = $false
        while ([DateTimeOffset]::Now -lt $deadline) {
            Start-Sleep -Milliseconds 500
            if (-not [System.IO.File]::Exists($heartbeatPath)) { continue }
            try {
                $heartbeat = [System.IO.File]::ReadAllText($heartbeatPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                $fresh = ([DateTimeOffset]::Now - [DateTimeOffset]::Parse([string]$heartbeat.timestamp)).TotalSeconds -le 10
                $heartbeatPid = [int]$heartbeat.pid
                $process = Get-CimInstance Win32_Process -Filter "ProcessId=$heartbeatPid" -ErrorAction SilentlyContinue
                $expectedTrayPath = Join-Path $InstallDir "devspace-watchdog-tray.ps1"
                $processReady = $process -and (Test-WatchdogExecutablePath $process $powerShellPath) -and
                    (Test-WatchdogCommandToken ([string]$process.CommandLine) $expectedTrayPath) -and
                    (Test-WatchdogCommandToken ([string]$process.CommandLine) $configPath)
                $dashboardReady = Test-InstallerDashboardStatus ([int]$settings.dashboardPort)
                $state = [System.IO.File]::ReadAllText((Join-Path $InstallDir "watchdog-tray-state.json"), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                $managementReady = @("devspace", "hermes", "router", "ngrok" | Where-Object { [string](Get-WatchdogProperty $state.desired $_ "") -notin @("running", "stopped_by_user") }).Count -eq 0
                if ($fresh -and $processReady -and $dashboardReady -and $managementReady) { $ready = $true; break }
            } catch { }
        }
        if (-not $ready) { throw "Tray did not produce a fresh heartbeat, loopback dashboard, and service-management state within $StartupTimeoutSeconds seconds." }
        if ($legacyTask) {
            try {
                Disable-ScheduledTask -TaskName $legacyName -ErrorAction Stop | Out-Null
                $taskDisabled = $true
            } catch {
                $marker = Join-Path $InstallDir "legacy-watchdog-poller.disabled"
                [System.IO.File]::WriteAllText($marker, "Tray healthy; legacy task ACL prevented disable at $([DateTimeOffset]::UtcNow.ToString('o'))" + [Environment]::NewLine, [System.Text.Encoding]::ASCII)
                $taskQuiesced = $true
                Write-Warning "Legacy task '$legacyName' could not be disabled with current-user permissions. It has been logically quiesced by $marker."
            }
        }
    }

    Write-InstallerJson $recordPath $manifest
    Write-Host "DevSpace Watchdog Tray installed."
    Write-Host "Autostart: $runName"
    Write-Host "Dashboard: http://127.0.0.1:$($settings.dashboardPort)/"
    Write-Host "Recovery backup: $backupPath"
    if ($legacyTask) { Write-Host "Legacy watchdog task: $(if ($taskDisabled) { 'disabled after tray readiness' } elseif ($taskQuiesced) { 'logically quiesced; ACL prevents disable' } else { 'unchanged' }) ($legacyName)" }
} catch {
    $failure = $_
    if ($legacyWasEnabled -and $legacyName) { Enable-ScheduledTask -TaskName $legacyName -ErrorAction SilentlyContinue | Out-Null }
    if ($runChanged) {
        if ($null -ne $existingRun) { Set-ItemProperty -LiteralPath $runPath -Name $runName -Value $existingRun -ErrorAction SilentlyContinue }
        else { Remove-ItemProperty -LiteralPath $runPath -Name $runName -ErrorAction SilentlyContinue }
    }
    $launcher = Join-Path $InstallDir "run-devspace-watchdog-tray-hidden.vbs"
    if ([System.IO.File]::Exists($launcher)) { Start-Process -FilePath "C:\Windows\System32\wscript.exe" -ArgumentList @("//B", "//NoLogo", "`"$launcher`"", "-Stop") -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null }
    $stopDeadline = [DateTimeOffset]::Now.AddSeconds(10)
    do { Start-Sleep -Milliseconds 250; $trayStillRunning = Test-InstalledTrayProcess } while ($trayStillRunning -and [DateTimeOffset]::Now -lt $stopDeadline)
    if (-not $trayStillRunning) {
        foreach ($item in $overwritten) {
            $source = Join-Path $payloadPath $item.name; $target = Join-Path $InstallDir $item.name
            if ([System.IO.File]::Exists($source)) { [System.IO.File]::Copy($source, $target, $true) }
        }
        foreach ($name in $createdTargets) {
            $target = Join-Path $InstallDir $name
            if ([System.IO.File]::Exists($target)) { [System.IO.File]::Delete($target) }
        }
        if ($existingTrayWasRunning) {
            $restoredLauncher = Join-Path $InstallDir "run-devspace-watchdog-tray-hidden.vbs"
            if ([System.IO.File]::Exists($restoredLauncher)) { Start-Process -FilePath "C:\Windows\System32\wscript.exe" -ArgumentList @("//B", "//NoLogo", "`"$restoredLauncher`"") -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null }
        }
        throw "DevSpace Watchdog Tray install failed and installation changes were rolled back. Legacy services were not stopped. Recovery backup: $backupPath. $($failure.Exception.Message)"
    }
    throw "DevSpace Watchdog Tray install failed, and the Tray did not stop within 10 seconds. Autostart and the legacy task were restored, but installed files were left intact to avoid modifying a running process. Recovery backup: $backupPath. $($failure.Exception.Message)"
}
