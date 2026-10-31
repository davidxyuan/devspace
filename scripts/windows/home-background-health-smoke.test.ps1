[CmdletBinding()]
param(
    [string]$CorePath = "$env:USERPROFILE\.devspace\watchdog-control-core.ps1",
    [string]$ConfigPath = "$env:USERPROFILE\.devspace\devspace-watchdog.config.json"
)
$ErrorActionPreference='Stop'
$scriptText=@'
param($CorePath,$ConfigPath)
$ErrorActionPreference='Stop'
. $CorePath
$all=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
Write-Output "CIM_COUNT=$($all.Count)"
Write-Output "NODE_COUNT=$(@($all | Where-Object Name -eq 'node.exe').Count)"
$h=Get-WatchdogHealthSnapshot -ConfigPath $ConfigPath
foreach($svc in @('devspace','hermes','router','ngrok')){
  $v=$h.services.$svc
  Write-Output "$svc process=$($v.processFound) pid=$($v.pid) uncertain=$($v.transportReachableWithoutOwner)"
}
'@
$p=[PowerShell]::Create()
try{
 [void]$p.AddScript($scriptText).AddArgument($CorePath).AddArgument($ConfigPath)
 $async=$p.BeginInvoke()
 if(-not $async.AsyncWaitHandle.WaitOne(20000)) { Write-Output 'ASYNC_TIMEOUT'; exit 9 }
 $output=$p.EndInvoke($async)
 foreach($item in $output){[string]$item}
 if($p.Streams.Error.Count){
  foreach($errorItem in $p.Streams.Error){Write-Output ("RUNSPACE_ERROR: "+$errorItem.ToString())}
  exit 3
 }
}finally{$p.Dispose()}
