[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:LOCALAPPDATA\DevSpaceTestedStack",
    [string]$PythonPath,
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

# Python 3.12's legacy Windows installer cannot relocate an already-installed 3.12
# during Modify mode. If an existing 3.12 registration is unusable, use a different
# minor version that Hermes supports and install it as an isolated fallback under InstallRoot.
$managedPythonFallbackVersion = "3.11.9"
$managedPythonFallbackDir = Join-Path $InstallRoot "tools\python\3.11.9"
$managedPythonFallbackExe = Join-Path $managedPythonFallbackDir "python.exe"

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
    & $winget install --id $wingetId --exact --source winget --accept-package-agreements --accept-source-agreements 2>&1 | Out-Host
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
        & $winget.Source install --id $wingetId --exact --source winget --accept-package-agreements --accept-source-agreements 2>&1 | Out-Host
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    Refresh-Path
    if ($code -eq 0) { return $true }
    if ($code -eq -1978335189) {
        Write-Warning "winget reports no applicable update for $displayName (0x8A15002B). An installation may already be registered; discovery will be retried before using the isolated fallback."
    } else {
        Write-Warning "winget could not install $displayName (exit code $code). Discovery will be retried before using the isolated fallback."
    }
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

function Add-PythonCandidate([System.Collections.Generic.List[string]]$List, [string]$Path) {
    if ($Path -and -not [string]::IsNullOrWhiteSpace($Path)) {
        [void]$List.Add($Path.Trim())
    }
}

function Get-PythonRuntimeInfo([string]$Path, [switch]$RequireVenv) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $versionText = (& $Path -c "import platform; print(platform.python_version())" 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0 -or -not $versionText) { return $null }
        $version = [version](([string]$versionText).Trim())
        if ($version -lt [version]"3.10" -or $version -ge [version]"3.13") { return $null }
        $runtimeProbe = (& $Path -c "import sys; print(sys.executable)" 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0 -or -not $runtimeProbe) { return $null }
        $pipProbe = (& $Path -m pip --version 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0 -or -not $pipProbe) { return $null }
        if ($RequireVenv) {
            $venvRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("devspace-python-smoke-" + [Guid]::NewGuid().ToString("N"))
            try {
                & $Path -m venv $venvRoot 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { return $null }
                $venvPython = Join-Path $venvRoot "Scripts\python.exe"
                if (-not (Test-Path -LiteralPath $venvPython)) { return $null }
                & $venvPython -c "import sys; print(sys.prefix)" 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) { return $null }
                & $venvPython -m pip --version 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) { return $null }
            } finally {
                Remove-Item -LiteralPath $venvRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        return [pscustomobject]@{ Path=[System.IO.Path]::GetFullPath($Path); Version=$version }
    } catch { return $null }
}

function Get-CompatiblePython {
    if ($PythonPath) {
        $explicit = Get-PythonRuntimeInfo -Path $PythonPath -RequireVenv
        if (-not $explicit) { throw "Explicit -PythonPath is not a usable Python >=3.10,<3.13 runtime with pip and venv: $PythonPath" }
        return $explicit
    }
    $candidates = New-Object System.Collections.Generic.List[string]

    Add-PythonCandidate $candidates $managedPythonFallbackExe

    foreach ($command in @(Get-Command python.exe -All -ErrorAction SilentlyContinue)) {
        if ($command.Source) { Add-PythonCandidate $candidates ([string]$command.Source) }
    }

    $py = Get-Command py.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($py) {
        foreach ($selector in @("3.12", "3.11", "3.10")) {
            try {
                $resolved = (& $py.Source "-$selector" -c "import sys; print(sys.executable)" 2>$null | Select-Object -First 1)
                if ($LASTEXITCODE -eq 0 -and $resolved) { Add-PythonCandidate $candidates ([string]$resolved) }
            } catch {}
        }
    }

    # Read the exact PEP 514 keys used by the traditional CPython Windows installer.
    foreach ($hive in @(
        "Registry::HKEY_CURRENT_USER\Software\Python\PythonCore",
        "Registry::HKEY_LOCAL_MACHINE\Software\Python\PythonCore",
        "Registry::HKEY_LOCAL_MACHINE\Software\Wow6432Node\Python\PythonCore"
    )) {
        foreach ($versionName in @("3.12", "3.11", "3.10")) {
            $installKeyPath = "$hive\$versionName\InstallPath"
            $installKey = Get-Item -LiteralPath $installKeyPath -ErrorAction SilentlyContinue
            if (-not $installKey) { continue }
            try {
                $executablePath = [string]$installKey.GetValue("ExecutablePath")
                $installPath = [string]$installKey.GetValue("")
                if ($executablePath) {
                    Add-PythonCandidate $candidates $executablePath
                } elseif ($installPath) {
                    Add-PythonCandidate $candidates (Join-Path $installPath "python.exe")
                }
            } catch {}
        }
    }

    # Explicit default locations avoid relying on PATH or wildcard registry-provider behavior.
    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python311\python.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python310\python.exe"),
        (Join-Path $env:ProgramFiles "Python312\python.exe"),
        (Join-Path $env:ProgramFiles "Python311\python.exe"),
        (Join-Path $env:ProgramFiles "Python310\python.exe"),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "Python312\python.exe" }),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "Python311\python.exe" }),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "Python310\python.exe" })
    )) {
        Add-PythonCandidate $candidates $candidate
    }

    $compatible = @()
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        $runtime = Get-PythonRuntimeInfo -Path $candidate
        if ($runtime) { $compatible += $runtime }
    }

    # Prefer the newest tested-compatible interpreter (3.12, then 3.11, then 3.10).
    return $compatible | Sort-Object Version -Descending | Select-Object -First 1
}

function Install-ManagedPythonFallback {
    $version = $managedPythonFallbackVersion
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($arch) {
        "ARM64" { $fileName = "python-$version-arm64.exe"; break }
        "AMD64" { $fileName = "python-$version-amd64.exe"; break }
        "x86" { $fileName = "python-$version.exe"; break }
        default { throw "Unsupported Windows architecture for automatic Python install: $arch" }
    }

    if (Test-Path -LiteralPath $managedPythonFallbackExe) {
        $existingRuntime = Get-PythonRuntimeInfo -Path $managedPythonFallbackExe -RequireVenv
        if ($existingRuntime) {
            Write-Host "Using existing managed Python $($existingRuntime.Version): $managedPythonFallbackExe" -ForegroundColor Green
            return $managedPythonFallbackExe
        }
        Write-Warning "Managed Python exists but failed version/runtime/pip/venv validation; only this invalid managed runtime will be replaced: $managedPythonFallbackExe"
    }

    if (Test-Path -LiteralPath $managedPythonFallbackDir) {
        Remove-Item -LiteralPath $managedPythonFallbackDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $managedPythonFallbackDir -Parent) | Out-Null

    $url = "https://www.python.org/ftp/python/$version/$fileName"
    $installerPath = Join-Path $env:TEMP $fileName
    $logPath = "$installerPath.log"
    Write-Host "Downloading isolated Python $version fallback from python.org..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $url -OutFile $installerPath -UseBasicParsing

    $signature = Get-AuthenticodeSignature -LiteralPath $installerPath
    if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -notmatch "Python Software Foundation") {
        throw "Downloaded Python installer failed Authenticode validation. Status=$($signature.Status); Signer=$($signature.SignerCertificate.Subject)"
    }

    Write-Host "Installing isolated Python $version fallback into: $managedPythonFallbackDir" -ForegroundColor Cyan
    $arguments = @(
        "/quiet",
        "InstallAllUsers=0",
        "TargetDir=`"$managedPythonFallbackDir`"",
        "PrependPath=0",
        "AppendPath=0",
        "Include_pip=1",
        "Include_launcher=0",
        "InstallLauncherAllUsers=0",
        "AssociateFiles=0",
        "Shortcuts=0",
        "Include_test=0",
        "/log",
        "`"$logPath`""
    )
    $process = Start-Process -FilePath $installerPath -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "Official Python $version fallback installer failed with exit code $($process.ExitCode). Log: $logPath"
    }

    if (Test-Path -LiteralPath $managedPythonFallbackExe) {
        $installedRuntime = Get-PythonRuntimeInfo -Path $managedPythonFallbackExe -RequireVenv
        if ($installedRuntime) {
            Write-Host "Verified isolated Python $($installedRuntime.Version): $managedPythonFallbackExe" -ForegroundColor Green
            return $managedPythonFallbackExe
        }
    }

    # If the same minor version was already registered elsewhere, the traditional installer may enter Modify mode.
    # In that case, accept a now-discoverable compatible interpreter rather than pretending TargetDir moved it.
    $python = Get-CompatiblePython
    if ($python) {
        Write-Host "Using compatible Python $($python.Version) discovered after fallback install: $($python.Path)" -ForegroundColor Green
        return [string]$python.Path
    }

    throw "Python fallback installation returned success but no usable Python >=3.10,<3.13 was found. Log: $logPath"
}

function Require-CompatiblePython {
    $python = Get-CompatiblePython
    if ($python) {
        Write-Host "Using Python $($python.Version): $($python.Path)" -ForegroundColor Green
        return [string]$python.Path
    }

    Write-Host "No usable Python 3.10-3.12 was found. Trying the normal Python 3.12 package first..." -ForegroundColor Yellow
    [void](Try-InstallWingetPackage "Python.Python.3.12" "Python 3.12")

    $python = Get-CompatiblePython
    if ($python) {
        Write-Host "Using Python $($python.Version): $($python.Path)" -ForegroundColor Green
        return [string]$python.Path
    }

    Write-Warning "Python 3.12 is still unavailable. The traditional 3.12 installer cannot relocate an already-registered 3.12 during Modify mode. Using isolated Python 3.11.9 under InstallRoot instead."
    return [string](Install-ManagedPythonFallback)
}

function Invoke-Checked([scriptblock]$command, [string]$message) {
    & $command
    if ($LASTEXITCODE -ne 0) { throw $message }
}

function Test-NodeNpmPreflight([string]$NodePath, [string]$NpmPath) {
    $nodeVersionText = (& $NodePath -p "process.versions.node" 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or -not $nodeVersionText) { throw "Node preflight failed: node --version could not run." }
    $nodeVersion = [version](([string]$nodeVersionText).Trim())
    $npmVersion = (& $NpmPath --version 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or -not $npmVersion) { throw "Node/npm preflight failed: npm --version could not run." }
    if (($IsWindows -or $env:OS -eq "Windows_NT") -and $nodeVersion -ge [version]"24.0") {
        $env:NODE_USE_SYSTEM_CA = "1"
        Write-Host "Node/npm preflight: NODE_USE_SYSTEM_CA=1 enabled for this installer process." -ForegroundColor Cyan
    }
    $strictSsl = (& $NpmPath config get strict-ssl 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0) { throw "Node/npm preflight failed: npm config could not be read." }
    if (([string]$strictSsl).Trim().ToLowerInvariant() -eq "false") {
        Write-Warning "npm strict-ssl is already disabled outside this installer. The installer will not use or persist an insecure TLS bypass; restore strict-ssl=true after correcting the local npm configuration."
    }
    $pingOutput = (& $NpmPath ping --registry=https://registry.npmjs.org/ 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        if ($pingOutput -match "SELF_SIGNED_CERT_IN_CHAIN|self signed certificate|certificate") {
            throw "Node/npm TLS preflight failed against registry.npmjs.org. On corporate Windows networks use a supported Node version with Windows system CA trust (NODE_USE_SYSTEM_CA=1) or install the corporate root CA; strict-ssl=false is not used as a permanent workaround."
        }
        throw "Node/npm connectivity preflight failed against registry.npmjs.org: $($pingOutput.Trim())"
    }
    Write-Host "Node/npm preflight passed: Node $nodeVersionText, npm $npmVersion." -ForegroundColor Green
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
Test-NodeNpmPreflight -NodePath $node -NpmPath $npm
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
Write-Host "For a complete fresh/existing auto-detected setup with validated capability choices, use scripts\windows\detect-and-apply-tested-stack.ps1 from codex/devspace-v1.0.4-watchdog-fix."
Write-Host "Configure this machine next (choose its own URL, roots, token, and task settings):"
Write-Host "  powershell.exe -ExecutionPolicy Bypass -File `"$devSpaceDir\scripts\windows\install-devspace-watchdog.ps1`" -Components DevSpace,Hermes -HermesDir `"$hermesDir`" -CliPath `"$devSpaceDir\dist\cli.js`" -SkipNpmInstall -SkipHermesInstall -PublicBaseUrl `"https://THIS-MACHINE.example.com`" -AllowedRoots `"C:\path\to\approved\workspaces`" -InstallTools"
