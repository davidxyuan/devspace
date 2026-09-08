[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ParameterPath, [Parameter(Mandatory=$true)][string]$InstallerPath)
$ErrorActionPreference = 'Stop'
$value = [IO.File]::ReadAllText($ParameterPath) | ConvertFrom-Json
$parameters = @{}
foreach ($property in $value.PSObject.Properties) { $parameters[$property.Name] = $property.Value }
& $InstallerPath @parameters
if (-not $?) { exit 1 }
