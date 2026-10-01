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

$tempRoot = Join-Path $env:TEMP ('devspace-python-probe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $good = Join-Path $tempRoot 'python-good.cmd'
    $old = Join-Path $tempRoot 'python-old.cmd'
    $bad = Join-Path $tempRoot 'python-bad.cmd'
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
    if ($source -notmatch 'Invoke-WebRequest.+hermes-agent\.nousresearch\.com/install\.ps1.+-OutFile') {
        throw 'Hermes Agent installer is not staged as a file before execution.'
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
