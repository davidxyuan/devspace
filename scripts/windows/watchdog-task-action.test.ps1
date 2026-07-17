[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "watchdog-task-action.ps1")

function Assert-Equal([string]$name, $actual, $expected) {
    if ($actual -ne $expected) {
        throw "$name failed.`nExpected: $expected`nActual:   $actual"
    }
}

$installDir = Join-Path $env:TEMP "DevSpace Launcher Test"
$resolvedInstallDir = [System.IO.Path]::GetFullPath($installDir)

$vbs = Get-DevSpaceWatchdogTaskActionSpec -TaskLauncher Vbs -InstallDir $installDir
$vbsPath = Join-Path $resolvedInstallDir "run-devspace-watchdog-hidden.vbs"
Assert-Equal "VBS launcher" $vbs.Launcher "Vbs"
Assert-Equal "VBS executable" $vbs.Execute "wscript.exe"
Assert-Equal "VBS arguments" $vbs.Arguments "`"$vbsPath`" -Once"
Assert-Equal "VBS task command" $vbs.TaskCommand "wscript.exe `"$vbsPath`" -Once"

$powerShell = Get-DevSpaceWatchdogTaskActionSpec -TaskLauncher PowerShell -InstallDir $installDir
$watchdogPath = Join-Path $resolvedInstallDir "devspace-watchdog.ps1"
$configPath = Join-Path $resolvedInstallDir "devspace-watchdog.config.json"
$powerShellArguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdogPath`" -Once -ConfigPath `"$configPath`""
Assert-Equal "PowerShell launcher" $powerShell.Launcher "PowerShell"
Assert-Equal "PowerShell executable" $powerShell.Execute "powershell.exe"
Assert-Equal "PowerShell arguments" $powerShell.Arguments $powerShellArguments
Assert-Equal "PowerShell task command" $powerShell.TaskCommand "powershell.exe $powerShellArguments"

$invalidRejected = $false
try {
    Get-DevSpaceWatchdogTaskActionSpec -TaskLauncher Invalid -InstallDir $installDir | Out-Null
} catch {
    $invalidRejected = $true
}

if (-not $invalidRejected) {
    throw "Invalid TaskLauncher value was not rejected."
}

$installerSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot "install-devspace-watchdog.ps1") -Raw
if ($installerSource -notmatch '(?s)if \(\$NoElevate\).+?\$TaskLauncher -eq "PowerShell".+?requires administrator permission') {
    throw "Non-elevated PowerShell task registration must fail before installation."
}
if ($installerSource -notmatch '\$UserMode -and \$TaskLauncher -eq "Vbs"') {
    throw "Only the VBS user-mode launcher may skip elevation."
}
if ($installerSource -notmatch '\$useSchtasks = \(\$UserMode -or \$NoElevate\) -and -not \(Test-IsElevated\)') {
    throw "Elevated user-mode installs must use the S4U registration path."
}
if ($installerSource -notmatch '(?s)Stop-ScheduledTask -TaskName \$oldTaskName.+?if \(\$oldTaskName -ne \$taskName\).+?Unregister-ScheduledTask') {
    throw "A failed replacement must leave the current watchdog task registered."
}
if ($installerSource -match '-LogonType\s+Interactive') {
    throw "Elevated task registration must not use an interactive principal."
}
if ($installerSource -notmatch '-LogonType\s+S4U') {
    throw "Elevated task registration must use an S4U principal."
}

Write-Host "watchdog-task-action tests passed."
