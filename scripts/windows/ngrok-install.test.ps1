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
  echo   --log string
  exit /b 0
)
if "%1"=="version" echo ngrok version 3.39.11
"@ | Set-Content -LiteralPath $newNgrok -Encoding ASCII

    $urlOnlyNgrok = Join-Path $tempRoot "url-only-ngrok.cmd"
    @"
@echo off
if "%1"=="http" (
  echo   --url string
  echo   --log string
  exit /b 0
)
if "%1"=="version" echo ngrok version 3.39.11
"@ | Set-Content -LiteralPath $urlOnlyNgrok -Encoding ASCII

    Assert-Equal "old ngrok rejected" (Test-NgrokEndpointFlagSupport $oldNgrok) $false
    Assert-Equal "ngrok 3.39 accepted without web-addr" (Test-NgrokEndpointFlagSupport $newNgrok) $true
    Assert-Equal "url-only accepted when binding not required" (Test-NgrokEndpointFlagSupport $urlOnlyNgrok) $true
    Assert-Equal "url-only rejected when binding required" (Test-NgrokEndpointFlagSupport $urlOnlyNgrok -RequireBinding) $false
    Assert-Equal "binding-capable ngrok accepted when required" (Test-NgrokEndpointFlagSupport $newNgrok -RequireBinding) $true
    Assert-Equal "version parsed" (Get-NgrokVersionSlug $newNgrok) "3.39.11"
    Assert-Equal "official stable URL" $script:NgrokStableDownloadUrl "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip"
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "ngrok install tests passed."
