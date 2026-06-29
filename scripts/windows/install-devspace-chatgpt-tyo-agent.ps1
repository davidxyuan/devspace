[CmdletBinding()]
param(
    [string]$PublicBaseUrl = "https://shush-underuse-obnoxious.ngrok-free.dev",
    [string]$MachineName = "tyo",
    [string]$McpNameSuffix = "tyo",
    [string[]]$RouteAliasMachineNames = @("c02250073"),
    [string]$CliPath,
    [string[]]$Components = @("DevSpace", "Hermes"),
    [switch]$NoFullAccess,
    [switch]$InstallTools,
    [switch]$SkipNpmInstall,
    [switch]$SkipHermesInstall,
    [switch]$SkipHermesAgentInstall,
    [switch]$SkipStart
)

$installer = Join-Path $PSScriptRoot "install-devspace-watchdog.ps1"
$params = @{
    UserMode = $true
    Components = $Components
    PublicBaseUrl = $PublicBaseUrl
    NgrokEndpointMode = "AgentEndpoint"
    MachineName = $MachineName
    McpNameSuffix = $McpNameSuffix
    RouteAliasMachineNames = $RouteAliasMachineNames
}

if (-not $NoFullAccess) { $params.FullAccess = $true }
if ($CliPath) { $params.CliPath = $CliPath }
if ($InstallTools) { $params.InstallTools = $true }
if ($SkipNpmInstall) { $params.SkipNpmInstall = $true }
if ($SkipHermesInstall) { $params.SkipHermesInstall = $true }
if ($SkipHermesAgentInstall) { $params.SkipHermesAgentInstall = $true }
if ($SkipStart) { $params.SkipStart = $true }

& $installer @params
