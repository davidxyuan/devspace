function Get-DevSpaceWatchdogTaskActionSpec {
    [CmdletBinding()]
    param(
        [ValidateSet("Vbs", "PowerShell")]
        [string]$TaskLauncher = "Vbs",

        [Parameter(Mandatory)]
        [string]$InstallDir
    )

    $resolvedInstallDir = [System.IO.Path]::GetFullPath($InstallDir)

    if ($TaskLauncher -eq "PowerShell") {
        $watchdogPath = Join-Path $resolvedInstallDir "devspace-watchdog.ps1"
        $configPath = Join-Path $resolvedInstallDir "devspace-watchdog.config.json"
        $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdogPath`" -Once -ConfigPath `"$configPath`""

        return [pscustomobject]@{
            Launcher = "PowerShell"
            Execute = "powershell.exe"
            Arguments = $arguments
            TaskCommand = "powershell.exe $arguments"
        }
    }

    $launcherPath = Join-Path $resolvedInstallDir "run-devspace-watchdog-hidden.vbs"
    $arguments = "`"$launcherPath`" -Once"

    return [pscustomobject]@{
        Launcher = "Vbs"
        Execute = "wscript.exe"
        Arguments = $arguments
        TaskCommand = "wscript.exe $arguments"
    }
}
