[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RequestPath
)

$ErrorActionPreference = "Stop"
$requestPathFull = [IO.Path]::GetFullPath($RequestPath)
if (-not (Test-Path -LiteralPath $requestPathFull)) { throw "Upgrade request does not exist: $requestPathFull" }
$request = Get-Content -LiteralPath $requestPathFull -Raw | ConvertFrom-Json
$runDir = Split-Path -Parent $requestPathFull
$statusPath = Join-Path $runDir "status.json"
$stdoutPath = Join-Path $runDir "upgrade.out.log"
$stderrPath = Join-Path $runDir "upgrade.err.log"
$upgradePath = Join-Path $PSScriptRoot "upgrade-existing-tested-stack.ps1"

function Write-Status([string]$state, [int]$exitCode, [string]$message) {
    [ordered]@{
        state=$state
        exitCode=$exitCode
        message=$message
        updatedAt=(Get-Date).ToString("o")
        requestPath=$requestPathFull
        stdoutPath=$stdoutPath
        stderrPath=$stderrPath
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statusPath -Encoding UTF8
}

$params = @{
    InstallDir=[string]$request.InstallDir
    BackupRoot=[string]$request.BackupRoot
    Action=[string]$request.Action
    CapabilitySelection=[string]$request.CapabilitySelection
    HermesAllowedRoots=@($request.HermesAllowedRoots)
}
if ($request.DevSpaceDir) { $params.DevSpaceDir = [string]$request.DevSpaceDir }
if ($request.HermesDir) { $params.HermesDir = [string]$request.HermesDir }
foreach ($switchName in @("DryRun", "VerifyOnly", "SkipSourceTests", "NoAutoRollback")) {
    if ([bool]$request.$switchName) { $params[$switchName] = $true }
}

Write-Status "running" 0 "Upgrade process started."
try {
    & $upgradePath @params *> $stdoutPath
    $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($code -ne 0) {
        Write-Status "failed" $code "Upgrade installer returned exit code $code."
        exit $code
    }
    Write-Status "completed" 0 "Upgrade completed successfully."
    exit 0
} catch {
    $_ | Out-String | Set-Content -LiteralPath $stderrPath -Encoding UTF8
    Write-Status "failed" 1 $_.Exception.Message
    exit 1
}
