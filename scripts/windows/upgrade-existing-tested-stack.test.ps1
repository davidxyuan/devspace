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
Write-Host "existing stack upgrade installer tests passed."
