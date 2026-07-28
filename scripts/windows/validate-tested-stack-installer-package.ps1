[CmdletBinding()]
param(
    [string]$PackageDir
)

$ErrorActionPreference = "Stop"
if (-not $PackageDir) { $PackageDir = $PSScriptRoot }
$root = [IO.Path]::GetFullPath($PackageDir)
$required = @(
    "detect-and-apply-tested-stack.ps1",
    "install-tested-stack.ps1",
    "install-devspace-watchdog.ps1",
    "upgrade-existing-tested-stack.ps1",
    "start-existing-tested-stack-upgrade.ps1",
    "run-existing-tested-stack-upgrade.ps1",
    "capability-config.ps1",
    "devspace-watchdog.ps1",
    "watchdog-task-action.ps1",
    "ngrok-install.ps1",
    "mcp-router.cjs",
    "run-devspace-watchdog-hidden.vbs"
)
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
$migrationPath = Join-Path (Split-Path $root -Parent) "migrate-oauth-json-to-sqlite.mjs"
if (-not (Test-Path -LiteralPath $migrationPath)) { $missing += "../migrate-oauth-json-to-sqlite.mjs" }
if ($missing.Count) { throw "Installer package is incomplete. Missing: $($missing -join ', ')" }

$parseErrors = @()
foreach ($name in @($required | Where-Object { $_ -like "*.ps1" })) {
    $path = Join-Path $root $name
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { $parseErrors += "$name`n$($errors | Out-String)" }
}
if ($parseErrors.Count) { throw ($parseErrors -join "`n") }

$upgrade = Get-Content (Join-Path $root "upgrade-existing-tested-stack.ps1") -Raw
foreach ($marker in @(
    'UpgradeDevSpace', 'UpgradeHermes', 'Assert-CanStopManagedListeners',
    'Invoke-Rollback', 'ResponseHeadersRead', 'rollback-manifest.json'
)) {
    if (-not $upgrade.Contains($marker)) { throw "Upgrade installer is missing required marker: $marker" }
}
Write-Host "Tested-stack installer package validation passed."
Write-Host "Package directory: $root"
Write-Host "Files checked: $($required.Count)"
