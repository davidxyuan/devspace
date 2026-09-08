[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateSet("Run", "Stop", "Host", "StopHost")]
    [string]$Mode = "Run"
)

$ErrorActionPreference = "Stop"
$corePath = Join-Path $PSScriptRoot "watchdog-control-core.ps1"
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "devspace-watchdog.config.json" }
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)

function Get-TrayStableHash([string]$Value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(([System.IO.Path]::GetFullPath($Value)).ToLowerInvariant())
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "").Substring(0, 20)
    } finally { $sha.Dispose() }
}

$stableHash = Get-TrayStableHash $ConfigPath
$isHostMode = $Mode -in @("Host", "StopHost")
$instanceRole = if ($isHostMode) { "Host" } else { "Tray" }
$stopEventCreated = $false
$stopEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, "Local\DevSpaceWatchdog${instanceRole}Stop-$stableHash", [ref]$stopEventCreated)
if ($Mode -in @("Stop", "StopHost")) {
    [void]$stopEvent.Set()
    $stopEvent.Dispose()
    exit 0
}

$env:DEVSPACE_STACK_OPERATION_TOKEN = $null
. $corePath
. (Join-Path $PSScriptRoot "stack-operation.ps1")
. (Join-Path $PSScriptRoot "stack-host-management.ps1")
$script:config = Read-WatchdogJson $ConfigPath
$script:settings = Get-WatchdogControlSettings $script:config
$script:stateDir = [System.IO.Path]::GetFullPath([string]$script:config.stateDir)
$script:statePath = Join-Path $script:stateDir "watchdog-tray-state.json"
$script:heartbeatPath = Join-Path $script:stateDir $(if ($isHostMode) { "watchdog-host-heartbeat.json" } else { "watchdog-tray-heartbeat.json" })
$script:templatePath = Join-Path $PSScriptRoot "devspace-control-center.html"

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\DevSpaceWatchdog$instanceRole-$stableHash", [ref]$createdNew)
if (-not $createdNew) {
    $stopEvent.Dispose()
    $mutex.Dispose()
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DevSpaceTrayNative {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
}
"@

function New-TrayCircleIcon([System.Drawing.Color]$Color) {
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
        try { return ([System.Drawing.Icon]::FromHandle($handle).Clone()) } finally { [void][DevSpaceTrayNative]::DestroyIcon($handle) }
    } finally {
        $border.Dispose(); $brush.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
    }
}

function New-ControlToken {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function Test-ControlToken([string]$Left, [string]$Right) {
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $a = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Left))
        $b = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Right))
        $difference = 0
        for ($i = 0; $i -lt $a.Length; $i++) { $difference = $difference -bor ($a[$i] -bxor $b[$i]) }
        return $difference -eq 0
    } finally { $sha.Dispose() }
}

$script:controlToken = New-ControlToken
$script:state = Read-WatchdogState $script:statePath $script:config
if ($script:state.stateLoadError) {
    Write-WatchdogEvent $script:stateDir $script:config "tray" "state_load_failed" $script:state.stateLoadError "enter maintenance" "auto recovery paused"
}
Save-WatchdogState $script:statePath $script:state
$script:lastHealth = $null
$script:lastPublic = $null
$script:lastServiceSignature = @{}
$script:lastPublicSignature = ""
$script:healthPowerShell = $null
$script:healthAsync = $null
$script:healthIncludedPublic = $false
$script:lastHealthStarted = [DateTimeOffset]::MinValue
$script:lastPublicStarted = [DateTimeOffset]::MinValue
$publicProbeState = Get-WatchdogProperty $script:state "publicProbe" $null
$script:publicProbeFailureCount = [int](Get-WatchdogProperty $publicProbeState "consecutiveFailures" 0)
$script:nextPublicProbeAt = [DateTimeOffset]::MinValue
$nextPublicProbeText = [string](Get-WatchdogProperty $publicProbeState "nextProbeUtc" "")
$parsedNextPublicProbe = [DateTimeOffset]::MinValue
if ($nextPublicProbeText -and [DateTimeOffset]::TryParse($nextPublicProbeText, [ref]$parsedNextPublicProbe)) { $script:nextPublicProbeAt = $parsedNextPublicProbe }
if ($script:publicProbeFailureCount -eq 0) {
    $lastSuccessText = [string](Get-WatchdogProperty $publicProbeState "lastSuccessUtc" "")
    $parsedLastSuccess = [DateTimeOffset]::MinValue
    if ($lastSuccessText -and [DateTimeOffset]::TryParse($lastSuccessText, [ref]$parsedLastSuccess)) {
        $minimumNextProbe = $parsedLastSuccess.AddSeconds([int]$script:settings.publicProbeSeconds)
        if ($script:nextPublicProbeAt -eq [DateTimeOffset]::MinValue -or $script:nextPublicProbeAt -lt $minimumNextProbe) {
            $script:nextPublicProbeAt = $minimumNextProbe
            $publicProbeState.nextProbeUtc = ConvertTo-WatchdogIso $minimumNextProbe
            Save-WatchdogState $script:statePath $script:state
        }
    }
}
# A restart has no in-memory public snapshot. Probe once immediately instead of
# leaving the tray at "Checking public MCP" until the persisted six-hour slot.
$script:forcePublicProbe = $true
$script:nextPublicProbeAt = [DateTimeOffset]::MinValue
$script:lastHeartbeat = [DateTimeOffset]::MinValue
$script:mutationInProgress = $false
$script:mutationPowerShell = $null
$script:mutationAsync = $null
$script:stackMutationLease = $null
$script:mutationClient = $null
$script:shutdownRequested = $false
$script:lastTimerError = ""
$script:lastTimerErrorAt = [DateTimeOffset]::MinValue

function Get-ServiceFromSnapshot([string]$Service) {
    if (-not $script:lastHealth) { return $null }
    return Get-WatchdogProperty $script:lastHealth.services $Service $null
}

function Get-OverallTrayState {
    if (-not $script:lastHealth) { return [pscustomobject]@{ color="YELLOW"; label="Checking" } }
    $enabled = @($script:WatchdogServiceNames | Where-Object { Test-WatchdogServiceEnabled $_ $script:config })
    $desiredRunning = @($enabled | Where-Object { [string](Get-WatchdogProperty $script:state.desired $_ "running") -eq "running" })
    if ($enabled.Count -gt 0 -and $desiredRunning.Count -eq 0) { return [pscustomobject]@{ color="GRAY"; label="Stopped by user" } }
    foreach ($service in $enabled) {
        $record = Get-WatchdogProperty $script:state.recovery $service $null
        $health = Get-ServiceFromSnapshot $service
        if ([string](Get-WatchdogProperty $record "phase" "") -eq "RecoveryFailed" -or [bool](Get-WatchdogProperty $health "identityConflict" $false)) {
            return [pscustomobject]@{ color="RED"; label="Recovery failed" }
        }
    }
    if ($script:state.maintenanceMode) { return [pscustomobject]@{ color="YELLOW"; label="Maintenance" } }
    foreach ($service in $enabled) {
        if ([string](Get-WatchdogProperty $script:state.desired $service "running") -eq "stopped_by_user") { return [pscustomobject]@{ color="YELLOW"; label="Partially stopped" } }
        $health = Get-ServiceFromSnapshot $service
        if (-not [bool](Get-WatchdogProperty $health "healthy" $false)) { return [pscustomobject]@{ color="YELLOW"; label="Degraded" } }
    }
    $routerHealth = Get-ServiceFromSnapshot "router"
    $connectionMetrics = Get-WatchdogProperty $routerHealth "connections" $null
    $connectionLevel = [string](Get-WatchdogProperty $connectionMetrics "level" "")
    if ($connectionLevel -eq "RED") { return [pscustomobject]@{ color="RED"; label="Connection overload" } }
    if ($connectionLevel -eq "YELLOW") { return [pscustomobject]@{ color="YELLOW"; label="Connection warning" } }
    if (-not $script:lastPublic) { return [pscustomobject]@{ color="YELLOW"; label="Checking public MCP" } }
    foreach ($service in @("devspace", "hermes")) {
        if (Test-WatchdogServiceEnabled $service $script:config) {
            $probe = Get-WatchdogProperty $script:lastPublic $service $null
            if (-not [bool](Get-WatchdogProperty $probe "protocolHealthy" $false)) { return [pscustomobject]@{ color="YELLOW"; label="Public MCP degraded" } }
        }
    }
    return [pscustomobject]@{ color="GREEN"; label="Healthy" }
}

function Get-ControlStatusPayload {
    $overall = Get-OverallTrayState
    $editable = Get-WatchdogEditableConfig $script:config
    $services = [ordered]@{}
    foreach ($service in $script:WatchdogServiceNames) {
        $health = Get-ServiceFromSnapshot $service
        $record = Get-WatchdogProperty $script:state.recovery $service (New-WatchdogRecoveryRecord)
        $services[$service] = [pscustomobject][ordered]@{
            enabled = Test-WatchdogServiceEnabled $service $script:config
            desired = [string](Get-WatchdogProperty $script:state.desired $service "running")
            phase = [string](Get-WatchdogProperty $record "phase" "Checking")
            healthy = [bool](Get-WatchdogProperty $health "healthy" $false)
            processFound = [bool](Get-WatchdogProperty $health "processFound" $false)
            listenerFound = [bool](Get-WatchdogProperty $health "listenerFound" $false)
            httpReachable = [bool](Get-WatchdogProperty $health "httpReachable" $false)
            protocolHealthy = [bool](Get-WatchdogProperty $health "protocolHealthy" $false)
            busyIndeterminate = [bool](Get-WatchdogProperty $health "busyIndeterminate" $false)
            identityConflict = [bool](Get-WatchdogProperty $health "identityConflict" $false)
            pid = Get-WatchdogProperty $health "pid" $null
            port = Get-WatchdogServicePort $service $script:config
            uptimeSeconds = Get-WatchdogProperty $health "uptimeSeconds" $null
            detail = [string](Get-WatchdogProperty $health "detail" "checking")
            attemptCount = [int](Get-WatchdogProperty $record "attemptCount" 0)
            lastError = [string](Get-WatchdogProperty $record "lastError" (Get-WatchdogProperty $health "error" ""))
            lastRecoveryUtc = Get-WatchdogProperty $record "lastRecoveryUtc" $null
            nextRetryUtc = Get-WatchdogProperty $record "nextRetryUtc" $null
        }
    }
    return [pscustomobject][ordered]@{
        timestamp = ConvertTo-WatchdogIso ([DateTimeOffset]::UtcNow)
        overall = $overall
        inventory = Get-CachedStackInventory
        activeJob = Get-CachedStackJob
        maintenanceMode = [bool]$script:state.maintenanceMode
        mutationInProgress = [bool]$script:mutationInProgress
        stopping = [bool]$script:shutdownRequested
        services = [pscustomobject]$services
        optionalTools = Get-WatchdogProperty $script:lastHealth "optionalTools" $null
        connections = Get-WatchdogProperty (Get-ServiceFromSnapshot "router") "connections" $null
        publicEndpoint = [pscustomobject]@{
            mode = $editable.endpointMode
            domain = $editable.publicDomain
            devspaceUrl = $editable.publicDomain.TrimEnd("/") + $editable.devspaceRoutePath + "/mcp"
            hermesUrl = $editable.publicDomain.TrimEnd("/") + $editable.hermesRoutePath + "/mcp"
            probes = $script:lastPublic
            schedule = [pscustomobject]@{
                healthyIntervalSeconds = [int]$script:settings.publicProbeSeconds
                consecutiveFailures = [int]$script:publicProbeFailureCount
                nextProbeUtc = $(if ($script:nextPublicProbeAt -eq [DateTimeOffset]::MinValue) { $null } else { ConvertTo-WatchdogIso $script:nextPublicProbeAt })
                forced = [bool]$script:forcePublicProbe
            }
        }
        config = $editable
    }
}

function Start-HealthRunspace([switch]$IncludePublic) {
    if ($script:healthAsync -or $script:mutationInProgress -or $script:shutdownRequested) { return }
    $scriptText = @'
param($CorePath, $ConfigurationPath, $ProbePublic)
$ErrorActionPreference = "Stop"
. $CorePath
$snapshot = Get-WatchdogHealthSnapshot -ConfigPath $ConfigurationPath -IncludePublic:$ProbePublic
$snapshot | ConvertTo-Json -Depth 30 -Compress
'@
    $script:healthPowerShell = [PowerShell]::Create()
    [void]$script:healthPowerShell.AddScript($scriptText).AddArgument($corePath).AddArgument($ConfigPath).AddArgument([bool]$IncludePublic)
    $script:healthAsync = $script:healthPowerShell.BeginInvoke()
    $script:healthIncludedPublic = [bool]$IncludePublic
    $script:lastHealthStarted = [DateTimeOffset]::UtcNow
    if ($IncludePublic) { $script:lastPublicStarted = $script:lastHealthStarted }
}

function Stop-HealthRunspace {
    if (-not $script:healthPowerShell) { return }
    try { if ($script:healthAsync -and -not $script:healthAsync.IsCompleted) { $script:healthPowerShell.Stop() } } catch { }
    try { $script:healthPowerShell.Dispose() } catch { }
    $script:healthPowerShell = $null
    $script:healthAsync = $null
    $script:healthIncludedPublic = $false
}

function Test-PublicProbeHealthy($PublicSnapshot) {
    if (-not $PublicSnapshot) { return $false }
    foreach ($service in @("devspace", "hermes")) {
        if (-not (Test-WatchdogServiceEnabled $service $script:config)) { continue }
        $probe = Get-WatchdogProperty $PublicSnapshot $service $null
        if (-not [bool](Get-WatchdogProperty $probe "protocolHealthy" $false)) { return $false }
    }
    return $true
}

function Update-PublicProbeSchedule($PublicSnapshot, [bool]$Completed = $true) {
    $now = [DateTimeOffset]::UtcNow
    $healthy = $Completed -and (Test-PublicProbeHealthy $PublicSnapshot)
    if ($healthy) {
        $script:publicProbeFailureCount = 0
        $delaySeconds = [int]$script:settings.publicProbeSeconds
    } else {
        $script:publicProbeFailureCount++
        $backoff = @($script:settings.publicProbeBackoffSeconds)
        $index = [Math]::Min([Math]::Max($script:publicProbeFailureCount - 1, 0), $backoff.Count - 1)
        $delaySeconds = [int]$backoff[$index]
    }
    $script:forcePublicProbe = $false
    $script:nextPublicProbeAt = $now.AddSeconds($delaySeconds)
    $record = Get-WatchdogProperty $script:state "publicProbe" $null
    if (-not $record) {
        $record = [pscustomobject][ordered]@{ consecutiveFailures=0; nextProbeUtc=$null; lastAttemptUtc=$null; lastSuccessUtc=$null }
        Set-WatchdogProperty $script:state "publicProbe" $record
    }
    $record.consecutiveFailures = [int]$script:publicProbeFailureCount
    $record.lastAttemptUtc = ConvertTo-WatchdogIso $now
    if ($healthy) { $record.lastSuccessUtc = ConvertTo-WatchdogIso $now }
    $record.nextProbeUtc = ConvertTo-WatchdogIso $script:nextPublicProbeAt
    try { Save-WatchdogState $script:statePath $script:state } catch { }
}

function Request-ImmediatePublicProbe([string]$Reason = "event") {
    $script:forcePublicProbe = $true
    $script:nextPublicProbeAt = [DateTimeOffset]::MinValue
    $record = Get-WatchdogProperty $script:state "publicProbe" $null
    if (-not $record) {
        $record = [pscustomobject][ordered]@{ consecutiveFailures=0; nextProbeUtc=$null; lastAttemptUtc=$null; lastSuccessUtc=$null }
        Set-WatchdogProperty $script:state "publicProbe" $record
    }
    $record.nextProbeUtc = $null
    try { Save-WatchdogState $script:statePath $script:state } catch { }
    if ($Reason) {
        Write-WatchdogEvent $script:stateDir $script:config "public" "verify_requested" $Reason "schedule" "immediate"
    }
}

function Test-PublicProbeDue([DateTimeOffset]$Now) {
    return $script:forcePublicProbe -or $script:nextPublicProbeAt -eq [DateTimeOffset]::MinValue -or $Now -ge $script:nextPublicProbeAt
}

function Write-HealthTransitions($Snapshot) {
    foreach ($service in $script:WatchdogServiceNames) {
        $health = Get-WatchdogProperty $Snapshot.services $service $null
        if (-not $health) { continue }
        $signature = "$(Get-WatchdogProperty $health 'healthy' $false)|$(Get-WatchdogProperty $health 'detail' '')|$(Get-WatchdogProperty $health 'identityConflict' $false)"
        if ($script:lastServiceSignature[$service] -ne $signature) {
            Write-WatchdogEvent $script:stateDir $script:config $service "health" ([string]$health.error) "observe" $(if ($health.healthy) { "healthy" } else { [string]$health.detail })
            $script:lastServiceSignature[$service] = $signature
        }
    }
    if ($Snapshot.public) {
        $publicSignature = "$(Get-WatchdogProperty $Snapshot.public.devspace 'protocolHealthy' $false)|$(Get-WatchdogProperty $Snapshot.public.hermes 'protocolHealthy' $false)"
        if ($script:lastPublicSignature -ne $publicSignature) {
            Write-WatchdogEvent $script:stateDir $script:config "public" "health" "periodic MCP initialize" "probe" $publicSignature
            $script:lastPublicSignature = $publicSignature
        }
    }
}

function Apply-HealthSnapshot($Snapshot) {
    $previousHealth = $script:lastHealth
    Write-HealthTransitions $Snapshot
    $script:lastHealth = $Snapshot
    if (-not $Snapshot.public -and $previousHealth) {
        foreach ($service in @("devspace", "hermes", "router", "ngrok")) {
            if (-not (Test-WatchdogServiceEnabled $service $script:config)) { continue }
            $previousService = Get-WatchdogProperty $previousHealth.services $service $null
            $currentService = Get-WatchdogProperty $Snapshot.services $service $null
            if (-not $previousService -or -not $currentService -or -not [bool](Get-WatchdogProperty $currentService "healthy" $false)) { continue }
            $previousPid = [int](Get-WatchdogProperty $previousService "pid" 0)
            $currentPid = [int](Get-WatchdogProperty $currentService "pid" 0)
            $pidChanged = $previousPid -gt 0 -and $currentPid -gt 0 -and $previousPid -ne $currentPid
            $processRestored = -not [bool](Get-WatchdogProperty $previousService "processFound" $false) -and [bool](Get-WatchdogProperty $currentService "processFound" $false)
            $listenerRestored = -not [bool](Get-WatchdogProperty $previousService "listenerFound" $false) -and [bool](Get-WatchdogProperty $currentService "listenerFound" $false)
            if ($pidChanged -or $processRestored -or $listenerRestored) { Request-ImmediatePublicProbe "local_recovered:$service" }
        }
    }
    if ($Snapshot.public) {
        $script:lastPublic = $Snapshot.public
        Update-PublicProbeSchedule $Snapshot.public $true
    }
    if (-not $script:mutationInProgress) {
        foreach ($service in $script:WatchdogServiceNames) {
            if (-not (Test-WatchdogServiceEnabled $service $script:config)) { continue }
            $health = Get-WatchdogProperty $Snapshot.services $service $null
            $decision = Update-WatchdogRecoveryDecision $script:state $service $health $script:settings
            if ($decision.action -eq "Recover") {
                $result = Invoke-WatchdogServiceRecovery $service $ConfigPath $script:config $health
                Complete-WatchdogRecoveryAttempt $script:state $service $result
                Write-WatchdogEvent $script:stateDir $script:config $service "recovery" $decision.reason "attempt $($decision.record.attemptCount)" $(if ($result.success) { "dispatched" } else { $result.error })
                if ($result.success -and $service -in @("devspace", "hermes", "router", "ngrok")) { Request-ImmediatePublicProbe "recovery:$service" }
            }
        }
        Save-WatchdogState $script:statePath $script:state
    }
}

function Complete-HealthRunspace {
    if (-not $script:healthAsync -or -not $script:healthAsync.IsCompleted) { return }
    $includedPublic = [bool]$script:healthIncludedPublic
    try {
        $output = $script:healthPowerShell.EndInvoke($script:healthAsync)
        $json = ($output | ForEach-Object { [string]$_ }) -join ""
        if (-not $json) {
            $errors = ($script:healthPowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join "; "
            throw $(if ($errors) { $errors } else { "Health runspace returned no data." })
        }
        Apply-HealthSnapshot ($json | ConvertFrom-Json)
    } catch {
        if ($includedPublic) { Update-PublicProbeSchedule $null $false }
        Write-WatchdogEvent $script:stateDir $script:config "tray" "health_cycle_failed" $_.Exception.Message "probe" "failed"
    } finally {
        $script:healthPowerShell.Dispose()
        $script:healthPowerShell = $null
        $script:healthAsync = $null
        $script:healthIncludedPublic = $false
    }
}

function Invoke-OptionalToolRepair([string]$Tool) {
    Assert-ControlMutationAvailable
    $status = Get-WatchdogProperty $script:lastHealth "optionalTools" $null
    if (-not $status) { return [pscustomobject]@{ success=$false; error="Optional-tool health check is not ready." } }
    $result = Repair-WatchdogOptionalTool $Tool $status
    Write-WatchdogEvent $script:stateDir $script:config "optional:$Tool" "manual_repair" "user request" "repair" $(if ($result.success) { "dispatched" } else { $result.error })
    return $result
}

function Invoke-ManualServiceAction([string]$Action, [string]$Service) {
    Assert-ControlMutationAvailable
    if ($Action -notin @("start", "stop", "restart", "retry", "keep_stopped", "maintenance", "resume")) { throw "Unknown action." }
    if ($Action -in @("maintenance", "resume")) {
        $script:state.maintenanceMode = ($Action -eq "maintenance")
        Save-WatchdogState $script:statePath $script:state
        Write-WatchdogEvent $script:stateDir $script:config "all" "manual_action" "user request" $Action "complete"
        return [pscustomobject]@{ success=$true; results=@() }
    }
    $targets = if ($Service -eq "all") { @($script:WatchdogServiceNames | Where-Object { Test-WatchdogServiceEnabled $_ $script:config }) } elseif ($Service -in $script:WatchdogServiceNames) { @($Service) } else { throw "Unknown service." }
    if ($Action -in @("stop", "keep_stopped")) { $targets = @($targets | Sort-Object { [Array]::IndexOf(@("ngrok","router","hermes","devspace"), $_) }) }
    else { $targets = @($targets | Sort-Object { [Array]::IndexOf(@("devspace","hermes","router","ngrok"), $_) }) }
    $results = @()
    foreach ($target in $targets) {
        if ($Action -in @("start", "restart", "retry")) { Set-WatchdogDesiredState $script:state $target "running" }
        if ($Action -in @("stop", "keep_stopped")) { Set-WatchdogDesiredState $script:state $target "stopped_by_user" }
    }
    Save-WatchdogState $script:statePath $script:state
    foreach ($target in $targets) {
        $health = Get-ServiceFromSnapshot $target
        $result = switch ($Action) {
            "start" {
                if (-not $health) { [pscustomobject]@{ success=$false; error="Health check is not ready; refusing a duplicate start." } }
                elseif ($health.healthy) { [pscustomobject]@{ success=$true; error="already healthy" } }
                elseif ($health -and ($health.identityConflict -or $health.busyIndeterminate)) { [pscustomobject]@{ success=$false; error="Current identity/busy evidence blocks a duplicate start." } }
                else { Start-WatchdogManagedService $target $ConfigPath $script:config }
            }
            "stop" { Stop-WatchdogManagedService $target $script:config }
            "keep_stopped" { Stop-WatchdogManagedService $target $script:config }
            "restart" { Restart-WatchdogManagedService $target $ConfigPath $script:config }
            "retry" {
                Reset-WatchdogRecoveryForRetry $script:state $target
                if (-not $health) { [pscustomobject]@{ success=$false; error="Health check is not ready." } }
                elseif ($health.healthy) { [pscustomobject]@{ success=$true; error="already healthy" } }
                elseif ($health.identityConflict) { [pscustomobject]@{ success=$false; error="Identity conflict blocks manual retry." } }
                else { Restart-WatchdogManagedService $target $ConfigPath $script:config }
            }
        }
        $results += [pscustomobject]@{ service=$target; success=[bool]$result.success; error=[string](Get-WatchdogProperty $result "error" "") }
        Write-WatchdogEvent $script:stateDir $script:config $target "manual_action" "user request" $Action $(if ($result.success) { "complete" } else { $result.error })
        if ($result.success -and $Action -in @("start", "restart", "retry")) { Request-ImmediatePublicProbe "manual_$Action`:$target" }
    }
    Save-WatchdogState $script:statePath $script:state
    return [pscustomobject]@{ success=(@($results | Where-Object { -not $_.success }).Count -eq 0); results=$results }
}

function Invoke-ConfigApply($InputObject) {
    Assert-ControlMutationAvailable
    $script:mutationInProgress = $true
    Stop-HealthRunspace
    $oldConfig = $script:config
    $result = $null
    $stoppedServices = @()
    $newConfigActive = $false
    try {
        $result = Set-WatchdogConfiguration $ConfigPath $InputObject
        foreach ($service in @("ngrok", "router", "devspace", "hermes")) {
            if ($service -notin @($result.impact.requiresServiceRestart) -or -not (Test-WatchdogServiceEnabled $service $oldConfig)) { continue }
            $stop = Stop-WatchdogManagedService $service $oldConfig
            if (-not $stop.success) { throw "Could not stop $service for configuration apply: $($stop.error)" }
            $stoppedServices += $service
        }
        $script:config = $result.config
        $script:settings = Get-WatchdogControlSettings $script:config
        $newConfigActive = $true
        foreach ($service in @("devspace", "hermes", "router", "ngrok")) {
            if ($service -in @($result.impact.requiresServiceRestart) -and (Test-WatchdogServiceEnabled $service $script:config) -and [string](Get-WatchdogProperty $script:state.desired $service "running") -eq "running") {
                $start = Start-WatchdogManagedService $service $ConfigPath $script:config
                if (-not $start.success) { throw "Could not start $service after configuration apply: $($start.error)" }
            }
        }
        Write-WatchdogEvent $script:stateDir $script:config "configuration" "apply" ($result.impact.level) "backup $($result.backup.id)" "complete"
        return $result
    } catch {
        $applyError = $_.Exception.Message
        if ($result) {
            $rollbackErrors = @()
            if ($newConfigActive) {
                foreach ($service in $stoppedServices) {
                    $stop = Stop-WatchdogManagedService $service $result.config
                    if (-not $stop.success) { $rollbackErrors += "stop new $service`: $($stop.error)" }
                }
            }
            try { [void](Restore-WatchdogConfigurationBackup $ConfigPath $result.backup.id) }
            catch { $rollbackErrors += "restore files: $($_.Exception.Message)" }
            $script:config = $oldConfig
            $script:settings = Get-WatchdogControlSettings $script:config
            foreach ($service in @("devspace", "hermes", "router", "ngrok")) {
                if ($service -notin $stoppedServices -or [string](Get-WatchdogProperty $script:state.desired $service "running") -ne "running") { continue }
                $start = Start-WatchdogManagedService $service $ConfigPath $oldConfig
                if (-not $start.success) { $rollbackErrors += "restart old $service`: $($start.error)" }
            }
            if ($rollbackErrors.Count) { throw "Configuration apply failed and rollback needs operator attention: $applyError; $($rollbackErrors -join '; ')" }
            throw "Configuration apply failed; previous files and managed services were restored: $applyError"
        }
        throw
    } finally {
        $script:lastHealth = $null
        $script:lastPublic = $null
        $script:lastHealthStarted = [DateTimeOffset]::MinValue
        Request-ImmediatePublicProbe "configuration_apply"
        $script:mutationInProgress = $false
    }
}

function Invoke-ConfigRollback([string]$BackupId) {
    Assert-ControlMutationAvailable
    $script:mutationInProgress = $true
    Stop-HealthRunspace
    $oldConfig = $script:config
    $restored = $null
    $rollbackImpact = $null
    $stoppedServices = @()
    $restoredConfigActive = $false
    try {
        $restored = Restore-WatchdogConfigurationBackup $ConfigPath $BackupId
        $rollbackImpact = New-WatchdogConfigImpact $oldConfig (Get-WatchdogEditableConfig $restored.config)
        foreach ($service in @("ngrok", "router", "devspace", "hermes")) {
            if ($service -notin @($rollbackImpact.requiresServiceRestart) -or -not (Test-WatchdogServiceEnabled $service $oldConfig)) { continue }
            $stop = Stop-WatchdogManagedService $service $oldConfig
            if (-not $stop.success) { throw "Could not stop $service for configuration rollback: $($stop.error)" }
            $stoppedServices += $service
        }
        $script:config = $restored.config
        $script:settings = Get-WatchdogControlSettings $script:config
        $restoredConfigActive = $true
        foreach ($service in @("devspace", "hermes", "router", "ngrok")) {
            if ($service -in @($rollbackImpact.requiresServiceRestart) -and (Test-WatchdogServiceEnabled $service $script:config) -and [string](Get-WatchdogProperty $script:state.desired $service "running") -eq "running") {
                $start = Start-WatchdogManagedService $service $ConfigPath $script:config
                if (-not $start.success) { throw "Could not start $service after configuration rollback: $($start.error)" }
            }
        }
        Write-WatchdogEvent $script:stateDir $script:config "configuration" "rollback" $BackupId "restore" "complete"
        Set-WatchdogProperty $restored "impact" $rollbackImpact
        return $restored
    } catch {
        $rollbackError = $_.Exception.Message
        if ($restored) {
            $undoErrors = @()
            if ($restoredConfigActive) {
                foreach ($service in $stoppedServices) {
                    $stop = Stop-WatchdogManagedService $service $restored.config
                    if (-not $stop.success) { $undoErrors += "stop restored $service`: $($stop.error)" }
                }
            }
            try { [void](Restore-WatchdogConfigurationBackup $ConfigPath $restored.safetyBackup.id) }
            catch { $undoErrors += "restore pre-rollback files: $($_.Exception.Message)" }
            $script:config = $oldConfig
            $script:settings = Get-WatchdogControlSettings $script:config
            foreach ($service in @("devspace", "hermes", "router", "ngrok")) {
                if ($service -notin $stoppedServices -or [string](Get-WatchdogProperty $script:state.desired $service "running") -ne "running") { continue }
                $start = Start-WatchdogManagedService $service $ConfigPath $oldConfig
                if (-not $start.success) { $undoErrors += "restart pre-rollback $service`: $($start.error)" }
            }
            if ($undoErrors.Count) { throw "Configuration rollback failed and undo needs operator attention: $rollbackError; $($undoErrors -join '; ')" }
            throw "Configuration rollback failed; the pre-rollback files and managed services were restored: $rollbackError"
        }
        throw
    } finally {
        $script:lastHealth = $null
        $script:lastPublic = $null
        $script:lastHealthStarted = [DateTimeOffset]::MinValue
        Request-ImmediatePublicProbe "configuration_rollback"
        $script:mutationInProgress = $false
    }
}

function Assert-ControlMutationAvailable {
    if ($script:shutdownRequested) { throw "Watchdog is stopping; mutations are unavailable." }
    if ($script:mutationInProgress) { throw "Another mutation is in progress. Wait for it to finish." }
}

function Start-ControlNgrokSwitch($Client, $Payload, [switch]$SavedProfile) {
    Assert-ControlMutationAvailable
    Stop-HealthRunspace
    $script:mutationInProgress = $true
    $scriptText = @'
param($CorePath, $ConfigurationPath, $PayloadJson, $DesiredJson, $Saved)
$ErrorActionPreference = "Stop"
. $CorePath
$payload = $PayloadJson | ConvertFrom-Json
$PayloadJson = $null
try {
    $outcome = Invoke-WatchdogNgrokSwitch $ConfigurationPath $payload ($DesiredJson | ConvertFrom-Json) -SavedProfile:$Saved
    [pscustomobject]@{ success=$true; outcome=$outcome } | ConvertTo-Json -Depth 30 -Compress
} catch {
    $failure = Protect-WatchdogText $_.Exception.Message
    $needsAttention = [bool]$_.Exception.Data["WatchdogRollbackNeedsAttention"]
    $currentConfig = $null
    try { $currentConfig = Read-WatchdogJson $ConfigurationPath } catch { $needsAttention = $true }
    [pscustomobject]@{ success=$false; error=$failure; config=$currentConfig; needsAttention=$needsAttention } | ConvertTo-Json -Depth 30 -Compress
} finally {
    if ($payload.PSObject.Properties["authToken"]) { $payload.authToken = $null }
}
'@
    try {
        Write-ControlHeartbeat -Force
        $script:mutationPowerShell = [PowerShell]::Create()
        [void]$script:mutationPowerShell.AddScript($scriptText).AddArgument($corePath).AddArgument($ConfigPath).AddArgument((ConvertTo-Json -InputObject $Payload -Depth 10 -Compress)).AddArgument((ConvertTo-Json -InputObject $script:state.desired -Compress)).AddArgument([bool]$SavedProfile)
        $script:mutationAsync = $script:mutationPowerShell.BeginInvoke()
        $script:mutationClient = $Client
    } catch {
        if ($script:mutationAsync) { throw }
        if ($script:mutationPowerShell) { $script:mutationPowerShell.Dispose() }
        $script:mutationPowerShell = $null
        $script:mutationInProgress = $false
        throw
    }
}

function Complete-ControlNgrokSwitch {
    if (-not $script:mutationAsync -or -not $script:mutationAsync.IsCompleted) { return }
    $status = 400
    $response = $null
    try {
        $output = $script:mutationPowerShell.EndInvoke($script:mutationAsync)
        $json = ($output | ForEach-Object { [string]$_ }) -join ""
        if (-not $json) { throw "Account switch worker returned no result; inspect configuration before retrying." }
        $completed = $json | ConvertFrom-Json
        if ($completed.success) {
            $script:config = $completed.outcome.config
            $script:settings = Get-WatchdogControlSettings $script:config
            # Keep automatic recovery excluded while adopting the transaction's verified evidence.
            Apply-HealthSnapshot $completed.outcome.snapshot
            $response = $completed.outcome.result
            $status = 200
        } else {
            if ($completed.config) {
                $script:config = $completed.config
                $script:settings = Get-WatchdogControlSettings $script:config
            }
            $script:lastHealth = $null
            $script:lastPublic = $null
            if ($completed.needsAttention) {
                $script:state.maintenanceMode = $true
                Save-WatchdogState $script:statePath $script:state
            }
            Request-ImmediatePublicProbe "ngrok_switch_failed"
            $response = @{ error=[string]$completed.error }
        }
    } catch {
        $script:state.maintenanceMode = $true
        Save-WatchdogState $script:statePath $script:state
        $response = @{ error=(Protect-WatchdogText $_.Exception.Message) }
    } finally {
        try { if ($script:mutationClient) { Write-ControlJson $script:mutationClient.GetStream() $status $response } } catch { }
        if ($script:mutationClient) { $script:mutationClient.Dispose() }
        $script:mutationPowerShell.Dispose()
        $script:mutationClient = $null
        $script:mutationPowerShell = $null
        $script:mutationAsync = $null
        Exit-StackOperation $script:stackMutationLease; $script:stackMutationLease = $null
        $script:mutationInProgress = $false
        $script:lastHealthStarted = [DateTimeOffset]::MinValue
    }
}

function Write-ControlHeartbeat([switch]$Force) {
    $now = [DateTimeOffset]::UtcNow
    if (-not $Force -and ($now - $script:lastHeartbeat).TotalSeconds -lt 3) { return }
    Write-WatchdogAtomicJson $script:heartbeatPath ([pscustomobject]@{
        pid=$PID; timestamp=(ConvertTo-WatchdogIso $now)
        processStartUtc=(ConvertTo-WatchdogIso ([DateTimeOffset][System.Diagnostics.Process]::GetCurrentProcess().StartTime))
        dashboard="http://127.0.0.1:$($script:settings.dashboardPort)/"; status=(Get-OverallTrayState).label
        role=$(if ($isHostMode) { "host" } else { "tray" })
        sessionId=[System.Diagnostics.Process]::GetCurrentProcess().SessionId
        mutationInProgress=[bool]$script:mutationInProgress
    }) 5
    $script:lastHeartbeat = $now
}

function Wait-ControlMutationDrain {
    $script:shutdownRequested = $true
    while ($script:mutationAsync) {
        # An account transaction must finish its rollback; cancelling its pipeline is unsafe.
        Start-Sleep -Milliseconds 100
        Complete-ControlNgrokSwitch
        Complete-StackManagementProxies
        try { Write-ControlHeartbeat } catch { }
    }
}

function Read-LoopbackHttpRequest($Client) {
    if (-not [System.Net.IPAddress]::IsLoopback($Client.Client.RemoteEndPoint.Address)) { throw "Remote client is not loopback." }
    $Client.ReceiveTimeout = 750
    $Client.SendTimeout = 750
    $stream = $Client.GetStream()
    $headerBytes = New-Object System.Collections.Generic.List[byte]
    $matched = 0
    $terminator = @(13,10,13,10)
    while ($headerBytes.Count -lt 16384 -and $matched -lt 4) {
        $value = $stream.ReadByte()
        if ($value -lt 0) { throw "Connection closed before HTTP headers completed." }
        $headerBytes.Add([byte]$value)
        if ($value -eq $terminator[$matched]) { $matched++ } elseif ($value -eq 13) { $matched = 1 } else { $matched = 0 }
    }
    if ($matched -ne 4) { throw "HTTP headers are too large." }
    $headerText = [System.Text.Encoding]::ASCII.GetString($headerBytes.ToArray(), 0, $headerBytes.Count - 4)
    $lines = $headerText -split "`r`n"
    $requestParts = $lines[0] -split " "
    if ($requestParts.Count -ne 3 -or $requestParts[2] -notin @("HTTP/1.0", "HTTP/1.1")) { throw "Malformed HTTP request line." }
    $headers = @{}
    foreach ($line in $lines | Select-Object -Skip 1) {
        $separator = $line.IndexOf(":")
        if ($separator -le 0) { throw "Malformed HTTP header." }
        $name = $line.Substring(0, $separator).Trim().ToLowerInvariant()
        $value = $line.Substring($separator + 1).Trim()
        if ($name -notmatch '^[a-z0-9-]+$' -or $headers.ContainsKey($name)) { throw "Duplicate or invalid HTTP header." }
        $headers[$name] = $value
    }
    $contentLength = 0
    if ($headers.ContainsKey("content-length")) {
        if (-not [int]::TryParse($headers["content-length"], [ref]$contentLength) -or $contentLength -lt 0 -or $contentLength -gt 65536) { throw "Invalid HTTP content length." }
    }
    if ($headers.ContainsKey("transfer-encoding")) { throw "Transfer-Encoding is not supported." }
    $bodyBytes = New-Object byte[] $contentLength
    $offset = 0
    while ($offset -lt $contentLength) {
        $read = $stream.Read($bodyBytes, $offset, $contentLength - $offset)
        if ($read -le 0) { throw "Connection closed before HTTP body completed." }
        $offset += $read
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $body = if ($contentLength) { $utf8.GetString($bodyBytes) } else { "" }
    return [pscustomobject]@{ method=$requestParts[0]; path=$requestParts[1]; headers=$headers; body=$body; stream=$stream; client=$Client }
}

function Write-LoopbackHttpResponse($Stream, [int]$Status, [string]$ContentType, [string]$Body) {
    $reason = switch ($Status) { 200 { "OK" } 202 { "Accepted" } 503 { "Service Unavailable" } 400 { "Bad Request" } 403 { "Forbidden" } 404 { "Not Found" } 405 { "Method Not Allowed" } 409 { "Conflict" } 500 { "Internal Server Error" } default { "Error" } }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $headers = "HTTP/1.1 $Status $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`nX-Frame-Options: DENY`r`nContent-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Write-ControlJson($Stream, [int]$Status, $Value) {
    Write-LoopbackHttpResponse $Stream $Status "application/json; charset=utf-8" (ConvertTo-Json -InputObject $Value -Depth 30 -Compress)
}

function Invoke-SetupDashboardLaunch {
    $nodePath = [string](Get-WatchdogProperty $script:config "nodePath" "")
    $cliPath = [string](Get-WatchdogProperty $script:config "cliPath" "")
    if (-not $nodePath -or -not [System.IO.File]::Exists($nodePath)) { throw "Configured Node runtime is missing." }
    $packageRoot = [string](Get-WatchdogProperty $script:config 'managementPackageRoot' '')
    if (-not $packageRoot) {
        if (-not $cliPath -or -not [System.IO.File]::Exists($cliPath)) { throw "Configured DevSpace CLI path is missing." }
        $packageRoot = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $cliPath -Parent) ".."))
    }
    $setupScript = Join-Path $packageRoot "scripts\windows\devspace-stack-setup.cjs"
    if (-not [System.IO.File]::Exists($setupScript)) { throw "This DevSpace package does not include the Setup Dashboard. Update the npm/GitHub package first." }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $nodePath
    $psi.Arguments = ((@($setupScript, "--install-dir", (Split-Path $ConfigPath -Parent)) | ForEach-Object { ConvertTo-WatchdogNativeArgument $_ }) -join " ")
    $psi.WorkingDirectory = $packageRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process = [System.Diagnostics.Process]::Start($psi)
    if (-not $process) { throw "Setup Dashboard process did not start." }
    $pid = $process.Id
    $process.Dispose()
    Write-WatchdogEvent $script:stateDir $script:config "setup" "launch" "user request" "open setup dashboard" "pid=$pid"
    return [pscustomobject]@{ success=$true; pid=$pid }
}

function Assert-ControlMutation($Request) {
    $expectedOrigin = "http://127.0.0.1:$($script:settings.dashboardPort)"
    if ($Request.method -ne "POST") { throw "Mutation requires POST." }
    if ([string]$Request.headers["host"] -ne "127.0.0.1:$($script:settings.dashboardPort)") { throw "Invalid Host header." }
    if ([string]$Request.headers["origin"] -ne $expectedOrigin) { throw "Invalid Origin header." }
    if (-not (Test-ControlToken ([string]$Request.headers["x-devspace-control-token"]) $script:controlToken)) { throw "Invalid control token." }
    if ([string]$Request.headers["content-type"] -notmatch '^application/json(?:;|$)') { throw "Mutation requires JSON." }
}

function Invoke-ControlHttpRequest($Request) {
    $expectedHost = "127.0.0.1:$($script:settings.dashboardPort)"
    if ([string]$Request.headers["host"] -ne $expectedHost) { Write-ControlJson $Request.stream 403 @{ error="Invalid Host header." }; return }
    if ($Request.method -eq "GET" -and $Request.path -eq "/") {
        Write-LoopbackHttpResponse $Request.stream 200 "text/html; charset=utf-8" $script:dashboardHtml
        return
    }
    if ($Request.method -eq "GET" -and $Request.path -eq "/api/status") { Write-ControlJson $Request.stream 200 (Get-ControlStatusPayload); return }
    if ($Request.method -eq "GET" -and $Request.path -eq "/api/history") { Write-ControlJson $Request.stream 200 @(Get-WatchdogEventHistory $script:stateDir $script:config 250); return }
    if ($Request.method -eq "GET" -and $Request.path -eq "/api/backups") { Write-ControlJson $Request.stream 200 @(Get-WatchdogConfigurationBackups $script:stateDir); return }
    if ($Request.method -eq "GET" -and $Request.path -eq "/api/ngrok/profiles") { Write-ControlJson $Request.stream 200 @(Get-WatchdogNgrokProfiles $script:config); return }
    if ($Request.method -eq "GET" -and ($Request.path -eq "/api/components" -or $Request.path -match '^/api/job\?id=[a-f0-9]{24}$')) { return (Start-StackManagementProxy $Request) }
    if ($Request.method -ne "POST") { Write-ControlJson $Request.stream 404 @{ error="Not found." }; return }
    try {
        Assert-ControlMutation $Request
        if ($Request.path -in @("/api/components/refresh", "/api/components/action")) {
            if ($script:mutationInProgress -or $script:shutdownRequested) { Write-ControlJson $Request.stream 409 @{error="Watchdog is busy or stopping."}; return }
            return (Start-StackManagementProxy $Request)
        }
        $requestLease = if ($Request.path -ne "/api/setup/launch") { Enter-StackOperation -InstallDir $script:stackInstallDir } else { $null }
        if ($script:mutationInProgress -or $script:shutdownRequested) {
            Write-ControlJson $Request.stream 409 @{ error="Watchdog is busy or stopping. Wait for the current operation to finish." }
            return
        }
        $payload = if ($Request.body) { $Request.body | ConvertFrom-Json } else { [pscustomobject]@{} }
        switch ($Request.path) {
            "/api/action" {
                $action = [string](Get-WatchdogProperty $payload "action" "")
                $service = [string](Get-WatchdogProperty $payload "service" "")
                $confirmation = [string](Get-WatchdogProperty $payload "confirmation" "")
                if ($service -eq "all" -and $action -eq "stop" -and $confirmation -ne "STOP ALL") { throw "STOP ALL confirmation is required." }
                if ($service -eq "all" -and $action -eq "restart" -and $confirmation -ne "RESTART ALL") { throw "RESTART ALL confirmation is required." }
                Write-ControlJson $Request.stream 200 (Invoke-ManualServiceAction $action $service)
            }
            "/api/optional/repair" {
                $tool = [string](Get-WatchdogProperty $payload "tool" "")
                Write-ControlJson $Request.stream 200 (Invoke-OptionalToolRepair $tool)
            }
            "/api/setup/launch" {
                Write-ControlJson $Request.stream 200 (Invoke-SetupDashboardLaunch)
            }
            "/api/ngrok/switch" {
                Start-ControlNgrokSwitch $Request.client $payload
                $script:stackMutationLease = $requestLease; $requestLease = $null
                return $true
            }
            "/api/ngrok/profile/save" {
                Write-ControlJson $Request.stream 200 (Save-WatchdogNgrokProfile $script:config $payload)
            }
            "/api/ngrok/profile/delete" {
                if ([string](Get-WatchdogProperty $payload "confirmation" "") -ne "DELETE NGROK PROFILE") { throw "DELETE NGROK PROFILE confirmation is required." }
                Write-ControlJson $Request.stream 200 (Remove-WatchdogNgrokProfile $script:config ([string](Get-WatchdogProperty $payload "id" "")))
            }
            "/api/ngrok/profile/switch" {
                Start-ControlNgrokSwitch $Request.client $payload -SavedProfile
                $script:stackMutationLease = $requestLease; $requestLease = $null
                return $true
            }
            "/api/config/preview" {
                $editable = ConvertTo-WatchdogEditableConfig (Get-WatchdogProperty $payload "config" $null) $script:config
                Write-ControlJson $Request.stream 200 (New-WatchdogConfigImpact $script:config $editable)
            }
            "/api/config/apply" {
                if ([string](Get-WatchdogProperty $payload "confirmation" "") -ne "APPLY") { throw "APPLY confirmation is required." }
                $result = Invoke-ConfigApply (Get-WatchdogProperty $payload "config" $null)
                Write-ControlJson $Request.stream 200 @{ success=$true; impact=$result.impact; backupId=$result.backup.id }
            }
            "/api/config/rollback" {
                if ([string](Get-WatchdogProperty $payload "confirmation" "") -ne "ROLLBACK") { throw "ROLLBACK confirmation is required." }
                $restored = Invoke-ConfigRollback ([string](Get-WatchdogProperty $payload "backupId" ""))
                Write-ControlJson $Request.stream 200 @{ success=$true; restored=$restored.restored }
            }
            default { Write-ControlJson $Request.stream 404 @{ error="Not found." } }
        }
    } catch {
        Write-ControlJson $Request.stream 400 @{ error=(Protect-WatchdogText $_.Exception.Message) }
    } finally { Exit-StackOperation $requestLease }
}

function Invoke-PendingDashboardRequest {
    if (-not $script:listener.Pending()) { return }
    $client = $script:listener.AcceptTcpClient()
    $deferred = $false
    try {
        try { $request = Read-LoopbackHttpRequest $client; $deferred = [bool](Invoke-ControlHttpRequest $request) }
        catch { try { Write-ControlJson $client.GetStream() 400 @{ error=(Protect-WatchdogText $_.Exception.Message) } } catch { } }
    } finally { if (-not $deferred) { $client.Dispose() } }
}

function Start-ControlShellTarget([string]$Executable, [string[]]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.Arguments = (@($Arguments) | ForEach-Object { ConvertTo-WatchdogNativeArgument ([string]$_) }) -join " "
    $process = [System.Diagnostics.Process]::Start($psi)
    if ($process) { $process.Dispose() }
}

function Open-ControlDashboard {
    $url = "http://127.0.0.1:$($script:settings.dashboardPort)/"
    Start-ControlShellTarget (Join-Path $env:WINDIR "System32\rundll32.exe") @("url.dll,FileProtocolHandler", $url)
}

function Open-ControlLogs {
    Start-ControlShellTarget (Join-Path $env:WINDIR "explorer.exe") @($script:stateDir)
}

if (-not [System.IO.File]::Exists($script:templatePath)) { throw "Dashboard template is missing: $($script:templatePath)" }
$script:dashboardHtml = ([System.IO.File]::ReadAllText($script:templatePath, [System.Text.Encoding]::UTF8)).Replace("{{CONTROL_TOKEN}}", $script:controlToken).Replace("{{DASHBOARD_PORT}}", [string]$script:settings.dashboardPort)
$script:listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $script:settings.dashboardPort)
$script:listener.Start(16)
if (-not [DevSpaceTrayNative]::SetHandleInformation($script:listener.Server.Handle, 1, 0)) {
    throw "Dashboard listener handle could not be marked non-inheritable."
}

if ($Mode -eq "Host") {
    Write-WatchdogEvent $script:stateDir $script:config "host" "start" "Windows login or launcher" "monitor" "dashboard 127.0.0.1:$($script:settings.dashboardPort)"
    try {
        Start-HealthRunspace -IncludePublic:(Test-PublicProbeDue ([DateTimeOffset]::UtcNow))
        while ($true) {
            if ($stopEvent.WaitOne(100)) { $script:shutdownRequested = $true }
            try {
                Complete-ControlNgrokSwitch
                Complete-StackManagementProxies
                if ($script:shutdownRequested -and -not $script:mutationInProgress) { break }
                $handled = 0
                while ($handled -lt 8 -and $script:listener.Pending()) {
                    Invoke-PendingDashboardRequest
                    $handled++
                }
                if ($script:healthAsync -and -not $script:healthAsync.IsCompleted -and ([DateTimeOffset]::UtcNow - $script:lastHealthStarted).TotalSeconds -ge 45) {
                    $timedOutPublic = [bool]$script:healthIncludedPublic
                    Stop-HealthRunspace
                    if ($timedOutPublic) { Update-PublicProbeSchedule $null $false }
                    Write-WatchdogEvent $script:stateDir $script:config "host" "health_cycle_timeout" "Health evidence did not complete within 45 seconds." "cancel stale probe" $(if ($timedOutPublic) { "public backoff scheduled" } else { "monitoring retained" })
                }
                Complete-HealthRunspace
                $now = [DateTimeOffset]::UtcNow
                if (-not $script:healthAsync -and ($now - $script:lastHealthStarted).TotalSeconds -ge $script:settings.localProbeSeconds) {
                    $includePublic = Test-PublicProbeDue $now
                    Start-HealthRunspace -IncludePublic:$includePublic
                }
                Write-ControlHeartbeat
            } catch {
                $timerError = Protect-WatchdogText $_.Exception.Message
                if ($timerError -ne $script:lastTimerError -or ([DateTimeOffset]::UtcNow - $script:lastTimerErrorAt).TotalSeconds -ge 30) {
                    try { Write-WatchdogEvent $script:stateDir $script:config "host" "loop_error" $timerError "continue" "monitoring retained" } catch { }
                    $script:lastTimerError = $timerError
                    $script:lastTimerErrorAt = [DateTimeOffset]::UtcNow
                }
            }
        }
    } finally {
        Wait-ControlMutationDrain
        Write-WatchdogEvent $script:stateDir $script:config "host" "exit" "stop event" "stop monitoring host" "managed services left unchanged"
        Stop-HealthRunspace
        try { $script:listener.Stop() } catch { }
        if ([System.IO.File]::Exists($script:heartbeatPath)) { [System.IO.File]::Delete($script:heartbeatPath) }
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
        $stopEvent.Dispose()
    }
    exit 0
}

$script:icons = @{
    GREEN = New-TrayCircleIcon ([System.Drawing.Color]::FromArgb(40, 180, 99))
    YELLOW = New-TrayCircleIcon ([System.Drawing.Color]::FromArgb(244, 180, 0))
    RED = New-TrayCircleIcon ([System.Drawing.Color]::FromArgb(220, 53, 69))
    GRAY = New-TrayCircleIcon ([System.Drawing.Color]::FromArgb(125, 133, 144))
}
$notify = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$openItem = $menu.Items.Add("Open Dashboard")
$statusItem = New-Object System.Windows.Forms.ToolStripMenuItem("Status: Checking")
$statusItem.Enabled = $false
[void]$menu.Items.Add($statusItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$startAllItem = $menu.Items.Add("Start All")
$stopAllItem = $menu.Items.Add("Stop All")
$restartAllItem = $menu.Items.Add("Restart All")
$servicesMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Services")
$script:serviceMenuItems = @{}
foreach ($service in $script:WatchdogServiceNames) {
    $serviceMenu = New-Object System.Windows.Forms.ToolStripMenuItem((Get-Culture).TextInfo.ToTitleCase($service))
    $stateItem = New-Object System.Windows.Forms.ToolStripMenuItem("Checking")
    $stateItem.Enabled = $false
    [void]$serviceMenu.DropDownItems.Add($stateItem)
    $startItem = $serviceMenu.DropDownItems.Add("Start")
    $stopItem = $serviceMenu.DropDownItems.Add("Stop")
    $restartItem = $serviceMenu.DropDownItems.Add("Restart")
    $startItem.add_Click(({ [void](Invoke-ManualServiceAction "start" $service) }).GetNewClosure())
    $stopItem.add_Click(({ [void](Invoke-ManualServiceAction "stop" $service) }).GetNewClosure())
    $restartItem.add_Click(({ [void](Invoke-ManualServiceAction "restart" $service) }).GetNewClosure())
    $script:serviceMenuItems[$service] = @{ state=$stateItem; start=$startItem; stop=$stopItem; restart=$restartItem; menu=$serviceMenu }
    [void]$servicesMenu.DropDownItems.Add($serviceMenu)
}
[void]$menu.Items.Add($servicesMenu)
$optionalMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Optional tools")
$codexStateItem = New-Object System.Windows.Forms.ToolStripMenuItem("Codex: Not detected")
$codexStateItem.Enabled = $false
$officialC2cItem = New-Object System.Windows.Forms.ToolStripMenuItem("Official C2C: Not detected")
$officialC2cItem.Enabled = $false
$tyoC2cItem = New-Object System.Windows.Forms.ToolStripMenuItem("TYO C2C: Not detected")
$tyoC2cItem.Enabled = $false
$openCodexStateItem = New-Object System.Windows.Forms.ToolStripMenuItem("OpenCodex: Not detected")
$openCodexStateItem.Enabled = $false
$repairOpenCodexTrayItem = New-Object System.Windows.Forms.ToolStripMenuItem("Repair OpenCodex Tray")
[void]$optionalMenu.DropDownItems.Add($codexStateItem)
[void]$optionalMenu.DropDownItems.Add($officialC2cItem)
[void]$optionalMenu.DropDownItems.Add($tyoC2cItem)
[void]$optionalMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$optionalMenu.DropDownItems.Add($openCodexStateItem)
[void]$optionalMenu.DropDownItems.Add($repairOpenCodexTrayItem)
$optionalMenu.Visible = $false
[void]$menu.Items.Add($optionalMenu)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$maintenanceItem = $menu.Items.Add("Maintenance Mode")
$resumeItem = $menu.Items.Add("Resume Auto Recovery")
$logsItem = $menu.Items.Add("Open Logs")
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$exitItem = $menu.Items.Add("Exit Tray")

$openItem.add_Click({ Open-ControlDashboard })
$notify.add_DoubleClick({ Open-ControlDashboard })
$startAllItem.add_Click({ [void](Invoke-ManualServiceAction "start" "all") })
$stopAllItem.add_Click({
    if ([System.Windows.Forms.MessageBox]::Show("Stop DevSpace, Hermes, Router, and ngrok and persist STOPPED_BY_USER?", "DevSpace Watchdog", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning) -eq [System.Windows.Forms.DialogResult]::Yes) {
        [void](Invoke-ManualServiceAction "stop" "all")
    }
})
$restartAllItem.add_Click({
    if ([System.Windows.Forms.MessageBox]::Show("Restart all managed services? Active MCP calls can be interrupted.", "DevSpace Watchdog", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning) -eq [System.Windows.Forms.DialogResult]::Yes) {
        [void](Invoke-ManualServiceAction "restart" "all")
    }
})
$repairOpenCodexTrayItem.add_Click({
    $result = Invoke-OptionalToolRepair "opencodex-tray"
    if (-not $result.success) {
        [void][System.Windows.Forms.MessageBox]::Show($result.error, "Optional tool repair", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
})
$maintenanceItem.add_Click({ [void](Invoke-ManualServiceAction "maintenance" "all") })
$resumeItem.add_Click({ [void](Invoke-ManualServiceAction "resume" "all") })
$logsItem.add_Click({ Open-ControlLogs })
$exitItem.add_Click({ $script:shutdownRequested = $true })

function Update-TrayPresentation {
    $overall = Get-OverallTrayState
    $notify.Icon = $script:icons[$overall.color]
    $notify.Text = "DevSpace Watchdog - $($overall.label)"
    $statusItem.Text = "Status: $($overall.label)"
    $available = -not $script:mutationInProgress -and -not $script:shutdownRequested
    $maintenanceItem.Enabled = $available -and -not $script:state.maintenanceMode
    $resumeItem.Enabled = $available -and [bool]$script:state.maintenanceMode
    $startAllItem.Enabled = $available
    $stopAllItem.Enabled = $available
    $restartAllItem.Enabled = $available
    $tools = Get-WatchdogProperty $script:lastHealth "optionalTools" $null
    $codex = Get-WatchdogProperty $tools "codex" $null
    $openCodex = Get-WatchdogProperty $tools "openCodex" $null
    $codexVisible = [bool](Get-WatchdogProperty $codex "visible" $false)
    $openCodexVisible = [bool](Get-WatchdogProperty $openCodex "visible" $false)
    $optionalMenu.Visible = $codexVisible -or $openCodexVisible
    if ($codexVisible) {
        $codexStateItem.Text = "Codex: " + $(if ([bool](Get-WatchdogProperty $codex "running" $false)) { "Running" } else { "Installed" })
        $officialC2cItem.Visible = $true
        $officialC2cItem.Text = "Official C2C: " + $(if ([bool](Get-WatchdogProperty $codex "officialC2c" $false)) { "Available" } else { "Not installed" })
        $tyoC2cItem.Visible = $true
        $tyoC2cItem.Text = "TYO C2C: " + $(if ([bool](Get-WatchdogProperty $codex "tyoC2c" $false)) { "Available" } else { "Not installed" })
    } else {
        $codexStateItem.Text = "Codex: Not detected"
        $officialC2cItem.Visible = $false
        $tyoC2cItem.Visible = $false
    }
    $openCodexStateItem.Visible = $openCodexVisible
    $repairOpenCodexTrayItem.Visible = $openCodexVisible
    if ($openCodexVisible) {
        $proxyText = if ([bool](Get-WatchdogProperty $openCodex "proxyHealthy" $false)) { "Proxy OK" } elseif ([bool](Get-WatchdogProperty $openCodex "proxyRunning" $false)) { "Proxy degraded" } else { "Proxy stopped" }
        $trayText = if ([bool](Get-WatchdogProperty $openCodex "trayRunning" $false)) { "Tray OK" } elseif ([bool](Get-WatchdogProperty $openCodex "trayInstalled" $false)) { "Tray stopped" } else { "No Tray" }
        $openCodexStateItem.Text = "OpenCodex: $proxyText / $trayText"
        $repairOpenCodexTrayItem.Enabled = $available -and [bool](Get-WatchdogProperty $openCodex "repairTrayAvailable" $false)
    }
    foreach ($service in $script:WatchdogServiceNames) {
        $item = $script:serviceMenuItems[$service]
        $enabled = Test-WatchdogServiceEnabled $service $script:config
        $desired = [string](Get-WatchdogProperty $script:state.desired $service "running")
        $health = Get-ServiceFromSnapshot $service
        $record = Get-WatchdogProperty $script:state.recovery $service $null
        $item.menu.Enabled = $available -and $enabled
        $item.state.Text = if (-not $enabled) { "Disabled" } elseif ($desired -eq "stopped_by_user") { "Stopped by user" } elseif ($health -and $health.healthy) { "Healthy" } else { [string](Get-WatchdogProperty $record "phase" "Checking") }
        $item.start.Enabled = $enabled -and $desired -eq "stopped_by_user"
        $item.stop.Enabled = $enabled -and $desired -eq "running"
        $item.restart.Enabled = $enabled -and $desired -eq "running"
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.add_Tick({
    try {
        if ($stopEvent.WaitOne(0)) { $script:shutdownRequested = $true }
        Complete-ControlNgrokSwitch
        Complete-StackManagementProxies
        if ($script:shutdownRequested -and -not $script:mutationInProgress) { [System.Windows.Forms.Application]::Exit(); return }
        if ($script:listener.Pending()) { Invoke-PendingDashboardRequest }
        if ($script:healthAsync -and -not $script:healthAsync.IsCompleted -and ([DateTimeOffset]::UtcNow - $script:lastHealthStarted).TotalSeconds -ge 45) {
            $timedOutPublic = [bool]$script:healthIncludedPublic
            Stop-HealthRunspace
            if ($timedOutPublic) { Update-PublicProbeSchedule $null $false }
            Write-WatchdogEvent $script:stateDir $script:config "tray" "health_cycle_timeout" "Health evidence did not complete within 45 seconds." "cancel stale probe" $(if ($timedOutPublic) { "public backoff scheduled" } else { "monitoring retained" })
        }
        Complete-HealthRunspace
        $now = [DateTimeOffset]::UtcNow
        if (-not $script:healthAsync -and ($now - $script:lastHealthStarted).TotalSeconds -ge $script:settings.localProbeSeconds) {
            $includePublic = Test-PublicProbeDue $now
            Start-HealthRunspace -IncludePublic:$includePublic
        }
        Write-ControlHeartbeat
        Update-TrayPresentation
    } catch {
        $timerError = Protect-WatchdogText $_.Exception.Message
        if ($timerError -ne $script:lastTimerError -or ([DateTimeOffset]::UtcNow - $script:lastTimerErrorAt).TotalSeconds -ge 30) {
            try { Write-WatchdogEvent $script:stateDir $script:config "tray" "timer_error" $timerError "continue" "monitoring retained" } catch { }
            $script:lastTimerError = $timerError
            $script:lastTimerErrorAt = [DateTimeOffset]::UtcNow
        }
    }
})

$notify.ContextMenuStrip = $menu
$notify.Icon = $script:icons.YELLOW
$notify.Visible = $true
$notify.Text = "DevSpace Watchdog - Checking"
Write-WatchdogEvent $script:stateDir $script:config "tray" "start" "Windows login or manual launch" "monitor" "dashboard 127.0.0.1:$($script:settings.dashboardPort)"

try {
    Start-HealthRunspace -IncludePublic:(Test-PublicProbeDue ([DateTimeOffset]::UtcNow))
    $timer.Start()
    [System.Windows.Forms.Application]::Run()
} finally {
    Wait-ControlMutationDrain
    Write-WatchdogEvent $script:stateDir $script:config "tray" "exit" "Exit Tray" "stop monitoring UI" "managed services left unchanged"
    $timer.Stop(); $timer.Dispose()
    Stop-HealthRunspace
    $script:listener.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    $menu.Dispose()
    foreach ($icon in $script:icons.Values) { $icon.Dispose() }
    if ([System.IO.File]::Exists($script:heartbeatPath)) { [System.IO.File]::Delete($script:heartbeatPath) }
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
    $stopEvent.Dispose()
}
