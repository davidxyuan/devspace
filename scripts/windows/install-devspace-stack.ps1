[CmdletBinding()]
param([string]$InstallDir = "$env:USERPROFILE\.devspace", [switch]$InspectOnly, [switch]$NoOpen)
$ErrorActionPreference = 'Stop'
# Node/npm may inherit another PowerShell edition's module path.
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -Force

function Test-StackNode([string]$Path) {
    if (-not $Path -or -not [IO.File]::Exists($Path)) { return $false }
    try {
        $versionOutput = @(& $Path --version 2>$null)
        $versionExitCode = $LASTEXITCODE
        $versionText = [string]($versionOutput | Select-Object -First 1)
        if ($versionExitCode -ne 0 -or $versionText -notmatch '^v(\d+)\.(\d+)\.(\d+)$') { return $false }
        $version = [version]$versionText.TrimStart('v')
        return $version -ge [version]'22.19.0' -and $version -lt [version]'27.0.0'
    } catch { return $false }
}
function Find-StackNode([string]$InstallDir) {
    $candidates = @()
    $watchdog = Join-Path $InstallDir 'devspace-watchdog.config.json'
    if ([IO.File]::Exists($watchdog)) {
        # Invalid existing configuration remains an error, not a fresh-machine signal.
        $config = [IO.File]::ReadAllText($watchdog) | ConvertFrom-Json
        $candidates += [string]$config.nodePath
    }
    $candidates += @(Get-Command node.exe -All -ErrorAction SilentlyContinue | ForEach-Object {$_.Source})
    $candidates += @((Join-Path $env:ProgramFiles 'nodejs\node.exe'), (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'))
    foreach ($candidate in $candidates | Select-Object -Unique) { if (Test-StackNode $candidate) { return $candidate } }
    return $null
}
function Assert-StackPlainPath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Package path contains a junction or symbolic link: $current" }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

$node = Find-StackNode $InstallDir
$winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($InspectOnly) {
    @{nodePath=$node;nodeCompatible=[bool]$node;wingetAvailable=[bool]$winget;installDir=[IO.Path]::GetFullPath($InstallDir)} | ConvertTo-Json -Compress
    exit 0
}
if (-not $node) {
    if (-not $winget) { throw 'Node.js >=22.19 and <27 is required. Windows App Installer (winget) is missing; install Node.js LTS from https://nodejs.org/ then double-click this installer again.' }
    Write-Host 'Installing missing Node.js LTS...'
    & $winget.Source install --id OpenJS.NodeJS.LTS --exact --source winget --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) { throw 'Node.js installation did not finish. Complete the Windows installer prompt and run this installer again.' }
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine')+';'+[Environment]::GetEnvironmentVariable('PATH','User')
    $node = Find-StackNode $InstallDir
    if (-not $node) { throw 'A compatible Node.js runtime was not found after installation. Reopen this installer after Node.js setup completes.' }
}

$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$manifestPath = Join-Path $packageRoot 'oneclick-payload.json'
if ([IO.File]::Exists($manifestPath)) {
    Assert-StackPlainPath $manifestPath
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ([string]$manifest.fingerprint -notmatch '^[a-f0-9]{64}$') { throw 'Invalid one-click package fingerprint.' }
    $canonical = ($manifest.files | ForEach-Object {$_.path+':'+$_.sha256}) -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actualFingerprint = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    if ($actualFingerprint -cne $manifest.fingerprint) { throw 'One-click manifest integrity check failed.' }
    $destination = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA ('DevSpaceStack\packages\'+$manifest.fingerprint)))
    $verifiedFiles = @()
    foreach ($entry in $manifest.files) {
        $source = [IO.Path]::GetFullPath((Join-Path $packageRoot ([string]$entry.path)))
        $target = [IO.Path]::GetFullPath((Join-Path $destination ([string]$entry.path)))
        if (-not $source.StartsWith($packageRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or -not $target.StartsWith($destination.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid package file path.' }
        Assert-StackPlainPath $source
        Assert-StackPlainPath $target
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ine $entry.sha256) { throw "Package file failed integrity check: $($entry.path)" }
        if ([IO.File]::Exists($target)) {
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $entry.sha256) { throw "Existing managed package was modified: $target. Preserve it and use a new package." }
        }
        $verifiedFiles += [pscustomobject]@{source=$source;target=$target}
    }
    foreach ($file in $verifiedFiles) {
        if ([IO.File]::Exists($file.target)) { continue }
        [void][IO.Directory]::CreateDirectory((Split-Path $file.target -Parent))
        [IO.File]::Copy($file.source,$file.target,$false)
    }
    [IO.File]::WriteAllText((Join-Path $destination 'oneclick-payload.json'),[IO.File]::ReadAllText($manifestPath))
    $packageRoot = $destination
}
$setup = Join-Path $packageRoot 'scripts\windows\devspace-stack-setup.cjs'
$arguments = @($setup,'--install-dir',[IO.Path]::GetFullPath($InstallDir))
if ($NoOpen) { $arguments += '--no-open' }
Write-Host 'Starting DevSpace Stack Setup. Existing settings will be detected automatically.'
& $node @arguments
exit $LASTEXITCODE
