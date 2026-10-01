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

    if (-not (Test-PythonForHermesGpt $good)) { throw 'Python 3.12 fixture was rejected.' }
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
    if ($source -notmatch 'Invoke-WebRequest.+hermes-agent\.nousresearch\.com/install\.ps1.+-OutFile') {
        throw 'Hermes Agent installer is not staged as a file before execution.'
    }

    Write-Output 'install-devspace-watchdog Python/runtime bootstrap tests passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
