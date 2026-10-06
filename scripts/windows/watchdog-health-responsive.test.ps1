[CmdletBinding()]
param([string]$SourceDirectory)
$ErrorActionPreference = 'Stop'
if (-not $SourceDirectory) { $SourceDirectory = $PSScriptRoot }
. (Join-Path $PSScriptRoot 'watchdog-control-core.ps1')
function Assert-True([string]$Name, [bool]$Value) { if (-not $Value) { throw "$Name failed." } }
function Read-Ast([string]$Name) {
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceDirectory $Name), [ref]$null, [ref]$errors)
    if ($errors.Count) { throw $errors[0].Message }
    return $ast
}
$ast = Read-Ast 'devspace-watchdog-tray.ps1'
foreach ($name in @('Start-HealthRunspace','Stop-HealthRunspace','Update-HealthRunspace','Complete-HealthRunspace',
    'Get-OverallTrayState','Write-ControlHeartbeat','Read-LoopbackHttpRequest','Write-LoopbackHttpResponse',
    'Write-ControlJson','Invoke-ControlHttpRequest','Invoke-PendingDashboardRequest','Assert-ControlMutationAvailable',
    'Start-AutomaticRecovery','Complete-AutomaticRecovery','Complete-ControlNgrokSwitch','Wait-ControlMutationDrain')) {
    $fn = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if ($fn) { Invoke-Expression $fn.Extent.Text }
}
$hostBranch = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$Mode -eq "Host"' })[0]
$loop = $hostBranch.Find({param($n) $n -is [Management.Automation.Language.WhileStatementAst]}, $true)
Assert-True 'production Host loop located' ($null -ne $loop)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('devspace-health-responsive-' + [guid]::NewGuid().ToString('N'))
$gateName = 'Local\DevSpaceHealthFixture-' + [guid]::NewGuid().ToString('N')
$stopName = $gateName + '-stop'
$gate = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $gateName)
$entered = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, ($gateName+'-entered'))
$stopEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, $stopName)
$clientWorker = $null
$script:listener = $null
try {
    [void][IO.Directory]::CreateDirectory($tempRoot)
    $corePath = Join-Path $tempRoot 'fixture-core.ps1'
    $ConfigPath = Join-Path $tempRoot 'config.json'
    [IO.File]::WriteAllText($ConfigPath, $gateName)
    [IO.File]::WriteAllText($corePath, @'
function Get-WatchdogHealthSnapshot($ConfigPath, [switch]$IncludePublic) {
    $name = [IO.File]::ReadAllText($ConfigPath)
    $gate = [Threading.EventWaitHandle]::OpenExisting($name)
    $entered = [Threading.EventWaitHandle]::OpenExisting($name+'-entered')
    try { [void]$entered.Set(); [void]$gate.WaitOne(25000); return @{fixture='completed'} }
    finally { $entered.Dispose(); $gate.Dispose() }
}
function Read-WatchdogJson($Path) { return @{} }
function Protect-WatchdogText($Text) { return $Text }
function Invoke-WatchdogServiceRecovery($Service,$Path,$Config,$Health) {
    [void](Get-WatchdogHealthSnapshot $Path)
    return @{success=$true;error=''}
}
'@)
    $script:settings = [pscustomobject]@{dashboardPort=0;localProbeSeconds=999999}
    $script:listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $script:listener.Start()
    $script:settings.dashboardPort = $script:listener.LocalEndpoint.Port
    $script:stateDir=$tempRoot; $script:statePath=Join-Path $tempRoot 'state.json'
    $script:heartbeatPath=Join-Path $tempRoot 'heartbeat.json'
    $script:config=@{}; $script:state=[pscustomobject]@{maintenanceMode=$false}
    $script:lastHealth=$null; $script:dashboardHtml='fixture dashboard'
    $script:lastHeartbeat=[DateTimeOffset]::MinValue
    $script:healthAsync=$null; $script:healthPowerShell=$null; $script:healthStopAsync=$null
    $script:healthStopping=$false; $script:healthProbeTimedOut=$false
    $script:mutationAsync=$null; $script:mutationInProgress=$false; $script:shutdownRequested=$false
    $script:applied=0; $script:events=@(); $isHostMode=$true
    function Apply-HealthSnapshot($Snapshot) { $script:applied++ }
    function Write-WatchdogEvent($Dir,$Config,$Service,$Event,$Cause,$Action,$Result) { $script:events += [pscustomobject]@{event=$Event;cause=$Cause} }
    function Test-PublicProbeDue { return $false }
    function Complete-StackManagementProxies {}
    function Get-ControlStatusPayload { return @{overall=(Get-OverallTrayState)} }
    Start-HealthRunspace
    Assert-True 'probe entered a non-interruptible native wait' ($entered.WaitOne(5000))
    $originalWorker=$script:healthPowerShell
    Start-HealthRunspace
    Assert-True 'only one probe may run' ([object]::ReferenceEquals($originalWorker,$script:healthPowerShell))
    $script:lastHealthStarted=[DateTimeOffset]::UtcNow.AddSeconds(-46)
    $clientBody = {
        param($Port,$HeartbeatPath,$GateName,$StopName)
        $gate=[Threading.EventWaitHandle]::OpenExisting($GateName)
        $stop=[Threading.EventWaitHandle]::OpenExisting($StopName)
        $watch=[Diagnostics.Stopwatch]::StartNew(); $ok=0; $failed=0; $maxAge=0; $delayed=0
        try {
            while ($watch.Elapsed.TotalSeconds -lt 16) {
                try {
                    $status=Invoke-RestMethod "http://127.0.0.1:$Port/api/status" -TimeoutSec 1
                    if ($status.overall.label -eq 'Health check delayed') { $delayed++ }
                    $page=Invoke-WebRequest "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 1
                    if ($page.StatusCode -eq 200) { $ok++ }
                    $hb=[IO.File]::ReadAllText($HeartbeatPath) | ConvertFrom-Json
                    $maxAge=[Math]::Max($maxAge,([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse($hb.timestamp)).TotalSeconds)
                } catch { $failed++ }
                Start-Sleep -Milliseconds 100
            }
            [pscustomobject]@{ok=$ok;failed=$failed;maxAge=$maxAge;delayed=$delayed}
        } finally { [void]$gate.Set(); [void]$stop.Set(); $gate.Dispose(); $stop.Dispose() }
    }
    $clientWorker=[PowerShell]::Create()
    [void]$clientWorker.AddScript($clientBody.ToString()).AddArgument($script:settings.dashboardPort).AddArgument($script:heartbeatPath).AddArgument($gateName).AddArgument($stopName)
    $clientAsync=$clientWorker.BeginInvoke()
    Invoke-Expression $loop.Extent.Text
    $result=@($clientWorker.EndInvoke($clientAsync))[0]
    Assert-True 'real Dashboard GETs continue during cancellation beyond 15 seconds' ($result.ok -ge 20 -and $result.failed -eq 0)
    Assert-True 'real heartbeat remains fresh' ($result.maxAge -lt 6)
    Assert-True 'Dashboard reports delayed evidence honestly' ($result.delayed -ge 20)
    $script:shutdownRequested=$false
    while ($script:healthAsync) { Complete-HealthRunspace; [Threading.Thread]::Sleep(20) }
    Assert-True 'cancelled result never applied and references released' ($script:applied -eq 0 -and -not $script:healthPowerShell -and -not $script:healthStopAsync)
    Assert-True 'timeout logged once' (@($script:events | Where-Object event -eq health_cycle_timeout).Count -eq 1)
    Start-HealthRunspace
    while ($script:healthAsync) { Complete-HealthRunspace; [Threading.Thread]::Sleep(20) }
    Assert-True 'next successful check clears delayed status' ($script:applied -eq 1 -and -not $script:healthProbeTimedOut)

    [void]$gate.Reset(); [void]$entered.Reset()
    Start-HealthRunspace
    Assert-True 'mutation fixture entered' ($entered.WaitOne(5000))
    $watch=[Diagnostics.Stopwatch]::StartNew(); $rejected=$false
    try { Stop-HealthRunspace -ForMutation } catch { $rejected=$_.Exception.Message -match 'Health check is stopping' }
    Assert-True 'pending cancellation rejects mutation without blocking' ($rejected -and $watch.Elapsed.TotalSeconds -lt 1 -and -not $script:mutationInProgress)
    $originalWorker=$script:healthPowerShell
    Start-HealthRunspace
    Assert-True 'cancellation cannot orphan or overlap worker' ([object]::ReferenceEquals($originalWorker,$script:healthPowerShell))
    [void]$gate.Set()
    while ($script:healthAsync) { Complete-HealthRunspace; [Threading.Thread]::Sleep(20) }

    function Complete-WatchdogRecoveryAttempt($State,$Service,$Result) { $script:recovered=$Result.success }
    function Save-WatchdogState {}
    function Request-ImmediatePublicProbe($Reason) { $script:publicReason=$Reason }
    [void]$gate.Reset(); [void]$entered.Reset()
    Start-AutomaticRecovery 'devspace' @{} ([pscustomobject]@{reason='fixture';record=@{attemptCount=1}})
    Assert-True 'automatic recovery runs in background' ($entered.WaitOne(5000) -and $script:mutationInProgress -and -not $script:mutationAsync.IsCompleted)
    Write-ControlHeartbeat -Force
    Assert-True 'recovery heartbeat protects transaction' ((Read-WatchdogJson $script:heartbeatPath).mutationInProgress)
    $clientWorker.Dispose()
    $clientWorker=[PowerShell]::Create()
    [void]$clientWorker.AddScript($clientBody.ToString()).AddArgument($script:settings.dashboardPort).AddArgument($script:heartbeatPath).AddArgument($gateName).AddArgument($stopName)
    $clientAsync=$clientWorker.BeginInvoke()
    Invoke-Expression $loop.Extent.Text
    $recoveryResult=@($clientWorker.EndInvoke($clientAsync))[0]
    Assert-True 'real Dashboard and heartbeat continue throughout background recovery' ($recoveryResult.ok -ge 20 -and $recoveryResult.failed -eq 0 -and $recoveryResult.maxAge -lt 6)
    Wait-ControlMutationDrain
    Assert-True 'recovery drains and releases ownership' ($script:recovered -and -not $script:mutationAsync -and -not $script:mutationInProgress -and -not (Test-StackOperationBusy $tempRoot))
    Assert-True 'completed recovery requests fresh public evidence' ($script:publicReason -eq 'recovery:devspace')
    Write-Host "Host responsiveness passed: $($result.ok) real HTTP rounds while cancellation pending, $($recoveryResult.ok) during recovery; maximum heartbeat ages $([Math]::Round($result.maxAge,2))s/$([Math]::Round($recoveryResult.maxAge,2))s; no overlapping probes; recovery drained."
} finally {
    [void]$gate.Set(); [void]$stopEvent.Set()
    if ($clientWorker) { $clientWorker.Stop(); $clientWorker.Dispose() }
    if ($script:healthPowerShell) { $script:healthPowerShell.Stop(); $script:healthPowerShell.Dispose() }
    if ($script:mutationPowerShell) { $script:mutationPowerShell.Stop(); $script:mutationPowerShell.Dispose() }
    if ($script:listener) { $script:listener.Stop() }
    $gate.Dispose(); $entered.Dispose(); $stopEvent.Dispose()
    $resolved=[IO.Path]::GetFullPath($tempRoot)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('devspace-health-responsive-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
