$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'update-installed-watchdog-runtime.ps1'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
if ($errors.Count) { throw $errors[0].Message }
$source = [IO.File]::ReadAllText($path)
$legacyLauncher = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'devspace-watchdog.ps1'))
if ($legacyLauncher.Length -gt 4096) { throw 'legacy watchdog launcher must remain tiny so ACL-protected pollers exit before parsing the full implementation.' }
if (-not $legacyLauncher.Contains('legacy-watchdog-poller.disabled') -or -not $legacyLauncher.Contains('devspace-watchdog-legacy.ps1') -or -not $legacyLauncher.Contains('if ($Once -and (Test-Path -LiteralPath $disableMarker)) { exit 0 }')) { throw 'legacy watchdog launcher does not preserve fast logical quiesce.' }
function Assert-Contains([string]$Name,[string]$Text) { if (-not $source.Contains($Text)) { throw "$Name failed." } }
function Assert-NotContains([string]$Name,[string]$Text) { if ($source.Contains($Text)) { throw "$Name failed." } }
foreach ($name in @(
    'watchdog-control-core.ps1','stack-operation.ps1','stack-host-management.ps1','watchdog-install-transaction.ps1',
    'devspace-watchdog-tray.ps1','devspace-watchdog-tray-ui.ps1','devspace-watchdog-bootstrap.ps1','devspace-control-center.html',
    'run-devspace-watchdog-tray-hidden.vbs','uninstall-devspace-watchdog-tray.ps1','restore-old-watchdog.ps1',
    'devspace-watchdog.ps1','devspace-watchdog-legacy.ps1','mcp-router.cjs')) { Assert-Contains "tracks $name" "'$name'" }
Assert-Contains 'requires existing install record' "watchdog-tray-install.json"
Assert-Contains 'verifies current payload hashes' 'Installed payload changed since the install record'
Assert-Contains 'backs up changed runtime files' 'runtime-update-manifest.json'
Assert-Contains 'permits additive legacy backend migration only' "-and `$name -ne 'devspace-watchdog-legacy.ps1'"
Assert-Contains 'tracks whether changed files existed before update' 'targetExisted=$targetExists'
Assert-Contains 'rollback removes files added by migration' "elseif ([IO.File]::Exists(`$target))"
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
Assert-Contains 'detects Kaspersky before batch mutation' 'function Test-UpdateKasperskyEndpointSecurity'
Assert-Contains 'blocks Kaspersky-managed Apply before writes' 'Kaspersky Endpoint Security is active; batch updater Apply is disabled before any file writes'
if ($source.IndexOf('if (Test-UpdateKasperskyEndpointSecurity)') -gt $source.IndexOf('$backupDir = Join-Path')) { throw 'Kaspersky guard must run before backup/copy mutation.' }
Assert-NotContains 'does not disable legacy scheduled task' 'Disable-ScheduledTask'
Assert-NotContains 'does not unregister legacy scheduled task' 'Unregister-ScheduledTask'
Assert-Contains 'migrates only verified supervisor action' 'Convert-InstallSupervisorTaskAction $InstallDir'
Assert-Contains 'backs up supervisor XML before action migration' '$previousSupervisorTaskXml = Export-ScheduledTask'
Assert-Contains 'restores prior supervisor XML on rollback' 'Register-ScheduledTask -TaskName $supervisorSpec.name'
Assert-Contains 'rollback uses backed-up supervisor XML' '-Xml $previousSupervisorTaskXml'
Assert-NotContains 'does not stop DevSpace service' "Stop-WatchdogManagedService 'devspace'"
Assert-NotContains 'does not stop Hermes service' "Stop-WatchdogManagedService 'hermes'"
Assert-NotContains 'does not stop ngrok service' "Stop-WatchdogManagedService 'ngrok'"

& {
    $healthFunction = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-UpdateServiceAcceptable'}, $true)
    . ([scriptblock]::Create($healthFunction.Extent.Text))
    $AllowHermesBusyTransport = $false
    foreach ($service in @($null, @{}, @{healthy=$true}, @{enabled=$null}, @{enabled=0}, @{enabled='false';healthy=$true})) {
        if (Test-UpdateServiceAcceptable 'devspace' $service) { throw 'Missing or invalid service state must block updates.' }
    }
    if (-not (Test-UpdateServiceAcceptable 'devspace' @{enabled=$false})) { throw 'Explicitly disabled services must remain supported.' }
    if (-not (Test-UpdateServiceAcceptable 'devspace' @{enabled=$true;healthy=$true})) { throw 'Healthy services must remain supported.' }
}

& {
    $readyFunction = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-UpdateRolesReady'}, $true)
    . ([scriptblock]::Create($readyFunction.Extent.Text))
    $StartupTimeoutSeconds = 0
    function Start-Sleep { param($Milliseconds) }
    function Invoke-WebRequest { param([switch]$UseBasicParsing,$Uri,$TimeoutSec) @{StatusCode=200} }
    function Test-UpdateHeartbeat { param($Name,$Role,$MaxAgeSeconds) $Role -ne $missingRole }
    foreach ($missingRole in @('host','tray-ui','supervisor')) {
        if (Wait-UpdateRolesReady 18777) { throw "Missing $missingRole was accepted as ready." }
    }
    $missingRole = ''
    if (-not (Wait-UpdateRolesReady 18777)) { throw 'All ready roles were rejected.' }
}

# A failed task query is not proof that the supervisor exited.
& {
    . (Join-Path $PSScriptRoot 'watchdog-install-transaction.ps1')
    function Get-ScheduledTask {
        [CmdletBinding()]param($TaskName,$TaskPath)
        Write-Error 'fixture scheduler unavailable'
    }
    $queryFailed = $false
    try { Wait-InstallSupervisorTaskStopped (Join-Path ([IO.Path]::GetTempPath()) 'watchdog-query-fixture') }
    catch { $queryFailed = $_.Exception.Message -like '*fixture scheduler unavailable*' }
    if (-not $queryFailed) { throw 'A failed supervisor query was accepted as exit proof.' }
    function Get-ScheduledTask { [CmdletBinding()]param($TaskName,$TaskPath) }
    Wait-InstallSupervisorTaskStopped (Join-Path ([IO.Path]::GetTempPath()) 'watchdog-query-fixture')
}

# Run the real transaction block with isolated files and lifecycle doubles.
$transaction = $ast.FindAll({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $node.Body.Extent.Text.Contains('$sourceBootstrap = Join-Path $SourceDir') -and -not $node.Body.Extent.Text.Contains('$lease = Enter-StackOperation $InstallDir')}, $true) | Select-Object -First 1
if (-not $transaction) { throw 'Runtime update transaction was not found.' }
$transactionBlock = [scriptblock]::Create($transaction.Extent.Text)
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('watchdog-update-rollback-' + [guid]::NewGuid().ToString('N'))
try {
    $SourceDir = Join-Path $fixtureRoot 'source'
    $InstallDir = Join-Path $fixtureRoot 'installed'
    [void][IO.Directory]::CreateDirectory($SourceDir)
    [void][IO.Directory]::CreateDirectory($InstallDir)
    $bootstrap = @'
param($Mode,$ConfigPath,$RuntimeDirectory)
$global:RuntimeRollbackFixture.events.Add($Mode)
switch ($Mode) {
    'Stop' {
        if ($global:RuntimeRollbackFixture.stopFails -and $global:RuntimeRollbackFixture.running) { throw 'fixture stop failed' }
        $global:RuntimeRollbackFixture.running = $false
    }
    'CheckStopped' {
        if ($global:RuntimeRollbackFixture.checkFails -and $global:RuntimeRollbackFixture.events.Contains('Run')) { throw 'fixture exit proof failed' }
        if ($global:RuntimeRollbackFixture.running) { throw 'fixture still running' }
    }
    'Run' {
        $global:RuntimeRollbackFixture.running = $true
        if ($global:RuntimeRollbackFixture.startFails -and $global:RuntimeRollbackFixture.events.FindAll({param($e) $e -eq 'Run'}).Count -eq 1) { throw 'fixture partially started' }
    }
    default { throw 'Unexpected lifecycle mode' }
}
'@
    foreach ($dir in @($SourceDir,$InstallDir)) { [IO.File]::WriteAllText((Join-Path $dir 'devspace-watchdog-bootstrap.ps1'),$bootstrap) }
    function Enter-StackOperation { param($Path) if ($global:RuntimeRollbackFixture.leaseFails) { throw 'fixture lease busy' }; 'fixture-lease' }
    function Exit-StackOperation { param($Lease) $global:RuntimeRollbackFixture.events.Add('unlock') }
    function Wait-InstallSupervisorTaskStopped { param($Path) $global:RuntimeRollbackFixture.events.Add('supervisor-stopped') }
    function Convert-InstallSupervisorTaskAction { param($Path) @{changed=$false} }
    function Start-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction) $global:RuntimeRollbackFixture.events.Add('start-supervisor') }
    function Register-ScheduledTask { throw 'Unexpected task registration' }
    function Wait-UpdateRolesReady { param($Port) $global:RuntimeRollbackFixture.events.Add('readiness'); return $global:RuntimeRollbackFixture.ready }
    function Get-WatchdogControlSettings { param($Config) @{dashboardPort=18777} }
    function Get-WatchdogFileSha256 { param($Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    function Write-WatchdogAtomicJson { param($Path,$Value) $global:RuntimeRollbackFixture.events.Add('write-record'); [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 10)) }
    function Copy-UpdateFile {
        param($Source,$Destination)
        if ($global:RuntimeRollbackFixture.running) { throw 'attempted overwrite while fixture role was running' }
        $global:RuntimeRollbackFixture.events.Add($(if ($Source -like '*backup*') {'restore'} else {'copy-new'}))
        [IO.File]::Copy($Source,$Destination,$true)
        if ($global:RuntimeRollbackFixture.copyFails -and $Source -notlike '*backup*') { throw 'fixture copy failed after replacing its destination' }
    }
    foreach ($scenario in @('healthy','readiness-failure','partial-start-failure','copy-failure','stop-failure','check-failure')) {
        $global:RuntimeRollbackFixture = @{events=[Collections.Generic.List[string]]::new(); running=$false; ready=$scenario -eq 'healthy'; startFails=$scenario -eq 'partial-start-failure'; copyFails=$scenario -eq 'copy-failure'; stopFails=$scenario -eq 'stop-failure'; checkFails=$scenario -eq 'check-failure'}
        $configPath = Join-Path $InstallDir 'fixture.json'; $config=@{}; $record=@{}; $recordPath=Join-Path $InstallDir 'record.json'
        $payloadFiles=@('payload.ps1'); $changes=@([pscustomobject]@{name='payload.ps1'})
        $installedMap=@{'payload.ps1'=@{sha256='old'}}; $supervisorSpec=@{name='fixture-supervisor'}
        $backupDir=Join-Path $fixtureRoot 'backup'
        [void][IO.Directory]::CreateDirectory($backupDir)
        foreach ($directory in @($InstallDir,$backupDir)) { [IO.File]::WriteAllText((Join-Path $directory 'payload.ps1'),'old payload'); [IO.File]::WriteAllText((Join-Path $directory 'record.json'),'old record') }
        [IO.File]::WriteAllText((Join-Path $SourceDir 'payload.ps1'),'new payload')
        $payloadBackup=Join-Path $backupDir 'payload.ps1'
        $backupFiles=@(@{name='payload.ps1';existed=$true;path=$payloadBackup;sha256=(Get-WatchdogFileSha256 $payloadBackup)})
        $recordBackup=Join-Path $backupDir 'record.json'; $recordBackupHash=Get-WatchdogFileSha256 $recordBackup; $supervisorActionChanged=$false
        $lease='fixture-lease'; $rolesStopped=$false; $failureMessage=''
        try { . $transactionBlock } catch { $failureMessage=$_.Exception.Message }
        $events=$global:RuntimeRollbackFixture.events
        if ($scenario -eq 'healthy') {
            if ($failureMessage -or $events.Contains('restore')) { throw "Healthy update failed: $failureMessage" }
            if ([IO.File]::ReadAllText((Join-Path $InstallDir 'payload.ps1')) -ne 'new payload') { throw 'Successful update did not copy its payload.' }
        } elseif ($scenario -in @('stop-failure','check-failure')) {
            if ($failureMessage -notlike '*Rollback also needs attention*' -or $events.Contains('restore')) { throw 'Unconfirmed shutdown must preserve the files.' }
        } else {
            if ($failureMessage -notlike '*payload was restored*' -or -not $events.Contains('restore')) { throw "$scenario did not safely restore: $failureMessage" }
            $firstRestore=$events.IndexOf('restore')
            if ($events[$firstRestore-1] -ne 'CheckStopped') { throw "$scenario restored without stopped-role proof." }
            if ([IO.File]::ReadAllText((Join-Path $InstallDir 'payload.ps1')) -ne 'old payload' -or [IO.File]::ReadAllText($recordPath) -ne 'old record') { throw "$scenario did not restore the actual files." }
        }
    }
} finally {
    Remove-Variable RuntimeRollbackFixture -Scope Global -ErrorAction SilentlyContinue
    if ([IO.Path]::GetFullPath($fixtureRoot) -ne $fixtureRoot -or -not $fixtureRoot.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped its temporary directory.' }
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
# Exercise the real shared lease with a second PowerShell process and disposable paths.
$gateRoot = Join-Path ([IO.Path]::GetTempPath()) ('watchdog-update-lease-' + [guid]::NewGuid().ToString('N'))
$previousToken = $env:DEVSPACE_STACK_OPERATION_TOKEN
$previousJob = $env:DEVSPACE_STACK_JOB_ID
$heldLease = $null
try {
    . (Join-Path $PSScriptRoot 'stack-operation.ps1')
    $env:DEVSPACE_STACK_OPERATION_TOKEN = $null
    $env:DEVSPACE_STACK_JOB_ID = $null
    $gateInstall = Join-Path $gateRoot "installed-'fixture"
    [void][IO.Directory]::CreateDirectory($gateInstall)
    $gateScript = Join-Path $gateRoot 'update.ps1'
    $securityPredicate = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-UpdateKasperskyEndpointSecurity'}, $true)
    # The fixture changes only detection, never the host security software or a real installation.
    [IO.File]::WriteAllText($gateScript, $source.Replace($securityPredicate.Extent.Text, 'function Test-UpdateKasperskyEndpointSecurity { return $false }'))
    function Invoke-GateFixture {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $psi.Arguments = "-NoProfile -File `"$gateScript`" -InstallDir `"$gateInstall`" -SourceDir `"$PSScriptRoot`" -Apply"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = 'Hidden'
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $child = [Diagnostics.Process]::Start($psi)
        try {
            $stdout = $child.StandardOutput.ReadToEndAsync()
            $stderr = $child.StandardError.ReadToEndAsync()
            $child.WaitForExit()
            return @{code=$child.ExitCode; text=($stdout.Result + $stderr.Result)}
        } finally { $child.Dispose() }
    }
    $heldLease = Enter-StackOperation $gateInstall
    $env:DEVSPACE_STACK_OPERATION_TOKEN = $null
    $result = Invoke-GateFixture
    if ($result.code -eq 0 -or $result.text -notlike '*Another stack installation*') { throw "Live shared lease was bypassed: $($result.text)" }
    Exit-StackOperation $heldLease
    $heldLease = $null
    $directory = Join-Path $gateInstall 'stack-management'
    $legacyLock = Join-Path $directory 'node-runtime-update.lock'
    [IO.File]::WriteAllText($legacyLock, 'old updater fixture')
    $result = Invoke-GateFixture
    if ($result.code -eq 0 -or $result.text -notlike '*older Node runtime update*') { throw "Older updater lock was bypassed: $($result.text)" }
    if ([IO.File]::ReadAllText($legacyLock) -ne 'old updater fixture') { throw 'Older updater lock was modified.' }
    [IO.File]::Delete($legacyLock)
    [void][IO.Directory]::CreateDirectory((Join-Path $directory 'jobs'))
    $job = 'a' * 24
    [IO.File]::WriteAllText((Join-Path $directory 'active.json'), (@{id=$job} | ConvertTo-Json))
    [IO.File]::WriteAllText((Join-Path $directory "jobs\$job.json"), (@{id=$job;phase='rollback_failed'} | ConvertTo-Json))
    $result = Invoke-GateFixture
    if ($result.code -eq 0 -or $result.text -notlike '*job is still running or requires recovery*') { throw "Durable recovery reservation was bypassed: $($result.text)" }
    [IO.File]::Delete((Join-Path $directory 'active.json'))
    $result = Invoke-GateFixture
    if ($result.code -eq 0 -or $result.text -notlike '*requires an existing verified Watchdog Tray installation*') { throw "Expected isolated preflight failure: $($result.text)" }
    if (Test-StackOperationBusy $gateInstall) { throw 'Failed preflight leaked the shared lease.' }
    if ([IO.File]::ReadAllText((Get-StackOperationPath $gateInstall))) { throw 'Failed preflight did not clear its lease record.' }
    if ([IO.Directory]::Exists((Join-Path $gateInstall 'configuration-backups'))) { throw 'Preflight failure created a backup.' }
    Write-Host 'PASS: live cross-process lease, durable failed-job reservation, and preflight lease release.'
} finally {
    Exit-StackOperation $heldLease
    $env:DEVSPACE_STACK_OPERATION_TOKEN = $previousToken
    $env:DEVSPACE_STACK_JOB_ID = $previousJob
    if ([IO.Path]::GetFullPath($gateRoot) -ne $gateRoot -or [IO.Path]::GetDirectoryName($gateRoot) -ne ([IO.Path]::GetTempPath().TrimEnd('\'))) { throw 'Lease fixture cleanup escaped its temporary directory.' }
    if ([IO.Directory]::Exists($gateRoot)) { Remove-Item -LiteralPath $gateRoot -Recurse -Force }
}
Write-Host 'installed runtime updater checks passed: existing-install-only, shared lease, bounded supervisor action migration, lifecycle proof, backup and router-only restart.'
