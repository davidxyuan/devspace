[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PublicBaseUrl,
    [string]$MachineName = "tyo",
    [string]$McpNameSuffix = "tyo",
    [string]$NgrokAgentBaseUrl,
    [string[]]$RouteAliasMachineNames = @(),
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
    NgrokEndpointMode = "CloudEndpoint"
    MachineName = $MachineName
    McpNameSuffix = $McpNameSuffix
    RouteAliasMachineNames = $RouteAliasMachineNames
}

if ($NgrokAgentBaseUrl) { $params.NgrokAgentBaseUrl = $NgrokAgentBaseUrl }
if (-not $NoFullAccess) { $params.FullAccess = $true }
if ($CliPath) { $params.CliPath = $CliPath }
if ($InstallTools) { $params.InstallTools = $true }
if ($SkipNpmInstall) { $params.SkipNpmInstall = $true }
if ($SkipHermesInstall) { $params.SkipHermesInstall = $true }
if ($SkipHermesAgentInstall) { $params.SkipHermesAgentInstall = $true }
if ($SkipStart) { $params.SkipStart = $true }

& $installer @params
