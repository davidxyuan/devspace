[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "watchdog-control-core.ps1")
Set-StrictMode -Version Latest

function Assert-Equal([string]$Name, $Actual, $Expected) {
    if ($Actual -ne $Expected) { throw "$Name failed.`nExpected: $Expected`nActual:   $Actual" }
}

function Assert-True([string]$Name, [bool]$Value) {
    if (-not $Value) { throw "$Name failed." }
}

function Assert-Contains([string]$Name, [string]$Text, [string]$Expected) {
    if (-not $Text.Contains($Expected)) { throw "$Name failed. Missing: $Expected" }
}

function Assert-Throws([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    try { & $Action; throw "$Name did not throw." }
    catch {
        if ($_.Exception.Message -eq "$Name did not throw.") { throw }
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) { throw "$Name threw the wrong error: $($_.Exception.Message)" }
    }
}

function New-TestConfig([string]$Root) {
    return [pscustomobject][ordered]@{
        stateDir=$Root; machineSlug="alpha"; devspaceEnabled=$true; hermesEnabled=$true
        mcpRoutes=@(
            [pscustomobject]@{name="devspace_chatgpt_alpha";service="devspace";prefix="/alpha/devspace_chatgpt";targetHost="127.0.0.1";targetPort=17676},
            [pscustomobject]@{name="hermes_chatgpt_alpha";service="hermes";prefix="/alpha/hermes_chatgpt";targetHost="127.0.0.1";targetPort=14750}
        )
        port=17676; retiredPorts=@(); nodePath="C:\missing\node.exe"; cliPath="C:\missing\cli.js"
        hermesCommand="C:\missing\run-hermes.cmd"; hermesPython="C:\missing\python.exe"; hermesServer="C:\missing\server.py"; hermesWorkingDirectory="C:\missing"; hermesPort=14750
        routerPath="C:\missing\router.cjs"; routerPort=18766; publicUpstreamPort=18766
        ngrokPath="C:\missing\ngrok.exe"; manageNgrok=$true; publicBaseUrl="https://alpha.example.test/alpha/devspace_chatgpt"
        ngrokEndpointMode="AgentEndpoint"; ngrokAgentBaseUrl="https://alpha.example.test"; ngrokBinding=""; ngrokInspectorPort=4040; ngrokWebAddrSupported=$false
        mcpNameSuffix="alpha"; cloudEndpointPolicyPath=""; cloudEndpointRulePath=""
        capabilities=[pscustomobject]@{devspace=[pscustomobject]@{toolMode="full";widgets="full";skills=$true;subagents=$true};hermes=[pscustomobject]@{}}
        controlCenter=[pscustomobject]@{
            dashboardPort=18777;localProbeSeconds=5;publicProbeSeconds=45;failureThreshold=2;maxRecoveryAttempts=5
            backoffSeconds=@(0,10,30,60,120);logMaxBytes=65536;historyLimit=100
            displayNames=[pscustomobject]@{devspace="Alpha DevSpace";hermes="Alpha Hermes"}
        }
    }
}

function Copy-Editable($Config) { return Copy-WatchdogObject (Get-WatchdogEditableConfig $Config) }

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("devspace-watchdog-control-test-" + [Guid]::NewGuid().ToString("N"))
try {
    [void][System.IO.Directory]::CreateDirectory($tempRoot)
    $configPath = Join-Path $tempRoot "devspace-watchdog.config.json"
    $devspaceConfigPath = Join-Path $tempRoot "config.json"
    $config = New-TestConfig $tempRoot
    Write-WatchdogAtomicJson $configPath $config 30
    Write-WatchdogAtomicJson $devspaceConfigPath ([pscustomobject]@{host="127.0.0.1";port=17676;allowedRoots=@($tempRoot);publicBaseUrl=$config.publicBaseUrl}) 10

    $settings = Get-WatchdogControlSettings $config
    Assert-Equal "default dashboard port" $settings.dashboardPort 18777
    Assert-Equal "backoff count" $settings.backoffSeconds.Count 5

    $statePath = Join-Path $tempRoot "watchdog-tray-state.json"
    $state = New-WatchdogState $config
    Set-WatchdogDesiredState $state "hermes" "stopped_by_user"
    $state.maintenanceMode = $true
    Save-WatchdogState $statePath $state
    $reloaded = Read-WatchdogState $statePath $config
    Assert-Equal "manual stop persisted" $reloaded.desired.hermes "stopped_by_user"
    Assert-Equal "maintenance persisted" $reloaded.maintenanceMode $true
    Assert-Equal "reboot-style state reload" $reloaded.recovery.hermes.phase "ManualStop"
    $corruptStatePath = Join-Path $tempRoot "corrupt-state.json"
    Write-WatchdogAtomicText $corruptStatePath "{not-json"
    $safeState = Read-WatchdogState $corruptStatePath $config
    Assert-Equal "corrupt state pauses recovery" $safeState.maintenanceMode $true
    Assert-True "corrupt state records error" ([bool]$safeState.stateLoadError)

    $decisionState = New-WatchdogState $config
    $testSettings = Get-WatchdogControlSettings $config
    $testSettings.maxRecoveryAttempts = 2
    $testSettings.backoffSeconds = @(0,10)
    $failed = [pscustomobject]@{healthy=$false;busyIndeterminate=$false;identityConflict=$false;error="missing"}
    $now = [DateTimeOffset]::Parse("2026-08-28T00:00:00Z")
    $first = Update-WatchdogRecoveryDecision $decisionState "devspace" $failed $testSettings $now
    Assert-Equal "single failure does not restart" $first.action "None"
    Assert-Equal "first failure suspect" $first.record.phase "Suspect"
    $second = Update-WatchdogRecoveryDecision $decisionState "devspace" $failed $testSettings $now.AddSeconds(1)
    Assert-Equal "confirmed failure restarts" $second.action "Recover"
    Assert-Equal "first recovery attempt" $second.record.attemptCount 1
    Complete-WatchdogRecoveryAttempt $decisionState "devspace" ([pscustomobject]@{success=$false;error="start failed"})
    $waiting = Update-WatchdogRecoveryDecision $decisionState "devspace" $failed $testSettings $now.AddSeconds(2)
    Assert-Equal "second attempt enters backoff" $waiting.action "Wait"
    $retry = Update-WatchdogRecoveryDecision $decisionState "devspace" $failed $testSettings $now.AddSeconds(12)
    Assert-Equal "backoff permits retry" $retry.action "Recover"
    Assert-Equal "second recovery attempt" $retry.record.attemptCount 2
    $maxed = Update-WatchdogRecoveryDecision $decisionState "devspace" $failed $testSettings $now.AddSeconds(30)
    Assert-Equal "max retry stops recovery" $maxed.action "None"
    Assert-Equal "max retry fail-safe" $maxed.record.phase "RecoveryFailed"

    $manualState = New-WatchdogState $config
    Set-WatchdogDesiredState $manualState "devspace" "stopped_by_user"
    Assert-Equal "manual stop never recovers" (Update-WatchdogRecoveryDecision $manualState "devspace" $failed $testSettings $now).reason "stopped_by_user"
    $maintenanceState = New-WatchdogState $config; $maintenanceState.maintenanceMode = $true
    Assert-Equal "maintenance never recovers" (Update-WatchdogRecoveryDecision $maintenanceState "devspace" $failed $testSettings $now).reason "maintenance"
    $busy = [pscustomobject]@{healthy=$false;busyIndeterminate=$true;identityConflict=$false;error="long MCP call"}
    Assert-Equal "busy service never restarts" (Update-WatchdogRecoveryDecision (New-WatchdogState $config) "devspace" $busy $testSettings $now).reason "busy_indeterminate"
    $conflict = [pscustomobject]@{healthy=$false;busyIndeterminate=$false;identityConflict=$true;error="wrong owner"}
    Assert-Equal "identity conflict fails closed" (Update-WatchdogRecoveryDecision (New-WatchdogState $config) "devspace" $conflict $testSettings $now).record.phase "RecoveryFailed"
    $healthyState = New-WatchdogState $config; $healthyState.recovery.devspace.attemptCount = 2
    $healthy = [pscustomobject]@{healthy=$true;busyIndeterminate=$false;identityConflict=$false;error=""}
    Assert-Equal "healthy state resets attempts" (Update-WatchdogRecoveryDecision $healthyState "devspace" $healthy $testSettings $now).record.attemptCount 0

    $displayInput = Copy-Editable $config; $displayInput.devspaceDisplayName = "Display Only"
    $displayValidated = ConvertTo-WatchdogEditableConfig $displayInput $config
    Assert-Equal "display name impact green" (New-WatchdogConfigImpact $config $displayValidated).level "GREEN"
    $restartInput = Copy-Editable $config; $restartInput.routerPort = 18767
    $restartValidated = ConvertTo-WatchdogEditableConfig $restartInput $config
    Assert-Equal "restart-only impact yellow" (New-WatchdogConfigImpact $config $restartValidated).level "YELLOW"
    $domainInput = Copy-Editable $config; $domainInput.publicDomain = "https://beta.example.test"
    $domainValidated = ConvertTo-WatchdogEditableConfig $domainInput $config
    $domainImpact = New-WatchdogConfigImpact $config $domainValidated
    Assert-Equal "domain impact red" $domainImpact.level "RED"
    Assert-Equal "domain requires reconnect" $domainImpact.requiresChatGptReconnect $true
    $routeInput = Copy-Editable $config; $routeInput.devspaceRoutePath = "/alpha/new_devspace"
    Assert-Equal "route impact red" (New-WatchdogConfigImpact $config (ConvertTo-WatchdogEditableConfig $routeInput $config)).level "RED"

    $cloudInput = Copy-Editable $config
    $cloudInput.endpointMode = "CloudEndpoint"
    $cloudInput.internalAgentEndpoint = "https://alpha-devspace.internal"
    $cloud = ConvertTo-WatchdogEditableConfig $cloudInput $config
    $cloudProposed = New-WatchdogProposedConfig $config $cloud
    Assert-Equal "Cloud endpoint binding" $cloudProposed.ngrokBinding "internal"
    Assert-Equal "Cloud internal endpoint" $cloudProposed.ngrokAgentBaseUrl "https://alpha-devspace.internal"
    $policy = New-WatchdogNgrokPolicy $cloud.machineSlug $cloud.internalAgentEndpoint
    Assert-Contains "Traffic Policy machine route" $policy 'req.url.path.startsWith("/alpha/")'
    Assert-Contains "Traffic Policy OAuth authorization route" $policy '/.well-known/oauth-authorization-server/alpha/'
    Assert-Contains "Traffic Policy OAuth resource route" $policy '/.well-known/oauth-protected-resource/alpha/'
    $customCloud = Copy-WatchdogObject $cloud
    $customCloud.devspaceRoutePath = "/shared/devspace"
    $customCloud.hermesRoutePath = "/shared/hermes"
    $customPolicy = (New-WatchdogConfigImpact $config $customCloud).trafficPolicy
    Assert-Contains "Traffic Policy includes custom DevSpace route" $customPolicy 'req.url.path == "/shared/devspace"'
    Assert-Contains "Traffic Policy includes custom OAuth metadata route" $customPolicy '/.well-known/oauth-authorization-server/shared/hermes'
    $agent = Copy-Editable $config; $agent.endpointMode = "AgentEndpoint"; $agent.internalAgentEndpoint = "https://unused.example.test"
    $agentValidated = ConvertTo-WatchdogEditableConfig $agent $config
    Assert-Equal "Agent endpoint ignores stale internal origin" $agentValidated.internalAgentEndpoint "https://alpha.example.test"
    $agentProposed = New-WatchdogProposedConfig $config $agentValidated
    Assert-Equal "Agent endpoint clears binding" $agentProposed.ngrokBinding ""
    Assert-Equal "Agent endpoint uses public origin" $agentProposed.ngrokAgentBaseUrl "https://alpha.example.test"

    Assert-Throws "invalid low port" { $input=Copy-Editable $config; $input.routerPort=0; ConvertTo-WatchdogEditableConfig $input $config } "Router Port"
    Assert-Throws "invalid high port" { $input=Copy-Editable $config; $input.routerPort=65536; ConvertTo-WatchdogEditableConfig $input $config } "Router Port"
    Assert-Throws "duplicate ports" { $input=Copy-Editable $config; $input.routerPort=$input.ngrokInspectorPort; ConvertTo-WatchdogEditableConfig $input $config } "distinct"
    Assert-Throws "unsupported inspector override" { $input=Copy-Editable $config; $input.ngrokInspectorPort=14041; ConvertTo-WatchdogEditableConfig $input $config } "must remain 4040"
    Assert-Throws "domain path rejected" { $input=Copy-Editable $config; $input.publicDomain="https://evil.example/path"; ConvertTo-WatchdogEditableConfig $input $config } "path"
    Assert-Throws "domain credentials rejected" { $input=Copy-Editable $config; $input.publicDomain="https://user:pass@evil.example"; ConvertTo-WatchdogEditableConfig $input $config } "credentials"
    Assert-Throws "localhost rejected" { $input=Copy-Editable $config; $input.publicDomain="https://localhost"; ConvertTo-WatchdogEditableConfig $input $config } "invalid public host"
    Assert-Throws "unsafe route rejected" { $input=Copy-Editable $config; $input.devspaceRoutePath="/alpha/x;Stop-Process"; ConvertTo-WatchdogEditableConfig $input $config } "Route Path"
    Assert-Throws "path traversal rejected" { $input=Copy-Editable $config; $input.devspaceRoutePath="/alpha/../x"; ConvertTo-WatchdogEditableConfig $input $config } "Route Path"
    Assert-Throws "internal command injection rejected" { $input=Copy-Editable $config; $input.endpointMode="CloudEndpoint"; $input.internalAgentEndpoint='https://alpha.internal";Stop-Process'; ConvertTo-WatchdogEditableConfig $input $config } "Internal Agent Endpoint"

    $validRpc = '{"jsonrpc":"2.0","id":"devspace-watchdog-health","result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"test","version":"1"}}}'
    Assert-Equal "valid MCP JSON-RPC accepted" (Test-WatchdogMcpResponse 200 $validRpc @{}).protocolHealthy $true
    Assert-Equal "arbitrary HTTP 200 rejected" (Test-WatchdogMcpResponse 200 '<html>OK</html>' @{}).protocolHealthy $false
    Assert-Equal "generic JSON-RPC error rejected" (Test-WatchdogMcpResponse 200 '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}' @{}).protocolHealthy $false
    Assert-Equal "OAuth MCP challenge accepted" (Test-WatchdogMcpResponse 401 "" @{"www-authenticate"='Bearer resource_metadata="https://alpha.example/.well-known/oauth-protected-resource"'}).protocolHealthy $true
    Assert-Equal "plain 401 rejected" (Test-WatchdogMcpResponse 401 "" @{"www-authenticate"="Basic"}).protocolHealthy $false

    $expectedNode = [pscustomobject]@{Name="node.exe";ExecutablePath=$config.nodePath;CommandLine='"C:\missing\node.exe" "C:\missing\cli.js" serve'}
    Assert-Equal "DevSpace process identity accepts exact executable" (Test-WatchdogManagedProcess $expectedNode "devspace" $config) $true
    $wrongNode = Copy-WatchdogObject $expectedNode; $wrongNode.ExecutablePath = "C:\other\node.exe"
    Assert-Equal "DevSpace process identity rejects wrong executable" (Test-WatchdogManagedProcess $wrongNode "devspace" $config) $false
    $hermesUvChild = [pscustomobject]@{Name="python.exe";ExecutablePath="C:\uv\python.exe";CommandLine='"C:\uv\python.exe" "C:\missing\server.py" --http --host 127.0.0.1 --port 14750'}
    Assert-Equal "Hermes process identity accepts uv child with exact server and port" (Test-WatchdogManagedProcess $hermesUvChild "hermes" $config) $true
    $hermesWithWrongPort = [pscustomobject]@{Name="python.exe";ExecutablePath=$config.hermesPython;CommandLine='"C:\missing\python.exe" "C:\missing\server.py" --http --host 127.0.0.1 --port 114750'}
    Assert-Equal "Hermes process identity rejects partial port match" (Test-WatchdogManagedProcess $hermesWithWrongPort "hermes" $config) $false
    $cloudIdentityConfig = Copy-WatchdogObject $config; $cloudIdentityConfig.ngrokBinding = "internal"; $cloudIdentityConfig.ngrokAgentBaseUrl = "https://alpha-devspace.internal"
    $ngrokWithoutBinding = [pscustomobject]@{Name="ngrok.exe";ExecutablePath=$config.ngrokPath;CommandLine='"C:\missing\ngrok.exe" http http://127.0.0.1:18766 --url https://alpha-devspace.internal'}
    Assert-Equal "Cloud ngrok identity requires binding" (Test-WatchdogManagedProcess $ngrokWithoutBinding "ngrok" $cloudIdentityConfig) $false
    $ngrokWrongBinding = Copy-WatchdogObject $ngrokWithoutBinding; $ngrokWrongBinding.CommandLine += ' --binding not-internal'
    Assert-Equal "Cloud ngrok identity rejects partial binding match" (Test-WatchdogManagedProcess $ngrokWrongBinding "ngrok" $cloudIdentityConfig) $false

    $disabledConfig = Copy-WatchdogObject $config
    $disabledConfig.devspaceEnabled = $false; $disabledConfig.hermesEnabled = $false; $disabledConfig.routerPort = 0; $disabledConfig.manageNgrok = $false
    $disabledPath = Join-Path $tempRoot "disabled-watchdog.config.json"
    Write-WatchdogAtomicJson $disabledPath $disabledConfig 30
    $disabledHealth = Get-WatchdogHealthSnapshot $disabledPath
    Assert-Equal "disabled DevSpace is not probed" $disabledHealth.services.devspace.enabled $false
    Assert-Equal "disabled ngrok is not probed" $disabledHealth.services.ngrok.enabled $false

    $optionalConfig = Copy-WatchdogObject $config
    Set-WatchdogProperty $optionalConfig "codexPath" (Join-Path $tempRoot "missing-codex.cmd")
    Set-WatchdogProperty $optionalConfig "codexSkillRoot" (Join-Path $tempRoot "missing-skills")
    Set-WatchdogProperty $optionalConfig "openCodexHome" (Join-Path $tempRoot "missing-opencodex")
    $absentTools = Get-WatchdogOptionalToolStatus $optionalConfig @()
    Assert-Equal "missing Codex stays optional" $absentTools.codex.visible $false
    Assert-Equal "missing OpenCodex stays optional" $absentTools.openCodex.visible $false

    $fakeCodex = Join-Path $tempRoot "codex.cmd"
    Write-WatchdogAtomicText $fakeCodex "@echo off`r`n"
    $skillRoot = Join-Path $tempRoot "skills"
    [void][System.IO.Directory]::CreateDirectory((Join-Path $skillRoot "codex-with-chatgpt"))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $skillRoot "tyo-c2c-orchestrator"))
    Write-WatchdogAtomicText (Join-Path $skillRoot "codex-with-chatgpt\SKILL.md") "official"
    Write-WatchdogAtomicText (Join-Path $skillRoot "tyo-c2c-orchestrator\SKILL.md") "tyo"
    $fakeOpenCodex = Join-Path $tempRoot "opencodex"
    [void][System.IO.Directory]::CreateDirectory($fakeOpenCodex)
    Write-WatchdogAtomicText (Join-Path $fakeOpenCodex "opencodex-tray.ps1") "# tray"
    Write-WatchdogAtomicText (Join-Path $fakeOpenCodex "opencodex-tray.vbs") "' launcher"
    Set-WatchdogProperty $optionalConfig "codexPath" $fakeCodex
    Set-WatchdogProperty $optionalConfig "codexSkillRoot" $skillRoot
    Set-WatchdogProperty $optionalConfig "openCodexHome" $fakeOpenCodex
    $fakeProcesses = @(
        [pscustomobject]@{Name="codex.exe";CommandLine="codex.exe"},
        [pscustomobject]@{Name="powershell.exe";CommandLine="powershell.exe -File $fakeOpenCodex\opencodex-tray.ps1"}
    )
    $presentTools = Get-WatchdogOptionalToolStatus $optionalConfig $fakeProcesses
    Assert-Equal "Codex auto-detected" $presentTools.codex.visible $true
    Assert-Equal "official C2C detected" $presentTools.codex.officialC2c $true
    Assert-Equal "TYO C2C detected" $presentTools.codex.tyoC2c $true
    Assert-Equal "OpenCodex tray detected" $presentTools.openCodex.trayRunning $true
    Assert-Equal "running OpenCodex tray needs no repair" $presentTools.openCodex.repairTrayAvailable $false

    $applyInput = Copy-Editable $config; $applyInput.devspaceDisplayName = "Changed Display"
    $applied = Set-WatchdogConfiguration $configPath $applyInput
    Assert-True "configuration backup created" ([System.IO.File]::Exists((Join-Path (Join-Path (Get-WatchdogBackupRoot $tempRoot) $applied.backup.id) "manifest.json")))
    Assert-Equal "configuration applied" (Get-WatchdogEditableConfig (Read-WatchdogJson $configPath)).devspaceDisplayName "Changed Display"
    Assert-True "backup listed" (@(Get-WatchdogConfigurationBackups $tempRoot).Count -ge 1)
    [void](Restore-WatchdogConfigurationBackup $configPath $applied.backup.id)
    Assert-Equal "configuration rollback restored before state" (Get-WatchdogEditableConfig (Read-WatchdogJson $configPath)).devspaceDisplayName "Alpha DevSpace"

    $cloudApplyInput = Copy-Editable (Read-WatchdogJson $configPath)
    $cloudApplyInput.endpointMode = "CloudEndpoint"
    $cloudApplyInput.internalAgentEndpoint = "https://alpha-devspace.internal"
    $preexistingPolicyPath = Join-Path $tempRoot "ngrok-cloud-endpoint-alpha.policy.yml"
    Write-WatchdogAtomicText $preexistingPolicyPath "preexisting-policy`n"
    $cloudApplied = Set-WatchdogConfiguration $configPath $cloudApplyInput
    $cloudConfig = Read-WatchdogJson $configPath
    Assert-True "Cloud apply writes policy" ([System.IO.File]::Exists([string]$cloudConfig.cloudEndpointPolicyPath))
    Assert-True "Cloud apply writes merge rule" ([System.IO.File]::Exists([string]$cloudConfig.cloudEndpointRulePath))
    [void](Restore-WatchdogConfigurationBackup $configPath $cloudApplied.backup.id)
    Assert-Equal "rollback restores preexisting generated policy" ([System.IO.File]::ReadAllText([string]$cloudConfig.cloudEndpointPolicyPath, [System.Text.Encoding]::UTF8)) "preexisting-policy`n"
    Assert-True "rollback removes newly generated merge rule" (-not [System.IO.File]::Exists([string]$cloudConfig.cloudEndpointRulePath))

    $traySource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "devspace-watchdog-tray.ps1"), [System.Text.Encoding]::UTF8)
    $coreSource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "watchdog-control-core.ps1"), [System.Text.Encoding]::UTF8)
    $dashboardSource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "devspace-control-center.html"), [System.Text.Encoding]::UTF8)
    $installerSource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "install-devspace-watchdog-tray.ps1"), [System.Text.Encoding]::UTF8)
    $launcherSource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "run-devspace-watchdog-tray-hidden.vbs"), [System.Text.Encoding]::UTF8)
    Assert-Contains "dashboard binds loopback" $traySource '[System.Net.IPAddress]::Loopback'
    Assert-True "dashboard does not bind all interfaces" (-not $traySource.Contains("0.0.0.0"))
    Assert-Contains "dashboard checks Origin" $traySource 'Invalid Origin header.'
    Assert-Contains "dashboard checks control token" $traySource 'x-devspace-control-token'
    Assert-Contains "dashboard bounds request body" $traySource '$contentLength -gt 65536'
    Assert-True "dashboard avoids dynamic HTML injection" (-not $dashboardSource.Contains("innerHTML"))
    Assert-Contains "dashboard has Overview" $dashboardSource 'data-tab="overview"'
    Assert-Contains "dashboard has Control" $dashboardSource 'data-tab="control"'
    Assert-Contains "dashboard has Network and MCP" $dashboardSource 'data-tab="network"'
    Assert-Contains "dashboard has ngrok Setup" $dashboardSource 'data-tab="ngrok"'
    Assert-Contains "dashboard has Logs and Recovery" $dashboardSource 'data-tab="logs"'
    Assert-Contains "dashboard has optional tools" $dashboardSource 'id="optional-tools-panel"'
    Assert-Contains "dashboard supports OpenCodex Tray repair" $dashboardSource '/api/optional/repair'
    Assert-Contains "Tray has optional tools menu" $traySource 'ToolStripMenuItem("Optional tools")'
    Assert-Contains "Tray hides optional tools when absent" $traySource '$optionalMenu.Visible = $false'
    Assert-Contains "Stop All requires typed confirmation" $dashboardSource 'Type STOP ALL'
    Assert-Contains "config Apply requires typed confirmation" $dashboardSource 'Type APPLY'
    Assert-Contains "rollback requires typed confirmation" $dashboardSource 'Type ROLLBACK'
    Assert-Contains "backup UI shows before state" $dashboardSource 'Before\n${JSON.stringify(backup.before'
    $scriptMatch = [regex]::Match($dashboardSource.Replace("{{CONTROL_TOKEN}}", "test-token").Replace("{{DASHBOARD_PORT}}", "18777"), '(?s)<script>(.*?)</script>')
    Assert-True "dashboard script extracted" $scriptMatch.Success
    $javascriptPath = Join-Path $tempRoot "control-center.js"
    [System.IO.File]::WriteAllText($javascriptPath, $scriptMatch.Groups[1].Value, (New-Object System.Text.UTF8Encoding($false)))
    & node.exe --check $javascriptPath
    if ($LASTEXITCODE -ne 0) { throw "dashboard JavaScript syntax validation failed." }
    Assert-Contains "launcher uses STA" $launcherSource '-STA'
    Assert-Contains "launcher hides PowerShell" $launcherSource 'shell.Run command, 0, False'
    Assert-Contains "managed launches reuse hidden console" $coreSource 'NoNewWindow = $true'
    Assert-True "installer disables task only after readiness check" ($installerSource.IndexOf('if (-not $ready)') -lt $installerSource.IndexOf('Disable-ScheduledTask'))
    Assert-True "installer retains legacy task" (-not $installerSource.Contains("Unregister-ScheduledTask"))
    Assert-Contains "installer refuses unverified skip-start migration" $installerSource 'Tray migration cannot use -SkipStart'
    Assert-Contains "installer verifies exact PowerShell executable" $installerSource 'Test-WatchdogExecutablePath'

    Write-Host "watchdog control core, persistence, recovery, impact, security, backup, Tray, and installer tests passed."
} finally {
    $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
    $systemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedTemp.StartsWith($systemTemp, [System.StringComparison]::OrdinalIgnoreCase) -and [System.IO.Directory]::Exists($resolvedTemp)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
