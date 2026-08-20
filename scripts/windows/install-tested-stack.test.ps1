$ErrorActionPreference = "Stop"
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$installerPath = Join-Path $PSScriptRoot "install-tested-stack.ps1"
$installer = Get-Content -LiteralPath $installerPath -Raw
$html = Get-Content -LiteralPath (Join-Path $root "docs\windows-new-pc-install.zh-TW.html") -Raw
$tyoAgent = Get-Content -LiteralPath (Join-Path $PSScriptRoot "install-devspace-chatgpt-tyo-agent.ps1") -Raw
$tyoCloud = Get-Content -LiteralPath (Join-Path $PSScriptRoot "install-devspace-chatgpt-tyo-cloud.ps1") -Raw
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$addCandidateAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Add-PythonCandidate" }, $true)
if (-not $addCandidateAst) { throw "Missing Add-PythonCandidate." }
Invoke-Expression $addCandidateAst.Extent.Text
$candidateList = New-Object System.Collections.Generic.List[string]
$leakedOutput = @(Add-PythonCandidate $candidateList " C:\Python311\python.exe ")
if ($leakedOutput.Count -ne 0) { throw "Add-PythonCandidate leaked List.Add() output into the PowerShell pipeline." }
if ($candidateList.Count -ne 1 -or $candidateList[0] -ne "C:\Python311\python.exe") { throw "Add-PythonCandidate did not add/trim the candidate correctly." }

@(
    '$DevSpaceVersion = "1.0.4"',
    '$DevSpaceRef = "fix/windows-new-pc-installer-hardening-20260820"',
    '$DevSpaceCommit = "057de105c25c922e1ec3324e1b48509818fd2472"',
    '$HermesVersion = "0.5.0"',
    '$HermesRef = "fix/windows-new-pc-installer-hardening-20260820"',
    '$HermesCommit = "0db9e25d2c0896481cb9521eedae7096523be808"',
    '[string]$PythonPath',
    '[switch]$VerifyOnly',
    '[void]$List.Add($Path.Trim())',
    'Get-PythonRuntimeInfo',
    'Get-PythonRuntimeInfo -Path $PythonPath -RequireVenv',
    'Explicit -PythonPath is not a usable Python',
    'Get-PythonRuntimeInfo -Path $managedPythonFallbackExe -RequireVenv',
    'failed version/runtime/pip/venv validation',
    '-m venv $venvRoot',
    '-m pip --version',
    'Require-CompatiblePython',
    'Python.Python.3.12',
    'Try-InstallWingetPackage',
    '$managedPythonFallbackVersion = "3.11.9"',
    '$managedPythonFallbackDir = Join-Path $InstallRoot "tools\python\3.11.9"',
    'Install-ManagedPythonFallback',
    'https://www.python.org/ftp/python/$version/$fileName',
    'Get-AuthenticodeSignature',
    'Python Software Foundation',
    'Registry::HKEY_CURRENT_USER\Software\Python\PythonCore',
    'Registry::HKEY_LOCAL_MACHINE\Software\Python\PythonCore',
    'Programs\Python\Python312\python.exe',
    'TargetDir=`"$managedPythonFallbackDir`"',
    'InstallAllUsers=0',
    'Include_pip=1',
    '0x8A15002B',
    'cannot relocate an already-registered 3.12 during Modify mode',
    'Test-NodeNpmPreflight',
    'NODE_USE_SYSTEM_CA',
    'ping --registry=https://registry.npmjs.org/',
    'strict-ssl is already disabled outside this installer',
    'strict-ssl=false is not used as a permanent workaround',
    'Install-PinnedRepo $HermesRepo $HermesRef $HermesCommit $hermesDir',
    'No OAuth state, secrets, routes, SQLite data, or scheduled tasks were copied or created.'
) | ForEach-Object {
    if (-not $installer.Contains($_)) { throw "Installer is missing expected pinned/safety/bootstrap text: $_" }
}
if ($installer.Contains('$managedPython312Dir')) {
    throw "Installer must not try to relocate an already-installed Python 3.12 into InstallRoot."
}
if ($installer.Contains('TargetDir=`"$managedPython312Dir`"')) {
    throw "Installer still contains the broken Python 3.12 relocation flow."
}
if ($installer.Contains('$existingVersionText:')) {
    throw "Installer contains invalid PowerShell interpolation: `$existingVersionText:"
}
if ($installer.Contains('$versionText:')) {
    throw "Installer contains invalid PowerShell interpolation: `$versionText:"
}

if (-not $html.Contains('clone --depth 1 --branch "fix/windows-new-pc-installer-hardening-20260820"')) {
    throw "HTML does not clone the complete tested installer branch before execution."
}
if (-not $html.Contains('powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer')) {
    throw "HTML does not execute the installer from a real .ps1 file."
}
if ($html.Contains('([scriptblock]::Create((Invoke-RestMethod "https://raw.githubusercontent.com')) {
    throw "HTML still emits the old ScriptBlock/Invoke-RestMethod installer flow."
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
