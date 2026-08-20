[CmdletBinding()]
param(
    [string]$InstallDir = "$env:USERPROFILE\.devspace",
    [string]$AllowedRoots,
    [string]$PublicBaseUrl,
    [ValidateSet("AgentEndpoint", "CloudEndpoint")]
    [string]$NgrokEndpointMode,
    [string]$NgrokAgentBaseUrl,
    [string]$NgrokBinding,
    [string]$McpNameSuffix,
    [string[]]$RouteAliasMachineNames,
    [string]$CloudEndpointPolicyPath,
    [int]$Port = 7676,
    [string]$NgrokPath,
    [string]$NgrokConfigPath,
    [string]$NgrokAuthtoken,
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
    [ValidateSet("Vbs", "PowerShell")]
    [string]$TaskLauncher = "Vbs",
    [switch]$UsePublishedPackage,
    [switch]$InstallTools,
    [switch]$SkipNpmInstall,
    [switch]$SkipHermesInstall,
    [switch]$SkipHermesAgentInstall,
    [switch]$FullAccess,
    [switch]$SkipNgrok,
    [switch]$SkipStart,
    [switch]$UserMode,
    [switch]$NoElevate,
    [ValidateSet("minimal", "full", "codex")][string]$DevSpaceToolMode = "minimal",
    [ValidateSet("off", "changes", "full")][string]$DevSpaceWidgets = "off",
    [ValidateSet("On", "Off")][string]$DevSpaceSkills = "Off",
    [ValidateSet("On", "Off")][string]$DevSpaceSubagents = "Off",
    [ValidateSet("On", "Off")][string]$HermesBridge = "On",
    [ValidateSet("On", "Off")][string]$HermesReadOnlyTools = "On",
    [ValidateSet("On", "Off")][string]$HermesVision = "Off",
    [ValidateSet("On", "Off")][string]$HermesWeb = "Off",
    [ValidateSet("On", "Off")][string]$HermesDiagnostics = "On",
    [ValidateSet("On", "Off")][string]$HermesRunner = "Off",
    [ValidateSet("On", "Off")][string]$HermesRunnerWrite = "Off",
    [ValidateSet("On", "Off")][string]$HermesWorkspaceWrite = "Off",
    [ValidateSet("On", "Off")][string]$HermesMemoryWrite = "Off",
    [ValidateSet("On", "Off")][string]$HermesTerminal = "Off",
    [ValidateSet("On", "Off")][string]$HermesOperator = "Off",
    [ValidateSet("On", "Off")][string]$HermesOperatorDirect = "Off",
    [ValidateSet("On", "Off")][string]$HermesOwnerMode = "Off",
    [ValidateSet("On", "Off")][string]$HermesCron = "Off",
    [ValidateSet("On", "Off")][string]$HermesCronWrite = "Off",
    [ValidateSet("On", "Off")][string]$HermesSkillWrite = "Off",
    [ValidateSet("On", "Off")][string]$HermesPrivateNetwork = "Off",
    [ValidateSet("restricted", "full")][string]$HermesFilesystemScope = "restricted",
    [string[]]$HermesAllowedRoots = @(),
    [string]$CapabilitySelection = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "watchdog-task-action.ps1")
. (Join-Path $PSScriptRoot "ngrok-install.ps1")
. (Join-Path $PSScriptRoot "capability-config.ps1")
$script:InstallDocsPath = Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))) "docs\windows-watchdog.md"

trap {
    Write-Host ""
    Write-Host "DevSpace watchdog install failed." -ForegroundColor Red
    Write-Host $_.Exception.Message
    if (Test-Path -LiteralPath $script:InstallDocsPath) {
        Write-Host "Troubleshooting: $script:InstallDocsPath"
    }
    exit 1
}

function Fail([string]$message, [string]$fix = "") {
    if ($fix) {
        throw "$message`nFix: $fix"
    }
    throw $message
}

function Get-ListenOwnerDetails([int]$listenPort) {
    @(
        Get-NetTCPConnection -LocalPort $listenPort -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique |
            Where-Object { $_ -and $_ -ne 0 } |
            ForEach-Object { Get-CimInstance Win32_Process -Filter "ProcessId=$_" -ErrorAction SilentlyContinue }
    )
}

function Assert-FixedPortOwnership([int]$listenPort, [string]$serviceName, [string[]]$expectedPaths) {
    foreach ($owner in Get-ListenOwnerDetails $listenPort) {
        $command = [string]$owner.CommandLine
        $isExpected = @($expectedPaths | Where-Object {
            $_ -and $command.IndexOf([string]$_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        }).Count -gt 0
        if (-not $isExpected) {
            Fail "FIXED PORT CONFLICT: $serviceName requires 127.0.0.1:$listenPort, owned by PID $($owner.ProcessId) ($($owner.Name)), command=$command." "Stop or reconfigure that process, then rerun. This installer will not move the service port, stop the owner, or rewrite dependent public routes and clients."
        }
    }
}

function Find-AvailableLoopbackPort([int]$preferredPort, [string[]]$expectedCommandFragments = @()) {
    for ($candidate = $preferredPort; $candidate -lt ($preferredPort + 100); $candidate++) {
        $owners = @(Get-ListenOwnerDetails $candidate)
        if ($owners.Count -eq 0) {
            return $candidate
        }
        if ($candidate -eq $preferredPort -and $expectedCommandFragments.Count -and
            @($owners | Where-Object {
                $command = [string]$_.CommandLine
                @($expectedCommandFragments | Where-Object {
                    $_ -and $command.IndexOf([string]$_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                }).Count -eq 0
            }).Count -eq 0) {
            return $candidate
        }
    }
    Fail "No available loopback port was found for the ngrok inspection UI in the range $preferredPort-$($preferredPort + 99)." "Free one port in that range and rerun."
}

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
    try {
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList ($args -join " ") -Verb RunAs -Wait -PassThru
    } catch {
        Fail "Administrator permission was not granted." "Approve the UAC prompt, or rerun with -UserMode for a current-user install."
    }
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
        Fail "$displayName is missing and winget.exe is not available." "Install App Installer/winget first, install $displayName manually, or run on Windows 10/11 with winget available."
    }

    Write-Host "Installing $displayName with winget..."
    & $winget install --id $packageId --exact --source winget --accept-package-agreements --accept-source-agreements 2>&1 | Out-Host
    $wingetExitCode = $LASTEXITCODE
    if ($wingetExitCode -ne 0) {
        Fail "winget failed to install $displayName ($packageId)." "Open PowerShell as Administrator and rerun with -InstallTools, or install $displayName manually and rerun this installer."
    }
    Refresh-Path
}

function Ensure-Command([string]$name, [string]$packageId, [string]$displayName) {
    $path = Find-CommandPath $name
    if ($path) {
        return $path
    }
    if (-not $InstallTools) {
        Fail "$displayName is missing." "Rerun the same command with -InstallTools, or install $displayName manually and open a new PowerShell window."
    }
    Install-WingetPackage $packageId $displayName
    $path = Find-CommandPath $name
    if (-not $path) {
        Fail "$displayName was installed but $name is still not on PATH." "Close and reopen PowerShell, then rerun this installer. If this is ngrok or Python, you can also pass -NgrokPath or -PythonPath."
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
                Fail "Invalid component '$name'." "Use -Components DevSpace, -Components Hermes, or -Components DevSpace,Hermes."
            }
            $result += $name
        }
    }
    if ($result.Count -eq 0) {
        Fail "At least one component is required." "Use -Components DevSpace, -Components Hermes, or -Components DevSpace,Hermes."
    }
    return $result | Select-Object -Unique
}

function Test-Component([string]$name) {
    return @($componentList) -contains $name
}

function Invoke-Checked([scriptblock]$command, [string]$message) {
    & $command
    if ($LASTEXITCODE -ne 0) {
        Fail $message "Review the command output above, fix that tool-specific error, then rerun the same installer command."
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
        Fail "Hermes Agent is missing." "Remove -SkipHermesAgentInstall so the installer can install it, install Hermes Agent manually, or use -Components DevSpace."
    }

    Write-Host "Installing Hermes Agent..."
    $installScript = Invoke-RestMethod -Uri "https://hermes-agent.nousresearch.com/install.ps1"
    & ([scriptblock]::Create($installScript)) -SkipSetup
    $exe = Find-HermesAgentExe
    if (-not $exe) {
        Fail "Hermes Agent install finished, but hermes.exe was not found." "Open a new PowerShell window and rerun, or pass -HermesAgentExe with the full hermes.exe path."
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
    Fail "Git is missing." "Rerun with -InstallTools, install Git for Windows manually, or install Hermes Agent before selecting -Components Hermes."
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
    Fail "Python is missing." "Rerun with -InstallTools, install Python 3 manually, or install Hermes Agent before selecting -Components Hermes."
}

function Get-UrlOrigin([string]$Url) {
    try {
        $uri = [Uri]$Url
    } catch {
        Fail "Invalid URL: $Url" 'Use a full origin such as https://example.ngrok-free.dev. Do not pass /mcp here.'
    }
    if (-not $uri.Scheme -or -not $uri.Host) {
        Fail "Invalid URL: $Url" 'Use a full origin such as https://example.ngrok-free.dev. Do not pass /mcp here.'
    }
    return $uri.GetLeftPart([System.UriPartial]::Authority).TrimEnd("/")
}

function Join-UrlPath([string]$Origin, [string]$Path) {
    return "$($Origin.TrimEnd("/"))/$($Path.TrimStart("/"))"
}

function Join-McpRouteName([string]$BaseName, [string]$Suffix) {
    $suffixSlug = ConvertTo-Slug $Suffix
    if (-not $suffixSlug) {
        return $BaseName
    }
    return "${BaseName}_$suffixSlug"
}

function New-NgrokCloudEndpointRule([string]$MachineSlug, [string]$InternalUrl) {
    $machinePrefix = "/$MachineSlug/"
    $wellKnownPrefix = "/.well-known/oauth-authorization-server/$MachineSlug/"
    $protectedResourcePrefix = "/.well-known/oauth-protected-resource/$MachineSlug/"
@"
- name: DevSpace $MachineSlug router
  expressions:
    - req.url.path.startsWith("$machinePrefix") || req.url.path.startsWith("$wellKnownPrefix") || req.url.path.startsWith("$protectedResourcePrefix")
  actions:
    - type: forward-internal
      config:
        url: $InternalUrl
        binding: internal
"@
}

function New-NgrokCloudEndpointPolicy([string]$MachineSlug, [string]$InternalUrl) {
    $rule = New-NgrokCloudEndpointRule $MachineSlug $InternalUrl
@"
on_http_request:
$($rule -replace "(?m)^", "  ")
"@
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
    Fail "Missing machine name." 'Pass -MachineName with a URL-safe name, for example -MachineName "david-pc".'
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$configPath = Join-Path $InstallDir "config.json"
$authPath = Join-Path $InstallDir "auth.json"
$watchdogConfigPath = Join-Path $InstallDir "devspace-watchdog.config.json"
$existingConfig = Read-JsonFile $configPath
$existingAuth = Read-JsonFile $authPath
$existingWatchdogConfig = Read-JsonFile $watchdogConfigPath
if (($installDevSpace -and $Port -eq $RouterPort) -or ($installHermes -and $HermesPort -eq $RouterPort) -or
    ($installDevSpace -and $installHermes -and $Port -eq $HermesPort)) {
    Fail "DevSpace, Hermes-GPT, and router ports must be distinct." "Choose three fixed, non-overlapping ports and update their dependent routes and clients explicitly."
}
if ($installDevSpace) {
    Assert-FixedPortOwnership $Port "DevSpace" @([string]$existingWatchdogConfig.cliPath)
}
if ($installHermes) {
    Assert-FixedPortOwnership $HermesPort "Hermes-GPT" @([string]$existingWatchdogConfig.hermesServer, [string]$existingWatchdogConfig.hermesCommand)
}
if ($useRouter) {
    Assert-FixedPortOwnership $RouterPort "MCP router" @([string]$existingWatchdogConfig.routerPath)
}
foreach ($entry in (ConvertFrom-CapabilitySelection $CapabilitySelection).GetEnumerator()) {
    Set-Variable -Name $entry.Key -Value $entry.Value
}
$devspaceCapabilities = New-DevSpaceCapabilityConfig $DevSpaceToolMode $DevSpaceWidgets $DevSpaceSkills $DevSpaceSubagents
$hermesCapabilities = New-HermesCapabilityConfig `
    $HermesBridge $HermesReadOnlyTools $HermesVision $HermesWeb $HermesDiagnostics `
    $HermesRunner $HermesRunnerWrite $HermesWorkspaceWrite $HermesMemoryWrite $HermesTerminal `
    $HermesOperator $HermesOperatorDirect $HermesOwnerMode $HermesCron $HermesCronWrite `
    $HermesSkillWrite $HermesPrivateNetwork $HermesFilesystemScope $HermesAllowedRoots

$needsNode = $installDevSpace -or $useRouter

if ($needsNode -and -not $NodePath) {
    $NodePath = Ensure-Command "node.exe" "OpenJS.NodeJS.LTS" "Node.js LTS"
}
if ($installDevSpace) {
    $npmPath = Ensure-Command "npm.cmd" "OpenJS.NodeJS.LTS" "npm"
}
$hermesAgentPath = Install-HermesAgentIfNeeded

if (-not $SkipNgrok) {
    if (-not $NgrokPath -and $InstallTools) {
        try {
            $NgrokPath = Install-LatestNgrokAgent -InstallRoot $InstallDir
        } catch {
            Fail "The latest stable ngrok agent could not be installed: $($_.Exception.Message)" "Check HTTPS access to bin.equinox.io, then rerun the installer. You can also download the official latest ngrok v3 binary manually and pass -NgrokPath."
        }
    }
    if (-not $NgrokPath) {
        if ($existingWatchdogConfig.ngrokPath -and (Test-Path -LiteralPath ([string]$existingWatchdogConfig.ngrokPath))) {
            $NgrokPath = [string]$existingWatchdogConfig.ngrokPath
        }
    }
    if (-not $NgrokPath) {
        $NgrokPath = Find-CommandPath "ngrok.exe"
    }
    if (-not $NgrokPath -or -not (Test-Path -LiteralPath $NgrokPath)) {
        Fail "ngrok.exe was not found." "Rerun with -InstallTools to download the official latest stable ngrok agent, or pass -NgrokPath with the full path to a current ngrok v3 binary."
    }
    if (-not (Test-NgrokEndpointFlagSupport $NgrokPath)) {
        Fail "The selected ngrok agent does not support the required --url flag: $NgrokPath" "Rerun with -InstallTools to install the official latest stable ngrok agent, or pass -NgrokPath pointing to a current ngrok v3 binary."
    }
    if (-not $NgrokConfigPath) { $NgrokConfigPath = [string]$existingWatchdogConfig.ngrokConfigPath }
    if (-not $NgrokConfigPath) { $NgrokConfigPath = Join-Path $env:LOCALAPPDATA "ngrok\ngrok.yml" }
    $NgrokConfigPath = [System.IO.Path]::GetFullPath($NgrokConfigPath)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $NgrokConfigPath) | Out-Null
    $effectiveNgrokAuthtoken = if ($NgrokAuthtoken) { $NgrokAuthtoken } elseif ($env:NGROK_AUTHTOKEN) { $env:NGROK_AUTHTOKEN } else { "" }
    if ($effectiveNgrokAuthtoken) {
        Write-Host "Configuring ngrok authentication in the explicit local config..."
        Invoke-Checked { & $NgrokPath config add-authtoken $effectiveNgrokAuthtoken --config $NgrokConfigPath | Out-Null } "ngrok authtoken setup failed."
    }
    if (-not (Test-Path -LiteralPath $NgrokConfigPath)) {
        Fail "ngrok config file is missing: $NgrokConfigPath" "Pass -NgrokAuthtoken (or NGROK_AUTHTOKEN) so the installer can initialize the explicit config, or provide -NgrokConfigPath pointing to an existing authenticated ngrok config."
    }
    Invoke-Checked { & $NgrokPath config check --config $NgrokConfigPath | Out-Null } "ngrok config validation failed."
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
        Fail "DevSpace CLI was not found: $CliPath" "Rerun without -SkipNpmInstall so the checkout can build, or pass -CliPath pointing to dist\cli.js."
    }
}

if (-not $PublicBaseUrl) {
    $PublicBaseUrl = [string]$existingConfig.publicBaseUrl
}
if (-not $PublicBaseUrl) {
    Fail "Missing -PublicBaseUrl." 'Pass the stable public origin without /mcp, for example -PublicBaseUrl "https://example.ngrok-free.dev".'
}
$providedPublicBaseUrl = $PublicBaseUrl.TrimEnd("/")
$publicOrigin = Get-UrlOrigin $providedPublicBaseUrl
$devspaceRouteName = Join-McpRouteName "devspace_chatgpt" $McpNameSuffix
$hermesRouteName = Join-McpRouteName "hermes_chatgpt" $McpNameSuffix
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
        if ([string]$existingWatchdogConfig.ngrokEndpointMode -eq "CloudEndpoint") {
            $NgrokAgentBaseUrl = [string]$existingWatchdogConfig.ngrokAgentBaseUrl
        }
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
if (-not $SkipNgrok -and $NgrokBinding -and -not (Test-NgrokEndpointFlagSupport $NgrokPath -RequireBinding)) {
    Fail "The selected ngrok agent does not support --binding required by this endpoint mode: $NgrokPath" "Use a current ngrok v3 build that supports --binding, or choose an endpoint mode that does not require a binding."
}

$routeMachineSlugs = @($machineSlug)
foreach ($alias in @($RouteAliasMachineNames)) {
    $aliasSlug = ConvertTo-Slug $alias
    if ($aliasSlug -and $aliasSlug -ne $machineSlug) {
        $routeMachineSlugs += $aliasSlug
    }
}
$routeMachineSlugs = @($routeMachineSlugs | Select-Object -Unique)

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
        Fail "hermes-gpt server.py was not found: $hermesServer" "Remove -SkipHermesInstall so the installer can clone hermes-gpt, or pass -HermesDir to the correct repo folder."
    }

    $hermesCommandPath = Join-Path $InstallDir "run-hermes-gpt.cmd"
    $hermesWorkingDirectory = $HermesDir
    $hermesFullAccessEnabled = $false
    $hermesCapabilityEnv = @()
    $cmdGates = [ordered]@{
        HERMES_GPT_ENABLE_CODEX=$hermesCapabilities.bridge; HERMES_GPT_ENABLE_MCP=$hermesCapabilities.bridge
        HERMES_GPT_ENABLE_SESSION_SEARCH=$hermesCapabilities.readOnlyTools
        HERMES_GPT_ENABLE_VISION=$hermesCapabilities.vision; HERMES_GPT_ENABLE_WEB=$hermesCapabilities.web
        HERMES_GPT_ENABLE_DIAGNOSTICS=$hermesCapabilities.diagnostics
        HERMES_GPT_ENABLE_CODEX_RUNNER=$hermesCapabilities.runner
        HERMES_GPT_ALLOW_CODEX_WRITE=$hermesCapabilities.runnerWrite
        HERMES_GPT_ENABLE_WRITE=$hermesCapabilities.workspaceWrite
        HERMES_GPT_ENABLE_MEMORY_WRITE=$hermesCapabilities.memoryWrite
        HERMES_GPT_ENABLE_TERMINAL=$hermesCapabilities.terminal
        HERMES_GPT_OPERATOR_ENABLED=$hermesCapabilities.operator; HERMES_GPT_ENABLE_CRON=$hermesCapabilities.cron
        HERMES_GPT_ALLOW_WRITE=($hermesCapabilities.cronWrite -or $hermesCapabilities.skillWrite)
        HERMES_GPT_ALLOW_CRON_WRITE=$hermesCapabilities.cronWrite
        HERMES_GPT_ALLOW_SKILL_WRITE=$hermesCapabilities.skillWrite
        HERMES_GPT_ALLOW_PRIVATE_NETWORK=$hermesCapabilities.privateNetwork
    }
    foreach ($entry in $cmdGates.GetEnumerator()) {
        if ($entry.Value) { $hermesCapabilityEnv += "set `"$($entry.Key)=1`"" }
    }
    $hermesRoots = if ($hermesCapabilities.filesystemScope -eq "full") { @(Get-FullAccessRoots) } else { @($hermesCapabilities.allowedRoots) }
    if ($hermesRoots.Count) {
        $hermesCapabilityEnv += "set `"HERMES_GPT_CODEX_ALLOWED_ROOTS=$($hermesRoots -join ',')`""
        $hermesCapabilityEnv += "set `"HERMES_GPT_OPERATOR_ALLOWED_PATHS=$($hermesRoots -join ',')`""
    }
    if ($hermesCapabilities.operator) {
        $level = if ($hermesCapabilities.ownerMode) { "owner" } elseif ($hermesCapabilities.workspaceWrite -or $hermesCapabilities.runner) { "workspace" } elseif ($hermesCapabilities.skillWrite) { "skills_config" } elseif ($hermesCapabilities.cronWrite) { "cron" } else { "read_only" }
        $hermesCapabilityEnv += "set `"HERMES_GPT_OPERATOR_LEVEL=$level`""
        $hermesCapabilityEnv += "set `"HERMES_GPT_OPERATOR_APPLY_MODE=$(if ($hermesCapabilities.operatorDirect) { 'direct' } else { 'dry_run' })`""
    }
    if ($hermesCapabilities.ownerMode) { $hermesCapabilityEnv += 'set "HERMES_GPT_OWNER_ACK=I_UNDERSTAND_THIS_CAN_MUTATE_MY_MACHINE"' }
    $hermesFullAccessEnv = $hermesCapabilityEnv -join [Environment]::NewLine
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
foreach ($routeMachineSlug in $routeMachineSlugs) {
    $routeNameSuffix = if ($routeMachineSlug -eq $machineSlug) { "" } else { "_alias_$routeMachineSlug" }
    if ($installDevSpace) {
        $mcpRoutes += [ordered]@{
            name = "$devspaceRouteName$routeNameSuffix"
            service = "devspace"
            prefix = "/$routeMachineSlug/devspace_chatgpt"
            targetHost = "127.0.0.1"
            targetPort = $Port
        }
    }
    if ($installHermes) {
        $mcpRoutes += [ordered]@{
            name = "$hermesRouteName$routeNameSuffix"
            service = "hermes"
            prefix = "/$routeMachineSlug/hermes_chatgpt"
            targetHost = "127.0.0.1"
            targetPort = $HermesPort
        }
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
    ngrokConfigPath = if ($SkipNgrok) { "" } else { [System.IO.Path]::GetFullPath($NgrokConfigPath) }
    manageNgrok = -not $SkipNgrok
    publicBaseUrl = $PublicBaseUrl
    ngrokEndpointMode = $NgrokEndpointMode
    ngrokAgentBaseUrl = $NgrokAgentBaseUrl
    ngrokBinding = $NgrokBinding
    # ngrok v3.39+ removed --web-addr; use the supported default inspector.
    ngrokInspectorPort = if ($SkipNgrok) { 0 } else { 4040 }
    mcpNameSuffix = if ($McpNameSuffix) { ConvertTo-Slug $McpNameSuffix } else { "" }
    routeAliasMachineNames = @($routeMachineSlugs | Where-Object { $_ -ne $machineSlug })
    capabilities = [ordered]@{ devspace = $devspaceCapabilities; hermes = $hermesCapabilities }
    cloudEndpointPolicyPath = ""
}

if ($NgrokEndpointMode -eq "CloudEndpoint") {
    if (-not $CloudEndpointPolicyPath) {
        $CloudEndpointPolicyPath = Join-Path $InstallDir "ngrok-cloud-endpoint-$machineSlug.policy.yml"
    }
    $CloudEndpointPolicyPath = [System.IO.Path]::GetFullPath($CloudEndpointPolicyPath)
    $CloudEndpointRulePath = Join-Path (Split-Path $CloudEndpointPolicyPath -Parent) "ngrok-cloud-endpoint-$machineSlug.rule.yml"
    $policy = New-NgrokCloudEndpointPolicy $machineSlug $NgrokAgentBaseUrl
    $rule = New-NgrokCloudEndpointRule $machineSlug $NgrokAgentBaseUrl
    [System.IO.File]::WriteAllText($CloudEndpointPolicyPath, $policy + [Environment]::NewLine, [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($CloudEndpointRulePath, $rule + [Environment]::NewLine, [System.Text.Encoding]::ASCII)
    $watchdogConfig["cloudEndpointPolicyPath"] = $CloudEndpointPolicyPath
    $watchdogConfig["cloudEndpointRulePath"] = [System.IO.Path]::GetFullPath($CloudEndpointRulePath)
}
Write-JsonFile $watchdogConfigPath $watchdogConfig 6
$restartFlagPath = Join-Path $InstallDir "restart-devspace.flag"
[System.IO.File]::WriteAllText($restartFlagPath, "installer updated config at $(Get-Date -Format o)" + [Environment]::NewLine, [System.Text.Encoding]::ASCII)

function Test-InstallerHttp([string]$Url, [int]$MinimumStatus = 200, [int]$MaximumStatus = 499) {
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
        $status = [int]$response.StatusCode
        return $status -ge $MinimumStatus -and $status -le $MaximumStatus
    } catch {
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode.value__
            return $status -ge $MinimumStatus -and $status -le $MaximumStatus
        }
        return $false
    }
}

function Get-InstallerHealthFailures {
    $failures = New-Object System.Collections.Generic.List[string]
    $requiredPorts = @()
    if ($installDevSpace) { $requiredPorts += $Port }
    if ($installHermes) { $requiredPorts += $HermesPort }
    if ($useRouter) { $requiredPorts += $RouterPort }
    if (-not $SkipNgrok) { $requiredPorts += 4040 }
    foreach ($requiredPort in @($requiredPorts | Select-Object -Unique)) {
        if (-not (Get-NetTCPConnection -LocalPort $requiredPort -State Listen -ErrorAction SilentlyContinue)) { [void]$failures.Add("listener:$requiredPort") }
    }
    if ($installDevSpace -and -not (Test-InstallerHttp "http://127.0.0.1:$Port/healthz" 200 299)) { [void]$failures.Add("DevSpace:http://127.0.0.1:$Port/healthz") }
    if ($installHermes -and -not (Test-InstallerHttp "http://127.0.0.1:$HermesPort/mcp" 200 499)) { [void]$failures.Add("Hermes:http://127.0.0.1:$HermesPort/mcp") }
    if ($useRouter) {
        try {
            $routerStatus = Invoke-RestMethod -Uri "http://127.0.0.1:$RouterPort/__router/status" -TimeoutSec 5
            if (-not $routerStatus.ok) { [void]$failures.Add("Router:status-not-ok") }
            if ($installDevSpace) {
                $actual = [string]$routerStatus.routes.PSObject.Properties[$devspaceRouteName].Value
                $expected = "/$machineSlug/devspace_chatgpt/* -> http://127.0.0.1:$Port/*"
                if ($actual -ne $expected) { [void]$failures.Add("Router:devspace-route") }
            }
            if ($installHermes) {
                $actual = [string]$routerStatus.routes.PSObject.Properties[$hermesRouteName].Value
                $expected = "/$machineSlug/hermes_chatgpt/* -> http://127.0.0.1:$HermesPort/*"
                if ($actual -ne $expected) { [void]$failures.Add("Router:hermes-route") }
            }
        } catch { [void]$failures.Add("Router:http://127.0.0.1:$RouterPort/__router/status") }
    }
    if (-not $SkipNgrok) {
        try {
            $tunnels = Invoke-RestMethod -Uri "http://127.0.0.1:4040/api/tunnels" -TimeoutSec 5
            $matchingTunnel = @($tunnels.tunnels | Where-Object { [string]$_.public_url -eq $NgrokAgentBaseUrl -and [string]$_.config.addr -eq "http://127.0.0.1:$RouterPort" }) | Select-Object -First 1
            if (-not $matchingTunnel) { [void]$failures.Add("ngrok:tunnel") }
        } catch { [void]$failures.Add("ngrok:http://127.0.0.1:4040/api/tunnels") }
        if ($NgrokEndpointMode -eq "AgentEndpoint" -and -not (Test-InstallerHttp "$publicOrigin/__router/status" 200 299)) { [void]$failures.Add("public-mcp-route:$publicOrigin") }
    }
    return @($failures)
}

function Assert-InstallationHealth {
    $deadline = (Get-Date).AddSeconds(30)
    $failures = @("startup")
    do {
        Start-Sleep -Seconds 2
        $failures = @(Get-InstallerHealthFailures)
        if ($failures.Count -eq 0) { Write-Host "End-to-end health validation passed." -ForegroundColor Green; return }
    } while ((Get-Date) -lt $deadline)
    throw "End-to-end health validation failed. Failing layer(s): $($failures -join ', '). The installer will not report complete success."
}

$legacyTaskName = "DevSpaceNgrokWatchdog"
$taskName = if ($UserMode -or $NoElevate) { "DevSpaceNgrokWatchdogUserPoller" } else { "DevSpaceNgrokWatchdogPoller" }
$runLevel = if ($UserMode -or $NoElevate) { "Limited" } else { "Highest" }
$modeName = if ($UserMode -or $NoElevate) { "standard user" } else { "administrator" }
foreach ($oldTaskName in @($legacyTaskName, "DevSpaceNgrokWatchdogPoller", "DevSpaceNgrokWatchdogUserPoller", "DevSpace Serve Watchdog")) {
    Stop-ScheduledTask -TaskName $oldTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $oldTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

$taskActionSpec = Get-DevSpaceWatchdogTaskActionSpec `
    -TaskLauncher $TaskLauncher `
    -InstallDir $InstallDir
$taskCommand = $taskActionSpec.TaskCommand
$action = New-ScheduledTaskAction `
    -Execute $taskActionSpec.Execute `
    -Argument $taskActionSpec.Arguments
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
$principalLogonType = if ($UserMode -or $NoElevate) { "S4U" } else { "Interactive" }
$principal = New-ScheduledTaskPrincipal `
    -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType $principalLogonType `
    -RunLevel ($runLevel)
try {
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger @($logonTrigger, $pollTrigger) `
        -Settings $settings `
        -Principal $principal `
        -Description "Runs the DevSpace watchdog every minute in the background as $modeName." `
        -Force | Out-Null
} catch {
    Fail "Register-ScheduledTask failed for ${taskName}: $($_.Exception.Message)" "If this is a stale elevated task, delete it from an Administrator PowerShell and rerun the installer."
}

if (-not $SkipStart) {
    try {
        Start-ScheduledTask -TaskName $taskName
        Assert-InstallationHealth
    } catch {
        Fail "Scheduled task or end-to-end health validation failed: $($_.Exception.Message)" "Inspect the watchdog/ngrok logs and the reported failing layer, correct the dependency/configuration issue, then rerun."
    }
} else {
    Write-Warning "-SkipStart was requested; runtime end-to-end health validation was intentionally not executed."
}

Write-Host "DevSpace watchdog installed and configuration written."
Write-Host "Mode: $modeName"
Write-Host "Machine: $machineSlug"
Write-Host "Scheduled task: $taskName"
Write-Host "Task launcher: $($taskActionSpec.Launcher)"
Write-Host "Task action: $taskCommand"
Write-Host "Config: $configPath"
Write-Host "ngrok endpoint mode: $NgrokEndpointMode"
Write-Host "Public router base URL: $publicOrigin"
Write-Host "DevSpace MCP name: $devspaceRouteName"
Write-Host "Hermes MCP name: $hermesRouteName"
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
if (-not $SkipNgrok) {
    Write-Host "ngrok local inspection URL: http://127.0.0.1:$($watchdogConfig.ngrokInspectorPort)"
}
if ($NgrokEndpointMode -eq "CloudEndpoint" -and $CloudEndpointPolicyPath) {
    Write-Host "Cloud Endpoint policy file: $CloudEndpointPolicyPath"
    Write-Host "Cloud Endpoint merge rule: $CloudEndpointRulePath"
    Write-Host "Next: paste or merge the policy/rule into the ngrok Cloud Endpoint Traffic Policy."
}
Write-Host "Watchdog log: $(Join-Path $InstallDir "devspace-watchdog.log")"
Write-Host "ngrok error log: $(Join-Path $InstallDir "ngrok-watchdog.err.log")"
Write-Host "Troubleshooting: $script:InstallDocsPath"
