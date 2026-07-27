$ErrorActionPreference = "Stop"
$path = Join-Path $PSScriptRoot "upgrade-existing-tested-stack.ps1"
$tokens = $null
$errors = $null
[Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count) { throw ($errors | Out-String) }
$source = Get-Content $path -Raw
@(
    "[switch]`$DryRun",
    "[switch]`$VerifyOnly",
    "Export-ScheduledTask",
    "rollback-manifest.json",
    "migrate-oauth-json-to-sqlite.mjs",
    "credentials will not be regenerated",
    "Watchdog configuration changed unexpectedly",
    "task definition or privilege mode changed unexpectedly"
) | ForEach-Object { if (-not $source.Contains($_)) { throw "Missing safety behavior: $_" } }
Write-Host "existing stack upgrade installer tests passed."
