$ErrorActionPreference = "Stop"
$watchdog = Get-Content (Join-Path $PSScriptRoot "devspace-watchdog.ps1") -Raw
$installer = Get-Content (Join-Path $PSScriptRoot "install-devspace-watchdog.ps1") -Raw
$upgrader = Get-Content (Join-Path $PSScriptRoot "upgrade-existing-tested-stack.ps1") -Raw
$entry = Get-Content (Join-Path $PSScriptRoot "detect-and-apply-tested-stack.ps1") -Raw

@(
    "DEVSPACE_TOOL_MODE", "DEVSPACE_WIDGETS", "DEVSPACE_SKILLS", "DEVSPACE_SUBAGENTS",
    "HERMES_GPT_ENABLE_CODEX", "HERMES_GPT_ENABLE_MCP", "HERMES_GPT_ENABLE_VISION",
    "HERMES_GPT_ENABLE_WEB", "HERMES_GPT_ENABLE_DIAGNOSTICS", "HERMES_GPT_ENABLE_CODEX_RUNNER",
    "HERMES_GPT_ALLOW_CODEX_WRITE", "HERMES_GPT_ENABLE_WRITE", "HERMES_GPT_ENABLE_MEMORY_WRITE",
    "HERMES_GPT_ENABLE_TERMINAL", "HERMES_GPT_OPERATOR_ENABLED", "HERMES_GPT_ENABLE_CRON",
    "HERMES_GPT_ALLOW_CRON_WRITE", "HERMES_GPT_ALLOW_SKILL_WRITE",
    "HERMES_GPT_ALLOW_PRIVATE_NETWORK", "HERMES_GPT_CODEX_ALLOWED_ROOTS"
) | ForEach-Object { if (-not $watchdog.Contains($_)) { throw "Watchdog missing supported gate: $_" } }

if ($installer -match 'if \(\$FullAccess\)\s*\{\s*\$env:HERMES') {
    throw "DevSpace FullAccess must not enable Hermes capabilities."
}
if (-not $upgrader.Contains('if ($Action -eq "Upgrade")')) { throw "Upgrade mutations are not action-gated." }
if (-not $upgrader.Contains("Preserve current effective settings")) { throw "Upgrade lacks Preserve default." }
if (-not $entry.Contains("partial/unknown existing installation")) { throw "Unified entry lacks partial-install refusal." }
if (-not $entry.Contains("repository artifacts exist without a recognized live configuration")) { throw "Unified entry may overwrite unknown repos." }
Write-Host "capability watchdog tests passed."
