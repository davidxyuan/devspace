[CmdletBinding()]
param(
    [string]$InstallDir = "$env:USERPROFILE\.devspace",
    [string]$AllowedRoots,
    [string]$PublicBaseUrl,
    [int]$Port = 7676,
    [string]$NgrokPath,
    [string]$NodePath,
    [string]$CliPath,
    [switch]$UsePublishedPackage,
    [switch]$InstallTools,
    [switch]$SkipNpmInstall,
    [switch]$SkipNgrok,
    [switch]$SkipStart,
    [switch]$NoElevate
)

$ErrorActionPreference = "Stop"

function Test-IsElevated {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-ElevatedIfNeeded {
    if ((Test-IsElevated) -or $NoElevate) {
        return
    }

    $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Key -eq "NoElevate") {
            continue
        }
        if ($entry.Value -is [switch]) {
            if ($entry.Value.IsPresent) {
                $args += "-$($entry.Key)"
            }
        } else {
            $args += "-$($entry.Key)"
            $args += "`"$($entry.Value)`""
        }
    }
    $args += "-NoElevate"

    Write-Host "Requesting administrator permission to install tools and register the Highest scheduled task..."
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList ($args -join " ") -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
}

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Find-CommandPath([string]$name) {
    Refresh-Path
    $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return $command.Source
    }
    return $null
}

function Install-WingetPackage([string]$packageId, [string]$displayName) {
    $winget = Find-CommandPath "winget.exe"
    if (-not $winget) {
        throw "$displayName is missing and winget.exe is not available. Install $displayName manually or rerun on a Windows version with winget."
    }

    Write-Host "Installing $displayName with winget..."
    & $winget install --id $packageId --exact --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $displayName ($packageId)."
    }
    Refresh-Path
}

function Ensure-Command([string]$name, [string]$packageId, [string]$displayName) {
    $path = Find-CommandPath $name
    if ($path) {
        return $path
    }
    if (-not $InstallTools) {
        throw "$displayName is missing. Rerun with -InstallTools to install it with winget."
    }
    Install-WingetPackage $packageId $displayName
    $path = Find-CommandPath $name
    if (-not $path) {
        throw "$displayName was installed but $name is still not on PATH."
    }
    return $path
}

function New-OwnerToken {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Split-Roots([string]$rootsText) {
    @(
        $rootsText -split "[;,]" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ } |
            ForEach-Object { [System.IO.Path]::GetFullPath($_) }
    )
}

Restart-ElevatedIfNeeded

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$gitPath = Ensure-Command "git.exe" "Git.Git" "Git for Windows"
if (-not $NodePath) {
    $NodePath = Ensure-Command "node.exe" "OpenJS.NodeJS.LTS" "Node.js LTS"
}
$npmPath = Ensure-Command "npm.cmd" "OpenJS.NodeJS.LTS" "npm"

if (-not $SkipNgrok) {
    if (-not $NgrokPath) {
        $NgrokPath = Find-CommandPath "ngrok.exe"
        if (-not $NgrokPath) {
            if (-not $InstallTools) {
                throw "ngrok.exe is missing. Rerun with -InstallTools or pass -NgrokPath."
            }
            Install-WingetPackage "Ngrok.Ngrok" "ngrok"
            $NgrokPath = Find-CommandPath "ngrok.exe"
        }
    }
    if (-not $NgrokPath -or -not (Test-Path -LiteralPath $NgrokPath)) {
        throw "ngrok.exe was not found. Pass -NgrokPath or install ngrok."
    }
}

if (-not $CliPath) {
    if ($UsePublishedPackage) {
        Write-Host "Installing @waishnav/devspace globally..."
        & $npmPath install -g "@waishnav/devspace"
        if ($LASTEXITCODE -ne 0) {
            throw "npm install -g @waishnav/devspace failed."
        }
        $globalRoot = (& $npmPath root -g).Trim()
        $CliPath = Join-Path $globalRoot "@waishnav\devspace\dist\cli.js"
    } else {
        if (-not $SkipNpmInstall) {
            Write-Host "Installing repo dependencies..."
            & $npmPath install --include=dev --prefix $repoRoot
            if ($LASTEXITCODE -ne 0) {
                throw "npm install failed."
            }
        }

        Write-Host "Building DevSpace from this checkout..."
        Push-Location $repoRoot
        try {
            & $npmPath run build
            if ($LASTEXITCODE -ne 0) {
                throw "npm run build failed."
            }
        } finally {
            Pop-Location
        }
        $CliPath = Join-Path $repoRoot "dist\cli.js"
    }
}

if (-not (Test-Path -LiteralPath $CliPath)) {
    throw "DevSpace CLI was not found: $CliPath"
}

$configPath = Join-Path $InstallDir "config.json"
$authPath = Join-Path $InstallDir "auth.json"
$existingConfig = Read-JsonFile $configPath
$existingAuth = Read-JsonFile $authPath

if (-not $PublicBaseUrl) {
    $PublicBaseUrl = [string]$existingConfig.publicBaseUrl
}
if (-not $PublicBaseUrl) {
    throw "Missing -PublicBaseUrl. Use your stable ngrok/Cloudflare/Tailscale public origin without /mcp."
}
$PublicBaseUrl = $PublicBaseUrl.TrimEnd("/")

$allowedRootList = @()
if ($AllowedRoots) {
    $allowedRootList = Split-Roots $AllowedRoots
} elseif ($existingConfig.allowedRoots) {
    $allowedRootList = @($existingConfig.allowedRoots)
} else {
    $allowedRootList = @($repoRoot)
}

$devspaceConfig = [ordered]@{
    host = "127.0.0.1"
    port = $Port
    allowedRoots = $allowedRootList
    publicBaseUrl = $PublicBaseUrl
}
$devspaceConfig | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8

$ownerToken = [string]$existingAuth.ownerToken
if (-not $ownerToken) {
    $ownerToken = New-OwnerToken
}
@{ ownerToken = $ownerToken } | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath $authPath -Encoding UTF8

Copy-Item -LiteralPath (Join-Path $PSScriptRoot "devspace-watchdog.ps1") -Destination (Join-Path $InstallDir "devspace-watchdog.ps1") -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "run-devspace-watchdog-hidden.vbs") -Destination (Join-Path $InstallDir "run-devspace-watchdog-hidden.vbs") -Force

$watchdogConfig = [ordered]@{
    stateDir = $InstallDir
    port = $Port
    retiredPorts = @(7677)
    nodePath = [System.IO.Path]::GetFullPath($NodePath)
    cliPath = [System.IO.Path]::GetFullPath($CliPath)
    ngrokPath = if ($SkipNgrok) { "" } else { [System.IO.Path]::GetFullPath($NgrokPath) }
    manageNgrok = -not $SkipNgrok
    publicBaseUrl = $PublicBaseUrl
}
$watchdogConfig | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $InstallDir "devspace-watchdog.config.json") -Encoding UTF8

$legacyTaskName = "DevSpaceNgrokWatchdog"
$taskName = "DevSpaceNgrokWatchdogPoller"
Stop-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false -ErrorAction SilentlyContinue
Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$launcherPath = Join-Path $InstallDir "run-devspace-watchdog-hidden.vbs"
$action = New-ScheduledTaskAction `
    -Execute "wscript.exe" `
    -Argument "`"$launcherPath`" -Once"
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
$pollTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal `
    -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive `
    -RunLevel Highest

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger @($logonTrigger, $pollTrigger) `
    -Settings $settings `
    -Principal $principal `
    -Description "Runs the DevSpace watchdog every minute in the background with highest privileges." `
    -Force | Out-Null

if (-not $SkipStart) {
    Start-ScheduledTask -TaskName $taskName
}

Write-Host "DevSpace watchdog installed."
Write-Host "Config: $configPath"
Write-Host "Auth: $authPath"
Write-Host "Owner password: $ownerToken"
Write-Host "Local MCP URL: http://127.0.0.1:$Port/mcp"
Write-Host "Public MCP URL: $PublicBaseUrl/mcp"
