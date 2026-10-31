[CmdletBinding()]
param(
    [string]$ConfigPath = "$env:USERPROFILE\.devspace\devspace-watchdog.config.json",
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'watchdog-control-core.ps1')
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$config = Read-WatchdogJson $ConfigPath
$stateDir = [IO.Path]::GetFullPath([string]$config.stateDir)
if (-not $stateDir.Equals([IO.Path]::GetDirectoryName($ConfigPath),[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing attestation: config file is not inside its declared state directory.'
}
$stateFile = Join-Path $stateDir 'watchdog-tray-state.json'
if (-not [bool](Read-WatchdogJson $stateFile).maintenanceMode) { throw 'Attestation requires Maintenance mode.' }
$processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
$services = [ordered]@{}
foreach ($service in @('devspace','hermes','router','ngrok')) {
    if (-not (Test-WatchdogServiceEnabled $service $config)) { continue }
    $verified = @($processes | Where-Object { Test-WatchdogManagedProcess $_ $service $config })
    if ($verified.Count -lt 1 -or $verified.Count -gt 3) {
        throw "Strict process verification failed for $service; count=$($verified.Count). No attestation written."
    }
    $port = Get-WatchdogServicePort $service $config
    if (-not (Test-WatchdogTcpPortReachable $port)) { throw "$service TCP port unavailable. No attestation written." }
    $observedListeners = @(Get-WatchdogListenOwners $port)
    foreach ($listenerPid in $observedListeners) {
        if ($listenerPid -notin @($verified | ForEach-Object { [int]$_.ProcessId })) {
            throw "$service listener is not strictly verified; owner PID=$listenerPid. No attestation written."
        }
    }
    $services[$service] = @($verified | ForEach-Object {
        [pscustomobject]@{
            pid=[int]$_.ProcessId
            name=[string]$_.Name
            creationUtcTicks=[string]$_.CreationDate.ToUniversalTime().Ticks
        }
    })
    Write-Host "$service exact identity verified for $($verified.Count) process(es)"
}
if (-not $services.Count) { throw 'No managed services were verified.' }
$evidence = [pscustomobject][ordered]@{
    schemaVersion=1
    machineSlug=[string]$config.machineSlug
    windowsUser=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    createdUtc=[DateTimeOffset]::UtcNow.ToString('o')
    configSha256=Get-WatchdogFileSha256 $ConfigPath
    services=[pscustomobject]$services
}
$target = Join-Path $stateDir 'watchdog-legacy-process-attestation.json'
if ($Apply) {
    if ([IO.File]::Exists($target)) { throw 'Existing attestation must be reviewed; refusing silent overwrite.' }
    Write-WatchdogAtomicJson $target $evidence 30
    Write-Host "Attestation saved (PIDs and creation timestamps only); no process was restarted."
} else {
    Write-Host 'Preview only; use -Apply to write an exact-PID attestation.'
    Write-Output ($evidence | ConvertTo-Json -Depth 8 -Compress)
}
