$ErrorActionPreference = "Stop"
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$installerPath = Join-Path $PSScriptRoot "install-tested-stack.ps1"
$installer = Get-Content -LiteralPath $installerPath -Raw
$html = Get-Content -LiteralPath (Join-Path $root "docs\windows-new-pc-install.zh-TW.html") -Raw
$tyoAgent = Get-Content -LiteralPath (Join-Path $PSScriptRoot "install-devspace-chatgpt-tyo-agent.ps1") -Raw
$tyoCloud = Get-Content -LiteralPath (Join-Path $PSScriptRoot "install-devspace-chatgpt-tyo-cloud.ps1") -Raw
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count) { throw ($errors | Out-String) }

@(
    '$DevSpaceVersion = "1.0.4"',
    '$DevSpaceRef = "codex/devspace-v1.0.4-watchdog-fix"',
    '$DevSpaceCommit = "15fcf9068608e51a56f97609aba32535a0359407"',
    '$HermesVersion = "0.5.0"',
    '$HermesCommit = "db5ffa1bd2e4fcfecdebb2bcf479334144e1cbe3"',
    '[switch]$VerifyOnly',
    'No OAuth state, secrets, routes, SQLite data, or scheduled tasks were copied or created.'
) | ForEach-Object {
    if (-not $installer.Contains($_)) { throw "Installer is missing expected pinned/safety text: $_" }
}
if (-not $html.Contains("install-tested-stack.ps1")) { throw "HTML does not use the tested-stack installer." }
if (-not $html.Contains("codex/windows-fixed-port-conflicts/scripts/windows/install-tested-stack.ps1")) {
    throw "HTML code-only installer does not use the maintained one-click branch."
}
if ($html.Contains('$branch = "codex/chatgpt-mcp-router-fix"')) { throw "HTML still emits the old unpinned install flow." }
foreach ($helper in @($tyoAgent, $tyoCloud)) {
    if (-not $helper.Contains('HermesRepo = "https://github.com/davidxyuan/hermes-gpt.git"')) {
        throw "TYO helper does not explicitly select the tested Hermes fork."
    }
}

Write-Host "tested stack installer tests passed."
