$ErrorActionPreference = "Stop"
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$installerPath = Join-Path $PSScriptRoot "install-tested-stack.ps1"
$installer = Get-Content -LiteralPath $installerPath -Raw
$html = Get-Content -LiteralPath (Join-Path $root "docs\windows-new-pc-install.zh-TW.html") -Raw
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count) { throw ($errors | Out-String) }

@(
    '$DevSpaceVersion = "1.0.4"',
    '$DevSpaceCommit = "9c4462ba1ea43a846fd511b8b10e4bb6ac49493d"',
    '$HermesVersion = "0.5.0"',
    '$HermesCommit = "db5ffa1bd2e4fcfecdebb2bcf479334144e1cbe3"',
    '[switch]$VerifyOnly',
    'No OAuth state, secrets, routes, SQLite data, or scheduled tasks were copied or created.'
) | ForEach-Object {
    if (-not $installer.Contains($_)) { throw "Installer is missing expected pinned/safety text: $_" }
}
if (-not $html.Contains("install-tested-stack.ps1")) { throw "HTML does not use the tested-stack installer." }
if ($html.Contains('$branch = "codex/chatgpt-mcp-router-fix"')) { throw "HTML still emits the old unpinned install flow." }

Write-Host "tested stack installer tests passed."
