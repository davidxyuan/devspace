$ErrorActionPreference = 'Stop'
$target = Join-Path $PSScriptRoot 'set-hermes-owner-capabilities.ps1'
. (Join-Path $PSScriptRoot 'watchdog-control-core.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('devspace-owner-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
# Only process/Host operations are replaced; configuration, backup, locks and environment generation are real.
$realCore = (Join-Path $PSScriptRoot 'watchdog-control-core.ps1').Replace("'", "''")
$fixtureCore = ". '$realCore'" + [Environment]::NewLine + @'
function Get-WatchdogHealthSnapshot { [pscustomobject]@{services=[pscustomobject]@{hermes=[pscustomobject]@{healthy=$true;identityConflict=$false}}} }
function Restart-WatchdogManagedService($Service,$ConfigPath,$Config) {
    if ((Test-Path (Join-Path (Split-Path $ConfigPath) 'fail-owner')) -and $Config.capabilities.hermes.ownerMode) { return [pscustomobject]@{success=$false;error='simulated activation failure'} }
    [pscustomobject]@{success=$true;pid=123}
}
'@
[IO.File]::WriteAllText((Join-Path $fixture 'watchdog-control-core.ps1'), $fixtureCore)
[IO.File]::WriteAllText((Join-Path $fixture 'devspace-watchdog-bootstrap.ps1'), 'param($Mode,$ConfigPath)')
$configPath = Join-Path $fixture 'devspace-watchdog.config.json'
$initial = [pscustomobject]@{stateDir=$fixture;machineSlug='nt2rframestation';hermesEnabled=$true;hermesFullAccess=$true;publicBaseUrl='https://preserve.example/path';custom=[pscustomobject]@{keep='yes'};capabilities=[pscustomobject]@{devspace=[pscustomobject]@{toolMode='minimal'}}}
$initialJson = $initial | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($configPath, $initialJson)
[IO.File]::WriteAllText((Join-Path $fixture 'watchdog-tray-state.json'), '{"maintenanceMode":false,"desired":{"hermes":"running"}}')
& $target -MachineSlug nt2rframestation -InstallDir $fixture | Out-Null
if ([IO.File]::ReadAllText($configPath) -cne $initialJson -or (Test-Path (Join-Path $fixture 'configuration-backups'))) { throw 'Preview mutated installation.' }
try { & $target -MachineSlug nt2rctfpoweruniformity -InstallDir $fixture -Apply; throw 'Wrong identity accepted' }
catch { if ($_.Exception.Message -notlike '*does not match*') { throw } }
& $target -MachineSlug nt2rframestation -InstallDir $fixture -Apply | Out-Null
$actual = Get-Content $configPath -Raw | ConvertFrom-Json
$envMap = Get-WatchdogHermesEnvironment $actual
if ($envMap.HERMES_GPT_OPERATOR_ENABLED -ne '1' -or $envMap.HERMES_GPT_OPERATOR_LEVEL -ne 'owner' -or $envMap.HERMES_GPT_OPERATOR_APPLY_MODE -ne 'direct') { throw 'Owner environment was not generated.' }
if ($actual.publicBaseUrl -ne $initial.publicBaseUrl -or $actual.custom.keep -ne 'yes' -or $actual.capabilities.devspace.toolMode -ne 'minimal') { throw 'Unrelated settings changed.' }
$backups = @(Get-ChildItem (Join-Path $fixture 'configuration-backups') -Directory)
if ($backups.Count -ne 1 -or [IO.File]::ReadAllText((Join-Path $backups[0].FullName 'devspace-watchdog.config.json')) -cne $initialJson) { throw 'Original backup lost.' }
[IO.File]::WriteAllText($configPath, $initialJson)
[IO.File]::WriteAllText((Join-Path $fixture 'fail-owner'), '1')
try { & $target -MachineSlug nt2rframestation -InstallDir $fixture -Apply; throw 'Failure not reported' }
catch { if ($_.Exception.Message -notlike '*simulated activation failure*') { throw } }
if ([IO.File]::ReadAllText($configPath) -cne $initialJson) { throw 'Activation failure did not restore original configuration.' }
Write-Host "Owner capability checks passed: preview, identity, preservation, backup and rollback. Fixture: $fixture"
