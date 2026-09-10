[CmdletBinding()]
param(
    [string]$InstallDir = "$env:USERPROFILE\.devspace",
    [string]$SourceDir = $PSScriptRoot,
    [string]$ExpectedMachineSlug = "",
    [int]$StartupTimeoutSeconds = 30,
    [switch]$AllowHermesBusyTransport,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$SourceDir = [IO.Path]::GetFullPath($SourceDir)
if ($StartupTimeoutSeconds -lt 10 -or $StartupTimeoutSeconds -gt 60) { throw 'StartupTimeoutSeconds must be from 10 through 60.' }

$payloadFiles = @(
    'watchdog-control-core.ps1',
    'stack-operation.ps1',
    'stack-host-management.ps1',
    'watchdog-install-transaction.ps1',
    'devspace-watchdog-tray.ps1',
    'devspace-watchdog-tray-ui.ps1',
    'devspace-watchdog-bootstrap.ps1',
    'devspace-control-center.html',
    'run-devspace-watchdog-tray-hidden.vbs',
    'uninstall-devspace-watchdog-tray.ps1',
    'restore-old-watchdog.ps1'
)
$backendFiles = @('devspace-watchdog.ps1','mcp-router.cjs')
$allFiles = @($payloadFiles + $backendFiles)
$configPath = Join-Path $InstallDir 'devspace-watchdog.config.json'
$recordPath = Join-Path $InstallDir 'watchdog-tray-install.json'

foreach ($name in @('watchdog-control-core.ps1','watchdog-install-transaction.ps1','stack-operation.ps1','devspace-watchdog-bootstrap.ps1')) {
    $required = Join-Path $SourceDir $name
    if (-not [IO.File]::Exists($required)) { throw "Update source is incomplete: $required" }
}
. (Join-Path $SourceDir 'watchdog-control-core.ps1')
. (Join-Path $SourceDir 'watchdog-install-transaction.ps1')
. (Join-Path $SourceDir 'stack-operation.ps1')

function Assert-UpdatePowerShellSyntax([string]$Path) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "PowerShell syntax validation failed for $Path`: $($errors[0].Message)" }
}
function Test-UpdateContentEqual([string]$Left, [string]$Right) {
    if ((Get-WatchdogFileSha256 $Left) -eq (Get-WatchdogFileSha256 $Right)) { return $true }
    try {
        $leftText = [IO.File]::ReadAllText($Left, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
        $rightText = [IO.File]::ReadAllText($Right, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
        return $leftText -ceq $rightText
    } catch { return $false }
}
function Copy-UpdateFile([string]$Source, [string]$Destination) {
    $temporary = "$Destination.update-$PID-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    try {
        [IO.File]::Copy($Source, $temporary, $true)
        $sourceHash = Get-WatchdogFileSha256 $Source
        if ((Get-WatchdogFileSha256 $temporary) -ne $sourceHash) { throw "Staged file hash mismatch: $Source" }
        $lastError = ''
        for ($attempt = 0; $attempt -lt 25; $attempt++) {
            try {
                [IO.File]::Copy($temporary, $Destination, $true)
                $lastError = ''
                break
            } catch [IO.IOException] { $lastError = $_.Exception.Message }
            catch [UnauthorizedAccessException] { $lastError = $_.Exception.Message }
            Start-Sleep -Milliseconds 200
        }
        if ($lastError) { throw "Could not replace $Destination after retrying transient locks: $lastError" }
        if ((Get-WatchdogFileSha256 $Destination) -ne $sourceHash) { throw "Installed file hash mismatch after copy: $Destination" }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Read-UpdateHeartbeat([string]$Name) {
    $path = Join-Path $InstallDir $Name
    if (-not [IO.File]::Exists($path)) { return $null }
    try { return Read-WatchdogJson $path } catch { return $null }
}
function Test-UpdateHeartbeat([string]$Name, [string]$Role) {
    $heartbeat = Read-UpdateHeartbeat $Name
    if (-not $heartbeat -or [string]$heartbeat.role -ne $Role) { return $false }
    $stamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$heartbeat.timestamp, [ref]$stamp)) { return $false }
    if (([DateTimeOffset]::UtcNow - $stamp.ToUniversalTime()).TotalSeconds -gt 15) { return $false }
    return [bool](Get-Process -Id ([int]$heartbeat.pid) -ErrorAction SilentlyContinue)
}
function Wait-UpdateRolesReady([int]$DashboardPort) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    do {
        $hostReady = Test-UpdateHeartbeat 'watchdog-host-heartbeat.json' 'host'
        $trayReady = Test-UpdateHeartbeat 'watchdog-tray-heartbeat.json' 'tray-ui'
        $dashboardReady = $false
        if ($hostReady) {
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$DashboardPort/api/status" -TimeoutSec 2
                $dashboardReady = [int]$response.StatusCode -eq 200
            } catch { }
        }
        if ($hostReady -and $trayReady -and $dashboardReady) { return $true }
        Start-Sleep -Milliseconds 300
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    return $false
}
function Test-UpdateServiceAcceptable([string]$Name, $Service) {
    if (-not $Service -or -not $Service.enabled) { return $true }
    if ($Service.identityConflict) { return $false }
    if ($Service.healthy) { return $true }
    if ($Name -eq 'hermes' -and $AllowHermesBusyTransport -and $Service.processFound -and $Service.listenerFound -and $Service.busyIndeterminate) { return $true }
    return $false
}
function Assert-UpdateServiceHealth($Snapshot) {
    if (-not $Snapshot -or -not $Snapshot.services) { throw 'Watchdog health snapshot is unavailable; refusing runtime payload update.' }
    foreach ($name in @('devspace','hermes','router','ngrok')) {
        $service = Get-WatchdogProperty $Snapshot.services $name $null
        if (-not (Test-UpdateServiceAcceptable $name $service)) { throw "$name is not healthy or has an identity conflict; refusing runtime payload update." }
    }
}
function Get-UpdateStableHealth([int]$Attempts = 8, [int]$DelayMilliseconds = 750) {
    $consecutiveHealthy = 0
    $lastSnapshot = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try { $lastSnapshot = Get-WatchdogHealthSnapshot $configPath } catch { $lastSnapshot = $null }
        if ($lastSnapshot -and $lastSnapshot.services) {
            $identityConflict = @('devspace','hermes','router','ngrok' | Where-Object {
                $service = Get-WatchdogProperty $lastSnapshot.services $_ $null
                $service -and $service.enabled -and $service.identityConflict
            })
            if ($identityConflict.Count) { throw "Identity conflict detected for $($identityConflict -join ', '); refusing runtime payload update." }
            $unhealthy = @('devspace','hermes','router','ngrok' | Where-Object {
                $service = Get-WatchdogProperty $lastSnapshot.services $_ $null
                -not (Test-UpdateServiceAcceptable $_ $service)
            })
            if (-not $unhealthy.Count) {
                $consecutiveHealthy++
                if ($consecutiveHealthy -ge 2) { return $lastSnapshot }
            } else { $consecutiveHealthy = 0 }
        } else { $consecutiveHealthy = 0 }
        if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds $DelayMilliseconds }
    }
    Assert-UpdateServiceHealth $lastSnapshot
    throw 'Watchdog services did not remain healthy for two consecutive preflight checks.'
}

if (-not [IO.File]::Exists($configPath) -or -not [IO.File]::Exists($recordPath)) { throw 'This updater requires an existing verified Watchdog Tray installation.' }
foreach ($name in $allFiles) {
    $source = Join-Path $SourceDir $name
    if (-not [IO.File]::Exists($source)) { throw "Update source is missing: $source" }
    if ([IO.Path]::GetExtension($source) -eq '.ps1') { Assert-UpdatePowerShellSyntax $source }
}
$config = Read-WatchdogJson $configPath
if ([IO.Path]::GetFullPath([string]$config.stateDir) -ne $InstallDir) { throw 'Watchdog stateDir does not match InstallDir.' }
if ($ExpectedMachineSlug -and [string]$config.machineSlug -cne $ExpectedMachineSlug) { throw "Machine slug mismatch: expected $ExpectedMachineSlug, found $($config.machineSlug)." }
$record = Read-WatchdogJson $recordPath
if ([IO.Path]::GetFullPath([string]$record.installDir) -ne $InstallDir) { throw 'Tray install record belongs to another installation directory.' }
$supervisorSpec = Get-InstallSupervisorTaskSpec $InstallDir
$supervisorTask = Get-ScheduledTask -TaskName $supervisorSpec.name -TaskPath '\' -ErrorAction Stop
Assert-InstallSupervisorTask $supervisorTask $supervisorSpec
if ([string]$supervisorTask.State -notin @('Running','Ready')) { throw "Supervisor task is not in a usable state: $($supervisorTask.State)" }

$installedMap = @{}
foreach ($item in @($record.installedFiles)) { $installedMap[[string]$item.name] = $item }
foreach ($name in $payloadFiles) {
    if (-not $installedMap.ContainsKey($name)) { throw "Tray install record does not track $name; use the full installer instead." }
    $target = Join-Path $InstallDir $name
    if (-not [IO.File]::Exists($target)) { throw "Installed payload is missing: $target" }
    if ((Get-WatchdogFileSha256 $target) -ne [string]$installedMap[$name].sha256) { throw "Installed payload changed since the install record: $name" }
}
foreach ($name in $backendFiles) {
    if (-not [IO.File]::Exists((Join-Path $InstallDir $name))) { throw "Installed backend file is missing: $name" }
}
[void](Get-UpdateStableHealth)

$changes = @()
foreach ($name in $allFiles) {
    $source = Join-Path $SourceDir $name
    $target = Join-Path $InstallDir $name
    $sourceHash = Get-WatchdogFileSha256 $source
    $targetHash = Get-WatchdogFileSha256 $target
    if (-not (Test-UpdateContentEqual $source $target)) { $changes += [pscustomobject]@{name=$name;sourceHash=$sourceHash;targetHash=$targetHash} }
}
Write-Host "Machine: $($config.machineSlug)"
Write-Host "InstallDir: $InstallDir"
Write-Host "Changed runtime files: $($changes.Count)"
foreach ($change in $changes) { Write-Host " - $($change.name)" }
if (-not $changes.Count) { Write-Host 'Installed Watchdog runtime already matches this source.' -ForegroundColor Green; return }
if (-not $Apply) { Write-Host 'Preview only. Re-run with -Apply to update this verified installation.'; return }

$backupDir = Join-Path $InstallDir ('configuration-backups\runtime-update-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($backupDir)
$backupFiles = @()
foreach ($change in $changes) {
    $target = Join-Path $InstallDir $change.name
    $backup = Join-Path $backupDir $change.name
    [IO.File]::Copy($target, $backup, $false)
    $hash = Get-WatchdogFileSha256 $backup
    if ($hash -ne $change.targetHash) { throw "Backup hash mismatch for $($change.name)" }
    $backupFiles += [pscustomobject]@{name=$change.name;path=$backup;sha256=$hash}
}
$recordBackup = Join-Path $backupDir 'watchdog-tray-install.json'
[IO.File]::Copy($recordPath, $recordBackup, $false)
$recordBackupHash = Get-WatchdogFileSha256 $recordBackup
Write-WatchdogAtomicJson (Join-Path $backupDir 'runtime-update-manifest.json') ([pscustomobject]@{
    schemaVersion=1; createdAt=[DateTimeOffset]::UtcNow.ToString('o'); machineSlug=[string]$config.machineSlug
    sourceDir=$SourceDir; installDir=$InstallDir; files=$backupFiles; installRecordSha256=$recordBackupHash
})

$lease = $null
$rolesStopped = $false
$routerChanged = [bool]($changes.name -contains 'mcp-router.cjs')
try {
    $lease = Enter-StackOperation $InstallDir
    $sourceBootstrap = Join-Path $SourceDir 'devspace-watchdog-bootstrap.ps1'
    & $sourceBootstrap -Mode Stop -ConfigPath $configPath -RuntimeDirectory $InstallDir
    Wait-InstallSupervisorTaskStopped $InstallDir
    & $sourceBootstrap -Mode CheckStopped -ConfigPath $configPath -RuntimeDirectory $InstallDir
    $rolesStopped = $true

    foreach ($change in $changes) { Copy-UpdateFile (Join-Path $SourceDir $change.name) (Join-Path $InstallDir $change.name) }
    foreach ($name in $payloadFiles) {
        if ($changes.name -notcontains $name) { continue }
        $entry = $installedMap[$name]
        $entry.sha256 = Get-WatchdogFileSha256 (Join-Path $InstallDir $name)
    }
    Write-WatchdogAtomicJson $recordPath $record

    & (Join-Path $InstallDir 'devspace-watchdog-bootstrap.ps1') -Mode Run -ConfigPath $configPath
    Start-ScheduledTask -TaskName $supervisorSpec.name -TaskPath '\' -ErrorAction Stop
    if (-not (Wait-UpdateRolesReady ([int](Get-WatchdogControlSettings $config).dashboardPort))) { throw 'Updated Host/Tray/Supervisor did not become ready in time.' }
    $rolesStopped = $false
} catch {
    $failure = $_.Exception.Message
    try {
        if (-not $rolesStopped) {
            & (Join-Path $SourceDir 'devspace-watchdog-bootstrap.ps1') -Mode Stop -ConfigPath $configPath -RuntimeDirectory $InstallDir
            Wait-InstallSupervisorTaskStopped $InstallDir
        }
        foreach ($item in $backupFiles) {
            if ((Get-WatchdogFileSha256 $item.path) -ne [string]$item.sha256) { throw "Rollback backup hash mismatch: $($item.name)" }
            Copy-UpdateFile $item.path (Join-Path $InstallDir $item.name)
        }
        if ((Get-WatchdogFileSha256 $recordBackup) -ne $recordBackupHash) { throw 'Install-record rollback backup hash mismatch.' }
        Copy-UpdateFile $recordBackup $recordPath
        & (Join-Path $InstallDir 'devspace-watchdog-bootstrap.ps1') -Mode Run -ConfigPath $configPath
        Start-ScheduledTask -TaskName $supervisorSpec.name -TaskPath '\' -ErrorAction Stop
    } catch { throw "Runtime update failed: $failure. Rollback also needs attention: $($_.Exception.Message). Backup: $backupDir" }
    throw "Runtime update failed and payload was restored: $failure. Backup: $backupDir"
} finally { Exit-StackOperation $lease }

if ($routerChanged) {
    $liveConfig = Read-WatchdogJson $configPath
    $restart = Restart-WatchdogManagedService 'router' $configPath $liveConfig
    if (-not $restart.success) {
        throw "Runtime files were updated, but Router restart failed: $($restart.error). Backup: $backupDir"
    }
}
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSeconds)
do {
    try {
        $finalHealth = Get-WatchdogHealthSnapshot $configPath
        $unhealthy = @('devspace','hermes','router','ngrok' | Where-Object {
            $service = Get-WatchdogProperty $finalHealth.services $_ $null
            $service -and $service.enabled -and (-not $service.healthy -or $service.identityConflict)
        })
        if (-not $unhealthy.Count) { break }
    } catch { }
    Start-Sleep -Milliseconds 500
} while ([DateTimeOffset]::UtcNow -lt $deadline)
Assert-UpdateServiceHealth $finalHealth
Write-Host "Watchdog runtime update complete. Backup: $backupDir" -ForegroundColor Green
