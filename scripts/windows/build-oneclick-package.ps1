[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -Force
$packageRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $packageRoot 'releases' }
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$stage=Join-Path ([IO.Path]::GetTempPath()) ('devspace-oneclick-package-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($stage)
Push-Location $packageRoot
try {
    $packed = (& npm.cmd pack --ignore-scripts --json --pack-destination $stage | Out-String) | ConvertFrom-Json
    if($LASTEXITCODE -ne 0){throw 'npm pack failed.'}
    $archive=Join-Path $stage ([string]$packed[0].filename)
    & tar.exe -xf $archive -C $stage
    if($LASTEXITCODE -ne 0){throw 'Package extraction failed.'}
    $payload=Join-Path $stage 'package'
    Copy-Item -LiteralPath (Join-Path $packageRoot 'package-lock.json') -Destination $payload
    $files=@(Get-ChildItem -LiteralPath $payload -File -Recurse | Sort-Object FullName | ForEach-Object {
        @{path=$_.FullName.Substring($payload.Length+1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    $canonical=($files | ForEach-Object {$_.path+':'+$_.sha256}) -join "`n"
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$fingerprint=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $head=(& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify package source HEAD.' }
    $dirty=[bool]((& git status --porcelain --untracked-files=all | Out-String).Trim())
    if ($LASTEXITCODE -ne 0) { throw 'Cannot verify package source worktree.' }
    $branch=(& git branch --show-current | Out-String).Trim()
    $remoteName=if ($branch) { (& git config --get "branch.$branch.remote" | Out-String).Trim() } else { '' }
    $trackingRef=if ($remoteName -and $remoteName -ne '.') { (& git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' | Out-String).Trim() } else { '' }
    $remoteUrl=(& git remote get-url $(if ($remoteName -and $remoteName -ne '.') { $remoteName } else { 'origin' }) | Out-String).Trim()
    $repository=if ($remoteUrl -match '^(?:https://github\.com/|git@github\.com:)([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+?)(?:\.git)?/?$') { $Matches[1] } else { '' }
    $provenance=@('workspace',$head,$repository,$branch,$trackingRef,$remoteName,$dirty.ToString().ToLowerInvariant(),$fingerprint) -join "`n"
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$provenanceFingerprint=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($provenance))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    @{schemaVersion=1;fingerprint=$fingerprint;source='workspace';head=$head;repository=$repository;branch=$branch;trackingRef=$trackingRef;remoteName=$remoteName;dirty=$dirty;provenanceFingerprint=$provenanceFingerprint;createdAt=[DateTimeOffset]::UtcNow.ToString('o');files=$files} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $payload 'oneclick-payload.json') -Encoding UTF8
    $launcher='@echo off'+"`r`n"+'call "%~dp0package\scripts\windows\install-devspace-stack.cmd" %*'+"`r`n"
    [IO.File]::WriteAllText((Join-Path $stage 'Install-DevSpace.cmd'),$launcher,[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $stage 'README.txt'),"Extract this ZIP, then double-click Install-DevSpace.cmd.`r`nExisting settings are detected automatically. New machines need an ngrok token/domain and approved folders.`r`nNode.js is reused or installed with winget; missing components are installed from Setup.`r`nNo account password is required. Internet is required for missing dependencies.`r`n",[Text.Encoding]::UTF8)
    $target=Join-Path $OutputDirectory ('DevSpace-OneClick-'+$stamp+'.zip')
    if([IO.File]::Exists($target)){throw 'Output already exists; use a new timestamp/directory.'}
    Compress-Archive -LiteralPath $payload,(Join-Path $stage 'Install-DevSpace.cmd'),(Join-Path $stage 'README.txt') -DestinationPath $target
    @{path=$target;sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash;fingerprint=$fingerprint;files=$files.Count;stage=$stage}|ConvertTo-Json -Compress
} finally {Pop-Location}
