# Loaded by the Watchdog Host. Slow discovery/network work stays in a disposable runspace.
$script:componentProxies = New-Object System.Collections.ArrayList
$script:stackInstallDir = Split-Path $ConfigPath -Parent
$script:managementDirectory = Join-Path $script:stackInstallDir 'stack-management'

function Get-CachedStackInventory {
    $path = Join-Path $script:managementDirectory 'inventory.json'
    try { return Read-WatchdogJson $path } catch { return [pscustomobject]@{schemaVersion=1;revision='';components=@();blockers=@();checkedAt=$null} }
}
function Get-CachedStackJob {
    try {
        $active = Read-WatchdogJson (Join-Path $script:managementDirectory 'active.json')
        if ([string]$active.id -notmatch '^[a-f0-9]{24}$') { return $null }
        $job = Read-WatchdogJson (Join-Path $script:managementDirectory "jobs\$($active.id).json")
        if ($job.phase -notin @('completed','failed')) { return $job }
    } catch { }
    return $null
}
function Start-StackManagementProxy($Request) {
    if ($script:componentProxies.Count -ge 4) { Write-ControlJson $Request.stream 409 @{error='Component requests are busy. Try again shortly.'}; return $false }
    $node = [string]$script:config.nodePath
    $managementRoot = [string](Get-WatchdogProperty $script:config 'managementPackageRoot' '')
    if (-not $managementRoot) { $managementRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path ([string]$script:config.cliPath) -Parent) '..')) }
    $setup = Join-Path $managementRoot 'scripts\windows\devspace-stack-setup.cjs'
    $worker = [PowerShell]::Create()
    $code = @'
param($InstallDir,$NodePath,$SetupPath,$Method,$Route,$Body)
$ErrorActionPreference='Stop'
try {
    $endpointPath=Join-Path $InstallDir 'stack-management\endpoint.json'
    $launched=$false
    for($attempt=0;$attempt -lt 2;$attempt++) {
        try {
            $endpoint=[IO.File]::ReadAllText($endpointPath)|ConvertFrom-Json
            if ([IO.Path]::GetFullPath([string]$endpoint.installDir) -ine [IO.Path]::GetFullPath($InstallDir) -or [int]$endpoint.port -lt 1024 -or [int]$endpoint.port -gt 65535) { throw 'Manager identity mismatch.' }
            $origin='http://127.0.0.1:'+ [int]$endpoint.port
            $headers=@{'x-devspace-setup-token'=[string]$endpoint.token;Origin=$origin}
            $identity=Invoke-RestMethod -Uri ($origin+'/api/status') -TimeoutSec 3
            $expectedRoot=[IO.Path]::GetFullPath((Join-Path (Split-Path $SetupPath -Parent) '..\..'))
            if ([IO.Path]::GetFullPath([string]$identity.installDir) -ine [IO.Path]::GetFullPath($InstallDir) -or [IO.Path]::GetFullPath([string]$identity.packageRoot) -ine $expectedRoot) { throw 'Connected manager belongs to another installation or package.' }
            $response=Invoke-WebRequest -UseBasicParsing -Uri ($origin+$Route) -Method $Method -Headers $headers -ContentType 'application/json' -Body $(if($Method -eq 'POST'){$Body}else{$null}) -TimeoutSec 8
            @{status=[int]$response.StatusCode;body=[string]$response.Content}|ConvertTo-Json -Compress
            return
        } catch {
            if ($_.Exception.Response) {
                $stream=$_.Exception.Response.GetResponseStream()
                $reader=New-Object IO.StreamReader($stream)
                try { @{status=[int]$_.Exception.Response.StatusCode;body=$reader.ReadToEnd()}|ConvertTo-Json -Compress } finally {$reader.Dispose()}
                return
            }
            if($launched){throw}
            if(-not [IO.File]::Exists($NodePath) -or -not [IO.File]::Exists($SetupPath)){throw 'Management scripts are missing. Run the one-click installer to repair them.'}
            foreach($value in @($SetupPath,$InstallDir)){if($value.Contains('"') -or $value.Contains("`n")){throw 'Invalid manager path.'}}
            $psi=New-Object Diagnostics.ProcessStartInfo
            $psi.FileName=$NodePath;$psi.Arguments='"'+$SetupPath+'" --no-open --install-dir "'+$InstallDir.TrimEnd('\')+'"'
            $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WindowStyle='Hidden'
            $started=[Diagnostics.Process]::Start($psi)
            try {
                $deadline=[DateTimeOffset]::UtcNow.AddSeconds(6)
                do {
                    Start-Sleep -Milliseconds 100
                    try {$updated=[IO.File]::ReadAllText($endpointPath)|ConvertFrom-Json;if([int]$updated.pid -eq $started.Id){break}}catch{}
                }while([DateTimeOffset]::UtcNow -lt $deadline -and -not $started.HasExited)
            } finally {$started.Dispose()}
            $launched=$true
        }
    }
} catch {@{status=503;body=(@{error=$_.Exception.Message}|ConvertTo-Json -Compress)}|ConvertTo-Json -Compress}
'@
    [void]$worker.AddScript($code).AddArgument($script:stackInstallDir).AddArgument($node).AddArgument($setup).AddArgument($Request.method).AddArgument($Request.path).AddArgument($Request.body)
    $async = $worker.BeginInvoke()
    [void]$script:componentProxies.Add([pscustomobject]@{worker=$worker;async=$async;client=$Request.client})
    return $true
}
function Complete-StackManagementProxies {
    foreach ($proxy in @($script:componentProxies.ToArray())) {
        if (-not $proxy.async.IsCompleted) { continue }
        try {
            $result = (($proxy.worker.EndInvoke($proxy.async) | ForEach-Object {[string]$_}) -join '') | ConvertFrom-Json
            Write-LoopbackHttpResponse $proxy.client.GetStream() ([int]$result.status) 'application/json; charset=utf-8' ([string]$result.body)
        } catch { try {Write-ControlJson $proxy.client.GetStream() 503 @{error='Management connection interrupted; check the job before retrying.'}}catch{} }
        finally {$proxy.client.Dispose();$proxy.worker.Dispose();[void]$script:componentProxies.Remove($proxy)}
    }
}
