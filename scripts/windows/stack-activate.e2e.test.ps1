[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

function Assert-StackE2E([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('devspace-stack-e2e-' + [guid]::NewGuid().ToString('N'))
$scriptRoot = Join-Path $testRoot 'scripts'
$installDir = Join-Path $testRoot 'installation'
$candidateRoot = Join-Path $testRoot 'candidate'
$oldManagementRoot = Join-Path $testRoot 'old-management'
$configPath = Join-Path $installDir 'devspace-watchdog.config.json'
$authPath = Join-Path $installDir 'auth.json'
$statePath = Join-Path $installDir 'watchdog-tray-state.json'
$oldCli = Join-Path $oldManagementRoot 'dist\cli.js'
$taskScript = Join-Path $installDir 'devspace-watchdog.ps1'
$taskConfig = Join-Path $installDir 'devspace-watchdog.config.json'
$powershellExe = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source

try {
    [void][IO.Directory]::CreateDirectory($scriptRoot)
    [void][IO.Directory]::CreateDirectory($installDir)
    [void][IO.Directory]::CreateDirectory($candidateRoot)
    [void][IO.Directory]::CreateDirectory((Split-Path $oldCli -Parent))
    foreach ($name in @('stack-activate.ps1', 'stack-operation.ps1', 'watchdog-control-core.ps1', 'watchdog-install-transaction.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $scriptRoot $name)
    }
    @('devspace-stack-setup.cjs', 'stack-management.cjs', 'stack-host-management.ps1', 'install-devspace-watchdog-tray.ps1') | ForEach-Object {
        $path = Join-Path $candidateRoot "scripts\windows\$_"
        [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
        [IO.File]::WriteAllText($path, '# candidate management fixture')
    }
    [IO.File]::WriteAllText($oldCli, '# original CLI')
    [IO.File]::WriteAllText((Join-Path $scriptRoot 'devspace-watchdog-bootstrap.ps1'), '[CmdletBinding()] param([string]$Mode, [string]$ConfigPath, [string]$RuntimeDirectory)')
    $installer = Join-Path $candidateRoot 'fail-installer.ps1'
    [IO.File]::WriteAllText($installer, @'
[CmdletBinding()]
param([string]$InstallDir, [string]$OriginalTransactionPath, [switch]$Confirm)
$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText((Join-Path $InstallDir 'candidate-touched.txt'), 'candidate ran after config activation')
throw 'forced activation failure'
'@)
    $config = [ordered]@{ stateDir=$installDir; cliPath=$oldCli; managementPackageRoot=$oldManagementRoot; nodePath=$powershellExe; custom=@{keep='yes'} }
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 20))
    [IO.File]::WriteAllText($authPath, '{"ownerToken":"preserve"}')
    [IO.File]::WriteAllText($statePath, '{"desired":{"devspace":"running"}}')
    [IO.File]::WriteAllText($taskScript, '# legacy task identity')

    $global:StackE2ETask = [pscustomobject]@{
        TaskName='DevSpaceNgrokWatchdog'; TaskPath='\'; State='Running';
        Settings=[pscustomobject]@{Enabled=$true};
        Actions=@([pscustomobject]@{Execute=$powershellExe; Arguments=(' -NoProfile -File "' + $taskScript + '" -ConfigPath "' + $taskConfig + '"')})
    }
    $global:StackE2ETaskEvents = @()
    function global:Get-ScheduledTask { [CmdletBinding()] param([string]$TaskName, [string]$TaskPath); if ($TaskName -and $TaskName -ne $global:StackE2ETask.TaskName) { return @() }; return $global:StackE2ETask }
    function global:Export-ScheduledTask { [CmdletBinding()] param([string]$TaskName, [string]$TaskPath); return '<Task><Settings><Enabled>true</Enabled></Settings></Task>' }
    function global:Disable-ScheduledTask { [CmdletBinding()] param([string]$TaskName, [string]$TaskPath); $global:StackE2ETask.Settings.Enabled=$false; $global:StackE2ETaskEvents += 'disable' }
    function global:Enable-ScheduledTask { [CmdletBinding()] param([string]$TaskName, [string]$TaskPath); $global:StackE2ETask.Settings.Enabled=$true; $global:StackE2ETaskEvents += 'enable' }
    function global:Stop-ScheduledTask { [CmdletBinding()] param([string]$TaskName, [string]$TaskPath); $global:StackE2ETask.State='Ready'; $global:StackE2ETaskEvents += 'stop' }
    function global:Start-ScheduledTask { [CmdletBinding()] param([string]$TaskName, [string]$TaskPath); $global:StackE2ETask.State='Running'; $global:StackE2ETaskEvents += 'start' }
    function global:Get-CimInstance { [CmdletBinding()] param([string]$ClassName, [string]$Filter); return @() }
    function global:Get-NetTCPConnection { [CmdletBinding()] param([int]$LocalPort, [string]$State); return @() }

    $candidate = [ordered]@{ kind='management'; componentId='devspace-tray-fork'; action='update'; root=$candidateRoot; runtimeRoot=$candidateRoot; installerPath=$installer }
    $candidatePath = Join-Path $testRoot 'candidate.json'
    [IO.File]::WriteAllText($candidatePath, ($candidate | ConvertTo-Json -Depth 20))
    $beforeConfig = [IO.File]::ReadAllBytes($configPath)
    $failure = $null
    try { & (Join-Path $scriptRoot 'stack-activate.ps1') -InstallDir $installDir -CandidatePath $candidatePath } catch { $failure = $_ }
    Assert-StackE2E ($null -ne $failure -and $failure.Exception.Message -match 'original configuration restored') 'Real activation failure did not enter the rollback path.'
    Assert-StackE2E ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq [Convert]::ToBase64String($beforeConfig)) 'Rollback did not restore the original configuration bytes.'
    $after = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Assert-StackE2E ($after.cliPath -eq $oldCli -and $after.managementPackageRoot -eq $oldManagementRoot -and $after.custom.keep -eq 'yes') 'Rollback changed the active runtime or unrelated settings.'
    Assert-StackE2E ($global:StackE2ETask.Settings.Enabled -and $global:StackE2ETask.State -eq 'Running') 'Rollback did not restore the prior scheduled-task state.'
    Assert-StackE2E ($global:StackE2ETaskEvents -contains 'disable' -and $global:StackE2ETaskEvents -contains 'enable' -and $global:StackE2ETaskEvents -contains 'stop' -and $global:StackE2ETaskEvents -contains 'start') 'The transaction did not exercise task stop/restore.'
    Assert-StackE2E ([IO.File]::Exists((Join-Path $installDir 'candidate-touched.txt'))) 'Failure fixture did not run after candidate activation.'
    Assert-StackE2E (-not [IO.File]::Exists((Join-Path $installDir 'stack-management\operation.lock')) -or [IO.File]::ReadAllText((Join-Path $installDir 'stack-management\operation.lock')) -eq '') 'Operation ownership was not released after rollback.'
    Write-Host 'stack-activate: real candidate activation failure restored config, task state and operation ownership.'
} finally {
    Remove-Variable StackE2ETask,StackE2ETaskEvents -Scope Global -ErrorAction SilentlyContinue
    foreach ($name in @('Get-ScheduledTask','Export-ScheduledTask','Disable-ScheduledTask','Enable-ScheduledTask','Stop-ScheduledTask','Start-ScheduledTask','Get-CimInstance','Get-NetTCPConnection')) { Remove-Item "function:\global:$name" -ErrorAction SilentlyContinue }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
