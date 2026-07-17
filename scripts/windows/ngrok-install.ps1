$script:NgrokStableDownloadUrl = "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip"

function Test-NgrokEndpointFlagSupport([string]$NgrokPath) {
    if (-not $NgrokPath -or -not (Test-Path -LiteralPath $NgrokPath)) {
        return $false
    }

    try {
        $helpText = (& $NgrokPath http --help 2>&1 | Out-String)
        return $helpText -match "(?m)^\s*--url(?:\s|$)" -and $helpText -match "(?m)^\s*--binding(?:\s|$)"
    } catch {
        return $false
    }
}

function Get-NgrokVersionSlug([string]$NgrokPath) {
    try {
        $versionText = (& $NgrokPath version 2>&1 | Out-String).Trim()
        if ($versionText -match "(?<version>\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)") {
            return $Matches.version
        }
    } catch {
    }
    return "download-$(Get-Date -Format 'yyyyMMddHHmmss')"
}

function Install-LatestNgrokAgent(
    [string]$InstallRoot,
    [string]$DownloadUrl = $script:NgrokStableDownloadUrl
) {
    if (-not $InstallRoot) {
        throw "InstallRoot is required to install ngrok."
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("devspace-ngrok-" + [Guid]::NewGuid().ToString("N"))
    $zipPath = Join-Path $tempRoot "ngrok.zip"
    $extractPath = Join-Path $tempRoot "extract"

    try {
        New-Item -ItemType Directory -Force -Path $extractPath | Out-Null
        Write-Host "Downloading the latest stable ngrok agent from the official ngrok distribution..."
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $zipPath -UseBasicParsing
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

        $downloadedNgrok = Get-ChildItem -LiteralPath $extractPath -Filter "ngrok.exe" -File -Recurse |
            Select-Object -First 1
        if (-not $downloadedNgrok) {
            throw "The official ngrok archive did not contain ngrok.exe."
        }
        if (-not (Test-NgrokEndpointFlagSupport $downloadedNgrok.FullName)) {
            throw "The downloaded ngrok agent does not support the required --url and --binding flags."
        }

        $versionSlug = Get-NgrokVersionSlug $downloadedNgrok.FullName
        $targetDir = Join-Path $InstallRoot ("tools\ngrok\" + $versionSlug)
        $targetPath = Join-Path $targetDir "ngrok.exe"
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

        if (-not (Test-Path -LiteralPath $targetPath)) {
            Copy-Item -LiteralPath $downloadedNgrok.FullName -Destination $targetPath -Force
        }

        Write-Host "Latest stable ngrok ready: $targetPath"
        return [System.IO.Path]::GetFullPath($targetPath)
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
