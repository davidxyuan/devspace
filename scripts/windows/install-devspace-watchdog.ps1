[CmdletBinding()]
param(
    [string]$InstallDir = "$env:USERPROFILE\.devspace",
    [string]$ManagementPackageRoot,
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
    [switch]$InstallWatchdogTray,
    [switch]$NoLegacyPoller,
    [switch]$UserMode,
    [switch]$NoElevate,
    [ValidateSet("minimal", "full", "codex")][string]$DevSpaceToolMode = "minimal",
    [ValidateSet("off", "changes", "full")][string]$DevSpaceWidgets = "off",
    [ValidateSet("On", "Off")][string]$DevSpaceSkills = "Off",
    [ValidateSet("On", "Off")][string]$DevSpaceSubagents = "Off",
    [ValidateSet("stateful", "stateless-json")][string]$DevSpaceMcpTransport = "stateful",
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
. (Join-Path $PSScriptRoot "watchdog-install-transaction.ps1")
$script:InstallDocsPath = Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))) "docs\windows-watchdog.md"

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

function Write-JsonFile([string]$path, $value, [int]$depth = 40) {
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
if ($InstallWatchdogTray -and $SkipStart) {
    Fail "-InstallWatchdogTray cannot be combined with -SkipStart." "Run the opt-in Tray migration only when it may start the Tray and prove readiness."
}
if ($NoLegacyPoller -and -not $InstallWatchdogTray) {
    Fail "-NoLegacyPoller requires -InstallWatchdogTray." "Tray-only mode needs the persistent Tray to own monitoring and recovery."
}
if ($NoLegacyPoller -and -not ($UserMode -or $NoElevate)) {
    Fail "-NoLegacyPoller is intended for UserMode/NoElevate installs." "Use -UserMode -InstallWatchdogTray -NoLegacyPoller on standard-user company PCs."
}
$HermesDir = [System.IO.Path]::GetFullPath($HermesDir)
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
. (Join-Path $PSScriptRoot 'stack-operation.ps1')
$installLease = Enter-StackOperation -InstallDir $InstallDir
$installTransaction = $null
$priorControlRunning = $false
try {
$configPath = Join-Path $InstallDir "config.json"
$authPath = Join-Path $InstallDir "auth.json"
$watchdogConfigPath = Join-Path $InstallDir "devspace-watchdog.config.json"
$existingConfig = Read-JsonFile $configPath
$existingAuth = Read-JsonFile $authPath
$existingWatchdogConfig = Read-JsonFile $watchdogConfigPath
# Parameters omitted by the caller retain the effective installed value. Keep
# installed components even when only an additional component was selected.
$componentList = @(Get-ComponentList)
if ($existingWatchdogConfig.devspaceEnabled) { $componentList += 'DevSpace' }
if ($existingWatchdogConfig.hermesEnabled) { $componentList += 'Hermes' }
$componentList = @($componentList | Select-Object -Unique)
$installDevSpace = Test-Component 'DevSpace'
$installHermes = Test-Component 'Hermes'
$useRouter = $installDevSpace -or $installHermes
$installedParameters = @{
    Port='port'; HermesPort='hermesPort'; RouterPort='routerPort'; NodePath='nodePath'; CliPath='cliPath';
    HermesDir='hermesWorkingDirectory'; PythonPath='hermesPython'; NgrokPath='ngrokPath';
    MachineName='machineSlug'; McpNameSuffix='mcpNameSuffix'; RouteAliasMachineNames='routeAliasMachineNames';
    NgrokEndpointMode='ngrokEndpointMode'; NgrokAgentBaseUrl='ngrokAgentBaseUrl'; NgrokBinding='ngrokBinding';
    CloudEndpointPolicyPath='cloudEndpointPolicyPath'; FullAccess='fullAccess'
}
foreach ($entry in $installedParameters.GetEnumerator()) {
    $property = if ($existingWatchdogConfig) { $existingWatchdogConfig.PSObject.Properties[$entry.Value] } else { $null }
    if (-not $PSBoundParameters.ContainsKey($entry.Key) -and $property -and $null -ne $property.Value -and [string]$property.Value -ne '') {
        Set-Variable -Name $entry.Key -Value $property.Value
    }
}
if (-not $PSBoundParameters.ContainsKey('SkipNgrok') -and $existingWatchdogConfig -and $existingWatchdogConfig.manageNgrok -eq $false) { $SkipNgrok = $true }
if ($existingWatchdogConfig.hermesEnabled -and [IO.File]::Exists([string]$existingWatchdogConfig.hermesServer) -and [IO.File]::Exists([string]$existingWatchdogConfig.hermesPython) -and -not $PSBoundParameters.ContainsKey('HermesDir')) { $SkipHermesInstall = $true }
$MachineName = if ($MachineName) { $MachineName } else { [System.Net.Dns]::GetHostName() }
$machineSlug = ConvertTo-Slug $MachineName
if (-not $machineSlug) { Fail 'Missing machine name.' 'Pass a URL-safe MachineName.' }
$capabilityParameters = @{
    DevSpaceToolMode='toolMode'; DevSpaceWidgets='widgets'; DevSpaceSkills='skills'; DevSpaceSubagents='subagents'; DevSpaceMcpTransport='mcpTransport';
    HermesBridge='bridge'; HermesReadOnlyTools='readOnlyTools'; HermesVision='vision'; HermesWeb='web'; HermesDiagnostics='diagnostics';
    HermesRunner='runner'; HermesRunnerWrite='runnerWrite'; HermesWorkspaceWrite='workspaceWrite'; HermesMemoryWrite='memoryWrite'; HermesTerminal='terminal';
    HermesOperator='operator'; HermesOperatorDirect='operatorDirect'; HermesOwnerMode='ownerMode'; HermesCron='cron'; HermesCronWrite='cronWrite';
    HermesSkillWrite='skillWrite'; HermesPrivateNetwork='privateNetwork'; HermesFilesystemScope='filesystemScope'; HermesAllowedRoots='allowedRoots'
}
foreach ($entry in $capabilityParameters.GetEnumerator()) {
    $group = if ($entry.Key.StartsWith('DevSpace')) { $existingWatchdogConfig.capabilities.devspace } else { $existingWatchdogConfig.capabilities.hermes }
    $property = if ($group) { $group.PSObject.Properties[$entry.Value] } else { $null }
    if (-not $PSBoundParameters.ContainsKey($entry.Key) -and $property) {
        $value = if ($property.Value -is [bool]) { if ($property.Value) { 'On' } else { 'Off' } } else { $property.Value }
        Set-Variable -Name $entry.Key -Value $value
    }
}
if (-not $PSBoundParameters.ContainsKey("DevSpaceMcpTransport")) {
    $existingTransport = [string]$existingWatchdogConfig.capabilities.devspace.mcpTransport
    if ($existingTransport -in @("stateful", "stateless-json")) {
        $DevSpaceMcpTransport = $existingTransport
    }
}
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
$devspaceCapabilities = New-DevSpaceCapabilityConfig $DevSpaceToolMode $DevSpaceWidgets $DevSpaceSkills $DevSpaceSubagents $DevSpaceMcpTransport
$hermesCapabilities = New-HermesCapabilityConfig `
    $HermesBridge $HermesReadOnlyTools $HermesVision $HermesWeb $HermesDiagnostics `
    $HermesRunner $HermesRunnerWrite $HermesWorkspaceWrite $HermesMemoryWrite $HermesTerminal `
    $HermesOperator $HermesOperatorDirect $HermesOwnerMode $HermesCron $HermesCronWrite `
    $HermesSkillWrite $HermesPrivateNetwork $HermesFilesystemScope $HermesAllowedRoots

$needsNode = $installDevSpace -or $useRouter

if ($needsNode -and -not $NodePath) {
    $NodePath = Ensure-Command "node.exe" "OpenJS.NodeJS.LTS" "Node.js LTS"
}
if ($needsNode) {
    if (-not [IO.File]::Exists($NodePath)) { Fail "Configured Node.js was not found: $NodePath" }
    $nodeVersion = [version](& $NodePath -p 'process.versions.node')
    if ($LASTEXITCODE -ne 0 -or $nodeVersion -lt [version]'22.19' -or $nodeVersion -ge [version]'27.0') { Fail 'Node.js must be >=22.19 and <27.' 'Select a compatible Node installation; the existing runtime was not replaced.' }
}
if ($installDevSpace -and -not $CliPath) {
    $npmPath = Ensure-Command "npm.cmd" "OpenJS.NodeJS.LTS" "npm"
}
if ($installHermes -and [IO.File]::Exists((Join-Path $HermesDir 'server.py')) -and
    ([IO.File]::Exists((Join-Path $HermesDir '.venv\Scripts\python.exe')) -or ($PythonPath -and [IO.File]::Exists($PythonPath)))) { $SkipHermesInstall = $true }
$hermesAgentPath = if ($SkipHermesInstall) { Find-HermesAgentExe } else { Install-HermesAgentIfNeeded }

$ngrokWebAddrSupported = $false
if (-not $SkipNgrok) {
    if (-not $NgrokPath) { $NgrokPath = Find-CommandPath 'ngrok.exe' }
    if ((-not $NgrokPath -or -not (Test-NgrokEndpointFlagSupport $NgrokPath)) -and $InstallTools) {
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
        Fail "The selected ngrok agent does not support the required --url and --binding flags: $NgrokPath" "Rerun with -InstallTools to install the official latest stable ngrok agent, or pass -NgrokPath pointing to a current ngrok v3 binary."
    }
    $ngrokWebAddrSupported = Test-NgrokWebAddrSupport $NgrokPath
    $effectiveNgrokAuthtoken = if ($NgrokAuthtoken) { $NgrokAuthtoken } elseif ($env:NGROK_AUTHTOKEN) { $env:NGROK_AUTHTOKEN } else { "" }
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

    $devspaceConfig = Merge-InstallDefaults $existingConfig ([ordered]@{
        host = "127.0.0.1"
        port = $Port
        allowedRoots = $allowedRootList
        publicBaseUrl = $PublicBaseUrl
    })
    $devspaceConfig['port'] = $Port
    if ($PSBoundParameters.ContainsKey('AllowedRoots') -or $PSBoundParameters.ContainsKey('FullAccess')) { $devspaceConfig['allowedRoots'] = $allowedRootList }
    if ($PSBoundParameters.ContainsKey('PublicBaseUrl') -or $PSBoundParameters.ContainsKey('MachineName')) { $devspaceConfig['publicBaseUrl'] = $PublicBaseUrl }

    $ownerToken = if ($env:DEVSPACE_OWNER_TOKEN) { [string]$env:DEVSPACE_OWNER_TOKEN } else { [string]$existingAuth.ownerToken }
    if (-not $ownerToken) {
        $ownerToken = New-OwnerToken
    }
    $authConfig = ConvertTo-InstallMap $existingAuth
    $authConfig['ownerToken'] = $ownerToken
}

$hermesCommandPath = ""
if ($installHermes) {
    if (-not $SkipHermesInstall) {
        if (-not (Test-Path -LiteralPath $HermesDir)) {
            Write-Host "Cloning hermes-gpt..."
            $gitPath = Find-GitForClone
            Invoke-Checked { & $gitPath clone $HermesRepo $HermesDir } "git clone hermes-gpt failed."
        } elseif (-not (Test-Path -LiteralPath (Join-Path $HermesDir 'server.py'))) { Fail "Existing Hermes directory is not a recognized Hermes-GPT installation: $HermesDir" }

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
        if (-not $PythonPath) { Fail 'No compatible existing Hermes-GPT Python runtime was found.' }
        $hermesPython = [System.IO.Path]::GetFullPath($PythonPath)
    }
    if (-not [IO.File]::Exists($hermesPython)) { Fail "Hermes-GPT Python was not found: $hermesPython" }
    $pythonVersion = [version](& $hermesPython -c 'import platform; print(platform.python_version())')
    if ($LASTEXITCODE -ne 0 -or $pythonVersion -lt [version]'3.10') { Fail 'Hermes-GPT requires Python >=3.10.' }
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
    $hermesCommandContent = @"
@echo off
set "HERMES_HOME=%LOCALAPPDATA%\hermes"
$hermesFullAccessEnv
cd /d "$HermesDir"
"$hermesPython" "$hermesServer" --http --host 127.0.0.1 --port $HermesPort
"@
}

$routerPath = ""
if ($useRouter) {
    $routerPath = Join-Path $InstallDir "mcp-router.cjs"
    if ($existingWatchdogConfig.routerPath) { $routerPath = [IO.Path]::GetFullPath([string]$existingWatchdogConfig.routerPath) }
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
    manageNgrok = -not $SkipNgrok
    publicBaseUrl = $PublicBaseUrl
    ngrokEndpointMode = $NgrokEndpointMode
    ngrokAgentBaseUrl = $NgrokAgentBaseUrl
    ngrokBinding = $NgrokBinding
    ngrokWebAddrSupported = [bool]$ngrokWebAddrSupported
    ngrokInspectorPort = if ($SkipNgrok) { 0 } elseif (-not $ngrokWebAddrSupported) { 4040 } else {
        Find-AvailableLoopbackPort `
            $(if ($existingWatchdogConfig.ngrokInspectorPort) { [int]$existingWatchdogConfig.ngrokInspectorPort } else { 4040 }) `
            @([string]$existingWatchdogConfig.ngrokAgentBaseUrl, [string]$existingWatchdogConfig.publicBaseUrl)
    }
    mcpNameSuffix = if ($McpNameSuffix) { ConvertTo-Slug $McpNameSuffix } else { "" }
    routeAliasMachineNames = @($routeMachineSlugs | Where-Object { $_ -ne $machineSlug })
    capabilities = [ordered]@{ devspace = $devspaceCapabilities; hermes = $hermesCapabilities }
    controlCenter = if ($existingWatchdogConfig.controlCenter) { $existingWatchdogConfig.controlCenter } else { [ordered]@{
        dashboardPort = 8777
        localProbeSeconds = 5
        publicProbeSeconds = 21600
        publicProbeBackoffSeconds = @(300, 1800, 7200, 21600)
        failureThreshold = 2
        maxRecoveryAttempts = 5
        backoffSeconds = @(0, 10, 30, 60, 120)
        logMaxBytes = 2097152
        historyLimit = 500
        displayNames = [ordered]@{ devspace = "$MachineName DevSpace"; hermes = "$MachineName Hermes" }
    } }
    cloudEndpointPolicyPath = ""
}

if ($existingWatchdogConfig) {
    $candidate = $watchdogConfig
    $watchdogConfig = Merge-InstallDefaults $existingWatchdogConfig $candidate
    $watchdogConfig['devspaceEnabled'] = $installDevSpace
    $watchdogConfig['hermesEnabled'] = $installHermes
    $fieldParameters = @{
        port='Port'; hermesPort='HermesPort'; routerPort='RouterPort'; publicUpstreamPort='RouterPort'; nodePath='NodePath'; cliPath='CliPath';
        fullAccess='FullAccess'; machineSlug='MachineName'; mcpNameSuffix='McpNameSuffix'; ngrokEndpointMode='NgrokEndpointMode';
        ngrokAgentBaseUrl='NgrokAgentBaseUrl'; ngrokBinding='NgrokBinding'; ngrokPath='NgrokPath'; publicBaseUrl='PublicBaseUrl'; manageNgrok='SkipNgrok'
    }
    foreach ($entry in $fieldParameters.GetEnumerator()) {
        if ($PSBoundParameters.ContainsKey($entry.Value)) { $watchdogConfig[$entry.Key] = $candidate[$entry.Key] }
    }
    foreach ($field in @('cliPath','nodePath','ngrokPath','routerPath','routerPort','hermesCommand','hermesPython','hermesServer','hermesWorkingDirectory','hermesPort')) {
        if (-not $watchdogConfig[$field]) { $watchdogConfig[$field] = $candidate[$field] }
    }
    if ($PSBoundParameters.ContainsKey('HermesDir') -or $PSBoundParameters.ContainsKey('PythonPath')) {
        foreach ($field in @('hermesPython','hermesServer','hermesWorkingDirectory')) { $watchdogConfig[$field] = $candidate[$field] }
    }
    $existingRoutes = @($existingWatchdogConfig.mcpRoutes)
    foreach ($route in $mcpRoutes) {
        if (@($existingRoutes | Where-Object { [string]$_.prefix -eq [string]$route.prefix }).Count -eq 0) { $existingRoutes += $route }
    }
    $watchdogConfig['mcpRoutes'] = @($existingRoutes | ForEach-Object {
        $route = ConvertTo-InstallMap $_
        if ($route.service -eq 'devspace' -and $PSBoundParameters.ContainsKey('Port')) { $route['targetPort'] = $Port }
        if ($route.service -eq 'hermes' -and $PSBoundParameters.ContainsKey('HermesPort')) { $route['targetPort'] = $HermesPort }
        $route
    })
    if ($PSBoundParameters.ContainsKey('RouteAliasMachineNames')) { $watchdogConfig['routeAliasMachineNames'] = $candidate.routeAliasMachineNames }
    $preservedCapabilities = ConvertTo-InstallMap $existingWatchdogConfig.capabilities
    foreach ($group in @('devspace','hermes')) {
        $capabilities = ConvertTo-InstallMap $preservedCapabilities[$group]
        foreach ($key in $candidate.capabilities[$group].Keys) { $capabilities[$key] = $candidate.capabilities[$group][$key] }
        $preservedCapabilities[$group] = $capabilities
    }
    $watchdogConfig['capabilities'] = $preservedCapabilities
}
$ManagementPackageRoot = if ($ManagementPackageRoot) { [IO.Path]::GetFullPath($ManagementPackageRoot) } elseif ($existingWatchdogConfig.managementPackageRoot) { [IO.Path]::GetFullPath([string]$existingWatchdogConfig.managementPackageRoot) } else { $repoRoot }
if (-not [IO.File]::Exists((Join-Path $ManagementPackageRoot 'scripts\windows\devspace-stack-setup.cjs'))) { throw 'ManagementPackageRoot does not contain the Setup manager.' }
$watchdogConfig['managementPackageRoot'] = $ManagementPackageRoot

# Everything needed by the new configuration is prepared before activation.
$taskSnapshots = @(Get-InstallTaskSnapshots $InstallDir)
$legacyProcessSnapshots = @(Get-InstallLegacyProcessSnapshots $InstallDir)
$transactionNames = @('config.json','auth.json','ngrok-auth.dpapi.json','devspace-watchdog.config.json','devspace-watchdog.ps1','watchdog-control-core.ps1','stack-operation.ps1','run-devspace-watchdog-hidden.vbs','run-hermes-gpt.cmd','mcp-router.cjs','restart-devspace.flag','legacy-watchdog-poller.disabled','watchdog-tray-state.json')
$transactionPaths = @($transactionNames | ForEach-Object { Join-Path $InstallDir $_ })
if ($NgrokEndpointMode -eq 'CloudEndpoint') {
    if (-not $CloudEndpointPolicyPath) { $CloudEndpointPolicyPath = Join-Path $InstallDir "ngrok-cloud-endpoint-$machineSlug.policy.yml" }
    $transactionPaths += [IO.Path]::GetFullPath($CloudEndpointPolicyPath)
    $transactionPaths += Join-Path (Split-Path $CloudEndpointPolicyPath -Parent) "ngrok-cloud-endpoint-$machineSlug.rule.yml"
}
$installTransaction = Start-InstallTransaction $InstallDir $transactionPaths $taskSnapshots $legacyProcessSnapshots
Disable-InstallLegacyTasks $installTransaction
Stop-InstallLegacyProcesses $installTransaction
if ($existingWatchdogConfig -and $InstallWatchdogTray) {
    try { & (Join-Path $PSScriptRoot 'devspace-watchdog-bootstrap.ps1') -Mode CheckStopped -ConfigPath $watchdogConfigPath -RuntimeDirectory $InstallDir }
    catch { $priorControlRunning = $true }
    & (Join-Path $PSScriptRoot 'devspace-watchdog-bootstrap.ps1') -Mode Stop -ConfigPath $watchdogConfigPath -RuntimeDirectory $InstallDir
    & (Join-Path $PSScriptRoot 'devspace-watchdog-bootstrap.ps1') -Mode CheckStopped -ConfigPath $watchdogConfigPath -RuntimeDirectory $InstallDir
}
if ($installDevSpace) { Write-JsonFile $configPath $devspaceConfig; Write-JsonFile $authPath $authConfig }
foreach ($name in @('devspace-watchdog.ps1','watchdog-control-core.ps1','stack-operation.ps1','run-devspace-watchdog-hidden.vbs')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $InstallDir $name) -Force }
if ($installHermes -and (-not $SkipHermesInstall -or -not [IO.File]::Exists([string]$existingWatchdogConfig.hermesCommand))) {
    [IO.File]::WriteAllText($hermesCommandPath, $hermesCommandContent, [Text.Encoding]::ASCII)
}
if ($useRouter -and -not [IO.File]::Exists($routerPath)) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'mcp-router.cjs') -Destination $routerPath }
if ($effectiveNgrokAuthtoken) {
    . (Join-Path $PSScriptRoot 'watchdog-control-core.ps1')
    [void](Set-WatchdogNgrokCredential $watchdogConfig $effectiveNgrokAuthtoken)
    $effectiveNgrokAuthtoken = $null
}

if ($NgrokEndpointMode -eq "CloudEndpoint" -and (-not $existingWatchdogConfig.cloudEndpointPolicyPath -or $PSBoundParameters.ContainsKey('CloudEndpointPolicyPath') -or $PSBoundParameters.ContainsKey('NgrokAgentBaseUrl') -or $PSBoundParameters.ContainsKey('MachineName'))) {
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
Write-JsonFile $watchdogConfigPath $watchdogConfig
$restartFlagPath = Join-Path $InstallDir "restart-devspace.flag"
[System.IO.File]::WriteAllText($restartFlagPath, "installer updated config at $(Get-Date -Format o)" + [Environment]::NewLine, [System.Text.Encoding]::ASCII)

$legacyTaskName = "DevSpaceNgrokWatchdog"
$taskName = if ($UserMode -or $NoElevate) { "DevSpaceNgrokWatchdogUserPoller" } else { "DevSpaceNgrokWatchdogPoller" }
$runLevel = if ($UserMode -or $NoElevate) { "Limited" } else { "Highest" }
$modeName = if ($UserMode -or $NoElevate) { "standard user" } else { "administrator" }
$taskActionSpec = Get-DevSpaceWatchdogTaskActionSpec -TaskLauncher $TaskLauncher -InstallDir $InstallDir
$taskCommand = $taskActionSpec.TaskCommand

if ($NoLegacyPoller) {
    $legacyPollerDisableMarker = Join-Path $InstallDir "legacy-watchdog-poller.disabled"
    [System.IO.File]::WriteAllText($legacyPollerDisableMarker, "Tray-only install at $([DateTimeOffset]::UtcNow.ToString('o'))" + [Environment]::NewLine, [System.Text.Encoding]::ASCII)
} else {
    Remove-Item -LiteralPath (Join-Path $InstallDir "legacy-watchdog-poller.disabled") -Force -ErrorAction SilentlyContinue
    if ($taskSnapshots.Count) {
        # Reuse the exact existing task definition and its enabled/running state.
        foreach ($snapshot in $taskSnapshots) {
            if ($snapshot.enabled) { Enable-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop | Out-Null }
            if ($snapshot.running -and $snapshot.enabled -and -not $SkipStart) { Start-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop }
        }
    } else {
    $action = New-ScheduledTaskAction -Execute $taskActionSpec.Execute -Argument $taskActionSpec.Arguments
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn
    $pollTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
    $settings.Hidden = $true
    $useSchtasks = $UserMode -or $NoElevate
    if ($useSchtasks) {
        & schtasks.exe /Create /TN $taskName /SC MINUTE /MO 1 /TR $taskCommand | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Fail "schtasks.exe failed to register $taskName." "Use -UserMode -InstallWatchdogTray -NoLegacyPoller on PCs where an old elevated task cannot be replaced."
        }
        $installTransaction.createdTasks += [pscustomobject]@{name=$taskName;path='\'}
    } else {
        $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel ($runLevel)
        try {
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($logonTrigger, $pollTrigger) -Settings $settings -Principal $principal -Description "Runs the DevSpace watchdog every minute in the background as $modeName." | Out-Null
            $installTransaction.createdTasks += [pscustomobject]@{name=$taskName;path='\'}
        } catch {
            Fail "Register-ScheduledTask failed for ${taskName}: $($_.Exception.Message)" "Approve UAC and rerun, or use -UserMode -InstallWatchdogTray -NoLegacyPoller."
        }
    }
    if (-not $SkipStart) {
        try { Start-ScheduledTask -TaskName $taskName }
        catch { Fail "Scheduled task was created but could not be started: $($_.Exception.Message)" "Start it from Task Scheduler, or use Tray-only UserMode." }
    }
    }
}

if ($InstallWatchdogTray) {
    & (Join-Path $PSScriptRoot "install-devspace-watchdog-tray.ps1") -InstallDir $InstallDir -SkipStart:$SkipStart -OriginalTransactionPath (Join-Path $installTransaction.backupPath 'transaction.json') -Confirm:$false
}
elseif (-not $SkipStart) { Restart-InstallLegacyProcesses $installTransaction }
$installTransaction.completed = $true

Write-Host "DevSpace watchdog installed."
Write-Host "Mode: $modeName"
Write-Host "Machine: $machineSlug"
Write-Host "Scheduled task: $(if ($NoLegacyPoller) { 'none (Tray-only)' } else { $taskName })"
Write-Host "Task launcher: $(if ($NoLegacyPoller) { 'none' } else { $taskActionSpec.Launcher })"
Write-Host "Task action: $(if ($NoLegacyPoller) { 'none' } else { $taskCommand })"
Write-Host "Config: $configPath"
Write-Host "ngrok endpoint mode: $NgrokEndpointMode"
Write-Host "Public router base URL: $publicOrigin"
Write-Host "DevSpace MCP name: $devspaceRouteName"
Write-Host "Hermes MCP name: $hermesRouteName"
if ($installDevSpace) {
    Write-Host "Auth: $authPath"
    Write-Host 'Owner authentication: configured (preserved in auth.json)'
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
} catch {
    $failure = $_
    if ($installTransaction -and -not $installTransaction.completed) {
        try {
            if ($InstallWatchdogTray -and [IO.File]::Exists($watchdogConfigPath)) {
                & (Join-Path $PSScriptRoot 'devspace-watchdog-bootstrap.ps1') -Mode Stop -ConfigPath $watchdogConfigPath -RuntimeDirectory $InstallDir
                & (Join-Path $PSScriptRoot 'devspace-watchdog-bootstrap.ps1') -Mode CheckStopped -ConfigPath $watchdogConfigPath -RuntimeDirectory $InstallDir
            }
            Undo-InstallTransaction $installTransaction
            Restart-InstallLegacyProcesses $installTransaction
            if ($priorControlRunning -and [IO.File]::Exists((Join-Path $InstallDir 'devspace-watchdog-bootstrap.ps1'))) {
                & (Join-Path $InstallDir 'devspace-watchdog-bootstrap.ps1') -Mode Run -ConfigPath $watchdogConfigPath
            }
        } catch { throw "ROLLBACK_FAILED: $($_.Exception.Message). Original failure: $($failure.Exception.Message). Recovery: $($installTransaction.backupPath)" }
        throw "Installation failed; original configuration and task state restored. $($failure.Exception.Message). Recovery: $($installTransaction.backupPath)"
    }
    throw
} finally { Exit-StackOperation $installLease }
