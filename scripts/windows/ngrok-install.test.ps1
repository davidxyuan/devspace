$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "ngrok-install.ps1")

function Assert-Equal([string]$name, $actual, $expected) {
    if ($actual -ne $expected) {
        throw "$name failed.`nExpected: $expected`nActual:   $actual"
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("devspace-ngrok-test-" + [Guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

    $oldNgrok = Join-Path $tempRoot "old-ngrok.cmd"
    @"
@echo off
if "%1"=="http" (
  echo Usage: ngrok http [address:port ^| port]
  echo   --hostname string
  exit /b 0
)
if "%1"=="version" echo ngrok version 3.3.1
"@ | Set-Content -LiteralPath $oldNgrok -Encoding ASCII

    $newNgrok = Join-Path $tempRoot "new-ngrok.cmd"
    @"
@echo off
if "%1"=="http" (
  echo Usage: ngrok http [address:port ^| port]
  echo   --url string
  echo   --binding string
  echo   --web-addr string
  exit /b 0
)
if "%1"=="version" echo ngrok version 3.39.2
"@ | Set-Content -LiteralPath $newNgrok -Encoding ASCII

    $noWebAddrNgrok = Join-Path $tempRoot "no-web-addr-ngrok.cmd"
    @"
@echo off
if "%1"=="http" (
  echo Usage: ngrok http [address:port ^| port]
  echo   --url string
  echo   --binding string
  exit /b 0
)
if "%1"=="version" echo ngrok version 3.39.8
"@ | Set-Content -LiteralPath $noWebAddrNgrok -Encoding ASCII

    Assert-Equal "old ngrok rejected" (Test-NgrokEndpointFlagSupport $oldNgrok) $false
    Assert-Equal "new ngrok accepted" (Test-NgrokEndpointFlagSupport $newNgrok) $true
    Assert-Equal "endpoint flags do not require web addr" (Test-NgrokEndpointFlagSupport $noWebAddrNgrok) $true
    Assert-Equal "web addr detected" (Test-NgrokWebAddrSupport $newNgrok) $true
    Assert-Equal "missing web addr detected" (Test-NgrokWebAddrSupport $noWebAddrNgrok) $false
    Assert-Equal "version parsed" (Get-NgrokVersionSlug $newNgrok) "3.39.2"
    Assert-Equal "official stable URL" $script:NgrokStableDownloadUrl "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip"
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "ngrok install tests passed."
