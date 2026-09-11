$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$installer=Join-Path $root 'install-opencodex-tray-autostart.ps1'
$launcher=Join-Path $root 'opencodex-tray-launcher.cs'
$bootstrap=Join-Path $root 'devspace-watchdog-bootstrap.ps1'
foreach($p in @($installer,$launcher,$bootstrap)){if(-not (Test-Path $p)){throw "missing file: $p"}}
$installerText=Get-Content $installer -Raw
$bootstrapText=Get-Content $bootstrap -Raw
$required=@(
  'New-ScheduledTaskTrigger -AtLogOn',
  'RepetitionInterval (New-TimeSpan -Minutes 1)',
  'RestartCount 3',
  "OpenCodex Tray.lnk",
  'opencodex-tray-launcher.exe',
  'OpenCodexTrayStartTemp2',
  'MultipleInstances IgnoreNew'
)
foreach($needle in $required){if(-not $installerText.Contains($needle)){throw "installer missing expected behavior: $needle"}}
if(-not $installerText.Contains('$shortcut.Arguments = ''''')){throw 'installer does not clear stale desktop shortcut arguments'}
if(-not $bootstrapText.Contains('opencodex-tray-launcher.exe')){throw 'bootstrap repair does not prefer native launcher'}
if(-not $bootstrapText.Contains('opencodex-tray.vbs')){throw 'bootstrap repair lost VBS compatibility fallback'}
$null=[scriptblock]::Create($installerText)
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ocx-launcher-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
  $out=Join-Path $temp 'launcher.exe'
  Add-Type -Path $launcher -OutputAssembly $out -OutputType WindowsApplication -ReferencedAssemblies 'System.Web.Extensions.dll'
  if(-not (Test-Path $out)){throw 'native launcher did not compile'}
} finally {Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue}
Write-Output 'PASS: OpenCodex tray autostart source preserves native hidden launcher, logon/minute recovery, desktop shortcut, and legacy fallback.'
