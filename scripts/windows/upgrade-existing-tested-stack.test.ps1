$ErrorActionPreference = "Stop"
$paths = @(
    (Join-Path $PSScriptRoot "upgrade-existing-tested-stack.ps1"),
    (Join-Path $PSScriptRoot "start-existing-tested-stack-upgrade.ps1"),
    (Join-Path $PSScriptRoot "run-existing-tested-stack-upgrade.ps1")
)
foreach ($path in $paths) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw "$path`n$($errors | Out-String)" }
}
$source = Get-Content (Join-Path $PSScriptRoot "upgrade-existing-tested-stack.ps1") -Raw
@(
    'ValidateSet("Auto", "Upgrade", "UpgradeDevSpace", "UpgradeHermes", "CapabilitiesOnly")',
    "Get-TestedStackPlan",
    "Resolve-RepoRemote",
    "Normalize-GitUrl",
    "Assert-CanStopManagedListeners",
    "OpenProcess(0x0001",
    "FIXED PORT CONFLICT:",
    "ResponseHeadersRead",
    "Copy-CriticalState",
    "rollback-manifest.json",
    "Invoke-Rollback",
    "NoAutoRollback",
    "migrate-oauth-json-to-sqlite.mjs",
    "credentials will not be regenerated",
    "Owner auth changed unexpectedly",
    "Task privilege/definition changed unexpectedly",
    "Preserve current effective settings",
    "npm.cmd run test:windows-watchdog",
    "pytest -q",
    "Copy-Item `$WatchdogSource"
) | ForEach-Object { if (-not $source.Contains($_)) { throw "Missing upgrade safety behavior: $_" } }
if ($source.Contains("raw.githubusercontent.com")) { throw "Existing-machine upgrade must use the local tested installer package, not mutable raw branch downloads." }
foreach ($ambiguous in @('$devVersion', '$hermesVersion', '$DevSpaceVersion', '$HermesVersion', '$DevSpaceCommit', '$HermesCommit')) {
    if ($source.Contains($ambiguous)) { throw "PowerShell case-insensitive current/pinned variable collision remains: $ambiguous" }
}
foreach ($requiredName in @('$CurrentDevSpaceVersion', '$PinnedDevSpaceVersion', '$CurrentHermesVersion', '$PinnedHermesVersion')) {
    if (-not $source.Contains($requiredName)) { throw "Explicit current/pinned variable is missing: $requiredName" }
}
$launcher = Get-Content (Join-Path $PSScriptRoot "start-existing-tested-stack-upgrade.ps1") -Raw
if (-not $launcher.Contains("Start-Process") -or -not $launcher.Contains("status.json")) { throw "Detached upgrade launcher is incomplete." }
$runner = Get-Content (Join-Path $PSScriptRoot "run-existing-tested-stack-upgrade.ps1") -Raw
if (-not $runner.Contains("request.json") -and -not $runner.Contains("RequestPath")) { throw "Detached upgrade runner does not consume a request file." }

# Run only the rollback function with inert service/storage boundaries.
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
. (Join-Path $PSScriptRoot 'watchdog-control-core.ps1')
& {
    foreach ($name in @('Get-PortOwners','Test-ManagedProcessForPort','Get-ManagedListenerPlan','Stop-ManagedListeners')) {
        $definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        Invoke-Expression $definition.Extent.Text
    }
    function Fail([string]$Message) { throw $Message }
    $fixture=@{deny=$false;actions=[Collections.Generic.List[string]]::new();handles=@{}}
    $born=[datetime]'2026-11-17T00:00:00Z'
    $fixture.processes=@(
        [pscustomobject]@{ProcessId=42011;ParentProcessId=0;CreationDate=$born;Name='python.exe';ExecutablePath='C:\test\python.exe';CommandLine='python.exe C:\test\server.py --http --port 14750'},
        [pscustomobject]@{ProcessId=42012;ParentProcessId=42011;CreationDate=$born.AddSeconds(1)}
    )
    function Get-NetTCPConnection { if ($fixture.deny) { throw 'listener query denied' }; return [pscustomobject]@{State='Listen';LocalPort=14750;OwningProcess=42011} }
    function Get-CimInstance { param($ClassName,$Filter) if($Filter){return $fixture.processes[0]}; return $fixture.processes }
    function Stop-Process { throw 'PID-only termination is forbidden' }
    function Get-Process { param($Id) return $fixture.handles[[int]$Id] }
    $settings=@{hermesPort=14750;hermesPython='C:\test\python.exe';hermesServer='C:\test\server.py';ngrokInspectorPort=4040}
    $plan=@(Get-ManagedListenerPlan $settings)
    if ($plan.Count -ne 1 -or $plan[0].CreationDate -ne $born) { throw 'Legacy plan must retain the observed creation time.' }
    $fixture.deny=$true
    $failed=$false
    try { Get-ManagedListenerPlan $settings | Out-Null } catch { $failed=$true }
    if (-not $failed) { throw 'An unreadable listener inventory must not authorize a stop.' }
    $fixture.deny=$false
    $unrelated=[pscustomobject]@{Name='python.exe';ExecutablePath=$settings.hermesPython;CommandLine='python.exe C:\unrelated.py --port 14750'}
    if (Test-ManagedProcessForPort $settings 14750 $unrelated 4040) { throw 'A shared interpreter does not identify Hermes.' }
    $missing=@{port=7676;hermesPort=14750;routerPort=14780}
    foreach ($port in @(7676,14750,14780)) {
        if (Test-ManagedProcessForPort $missing $port $unrelated 4040) { throw 'Missing script path matched an unrelated listener.' }
    }
    foreach ($item in $fixture.processes) {
        $handle=[pscustomobject]@{Id=$item.ProcessId;StartTime=$item.CreationDate;Handle=[IntPtr]1;HasExited=$false;Disposed=$false}
        $handle | Add-Member ScriptMethod Kill { $fixture.actions.Add("kill:$($this.Id)"); $this.HasExited=$true }
        $handle | Add-Member ScriptMethod WaitForExit { param($Timeout) $fixture.actions.Add("wait:$($this.Id)"); return $this.HasExited }
        $handle | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
        $fixture.handles[[int]$item.ProcessId]=$handle
    }
    $fixture.processes[0].CreationDate=$born.AddTicks(20)
    $failed=$false
    try { Stop-ManagedListeners $plan } catch { $failed=$true }
    if (-not $failed -or $fixture.actions.Count) { throw 'Stale listener plan must preserve every process.' }
    $fixture.processes[0].CreationDate=$born
    $original=$fixture.processes
    $fixture.processes=@($original[1])
    $failed=$false
    try { Stop-ManagedListeners $plan } catch { $failed=$true }
    if (-not $failed -or $fixture.actions.Count) { throw 'A missing listener parent must not hide surviving descendants.' }
    $fixture.processes=$original
    Stop-ManagedListeners $plan
    if (($fixture.actions -join ',') -ne 'kill:42012,wait:42012,kill:42011,wait:42011') { throw 'Legacy children must exit before their listener parent.' }
    if (@($fixture.handles.Values | Where-Object { -not $_.Disposed }).Count) { throw 'Legacy stop leaked a retained handle.' }
}
$rollback = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Rollback' }, $true)
if (-not $rollback) { throw 'Rollback function missing.' }
& {
    $WarningPreference = 'SilentlyContinue'
    Invoke-Expression $rollback.Extent.Text
    $InstallDir = Join-Path $env:TEMP 'unused-upgrade-fixture'
    $manifest = [pscustomobject]@{ upgradeDevSpace=$false; upgradeHermes=$false; externalStateBackedUp=$false; hermesHomeBackedUp=$false }
    $task = [pscustomobject]@{ Name='unused-test-task'; Path='\' }
    $boundary = @{ failure=''; actions=[Collections.Generic.List[string]]::new() }
    function Read-Json { if ($boundary.failure -eq 'read') { throw 'injected read failure' }; return @{} }
    function Get-ManagedListenerPlan { if ($boundary.failure -eq 'identity') { throw 'injected identity failure' }; return @() }
    function Assert-CanStopManagedListeners { if ($boundary.failure -eq 'access') { throw 'injected access failure' } }
    function Stop-ManagedListeners { if ($boundary.failure -eq 'stop') { throw 'injected stop failure' }; $boundary.actions.Add('stopped') }
    function Restore-CriticalState { $boundary.actions.Add('restore') }
    function Start-ScheduledTask { $boundary.actions.Add('start') }
    function Start-Sleep { }
    function Verify-Live { $boundary.actions.Add('verify') }
    foreach ($phase in @('read','identity','access','stop')) {
        $boundary.failure = $phase
        $boundary.actions.Clear()
        $failure = $null
        try { Invoke-Rollback $manifest $InstallDir $task }
        catch { $failure = $_.Exception.Message }
        if (-not $failure -or $failure -notlike "*injected $phase failure*") { throw "Rollback must propagate $phase failure before restoring data." }
        if ($boundary.actions.Count) { throw "Rollback modified state after $phase failure: $($boundary.actions -join ',')" }
    }
    $boundary.failure = ''
    $boundary.actions.Clear()
    Invoke-Rollback $manifest $InstallDir $task
    if (($boundary.actions -join ',') -ne 'stopped,restore,start,verify') { throw 'Successful rollback ordering changed.' }
}
Write-Host "existing stack upgrade installer tests passed."
