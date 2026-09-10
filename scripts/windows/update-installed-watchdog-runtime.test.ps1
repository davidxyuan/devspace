$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'update-installed-watchdog-runtime.ps1'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
if ($errors.Count) { throw $errors[0].Message }
$source = [IO.File]::ReadAllText($path)
function Assert-Contains([string]$Name,[string]$Text) { if (-not $source.Contains($Text)) { throw "$Name failed." } }
function Assert-NotContains([string]$Name,[string]$Text) { if ($source.Contains($Text)) { throw "$Name failed." } }
foreach ($name in @(
    'watchdog-control-core.ps1','stack-operation.ps1','stack-host-management.ps1','watchdog-install-transaction.ps1',
    'devspace-watchdog-tray.ps1','devspace-watchdog-tray-ui.ps1','devspace-watchdog-bootstrap.ps1','devspace-control-center.html',
    'run-devspace-watchdog-tray-hidden.vbs','uninstall-devspace-watchdog-tray.ps1','restore-old-watchdog.ps1',
    'devspace-watchdog.ps1','mcp-router.cjs')) { Assert-Contains "tracks $name" "'$name'" }
Assert-Contains 'requires existing install record' "watchdog-tray-install.json"
Assert-Contains 'verifies current payload hashes' 'Installed payload changed since the install record'
Assert-Contains 'backs up changed runtime files' 'runtime-update-manifest.json'
Assert-Contains 'ignores line-ending-only differences' 'function Test-UpdateContentEqual'
Assert-Contains 'normalizes CRLF before deciding a runtime change' '.Replace("`r`n", "`n")'
Assert-Contains 'verifies backup hashes' 'Backup hash mismatch'
Assert-Contains 'bounded transient-health preflight' 'function Get-UpdateStableHealth'
Assert-Contains 'requires consecutive healthy checks' '$consecutiveHealthy -ge 2'
Assert-Contains 'identity conflict fails immediately' 'Identity conflict detected for'
Assert-Contains 'Hermes self-maintenance opt-in is explicit' '[switch]$AllowHermesBusyTransport'
Assert-Contains 'Hermes busy transport requires live process' '$Service.processFound'
Assert-Contains 'Hermes busy transport requires listener' '$Service.listenerFound'
Assert-Contains 'Hermes busy transport requires indeterminate busy proof' '$Service.busyIndeterminate'
Assert-Contains 'retries runtime copies instead of File.Replace' 'Could not replace $Destination after retrying transient locks'
Assert-NotContains 'does not use File.Replace for runtime rollback' '[IO.File]::Replace'
Assert-Contains 'uses lifecycle stop' '-Mode Stop'
Assert-Contains 'proves roles stopped' '-Mode CheckStopped'
Assert-Contains 'waits for existing supervisor' 'Wait-InstallSupervisorTaskStopped'
Assert-Contains 'restarts only changed backend router' "Restart-WatchdogManagedService 'router'"
Assert-Contains 'restores payload on update failure' 'payload was restored'
Assert-Contains 'requires explicit apply' 'if (-not $Apply)'
Assert-NotContains 'does not disable legacy scheduled task' 'Disable-ScheduledTask'
Assert-NotContains 'does not unregister legacy scheduled task' 'Unregister-ScheduledTask'
Assert-NotContains 'does not register replacement scheduled task' 'Register-ScheduledTask'
Assert-NotContains 'does not stop DevSpace service' "Stop-WatchdogManagedService 'devspace'"
Assert-NotContains 'does not stop Hermes service' "Stop-WatchdogManagedService 'hermes'"
Assert-NotContains 'does not stop ngrok service' "Stop-WatchdogManagedService 'ngrok'"
Write-Host 'installed runtime updater checks passed: existing-install-only, no legacy ACL mutation, lifecycle proof, backup and router-only restart.'
