[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$corePath = Join-Path $PSScriptRoot "watchdog-control-core.ps1"
. $corePath

function Assert-True([string]$Name, [bool]$Value) {
    if (-not $Value) { throw "$Name failed." }
}
function Assert-Equal([string]$Name, $Actual, $Expected) {
    if ($Actual -ne $Expected) { throw "$Name failed. Expected: $Expected; actual: $Actual" }
}
function Get-TestFunctionSource([string]$Path, [string]$Name) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw "Cannot parse $Path" }
    $node = $ast.Find({ param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $Name }, $true)
    if (-not $node) { throw "Missing function $Name" }
    return $node.Extent.Text
}
Invoke-Expression (Get-TestFunctionSource (Join-Path $PSScriptRoot "watchdog-control-core.test.ps1") "New-TestConfig")

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("devspace-ngrok-transaction-test-" + [Guid]::NewGuid().ToString("N"))
[void][System.IO.Directory]::CreateDirectory($testRoot)
try {
    $ConfigPath = Join-Path $testRoot "devspace-watchdog.config.json"
    . (Join-Path $PSScriptRoot 'stack-host-management.ps1')
    $script:stackMutationLease = $null
    $script:config = New-TestConfig $testRoot
    Write-WatchdogAtomicJson $ConfigPath $script:config 30
    $desired = (New-WatchdogState $script:config).desired
    $credentialPath = Get-WatchdogNgrokCredentialPath $script:config
    # This is a synthetic record, never a real ngrok credential or DPAPI operation.
    [System.IO.File]::WriteAllText($credentialPath, "old-test-record")
    $script:serviceCalls = @()
    $script:failVerification = $false
    $script:failOldRestart = $false
    $script:failOldVerification = $false
    $script:publicVerifications = 0
    function Set-WatchdogNgrokCredential($Config, [string]$Token) {
        if ($Token -ne "synthetic-token") { throw "Unexpected test token." }
        [System.IO.File]::WriteAllText((Get-WatchdogNgrokCredentialPath $Config), "new-test-record")
    }
    function Stop-WatchdogManagedService([string]$Service, $Config) {
        $script:serviceCalls += "stop:$Service"
        return [pscustomobject]@{ success=$true; error="" }
    }
    function Start-WatchdogManagedService([string]$Service, [string]$ConfigPath, $Config) {
        $path = Get-WatchdogNgrokCredentialPath $Config
        $record = if ([System.IO.File]::Exists($path)) { [System.IO.File]::ReadAllText($path) } else { "default-test-record" }
        $script:serviceCalls += "start:$Service`:$record"
        if ($script:failOldRestart -and $record -eq "old-test-record") { return [pscustomobject]@{ success=$false; error="synthetic old restart failure" } }
        return [pscustomobject]@{ success=$true; error="" }
    }
    function Get-WatchdogHealthSnapshot([string]$ConfigPath, [switch]$IncludePublic) {
        if ($IncludePublic) {
            $script:publicVerifications++
            $isOld = -not [System.IO.File]::Exists($credentialPath) -or [System.IO.File]::ReadAllText($credentialPath) -eq "old-test-record"
            if (($script:failVerification -and -not $isOld) -or ($script:failOldVerification -and $isOld)) { throw "synthetic verification failure" }
        }
        return [pscustomobject]@{
            services=[pscustomobject]@{ ngrok=[pscustomobject]@{ healthy=$true } }
            public=[pscustomobject]@{ devspace=[pscustomobject]@{ protocolHealthy=$true }; hermes=[pscustomobject]@{ protocolHealthy=$true } }
        }
    }
    function Write-WatchdogEvent { }
    function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
    $editable = Get-WatchdogEditableConfig $script:config
    $payload = [pscustomobject]@{
        confirmation="SWITCH NGROK"; authToken="synthetic-token"
        publicDomain=$editable.publicDomain; endpointMode=$editable.endpointMode; internalAgentEndpoint=$editable.internalAgentEndpoint
    }
    $result = Invoke-WatchdogNgrokAccountSwitch $ConfigPath $payload $desired
    Assert-True "token-only switch succeeds" $result.result.success
    Assert-True "token-only switch has no configuration backup" ($null -eq $result.result.backupId)
    Assert-Equal "token-only switch restarts once with new credential" ($script:serviceCalls -join ",") "stop:ngrok,start:ngrok:new-test-record"
    Assert-True "token-only switch creates no configuration backup directory" (-not [System.IO.Directory]::Exists((Get-WatchdogBackupRoot $testRoot)))

    [System.IO.File]::WriteAllText($credentialPath, "old-test-record")
    $script:serviceCalls = @()
    $script:failVerification = $true
    $errorText = ""
    try { [void](Invoke-WatchdogNgrokAccountSwitch $ConfigPath $payload $desired) } catch { $errorText = $_.Exception.Message }
    Assert-True "failed token-only switch reports rollback" ($errorText -like "*was rolled back*")
    Assert-Equal "failed token-only switch restores previous credential" ([System.IO.File]::ReadAllText($credentialPath)) "old-test-record"
    Assert-Equal "rollback restarts ngrok with restored credential" ($script:serviceCalls -join ",") "stop:ngrok,start:ngrok:new-test-record,stop:ngrok,start:ngrok:old-test-record"
    Assert-Equal "public verification only once per candidate and rollback" $script:publicVerifications 3

    $script:failOldVerification = $true
    $needsAttention = $false
    try { [void](Invoke-WatchdogNgrokAccountSwitch $ConfigPath $payload $desired) }
    catch { $needsAttention = [bool]$_.Exception.Data["WatchdogRollbackNeedsAttention"] }
    Assert-True "restored process without public proof requires attention" $needsAttention
    $script:failOldVerification = $false

    $script:failOldRestart = $true
    $needsAttention = $false
    try { [void](Invoke-WatchdogNgrokAccountSwitch $ConfigPath $payload $desired) }
    catch { $needsAttention = [bool]$_.Exception.Data["WatchdogRollbackNeedsAttention"] }
    Assert-True "partial rollback carries structural attention flag" $needsAttention
    $script:failOldRestart = $false

    $payload.publicDomain = "https://new-account.example.test"
    $script:serviceCalls = @()
    try { [void](Invoke-WatchdogNgrokAccountSwitch $ConfigPath $payload $desired) } catch { $errorText = $_.Exception.Message }
    Assert-True "domain failure reports rollback" ($errorText -like "*was rolled back*")
    Assert-Equal "domain failure restores config" (Read-WatchdogJson $ConfigPath).publicBaseUrl $script:config.publicBaseUrl
    Assert-Equal "domain failure restores credential" ([System.IO.File]::ReadAllText($credentialPath)) "old-test-record"
    Assert-True "domain failure restarts router with old credential" ($script:serviceCalls -contains "start:router:old-test-record")

    $script:failVerification = $false
    [void](Invoke-WatchdogNgrokAccountSwitch $ConfigPath $payload $desired)
    $previousPath = Join-Path $testRoot "ngrok-previous-account.json"
    $previousBytes = [System.IO.File]::ReadAllText($previousPath)
    Assert-True "recovery record never stores submitted plaintext token" (-not $previousBytes.Contains("synthetic-token"))
    $script:failOldVerification = $true; $errorText = ""
    try { [void](Invoke-WatchdogNgrokSwitch $ConfigPath ([pscustomobject]@{confirmation="RESTORE PREVIOUS NGROK"}) $desired) } catch { $errorText = $_.Exception.Message }
    Assert-True "failed restore reports failure" ($errorText -like "*was rolled back*")
    Assert-Equal "failed restore returns to current credential" ([System.IO.File]::ReadAllText($credentialPath)) "new-test-record"
    Assert-Equal "failed restore retains recovery point" ([System.IO.File]::ReadAllText($previousPath)) $previousBytes
    $script:failOldVerification = $false
    # Read from disk via the dispatcher, with no transaction-local credential available.
    $restoredAccount = Invoke-WatchdogNgrokSwitch $ConfigPath ([pscustomobject]@{confirmation="RESTORE PREVIOUS NGROK"}) $desired
    Assert-True "previous account restores and verifies" $restoredAccount.result.success
    Assert-Equal "restore returns to original domain" (Read-WatchdogJson $ConfigPath).publicBaseUrl $script:config.publicBaseUrl
    Assert-Equal "restore uses original credential" ([System.IO.File]::ReadAllText($credentialPath)) "old-test-record"
    Assert-Equal "restore retains recovery point" ([System.IO.File]::ReadAllText($previousPath)) $previousBytes
    $previous = Read-WatchdogJson $previousPath; $previous.machineSlug = "foreign"
    Write-WatchdogAtomicJson $previousPath $previous 10
    $script:serviceCalls = @(); $errorText = ""
    try { [void](Invoke-WatchdogNgrokSwitch $ConfigPath ([pscustomobject]@{confirmation="RESTORE PREVIOUS NGROK"}) $desired) } catch { $errorText = $_.Exception.Message }
    Assert-True "foreign recovery point rejected before restart" ($errorText -like "*does not match*" -and $script:serviceCalls.Count -eq 0)
    Write-WatchdogAtomicText $previousPath $previousBytes

    [System.IO.File]::Delete($credentialPath)
    [void](Invoke-WatchdogNgrokAccountSwitch $ConfigPath $payload $desired)
    Assert-True "original default credential absence is recorded" ($null -eq (Read-WatchdogJson $previousPath).credential)
    [void](Invoke-WatchdogNgrokSwitch $ConfigPath ([pscustomobject]@{confirmation="RESTORE PREVIOUS NGROK"}) $desired)
    Assert-True "restore removes override to reuse original ngrok configuration" (-not [System.IO.File]::Exists($credentialPath))
    [System.IO.File]::WriteAllText($credentialPath, "old-test-record")

    function Protect-WatchdogNgrokProfileToken([string]$Token) { return "synthetic-protected-profile-token" }
    $profilePayload = [pscustomobject]@{ name="One"; endpointMode="AgentEndpoint"; publicDomain="https://one.example.test"; internalAgentEndpoint=""; authToken="synthetic-token" }
    $one = Save-WatchdogNgrokProfile $script:config $profilePayload
    $json = ConvertTo-Json -InputObject $one -Depth 10 -Compress
    Assert-True "first profile response is a JSON array" ($json -match '"profiles":\[\{')
    $profilePayload.name = "Two"
    $two = Save-WatchdogNgrokProfile $script:config $profilePayload
    $removed = Remove-WatchdogNgrokProfile $script:config $two.id
    Assert-True "delete-to-one response is a JSON array" ((ConvertTo-Json -InputObject $removed -Depth 10 -Compress) -match '"profiles":\[\{')
    $removed = Remove-WatchdogNgrokProfile $script:config $one.id
    Assert-True "delete-to-zero response is an empty JSON array" ((ConvertTo-Json -InputObject $removed -Depth 10 -Compress) -match '"profiles":\[\]')

    $script:failVerification = $false
    $profilePayload.name = "Current domain"
    $profilePayload.publicDomain = $editable.publicDomain
    $saved = Save-WatchdogNgrokProfile $script:config $profilePayload
    function Unprotect-WatchdogNgrokProfileToken([string]$ProtectedText) { return "synthetic-token" }
    $savedResult = Invoke-WatchdogNgrokSwitch $ConfigPath ([pscustomobject]@{ confirmation="SWITCH NGROK PROFILE"; id=$saved.id }) $desired -SavedProfile
    Assert-True "saved token-only profile switches successfully" $savedResult.result.success
    Assert-Equal "saved profile is activated" (Read-WatchdogNgrokProfileStore $script:config).activeProfileId $saved.id
    Assert-True "saved token-only profile has no backup" ($null -eq $savedResult.result.backupId)
    [System.IO.File]::WriteAllText($credentialPath, "old-test-record")
    function Set-WatchdogNgrokActiveProfile($Config, [string]$Id) { throw "synthetic profile metadata write failure" }
    $script:serviceCalls = @()
    try { [void](Invoke-WatchdogNgrokSwitch $ConfigPath ([pscustomobject]@{ confirmation="SWITCH NGROK PROFILE"; id=$saved.id }) $desired -SavedProfile) }
    catch { $errorText = $_.Exception.Message }
    Assert-True "profile metadata failure participates in rollback" ($errorText -like "*was rolled back*")
    Assert-Equal "profile metadata failure restores credential" ([System.IO.File]::ReadAllText($credentialPath)) "old-test-record"
    Assert-True "profile metadata failure restarts old ngrok" ($script:serviceCalls -contains "start:ngrok:old-test-record")
    Invoke-Expression (Get-TestFunctionSource $corePath "Set-WatchdogNgrokActiveProfile")

    # Load Host functions without its top-level listener, UI, or process startup.
    $trayPath = Join-Path $PSScriptRoot "devspace-watchdog-tray.ps1"
    foreach ($name in @("Assert-ControlMutationAvailable", "Start-ControlNgrokSwitch", "Complete-ControlNgrokSwitch", "Write-ControlHeartbeat", "Wait-ControlMutationDrain", "Invoke-ControlHttpRequest", "Invoke-ManualServiceAction")) {
        Invoke-Expression (Get-TestFunctionSource $trayPath $name)
    }
    $script:settings = Get-WatchdogControlSettings $script:config
    $script:state = New-WatchdogState $script:config
    $script:statePath = Join-Path $testRoot "test-state.json"
    $script:heartbeatPath = Join-Path $testRoot "test-heartbeat.json"
    $script:lastHeartbeat = [DateTimeOffset]::MinValue
    $script:mutationInProgress = $false
    $script:mutationPowerShell = $null
    $script:mutationAsync = $null
    $script:mutationClient = $null
    $script:shutdownRequested = $false
    $script:responses = @()
    $script:healthStopped = 0
    $script:adoptedWhileBusy = $false
    $script:drainSleepCount = 0
    $isHostMode = $true
    function Stop-HealthRunspace { $script:healthStopped++ }
    function Get-OverallTrayState { return [pscustomobject]@{ label="Test" } }
    function Assert-ControlMutation { }
    function Get-ControlStatusPayload { return [pscustomobject]@{ mutationInProgress=$script:mutationInProgress } }
    function Write-ControlJson($Stream, [int]$Status, $Value) { $script:responses += [pscustomobject]@{ status=$Status; value=$Value } }
    function Apply-HealthSnapshot($Snapshot) { $script:adoptedWhileBusy = $script:mutationInProgress }
    function Request-ImmediatePublicProbe { }
    $client = [pscustomobject]@{ disposed=$false }
    $client | Add-Member ScriptMethod GetStream { return $null }
    $client | Add-Member ScriptMethod Dispose { $this.disposed = $true }

    # A named event holds a fake worker so the real dispatcher and completion/drain
    # functions can be exercised without loading the production service/credential code.
    $eventName = "Local\DevSpaceNgrokTest-" + [Guid]::NewGuid().ToString("N")
    $created = $false
    $gate = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $eventName, [ref]$created)
    $corePath = Join-Path $testRoot "fake-worker-core.ps1"
    $fakeWorker = @'
function Invoke-WatchdogNgrokSwitch($ConfigPath, $Payload, $Desired, [switch]$SavedProfile) {
    if ($Payload.needsAttention) {
        $failure = New-Object System.InvalidOperationException("synthetic partial rollback")
        $failure.Data["WatchdogRollbackNeedsAttention"] = $true
        throw $failure
    }
    $gate = [System.Threading.EventWaitHandle]::OpenExisting($Payload.eventName)
    try { if (-not $gate.WaitOne(30000)) { throw "Test worker was not released." } } finally { $gate.Dispose() }
    return [pscustomobject]@{ config=([System.IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json); snapshot=[pscustomobject]@{}; result=[pscustomobject]@{ success=$true } }
}
function Protect-WatchdogText($Value) { return $Value }
function Read-WatchdogJson($Path) { return [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json }
'@
    [System.IO.File]::WriteAllText($corePath, $fakeWorker)
    try {
        Start-ControlNgrokSwitch $client ([pscustomobject]@{ eventName=$eventName })
        Assert-True "dispatch returns while worker remains pending" (-not $script:mutationAsync.IsCompleted)
        Assert-Equal "dispatch stops previous health work" $script:healthStopped 1
        Write-ControlHeartbeat -Force
        $heartbeat = Read-WatchdogJson $script:heartbeatPath
        Assert-True "Host writes busy heartbeat while worker held" $heartbeat.mutationInProgress
        Assert-True "heartbeat binds exact process start" ([bool]$heartbeat.processStartUtc)
        $hostHeader = "127.0.0.1:$($script:settings.dashboardPort)"
        $getRequest = [pscustomobject]@{ method="GET"; path="/api/status"; headers=@{host=$hostHeader}; stream=$null }
        Invoke-ControlHttpRequest $getRequest
        Assert-Equal "GET status remains responsive" $script:responses[-1].status 200
        $held = [System.Diagnostics.Stopwatch]::StartNew()
        while ($held.Elapsed.TotalSeconds -lt 16) {
            [System.Threading.Thread]::Sleep(1000)
            Write-ControlHeartbeat
            Invoke-ControlHttpRequest $getRequest
        }
        Assert-True "worker stays active beyond stale-heartbeat threshold" (-not $script:mutationAsync.IsCompleted)
        $heartbeat = Read-WatchdogJson $script:heartbeatPath
        Assert-True "heartbeat remains fresh after sixteen seconds" (([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($heartbeat.timestamp)).TotalSeconds -lt 4)
        Assert-Equal "status still responds after sixteen seconds" $script:responses[-1].status 200
        $postRequest = [pscustomobject]@{ method="POST"; path="/api/action"; headers=@{host=$hostHeader}; body='{}'; stream=$null }
        Invoke-ControlHttpRequest $postRequest
        Assert-Equal "second mutation is rejected" $script:responses[-1].status 409
        $rejected = $false
        try { [void](Invoke-ManualServiceAction "maintenance" "all") } catch { $rejected = $true }
        Assert-True "legacy menu mutation also rejected" $rejected
        Assert-True "accepted HTTP client retained during work" (-not $client.disposed)

        function Start-Sleep {
            param([int]$Seconds, [int]$Milliseconds)
            $script:drainSleepCount++
            if ($script:drainSleepCount -eq 2) {
                Assert-True "shutdown latches before worker finishes" $script:shutdownRequested
                Assert-True "shutdown keeps transaction busy" $script:mutationInProgress
                [void]$gate.Set()
            }
            [System.Threading.Thread]::Sleep(20)
        }
        Wait-ControlMutationDrain
        Assert-True "shutdown drains transaction without cancellation" $script:adoptedWhileBusy
        Assert-True "completed worker releases busy slot" (-not $script:mutationInProgress)
        Assert-True "accepted HTTP client disposed after response" $client.disposed
        Assert-Equal "accepted request receives final success" $script:responses[-1].status 200
        $script:shutdownRequested = $false
        $client.disposed = $false
        Start-ControlNgrokSwitch $client ([pscustomobject]@{ needsAttention=$true })
        while ($script:mutationAsync) { [System.Threading.Thread]::Sleep(20); Complete-ControlNgrokSwitch }
        Assert-True "uncertain rollback pauses automatic recovery" $script:state.maintenanceMode
        Assert-True "uncertain rollback persists maintenance" (Read-WatchdogJson $script:statePath).maintenanceMode
        Assert-Equal "uncertain rollback returns failed response" $script:responses[-1].status 400
    } finally {
        [void]$gate.Set()
        if ($script:mutationAsync) { Wait-ControlMutationDrain }
        $gate.Dispose()
    }
    Write-Host "ngrok transaction, token-only rollback, profile arrays, async responsiveness and shutdown tests passed."
} finally {
    $fullRoot = [System.IO.Path]::GetFullPath($testRoot)
    $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $fullRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -or [System.IO.Path]::GetFileName($fullRoot) -notlike "devspace-ngrok-transaction-test-*") { throw "Unexpected test cleanup path." }
    Remove-Item -LiteralPath $fullRoot -Recurse -Force
}
