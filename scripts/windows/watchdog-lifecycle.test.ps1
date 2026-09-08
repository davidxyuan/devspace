[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "watchdog-control-core.ps1")

function Assert-True([string]$Name, [bool]$Value) { if (-not $Value) { throw "$Name failed." } }
function Assert-Throws([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    try { & $Action; throw "$Name did not throw." }
    catch { if ($_.Exception.Message -notmatch $Pattern) { throw } }
}
function Read-TestAst([string]$Name) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name), [ref]$null, [ref]$errors)
    if ($errors.Count) { throw $errors[0].Message }
    return $ast
}

$bootstrapAst = Read-TestAst "devspace-watchdog-bootstrap.ps1"
$nativeStart = $bootstrapAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Start-HiddenNativeProcess" }, $true)
$launchStatement = $nativeStart.Body.EndBlock.Statements | Where-Object { $_.Extent.Text.Contains('[System.Diagnostics.Process]::Start($psi)') } | Select-Object -First 1
$savedOperationToken = $env:DEVSPACE_STACK_OPERATION_TOKEN
try {
    $env:DEVSPACE_STACK_OPERATION_TOKEN = "fixture-supervisor-token"
    $FilePath = "fixture.exe"; $Arguments = @(); $RuntimeDirectory = $PSScriptRoot
    foreach ($statement in $nativeStart.Body.EndBlock.Statements) {
        if ($statement.Extent.StartOffset -ge $launchStatement.Extent.StartOffset) { break }
        Invoke-Expression $statement.Extent.Text
    }
    Assert-True "persistent role and interactive launcher environment excludes manager token" (-not $psi.EnvironmentVariables.ContainsKey("DEVSPACE_STACK_OPERATION_TOKEN"))
    Assert-True "bootstrap keeps its own token until lease release" ($env:DEVSPACE_STACK_OPERATION_TOKEN -eq "fixture-supervisor-token")
} finally { $env:DEVSPACE_STACK_OPERATION_TOKEN = $savedOperationToken }
foreach ($name in @("Convert-NativeArgument", "Read-RoleHeartbeat", "Get-RoleProcesses", "Test-RoleHeartbeatFresh", "Test-RoleMutexExists", "Test-RoleRunning", "Assert-RoleStopped", "Remove-StaleHeartbeat", "Recover-StaleRole", "Stop-RoleFromHeartbeat", "Stop-RoleReliably", "Invoke-HostRepair", "Invoke-BootstrapRun")) {
    $definition = $bootstrapAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing function $name" }
    Invoke-Expression $definition.Extent.Text
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("devspace-lifecycle-test-" + [guid]::NewGuid().ToString("N"))
$heldMutex = $null
try {
    [void][IO.Directory]::CreateDirectory($tempRoot)
    $ConfigPath = Join-Path $tempRoot "devspace-watchdog.config.json"
    $hostScript = Join-Path $tempRoot "devspace-watchdog-tray.ps1"
    $trayScript = Join-Path $tempRoot "devspace-watchdog-tray-ui.ps1"
    $hostHeartbeatPath = Join-Path $tempRoot "watchdog-host-heartbeat.json"
    $trayHeartbeatPath = Join-Path $tempRoot "watchdog-tray-heartbeat.json"
    $powershell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $freshHeartbeatSeconds = 15
    $script:alive = $false
    $script:signals = 0
    $script:kills = 0
    $script:killError = $false
    $script:exitAfterKill = $true
    $script:inventory = @()
    function Get-CimInstance { return @($script:inventory | Where-Object { $script:alive }) }
    $script:childModes = @()
    function Start-HiddenWatchdogProcess { param($ScriptPath, $ChildMode) $script:signals++; $script:childModes += $ChildMode }
    function Get-Process { return $script:fakeProcess }
    function Write-TestHeartbeat([bool]$Busy = $false) {
        Write-WatchdogAtomicJson $hostHeartbeatPath ([pscustomobject]@{pid=42;timestamp=[DateTimeOffset]::UtcNow.ToString("o");sessionId=0;mutationInProgress=$Busy}) 5
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ConfigPath.ToLowerInvariant()))).Replace("-", "").Substring(0,20) }
    finally { $sha.Dispose() }
    $heldMutex = New-Object Threading.Mutex($true, "Local\DevSpaceWatchdogHost-$hash")
    Assert-True "role mutex proves liveness without heartbeat" (Test-RoleRunning $hostHeartbeatPath)
    Assert-Throws "live mutex blocks recovery without heartbeat" { Recover-StaleRole $hostHeartbeatPath } 'live without a valid heartbeat'
    Assert-True "missing heartbeat recovery never signals or launches" ($script:signals -eq 0)
    $heldMutex.ReleaseMutex(); $heldMutex.Dispose(); $heldMutex = $null

    $started = [datetime]::UtcNow.AddMinutes(-1)
    $script:inventory = @([pscustomobject]@{ProcessId=42;SessionId=0;ExecutablePath=$powershell;CreationDate=$started;CommandLine=('powershell.exe -File "' + $hostScript + '" -Mode Host -ConfigPath "' + $ConfigPath + '"')})
    $script:fakeProcess = [pscustomobject]@{StartTime=$started}
    $script:fakeProcess | Add-Member ScriptMethod Kill { $script:kills++; if ($script:killError) { throw "fixture access denied" }; if ($script:exitAfterKill) { $script:alive=$false } }
    $script:fakeProcess | Add-Member ScriptMethod WaitForExit { param($Timeout) return -not $script:alive }
    $script:fakeProcess | Add-Member ScriptMethod Dispose { }
    $script:alive = $true
    Write-TestHeartbeat
    Assert-True "cross-session exact Host identity is recognized" ((Get-RoleProcesses $hostHeartbeatPath).ProcessId -eq 42)
    Assert-True "Host does not count as Tray" (@(Get-RoleProcesses $trayHeartbeatPath).Count -eq 0)
    $originalCommand = $script:inventory[0].CommandLine

    # Use production argument serialization so the fixture matches actual launches.
    $quotedHostCommand = (@($powershell, "-File", $hostScript, "-Mode", "Host", "-ConfigPath", $ConfigPath) | ForEach-Object { Convert-NativeArgument $_ }) -join " "
    $script:inventory[0].CommandLine = $quotedHostCommand
    Assert-True "production quoted Host is recognized" ((Get-RoleProcesses $hostHeartbeatPath).ProcessId -eq 42)
    Assert-True "quoted Host heartbeat is fresh" (Test-RoleHeartbeatFresh $hostHeartbeatPath)
    Assert-True "quoted Host is live" (Test-RoleRunning $hostHeartbeatPath)
    Assert-Throws "quoted Host prevents stopped proof" { Assert-RoleStopped $hostHeartbeatPath } 'still running'
    Assert-True "fresh quoted Host needs no recovery" (Recover-StaleRole $hostHeartbeatPath)
    Assert-True "fresh Host recovery never signals stop" ($script:signals -eq 0)

    foreach ($parameter in @('-Mode', '"-Mode"')) {
        foreach ($quoteValue in @($false, $true)) {
            foreach ($roleMode in @("Host", "Stop", "StopHost")) {
                $valueToken = if ($quoteValue) { Convert-NativeArgument $roleMode } else { $roleMode }
                $script:inventory[0].CommandLine = $originalCommand.Replace('-Mode Host', "$parameter $valueToken")
                Assert-True "Host classification for $parameter $valueToken" (@(Get-RoleProcesses $hostHeartbeatPath).Count -eq [int]($roleMode -eq "Host"))
                Assert-True "Host and stop helpers never count as Tray for $parameter $valueToken" (@(Get-RoleProcesses $trayHeartbeatPath).Count -eq 0)
            }
        }
    }
    foreach ($roleScript in @($hostScript, $trayScript)) {
        foreach ($roleMode in @("Run", "Stop")) {
            $script:inventory[0].CommandLine = (@($powershell, "-File", $roleScript, "-Mode", $roleMode, "-ConfigPath", $ConfigPath) | ForEach-Object { Convert-NativeArgument $_ }) -join " "
            Assert-True "quoted $roleMode on $roleScript has correct Tray classification" (@(Get-RoleProcesses $trayHeartbeatPath).Count -eq [int]($roleMode -eq "Run"))
            Assert-True "Tray and stop helper never count as Host" (@(Get-RoleProcesses $hostHeartbeatPath).Count -eq 0)
        }
    }
    $script:inventory[0].CommandLine = $originalCommand.Replace(' -Mode Host', '')
    Assert-True "legacy default Run remains Tray" (@(Get-RoleProcesses $trayHeartbeatPath).Count -eq 1)
    foreach ($invalidMode in @('-Mode HostOther', '-ModeOther Host', '-Mode Run -Other Host')) {
        $script:inventory[0].CommandLine = $originalCommand.Replace('-Mode Host', $invalidMode)
        Assert-True "unrelated Host token does not match: $invalidMode" (@(Get-RoleProcesses $hostHeartbeatPath).Count -eq 0)
    }
    $script:inventory[0].CommandLine = $quotedHostCommand.Replace($hostScript, "$hostScript.other")
    Assert-True "sibling script path does not match either role" (@(Get-RoleProcesses $hostHeartbeatPath).Count -eq 0 -and @(Get-RoleProcesses $trayHeartbeatPath).Count -eq 0)
    $script:inventory[0].CommandLine = $quotedHostCommand
    $script:inventory[0].ExecutablePath = "$powershell.other"
    Assert-Throws "wrong executable cannot claim quoted Host" { Get-RoleProcesses $hostHeartbeatPath } 'Cannot verify watchdog process identity'
    $script:inventory[0].ExecutablePath = $powershell
    $script:inventory[0].CreationDate = $null
    Assert-Throws "missing creation time cannot claim quoted Host" { Get-RoleProcesses $hostHeartbeatPath } 'Cannot verify watchdog process identity'
    $script:inventory[0].CreationDate = $started
    $originalCommand = $quotedHostCommand
    $script:inventory[0].CommandLine = $originalCommand.Replace($ConfigPath, "$ConfigPath.other")
    Assert-True "different configuration does not match" (@(Get-RoleProcesses $hostHeartbeatPath).Count -eq 0)
    $script:inventory[0].CommandLine = $originalCommand
    $script:killError = $true
    Assert-Throws "failed kill propagates through graceful stop" { Stop-RoleReliably $hostHeartbeatPath $hostScript "StopHost" } 'fixture access denied'
    Assert-True "failed stop retains heartbeat and live process" ([IO.File]::Exists($hostHeartbeatPath) -and $script:alive)
    Assert-Throws "failed recovery cannot authorize relaunch" { Recover-StaleRole $hostHeartbeatPath 99 } 'fixture access denied'
    Assert-True "failed recovery preserves evidence" ([IO.File]::Exists($hostHeartbeatPath) -and $script:alive)
    $script:killError = $false
    $script:exitAfterKill = $false
    Assert-Throws "termination timeout is not exit proof" { Stop-RoleFromHeartbeat $hostHeartbeatPath } 'did not exit'
    Assert-True "termination timeout retains heartbeat" ([IO.File]::Exists($hostHeartbeatPath))
    Write-TestHeartbeat $true
    $beforeKills = $script:kills
    Assert-Throws "active mutation blocks forced stop" { Stop-RoleFromHeartbeat $hostHeartbeatPath } 'mutation is still draining'
    Assert-True "active mutation is not killed" ($script:kills -eq $beforeKills -and [IO.File]::Exists($hostHeartbeatPath))
    Write-TestHeartbeat
    $script:fakeProcess.StartTime = $started.AddSeconds(1)
    Assert-Throws "PID reuse blocks forced stop" { Stop-RoleFromHeartbeat $hostHeartbeatPath } 'PID was reused'
    Assert-True "PID reuse does not kill" ($script:kills -eq $beforeKills)
    $script:fakeProcess.StartTime = $started
    $script:exitAfterKill = $true
    Stop-RoleReliably $hostHeartbeatPath $hostScript "StopHost"
    Assert-True "proven exit removes heartbeat" (-not $script:alive -and -not [IO.File]::Exists($hostHeartbeatPath))

    $script:alive = $true
    $beforeKills = $script:kills
    Assert-Throws "missing heartbeat does not authorize a kill" { Stop-RoleFromHeartbeat $hostHeartbeatPath } 'without a valid heartbeat'
    $script:fakeProcess | Add-Member ScriptMethod WaitForExit { param($Timeout) $script:alive=$false; return $true } -Force
    Stop-RoleFromHeartbeat $hostHeartbeatPath
    Assert-True "heartbeat teardown race waits for exit without kill" (-not $script:alive -and $script:kills -eq $beforeKills)
    $script:fakeProcess | Add-Member ScriptMethod WaitForExit { param($Timeout) return -not $script:alive } -Force

    $script:alive = $true
    Write-TestHeartbeat
    $beforeKills = $script:kills
    Assert-True "wrong-session quoted Host is recovered" (-not (Recover-StaleRole $hostHeartbeatPath 99))
    Assert-True "quoted recovery stops the verified Host and removes heartbeat" ($script:kills -eq $beforeKills + 1 -and -not $script:alive -and -not [IO.File]::Exists($hostHeartbeatPath))

    # Execute the same locked RepairHost branch used by the queued Tray action.
    $script:lockBusy=$true; $script:leasesReleased=0
    function Enter-StackOperation { param($InstallDir) if ($script:lockBusy) { throw "fixture management is busy" }; return [pscustomobject]@{fixture=$true} }
    function Exit-StackOperation { param($Lease) if ($Lease) { $script:leasesReleased++ } }
    function Start-InteractiveWatchdogTray { throw "RepairHost must never touch Thin Tray" }
    $beforeSignals=$script:signals
    Assert-Throws "busy manager blocks repair before role mutation" { Invoke-BootstrapRun "RepairHost" } 'fixture management is busy'
    Assert-True "busy repair never signals or launches" ($script:signals -eq $beforeSignals)
    $script:lockBusy=$false; $script:alive=$true
    Write-TestHeartbeat $true
    $script:childModes=@()
    Assert-Throws "repair cannot relaunch while active mutation drains" { Invoke-BootstrapRun "RepairHost" } 'mutation is still draining'
    Assert-True "failed repair only signals Host and preserves evidence" ($script:childModes.Count -eq 1 -and $script:childModes[0] -eq "StopHost" -and $script:alive -and [IO.File]::Exists($hostHeartbeatPath))
    Assert-True "failed repair releases management lease" ($script:leasesReleased -eq 1)
    Write-TestHeartbeat
    $script:childModes=@()
    Invoke-BootstrapRun "RepairHost"
    Assert-True "repair starts Host only after proven exit" (($script:childModes -join ",") -eq "StopHost,Host" -and -not $script:alive -and -not [IO.File]::Exists($hostHeartbeatPath))
    Assert-True "successful repair releases management lease" ($script:leasesReleased -eq 2)
    $stopBranch = @($bootstrapAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$Mode -eq "Stop"' })[0]
    $lockedStop = @($stopBranch.Clauses[0].Item2.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })[0]
    Assert-True "direct Stop owns a management lease" ($null -ne $lockedStop)
    $script:lockBusy=$true; $beforeSignals=$script:signals
    Assert-Throws "busy manager blocks direct Stop" { Invoke-Expression $lockedStop.Extent.Text } 'fixture management is busy'
    Assert-True "blocked direct Stop never signals roles" ($script:signals -eq $beforeSignals)
    $script:lockBusy=$false

    $installerAst = Read-TestAst "install-devspace-watchdog-tray.ps1"
    $copyFunction = $installerAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Copy-InstallerFileWithRetry" }, $true)
    Invoke-Expression $copyFunction.Extent.Text
    $InstallDir = Join-Path $tempRoot "install"
    $backupPath = Join-Path $InstallDir "configuration-backups\fixture"
    $payloadPath = Join-Path $backupPath "payload"
    [void][IO.Directory]::CreateDirectory($payloadPath)
    $files = @("run-devspace-watchdog-tray-hidden.vbs")
    $retiredFiles = @("devspace-watchdog-tray-launcher.exe")
    [IO.File]::WriteAllText((Join-Path $InstallDir $files[0]), "old launcher calls native exe")
    [IO.File]::WriteAllText((Join-Path $InstallDir $retiredFiles[0]), "original native payload")
    $overwritten=@(); $createdTargets=@()
    $backupLoop = $installerAst.Find({ param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -eq "name" -and $node.Condition.Extent.Text -eq '@($files) + @($retiredFiles)' }, $true)
    Assert-True "installer backup loop found" ($null -ne $backupLoop)
    Invoke-Expression $backupLoop.Extent.Text
    Assert-True "retired payload is hash-backed before deletion" ($overwritten.Count -eq 2 -and $createdTargets.Count -eq 0)
    $retireLoop = $installerAst.Find({ param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -eq "retiredName" }, $true)
    Invoke-Expression $retireLoop.Extent.Text
    $retiredTarget = Join-Path $InstallDir $retiredFiles[0]
    Assert-True "retirement removes only backed-up payload" (-not [IO.File]::Exists($retiredTarget))
    $retiredBackups = @($overwritten | Where-Object { $_.name -in $retiredFiles })
    foreach ($scriptName in @("uninstall-devspace-watchdog-tray.ps1", "restore-old-watchdog.ps1")) {
        $consumerAst = Read-TestAst $scriptName
        $hashFunction = $consumerAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -match '^Get-(Tray|Restore)FileSha256$' }, $true)
        Invoke-Expression $hashFunction.Extent.Text
        $runningFunction = $consumerAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -match '^Test-(Restore)?TrayProcessRunning$' }, $true)
        Invoke-Expression $runningFunction.Extent.Text
        $checkBootstrap = Join-Path $InstallDir "devspace-watchdog-bootstrap.ps1"
        [IO.File]::WriteAllText($checkBootstrap, 'param($Mode, $ConfigPath) if ($Mode -ne "CheckStopped") { throw "wrong check mode" }; throw "fixture role remains live"')
        Assert-Throws "$scriptName independently checks role without heartbeat" { & $runningFunction.Name $InstallDir } 'fixture role remains live'
        [IO.File]::Delete($checkBootstrap)
        $restoreLoop = $consumerAst.Find({ param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -eq "original" -and $node.Body.Extent.Text.Contains('[System.IO.File]::Copy') }, $true)
        Assert-True "$scriptName retired restore loop found" ($null -ne $restoreLoop)
        Invoke-Expression $restoreLoop.Extent.Text
        Assert-True "$scriptName restores original launcher" ([IO.File]::ReadAllText($retiredTarget) -eq "original native payload")
        [IO.File]::WriteAllText($retiredTarget, "later unrelated file")
        Assert-Throws "$scriptName refuses later replacement" { Invoke-Expression $restoreLoop.Extent.Text } 'refusing to overwrite'
        Assert-True "$scriptName preserves later replacement" ([IO.File]::ReadAllText($retiredTarget) -eq "later unrelated file")
        [IO.File]::Delete($retiredTarget)
        $retiredBackupPath = Join-Path $payloadPath $retiredFiles[0]
        [IO.File]::WriteAllText($retiredBackupPath, "corrupt backup")
        Assert-Throws "$scriptName refuses corrupt backup" { Invoke-Expression $restoreLoop.Extent.Text } 'backup is missing or corrupt'
        [IO.File]::WriteAllText($retiredBackupPath, "original native payload")
    }
    $rollbackLoop = $installerAst.Find({ param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -eq "item" -and $node.Body.Extent.Text.Contains('Rollback backup is missing or corrupt') }, $true)
    Invoke-Expression $rollbackLoop.Extent.Text
    Assert-True "installer catch restores retired payload" ([IO.File]::ReadAllText($retiredTarget) -eq "original native payload")

    $invokeFunction = $installerAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-InstalledWatchdogBootstrap" }, $true)
    Invoke-Expression $invokeFunction.Extent.Text
    $oldBootstrap = Join-Path $InstallDir "devspace-watchdog-bootstrap.ps1"
    [IO.File]::WriteAllText($oldBootstrap, '[CmdletBinding()] param([ValidateSet("Run")][string]$Mode, [string]$ConfigPath)')
    Assert-True "rollback Run supports old bootstrap without RuntimeDirectory" (Invoke-InstalledWatchdogBootstrap "Run")
    [IO.File]::Delete($oldBootstrap)

    # Evaluate the real installer guards with no dashboard/heartbeat evidence,
    # but an independent lifecycle check reporting a live thin Tray.
    $installTry = @($installerAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })[0]
    $stopGuard = @($installTry.Body.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains('refusing deployment.') -and $_.Extent.Text.Contains('Invoke-InstalledWatchdogStop') })[0]
    $proofGuard = @($installTry.Body.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains('refusing deployment.') -and $_.Extent.Text.Contains('CheckStopped') })[0]
    Assert-True "stop and proof are unconditional top-level deployment guards" ($null -ne $stopGuard -and $null -ne $proofGuard)
    $script:stopCalls=0; $script:proofFails=$true; $script:deployReached=$false
    function Invoke-InstalledWatchdogStop { $script:stopCalls++; return $true }
    function Invoke-InstalledWatchdogBootstrap { param($Mode) if ($script:proofFails) { throw "fixture thin Tray remains live" }; return $true }
    $existingTrayWasRunning=$false
    Assert-Throws "live thin Tray blocks deploy without dashboard owner" {
        Invoke-Expression $stopGuard.Extent.Text
        Invoke-Expression $proofGuard.Extent.Text
        $script:deployReached=$true
    } 'fixture thin Tray remains live'
    Assert-True "host absence never skips stop or permits deployment" ($script:stopCalls -eq 1 -and -not $script:deployReached)
    $script:proofFails=$false
    Invoke-Expression $stopGuard.Extent.Text
    Invoke-Expression $proofGuard.Extent.Text

    $rollbackGuard = $installerAst.Find({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text.Contains('$rolesStopped -and') }, $true)
    Assert-True "rollback has independent exit proof guard" ($null -ne $rollbackGuard)
    $rolesStopped=$false; $trayStillRunning=$false; $hostStillRunning=$false; $remainingDashboardOwners=@()
    $script:autostartWrites=0
    function Enable-ScheduledTask { $script:autostartWrites++ }
    function Set-ItemProperty { $script:autostartWrites++ }
    function Remove-ItemProperty { $script:autostartWrites++ }
    [IO.File]::WriteAllText($retiredTarget, "live Tray payload must remain")
    Invoke-Expression $rollbackGuard.Extent.Text
    Assert-True "missing heartbeat and listener cannot permit rollback writes" ([IO.File]::ReadAllText($retiredTarget) -eq "live Tray payload must remain")
    Assert-True "failed stop does not restore old autostart or task" ($script:autostartWrites -eq 0)
    $rollbackCatch = $installTry.CatchClauses[0].Body
    $taskRestore = $rollbackCatch.Find({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq "Enable-ScheduledTask" }, $true)
    Assert-True "task restoration is inside proven-exit branch" ($taskRestore.Extent.StartOffset -gt $rollbackGuard.Extent.StartOffset -and $taskRestore.Extent.EndOffset -lt $rollbackGuard.Extent.EndOffset)

    # Execute the actual VBS parser with fake COM objects; Run only prints, never launches.
    $vbs = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "run-devspace-watchdog-tray-hidden.vbs"))
    $vbs = $vbs.Replace('CreateObject("WScript.Shell")', 'New TestShell').Replace('CreateObject("Scripting.FileSystemObject")', 'New TestFileSystem')
    $vbs += @'

Class TestShell
  Function ExpandEnvironmentStrings(value)
    ExpandEnvironmentStrings = "C:\Windows"
  End Function
  Function Run(command, style, wait)
    WScript.Echo command
    Run = 7
  End Function
End Class
Class TestFileSystem
  Function GetParentFolderName(value)
    GetParentFolderName = "C:\fixture"
  End Function
  Function FileExists(value)
    FileExists = True
  End Function
End Class
'@
    $vbsPath = Join-Path $tempRoot "launcher-fixture.vbs"
    [IO.File]::WriteAllText($vbsPath, $vbs)
    $output = & cscript.exe //NoLogo $vbsPath -Stop
    Assert-True "VBS Stop reaches bootstrap and propagates exit" ($LASTEXITCODE -eq 7 -and $output -match ' -Mode Stop -ConfigPath ')
    $output = & cscript.exe //NoLogo $vbsPath
    Assert-True "VBS starts persistent supervisor" ($LASTEXITCODE -eq 7 -and $output -match ' -Mode Watch -ConfigPath ')
    $output = & cscript.exe //NoLogo $vbsPath -Invalid
    Assert-True "VBS rejects invalid mode without launch" ($LASTEXITCODE -eq 5 -and -not $output)
    $global:LASTEXITCODE = 0
    Write-Host "watchdog lifecycle tests passed (mocked processes; temporary payload files only)."
} finally {
    if ($heldMutex) { $heldMutex.ReleaseMutex(); $heldMutex.Dispose() }
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedTemp.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedTemp).StartsWith("devspace-lifecycle-test-")) { Remove-Item -LiteralPath $resolvedTemp -Recurse -Force }
}
