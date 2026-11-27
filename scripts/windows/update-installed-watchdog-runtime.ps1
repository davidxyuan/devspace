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
$backendFiles = @('devspace-watchdog.ps1','devspace-watchdog-legacy.ps1','mcp-router.cjs')
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
function Test-UpdateBackendBaseline([string]$Name, [string]$Target, [string]$Actual, $Record, $Config) {
    $hashes = $Record.backendFileHashes
    if ($null -ne $hashes -and $null -ne $hashes.PSObject.Properties[$Name]) {
        return $Actual -and $Actual -ieq [string]$hashes.$Name
    }
    if (-not $Actual) { return $Name -eq 'devspace-watchdog-legacy.ps1' }
    $root = [string]$Config.managementPackageRoot
    if (-not $root -or -not [IO.Path]::IsPathRooted($root)) { return $false }
    $manifest = Join-Path $root 'oneclick-payload.json'
    if (-not [IO.File]::Exists($manifest)) { return $false }
    $relative = "scripts/windows/$Name"
    $entries = @((Read-WatchdogJson $manifest).files | Where-Object { $_.path -ceq $relative })
    if ($entries.Count -ne 1 -or [string]$entries[0].sha256 -notmatch '^[0-9a-f]{64}$') { return $false }
    $expected = [string]$entries[0].sha256
    if ($Actual -ieq $expected) { return $true }
    $original = Join-Path $root $relative
    return [IO.File]::Exists($original) -and (Get-WatchdogFileSha256 $original) -ieq $expected -and (Test-UpdateContentEqual $Target $original)
}
function Test-UpdateKasperskyEndpointSecurity {
    if (Get-Process -Name 'avp' -ErrorAction SilentlyContinue) { return $true }
    foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($root -and [IO.Directory]::Exists((Join-Path $root 'Kaspersky Lab'))) { return $true }
    }
    return $false
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
function Test-UpdateHeartbeat([string]$Name, [string]$Role, [int]$MaxAgeSeconds = 15) {
    $heartbeat = Read-UpdateHeartbeat $Name
    if (-not $heartbeat -or [string]$heartbeat.role -ne $Role) { return $false }
    $stamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$heartbeat.timestamp, [ref]$stamp)) { return $false }
    $age = ([DateTimeOffset]::UtcNow - $stamp.ToUniversalTime()).TotalSeconds
    if ($age -lt -5 -or $age -gt $MaxAgeSeconds) { return $false }
    return Test-WatchdogHeartbeatProcess $heartbeat $Role $configPath
}
function Wait-UpdateRolesReady([int]$DashboardPort) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    do {
        $hostReady = Test-UpdateHeartbeat 'watchdog-host-heartbeat.json' 'host'
        $trayReady = Test-UpdateHeartbeat 'watchdog-tray-heartbeat.json' 'tray-ui'
        $supervisorReady = Test-UpdateHeartbeat 'watchdog-supervisor-heartbeat.json' 'supervisor' 30
        $dashboardReady = $false
        if ($hostReady) {
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$DashboardPort/api/status" -TimeoutSec 2
                $dashboardReady = [int]$response.StatusCode -eq 200
            } catch { }
        }
        if ($hostReady -and $trayReady -and $supervisorReady -and $dashboardReady) { return $true }
        Start-Sleep -Milliseconds 300
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    return $false
}
function Test-UpdateServiceAcceptable([string]$Name, $Service) {
    if (-not $Service -or $Service.enabled -isnot [bool]) { return $false }
    if (-not $Service.enabled) { return $true }
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
function Wait-UpdateServiceHealth {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    do {
        try {
            $snapshot = Get-WatchdogHealthSnapshot $configPath
            Assert-UpdateServiceHealth $snapshot
            # Give an explicitly permitted busy Hermes transport time to become fully healthy.
            $hermes = Get-WatchdogProperty $snapshot.services 'hermes' $null
            if (-not $hermes.enabled -or $hermes.healthy -or [DateTimeOffset]::UtcNow -ge $deadline) { return }
        } catch {
            if ([DateTimeOffset]::UtcNow -ge $deadline) { throw }
        }
        Start-Sleep -Milliseconds 500
    } while ($true)
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

$lease = $null
try {
if ($Apply) {
    if (Test-UpdateKasperskyEndpointSecurity) {
        throw 'Kaspersky Endpoint Security is active; batch updater Apply is disabled before any file writes. Use verified file-by-file deployment plus the existing Bootstrap/Dashboard lifecycle, or an IT-approved allowlist for the exact reviewed artifact.'
    }
    if ([IO.File]::Exists((Join-Path $InstallDir 'stack-management\node-runtime-update.lock'))) {
        throw 'An older Node runtime update is running or needs recovery; inspect its lock and backup before continuing.'
    }
    # Hold the shared lease while reading the plan, taking backups and recovering.
    $lease = Enter-StackOperation $InstallDir
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
Assert-InstallSupervisorTask $supervisorTask $supervisorSpec -AllowLegacyAction
$previousSupervisorTaskXml = Export-ScheduledTask -TaskName $supervisorSpec.name -TaskPath '\' -ErrorAction Stop
$supervisorActionChanged = $false
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
    $target = Join-Path $InstallDir $name
    if (-not [IO.File]::Exists($target) -and $name -ne 'devspace-watchdog-legacy.ps1') { throw "Installed backend file is missing: $name" }
}
[void](Get-UpdateStableHealth)

$changes = @()
$backendHashes = @{}
foreach ($name in $allFiles) {
    $source = Join-Path $SourceDir $name
    $target = Join-Path $InstallDir $name
    $sourceHash = Get-WatchdogFileSha256 $source
    $targetExists = [IO.File]::Exists($target)
    $targetHash = if ($targetExists) { Get-WatchdogFileSha256 $target } else { '' }
    if (-not $targetExists -or -not (Test-UpdateContentEqual $source $target)) {
        if ($name -in $backendFiles -and -not (Test-UpdateBackendBaseline $name $target $targetHash $record $config)) {
            throw "Cannot verify installed backend against its previous version: $name. Preserve the current file and review its changes."
        }
        $changes += [pscustomobject]@{name=$name;sourceHash=$sourceHash;targetHash=$targetHash;targetExisted=$targetExists}
        if ($name -in $backendFiles) { $backendHashes[$name] = $sourceHash }
    } elseif ($name -in $backendFiles) {
        $backendHashes[$name] = $targetHash
    }
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
    if ($change.targetExisted) {
        [IO.File]::Copy($target, $backup, $false)
        $hash = Get-WatchdogFileSha256 $backup
        if ($hash -ne $change.targetHash) { throw "Backup hash mismatch for $($change.name)" }
        $backupFiles += [pscustomobject]@{name=$change.name;path=$backup;sha256=$hash;existed=$true}
    } else {
        $backupFiles += [pscustomobject]@{name=$change.name;path='';sha256='';existed=$false}
    }
}
$recordBackup = Join-Path $backupDir 'watchdog-tray-install.json'
[IO.File]::Copy($recordPath, $recordBackup, $false)
$recordBackupHash = Get-WatchdogFileSha256 $recordBackup
$taskBackup = Join-Path $backupDir 'previous-supervisor-task.xml'
if ([string]::IsNullOrWhiteSpace($previousSupervisorTaskXml)) { throw 'Cannot back up an empty supervisor task definition.' }
[IO.File]::WriteAllText($taskBackup, $previousSupervisorTaskXml, [Text.Encoding]::Unicode)
if ([IO.File]::ReadAllText($taskBackup) -cne $previousSupervisorTaskXml) { throw 'Supervisor task backup differs from the exported definition.' }
Write-WatchdogAtomicJson (Join-Path $backupDir 'runtime-update-manifest.json') ([pscustomobject]@{
    schemaVersion=1; createdAt=[DateTimeOffset]::UtcNow.ToString('o'); machineSlug=[string]$config.machineSlug
    sourceDir=$SourceDir; installDir=$InstallDir; files=$backupFiles; installRecordSha256=$recordBackupHash
    supervisorTaskName=$supervisorSpec.name; supervisorTaskXmlSha256=(Get-WatchdogFileSha256 $taskBackup)
})

$rolesStopped = $false
$routerChanged = [bool]($changes.name -contains 'mcp-router.cjs')
try {
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
    $record | Add-Member -NotePropertyName backendFileHashes -NotePropertyValue $backendHashes -Force
    Write-WatchdogAtomicJson $recordPath $record
    $supervisorAction = Convert-InstallSupervisorTaskAction $InstallDir
    $supervisorActionChanged = [bool]$supervisorAction.changed

    # Run may partially start a role before throwing; rollback must quiesce it again.
    $rolesStopped = $false
    & (Join-Path $InstallDir 'devspace-watchdog-bootstrap.ps1') -Mode Run -ConfigPath $configPath
    Start-ScheduledTask -TaskName $supervisorSpec.name -TaskPath '\' -ErrorAction Stop
    if (-not (Wait-UpdateRolesReady ([int](Get-WatchdogControlSettings $config).dashboardPort))) { throw 'Updated Host/Tray/Supervisor did not become ready in time.' }
} catch {
    if (-not $lease) { throw }
    $failure = $_.Exception.Message
    try {
        if (-not $rolesStopped) {
            & (Join-Path $SourceDir 'devspace-watchdog-bootstrap.ps1') -Mode Stop -ConfigPath $configPath -RuntimeDirectory $InstallDir
            Wait-InstallSupervisorTaskStopped $InstallDir
        }
        & (Join-Path $SourceDir 'devspace-watchdog-bootstrap.ps1') -Mode CheckStopped -ConfigPath $configPath -RuntimeDirectory $InstallDir
        foreach ($item in $backupFiles) {
            $target = Join-Path $InstallDir $item.name
            if ([bool]$item.existed) {
                if ((Get-WatchdogFileSha256 $item.path) -ne [string]$item.sha256) { throw "Rollback backup hash mismatch: $($item.name)" }
                Copy-UpdateFile $item.path $target
            } elseif ([IO.File]::Exists($target)) {
                [IO.File]::Delete($target)
            }
        }
        if ((Get-WatchdogFileSha256 $recordBackup) -ne $recordBackupHash) { throw 'Install-record rollback backup hash mismatch.' }
        Copy-UpdateFile $recordBackup $recordPath
        if ($supervisorActionChanged -and $previousSupervisorTaskXml) {
            Register-ScheduledTask -TaskName $supervisorSpec.name -TaskPath '\' -Xml $previousSupervisorTaskXml -Force -ErrorAction Stop | Out-Null
        }
        & (Join-Path $InstallDir 'devspace-watchdog-bootstrap.ps1') -Mode Run -ConfigPath $configPath
        Start-ScheduledTask -TaskName $supervisorSpec.name -TaskPath '\' -ErrorAction Stop
        if (-not (Wait-UpdateRolesReady ([int](Get-WatchdogControlSettings $config).dashboardPort))) {
            throw 'Restored Host, Tray, Supervisor or dashboard did not become ready.'
        }
    } catch { throw "Runtime update failed: $failure. Rollback also needs attention: $($_.Exception.Message). Backup: $backupDir" }
    throw "Runtime update failed and payload was restored: $failure. Backup: $backupDir"
}

if ($routerChanged) {
    $liveConfig = Read-WatchdogJson $configPath
    $restart = Restart-WatchdogManagedService 'router' $configPath $liveConfig
    if (-not $restart.success) {
        throw "Runtime files were updated, but Router restart failed: $($restart.error). Backup: $backupDir"
    }
}
Wait-UpdateServiceHealth
Write-Host "Watchdog runtime update complete. Backup: $backupDir" -ForegroundColor Green
} finally { Exit-StackOperation $lease }
