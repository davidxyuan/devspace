[CmdletBinding()]
param(
    [string]$InstallDir = "$env:USERPROFILE\.devspace",
    [string]$DevSpaceDir,
    [string]$HermesDir,
    [string]$BackupRoot = "$env:USERPROFILE\DevSpaceUpgradeBackups",
    [ValidateSet("Auto", "Upgrade", "UpgradeDevSpace", "UpgradeHermes", "CapabilitiesOnly")][string]$Action = "Auto",
    [string]$CapabilitySelection = "",
    [string[]]$HermesAllowedRoots = @(),
    [switch]$DryRun,
    [switch]$VerifyOnly,
    [switch]$SkipSourceTests,
    [switch]$NoAutoRollback,
    [switch]$Wait
)

$ErrorActionPreference = "Stop"
$runRoot = Join-Path $env:LOCALAPPDATA "DevSpaceUpgradeRuns"
$runDir = Join-Path $runRoot (Get-Date -Format "yyyyMMdd-HHmmss")
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$requestPath = Join-Path $runDir "request.json"
$runnerPath = Join-Path $PSScriptRoot "run-existing-tested-stack-upgrade.ps1"
if (-not (Test-Path -LiteralPath $runnerPath)) { throw "Upgrade runner is missing: $runnerPath" }

[ordered]@{
    InstallDir=[IO.Path]::GetFullPath($InstallDir)
    DevSpaceDir=$(if ($DevSpaceDir) { [IO.Path]::GetFullPath($DevSpaceDir) } else { $null })
    HermesDir=$(if ($HermesDir) { [IO.Path]::GetFullPath($HermesDir) } else { $null })
    BackupRoot=[IO.Path]::GetFullPath($BackupRoot)
    Action=$Action
    CapabilitySelection=$CapabilitySelection
    HermesAllowedRoots=@($HermesAllowedRoots)
    DryRun=[bool]$DryRun
    VerifyOnly=[bool]$VerifyOnly
    SkipSourceTests=[bool]$SkipSourceTests
    NoAutoRollback=[bool]$NoAutoRollback
    createdAt=(Get-Date).ToString("o")
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $requestPath -Encoding UTF8

$arguments = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", "`"$runnerPath`"",
    "-RequestPath", "`"$requestPath`""
)
$process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru
[ordered]@{
    processId=$process.Id
    runDirectory=$runDir
    requestPath=$requestPath
    statusPath=(Join-Path $runDir "status.json")
    startedAt=(Get-Date).ToString("o")
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runDir "launch.json") -Encoding UTF8

Write-Host "Detached tested-stack upgrade started."
Write-Host "PID: $($process.Id)"
Write-Host "Run directory: $runDir"
Write-Host "Status: $(Join-Path $runDir 'status.json')"
if ($Wait) {
    Wait-Process -Id $process.Id
    $statusPath = Join-Path $runDir "status.json"
    if (Test-Path $statusPath) { Get-Content $statusPath }
    exit $process.ExitCode
}
