$ErrorActionPreference = "Stop"
$paths = @(
    (Join-Path $PSScriptRoot "upgrade-existing-tested-stack.ps1"),
    (Join-Path $PSScriptRoot "start-existing-tested-stack-upgrade.ps1"),
    (Join-Path $PSScriptRoot "run-existing-tested-stack-upgrade.ps1")
)
foreach ($path in $paths) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw "$path`n$($errors | Out-String)" }
}
$source = Get-Content (Join-Path $PSScriptRoot "upgrade-existing-tested-stack.ps1") -Raw
@(
    'ValidateSet("Auto", "Upgrade", "UpgradeDevSpace", "UpgradeHermes", "CapabilitiesOnly")',
    "Get-TestedStackPlan",
    "Resolve-RepoRemote",
    "Normalize-GitUrl",
    "Assert-CanStopManagedListeners",
    "OpenProcess(0x0001",
    "FIXED PORT CONFLICT:",
    "ResponseHeadersRead",
    "Copy-CriticalState",
    "rollback-manifest.json",
    "Invoke-Rollback",
    "NoAutoRollback",
    "migrate-oauth-json-to-sqlite.mjs",
    "credentials will not be regenerated",
    "Owner auth changed unexpectedly",
    "Task privilege/definition changed unexpectedly",
    "Preserve current effective settings",
    "npm.cmd run test:windows-watchdog",
    "pytest -q",
    "Copy-Item `$WatchdogSource"
) | ForEach-Object { if (-not $source.Contains($_)) { throw "Missing upgrade safety behavior: $_" } }
if ($source.Contains("raw.githubusercontent.com")) { throw "Existing-machine upgrade must use the local tested installer package, not mutable raw branch downloads." }
foreach ($ambiguous in @('$devVersion', '$hermesVersion', '$DevSpaceVersion', '$HermesVersion', '$DevSpaceCommit', '$HermesCommit')) {
    if ($source.Contains($ambiguous)) { throw "PowerShell case-insensitive current/pinned variable collision remains: $ambiguous" }
}
foreach ($requiredName in @('$CurrentDevSpaceVersion', '$PinnedDevSpaceVersion', '$CurrentHermesVersion', '$PinnedHermesVersion')) {
    if (-not $source.Contains($requiredName)) { throw "Explicit current/pinned variable is missing: $requiredName" }
}
$launcher = Get-Content (Join-Path $PSScriptRoot "start-existing-tested-stack-upgrade.ps1") -Raw
if (-not $launcher.Contains("Start-Process") -or -not $launcher.Contains("status.json")) { throw "Detached upgrade launcher is incomplete." }
$runner = Get-Content (Join-Path $PSScriptRoot "run-existing-tested-stack-upgrade.ps1") -Raw
if (-not $runner.Contains("request.json") -and -not $runner.Contains("RequestPath")) { throw "Detached upgrade runner does not consume a request file." }

# Run only the rollback function with inert service/storage boundaries.
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
$rollback = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Rollback' }, $true)
if (-not $rollback) { throw 'Rollback function missing.' }
& {
    $WarningPreference = 'SilentlyContinue'
    Invoke-Expression $rollback.Extent.Text
    $InstallDir = Join-Path $env:TEMP 'unused-upgrade-fixture'
    $manifest = [pscustomobject]@{ upgradeDevSpace=$false; upgradeHermes=$false; externalStateBackedUp=$false; hermesHomeBackedUp=$false }
    $task = [pscustomobject]@{ Name='unused-test-task'; Path='\' }
    $boundary = @{ failure=''; actions=[Collections.Generic.List[string]]::new() }
    function Read-Json { if ($boundary.failure -eq 'read') { throw 'injected read failure' }; return @{} }
    function Get-ManagedListenerPlan { if ($boundary.failure -eq 'identity') { throw 'injected identity failure' }; return @() }
    function Assert-CanStopManagedListeners { if ($boundary.failure -eq 'access') { throw 'injected access failure' } }
    function Stop-ManagedListeners { if ($boundary.failure -eq 'stop') { throw 'injected stop failure' }; $boundary.actions.Add('stopped') }
    function Restore-CriticalState { $boundary.actions.Add('restore') }
    function Start-ScheduledTask { $boundary.actions.Add('start') }
    function Start-Sleep { }
    function Verify-Live { $boundary.actions.Add('verify') }
    foreach ($phase in @('read','identity','access','stop')) {
        $boundary.failure = $phase
        $boundary.actions.Clear()
        $failure = $null
        try { Invoke-Rollback $manifest $InstallDir $task }
        catch { $failure = $_.Exception.Message }
        if (-not $failure -or $failure -notlike "*injected $phase failure*") { throw "Rollback must propagate $phase failure before restoring data." }
        if ($boundary.actions.Count) { throw "Rollback modified state after $phase failure: $($boundary.actions -join ',')" }
    }
    $boundary.failure = ''
    $boundary.actions.Clear()
    Invoke-Rollback $manifest $InstallDir $task
    if (($boundary.actions -join ',') -ne 'stopped,restore,start,verify') { throw 'Successful rollback ordering changed.' }
}
Write-Host "existing stack upgrade installer tests passed."
