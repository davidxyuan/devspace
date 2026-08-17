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
    '$DevSpaceCommit = "9c4462ba1ea43a846fd511b8b10e4bb6ac49493d"',
    '$HermesVersion = "0.5.0"',
    '$HermesCommit = "db5ffa1bd2e4fcfecdebb2bcf479334144e1cbe3"',
    '[switch]$VerifyOnly',
    'Require-CompatiblePython',
    'Python.Python.3.12',
    'Try-InstallWingetPackage',
    'Install-OfficialPython312',
    'https://www.python.org/ftp/python/$version/$fileName',
    'Get-AuthenticodeSignature',
    'Python Software Foundation',
    '$managedPython312Dir = Join-Path $InstallRoot "tools\python\3.12.10"',
    'HKCU:\Software\Python',
    'HKLM:\Software\Python',
    'HKLM:\Software\Wow6432Node\Python',
    'ExecutablePath',
    'TargetDir=`"$managedPython312Dir`"',
    'InstallAllUsers=0',
    'PrependPath=0',
    'Include_pip=1',
    'Include_launcher=0',
    '0x8A15002B',
    'No Python >=3.10 was found. Preparing Python 3.12 side-by-side',
    'expected managed runtime was not created',
    'Install-PinnedRepo $HermesRepo $HermesRef $HermesCommit $hermesDir',
    'No OAuth state, secrets, routes, SQLite data, or scheduled tasks were copied or created.'
) | ForEach-Object {
    if (-not $installer.Contains($_)) { throw "Installer is missing expected pinned/safety/bootstrap text: $_" }
}
if ($installer.Contains('$managedPython312Dir = Join-Path $env:USERPROFILE')) {
    throw "Managed Python must follow InstallRoot rather than defaulting to the C: user profile."
}

if (-not $html.Contains('clone --depth 1 --branch "codex/devspace-v1.0.4-watchdog-fix"')) {
    throw "HTML does not clone the complete tested installer branch before execution."
}
if (-not $html.Contains('powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer')) {
    throw "HTML does not execute the installer from a real .ps1 file."
}
if ($html.Contains('([scriptblock]::Create((Invoke-RestMethod')) {
    throw "HTML still contains the old ScriptBlock/Invoke-RestMethod installer flow."
}
if ($html.Contains('$branch = "codex/chatgpt-mcp-router-fix"')) {
    throw "HTML still emits the old unpinned install flow."
}
foreach ($helper in @($tyoAgent, $tyoCloud)) {
    if (-not $helper.Contains('HermesRepo = "https://github.com/davidxyuan/hermes-gpt.git"')) {
        throw "TYO helper does not explicitly select the tested Hermes fork."
    }
}

Write-Host "tested stack installer tests passed."
