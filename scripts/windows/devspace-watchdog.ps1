param(
    [switch]$Once,
    [switch]$NgrokOnly,
    [string]$ConfigPath
)

# Tiny compatibility launcher for the legacy scheduled poller. PowerShell parses
# an entire script before executing it, so keep this file intentionally small.
# On machines whose old Task Scheduler entry cannot be disabled because of its
# ACL, the marker lets the unavoidable powershell.exe process exit before the
# full legacy implementation is parsed or loaded.
$disableMarker = Join-Path $PSScriptRoot 'legacy-watchdog-poller.disabled'
if ($Once -and (Test-Path -LiteralPath $disableMarker)) { exit 0 }

$legacy = Join-Path $PSScriptRoot 'devspace-watchdog-legacy.ps1'
if (-not (Test-Path -LiteralPath $legacy)) { throw "Missing legacy watchdog implementation: $legacy" }
& $legacy @PSBoundParameters
exit $LASTEXITCODE
