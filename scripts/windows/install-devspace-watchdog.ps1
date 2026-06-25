[CmdletBinding()]
param(
    [string]$InstallDir = "$env:USERPROFILE\.devspace",
    [string]$AllowedRoots,
    [string]$PublicBaseUrl,
    [ValidateSet("AgentEndpoint", "CloudEndpoint")]
    [string]$NgrokEndpointMode,
    [string]$NgrokAgentBaseUrl,
    [string]$NgrokBinding,
    [int]$Port = 7676,
    [string]$NgrokPath,
    [string]$NodePath,
    [string]$CliPath,
    [string[]]$Components = @("DevSpace"),
    [string]$HermesRepo = "https://github.com/asimons81/hermes-gpt.git",
    [string]$HermesDir = "$env:USERPROFILE\hermes-gpt",
    [string]$PythonPath,
    [string]$MachineName,
    [string]$HermesAgentExe,
    [int]$HermesPort = 4750,
    [int]$RouterPort = 8765,
    [switch]$UsePublishedPackage,
    [switch]$InstallTools,
    [switch]$SkipNpmInstall,
    [switch]$SkipHermesInstall,
    [switch]$SkipHermesAgentInstall,
    [switch]$FullAccess,
    [switch]$SkipNgrok,
    [switch]$SkipStart,
    [switch]$UserMode,
    [switch]$NoElevate
)

$ErrorActionPreference = "Stop"

function Test-IsElevated {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-ElevatedIfNeeded {
    if ((Test-IsElevated) -or $UserMode -or $NoElevate) {
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
        } elseif ($entry.Value -is [array]) {
            $args += "-$($entry.Key)"
            foreach ($item in $entry.Value) {
                $args += "`"$item`""
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
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Write-JsonFile([string]$path, $value, [int]$depth = 4) {
    $json = ($value | ConvertTo-Json -Depth $depth) + [Environment]::NewLine
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Split-Roots([string]$rootsText) {
    @(
        $rootsText -split "[;,]" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ } |
            ForEach-Object { [System.IO.Path]::GetFullPath($_) }
    )
}

function Get-FullAccessRoots {
    @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root } | ForEach-Object { $_.Root })
}

function ConvertTo-Slug([string]$value) {
    ($value.Trim().ToLowerInvariant() -replace "[^a-z0-9]+", "-" -replace "^-+|-+$", "")
}

function Get-ComponentList {
    $valid = @("DevSpace", "Hermes")
    $result = @()
    foreach ($component in @($Components)) {
        foreach ($part in ([string]$component -split ",")) {
            $name = $part.Trim()
            if (-not $name) {
                continue
            }
            if ($valid -notcontains $name) {
                throw "Invalid component '$name'. Valid components: $($valid -join ', ')."
            }
            $result += $name
        }
    }
    if ($result.Count -eq 0) {
        throw "At least one component is required. Valid components: $($valid -join ', ')."
    }
    return $result | Select-Object -Unique
}

function Test-Component([string]$name) {
    return @($componentList) -contains $name
}

function Invoke-Checked([scriptblock]$command, [string]$message) {
    & $command
    if ($LASTEXITCODE -ne 0) {
        throw $message
    }
}

function Find-HermesAgentExe {
    if ($HermesAgentExe -and (Test-Path -LiteralPath $HermesAgentExe)) {
        return [System.IO.Path]::GetFullPath($HermesAgentExe)
    }

    $command = Find-CommandPath "hermes.exe"
    if ($command) {
        return $command
    }

    $localExe = Join-Path $env:LOCALAPPDATA "hermes\hermes-agent\venv\Scripts\hermes.exe"
    if (Test-Path -LiteralPath $localExe) {
        return $localExe
    }

    return $null
}

function Install-HermesAgentIfNeeded {
    if (-not $installHermes) {
        return $null
    }

    $exe = Find-HermesAgentExe
    if ($exe) {
        return $exe
    }
    if ($SkipHermesAgentInstall) {
        throw "Hermes Agent is missing. Install it first or omit -SkipHermesAgentInstall."
    }

    Write-Host "Installing Hermes Agent..."
    $installScript = Invoke-RestMethod -Uri "https://hermes-agent.nousresearch.com/install.ps1"
    & ([scriptblock]::Create($installScript)) -SkipSetup
    $exe = Find-HermesAgentExe
    if (-not $exe) {
        throw "Hermes Agent install finished, but hermes.exe was not found."
    }
    return $exe
}

function Find-GitForClone {
    $command = Find-CommandPath "git.exe"
    if ($command) {
        return $command
    }

    $hermesGit = Join-Path $env:LOCALAPPDATA "hermes\git\cmd\git.exe"
    if (Test-Path -LiteralPath $hermesGit) {
        return $hermesGit
    }

    if ($InstallTools) {
        Install-WingetPackage "Git.Git" "Git for Windows"
        return Ensure-Command "git.exe" "Git.Git" "Git for Windows"
    }
    throw "Git is missing. Rerun with -InstallTools or install Hermes Agent/Git first."
}

function Find-PythonForHermesGpt {
    if ($PythonPath -and (Test-Path -LiteralPath $PythonPath)) {
        return [System.IO.Path]::GetFullPath($PythonPath)
    }

    $hermesPython = Join-Path $env:LOCALAPPDATA "hermes\hermes-agent\venv\Scripts\python.exe"
    if (Test-Path -LiteralPath $hermesPython) {
        return $hermesPython
    }

    $command = Find-CommandPath "python.exe"
    if ($command) {
        return $command
    }

    if ($InstallTools) {
        Install-WingetPackage "Python.Python.3.12" "Python 3"
        return Ensure-Command "python.exe" "Python.Python.3.12" "Python 3"
    }
    throw "Python is missing. Rerun with -InstallTools or install Hermes Agent/Python first."
}

function Get-UrlOrigin([string]$Url) {
    try {
        $uri = [Uri]$Url
    } catch {
        throw "Invalid URL: $Url"
    }
    if (-not $uri.Scheme -or -not $uri.Host) {
        throw "Invalid URL: $Url"
    }
    return $uri.GetLeftPart([System.UriPartial]::Authority).TrimEnd("/")
}

function Join-UrlPath([string]$Origin, [string]$Path) {
    return "$($Origin.TrimEnd("/"))/$($Path.TrimStart("/"))"
}

Restart-ElevatedIfNeeded

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$HermesDir = [System.IO.Path]::GetFullPath($HermesDir)
$componentList = Get-ComponentList
$installDevSpace = Test-Component "DevSpace"
$installHermes = Test-Component "Hermes"
$useRouter = $installDevSpace -or $installHermes
$MachineName = if ($MachineName) { $MachineName } else { [System.Net.Dns]::GetHostName() }
$machineSlug = ConvertTo-Slug $MachineName
if (-not $machineSlug) {
    throw "Missing machine name. Pass -MachineName."
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$needsNode = $installDevSpace -or $useRouter

if ($needsNode -and -not $NodePath) {
    $NodePath = Ensure-Command "node.exe" "OpenJS.NodeJS.LTS" "Node.js LTS"
}
if ($installDevSpace) {
    $npmPath = Ensure-Command "npm.cmd" "OpenJS.NodeJS.LTS" "npm"
}
$hermesAgentPath = Install-HermesAgentIfNeeded

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

if ($installDevSpace) {
    if (-not $CliPath) {
        if ($UsePublishedPackage) {
            Write-Host "Installing @waishnav/devspace globally..."
            Invoke-Checked { & $npmPath install -g "@waishnav/devspace" } "npm install -g @waishnav/devspace failed."
            $globalRoot = (& $npmPath root -g).Trim()
            $CliPath = Join-Path $globalRoot "@waishnav\devspace\dist\cli.js"
        } else {
            if (-not $SkipNpmInstall) {
                Write-Host "Installing repo dependencies..."
                Invoke-Checked { & $npmPath install --include=dev --prefix $repoRoot } "npm install failed."
            }

            Write-Host "Building DevSpace from this checkout..."
            Push-Location $repoRoot
            try {
                Invoke-Checked { & $npmPath run build } "npm run build failed."
            } finally {
                Pop-Location
            }
            $CliPath = Join-Path $repoRoot "dist\cli.js"
        }
    }

    if (-not (Test-Path -LiteralPath $CliPath)) {
        throw "DevSpace CLI was not found: $CliPath"
    }
}

$configPath = Join-Path $InstallDir "config.json"
$authPath = Join-Path $InstallDir "auth.json"
$watchdogConfigPath = Join-Path $InstallDir "devspace-watchdog.config.json"
$existingConfig = Read-JsonFile $configPath
$existingAuth = Read-JsonFile $authPath
$existingWatchdogConfig = Read-JsonFile $watchdogConfigPath

if (-not $PublicBaseUrl) {
    $PublicBaseUrl = [string]$existingConfig.publicBaseUrl
}
if (-not $PublicBaseUrl) {
    throw "Missing -PublicBaseUrl. Use your stable ngrok/Cloudflare/Tailscale public origin without /mcp."
}
$providedPublicBaseUrl = $PublicBaseUrl.TrimEnd("/")
$publicOrigin = Get-UrlOrigin $providedPublicBaseUrl
$devspaceRoutePrefix = "/$machineSlug/devspace_chatgpt"
$hermesRoutePrefix = "/$machineSlug/hermes_chatgpt"
$devspacePublicBaseUrl = if ($installDevSpace) {
    Join-UrlPath $publicOrigin $devspaceRoutePrefix
} else {
    $providedPublicBaseUrl
}
$PublicBaseUrl = if ($installDevSpace) { $devspacePublicBaseUrl } else { $providedPublicBaseUrl }
if (-not $NgrokEndpointMode) {
    $NgrokEndpointMode = [string]$existingWatchdogConfig.ngrokEndpointMode
}
if (-not $NgrokEndpointMode) {
    $NgrokEndpointMode = "AgentEndpoint"
}

if ($NgrokEndpointMode -eq "CloudEndpoint") {
    if (-not $NgrokAgentBaseUrl) {
        $NgrokAgentBaseUrl = [string]$existingWatchdogConfig.ngrokAgentBaseUrl
    }
    if (-not $NgrokAgentBaseUrl) {
        $NgrokAgentBaseUrl = "https://$machineSlug-devspace.internal"
    }
    if (-not $NgrokBinding) {
        $NgrokBinding = [string]$existingWatchdogConfig.ngrokBinding
    }
    if (-not $NgrokBinding) {
        $NgrokBinding = "internal"
    }
} else {
    if (-not $NgrokAgentBaseUrl) {
        $NgrokAgentBaseUrl = [string]$existingWatchdogConfig.ngrokAgentBaseUrl
    }
    if (-not $NgrokAgentBaseUrl) {
        $NgrokAgentBaseUrl = $publicOrigin
    }
    $NgrokAgentBaseUrl = Get-UrlOrigin $NgrokAgentBaseUrl
    $NgrokBinding = ""
}
$NgrokAgentBaseUrl = $NgrokAgentBaseUrl.TrimEnd("/")

if ($installDevSpace) {
    $allowedRootList = @()
    if ($FullAccess) {
        $allowedRootList = Get-FullAccessRoots
    } elseif ($AllowedRoots) {
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
    Write-JsonFile $configPath $devspaceConfig 4

    $ownerToken = [string]$existingAuth.ownerToken
    if (-not $ownerToken) {
        $ownerToken = New-OwnerToken
    }
    Write-JsonFile $authPath @{ ownerToken = $ownerToken } 2
}

Copy-Item -LiteralPath (Join-Path $PSScriptRoot "devspace-watchdog.ps1") -Destination (Join-Path $InstallDir "devspace-watchdog.ps1") -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "run-devspace-watchdog-hidden.vbs") -Destination (Join-Path $InstallDir "run-devspace-watchdog-hidden.vbs") -Force

$hermesCommandPath = ""
if ($installHermes) {
    if (-not $SkipHermesInstall) {
        if (-not (Test-Path -LiteralPath $HermesDir)) {
            Write-Host "Cloning hermes-gpt..."
            $gitPath = Find-GitForClone
            Invoke-Checked { & $gitPath clone $HermesRepo $HermesDir } "git clone hermes-gpt failed."
        }

        $venvPython = Join-Path $HermesDir ".venv\Scripts\python.exe"
        if (-not (Test-Path -LiteralPath $venvPython)) {
            Write-Host "Creating hermes-gpt virtual environment..."
            $PythonPath = Find-PythonForHermesGpt
            Invoke-Checked { & $PythonPath -m venv (Join-Path $HermesDir ".venv") } "python -m venv failed."
        }

        $requirementsPath = Join-Path $HermesDir "requirements.txt"
        if (Test-Path -LiteralPath $requirementsPath) {
            Write-Host "Installing hermes-gpt Python dependencies..."
            Invoke-Checked { & $venvPython -m pip install -r $requirementsPath } "pip install hermes-gpt requirements failed."
        }
    }

    $hermesPython = Join-Path $HermesDir ".venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $hermesPython)) {
        $hermesPython = [System.IO.Path]::GetFullPath($PythonPath)
    }
    $hermesServer = Join-Path $HermesDir "server.py"
    if (-not (Test-Path -LiteralPath $hermesServer)) {
        throw "hermes-gpt server.py was not found: $hermesServer"
    }

    $hermesCommandPath = Join-Path $InstallDir "run-hermes-gpt.cmd"
    $hermesWorkingDirectory = $HermesDir
    $hermesFullAccessEnabled = [bool]$FullAccess
    $hermesFullAccessEnv = if ($FullAccess) {
@"
set "HERMES_GPT_ENABLE_WRITE=1"
set "HERMES_GPT_ENABLE_MEMORY_WRITE=1"
set "HERMES_GPT_ENABLE_SESSION_SEARCH=1"
set "HERMES_GPT_ENABLE_TERMINAL=1"
"@
    } else {
        ""
    }
    @"
@echo off
set "HERMES_HOME=%LOCALAPPDATA%\hermes"
$hermesFullAccessEnv
cd /d "$HermesDir"
"$hermesPython" "$hermesServer" --http --host 127.0.0.1 --port $HermesPort
"@ | Set-Content -LiteralPath $hermesCommandPath -Encoding ASCII
}

$routerPath = ""
if ($useRouter) {
    $routerPath = Join-Path $InstallDir "mcp-router.cjs"
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "mcp-router.cjs") -Destination $routerPath -Force
}

$mcpRoutes = @()
if ($installDevSpace) {
    $mcpRoutes += [ordered]@{
        name = "devspace_chatgpt"
        prefix = $devspaceRoutePrefix
        targetHost = "127.0.0.1"
        targetPort = $Port
    }
}
if ($installHermes) {
    $mcpRoutes += [ordered]@{
        name = "hermes_chatgpt"
        prefix = $hermesRoutePrefix
        targetHost = "127.0.0.1"
        targetPort = $HermesPort
    }
}

$watchdogConfig = [ordered]@{
    stateDir = $InstallDir
    machineSlug = $machineSlug
    fullAccess = [bool]$FullAccess
    devspaceEnabled = $installDevSpace
    hermesEnabled = $installHermes
    mcpRoutes = $mcpRoutes
    port = $Port
    retiredPorts = @(7677)
    nodePath = if ($NodePath) { [System.IO.Path]::GetFullPath($NodePath) } else { "" }
    cliPath = if ($CliPath) { [System.IO.Path]::GetFullPath($CliPath) } else { "" }
    hermesCommand = $hermesCommandPath
    hermesPython = if ($installHermes) { [System.IO.Path]::GetFullPath($hermesPython) } else { "" }
    hermesServer = if ($installHermes) { [System.IO.Path]::GetFullPath($hermesServer) } else { "" }
    hermesWorkingDirectory = if ($installHermes) { [System.IO.Path]::GetFullPath($hermesWorkingDirectory) } else { "" }
    hermesFullAccess = if ($installHermes) { $hermesFullAccessEnabled } else { $false }
    hermesPort = if ($installHermes) { $HermesPort } else { 0 }
    routerPath = $routerPath
    routerPort = if ($useRouter) { $RouterPort } else { 0 }
    publicUpstreamPort = $RouterPort
    ngrokPath = if ($SkipNgrok) { "" } else { [System.IO.Path]::GetFullPath($NgrokPath) }
    manageNgrok = -not $SkipNgrok
    publicBaseUrl = $PublicBaseUrl
    ngrokEndpointMode = $NgrokEndpointMode
    ngrokAgentBaseUrl = $NgrokAgentBaseUrl
    ngrokBinding = $NgrokBinding
}
Write-JsonFile $watchdogConfigPath $watchdogConfig 6

$legacyTaskName = "DevSpaceNgrokWatchdog"
$taskName = if ($UserMode -or $NoElevate) { "DevSpaceNgrokWatchdogUserPoller" } else { "DevSpaceNgrokWatchdogPoller" }
$runLevel = if ($UserMode -or $NoElevate) { "Limited" } else { "Highest" }
$modeName = if ($UserMode -or $NoElevate) { "standard user" } else { "administrator" }
foreach ($oldTaskName in @($legacyTaskName, "DevSpaceNgrokWatchdogPoller", "DevSpaceNgrokWatchdogUserPoller", "DevSpace Serve Watchdog")) {
    Stop-ScheduledTask -TaskName $oldTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $oldTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

$watchdogPath = Join-Path $InstallDir "devspace-watchdog.ps1"
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdogPath`" -Once -ConfigPath `"$watchdogConfigPath`""
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
$settings.Hidden = $true
$logonType = if ($UserMode -or $NoElevate) { "S4U" } else { "Interactive" }
$principal = New-ScheduledTaskPrincipal `
    -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType ($logonType) `
    -RunLevel ($runLevel)

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger @($logonTrigger, $pollTrigger) `
    -Settings $settings `
    -Principal $principal `
    -Description "Runs the DevSpace watchdog every minute in the background as $modeName." `
    -Force | Out-Null

if (-not $SkipStart) {
    Start-ScheduledTask -TaskName $taskName
}

Write-Host "DevSpace watchdog installed."
Write-Host "Mode: $modeName"
Write-Host "Machine: $machineSlug"
Write-Host "Scheduled task: $taskName"
Write-Host "Config: $configPath"
Write-Host "ngrok endpoint mode: $NgrokEndpointMode"
Write-Host "Public router base URL: $publicOrigin"
if ($installDevSpace) {
    Write-Host "Auth: $authPath"
    Write-Host "Owner password: $ownerToken"
    Write-Host "Local DevSpace MCP URL: http://127.0.0.1:$Port/mcp"
    Write-Host "Public DevSpace MCP URL: $devspacePublicBaseUrl/mcp"
}
if ($installHermes) {
    Write-Host "Hermes Agent: $hermesAgentPath"
    Write-Host "Local Hermes MCP URL: http://127.0.0.1:$HermesPort/mcp"
    Write-Host "Public Hermes MCP URL: $(Join-UrlPath $publicOrigin "$hermesRoutePrefix/mcp")"
}
if ($NgrokAgentBaseUrl) {
    Write-Host "ngrok Agent Endpoint URL: $NgrokAgentBaseUrl"
}
