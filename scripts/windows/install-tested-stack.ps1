[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:LOCALAPPDATA\DevSpaceTestedStack",
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"

# Tested stack manifest: update these values together only after validating a new pair.
$DevSpaceRepo = "https://github.com/davidxyuan/devspace.git"
$DevSpaceRef = "codex/upgrade-devspace-v1.0.4"
$DevSpaceCommit = "9c4462ba1ea43a846fd511b8b10e4bb6ac49493d"
$DevSpaceVersion = "1.0.4"
$HermesRepo = "https://github.com/davidxyuan/hermes-gpt.git"
$HermesRef = "codex/upgrade-v0.5.0"
$HermesCommit = "db5ffa1bd2e4fcfecdebb2bcf479334144e1cbe3"
$HermesVersion = "0.5.0"

$devSpaceDir = Join-Path $InstallRoot "devspace"
$hermesDir = Join-Path $InstallRoot "hermes-gpt"
$hermesPython = Join-Path $hermesDir ".venv\Scripts\python.exe"

function Require-Command([string]$name, [string]$wingetId) {
    $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { throw "$name is required and winget is unavailable." }
    & $winget.Source install --id $wingetId --exact --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget failed to install $wingetId." }
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw "$name was installed but is not on PATH. Open a new PowerShell window and rerun." }
    return $command.Source
}

function Invoke-Checked([scriptblock]$command, [string]$message) {
    & $command
    if ($LASTEXITCODE -ne 0) { throw $message }
}

function Assert-Equal([string]$name, [string]$actual, [string]$expected) {
    if ($actual.Trim() -ne $expected) { throw "$name mismatch. Expected '$expected', found '$actual'." }
}

function Install-PinnedRepo([string]$repo, [string]$ref, [string]$commit, [string]$path) {
    if (Test-Path -LiteralPath $path) {
        if (-not (Test-Path -LiteralPath (Join-Path $path ".git"))) { throw "Install target exists and is not a Git checkout: $path" }
        Assert-Equal "$path remote" (& git -C $path remote get-url origin) $repo
    } else {
        Invoke-Checked { git clone --no-checkout --filter=blob:none $repo $path } "Failed to clone $repo."
    }
    Invoke-Checked { git -C $path fetch --depth 1 origin $ref } "Failed to fetch tested ref $ref."
    Invoke-Checked { git -C $path checkout --detach $commit } "Failed to check out tested commit $commit."
    Assert-Equal "$path commit" (& git -C $path rev-parse HEAD) $commit
}

function Verify-Stack {
    Assert-Equal "DevSpace commit" (& git -C $devSpaceDir rev-parse HEAD) $DevSpaceCommit
    Assert-Equal "DevSpace version" ((Get-Content (Join-Path $devSpaceDir "package.json") -Raw | ConvertFrom-Json).version) $DevSpaceVersion
    if (-not (Test-Path -LiteralPath (Join-Path $devSpaceDir "dist\cli.js"))) { throw "DevSpace build is missing." }
    Assert-Equal "Hermes-GPT commit" (& git -C $hermesDir rev-parse HEAD) $HermesCommit
    Assert-Equal "Hermes-GPT version" (& $hermesPython -c "from importlib.metadata import version; print(version('hermes-gpt'))") $HermesVersion
    Write-Host "Verified DevSpace $DevSpaceVersion and Hermes-GPT $HermesVersion." -ForegroundColor Green
}

if ($VerifyOnly) {
    Verify-Stack
    exit 0
}

$git = Require-Command "git.exe" "Git.Git"
$npm = Require-Command "npm.cmd" "OpenJS.NodeJS.LTS"
$node = Require-Command "node.exe" "OpenJS.NodeJS.LTS"
$python = Require-Command "python.exe" "Python.Python.3.12"
if ([version](& $node -p "process.versions.node") -lt [version]"22.19" -or [version](& $node -p "process.versions.node") -ge [version]"27.0") {
    throw "DevSpace $DevSpaceVersion requires Node >=22.19 and <27."
}
if ([version](& $python -c "import platform; print(platform.python_version())") -lt [version]"3.10") {
    throw "Hermes-GPT $HermesVersion requires Python >=3.10."
}
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

Install-PinnedRepo $DevSpaceRepo $DevSpaceRef $DevSpaceCommit $devSpaceDir
Push-Location $devSpaceDir
try {
    Invoke-Checked { & $npm ci --include=dev } "DevSpace dependency install failed."
    Invoke-Checked { & $npm run build } "DevSpace build failed."
    Invoke-Checked { & $npm link } "DevSpace npm link failed."
} finally {
    Pop-Location
}

Install-PinnedRepo $HermesRepo $HermesRef $HermesCommit $hermesDir
if (-not (Test-Path -LiteralPath $hermesPython)) {
    Invoke-Checked { & $python -m venv (Join-Path $hermesDir ".venv") } "Hermes-GPT virtual environment creation failed."
}
Invoke-Checked { & $hermesPython -m pip install $hermesDir } "Hermes-GPT install failed."
Verify-Stack

Write-Host ""
Write-Host "Code and dependencies are installed. No OAuth state, secrets, routes, SQLite data, or scheduled tasks were copied or created." -ForegroundColor Yellow
Write-Host "For a complete fresh/existing auto-detected setup with validated capability choices, use scripts\windows\detect-and-apply-tested-stack.ps1 from codex/windows-fixed-port-conflicts."
Write-Host "Configure this machine next (choose its own URL, roots, token, and task settings):"
Write-Host "  powershell.exe -ExecutionPolicy Bypass -File `"$devSpaceDir\scripts\windows\install-devspace-watchdog.ps1`" -Components DevSpace,Hermes -HermesDir `"$hermesDir`" -CliPath `"$devSpaceDir\dist\cli.js`" -SkipNpmInstall -SkipHermesInstall -PublicBaseUrl `"https://THIS-MACHINE.example.com`" -AllowedRoots `"C:\path\to\approved\workspaces`" -InstallTools"
