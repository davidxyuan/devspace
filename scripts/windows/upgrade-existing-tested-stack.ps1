[CmdletBinding()]
param(
    [string]$InstallDir = "$env:USERPROFILE\.devspace",
    [string]$DevSpaceDir,
    [string]$HermesDir,
    [string]$BackupRoot = "$env:USERPROFILE\DevSpaceUpgradeBackups",
    [switch]$DryRun,
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"
$DevSpaceRepo = "https://github.com/davidxyuan/devspace.git"
$DevSpaceRef = "codex/upgrade-devspace-v1.0.4"
$DevSpaceCommit = "9c4462ba1ea43a846fd511b8b10e4bb6ac49493d"
$HermesRepo = "https://github.com/davidxyuan/hermes-gpt.git"
$HermesRef = "codex/upgrade-v0.5.0"
$HermesCommit = "db5ffa1bd2e4fcfecdebb2bcf479334144e1cbe3"
$MigrationUrl = "https://raw.githubusercontent.com/davidxyuan/devspace/codex/windows-safe-in-place-upgrade/scripts/migrate-oauth-json-to-sqlite.mjs"

function Fail([string]$message) { throw "SAFE UPGRADE REFUSED: $message" }
function Read-Json([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { Fail "Required file is missing: $path" }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { Fail "Invalid JSON: $path" }
}
function Run([scriptblock]$command, [string]$failure) {
    & $command
    if ($LASTEXITCODE -ne 0) { Fail $failure }
}
function Assert-Repo([string]$path, [string]$expectedRemote) {
    if (-not (Test-Path -LiteralPath (Join-Path $path ".git"))) { Fail "Not a Git checkout: $path" }
    $remote = (& git -C $path remote get-url origin).Trim()
    if ($remote -ne $expectedRemote) { Fail "Unexpected origin for ${path}: $remote" }
    if (& git -C $path status --porcelain --untracked-files=no) {
        Fail "Tracked changes exist in $path; commit or revert them before upgrading."
    }
}
function Get-TaskSnapshot {
    $names = @("DevSpaceNgrokWatchdog", "DevSpaceNgrokWatchdogPoller", "DevSpaceNgrokWatchdogUserPoller", "DevSpace Serve Watchdog")
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object TaskName -In $names)
    if ($tasks.Count -ne 1) { Fail "Expected exactly one supported DevSpace watchdog task; found $($tasks.Count)." }
    $task = $tasks[0]
    $xml = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
    [pscustomobject]@{ Task = $task; Xml = $xml; Name = $task.TaskName; Path = $task.TaskPath }
}
function Stop-ManagedListeners($watchdog) {
    $ports = @($watchdog.port, $watchdog.hermesPort, $watchdog.routerPort, 4040) |
        Where-Object { $_ -and [int]$_ -gt 0 } | Select-Object -Unique
    $managedPaths = @($watchdog.cliPath, $watchdog.hermesServer, $watchdog.routerPath, $watchdog.ngrokPath) |
        Where-Object { $_ }
    foreach ($port in $ports) {
        $connections = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
        foreach ($connection in $connections) {
            $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($connection.OwningProcess)"
            $isManaged = $managedPaths | Where-Object {
                $process.CommandLine -like "*$_*" -or $process.ExecutablePath -eq $_
            }
            if (-not $isManaged) { Fail "Port $port is owned by an unrecognized process; refusing to stop it." }
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
    $watchdog = Read-Json (Join-Path $InstallDir "devspace-watchdog.config.json")
    Test-Http "http://127.0.0.1:$($watchdog.port)/healthz" @(200)
    if ($watchdog.routerPort) { Test-Http "http://127.0.0.1:$($watchdog.routerPort)/__router/status" @(200) }
    if ($watchdog.hermesEnabled) { Test-Http "http://127.0.0.1:$($watchdog.hermesPort)/mcp" @(200, 400, 401, 404, 405, 406) }
    foreach ($route in @($watchdog.mcpRoutes)) {
        $publicOrigin = ([Uri]$watchdog.publicBaseUrl).GetLeftPart([System.UriPartial]::Authority)
        Test-Http "$publicOrigin$($route.prefix)/mcp" @(200, 400, 401, 404, 405, 406)
    }
    Write-Host "Verified local DevSpace, router/Hermes, and configured public MCP routes." -ForegroundColor Green
}

$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$config = Read-Json (Join-Path $InstallDir "config.json")
$auth = Read-Json (Join-Path $InstallDir "auth.json")
$watchdog = Read-Json (Join-Path $InstallDir "devspace-watchdog.config.json")
if (-not $auth.ownerToken) { Fail "auth.json has no ownerToken; credentials will not be regenerated." }
if (-not $config.allowedRoots -or -not $watchdog.publicBaseUrl -or -not $watchdog.machineSlug) {
    Fail "Machine-specific roots, public URL, or machine identity cannot be identified."
}
if (-not $watchdog.ngrokPath -or -not (Test-Path -LiteralPath $watchdog.ngrokPath)) {
    Fail "Configured ngrok binary cannot be identified."
}

if (-not $DevSpaceDir) { $DevSpaceDir = Split-Path (Split-Path ([string]$watchdog.cliPath) -Parent) -Parent }
if (-not $HermesDir) { $HermesDir = [string]$watchdog.hermesWorkingDirectory }
if (-not $DevSpaceDir -or -not $HermesDir) { Fail "DevSpace or Hermes checkout cannot be identified from watchdog config." }
$DevSpaceDir = [IO.Path]::GetFullPath($DevSpaceDir)
$HermesDir = [IO.Path]::GetFullPath($HermesDir)
Assert-Repo $DevSpaceDir $DevSpaceRepo
Assert-Repo $HermesDir $HermesRepo
$taskSnapshot = Get-TaskSnapshot

$stateDir = if ($config.stateDir) {
    [IO.Path]::GetFullPath([string]$config.stateDir)
} else {
    [IO.Path]::GetFullPath("$env:USERPROFILE\.local\share\devspace")
}
$legacyOauth = Join-Path $stateDir "oauth-state.json"
$sqlite = Join-Path $stateDir "devspace.sqlite"
if ((Test-Path $legacyOauth) -and (Test-Path $sqlite)) {
    $dbSize = (Get-Item $sqlite).Length
    if ($dbSize -eq 0) { Fail "Existing SQLite database is empty/corrupt." }
}

Write-Host "Existing supported stack detected:"
Write-Host "  DevSpace: $DevSpaceDir"
Write-Host "  Hermes:   $HermesDir"
Write-Host "  State:    $stateDir"
Write-Host "  Task:     $($taskSnapshot.Name)"
if ($DryRun) {
    Write-Host "Dry run complete. No services, files, repositories, or tasks were changed." -ForegroundColor Green
    exit 0
}
if ($VerifyOnly) {
    Verify-Live
    exit 0
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path ([IO.Path]::GetFullPath($BackupRoot)) $stamp
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Stop-ScheduledTask -TaskName $taskSnapshot.Name -TaskPath $taskSnapshot.Path -ErrorAction Stop
try {
    Stop-ManagedListeners $watchdog
    $taskSnapshot.Xml | Set-Content -LiteralPath (Join-Path $backup "watchdog-task.xml") -Encoding Unicode
    Invoke-WebRequest -Uri $MigrationUrl -OutFile (Join-Path $backup "migrate-oauth-json-to-sqlite.mjs") -UseBasicParsing
    Copy-Item -LiteralPath $InstallDir -Destination (Join-Path $backup "state") -Recurse
    if ($stateDir -ne $InstallDir -and (Test-Path -LiteralPath $stateDir)) {
        Copy-Item -LiteralPath $stateDir -Destination (Join-Path $backup "devspace-data") -Recurse
    }
    Copy-Item -LiteralPath $DevSpaceDir -Destination (Join-Path $backup "devspace") -Recurse
    Copy-Item -LiteralPath $HermesDir -Destination (Join-Path $backup "hermes-gpt") -Recurse
    $hermesHome = "$env:LOCALAPPDATA\hermes"
    if (Test-Path -LiteralPath $hermesHome) {
        Copy-Item -LiteralPath $hermesHome -Destination (Join-Path $backup "hermes-home") -Recurse
    }
    foreach ($ngrokConfig in @("$env:LOCALAPPDATA\ngrok\ngrok.yml", "$env:USERPROFILE\.ngrok2\ngrok.yml")) {
        if (Test-Path -LiteralPath $ngrokConfig) { Copy-Item -LiteralPath $ngrokConfig -Destination $backup }
    }
    $manifest = [ordered]@{
        createdAt = (Get-Date).ToString("o"); installDir = $InstallDir; stateDir = $stateDir
        devspaceDir = $DevSpaceDir; hermesDir = $HermesDir; taskName = $taskSnapshot.Name
        devspaceHead = (& git -C $DevSpaceDir rev-parse HEAD); hermesHead = (& git -C $HermesDir rev-parse HEAD)
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup "rollback-manifest.json") -Encoding UTF8
} catch {
    Start-ScheduledTask -TaskName $taskSnapshot.Name -TaskPath $taskSnapshot.Path -ErrorAction SilentlyContinue
    Fail "Rollback backup could not be completed at ${backup}: $($_.Exception.Message)"
}

try {
    Run { git -C $DevSpaceDir fetch --depth 1 origin $DevSpaceRef } "Failed to fetch pinned DevSpace."
    Run { git -C $DevSpaceDir checkout --detach $DevSpaceCommit } "Failed to select pinned DevSpace commit."
    Push-Location $DevSpaceDir
    try {
        Run { npm ci --include=dev } "DevSpace dependency install failed."
        Run { npm run build } "DevSpace build failed."
        Run { npm link } "DevSpace command link failed."
    } finally { Pop-Location }

    Run { git -C $HermesDir fetch --depth 1 origin $HermesRef } "Failed to fetch pinned Hermes-GPT."
    Run { git -C $HermesDir checkout --detach $HermesCommit } "Failed to select pinned Hermes-GPT commit."
    $hermesPython = Join-Path $HermesDir ".venv\Scripts\python.exe"
    if (-not (Test-Path $hermesPython)) { Fail "Existing Hermes virtual environment is missing." }
    Run { & $hermesPython -m pip install $HermesDir } "Hermes-GPT package upgrade failed."

    if (Test-Path $legacyOauth) {
        Push-Location $DevSpaceDir
        try {
            Run { node (Join-Path $backup "migrate-oauth-json-to-sqlite.mjs") $legacyOauth $sqlite } "OAuth JSON-to-SQLite migration failed."
        } finally { Pop-Location }
    }
    if ((Get-Content (Join-Path $InstallDir "auth.json") -Raw) -ne (Get-Content (Join-Path $backup "state\auth.json") -Raw)) {
        Fail "Owner authentication data changed unexpectedly."
    }
    if ((Get-Content (Join-Path $InstallDir "devspace-watchdog.config.json") -Raw) -ne (Get-Content (Join-Path $backup "state\devspace-watchdog.config.json") -Raw)) {
        Fail "Watchdog configuration changed unexpectedly."
    }
    if ((Export-ScheduledTask -TaskName $taskSnapshot.Name -TaskPath $taskSnapshot.Path) -ne $taskSnapshot.Xml) {
        Fail "Watchdog task definition or privilege mode changed unexpectedly."
    }
    Start-ScheduledTask -TaskName $taskSnapshot.Name -TaskPath $taskSnapshot.Path
    Start-Sleep -Seconds 8
    Verify-Live
} catch {
    Write-Error "Upgrade stopped. Services were not declared healthy. Rollback backup: $backup`n$($_.Exception.Message)"
    exit 1
}

Write-Host "Safe in-place upgrade completed. Rollback backup: $backup" -ForegroundColor Green
