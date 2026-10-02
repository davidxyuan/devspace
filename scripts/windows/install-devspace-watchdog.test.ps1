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
    if ($source -notmatch 'system-certs = true' -or $source -notmatch 'UV_SYSTEM_CERTS') {
        throw 'Hermes/uv installer does not opt into Windows system certificates.'
    }
    if ($source -notmatch 'Invoke-WebRequest.+hermes-agent\.nousresearch\.com/install\.ps1.+-OutFile' -or
        $source -notmatch 'powershell\.exe.+\$installScriptPath.+-SkipSetup.+Out-Host') {
        throw 'Hermes Agent full fallback is not staged/output-isolated correctly.'
    }
    if ($source -notmatch '601d98c2709f766290cc3627b035ab73cfd54232' -or
        $source -notmatch 'Installing lightweight Hermes Agent MCP runtime' -or
        $source -notmatch 'https://github\.com/davidxyuan/hermes-agent\.git' -or
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
