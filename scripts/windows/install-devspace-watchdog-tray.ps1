[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [string]$InstallDir = "$env:USERPROFILE\.devspace",
    [string]$LegacyTaskName = "",
    [string]$OriginalTransactionPath = "",
    [int]$StartupTimeoutSeconds = 30,
    [switch]$SkipStart
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'watchdog-install-transaction.ps1')
. (Join-Path $PSScriptRoot 'stack-operation.ps1')
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$configPath = Join-Path $InstallDir "devspace-watchdog.config.json"
$recordPath = Join-Path $InstallDir "watchdog-tray-install.json"
$files = @(
    "watchdog-control-core.ps1",
    "stack-operation.ps1",
    "stack-host-management.ps1",
    "watchdog-install-transaction.ps1",
    "devspace-watchdog-tray.ps1",
    "devspace-watchdog-tray-ui.ps1",
    "devspace-watchdog-bootstrap.ps1",
    "devspace-control-center.html",
    "run-devspace-watchdog-tray-hidden.vbs",
    "uninstall-devspace-watchdog-tray.ps1",
    "restore-old-watchdog.ps1"
)
$retiredFiles = @(
    "run-devspace-watchdog-tray-ui-hidden.vbs",
    "devspace-watchdog-tray-launcher.exe",
    "devspace-watchdog-tray-launcher.cs"
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

function Invoke-InstalledWatchdogBootstrap([ValidateSet("Run", "Stop", "CheckStopped")][string]$Mode) {
    # Stop/proof must use this installer's lifecycle checks, including when the
    # previous installation has no bootstrap or an older unsafe implementation.
    $bootstrapRoot = if ($Mode -eq "Run") { $InstallDir } else { $PSScriptRoot }
    $bootstrap = Join-Path $bootstrapRoot "devspace-watchdog-bootstrap.ps1"
    if (-not [System.IO.File]::Exists($bootstrap)) { return $false }
    # Run bootstrap in the current PowerShell process. This avoids an extra hidden
    # PowerShell child, ExecutionPolicy Bypass on the command line, and timeout-based
    # child termination -- all of which are noisy for endpoint behavior monitoring.
    if ($Mode -eq "Run") { & $bootstrap -Mode $Mode -ConfigPath $configPath }
    else { & $bootstrap -Mode $Mode -ConfigPath $configPath -RuntimeDirectory $InstallDir }
    return $true
}

function Invoke-InstalledWatchdogStop { return Invoke-InstalledWatchdogBootstrap "Stop" }
function Invoke-InstalledWatchdogRun { return Invoke-InstalledWatchdogBootstrap "Run" }

function Copy-InstallerFileWithRetry([string]$Source, [string]$Destination, [bool]$Overwrite) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    $lastError = $null
    do {
        try {
            [System.IO.File]::Copy($Source, $Destination, $Overwrite)
            return
        } catch [System.IO.IOException] {
            $lastError = $_.Exception.Message
        } catch [System.UnauthorizedAccessException] {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Could not copy '$Source' to '$Destination' after retrying transient file locks: $lastError"
}

function Read-InstallerHeartbeat([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    try {
        $value = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $heartbeatPid = 0
        if (-not [int]::TryParse([string]$value.pid, [ref]$heartbeatPid) -or $heartbeatPid -le 0) { return $null }
        $timestamp = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$value.timestamp, [ref]$timestamp)) { return $null }
        $sessionId = -1
        [void][int]::TryParse([string]$value.sessionId, [ref]$sessionId)
        return [pscustomobject]@{
            pid = $heartbeatPid
            timestamp = $timestamp
            role = [string]$value.role
            dashboard = [string]$value.dashboard
            sessionId = $sessionId
        }
    } catch { return $null }
}

function Test-InstallerHeartbeatFresh($Heartbeat, [string]$ExpectedRole = "") {
    if (-not $Heartbeat) { return $false }
    $age = ([DateTimeOffset]::UtcNow - $Heartbeat.timestamp.ToUniversalTime()).TotalSeconds
    if ($age -lt -5 -or $age -gt 15) { return $false }
    if ($ExpectedRole -and [string]$Heartbeat.role -ne $ExpectedRole) { return $false }
    return [bool](Get-Process -Id ([int]$Heartbeat.pid) -ErrorAction SilentlyContinue)
}

function Get-LegacyTaskName {
    if ($LegacyTaskName) { return $LegacyTaskName }
    foreach ($name in @("DevSpaceNgrokWatchdogUserPoller", "DevSpaceNgrokWatchdogPoller", "DevSpaceNgrokWatchdog")) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { return $name }
    }
    return ""
}

function Test-InstalledTrayProcess {
    $heartbeat = Read-InstallerHeartbeat (Join-Path $InstallDir "watchdog-tray-heartbeat.json")
    return Test-InstallerHeartbeatFresh $heartbeat "tray-ui"
}

function Test-InstalledHostProcess {
    $heartbeat = Read-InstallerHeartbeat (Join-Path $InstallDir "watchdog-host-heartbeat.json")
    return Test-InstallerHeartbeatFresh $heartbeat "host"
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
$activeConsoleSession = Get-WatchdogActiveConsoleSessionId
$stateDir = [System.IO.Path]::GetFullPath([string]$config.stateDir)
if (-not $stateDir.Equals($InstallDir, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Tray migration requires watchdog stateDir to match InstallDir." }
if ([System.Net.IPAddress]::Loopback.ToString() -ne "127.0.0.1") { throw "Loopback validation failed." }
$dashboardOwners = @(Get-NetTCPConnection -LocalPort $settings.dashboardPort -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
$existingTrayWasRunning = $false
if ($dashboardOwners.Count) {
    $expectedDashboardUrl = "http://127.0.0.1:$($settings.dashboardPort)/"
    $hostHeartbeat = Read-InstallerHeartbeat (Join-Path $InstallDir "watchdog-host-heartbeat.json")
    if ((Test-InstallerHeartbeatFresh $hostHeartbeat "host") -and
        [int]$hostHeartbeat.pid -in $dashboardOwners -and
        [string]$hostHeartbeat.dashboard -eq $expectedDashboardUrl) {
        $existingTrayWasRunning = $true
    }
    if (-not $existingTrayWasRunning) {
        $legacyHeartbeat = Read-InstallerHeartbeat (Join-Path $InstallDir "watchdog-tray-heartbeat.json")
        if ((Test-InstallerHeartbeatFresh $legacyHeartbeat) -and
            [int]$legacyHeartbeat.pid -in $dashboardOwners -and
            [string]$legacyHeartbeat.dashboard -eq $expectedDashboardUrl -and
            [string]$legacyHeartbeat.role -ne "tray-ui") {
            $existingTrayWasRunning = $true
        }
    }
    if (-not $existingTrayWasRunning) { throw "Dashboard port $($settings.dashboardPort) is owned by an unrecognized process; installation is blocked." }
}

$legacySnapshots = @(Get-InstallTaskSnapshots $InstallDir)
$legacyProcessTransaction = [pscustomobject]@{installDir=$InstallDir;legacyProcesses=@(Get-InstallLegacyProcessSnapshots $InstallDir);stoppedLegacyProcesses=@()}
$originalTransaction = $null
if ($OriginalTransactionPath) {
    $originalTransaction = Get-Content -LiteralPath $OriginalTransactionPath -Raw | ConvertFrom-Json
    if ([IO.Path]::GetFullPath([string]$originalTransaction.installDir) -ne $InstallDir) { throw 'Original installation backup belongs to another directory.' }
    $legacySnapshots = @($originalTransaction.tasks)
}
$legacyName = if ($LegacyTaskName) { $LegacyTaskName } elseif ($legacySnapshots.Count) { [string]$legacySnapshots[0].name } else { '' }
$legacyTask = if ($legacyName) { Get-ScheduledTask -TaskName $legacyName -ErrorAction SilentlyContinue } else { $null }
$legacyWasEnabled = if ($legacySnapshots.Count) { [bool]$legacySnapshots[0].enabled } else { $false }
$runName = "DevSpaceWatchdogTray-" + (Get-InstallerStableHash $InstallDir)
$runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$existingRun = (Get-ItemProperty -LiteralPath $runPath -Name $runName -ErrorAction SilentlyContinue).$runName
$runValue = '"' + (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') + '" -NoProfile -NonInteractive -WindowStyle Hidden -File "' + (Join-Path $InstallDir 'devspace-watchdog-bootstrap.ps1') + '" -Mode Run'
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
$trayInstallLease = $null

try {
    if (-not $PSCmdlet.ShouldProcess($InstallDir, "install and start DevSpace Watchdog Tray")) { return }
    $trayInstallLease = Enter-StackOperation -InstallDir $InstallDir
    [void][System.IO.Directory]::CreateDirectory($payloadPath)
    foreach ($name in @($files) + @($retiredFiles)) {
        $target = Join-Path $InstallDir $name
        if ([System.IO.File]::Exists($target)) {
            $backupFile = Join-Path $payloadPath $name
            Copy-InstallerFileWithRetry $target $backupFile $false
            $overwritten += [pscustomobject]@{ name=$name; sha256=(Get-WatchdogFileSha256 $backupFile) }
        } elseif ($name -in $files) { $createdTargets += $name }
    }
    foreach ($name in @("devspace-watchdog.config.json", "config.json")) {
        $source = Join-Path $InstallDir $name
        if ($originalTransaction) {
            $original = @($originalTransaction.files | Where-Object { [IO.Path]::GetFullPath([string]$_.target) -eq $source })
            if ($original.Count -ne 1) { throw "Original configuration snapshot is missing: $name" }
            if (-not $original[0].existed) { continue }
            $source = [string]$original[0].backup
            if (-not [IO.File]::Exists($source) -or (Get-WatchdogFileSha256 $source) -ne [string]$original[0].sha256) { throw "Original configuration snapshot is corrupt: $name" }
        }
        if ([System.IO.File]::Exists($source)) {
            $backupName = "pre-install-" + $name
            $destination = Join-Path $payloadPath $backupName
            Copy-InstallerFileWithRetry $source $destination $false
            $configBackups += [pscustomobject]@{ targetName=$name; backupName=$backupName; sha256=(Get-WatchdogFileSha256 $destination) }
        }
    }
    $taskXmlName = ""
    $taskXmlSha256 = ""
    $legacyTaskBackups = @()
    foreach ($snapshot in $legacySnapshots) {
        $xmlName = "$($snapshot.name).xml"
        $xmlPath = Join-Path $backupPath $xmlName
        [IO.File]::WriteAllText($xmlPath, [string]$snapshot.xml, [Text.UTF8Encoding]::new($false))
        $xmlHash = Get-WatchdogFileSha256 $xmlPath
        $legacyTaskBackups += [pscustomobject]@{ name=$snapshot.name; path=$snapshot.path; enabled=$snapshot.enabled; running=$snapshot.running; xml=$xmlName; sha256=$xmlHash }
        if ($snapshot.name -eq $legacyName) { $taskXmlName=$xmlName; $taskXmlSha256=$xmlHash }
    }

    foreach ($snapshot in $legacySnapshots) {
        $currentTask = Get-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop
        if (-not (Test-InstallTaskIdentity $currentTask $InstallDir)) { throw "Legacy task changed identity: $($snapshot.name)" }
        Disable-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop | Out-Null
        $taskDisabled = $true
        if ([string]$currentTask.State -eq 'Running') { Stop-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop }
    }
    Stop-InstallLegacyProcesses $legacyProcessTransaction
    try { [void](Invoke-InstalledWatchdogBootstrap "CheckStopped") }
    catch { $existingTrayWasRunning = $true }
    if (-not (Invoke-InstalledWatchdogStop)) { throw "Watchdog lifecycle stop is unavailable; refusing deployment." }
    if (-not (Invoke-InstalledWatchdogBootstrap "CheckStopped")) { throw "Watchdog exit proof is unavailable; refusing deployment." }

    foreach ($name in $files) {
        $source = Join-Path $PSScriptRoot $name
        $target = Join-Path $InstallDir $name
        Copy-InstallerFileWithRetry $source $target $true
        $installed += [pscustomobject]@{ name=$name; sha256=(Get-WatchdogFileSha256 $target) }
    }
    Set-ItemProperty -LiteralPath $runPath -Name $runName -Value $runValue
    $runChanged = $true

    $manifest = [pscustomobject][ordered]@{
        schemaVersion=1; timestamp=[DateTimeOffset]::Now.ToString("o"); installDir=$InstallDir; backupPath=$backupPath
        runName=$runName; runValue=$runValue; previousRunValue=$existingRun; legacyTaskName=$legacyName
        legacyTaskWasEnabled=$legacyWasEnabled; legacyTaskXml=$taskXmlName; legacyTaskXmlSha256=$taskXmlSha256; createdTargets=$createdTargets
        overwrittenFiles=$overwritten; installedFiles=$installed; configBackups=$configBackups; retiredFiles=$retiredFiles; dashboardPort=$settings.dashboardPort
        originalTransactionPath=$OriginalTransactionPath; legacyTasks=$legacyTaskBackups
        legacyProcesses=$(if ($originalTransaction) { @($originalTransaction.legacyProcesses) } else { @($legacyProcessTransaction.stoppedLegacyProcesses) })
    }
    Write-InstallerJson (Join-Path $backupPath "manifest.json") $manifest

    if (-not $SkipStart) {
        if (-not (Invoke-InstalledWatchdogRun)) { throw "Installed Watchdog bootstrap Run is missing after deployment." }
        $deadline = [DateTimeOffset]::Now.AddSeconds($StartupTimeoutSeconds)
        $trayHeartbeatPath = Join-Path $InstallDir "watchdog-tray-heartbeat.json"
        $hostHeartbeatPath = Join-Path $InstallDir "watchdog-host-heartbeat.json"
        $ready = $false
        while ([DateTimeOffset]::Now -lt $deadline) {
            Start-Sleep -Milliseconds 500
            if (-not [System.IO.File]::Exists($trayHeartbeatPath) -or -not [System.IO.File]::Exists($hostHeartbeatPath)) { continue }
            try {
                $trayHeartbeat = Read-InstallerHeartbeat $trayHeartbeatPath
                $hostHeartbeat = Read-InstallerHeartbeat $hostHeartbeatPath
                $trayProcess = if ($trayHeartbeat) { Get-Process -Id ([int]$trayHeartbeat.pid) -ErrorAction SilentlyContinue } else { $null }
                $traySessionReady = $activeConsoleSession -lt 0 -or ($trayProcess -and [int]$trayProcess.SessionId -eq $activeConsoleSession)
                $trayReady = (Test-InstallerHeartbeatFresh $trayHeartbeat "tray-ui") -and $traySessionReady
                $hostReady = Test-InstallerHeartbeatFresh $hostHeartbeat "host"
                $dashboardOwnersNow = @(Get-NetTCPConnection -LocalPort $settings.dashboardPort -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
                $hostOwnsDashboard = $hostReady -and [int]$hostHeartbeat.pid -in $dashboardOwnersNow
                $dashboardReady = $hostOwnsDashboard -and (Test-InstallerDashboardStatus ([int]$settings.dashboardPort))
                $state = [System.IO.File]::ReadAllText((Join-Path $InstallDir "watchdog-tray-state.json"), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                $managementReady = @("devspace", "hermes", "router", "ngrok" | Where-Object { [string](Get-WatchdogProperty $state.desired $_ "") -notin @("running", "stopped_by_user") }).Count -eq 0
                if ($trayReady -and $hostReady -and $dashboardReady -and $managementReady) { $ready = $true; break }
            } catch { }
        }
        if (-not $ready) { throw "Watchdog Host/Tray did not produce fresh heartbeats, loopback dashboard, and service-management state within $StartupTimeoutSeconds seconds." }
        foreach ($snapshot in $legacySnapshots) {
            $currentTask = Get-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop
            if (-not (Test-InstallTaskIdentity $currentTask $InstallDir)) { throw "Legacy task changed identity: $($snapshot.name)" }
            Disable-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop | Out-Null
            $taskDisabled = $true
        }
    }

    foreach ($retiredName in $retiredFiles) {
        $retiredPath = Join-Path $InstallDir $retiredName
        if (-not [System.IO.File]::Exists($retiredPath)) { continue }
        $original = @($overwritten | Where-Object { $_.name -eq $retiredName })
        if ($original.Count -ne 1 -or (Get-WatchdogFileSha256 $retiredPath) -ne $original[0].sha256) { throw "Retired Watchdog file changed during installation; refusing to remove $retiredPath." }
        $backupFile = Join-Path $payloadPath $retiredName
        if (-not [System.IO.File]::Exists($backupFile) -or (Get-WatchdogFileSha256 $backupFile) -ne $original[0].sha256) { throw "Retired Watchdog file backup is missing or corrupt: $retiredName" }
        [System.IO.File]::Delete($retiredPath)
    }
    Write-InstallerJson $recordPath $manifest
    Write-Host "DevSpace Watchdog Tray installed."
    Write-Host "Autostart: $runName"
    Write-Host "Dashboard: http://127.0.0.1:$($settings.dashboardPort)/"
    Write-Host "Recovery backup: $backupPath"
    if ($legacyTask) { Write-Host "Legacy watchdog task: $(if ($taskDisabled) { 'disabled after tray readiness' } elseif ($taskQuiesced) { 'logically quiesced; ACL prevents disable' } else { 'unchanged' }) ($legacyName)" }
} catch {
    $failure = $_
    try {
        if (-not (Invoke-InstalledWatchdogStop)) {
            $launcher = Join-Path $InstallDir "run-devspace-watchdog-tray-hidden.vbs"
            if ([System.IO.File]::Exists($launcher)) { Start-Process -FilePath "C:\Windows\System32\wscript.exe" -ArgumentList @("//B", "//NoLogo", "`"$launcher`"", "-Stop") -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null }
        }
    } catch { }
    $stopDeadline = [DateTimeOffset]::Now.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 250
        $trayStillRunning = Test-InstalledTrayProcess
        $hostStillRunning = Test-InstalledHostProcess
        $remainingDashboardOwners = @(Get-NetTCPConnection -LocalPort $settings.dashboardPort -State Listen -ErrorAction SilentlyContinue)
    } while (($trayStillRunning -or $hostStillRunning -or $remainingDashboardOwners.Count) -and [DateTimeOffset]::Now -lt $stopDeadline)
    $rolesStopped = $false
    try { $rolesStopped = Invoke-InstalledWatchdogBootstrap "CheckStopped" } catch { }
    if ($rolesStopped -and -not $trayStillRunning -and -not $hostStillRunning -and -not $remainingDashboardOwners.Count) {
        foreach ($item in $overwritten) {
            $source = Join-Path $payloadPath $item.name; $target = Join-Path $InstallDir $item.name
            if (-not [System.IO.File]::Exists($source) -or (Get-WatchdogFileSha256 $source) -ne $item.sha256) { throw "Rollback backup is missing or corrupt: $source" }
            if ($item.name -in $retiredFiles -and [System.IO.File]::Exists($target) -and (Get-WatchdogFileSha256 $target) -ne $item.sha256) { throw "Retired file was replaced; refusing to overwrite $target during rollback." }
            Copy-InstallerFileWithRetry $source $target $true
        }
        foreach ($name in $createdTargets) {
            $target = Join-Path $InstallDir $name
            if ([System.IO.File]::Exists($target)) { [System.IO.File]::Delete($target) }
        }
        if (-not $originalTransaction) {
            foreach ($snapshot in $legacySnapshots) {
                if ($snapshot.enabled) { Enable-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop | Out-Null }
                else { Disable-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop | Out-Null }
            }
            Restart-InstallLegacyProcesses $legacyProcessTransaction
        }
        if ($runChanged) {
            if ($null -ne $existingRun) { Set-ItemProperty -LiteralPath $runPath -Name $runName -Value $existingRun -ErrorAction Stop }
            else { Remove-ItemProperty -LiteralPath $runPath -Name $runName -ErrorAction Stop }
        }
        if ($existingTrayWasRunning) {
            try {
                if (-not (Invoke-InstalledWatchdogRun)) {
                    $restoredLauncher = Join-Path $InstallDir "run-devspace-watchdog-tray-hidden.vbs"
                    if ([System.IO.File]::Exists($restoredLauncher)) { Start-Process -FilePath "C:\Windows\System32\wscript.exe" -ArgumentList @("//B", "//NoLogo", "`"$restoredLauncher`"") -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null }
                }
            } catch { }
        }
        throw "DevSpace Watchdog Tray install failed and installation changes were rolled back. Legacy services were not stopped. Recovery backup: $backupPath. $($failure.Exception.Message)"
    }
    throw "DevSpace Watchdog Tray install failed, and the Watchdog Host/Tray did not fully stop and release the dashboard listener within 10 seconds. Installed files, autostart, and the legacy task were left intact because exit was not proven. Recovery backup: $backupPath. $($failure.Exception.Message)"
} finally { if ($trayInstallLease) { Exit-StackOperation $trayInstallLease } }
