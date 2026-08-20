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
    [switch]$VerifyOnly,
    [switch]$Detached,
    [switch]$SkipSourceTests,
    [switch]$NoAutoRollback
)

$ErrorActionPreference = "Stop"
$FallbackRawBase = "https://raw.githubusercontent.com/davidxyuan/devspace/fix/windows-new-pc-installer-hardening-20260820"
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

function Assert-PowerShellSyntax([string]$path) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) {
        $details = ($errors | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "Installer syntax validation failed before execution: $path`n$details"
    }
}
function Require-LocalScript([string]$name) {
    $path = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Installer package is incomplete: $name is missing beside detect-and-apply-tested-stack.ps1. Clone or copy the complete scripts/windows package before upgrading an existing machine."
    }
    if ([IO.Path]::GetExtension($path) -eq ".ps1") { Assert-PowerShellSyntax $path }
    return $path
}
function Resolve-FreshScript([string]$name, [string]$tempDir) {
    $local = Join-Path $PSScriptRoot $name
    if (Test-Path -LiteralPath $local) {
        if ([IO.Path]::GetExtension($local) -eq ".ps1") { Assert-PowerShellSyntax $local }
        return $local
    }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $destination = Join-Path $tempDir $name
    Invoke-WebRequest "$FallbackRawBase/scripts/windows/$name" -OutFile $destination -UseBasicParsing
    if ([IO.Path]::GetExtension($destination) -eq ".ps1") { Assert-PowerShellSyntax $destination }
    return $destination
}

if ($detected -eq "Existing") {
    $common = @{
        InstallDir=$InstallDir
        Action="Auto"
        CapabilitySelection=$CapabilitySelection
        HermesAllowedRoots=$HermesAllowedRoots
    }
    if ($DryRun) { $common.DryRun = $true }
    if ($VerifyOnly) { $common.VerifyOnly = $true }
    if ($SkipSourceTests) { $common.SkipSourceTests = $true }
    if ($NoAutoRollback) { $common.NoAutoRollback = $true }
    if ($Detached -and -not $VerifyOnly) {
        $launcher = Require-LocalScript "start-existing-tested-stack-upgrade.ps1"
        & $launcher @common
    } else {
        $upgrade = Require-LocalScript "upgrade-existing-tested-stack.ps1"
        & $upgrade @common
    }
    exit $LASTEXITCODE
}

Write-Host "Selected action: Fresh install"
if ($VerifyOnly) { throw "Nothing is installed to verify." }
if ($DryRun) {
    Write-Host "Would install pinned DevSpace 1.0.4 and Hermes-GPT 0.5.0, then apply the selected capabilities."
    Write-Host "Capability selection: $CapabilitySelection"
    exit 0
}
if (-not $PublicBaseUrl -or (-not $AllowedRoots -and -not $FullAccess)) {
    throw "Fresh install requires -PublicBaseUrl and either -AllowedRoots or -FullAccess."
}

$temp = Join-Path $env:TEMP "devspace-tested-stack-installer-$PID"
$installStack = Resolve-FreshScript "install-tested-stack.ps1" $temp
Write-Host "Installer syntax validation passed: $installStack" -ForegroundColor Green
& $installStack -InstallRoot $InstallRoot
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$watchdogScriptNames = @(
    "install-devspace-watchdog.ps1", "watchdog-task-action.ps1", "ngrok-install.ps1",
    "devspace-watchdog.ps1", "run-devspace-watchdog-hidden.vbs", "mcp-router.cjs",
    "capability-config.ps1"
)
$resolved = @{}
foreach ($name in $watchdogScriptNames) { $resolved[$name] = Resolve-FreshScript $name $temp }
$watchdogInstaller = $resolved["install-devspace-watchdog.ps1"]
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
& $watchdogInstaller @watchdogParams
