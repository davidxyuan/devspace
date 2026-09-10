[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateSet("Run", "Stop")]
    [string]$Mode = "Run"
)

$ErrorActionPreference = "Stop"
$env:DEVSPACE_STACK_OPERATION_TOKEN = $null
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "devspace-watchdog.config.json" }
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$corePath = Join-Path $PSScriptRoot "watchdog-control-core.ps1"
. $corePath
$config = Read-WatchdogJson $ConfigPath
$settings = Get-WatchdogControlSettings $config
$stateDir = [System.IO.Path]::GetFullPath([string]$config.stateDir)
$heartbeatPath = Join-Path $stateDir "watchdog-tray-heartbeat.json"
$hostHeartbeatPath = Join-Path $stateDir "watchdog-host-heartbeat.json"
$statusUrl = "http://127.0.0.1:$($settings.dashboardPort)/api/status"
$dashboardUrl = "http://127.0.0.1:$($settings.dashboardPort)/"
$hostScript = Join-Path $PSScriptRoot "devspace-watchdog-tray.ps1"
$bootstrapPath = Join-Path $PSScriptRoot "devspace-watchdog-bootstrap.ps1"
$startupTracePath = Join-Path $stateDir "watchdog-tray-ui-startup.log"

function Write-TrayStartupTrace([string]$Message) {
    try {
        $line = "$(ConvertTo-WatchdogIso ([DateTimeOffset]::UtcNow)) pid=$PID session=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId) $Message" + [Environment]::NewLine
        [System.IO.File]::AppendAllText($startupTracePath, $line, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

trap {
    Write-TrayStartupTrace ("fatal=" + (Protect-WatchdogText ($_ | Out-String)))
    exit 1
}

Write-TrayStartupTrace "start mode=$Mode"

function Get-StableHash([string]$Value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(([System.IO.Path]::GetFullPath($Value)).ToLowerInvariant())
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "").Substring(0, 20)
    } finally { $sha.Dispose() }
}

$stableHash = Get-StableHash $ConfigPath
$stopCreated = $false
# The Thin Tray lives in the interactive Windows session while maintenance can run in Session 0.
# Use one global manual-reset event so every currently running Tray session observes the same stop request.
$stopEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, "Global\DevSpaceWatchdogTrayUiStop-$stableHash", [ref]$stopCreated)
if ($Mode -eq "Stop") {
    Write-TrayStartupTrace "stop-signal"
    [void]$stopEvent.Set()
    $stopEvent.Dispose()
    exit 0
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\DevSpaceWatchdogTrayUi-$stableHash", [ref]$createdNew)
if (-not $createdNew) {
    Write-TrayStartupTrace "duplicate-mutex"
    $stopEvent.Dispose(); $mutex.Dispose(); exit 0
}
Write-TrayStartupTrace "mutex-acquired"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
Write-TrayStartupTrace "winforms-loaded"
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DevSpaceThinTrayNative {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@

function New-CircleIcon([System.Drawing.Color]$Color) {
    $bitmap = New-Object System.Drawing.Bitmap(16, 16)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $border = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90, 0, 0, 0), 1)
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.FillEllipse($brush, 2, 2, 12, 12)
        $graphics.DrawEllipse($border, 2, 2, 12, 12)
        $handle = $bitmap.GetHicon()
        try { return ([System.Drawing.Icon]::FromHandle($handle).Clone()) }
        finally { [void][DevSpaceThinTrayNative]::DestroyIcon($handle) }
    } finally { $border.Dispose(); $brush.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
}


function Start-TrayBackgroundWorker($Shared, [scriptblock]$Body, [object[]]$Arguments) {
    $pipeline = [PowerShell]::Create()
    try {
        [void]$pipeline.AddScript($Body.ToString()).AddArgument($Shared)
        foreach ($argument in $Arguments) { [void]$pipeline.AddArgument($argument) }
        return [pscustomobject]@{ pipeline=$pipeline; result=$pipeline.BeginInvoke() }
    } catch { $pipeline.Dispose(); throw }
}

# Only immutable inputs and synchronized values cross the runspace boundary.
# No control, NotifyIcon, or other WinForms object is accessed by this worker.
$trayWorkerBody = {
    param($Shared, $CorePath, $OperationPath, $ConfigPath, $HeartbeatPath, $HostHeartbeatPath, $DashboardUrl, $StateDirectory, $BootstrapPath, $RuntimeDirectory, $TrayPid, $SessionId, $ProcessStartUtc)
    $ErrorActionPreference = "Stop"
    . $CorePath
    . $OperationPath
    $lastHeartbeat = [DateTimeOffset]::MinValue
    $lastHostStart = [DateTimeOffset]::MinValue
    $lastBusyCheck = [DateTimeOffset]::MinValue
    $child = $null
    function Start-TrayWorkerProcess([string]$FilePath, [string[]]$Arguments) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = (@($Arguments) | ForEach-Object { ConvertTo-WatchdogNativeArgument ([string]$_) }) -join " "
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = "Hidden"
        $psi.WorkingDirectory = $RuntimeDirectory
        return [Diagnostics.Process]::Start($psi)
    }
    function Test-HostHeartbeatFresh {
        try {
            if (-not [IO.File]::Exists($HostHeartbeatPath)) { return $false }
            $value = [IO.File]::ReadAllText($HostHeartbeatPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string]$value.timestamp).ToUniversalTime()).TotalSeconds
            return $age -ge -5 -and $age -le 15
        } catch { return $false }
    }
    try {
        while (-not $Shared.Stop) {
            try {
                $now = [DateTimeOffset]::UtcNow
                if (($now - $lastBusyCheck).TotalSeconds -ge 1) {
                    # On an unreadable lock, keep repair disabled until a later successful check.
                    $Shared.ManagementBusy = $true
                    try { $Shared.ManagementBusy = Test-StackOperationBusy -InstallDir (Split-Path $ConfigPath -Parent) }
                    catch { $Shared.WorkerMessage = "Management state unavailable; repair is disabled." }
                    $lastBusyCheck = $now
                }
                if (($now - $lastHeartbeat).TotalSeconds -ge 3) {
                    Write-WatchdogAtomicJson $HeartbeatPath ([pscustomobject]@{
                        pid=$TrayPid; timestamp=(ConvertTo-WatchdogIso $now); dashboard=$DashboardUrl
                        status=[string]$Shared.StatusText; role="tray-ui"; sessionId=$SessionId; processStartUtc=$ProcessStartUtc
                    }) 5
                    $lastHeartbeat = $now
                }
                if ($child -and $child.HasExited) {
                    $code = $child.ExitCode
                    $child.Dispose(); $child = $null; $Shared.ChildRunning = $false
                    $Shared.WorkerMessage = if ($code -eq 0) { "" } else { "Host action failed ($code); open Dashboard or logs." }
                }
                if ($Shared.OpenLogs) {
                    $Shared.OpenLogs = $false
                    $opened = Start-TrayWorkerProcess (Join-Path $env:WINDIR "explorer.exe") @($StateDirectory)
                    if ($opened) { $opened.Dispose() }
                }
                if ($Shared.RepairRequested -and $Shared.ManagementBusy) {
                    $Shared.RepairRequested = $false
                    $Shared.WorkerMessage = "Stack management is busy; retry Repair when it finishes."
                }
                $repair = [bool]$Shared.RepairRequested
                if (-not $child -and -not $Shared.ManagementBusy -and ($repair -or $Shared.EnsureRequested)) {
                    if ($repair -or ($now - $lastHostStart).TotalSeconds -ge 15) {
                        $Shared.RepairRequested = $false; $Shared.EnsureRequested = $false
                        if ($repair -or -not (Test-HostHeartbeatFresh)) {
                            $lastHostStart = $now
                            $childMode = if ($repair) { "RepairHost" } else { "Run" }
                            $child = Start-TrayWorkerProcess (Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe") @("-NoLogo", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-File", $BootstrapPath, "-Mode", $childMode, "-ConfigPath", $ConfigPath)
                            $Shared.ChildRunning = $true
                            $Shared.WorkerMessage = if ($repair) { "Repairing Watchdog Host..." } else { "Starting Watchdog Host..." }
                        }
                    }
                }
            } catch {
                $message = Protect-WatchdogText $_.Exception.Message
                $Shared.WorkerMessage = "Background check failed; open logs or retry later."
                try { [IO.File]::AppendAllText((Join-Path $StateDirectory "watchdog-tray-ui-startup.log"), "$(ConvertTo-WatchdogIso ([DateTimeOffset]::UtcNow)) worker-error $message`r`n", [Text.Encoding]::UTF8) } catch { }
            }
            Start-Sleep -Milliseconds 100
        }
    } finally {
        if ($child) { $child.Dispose() }
        # Cleanup runs after the message loop closes, never on the UI timer.
        try { if ([IO.File]::Exists($HeartbeatPath)) { [IO.File]::Delete($HeartbeatPath) } } catch { }
    }
}
$script:trayShared = [hashtable]::Synchronized(@{
    Stop=$false; ExitRequested=$false; OpenLogs=$false; RepairRequested=$false
    EnsureRequested=$true; ManagementBusy=$true; ChildRunning=$false; StatusText="Checking"; WorkerMessage=""
})
$script:trayWorker = $null

$icons = @{
    GREEN = New-CircleIcon ([System.Drawing.Color]::FromArgb(40, 180, 99))
    YELLOW = New-CircleIcon ([System.Drawing.Color]::FromArgb(244, 180, 0))
    RED = New-CircleIcon ([System.Drawing.Color]::FromArgb(220, 53, 69))
    GRAY = New-CircleIcon ([System.Drawing.Color]::FromArgb(125, 133, 144))
}
Write-TrayStartupTrace "icons-created"
$notify = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$openItem = $menu.Items.Add("Open Dashboard")
$statusItem = New-Object System.Windows.Forms.ToolStripMenuItem("Status: Checking")
$statusItem.Enabled = $false
[void]$menu.Items.Add($statusItem)
$connectionItem = New-Object System.Windows.Forms.ToolStripMenuItem("Connections: Checking")
$connectionItem.Enabled = $false
[void]$menu.Items.Add($connectionItem)
$publicItem = New-Object System.Windows.Forms.ToolStripMenuItem("Public MCP: Checking")
$publicItem.Enabled = $false
[void]$menu.Items.Add($publicItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$servicesMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Services")
$serviceItems = @{}
foreach ($service in @("devspace", "hermes", "router", "ngrok")) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem(((Get-Culture).TextInfo.ToTitleCase($service)) + ": Checking")
    $item.Enabled = $false
    [void]$servicesMenu.DropDownItems.Add($item)
    $serviceItems[$service] = $item
}
[void]$menu.Items.Add($servicesMenu)
$controlsItem = New-Object System.Windows.Forms.ToolStripMenuItem("Service controls are in Dashboard")
$controlsItem.Enabled = $false
[void]$menu.Items.Add($controlsItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$repairHostItem = $menu.Items.Add("Repair Watchdog Host")
$logsItem = $menu.Items.Add("Open Logs")
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$exitItem = $menu.Items.Add("Exit Tray")

$notify.ContextMenuStrip = $menu
$notify.Icon = $icons.YELLOW
$notify.Visible = $true
$notify.Text = "DevSpace Watchdog - Checking"
Write-TrayStartupTrace "notify-visible"

$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromSeconds(2)
$script:statusTask = $null
$script:lastStatus = $null
$script:lastStatusStart = [DateTimeOffset]::MinValue
$script:statusFailures = 0

function Start-StatusProbe {
    if ($script:statusTask) { return }
    if (([DateTimeOffset]::UtcNow - $script:lastStatusStart).TotalSeconds -lt 2) { return }
    $script:lastStatusStart = [DateTimeOffset]::UtcNow
    $script:statusTask = $http.GetStringAsync($statusUrl)
}

function Update-Presentation($Status) {
    if (-not $Status) {
        $notify.Icon = $icons.YELLOW
        $notify.Text = "DevSpace Watchdog - Host unavailable"
        $statusItem.Text = "Status: Host unavailable"
        $connectionItem.Text = "Connections: unavailable"
        $publicItem.Text = "Public MCP: unavailable"
        foreach ($service in $serviceItems.Keys) { $serviceItems[$service].Text = ((Get-Culture).TextInfo.ToTitleCase($service)) + ": unavailable" }
        return
    }
    $overall = $Status.overall
    $color = [string]$overall.color
    if (-not $icons.ContainsKey($color)) { $color = "YELLOW" }
    $notify.Icon = $icons[$color]
    $notify.Text = "DevSpace Watchdog - $([string]$overall.label)"
    $statusItem.Text = "Status: $([string]$overall.label)"
    $connectionItem.Text = "Connections: " + $(if ($Status.connections) { [string]$Status.connections.level } else { "Checking" })
    $publicOk = $true
    foreach ($service in @("devspace", "hermes")) {
        $svc = $Status.services.$service
        if ($svc -and $svc.enabled) {
            $probe = $Status.publicEndpoint.probes.$service
            if (-not $probe -or -not $probe.protocolHealthy) { $publicOk = $false }
        }
    }
    $publicItem.Text = "Public MCP: " + $(if ($publicOk) { "Healthy" } else { "Checking / degraded" })
    foreach ($service in $serviceItems.Keys) {
        $svc = $Status.services.$service
        $label = if (-not $svc -or -not $svc.enabled) { "Disabled" } elseif ($svc.desired -eq "stopped_by_user") { "Stopped" } elseif ($svc.healthy) { "Healthy" } else { [string]$svc.phase }
        $serviceItems[$service].Text = ((Get-Culture).TextInfo.ToTitleCase($service)) + ": " + $label
    }
}

function Complete-StatusProbe {
    if (-not $script:statusTask -or -not $script:statusTask.IsCompleted) { return }
    try {
        if ($script:statusTask.IsCanceled -or $script:statusTask.IsFaulted) { throw "Host status request failed." }
        $script:lastStatus = $script:statusTask.Result | ConvertFrom-Json
        $script:statusFailures = 0
        Update-Presentation $script:lastStatus
    } catch {
        $script:statusFailures++
        if ($script:statusFailures -ge 2) { Update-Presentation $null }
    } finally { $script:statusTask = $null }
}

function Open-DashboardInDefaultBrowser {
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $dashboardUrl
        $psi.UseShellExecute = $true
        $opened = [Diagnostics.Process]::Start($psi)
        if (-not $opened) { throw "Windows shell did not return a browser process." }
        $opened.Dispose()
        Write-TrayStartupTrace "dashboard-opened shell-execute"
    } catch {
        $message = Protect-WatchdogText $_.Exception.Message
        $script:trayShared.WorkerMessage = "Could not open Dashboard; check the default browser association."
        Write-TrayStartupTrace "dashboard-open-failed $message"
    }
}

$openItem.add_Click({ Open-DashboardInDefaultBrowser })
$notify.add_DoubleClick({ Open-DashboardInDefaultBrowser })
$logsItem.add_Click({ $script:trayShared.OpenLogs = $true })
$repairHostItem.add_Click({ $script:trayShared.RepairRequested = $true })
$exitItem.add_Click({
    $script:trayShared.ExitRequested = $true
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.add_Tick({
    try {
        if ($stopEvent.WaitOne(0) -or $script:trayShared.ExitRequested) { [System.Windows.Forms.Application]::Exit(); return }
        Complete-StatusProbe
        Start-StatusProbe
        if ($script:statusFailures -ge 2) { $script:trayShared.EnsureRequested = $true }
        $script:trayShared.StatusText = if ($script:lastStatus) { [string]$script:lastStatus.overall.label } else { "Host unavailable" }
        $repairHostItem.Enabled = -not $script:trayShared.ManagementBusy -and -not $script:trayShared.ChildRunning -and -not $script:trayShared.RepairRequested
        $repairHostItem.Text = if ($script:trayShared.ManagementBusy) { "Repair Watchdog Host (management busy)" } elseif ($script:trayShared.ChildRunning) { "Watchdog Host action in progress..." } else { "Repair Watchdog Host" }
        if ($script:trayShared.WorkerMessage) { $statusItem.Text = [string]$script:trayShared.WorkerMessage }
    } catch {
        try { Write-TrayStartupTrace ("timer-error " + (Protect-WatchdogText $_.Exception.Message)) } catch { }
    }
})

try {
    $self = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $script:trayWorker = Start-TrayBackgroundWorker $script:trayShared $trayWorkerBody @($corePath, (Join-Path $PSScriptRoot "stack-operation.ps1"), $ConfigPath, $heartbeatPath, $hostHeartbeatPath, $dashboardUrl, $stateDir, $bootstrapPath, $PSScriptRoot, $PID, $self.SessionId, $self.StartTime.ToUniversalTime().ToString("o"))
    } finally { $self.Dispose() }
    Write-TrayStartupTrace "background-worker-started"
    Start-StatusProbe
    Write-TrayStartupTrace "status-probe-started"
    $timer.Start()
    Write-TrayStartupTrace "message-loop"
    [System.Windows.Forms.Application]::Run()
} finally {
    Write-TrayStartupTrace "exit"
    $timer.Stop(); $timer.Dispose()
    try { $http.Dispose() } catch { }
    $notify.Visible = $false
    $notify.Dispose(); $menu.Dispose()
    foreach ($icon in $icons.Values) { $icon.Dispose() }
    $script:trayShared.Stop = $true
    if ($script:trayWorker) {
        try { [void]$script:trayWorker.pipeline.EndInvoke($script:trayWorker.result) } catch { }
        finally { $script:trayWorker.pipeline.Dispose() }
    }
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose(); $stopEvent.Dispose()
}
