[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('nt2rctfpoweruniformity','nt2rframestation')][string]$MachineSlug,
    [string]$InstallDir = "$env:USERPROFILE\.devspace",
    [switch]$Apply
)

# Run locally as the installation owner. A disabled remote operator cannot enable itself.
$ErrorActionPreference = 'Stop'
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$configPath = Join-Path $InstallDir 'devspace-watchdog.config.json'
. (Join-Path $InstallDir 'watchdog-control-core.ps1')
$config = Read-WatchdogJson $configPath
if ($config.machineSlug -cne $MachineSlug -or [IO.Path]::GetFullPath([string]$config.stateDir) -ne $InstallDir) {
    throw 'Machine slug or installation directory does not match; no configuration changed.'
}
if (-not $config.hermesEnabled) { throw 'Hermes is disabled; no configuration changed.' }
$candidate = Copy-WatchdogObject $config
$capabilities = Get-WatchdogProperty $candidate 'capabilities' ([pscustomobject]@{})
$hermes = Get-WatchdogProperty $capabilities 'hermes' ([pscustomobject]@{})
# Explicit opt-in to the TYO profile observed on 2026-09-10. Resolve roots on this PC.
foreach ($key in @('bridge','readOnlyTools','vision','web','diagnostics','runner','runnerWrite',
    'workspaceWrite','memoryWrite','terminal','operator','operatorDirect','ownerMode',
    'cron','cronWrite','skillWrite','privateNetwork')) { Set-WatchdogProperty $hermes $key $true }
Set-WatchdogProperty $hermes 'filesystemScope' 'full'
Set-WatchdogProperty $hermes 'allowedRoots' @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root })
Set-WatchdogProperty $capabilities 'hermes' $hermes
Set-WatchdogProperty $candidate 'capabilities' $capabilities
$environment = Get-WatchdogHermesEnvironment $candidate
if ($environment.HERMES_GPT_OPERATOR_ENABLED -ne '1' -or $environment.HERMES_GPT_OPERATOR_LEVEL -ne 'owner' -or
    $environment.HERMES_GPT_OPERATOR_APPLY_MODE -ne 'direct' -or
    $environment.HERMES_GPT_OWNER_ACK -ne 'I_UNDERSTAND_THIS_CAN_MUTATE_MY_MACHINE') { throw 'Installed helper cannot produce the requested owner policy.' }
[pscustomobject]@{machineSlug=$MachineSlug;installDir=$InstallDir;operator='owner';applyMode='direct';filesystemScope='full';apply=[bool]$Apply}
if (-not $Apply) { Write-Host 'Preview only. Run this same command with -Apply on the target PC to save and activate.'; return }

$bootstrap = Join-Path $InstallDir 'devspace-watchdog-bootstrap.ps1'
if (-not (Test-Path -LiteralPath $bootstrap)) { throw 'Required Host lifecycle helper is missing.' }
$lease = $null; $backupPath = $null; $changed = $false
try {
    $lease = Enter-StackOperation $InstallDir
    $live = Read-WatchdogJson $configPath
    if (($live | ConvertTo-Json -Depth 30 -Compress) -cne ($config | ConvertTo-Json -Depth 30 -Compress)) { throw 'Configuration changed during preview; retry from the current configuration.' }
    $state = Read-WatchdogJson (Join-Path $InstallDir 'watchdog-tray-state.json')
    if ($state.maintenanceMode -or $state.desired.hermes -ne 'running') { throw 'Hermes must be intended running and outside maintenance before activation.' }
    $health = Get-WatchdogHealthSnapshot $configPath
    if (-not $health.services.hermes.healthy -or $health.services.hermes.identityConflict) { throw 'Current Hermes identity/health prevents activation.' }
    $backupDir = Join-Path $InstallDir ('configuration-backups\hermes-owner-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    [void][IO.Directory]::CreateDirectory($backupDir)
    $backupPath = Join-Path $backupDir 'devspace-watchdog.config.json'
    [IO.File]::Copy($configPath, $backupPath, $false)
    $backupHash = Get-WatchdogFileSha256 $backupPath
    if ($backupHash -ne (Get-WatchdogFileSha256 $configPath)) { throw 'Configuration backup hash mismatch.' }
    Write-Host "Configuration backup: $backupPath"
    $changed = $true
    Write-WatchdogAtomicJson $configPath $candidate
    & $bootstrap -Mode RepairHost -ConfigPath $configPath
    $restart = Restart-WatchdogManagedService 'hermes' $configPath $candidate
    if (-not $restart.success) { throw $restart.error }
    Write-Host "Owner configuration saved; Hermes started as PID $($restart.pid). Verify hermes_operator_policy from the connector."
} catch {
    $failure = $_.Exception.Message
    if ($changed) {
        try {
            if ((Get-WatchdogFileSha256 $backupPath) -ne $backupHash) { throw 'Recovery backup hash mismatch.' }
            Write-WatchdogAtomicText $configPath ([IO.File]::ReadAllText($backupPath))
            & $bootstrap -Mode RepairHost -ConfigPath $configPath
            $rollback = Restart-WatchdogManagedService 'hermes' $configPath $config
            if (-not $rollback.success) { throw $rollback.error }
        } catch { throw "Activation failed: $failure. Recovery needs attention: $($_.Exception.Message). Backup: $backupPath" }
    }
    throw "Owner activation failed: $failure. Previous configuration retained/restored; runtime health must be checked."
} finally { Exit-StackOperation $lease }
