[CmdletBinding()]
param(
    [string]$InstallDir = "$env:USERPROFILE\.devspace",
    [string]$DevSpaceDir,
    [string]$HermesDir,
    [string]$BackupRoot = "$env:USERPROFILE\DevSpaceUpgradeBackups",
    [ValidateSet("Auto", "Upgrade", "CapabilitiesOnly")][string]$Action = "Auto",
    [string]$CapabilitySelection = "",
    [string[]]$HermesAllowedRoots = @(),
    [switch]$DryRun,
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"
$DevSpaceRepo = "https://github.com/davidxyuan/devspace.git"
$DevSpaceRef = "codex/windows-fixed-port-conflicts"
$DevSpaceCommit = "ca7c10a39b5c099455db662c3aba9007b5eb34e3"
$DevSpaceVersion = [version]"1.0.4"
$HermesRepo = "https://github.com/davidxyuan/hermes-gpt.git"
$HermesRef = "codex/upgrade-v0.5.0"
$HermesCommit = "db5ffa1bd2e4fcfecdebb2bcf479334144e1cbe3"
$HermesVersion = [version]"0.5.0"
$RawBase = "https://raw.githubusercontent.com/davidxyuan/devspace/codex/windows-fixed-port-conflicts"
$MigrationUrl = "$RawBase/scripts/migrate-oauth-json-to-sqlite.mjs"
$CapabilityHelperUrl = "$RawBase/scripts/windows/capability-config.ps1"
$WatchdogUrl = "$RawBase/scripts/windows/devspace-watchdog.ps1"

function Fail([string]$message) { throw "SAFE EXISTING-MACHINE ACTION REFUSED: $message" }
function Read-Json([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { Fail "Required file is missing: $path" }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { Fail "Invalid JSON: $path" }
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
            ([string]$_.CommandLine).IndexOf($agentUrl, [System.StringComparison]::OrdinalIgnoreCase) -lt 0
        }).Count -eq 0) { return $candidate }
    }
    Fail "No available ngrok inspection UI port in $preferred-$($preferred + 99)."
}
function Run([scriptblock]$command, [string]$failure) {
    & $command
    if ($LASTEXITCODE -ne 0) { Fail $failure }
}
function Resolve-RepoRemote([string]$path, [string]$expectedRemote) {
    if (-not (Test-Path -LiteralPath (Join-Path $path ".git"))) { Fail "Not a Git checkout: $path" }
    if (& git -C $path status --porcelain --untracked-files=no) {
        Fail "Tracked changes exist in $path; no upgrade or capability change was attempted."
    }
    foreach ($name in @(& git -C $path remote)) {
        $url = (& git -C $path remote get-url $name).Trim()
        if ($url -eq $expectedRemote) { return [string]$name }
    }
    Fail "No Git remote in $path points to expected repository: $expectedRemote"
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
    }
}
function Stop-ManagedListeners($watchdog) {
    $inspectorPort = if ($watchdog.ngrokInspectorPort) { [int]$watchdog.ngrokInspectorPort } else { 4040 }
    $ports = @($watchdog.port, $watchdog.hermesPort, $watchdog.routerPort, $inspectorPort) |
        Where-Object { $_ -and [int]$_ -gt 0 } | Select-Object -Unique
    $managedPaths = @($watchdog.cliPath, $watchdog.hermesServer, $watchdog.routerPath, $watchdog.ngrokPath) | Where-Object { $_ }
    foreach ($port in $ports) {
        foreach ($connection in @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) {
            $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($connection.OwningProcess)"
            $isManaged = $managedPaths | Where-Object { $process.CommandLine -like "*$_*" -or $process.ExecutablePath -eq $_ }
            if (-not $isManaged) {
                if ([int]$port -eq $inspectorPort) { continue }
                Fail "FIXED PORT CONFLICT: 127.0.0.1:$port is owned by PID $($process.ProcessId) ($($process.Name)), command=$($process.CommandLine). Stop or reconfigure that process and rerun; no service port will be moved or owner stopped."
            }
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        }
    }
}
function Test-Http([string]$url, [int[]]$accepted) {
    try {
        $response = Invoke-WebRequest -Uri $url -TimeoutSec 15 -UseBasicParsing
        $status = [int]$response.StatusCode
    } catch {
        if (-not $_.Exception.Response) { Fail "Endpoint unreachable: $url" }
        $status = [int]$_.Exception.Response.StatusCode
    }
    if ($status -notin $accepted) { Fail "Unexpected HTTP $status from $url" }
}
function Verify-Live {
    $live = Read-Json (Join-Path $InstallDir "devspace-watchdog.config.json")
    Test-Http "http://127.0.0.1:$($live.port)/healthz" @(200)
    if ($live.routerPort) { Test-Http "http://127.0.0.1:$($live.routerPort)/__router/status" @(200) }
    if ($live.hermesEnabled) { Test-Http "http://127.0.0.1:$($live.hermesPort)/mcp" @(200, 400, 401, 405, 406) }
    foreach ($route in @($live.mcpRoutes)) {
        $origin = ([Uri]$live.publicBaseUrl).GetLeftPart([System.UriPartial]::Authority)
        Test-Http "$origin$($route.prefix)/mcp" @(200, 400, 401, 405, 406)
    }
}
function Get-CurrentCapabilityArguments($watchdog) {
    $dev = $watchdog.capabilities.devspace
    $hermes = $watchdog.capabilities.hermes
    if (-not $dev) {
        $dev = [pscustomobject]@{ toolMode = "minimal"; widgets = "full"; skills = $true; subagents = $false }
    }
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
        DevSpaceSkills=$(if ([bool]$dev.skills){"On"}else{"Off"})
        DevSpaceSubagents=$(if ([bool]$dev.subagents){"On"}else{"Off"})
        HermesBridge=$(if ([bool]$hermes.bridge){"On"}else{"Off"})
        HermesReadOnlyTools=$(if ([bool]$hermes.readOnlyTools){"On"}else{"Off"})
        HermesVision=$(if ([bool]$hermes.vision){"On"}else{"Off"}); HermesWeb=$(if ([bool]$hermes.web){"On"}else{"Off"})
        HermesDiagnostics=$(if ([bool]$hermes.diagnostics){"On"}else{"Off"})
        HermesRunner=$(if ([bool]$hermes.runner){"On"}else{"Off"}); HermesRunnerWrite=$(if ([bool]$hermes.runnerWrite){"On"}else{"Off"})
        HermesWorkspaceWrite=$(if ([bool]$hermes.workspaceWrite){"On"}else{"Off"})
        HermesMemoryWrite=$(if ([bool]$hermes.memoryWrite){"On"}else{"Off"})
        HermesTerminal=$(if ([bool]$hermes.terminal){"On"}else{"Off"}); HermesOperator=$(if ([bool]$hermes.operator){"On"}else{"Off"})
        HermesOperatorDirect=$(if ([bool]$hermes.operatorDirect){"On"}else{"Off"})
        HermesOwnerMode=$(if ([bool]$hermes.ownerMode){"On"}else{"Off"}); HermesCron=$(if ([bool]$hermes.cron){"On"}else{"Off"})
        HermesCronWrite=$(if ([bool]$hermes.cronWrite){"On"}else{"Off"}); HermesSkillWrite=$(if ([bool]$hermes.skillWrite){"On"}else{"Off"})
        HermesPrivateNetwork=$(if ([bool]$hermes.privateNetwork){"On"}else{"Off"})
        HermesFilesystemScope=[string]$hermes.filesystemScope
        HermesAllowedRoots=@($hermes.allowedRoots)
    }
}

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

. (Join-Path $PSScriptRoot "capability-config.ps1")
$devVersion = [version]((Get-Content (Join-Path $DevSpaceDir "package.json") -Raw | ConvertFrom-Json).version)
$devHead = (& git -C $DevSpaceDir rev-parse HEAD).Trim()
$hermesPython = Join-Path $HermesDir ".venv\Scripts\python.exe"
if (-not (Test-Path $hermesPython)) { Fail "Existing Hermes virtual environment is missing." }
$hermesProjectText = Get-Content (Join-Path $HermesDir "pyproject.toml") -Raw
if ($hermesProjectText -notmatch '(?m)^version\s*=\s*"([^"]+)"') { Fail "Hermes-GPT project version cannot be read." }
$hermesVersion = [version]$Matches[1]
$hermesHead = (& git -C $HermesDir rev-parse HEAD).Trim()
try {
    $detectedAction = Get-TestedStackAction $true $devVersion $hermesVersion $DevSpaceVersion $HermesVersion $devHead $hermesHead $DevSpaceCommit $HermesCommit
} catch {
    Fail "$($_.Exception.Message) Current state: DevSpace $devVersion ($devHead), Hermes-GPT $hermesVersion ($hermesHead)."
}
if ($Action -eq "CapabilitiesOnly" -and $detectedAction -ne "CapabilitiesOnly") {
    Fail "Requested CapabilitiesOnly but component upgrades are required: $detectedAction."
}
if ($Action -eq "Upgrade" -and $detectedAction -eq "CapabilitiesOnly") {
    Fail "Requested Upgrade but both tested components are already current."
}
$Action = $detectedAction
$upgradeDevSpace = $Action -in @("Upgrade", "UpgradeDevSpace")
$upgradeHermes = $Action -in @("Upgrade", "UpgradeHermes")
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
Write-Host "Detected action: $Action (DevSpace $devVersion, Hermes-GPT $hermesVersion)"
Write-Host "Port policy: DevSpace $($watchdog.port), Hermes-GPT $($watchdog.hermesPort), and router $($watchdog.routerPort) stay fixed; ngrok inspection URL will be http://127.0.0.1:$ngrokInspectorPort"
Write-Host "Capability delta:"
if ($applyCapabilities) {
    Write-Host "  before: $oldCapsJson"
    Write-Host "  after:  $newCapsJson"
} else {
    Write-Host "  Preserve current effective settings (no capability write requested)."
}
if ($DryRun) { Write-Host "Dry run complete; no live state changed." -ForegroundColor Green; exit 0 }
if ($VerifyOnly) { Verify-Live; Write-Host "Verification complete." -ForegroundColor Green; exit 0 }

$stateDir = if ($config.stateDir) { [IO.Path]::GetFullPath([string]$config.stateDir) } else { [IO.Path]::GetFullPath("$env:USERPROFILE\.local\share\devspace") }
$legacyOauth = Join-Path $stateDir "oauth-state.json"
$sqlite = Join-Path $stateDir "devspace.sqlite"
$backup = Join-Path ([IO.Path]::GetFullPath($BackupRoot)) (Get-Date -Format "yyyyMMdd-HHmmss")
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Stop-ScheduledTask -TaskName $taskSnapshot.Name -TaskPath $taskSnapshot.Path -ErrorAction Stop
try {
    Stop-ManagedListeners $watchdog
    $taskSnapshot.Xml | Set-Content (Join-Path $backup "watchdog-task.xml") -Encoding Unicode
    Copy-Item $InstallDir (Join-Path $backup "state") -Recurse
    if ($upgradeDevSpace -or $upgradeHermes) {
        if ($stateDir -ne $InstallDir -and (Test-Path $stateDir)) { Copy-Item $stateDir (Join-Path $backup "devspace-data") -Recurse }
    }
    if ($upgradeDevSpace) {
        Invoke-WebRequest $MigrationUrl -OutFile (Join-Path $backup "migrate-oauth-json-to-sqlite.mjs") -UseBasicParsing
        Copy-Item $DevSpaceDir (Join-Path $backup "devspace") -Recurse
    }
    if ($upgradeHermes) {
        Copy-Item $HermesDir (Join-Path $backup "hermes-gpt") -Recurse
        if (Test-Path "$env:LOCALAPPDATA\hermes") { Copy-Item "$env:LOCALAPPDATA\hermes" (Join-Path $backup "hermes-home") -Recurse }
    }
    [ordered]@{
        createdAt=(Get-Date).ToString("o"); action=$Action; installDir=$InstallDir
        devspaceDir=$DevSpaceDir; hermesDir=$HermesDir; taskName=$taskSnapshot.Name
        devspaceHead=(& git -C $DevSpaceDir rev-parse HEAD); hermesHead=(& git -C $HermesDir rev-parse HEAD)
        capabilitiesBefore=$oldCapsJson; capabilitiesAfter=$newCapsJson
    } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $backup "rollback-manifest.json") -Encoding UTF8
} catch {
    Start-ScheduledTask -TaskName $taskSnapshot.Name -TaskPath $taskSnapshot.Path -ErrorAction SilentlyContinue
    Fail "Consistent rollback backup failed: $($_.Exception.Message)"
}

try {
    if ($upgradeDevSpace) {
        Run { git -C $DevSpaceDir fetch --depth 1 $devRemote $DevSpaceRef } "Failed to fetch pinned DevSpace."
        Run { git -C $DevSpaceDir checkout --detach $DevSpaceCommit } "Failed to select pinned DevSpace."
        Push-Location $DevSpaceDir
        try { Run { npm ci --include=dev } "npm ci failed."; Run { npm run build } "DevSpace build failed."; Run { npm link } "npm link failed." } finally { Pop-Location }
        if (Test-Path $legacyOauth) {
            Push-Location $DevSpaceDir
            try { Run { node (Join-Path $backup "migrate-oauth-json-to-sqlite.mjs") $legacyOauth $sqlite } "OAuth migration failed." } finally { Pop-Location }
        }
    }
    if ($upgradeHermes) {
        Run { git -C $HermesDir fetch --depth 1 $hermesRemote $HermesRef } "Failed to fetch pinned Hermes-GPT."
        Run { git -C $HermesDir checkout --detach $HermesCommit } "Failed to select pinned Hermes-GPT."
        Run { & $hermesPython -m pip install $HermesDir } "Hermes-GPT install failed."
    }

    $updated = Read-Json $watchdogPath
    $updated | Add-Member -NotePropertyName ngrokInspectorPort -NotePropertyValue $ngrokInspectorPort -Force
    if ($applyCapabilities) {
        $updated | Add-Member -NotePropertyName capabilities -NotePropertyValue $newCapabilities -Force
    }
    $tmpConfig = "$watchdogPath.tmp-$PID"
    ($updated | ConvertTo-Json -Depth 12) + [Environment]::NewLine |
        Set-Content -LiteralPath $tmpConfig -Encoding UTF8
    Move-Item -LiteralPath $tmpConfig -Destination $watchdogPath -Force
    Invoke-WebRequest $WatchdogUrl -OutFile "$InstallDir\devspace-watchdog.ps1.tmp-$PID" -UseBasicParsing
    Move-Item "$InstallDir\devspace-watchdog.ps1.tmp-$PID" "$InstallDir\devspace-watchdog.ps1" -Force

    if ((Get-Content "$InstallDir\auth.json" -Raw) -ne (Get-Content "$backup\state\auth.json" -Raw)) { Fail "Owner auth changed unexpectedly." }
    if ((Export-ScheduledTask -TaskName $taskSnapshot.Name -TaskPath $taskSnapshot.Path) -ne $taskSnapshot.Xml) { Fail "Task privilege/definition changed unexpectedly." }
    if ($applyCapabilities) {
        $verifiedCaps = (Read-Json $watchdogPath).capabilities | ConvertTo-Json -Depth 8 -Compress
        if ($verifiedCaps -ne $newCapsJson) { Fail "Applied capability values did not verify." }
    }
    if ([int](Read-Json $watchdogPath).ngrokInspectorPort -ne $ngrokInspectorPort) { Fail "ngrok inspection port did not verify." }
    Start-ScheduledTask -TaskName $taskSnapshot.Name -TaskPath $taskSnapshot.Path
    Start-Sleep -Seconds 8
    Verify-Live
} catch {
    Write-Error "$Action stopped; rollback backup: $backup`n$($_.Exception.Message)"
    exit 1
}
Write-Host "$Action completed. Rollback backup: $backup" -ForegroundColor Green
