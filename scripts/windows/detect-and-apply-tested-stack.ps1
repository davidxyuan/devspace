[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:LOCALAPPDATA\DevSpaceTestedStack",
    [string]$InstallDir = "$env:USERPROFILE\.devspace",
    [string]$PublicBaseUrl,
    [string]$NgrokAuthtoken,
    [ValidateSet("AgentEndpoint", "CloudEndpoint")][string]$NgrokEndpointMode = "AgentEndpoint",
    [string]$NgrokAgentBaseUrl,
    [string]$MachineName = $env:COMPUTERNAME,
    [string]$McpNameSuffix,
    [string]$AllowedRoots,
    [switch]$FullAccess,
    [ValidateSet("Vbs", "PowerShell")][string]$TaskLauncher = "PowerShell",
    [switch]$UserMode,
    [string]$CapabilitySelection = "",
    [string[]]$HermesAllowedRoots = @(),
    [switch]$DryRun,
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"
$RawBase = "https://raw.githubusercontent.com/davidxyuan/devspace/codex/windows-fixed-port-conflicts"
$configExists = Test-Path (Join-Path $InstallDir "config.json")
$watchdogExists = Test-Path (Join-Path $InstallDir "devspace-watchdog.config.json")
$repoArtifacts = (Test-Path (Join-Path $InstallRoot "devspace")) -or (Test-Path (Join-Path $InstallRoot "hermes-gpt"))
if ($configExists -xor $watchdogExists) {
    throw "AUTO DETECTION REFUSED: partial/unknown existing installation. No files were changed."
}
if (-not $configExists -and $repoArtifacts) {
    throw "AUTO DETECTION REFUSED: repository artifacts exist without a recognized live configuration. No downgrade or overwrite was attempted."
}
$detected = if ($configExists -and $watchdogExists) { "Existing" } else { "Fresh" }
Write-Host "Detected installation state: $detected"

if ($detected -eq "Existing") {
    $upgrade = Invoke-RestMethod "$RawBase/scripts/windows/upgrade-existing-tested-stack.ps1"
    $params = @{
        InstallDir=$InstallDir; Action="Auto"; CapabilitySelection=$CapabilitySelection
        HermesAllowedRoots=$HermesAllowedRoots; DryRun=$DryRun; VerifyOnly=$VerifyOnly
    }
    & ([scriptblock]::Create($upgrade)) @params
    exit $LASTEXITCODE
}

Write-Host "Selected action: Fresh install"
if ($VerifyOnly) { throw "Nothing is installed to verify." }
if ($DryRun) {
    Write-Host "Would install pinned DevSpace 1.0.4 and Hermes-GPT 0.5.0, then apply the selected least-privilege capabilities."
    Write-Host "Capability selection: $CapabilitySelection"
    exit 0
}
if (-not $PublicBaseUrl -or (-not $AllowedRoots -and -not $FullAccess)) {
    throw "Fresh install requires -PublicBaseUrl and either -AllowedRoots or -FullAccess."
}

$fresh = Invoke-RestMethod "$RawBase/scripts/windows/install-tested-stack.ps1"
& ([scriptblock]::Create($fresh)) -InstallRoot $InstallRoot
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$temp = Join-Path $env:TEMP "devspace-capability-installer-$PID"
New-Item -ItemType Directory -Path $temp -Force | Out-Null
foreach ($name in @(
    "install-devspace-watchdog.ps1", "watchdog-task-action.ps1", "ngrok-install.ps1",
    "devspace-watchdog.ps1", "run-devspace-watchdog-hidden.vbs", "mcp-router.cjs",
    "capability-config.ps1"
)) {
    Invoke-WebRequest "$RawBase/scripts/windows/$name" -OutFile (Join-Path $temp $name) -UseBasicParsing
}
$watchdogParams = @{
    InstallDir=$InstallDir; Components=@("DevSpace","Hermes")
    HermesDir=(Join-Path $InstallRoot "hermes-gpt")
    CliPath=(Join-Path $InstallRoot "devspace\dist\cli.js")
    SkipNpmInstall=$true; SkipHermesInstall=$true; PublicBaseUrl=$PublicBaseUrl
    NgrokEndpointMode=$NgrokEndpointMode; MachineName=$MachineName
    McpNameSuffix=$(if ($McpNameSuffix) { $McpNameSuffix } else { $MachineName })
    TaskLauncher=$TaskLauncher; InstallTools=$true; CapabilitySelection=$CapabilitySelection
    HermesAllowedRoots=$HermesAllowedRoots
}
if ($NgrokAgentBaseUrl) { $watchdogParams.NgrokAgentBaseUrl = $NgrokAgentBaseUrl }
if ($NgrokAuthtoken) { $watchdogParams.NgrokAuthtoken = $NgrokAuthtoken }
if ($FullAccess) { $watchdogParams.FullAccess = $true } else { $watchdogParams.AllowedRoots = $AllowedRoots }
if ($UserMode) { $watchdogParams.UserMode = $true }
& (Join-Path $temp "install-devspace-watchdog.ps1") @watchdogParams
