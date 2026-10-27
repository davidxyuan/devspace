$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'install-devspace-watchdog.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Installer parser errors: $($errors -join '; ')" }

$testFunction = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-PythonForHermesGpt'
}, $true)
if (-not $testFunction) { throw 'Test-PythonForHermesGpt function not found.' }
. ([scriptblock]::Create($testFunction.Extent.Text))

$agentPythonFunction = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-PythonForHermesAgent'
}, $true)
if (-not $agentPythonFunction) { throw 'Test-PythonForHermesAgent function not found.' }
. ([scriptblock]::Create($agentPythonFunction.Extent.Text))

$invokeCheckedFunction = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Checked'
}, $true)
if (-not $invokeCheckedFunction) { throw 'Invoke-Checked function not found.' }
. ([scriptblock]::Create($invokeCheckedFunction.Extent.Text))
function Fail([string]$message, [string]$fix) { throw $message }

$tempRoot = Join-Path $env:TEMP ('devspace-python-probe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $good = Join-Path $tempRoot 'python-good.cmd'
    $old = Join-Path $tempRoot 'python-old.cmd'
    $bad = Join-Path $tempRoot 'python-bad.cmd'
    $future = Join-Path $tempRoot 'python-future.cmd'
    $nativeGood = Join-Path $tempRoot 'python-native-good.exe'

    [IO.File]::WriteAllText($good, @'
@echo off
echo 3.12.9
exit /b 0
'@)
    [IO.File]::WriteAllText($old, @'
@echo off
echo 3.9.18
exit /b 0
'@)
    [IO.File]::WriteAllText($bad, @'
@echo off
exit /b 1
'@)
    [IO.File]::WriteAllText($future, @'
@echo off
echo 3.14.1
exit /b 0
'@)
    Add-Type -TypeDefinition @'
using System;
public static class NativePythonProbeFixture {
    public static int Main(string[] args) {
        Console.WriteLine("3.12.10");
        return 0;
    }
}
'@ -OutputAssembly $nativeGood -OutputType ConsoleApplication

    if (-not (Test-PythonForHermesGpt $good)) { throw 'Python 3.12 fixture was rejected.' }
    if (-not (Test-PythonForHermesGpt $nativeGood)) { throw 'Native Python-like executable was rejected due to LASTEXITCODE/pipeline handling.' }
    if (Test-PythonForHermesGpt $old) { throw 'Python 3.9 fixture was accepted.' }
    if (Test-PythonForHermesGpt $bad) { throw 'Failed Python fixture was accepted.' }
    if (Test-PythonForHermesGpt 'C:\Users\fixture\AppData\Local\Microsoft\WindowsApps\python.exe') {
        throw 'Windows App Execution Alias was accepted as a real Python runtime.'
    }
    if (-not (Test-PythonForHermesAgent $good)) { throw 'Hermes Agent rejected Python 3.12.' }
    if (Test-PythonForHermesAgent $future) { throw 'Hermes Agent accepted unsupported Python 3.14.' }

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'
        Invoke-Checked { & cmd.exe /d /c 'echo benign-native-stderr 1>&2 & exit /b 0' 2>&1 | Out-Null } 'stderr-only native command was treated as failure'
        $nonzeroRejected = $false
        try {
            Invoke-Checked { & cmd.exe /d /c 'exit /b 7' } 'nonzero-native-command'
        } catch {
            if ($_.Exception.Message -match 'nonzero-native-command') { $nonzeroRejected = $true } else { throw }
        }
        if (-not $nonzeroRejected) { throw 'Invoke-Checked accepted a nonzero native exit code.' }
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    $source = Get-Content -LiteralPath $scriptPath -Raw
    $sourceFinder = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Find-HermesAgentSourceRoot' }, $true)
    . ([scriptblock]::Create($sourceFinder.Extent.Text))
    $originalLocalAppData = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = Join-Path $tempRoot 'local'
        $oldRoot = Join-Path $env:LOCALAPPDATA 'hermes\hermes-agent'
        $managed = Join-Path $tempRoot 'managed\revision'
        $payload = Join-Path $managed 'payload'
        foreach ($root in @($oldRoot,$payload)) {
            [void][IO.Directory]::CreateDirectory((Join-Path $root 'hermes_cli'))
            [IO.File]::WriteAllText((Join-Path $root 'pyproject.toml'), '[project]')
        }
        $exe = Join-Path $managed 'venv\Scripts\hermes.exe'
        if ((Find-HermesAgentSourceRoot $exe) -ne [IO.Path]::GetFullPath($payload)) { throw 'Managed Agent source was replaced by an unrelated legacy checkout.' }
        if (Find-HermesAgentSourceRoot (Join-Path $tempRoot 'unknown\hermes.exe')) { throw 'Unknown executable silently adopted the default Agent source.' }
    } finally { $env:LOCALAPPDATA = $originalLocalAppData }
    $fastInstall = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-HermesAgentRuntimeFast' }, $true)
    . ([scriptblock]::Create($fastInstall.Extent.Text))
    try {
        $env:LOCALAPPDATA = Join-Path $tempRoot 'pm-install'
        $releasePolicy = @{ components = @{ 'hermes-agent' = @{ revision = ('a' * 40); ref = 'v0.22.2'; repository = 'NousResearch/hermes-agent' } } }
        $fakeGit = Join-Path $tempRoot 'git-pm.ps1'
        [IO.File]::WriteAllText($fakeGit, @'
if ($args[0] -eq 'clone') {
    $pm = Join-Path $args[-1] 'pm'
    [void][IO.Directory]::CreateDirectory($pm)
    [IO.File]::WriteAllText((Join-Path $pm 'lock.json'), '{}')
} else { 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
$global:LASTEXITCODE = 0
'@)
        function Find-GitForClone { return $fakeGit }
        function Find-PythonForHermesAgent { return $nativeGood }
        $rejected = $false
        try { Install-HermesAgentRuntimeFast | Out-Null } catch {
            if ($_.Exception.Message -match 'official package manager.*not supported') { $rejected = $true } else { throw }
        }
        if (-not $rejected) { throw 'Fast installer accepted PM-owned Agent source.' }
        if (Test-Path (Join-Path $env:LOCALAPPDATA 'hermes\hermes-agent\venv')) { throw 'Fast installer created a legacy venv for PM-owned source.' }
    } finally { $env:LOCALAPPDATA = $originalLocalAppData }
    if ($source.IndexOf('stack-hermes-source.py') -lt 0 -or $source.IndexOf('stack-hermes-source.py') -gt $source.IndexOf('$installTransaction = Start-InstallTransaction')) { throw 'Hermes source preflight must happen before installation starts its transaction.' }
    if (-not $source.Contains('set "HERMES_AGENT_ROOT=$hermesAgentWorkingDirectory"')) { throw 'Generated Hermes launcher omits the selected Agent source.' }
    if ($source -notmatch 'Install-WingetPackage\s+"Python\.Python\.3\.12"\s+"Python 3"') {
        throw 'Python 3.12 winget fallback is missing.'
    }
    if ($source -notmatch '\$python\s*=\s*Find-UsablePythonForHermesGpt') {
        throw 'Python fallback is not re-probed after installation.'
    }
    if ($source -match '\[scriptblock\]::Create\(\$installScript\)') {
        throw 'Hermes Agent installer still executes downloaded PowerShell dynamically.'
    }
    if ($source -notmatch 'hermes\\bin\\hermes\.exe') {
        throw 'Hermes Agent discovery does not include the official %LOCALAPPDATA%\hermes\bin\hermes.exe path.'
    }
    if ($source -match 'hermes-agent\.nousresearch\.com/install\.ps1' -or $source -notmatch 'stack-release-policy\.cjs') {
        throw 'Installation must use the shared pinned release policy, without a floating fallback.'
    }
    if ($source -notmatch '\$commit = \[string\]\$pin\.revision' -or
        $source -notmatch '\$ref = \[string\]\$pin\.ref' -or
        $source -notmatch 'Installing lightweight Hermes Agent MCP runtime' -or
        $source -notmatch '\[string\]\$pin\.repository' -or
        $source -notmatch 'pip install --disable-pip-version-check -e' -or
        $source -notmatch 'hermesAgentExe = if \(\$hermesAgentPath\)' -or
        $source -notmatch 'hermesAgentWorkingDirectory = \$hermesAgentWorkingDirectory') {
        throw 'Hermes Agent fast runtime or explicit runtime identity fields are missing.'
    }
    if ($source -notmatch 'Set-WatchdogNgrokCredential.+\$effectiveNgrokAuthtoken' -or
        $source -notmatch 'Get-WatchdogNgrokCredential.+\$watchdogConfig' -or
        $source -notmatch 'ngrok Auth Token could not be persisted') {
        throw 'Installer does not verify ngrok DPAPI credential persistence after receiving a token.'
    }

    Write-Output 'install-devspace-watchdog Python/runtime/token bootstrap tests passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
