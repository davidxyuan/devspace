[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'watchdog-install-transaction.ps1')
function Assert-InstallTest([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('devspace-install-test-' + [guid]::NewGuid().ToString('N'))
$originalLocalAppData = $env:LOCALAPPDATA
$originalNgrokToken = $env:NGROK_AUTHTOKEN
try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $task = [pscustomobject]@{ TaskName='DevSpaceNgrokWatchdogUserPoller'; TaskPath='\'; State='Ready'; Settings=[pscustomobject]@{Enabled=$false}; Actions=@([pscustomobject]@{Execute='powershell.exe'; Arguments=('-NoProfile -File "' + (Join-Path $testRoot 'devspace-watchdog.ps1') + '" -Once -ConfigPath "' + (Join-Path $testRoot 'devspace-watchdog.config.json') + '"')}) }
    Assert-InstallTest (Test-InstallTaskIdentity $task $testRoot) 'Exact task identity was rejected.'
    Assert-InstallTest (-not (Test-InstallTaskIdentity $task ($testRoot + '-other'))) 'Other installation task was accepted.'
    $global:DevSpaceInstallerTestTask = $task
    $global:DevSpaceInstallerTaskEnabled = $false
    $global:DevSpaceInstallerTaskWrites = 0
    $global:DevSpaceInstallerProcesses = @()
    function Get-ScheduledTask { param($TaskName,$TaskPath) $global:DevSpaceInstallerTestTask }
    function Export-ScheduledTask { param($TaskName,$TaskPath) '<Task><Settings><Enabled>false</Enabled></Settings></Task>' }
    function Disable-ScheduledTask { param($TaskName,$TaskPath) $global:DevSpaceInstallerTaskEnabled=$false; $global:DevSpaceInstallerTaskWrites++ }
    function Enable-ScheduledTask { param($TaskName,$TaskPath) $global:DevSpaceInstallerTaskEnabled=$true; $global:DevSpaceInstallerTaskWrites++ }
    function Stop-ScheduledTask { param($TaskName,$TaskPath) throw 'Stopped task must not be started or stopped.' }
    function Start-ScheduledTask { param($TaskName,$TaskPath) throw 'Stopped task must not be started or stopped.' }
    function Get-NetTCPConnection { param($LocalPort,$State) @() }
    function Get-CimInstance { param($ClassName,$Filter) @($global:DevSpaceInstallerProcesses) }
    function schtasks.exe { throw 'Unexpected real scheduled-task creation path in isolated test.' }
    function Register-ScheduledTask { throw 'Unexpected scheduled-task registration in isolated test.' }
    $global:DevSpaceInstallerTaskRemoved = 0
    function Unregister-ScheduledTask { param($TaskName,$TaskPath,$Confirm) if ($TaskName -ne $global:DevSpaceInstallerTestTask.TaskName -or $TaskPath -ne '\') { throw 'Unexpected task deletion.' }; $global:DevSpaceInstallerTaskRemoved++ }
    $nodeExe = (Get-Command node.exe -ErrorAction Stop).Source
    $configPath = Join-Path $testRoot 'config.json'
    $watchdogPath = Join-Path $testRoot 'devspace-watchdog.config.json'
    $authPath = Join-Path $testRoot 'auth.json'
    $cli = Join-Path $testRoot 'cli.js'
    $ngrok = Join-Path $testRoot 'ngrok.cmd'
    [IO.File]::WriteAllText($ngrok, "@echo off`r`necho   --url URL`r`necho   --binding BINDING`r`necho   --web-addr ADDR`r`n")
    $env:NGROK_AUTHTOKEN = $null
    [IO.File]::WriteAllText($cli, '// reusable installed CLI')
    $config = @{host='127.0.0.1';port=17676;allowedRoots=@($testRoot);publicBaseUrl='https://example.test/custom/devspace';custom=@{nested=@{value='keep'}}}
    $watchdog = @{stateDir=$testRoot;machineSlug='original-machine';devspaceEnabled=$true;hermesEnabled=$false;port=17676;routerPort=18765;publicUpstreamPort=18765;nodePath=$nodeExe;cliPath=$cli;manageNgrok=$false;publicBaseUrl=$config.publicBaseUrl;ngrokEndpointMode='AgentEndpoint';ngrokAgentBaseUrl='https://example.test';mcpNameSuffix='custom';routeAliasMachineNames=@('old-alias');mcpRoutes=@(@{name='custom';service='devspace';prefix='/custom/devspace';targetHost='127.0.0.1';targetPort=17676;unknown='keep'});capabilities=@{devspace=@{toolMode='full';widgets='changes';skills=$true;subagents=$false;mcpTransport='stateless-json';futureFlag='keep'};hermes=@{}};controlCenter=@{dashboardPort=18777;futureSetting='keep'};futureSetting=@{deep=@{deeper=@{value='keep'}}}}
    $watchdog.ngrokPath = $ngrok
    $watchdog.manageNgrok = $true
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 30))
    [IO.File]::WriteAllText($watchdogPath, ($watchdog | ConvertTo-Json -Depth 30))
    [IO.File]::WriteAllText($authPath, '{"ownerToken":"private-original","otherCredential":"preserve"}')
    & (Join-Path $PSScriptRoot 'install-devspace-watchdog.ps1') -InstallDir $testRoot -Components DevSpace -UserMode -NoElevate -SkipStart -InstallTools -SkipNpmInstall
    $after = Get-Content -LiteralPath $watchdogPath -Raw | ConvertFrom-Json
    $afterConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $afterAuth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
    Assert-InstallTest ($after.port -eq 17676 -and $after.routerPort -eq 18765 -and $after.nodePath -eq $nodeExe -and $after.cliPath -eq $cli) 'Existing runtime ports/paths were replaced.'
    Assert-InstallTest ($after.ngrokPath -eq $ngrok) 'InstallTools replaced compatible ngrok instead of reusing it.'
    Assert-InstallTest ($after.capabilities.devspace.toolMode -eq 'full' -and $after.capabilities.devspace.skills -and $after.capabilities.devspace.futureFlag -eq 'keep') 'Capabilities were reset.'
    Assert-InstallTest ($after.mcpRoutes[0].prefix -eq '/custom/devspace' -and $after.mcpRoutes[0].unknown -eq 'keep' -and $after.controlCenter.futureSetting -eq 'keep') 'Routes/control settings were lost.'
    Assert-InstallTest ($after.futureSetting.deep.deeper.value -eq 'keep' -and $afterConfig.custom.nested.value -eq 'keep') 'Unknown nested configuration was truncated.'
    Assert-InstallTest ($afterConfig.publicBaseUrl -eq $config.publicBaseUrl -and $afterAuth.ownerToken -eq 'private-original' -and $afterAuth.otherCredential -eq 'preserve') 'Existing credentials or custom public URL changed.'
    Assert-InstallTest (-not $global:DevSpaceInstallerTaskEnabled) 'Disabled legacy task was enabled.'
    $quotedTask = [pscustomobject]@{Actions=@([pscustomobject]@{Execute=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe');Arguments=('"-File" "' + (Join-Path $testRoot 'devspace-watchdog.ps1') + '" "-ConfigPath" "' + (Join-Path $testRoot 'devspace-watchdog.config.json') + '"')})}
    Assert-InstallTest (Test-InstallTaskIdentity $quotedTask $testRoot) 'Quoted parameter names were rejected.'
    $quotedTask.Actions[0].Execute = Join-Path $testRoot 'powershell.exe'
    Assert-InstallTest (-not (Test-InstallTaskIdentity $quotedTask $testRoot)) 'Foreign executable with a trusted basename was accepted.'
    $born = [datetime]::UtcNow.AddMinutes(-1)
    $global:DevSpaceInstallerProcesses = @([pscustomobject]@{ProcessId=4242;Name='powershell.exe';ExecutablePath=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe');CreationDate=$born;CommandLine=($task.Actions[0].Arguments -replace ' -Once','')})
    $legacy = @(Get-InstallLegacyProcessSnapshots $testRoot)
    Assert-InstallTest ($legacy.Count -eq 1 -and -not $legacy[0].once) 'Detached legacy watchdog loop was not detected.'
    $global:DevSpaceInstallerFakeProcess = [pscustomobject]@{StartTime=$born.ToLocalTime()}
    $global:DevSpaceInstallerFakeProcess | Add-Member ScriptMethod Kill { $global:DevSpaceInstallerProcesses=@() }
    $global:DevSpaceInstallerFakeProcess | Add-Member ScriptMethod WaitForExit { param($Milliseconds) return $true }
    $global:DevSpaceInstallerFakeProcess | Add-Member ScriptMethod Dispose { }
    function Get-Process { param($Id) $global:DevSpaceInstallerFakeProcess }
    $legacyTransaction = Start-InstallTransaction $testRoot @() @() $legacy
    Stop-InstallLegacyProcesses $legacyTransaction
    Assert-InstallTest ($legacyTransaction.stoppedLegacyProcesses.Count -eq 1 -and $global:DevSpaceInstallerProcesses.Count -eq 0) 'Verified detached loop was not stopped and recorded for rollback.'
    $global:DevSpaceInstallerRestarts=@()
    function Start-Process { param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru)
        if ($WindowStyle -ne 'Hidden') { throw 'Legacy restart must be hidden.' }
        $global:DevSpaceInstallerRestarts += [pscustomobject]@{executable=$FilePath;arguments=$ArgumentList}
        $child = [pscustomobject]@{}
        $child | Add-Member ScriptMethod WaitForExit { param($Milliseconds) return $false }
        $child | Add-Member ScriptMethod Dispose { }
        return $child
    }
    Restart-InstallLegacyProcesses $legacyTransaction
    Assert-InstallTest ($global:DevSpaceInstallerRestarts.Count -eq 1 -and (Test-WatchdogCommandToken $global:DevSpaceInstallerRestarts[0].arguments (Join-Path $testRoot 'devspace-watchdog.config.json'))) 'Rollback did not restart the previously-running legacy loop with its exact configuration.'
    $global:DevSpaceInstallerProcesses = @([pscustomobject]@{ProcessId=4242;Name='powershell.exe';ExecutablePath=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe');CreationDate=$born.AddSeconds(1);CommandLine=($task.Actions[0].Arguments -replace ' -Once','')})
    try { Stop-InstallLegacyProcesses $legacyTransaction; throw 'Reused legacy PID accepted.' } catch { if ($_.Exception.Message -eq 'Reused legacy PID accepted.') { throw } }
    $global:DevSpaceInstallerProcesses=@()

    $saved = [IO.File]::ReadAllText($configPath)
    $created = Join-Path $testRoot 'created-runtime.txt'
    $transaction = Start-InstallTransaction $testRoot @($configPath,$created) @(Get-InstallTaskSnapshots $testRoot)
    Disable-InstallLegacyTasks $transaction
    [IO.File]::WriteAllText($configPath, 'changed')
    [IO.File]::WriteAllText($created, 'created')
    Undo-InstallTransaction $transaction
    Assert-InstallTest ([IO.File]::ReadAllText($configPath) -eq $saved -and -not [IO.File]::Exists($created) -and -not $global:DevSpaceInstallerTaskEnabled) 'Rollback failed to restore files and disabled task state.'
    [IO.File]::WriteAllText($transaction.files[0].backup, 'tampered')
    try { Undo-InstallTransaction $transaction; throw 'Corrupt backup accepted.' } catch { if ($_.Exception.Message -eq 'Corrupt backup accepted.') { throw } }
    $newTaskTransaction = Start-InstallTransaction $testRoot @() @()
    $newTaskTransaction.createdTasks = @([pscustomobject]@{name=$task.TaskName;path='\'})
    Undo-InstallTransaction $newTaskTransaction
    Assert-InstallTest ($global:DevSpaceInstallerTaskRemoved -eq 1) 'Rollback did not remove the exact newly-created task.'
    $parseErrors=$null
    $activationAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'stack-activate.ps1'), [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw $parseErrors[0].Message }
    $definition = $activationAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-StackCandidateConfiguration'}, $true)
    Invoke-Expression $definition.Extent.Text
    $candidateRoot = Join-Path $testRoot 'candidate'
    [void][IO.Directory]::CreateDirectory($candidateRoot)
    $candidateCli = Join-Path $candidateRoot 'cli.js'
    [IO.File]::WriteAllText($candidateCli, '// staged CLI')
    $candidate = [pscustomobject]@{kind='devspace';root=$candidateRoot;cliPath=$candidateCli;nodePath=$nodeExe}
    $change = Get-StackCandidateConfiguration $after $candidate
    Assert-InstallTest ($change.config.cliPath -eq $candidateCli -and $change.config.port -eq 17676 -and $change.config.capabilities.devspace.futureFlag -eq 'keep' -and $after.cliPath -eq $cli) 'Staged activation changed unrelated settings or mutated original configuration.'
    $candidate.cliPath = $cli
    try { Get-StackCandidateConfiguration $after $candidate | Out-Null; throw 'Outside candidate path accepted.' } catch { if ($_.Exception.Message -eq 'Outside candidate path accepted.') { throw } }
    Write-Host 'installer preservation, missing-only runtime reuse, task identity and rollback tests passed.'
} finally {
    Remove-Variable DevSpaceInstallerTestTask,DevSpaceInstallerTaskEnabled,DevSpaceInstallerTaskWrites,DevSpaceInstallerTaskRemoved,DevSpaceInstallerProcesses,DevSpaceInstallerFakeProcess,DevSpaceInstallerRestarts -Scope Global -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:NGROK_AUTHTOKEN = $originalNgrokToken
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
