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
    [switch]$NoAutoRollback
)

$ErrorActionPreference = "Stop"
$DevSpaceRepo = "https://github.com/davidxyuan/devspace.git"
$DevSpaceRef = "codex/windows-fixed-port-conflicts"
$PinnedDevSpaceCommit = "ca7c10a39b5c099455db662c3aba9007b5eb34e3"
$PinnedDevSpaceVersion = [version]"1.0.4"
$HermesRepo = "https://github.com/davidxyuan/hermes-gpt.git"
$HermesRef = "codex/upgrade-v0.5.0"
$PinnedHermesCommit = "db5ffa1bd2e4fcfecdebb2bcf479334144e1cbe3"
$PinnedHermesVersion = [version]"0.5.0"
$MigrationSource = Join-Path (Split-Path $PSScriptRoot -Parent) "migrate-oauth-json-to-sqlite.mjs"
$WatchdogSource = Join-Path $PSScriptRoot "devspace-watchdog.ps1"
$CapabilityHelper = Join-Path $PSScriptRoot "capability-config.ps1"

function Fail([string]$message) { throw "SAFE EXISTING-MACHINE ACTION REFUSED: $message" }
function Read-Json([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { Fail "Required file is missing: $path" }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { Fail "Invalid JSON: $path" }
}
function Run([scriptblock]$command, [string]$failure) {
    & $command
    if ($LASTEXITCODE -ne 0) { Fail $failure }
}
function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Normalize-GitUrl([string]$url) {
    $value = ([string]$url).Trim().TrimEnd("/")
    if ($value -match '^git@github\.com:(.+)$') { $value = "https://github.com/$($Matches[1])" }
    if ($value -match '^ssh://git@github\.com/(.+)$') { $value = "https://github.com/$($Matches[1])" }
    if ($value.EndsWith(".git", [StringComparison]::OrdinalIgnoreCase)) { $value = $value.Substring(0, $value.Length - 4) }
    return $value.ToLowerInvariant()
}
function Resolve-RepoRemote([string]$path, [string]$expectedRemote) {
    if (-not (Test-Path -LiteralPath (Join-Path $path ".git"))) { Fail "Not a Git checkout: $path" }
    $expected = Normalize-GitUrl $expectedRemote
    foreach ($name in @(& git -C $path remote)) {
        $url = (& git -C $path remote get-url $name).Trim()
        if ((Normalize-GitUrl $url) -eq $expected) { return [string]$name }
    }
    Fail "No Git remote in $path points to expected repository: $expectedRemote"
}
function Assert-RepoClean([string]$path, [string]$component) {
    $changes = @(& git -C $path status --porcelain --untracked-files=no)
    if ($changes.Count) { Fail "$component has tracked changes in $path; no source upgrade was attempted." }
}
function Get-HermesRepoVersion([string]$path) {
    $projectPath = Join-Path $path "pyproject.toml"
    if (-not (Test-Path $projectPath)) { Fail "Hermes-GPT pyproject.toml is missing: $projectPath" }
    $text = Get-Content $projectPath -Raw
    if ($text -notmatch '(?m)^version\s*=\s*"([^"]+)"') { Fail "Hermes-GPT project version cannot be read." }
    return [version]$Matches[1]
}
function Get-HermesInstalledVersion([string]$python) {
    try {
        $value = (& $python -c "from importlib.metadata import version; print(version('hermes-gpt'))" 2>$null).Trim()
        if ($LASTEXITCODE -eq 0 -and $value) { return [version]$value }
    } catch {}
    return $null
}
function Get-TaskSnapshot {
    $names = @("DevSpaceNgrokWatchdog", "DevSpaceNgrokWatchdogPoller", "DevSpaceNgrokWatchdogUserPoller", "DevSpace Serve Watchdog")
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object TaskName -In $names)
    if ($tasks.Count -ne 1) { Fail "Expected exactly one supported DevSpace watchdog task; found $($tasks.Count)." }
    $task = $tasks[0]
    [pscustomobject]@{
        Xml = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
        Name = $task.TaskName
        Path = $task.TaskPath
        State = [string]$task.State
    }
}
function Get-PortOwners([int]$port) {
    @(
        Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique |
            ForEach-Object { Get-CimInstance Win32_Process -Filter "ProcessId=$_" -ErrorAction SilentlyContinue }
    )
}
function Find-NgrokInspectorPort($watchdog) {
    $preferred = if ($watchdog.ngrokInspectorPort) { [int]$watchdog.ngrokInspectorPort } else { 4040 }
    for ($candidate = $preferred; $candidate -lt ($preferred + 100); $candidate++) {
        $owners = @(Get-PortOwners $candidate)
        if (-not $owners.Count) { return $candidate }
        $agentUrl = [string]$watchdog.ngrokAgentBaseUrl
        if ($candidate -eq $preferred -and $agentUrl -and @($owners | Where-Object {
            ([string]$_.CommandLine).IndexOf($agentUrl, [StringComparison]::OrdinalIgnoreCase) -lt 0
        }).Count -eq 0) { return $candidate }
    }
    Fail "No available ngrok inspection UI port in $preferred-$($preferred + 99)."
}
function Initialize-ProcessAccessCheck {
    if ("DevSpaceUpgrade.NativeProcess" -as [type]) { return }
    Add-Type @"
using System;
using System.Runtime.InteropServices;
namespace DevSpaceUpgrade {
  public static class NativeProcess {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
  }
}
"@
}
function Test-CanTerminateProcess([int]$ProcessId) {
    if ($ProcessId -eq $PID) { return $false }
    Initialize-ProcessAccessCheck
    $handle = [DevSpaceUpgrade.NativeProcess]::OpenProcess(0x0001, $false, $ProcessId)
    if ($handle -eq [IntPtr]::Zero) { return $false }
    [DevSpaceUpgrade.NativeProcess]::CloseHandle($handle) | Out-Null
    return $true
}
function Test-ManagedProcessForPort($watchdog, [int]$port, $process, [int]$inspectorPort) {
    $command = [string]$process.CommandLine
    $executable = [string]$process.ExecutablePath
    if ($port -eq [int]$watchdog.port) { return $command -like "*$($watchdog.cliPath)*" }
    if ($port -eq [int]$watchdog.hermesPort) {
        return ($command -like "*$($watchdog.hermesServer)*") -or ($watchdog.hermesPython -and $executable -eq [string]$watchdog.hermesPython)
    }
    if ($watchdog.routerPort -and $port -eq [int]$watchdog.routerPort) { return $command -like "*$($watchdog.routerPath)*" }
    if ($port -eq $inspectorPort) {
        return ($watchdog.ngrokPath -and $executable -eq [string]$watchdog.ngrokPath) -or
            ($watchdog.ngrokAgentBaseUrl -and $command -like "*$($watchdog.ngrokAgentBaseUrl)*")
    }
    return $false
}
function Get-ManagedListenerPlan($watchdog) {
    $inspectorPort = if ($watchdog.ngrokInspectorPort) { [int]$watchdog.ngrokInspectorPort } else { 4040 }
    $ports = @($watchdog.port, $watchdog.hermesPort, $watchdog.routerPort, $inspectorPort) |
        Where-Object { $_ -and [int]$_ -gt 0 } | Select-Object -Unique
    $items = @()
    foreach ($portValue in $ports) {
        $port = [int]$portValue
        foreach ($process in @(Get-PortOwners $port)) {
            $managed = Test-ManagedProcessForPort $watchdog $port $process $inspectorPort
            if (-not $managed) {
                if ($port -eq $inspectorPort) { continue }
                Fail "FIXED PORT CONFLICT: 127.0.0.1:$port is owned by PID $($process.ProcessId) ($($process.Name)), command=$($process.CommandLine). Stop or reconfigure that process and rerun; no service port will be moved or unknown owner stopped."
            }
            $items += [pscustomobject]@{ Port=$port; ProcessId=[int]$process.ProcessId; Name=[string]$process.Name; CommandLine=[string]$process.CommandLine }
        }
    }
    return @($items | Sort-Object ProcessId -Unique)
}
function Assert-CanStopManagedListeners([object[]]$plan) {
    foreach ($item in $plan) {
        if (-not (Test-CanTerminateProcess ([int]$item.ProcessId))) {
            $elevation = if (Test-IsElevated) { "The process may be protected or owned by another account." } else { "Rerun this installer from an elevated PowerShell or stop the process manually." }
            Fail "Cannot obtain terminate access for managed PID $($item.ProcessId) ($($item.Name)) on port $($item.Port). $elevation No services were stopped."
        }
    }
}
function Stop-ManagedListeners([object[]]$plan) {
    foreach ($item in $plan) {
        Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction Stop
    }
}
function Get-HttpStatusHeadersOnly([string]$url, [int]$timeoutSeconds = 15) {
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
    $request.Headers.TryAddWithoutValidation("Accept", "application/json, text/event-stream") | Out-Null
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter([TimeSpan]::FromSeconds($timeoutSeconds))
    try {
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).GetAwaiter().GetResult()
        return [int]$response.StatusCode
    } finally {
        if ($response) { $response.Dispose() }
        $request.Dispose(); $client.Dispose(); $cts.Dispose()
    }
}
function Test-Http([string]$url, [int[]]$accepted) {
    try { $status = Get-HttpStatusHeadersOnly $url } catch { Fail "Endpoint unreachable: $url ($($_.Exception.Message))" }
    if ($status -notin $accepted) { Fail "Unexpected HTTP $status from $url" }
}
function Verify-Live {
    $live = Read-Json (Join-Path $InstallDir "devspace-watchdog.config.json")
    Test-Http "http://127.0.0.1:$($live.port)/healthz" @(200)
    if ($live.routerPort) { Test-Http "http://127.0.0.1:$($live.routerPort)/__router/status" @(200) }
    if ($live.hermesEnabled) { Test-Http "http://127.0.0.1:$($live.hermesPort)/mcp" @(200, 400, 401, 405, 406) }
    $origin = ([Uri]$live.publicBaseUrl).GetLeftPart([UriPartial]::Authority)
    foreach ($route in @($live.mcpRoutes)) {
        Test-Http "$origin$($route.prefix)/mcp" @(200, 400, 401, 405, 406)
    }
}
function Get-CurrentCapabilityArguments($watchdog) {
    $dev = $watchdog.capabilities.devspace
    $hermes = $watchdog.capabilities.hermes
    if (-not $dev) { $dev = [pscustomobject]@{ toolMode="minimal"; widgets="full"; skills=$true; subagents=$false } }
    if (-not $hermes) {
        $legacy = [bool]$watchdog.hermesFullAccess
        $hermes = [pscustomobject]@{
            bridge=$false; readOnlyTools=$legacy; vision=$false; web=$false; diagnostics=$false
            runner=$false; runnerWrite=$false; workspaceWrite=$legacy; memoryWrite=$legacy; terminal=$legacy
            operator=$legacy; operatorDirect=$legacy; ownerMode=$legacy; cron=$false; cronWrite=$false
            skillWrite=$false; privateNetwork=$false
            filesystemScope=$(if ($legacy) { "full" } else { "restricted" }); allowedRoots=@()
        }
    }
    @{
        DevSpaceToolMode=[string]$dev.toolMode; DevSpaceWidgets=[string]$dev.widgets
        DevSpaceSkills=$(if ([bool]$dev.skills){"On"}else{"Off"}); DevSpaceSubagents=$(if ([bool]$dev.subagents){"On"}else{"Off"})
        HermesBridge=$(if ([bool]$hermes.bridge){"On"}else{"Off"}); HermesReadOnlyTools=$(if ([bool]$hermes.readOnlyTools){"On"}else{"Off"})
        HermesVision=$(if ([bool]$hermes.vision){"On"}else{"Off"}); HermesWeb=$(if ([bool]$hermes.web){"On"}else{"Off"})
        HermesDiagnostics=$(if ([bool]$hermes.diagnostics){"On"}else{"Off"}); HermesRunner=$(if ([bool]$hermes.runner){"On"}else{"Off"})
        HermesRunnerWrite=$(if ([bool]$hermes.runnerWrite){"On"}else{"Off"}); HermesWorkspaceWrite=$(if ([bool]$hermes.workspaceWrite){"On"}else{"Off"})
        HermesMemoryWrite=$(if ([bool]$hermes.memoryWrite){"On"}else{"Off"}); HermesTerminal=$(if ([bool]$hermes.terminal){"On"}else{"Off"})
        HermesOperator=$(if ([bool]$hermes.operator){"On"}else{"Off"}); HermesOperatorDirect=$(if ([bool]$hermes.operatorDirect){"On"}else{"Off"})
        HermesOwnerMode=$(if ([bool]$hermes.ownerMode){"On"}else{"Off"}); HermesCron=$(if ([bool]$hermes.cron){"On"}else{"Off"})
        HermesCronWrite=$(if ([bool]$hermes.cronWrite){"On"}else{"Off"}); HermesSkillWrite=$(if ([bool]$hermes.skillWrite){"On"}else{"Off"})
        HermesPrivateNetwork=$(if ([bool]$hermes.privateNetwork){"On"}else{"Off"})
        HermesFilesystemScope=[string]$hermes.filesystemScope; HermesAllowedRoots=@($hermes.allowedRoots)
    }
}
function Copy-CriticalState([string]$source, [string]$destination) {
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    foreach ($name in @(
        "config.json", "auth.json", "devspace-watchdog.config.json", "devspace-watchdog.ps1",
        "mcp-router.cjs", "run-hermes-gpt.cmd", "run-devspace-watchdog-hidden.vbs",
        "ngrok-cloud-endpoint-*.policy.yml", "ngrok-cloud-endpoint-*.rule.yml"
    )) {
        Get-ChildItem -LiteralPath $source -Filter $name -File -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $destination -Force }
    }
}
function Restore-CriticalState([string]$backupState, [string]$destination) {
    foreach ($file in @(Get-ChildItem -LiteralPath $backupState -File -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $destination $file.Name) -Force
    }
}
function Invoke-Rollback($manifest, [string]$backupPath, $taskSnapshot) {
    Write-Warning "Attempting automatic rollback from $backupPath"
    try {
        $live = Read-Json (Join-Path $InstallDir "devspace-watchdog.config.json")
        $currentPlan = Get-ManagedListenerPlan $live
        Assert-CanStopManagedListeners $currentPlan
        Stop-ManagedListeners $currentPlan
    } catch { Write-Warning "Rollback stop phase warning: $($_.Exception.Message)" }
    if ($manifest.upgradeDevSpace) {
        & git -C $manifest.devspaceDir checkout --detach $manifest.devspaceHead | Out-Null
        Push-Location $manifest.devspaceDir
        try { & npm.cmd ci --include=dev; if ($LASTEXITCODE) { throw "npm ci rollback failed" }; & npm.cmd run build; if ($LASTEXITCODE) { throw "npm build rollback failed" }; & npm.cmd link; if ($LASTEXITCODE) { throw "npm link rollback failed" } } finally { Pop-Location }
    }
    if ($manifest.upgradeHermes) {
        & git -C $manifest.hermesDir checkout --detach $manifest.hermesHead | Out-Null
        $venvBackup = Join-Path $backupPath "hermes-venv"
        $venvPath = Join-Path $manifest.hermesDir ".venv"
        if (Test-Path $venvBackup) {
            if (Test-Path $venvPath) { Remove-Item $venvPath -Recurse -Force }
            Copy-Item $venvBackup $venvPath -Recurse
        }
    }
    Restore-CriticalState (Join-Path $backupPath "state") $InstallDir
    if ($manifest.externalStateBackedUp) {
        $external = Join-Path $backupPath "devspace-data"
        if (Test-Path $external) {
            if (Test-Path $manifest.stateDir) { Remove-Item $manifest.stateDir -Recurse -Force }
            Copy-Item $external $manifest.stateDir -Recurse
        }
    }
    if ($manifest.hermesHomeBackedUp) {
        $hermesHome = Join-Path $env:LOCALAPPDATA "hermes"
        $source = Join-Path $backupPath "hermes-home"
        if (Test-Path $hermesHome) { Remove-Item $hermesHome -Recurse -Force }
        Copy-Item $source $hermesHome -Recurse
    }
    Start-ScheduledTask -TaskName $taskSnapshot.Name -TaskPath $taskSnapshot.Path -ErrorAction Stop
    Start-Sleep -Seconds 10
    Verify-Live
    Write-Warning "Automatic rollback completed."
}

foreach ($required in @($CapabilityHelper, $WatchdogSource, $MigrationSource)) {
    if (-not (Test-Path -LiteralPath $required)) { Fail "Installer package is incomplete; missing local file: $required" }
}
. $CapabilityHelper

$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$config = Read-Json (Join-Path $InstallDir "config.json")
$auth = Read-Json (Join-Path $InstallDir "auth.json")
$watchdogPath = Join-Path $InstallDir "devspace-watchdog.config.json"
$watchdog = Read-Json $watchdogPath
if (-not $auth.ownerToken) { Fail "auth.json has no ownerToken; credentials will not be regenerated." }
if (-not $config.allowedRoots -or -not $watchdog.publicBaseUrl -or -not $watchdog.machineSlug) { Fail "Machine identity/settings cannot be identified." }
if (-not $watchdog.ngrokPath -or -not (Test-Path -LiteralPath $watchdog.ngrokPath)) { Fail "Configured ngrok binary cannot be identified." }
if (-not $DevSpaceDir) { $DevSpaceDir = Split-Path (Split-Path ([string]$watchdog.cliPath) -Parent) -Parent }
if (-not $HermesDir) { $HermesDir = [string]$watchdog.hermesWorkingDirectory }
if (-not $DevSpaceDir -or -not $HermesDir) { Fail "DevSpace or Hermes checkout cannot be identified." }
$DevSpaceDir = [IO.Path]::GetFullPath($DevSpaceDir)
$HermesDir = [IO.Path]::GetFullPath($HermesDir)
$devRemote = Resolve-RepoRemote $DevSpaceDir $DevSpaceRepo
$hermesRemote = Resolve-RepoRemote $HermesDir $HermesRepo
$taskSnapshot = Get-TaskSnapshot
$CurrentDevSpaceVersion = [version]((Get-Content (Join-Path $DevSpaceDir "package.json") -Raw | ConvertFrom-Json).version)
$CurrentDevSpaceHead = (& git -C $DevSpaceDir rev-parse HEAD).Trim()
$hermesPython = Join-Path $HermesDir ".venv\Scripts\python.exe"
if (-not (Test-Path $hermesPython)) { Fail "Existing Hermes virtual environment is missing." }
$CurrentHermesVersion = Get-HermesRepoVersion $HermesDir
$CurrentHermesInstalledVersion = Get-HermesInstalledVersion $hermesPython
$CurrentHermesHead = (& git -C $HermesDir rev-parse HEAD).Trim()
try {
    $plan = Get-TestedStackPlan $true `
        $CurrentDevSpaceVersion $CurrentHermesVersion `
        $PinnedDevSpaceVersion $PinnedHermesVersion `
        $CurrentDevSpaceHead $CurrentHermesHead `
        $PinnedDevSpaceCommit $PinnedHermesCommit
} catch {
    Fail "$($_.Exception.Message) Current state: DevSpace $CurrentDevSpaceVersion ($CurrentDevSpaceHead), Hermes-GPT $CurrentHermesVersion ($CurrentHermesHead)."
}
$detectedAction = [string]$plan.action
if ($Action -ne "Auto" -and $Action -ne $detectedAction) { Fail "Requested $Action conflicts with detected safe action $detectedAction." }
$Action = $detectedAction
$upgradeDevSpace = $Action -in @("Upgrade", "UpgradeDevSpace")
$upgradeHermes = $Action -in @("Upgrade", "UpgradeHermes")
if ($upgradeDevSpace) { Assert-RepoClean $DevSpaceDir "DevSpace" }
if ($upgradeHermes) { Assert-RepoClean $HermesDir "Hermes-GPT" }
if ($Action -eq "CapabilitiesOnly" -and $CurrentHermesInstalledVersion -ne $PinnedHermesVersion) {
    Fail "Hermes source is current but installed distribution is '$CurrentHermesInstalledVersion'; expected $PinnedHermesVersion. Repair the runtime before capability-only changes."
}
if ($Action -eq "CapabilitiesOnly" -and -not $CapabilitySelection -and -not $VerifyOnly -and -not $DryRun) {
    Fail "Tested versions are already installed; provide an explicit capability selection or use -VerifyOnly."
}
$capArgs = Get-CurrentCapabilityArguments $watchdog
foreach ($entry in (ConvertFrom-CapabilitySelection $CapabilitySelection).GetEnumerator()) { $capArgs[$entry.Key] = $entry.Value }
if ($HermesAllowedRoots.Count) { $capArgs.HermesAllowedRoots = $HermesAllowedRoots }
$newCapabilities = [ordered]@{
    devspace = New-DevSpaceCapabilityConfig $capArgs.DevSpaceToolMode $capArgs.DevSpaceWidgets $capArgs.DevSpaceSkills $capArgs.DevSpaceSubagents
    hermes = New-HermesCapabilityConfig `
        $capArgs.HermesBridge $capArgs.HermesReadOnlyTools $capArgs.HermesVision $capArgs.HermesWeb $capArgs.HermesDiagnostics `
        $capArgs.HermesRunner $capArgs.HermesRunnerWrite $capArgs.HermesWorkspaceWrite $capArgs.HermesMemoryWrite $capArgs.HermesTerminal `
        $capArgs.HermesOperator $capArgs.HermesOperatorDirect $capArgs.HermesOwnerMode $capArgs.HermesCron $capArgs.HermesCronWrite `
        $capArgs.HermesSkillWrite $capArgs.HermesPrivateNetwork $capArgs.HermesFilesystemScope $capArgs.HermesAllowedRoots
}
$oldCapsJson = if ($watchdog.capabilities) { $watchdog.capabilities | ConvertTo-Json -Depth 8 -Compress } else { "<legacy>" }
$newCapsJson = $newCapabilities | ConvertTo-Json -Depth 8 -Compress
$applyCapabilities = [bool]$CapabilitySelection -or $HermesAllowedRoots.Count -gt 0
$ngrokInspectorPort = Find-NgrokInspectorPort $watchdog
$listenerPlan = Get-ManagedListenerPlan $watchdog
Assert-CanStopManagedListeners $listenerPlan
Write-Host "Detected action: $Action (DevSpace $CurrentDevSpaceVersion/$($plan.devspaceState), Hermes-GPT $CurrentHermesVersion/$($plan.hermesState), installed Hermes $CurrentHermesInstalledVersion)"
Write-Host "Fixed ports: DevSpace $($watchdog.port), Hermes-GPT $($watchdog.hermesPort), router $($watchdog.routerPort); ngrok inspector $ngrokInspectorPort"
if ($applyCapabilities) { Write-Host "Capability before: $oldCapsJson"; Write-Host "Capability after:  $newCapsJson" }
else { Write-Host "Preserve current effective settings (no capability write requested)." }
if ($DryRun) { Write-Host "Dry run complete; no live state changed." -ForegroundColor Green; exit 0 }
if ($VerifyOnly) { Verify-Live; Write-Host "Verification complete." -ForegroundColor Green; exit 0 }

$stateDir = if ($config.stateDir) { [IO.Path]::GetFullPath([string]$config.stateDir) } else { [IO.Path]::GetFullPath("$env:USERPROFILE\.local\share\devspace") }
$legacyOauth = Join-Path $stateDir "oauth-state.json"
$sqlite = Join-Path $stateDir "devspace.sqlite"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path ([IO.Path]::GetFullPath($BackupRoot)) "$stamp-$($watchdog.machineSlug)-$Action"
New-Item -ItemType Directory -Path $backup -Force | Out-Null
$manifest = [ordered]@{
    createdAt=(Get-Date).ToString("o"); action=$Action; installDir=$InstallDir; stateDir=$stateDir
    devspaceDir=$DevSpaceDir; hermesDir=$HermesDir; taskName=$taskSnapshot.Name; taskPath=$taskSnapshot.Path
    devspaceHead=$CurrentDevSpaceHead; hermesHead=$CurrentHermesHead; upgradeDevSpace=$upgradeDevSpace; upgradeHermes=$upgradeHermes
    externalStateBackedUp=$false; hermesHomeBackedUp=$false
    capabilitiesBefore=$oldCapsJson; capabilitiesAfter=$newCapsJson
}
Stop-ScheduledTask -TaskName $taskSnapshot.Name -TaskPath $taskSnapshot.Path -ErrorAction Stop
Stop-ManagedListeners $listenerPlan
try {
    $taskSnapshot.Xml | Set-Content (Join-Path $backup "watchdog-task.xml") -Encoding Unicode
    Copy-CriticalState $InstallDir (Join-Path $backup "state")
    if ($stateDir -ne $InstallDir -and (Test-Path $stateDir)) {
        Copy-Item $stateDir (Join-Path $backup "devspace-data") -Recurse
        $manifest.externalStateBackedUp = $true
    }
    if ($upgradeDevSpace) {
        Copy-Item $MigrationSource (Join-Path $backup "migrate-oauth-json-to-sqlite.mjs") -Force
        & git -C $DevSpaceDir branch -f "backup/installer-$stamp-devspace" $CurrentDevSpaceHead | Out-Null
        & git -C $DevSpaceDir bundle create (Join-Path $backup "devspace.bundle") --all
        if ($LASTEXITCODE) { throw "DevSpace git bundle backup failed." }
    }
    if ($upgradeHermes) {
        & git -C $HermesDir branch -f "backup/installer-$stamp-hermes" $CurrentHermesHead | Out-Null
        & git -C $HermesDir bundle create (Join-Path $backup "hermes-gpt.bundle") --all
        if ($LASTEXITCODE) { throw "Hermes git bundle backup failed." }
        Copy-Item (Join-Path $HermesDir ".venv") (Join-Path $backup "hermes-venv") -Recurse
        $hermesHome = Join-Path $env:LOCALAPPDATA "hermes"
        if (Test-Path $hermesHome) { Copy-Item $hermesHome (Join-Path $backup "hermes-home") -Recurse; $manifest.hermesHomeBackedUp = $true }
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $backup "rollback-manifest.json") -Encoding UTF8
} catch {
    Start-ScheduledTask -TaskName $taskSnapshot.Name -TaskPath $taskSnapshot.Path -ErrorAction SilentlyContinue
    Fail "Consistent rollback backup failed: $($_.Exception.Message)"
}

try {
    if ($upgradeDevSpace) {
        Run { git -C $DevSpaceDir fetch --depth 1 $devRemote $DevSpaceRef } "Failed to fetch pinned DevSpace."
        Run { git -C $DevSpaceDir checkout --detach $PinnedDevSpaceCommit } "Failed to select pinned DevSpace."
        Push-Location $DevSpaceDir
        try {
            Run { npm.cmd ci --include=dev } "npm ci failed."
            Run { npm.cmd run build } "DevSpace build failed."
            if (-not $SkipSourceTests) { Run { npm.cmd test } "DevSpace tests failed."; Run { npm.cmd run test:windows-watchdog } "DevSpace Windows tests failed." }
            Run { npm.cmd link } "npm link failed."
        } finally { Pop-Location }
        if (Test-Path $legacyOauth) {
            Push-Location $DevSpaceDir
            try { Run { node (Join-Path $backup "migrate-oauth-json-to-sqlite.mjs") $legacyOauth $sqlite } "OAuth migration failed." } finally { Pop-Location }
        }
    }
    if ($upgradeHermes) {
        Run { git -C $HermesDir fetch --depth 1 $hermesRemote $HermesRef } "Failed to fetch pinned Hermes-GPT."
        Run { git -C $HermesDir checkout --detach $PinnedHermesCommit } "Failed to select pinned Hermes-GPT."
        Run { & $hermesPython -m pip install $HermesDir } "Hermes-GPT install failed."
        if (-not $SkipSourceTests) {
            Run { & $hermesPython -m pip install "$HermesDir[dev]" } "Hermes-GPT test dependencies failed."
            $pytestTemp = Join-Path $backup "pytest-temp"
            Run { & $hermesPython -m pytest -q --basetemp $pytestTemp $HermesDir } "Hermes-GPT tests failed."
        }
        $installedAfter = Get-HermesInstalledVersion $hermesPython
        if ($installedAfter -ne $PinnedHermesVersion) { Fail "Hermes-GPT installed version is $installedAfter, expected $PinnedHermesVersion." }
    }
    $updated = Read-Json $watchdogPath
    $updated | Add-Member -NotePropertyName ngrokInspectorPort -NotePropertyValue $ngrokInspectorPort -Force
    if ($applyCapabilities) { $updated | Add-Member -NotePropertyName capabilities -NotePropertyValue $newCapabilities -Force }
    $tmpConfig = "$watchdogPath.tmp-$PID"
    ($updated | ConvertTo-Json -Depth 12) + [Environment]::NewLine | Set-Content -LiteralPath $tmpConfig -Encoding UTF8
    Move-Item -LiteralPath $tmpConfig -Destination $watchdogPath -Force
    Copy-Item $WatchdogSource "$InstallDir\devspace-watchdog.ps1.tmp-$PID" -Force
    Move-Item "$InstallDir\devspace-watchdog.ps1.tmp-$PID" "$InstallDir\devspace-watchdog.ps1" -Force
    if ((Get-Content "$InstallDir\auth.json" -Raw) -ne (Get-Content "$backup\state\auth.json" -Raw)) { Fail "Owner auth changed unexpectedly." }
    if ((Export-ScheduledTask -TaskName $taskSnapshot.Name -TaskPath $taskSnapshot.Path) -ne $taskSnapshot.Xml) { Fail "Task privilege/definition changed unexpectedly." }
    if ($applyCapabilities) {
        $verifiedCaps = (Read-Json $watchdogPath).capabilities | ConvertTo-Json -Depth 8 -Compress
        if ($verifiedCaps -ne $newCapsJson) { Fail "Applied capability values did not verify." }
    }
    Start-ScheduledTask -TaskName $taskSnapshot.Name -TaskPath $taskSnapshot.Path
    Start-Sleep -Seconds 12
    Verify-Live
} catch {
    $failure = $_.Exception.Message
    if (-not $NoAutoRollback) {
        try { Invoke-Rollback ([pscustomobject]$manifest) $backup $taskSnapshot } catch { Write-Error "Automatic rollback also failed: $($_.Exception.Message)" }
    } else {
        Start-ScheduledTask -TaskName $taskSnapshot.Name -TaskPath $taskSnapshot.Path -ErrorAction SilentlyContinue
    }
    Write-Error "$Action stopped; rollback backup: $backup`n$failure"
    exit 1
}
Write-Host "$Action completed. Rollback backup: $backup" -ForegroundColor Green
