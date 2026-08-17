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

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

function Get-Winget {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) { throw "winget.exe is required but unavailable. Install Microsoft App Installer first." }
    return $winget.Source
}

function Install-WingetPackage([string]$wingetId, [string]$displayName) {
    $winget = Get-Winget
    Write-Host "Installing $displayName ($wingetId)..." -ForegroundColor Cyan
    & $winget install --id $wingetId --exact --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $displayName ($wingetId). Exit code: $LASTEXITCODE"
    }
    Refresh-Path
}

function Try-InstallWingetPackage([string]$wingetId, [string]$displayName) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) {
        Write-Warning "winget.exe is unavailable; skipping winget for $displayName."
        return $false
    }

    Write-Host "Trying winget for $displayName ($wingetId)..." -ForegroundColor Cyan
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $winget.Source install --id $wingetId --exact --source winget --accept-package-agreements --accept-source-agreements
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    Refresh-Path
    if ($code -eq 0) { return $true }
    Write-Warning "winget could not install $displayName (exit code $code). Falling back to the official installer."
    return $false
}

function Require-Command([string]$name, [string]$wingetId) {
    $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    Install-WingetPackage $wingetId $name
    $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw "$name was installed but is not on PATH. Open a new PowerShell window and rerun." }
    return $command.Source
}

function Get-CompatiblePython {
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($command in @(Get-Command python.exe -All -ErrorAction SilentlyContinue)) {
        if ($command.Source) { $candidates.Add([string]$command.Source) }
    }

    $py = Get-Command py.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($py) {
        foreach ($selector in @("3.13", "3.12", "3.11", "3.10")) {
            try {
                $resolved = (& $py.Source "-$selector" -c "import sys; print(sys.executable)" 2>$null | Select-Object -First 1)
                if ($LASTEXITCODE -eq 0 -and $resolved) { $candidates.Add(([string]$resolved).Trim()) }
            } catch {}
        }
    }

    foreach ($pattern in @(
        "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
        "$env:ProgramFiles\Python3*\python.exe",
        "${env:ProgramFiles(x86)}\Python3*\python.exe"
    )) {
        if (-not $pattern) { continue }
        foreach ($item in @(Get-Item $pattern -ErrorAction SilentlyContinue)) {
            if ($item.FullName) { $candidates.Add([string]$item.FullName) }
        }
    }

    $compatible = @()
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $versionText = (& $candidate -c "import platform; print(platform.python_version())" 2>$null | Select-Object -First 1)
            if ($LASTEXITCODE -ne 0 -or -not $versionText) { continue }
            $version = [version](([string]$versionText).Trim())
            if ($version -ge [version]"3.10") {
                $compatible += [pscustomobject]@{ Path=$candidate; Version=$version }
            }
        } catch {}
    }

    return $compatible | Sort-Object Version -Descending | Select-Object -First 1
}

function Install-OfficialPython312 {
    $version = "3.12.10"
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($arch) {
        "ARM64" { $fileName = "python-$version-arm64.exe"; break }
        "AMD64" { $fileName = "python-$version-amd64.exe"; break }
        "x86" { $fileName = "python-$version.exe"; break }
        default { throw "Unsupported Windows architecture for automatic Python install: $arch" }
    }

    $url = "https://www.python.org/ftp/python/$version/$fileName"
    $installerPath = Join-Path $env:TEMP $fileName
    $logPath = "$installerPath.log"
    Write-Host "Downloading official Python $version installer from python.org..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $url -OutFile $installerPath -UseBasicParsing
    } catch {
        throw "Failed to download the official Python $version installer from $url. $($_.Exception.Message)"
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $installerPath
    if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -notmatch "Python Software Foundation") {
        throw "Downloaded Python installer failed Authenticode validation. Status=$($signature.Status); Signer=$($signature.SignerCertificate.Subject)"
    }

    Write-Host "Installing official Python $version for the current user..." -ForegroundColor Cyan
    $arguments = @(
        "/quiet",
        "InstallAllUsers=0",
        "PrependPath=1",
        "Include_pip=1",
        "Include_launcher=1",
        "Include_test=0",
        "/log",
        "`"$logPath`""
    )
    $process = Start-Process -FilePath $installerPath -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "Official Python $version installer failed with exit code $($process.ExitCode). Log: $logPath"
    }
    Refresh-Path
}

function Require-CompatiblePython {
    $python = Get-CompatiblePython
    if ($python) {
        Write-Host "Using Python $($python.Version): $($python.Path)" -ForegroundColor Green
        return [string]$python.Path
    }

    Write-Host "No Python >=3.10 was found. Installing Python 3.12 side-by-side with any existing Python..." -ForegroundColor Yellow
    $wingetOk = Try-InstallWingetPackage "Python.Python.3.12" "Python 3.12"
    if ($wingetOk) {
        $python = Get-CompatiblePython
    }
    if (-not $python) {
        Install-OfficialPython312
        $python = Get-CompatiblePython
    }
    if (-not $python) {
        throw "Python installation completed, but no compatible Python >=3.10 could be resolved. Open a new PowerShell window and rerun. Existing older Python versions do not need to be removed."
    }
    Write-Host "Using Python $($python.Version): $($python.Path)" -ForegroundColor Green
    return [string]$python.Path
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
$python = Require-CompatiblePython
if ([version](& $node -p "process.versions.node") -lt [version]"22.19" -or [version](& $node -p "process.versions.node") -ge [version]"27.0") {
    throw "DevSpace $DevSpaceVersion requires Node >=22.19 and <27. Current Node: $(& $node -p 'process.versions.node'). Install/update Node.js LTS and rerun."
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
