$ErrorActionPreference = "Stop"

$trayPath = Join-Path $PSScriptRoot "devspace-watchdog-tray.ps1"
$source = Get-Content -LiteralPath $trayPath -Raw
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "Tray source has parser errors: $($errors[0].Message)" }

$helper = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Test-RecentCompletedRouterRequest" }, $true))[0]
if (-not $helper) { throw "Test-RecentCompletedRouterRequest is missing" }
Invoke-Expression $helper.Extent.Text

function Get-WatchdogProperty($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-ServiceFromSnapshot([string]$Service) {
    if (-not $script:lastHealth) { return $null }
    return Get-WatchdogProperty $script:lastHealth.services $Service $null
}

function Set-RouterCompletion([string]$Timestamp) {
    $script:lastHealth = [pscustomobject]@{
        services = [pscustomobject]@{
            router = [pscustomobject]@{
                connections = [pscustomobject]@{
                    services = [pscustomobject]@{
                        devspace = [pscustomobject]@{ lastCompletedAt = $Timestamp }
                    }
                }
            }
        }
    }
}

Set-RouterCompletion ([DateTimeOffset]::UtcNow.AddSeconds(-15).ToString("o"))
if (-not (Test-RecentCompletedRouterRequest "devspace" 300)) { throw "recent completed request was not accepted" }

Set-RouterCompletion ([DateTimeOffset]::UtcNow.AddMinutes(-6).ToString("o"))
if (Test-RecentCompletedRouterRequest "devspace" 300) { throw "stale completed request incorrectly masked public degradation" }

Set-RouterCompletion "not-a-timestamp"
if (Test-RecentCompletedRouterRequest "devspace" 300) { throw "invalid completed timestamp was accepted" }

$overall = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-OverallTrayState" }, $true))[0]
if (-not $overall) { throw "Get-OverallTrayState is missing" }
$overallText = $overall.Extent.Text
if ($overallText -notmatch [regex]::Escape('Healthy (public verification pending)')) { throw "pending-public healthy state is missing" }
if ($overallText -notmatch [regex]::Escape('Test-RecentCompletedRouterRequest $service')) { throw "public-degraded branch does not consult recent real traffic" }

Write-Output "PASS: Tray trusts only recent completed Router traffic while public verification is pending."
