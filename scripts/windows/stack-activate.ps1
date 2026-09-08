[CmdletBinding()]
param([Parameter(Mandatory)][string]$InstallDir, [Parameter(Mandatory)][string]$CandidatePath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'watchdog-control-core.ps1')
. (Join-Path $PSScriptRoot 'watchdog-install-transaction.ps1')
. (Join-Path $PSScriptRoot 'stack-operation.ps1')

function Get-StackCandidateConfiguration($Config, $Candidate) {
    $next = ConvertTo-InstallMap $Config
    $service = ''
    $root = [IO.Path]::GetFullPath([string]$Candidate.root)
    if (-not [IO.Directory]::Exists($root)) { throw 'Staged candidate directory is missing.' }
    $runtimeRoot = if ($Candidate.runtimeRoot) { [IO.Path]::GetFullPath([string]$Candidate.runtimeRoot) } else { $root }
    if ($root -ne $runtimeRoot -and -not $root.StartsWith($runtimeRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Candidate payload is outside its staged runtime.' }
    $pathFields = @{}
    switch ([string]$Candidate.kind) {
        'devspace' { $service='devspace'; $pathFields['cliPath']=[string]$Candidate.cliPath; if ($Candidate.nodePath) { $pathFields['nodePath']=[string]$Candidate.nodePath } }
        'management' { if ($Candidate.componentId -ne 'devspace-tray-fork') { throw 'Unknown management component.' } }
        'hermes-gpt' { $service='hermes'; $pathFields['hermesPython']=[string]$Candidate.pythonPath; $pathFields['hermesServer']=[string]$Candidate.hermesServer; $next['hermesWorkingDirectory']=$root }
        'hermes-agent' { $pathFields['hermesAgentExe']=[string]$Candidate.hermesAgentExe; if ($Config.hermesEnabled) { $service='hermes' } }
        default { throw "Unsupported staged component kind: $($Candidate.kind)" }
    }
    if ($Candidate.componentId -eq 'devspace-tray-fork') {
        foreach ($required in @('devspace-stack-setup.cjs','stack-management.cjs','stack-host-management.ps1','install-devspace-watchdog-tray.ps1')) {
            if (-not [IO.File]::Exists((Join-Path $root "scripts\windows\$required"))) { throw "Staged fork is missing the complete management runtime: $required" }
        }
        $next['managementPackageRoot'] = $root
    }
    foreach ($entry in $pathFields.GetEnumerator()) {
        if (-not $entry.Value -or -not [IO.File]::Exists($entry.Value)) { throw "Staged component file is missing: $($entry.Key)" }
        $resolved = [IO.Path]::GetFullPath($entry.Value)
        $expectedRoot = if ($entry.Key -in @('hermesPython','hermesAgentExe')) { $runtimeRoot } else { $root }
        if ($entry.Key -ne 'nodePath' -and -not $resolved.StartsWith($expectedRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Staged component file is outside its candidate directory.' }
        $next[$entry.Key] = $resolved
    }
    if ($Candidate.action -eq 'install' -and $Candidate.kind -in @('devspace','hermes-gpt')) {
        $port = if ($service -eq 'devspace') { [int]$Config.port } else { [int]$Config.hermesPort }
        if ($port -lt 1 -or $port -gt 65535) { throw 'This component needs its ports and workspace settings configured in Setup first.' }
        if ($service -eq 'devspace') {
            $devspaceConfigPath = Join-Path ([string]$Config.stateDir) 'config.json'
            $devspaceSettings = Read-WatchdogJson $devspaceConfigPath
            if (-not $devspaceSettings -or -not @($devspaceSettings.allowedRoots).Count) { throw 'Configure DevSpace allowed workspaces in Setup before installing this component.' }
            $next['devspaceEnabled']=$true
        } else { $next['hermesEnabled']=$true }
    }
    return [pscustomobject]@{ config=$next; service=$service }
}

function Assert-StackServiceStopped([string]$Service, $Config) {
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $layer = Get-WatchdogProcessLayer $Service $Config $processes
    if ($layer.identityConflict -or $layer.listenerFound -or @($processes | Where-Object { Test-WatchdogManagedProcess $_ $Service $Config }).Count) { throw "Service $Service has not released its verified processes and listener." }
}

function Assert-StackServiceReady([string]$Service, $Config) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    do {
        $health = Get-WatchdogServiceHealth $Service $Config @(Get-CimInstance Win32_Process -ErrorAction Stop)
        if ($health.healthy) { return }
        Start-Sleep -Milliseconds 500
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Service $Service failed its local health check."
}

$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$configPath = Join-Path $InstallDir 'devspace-watchdog.config.json'
$lease = Enter-StackOperation $InstallDir
$transaction = $null
$controlStopped = $false
$serviceStopped = $false
$wasRunning = $false
$startCandidate = $false
$hostWasRunning = $false
$candidateActivated = $false
$config = $null
$change = $null
try {
    $config = Read-WatchdogJson $configPath
    if (-not $config -or [IO.Path]::GetFullPath([string]$config.stateDir) -ne $InstallDir) { throw 'Installed configuration identity is invalid.' }
    $candidate = Get-Content -LiteralPath $CandidatePath -Raw | ConvertFrom-Json
    $change = Get-StackCandidateConfiguration $config $candidate
    if ($change.service) {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        $layer = Get-WatchdogProcessLayer $change.service $config $processes
        if ($layer.identityConflict) { throw 'An unknown process owns the configured service port; update is blocked.' }
        $wasRunning = @($processes | Where-Object { Test-WatchdogManagedProcess $_ $change.service $config }).Count -gt 0
        $startCandidate = $wasRunning
        if ($candidate.action -eq 'install' -and $candidate.kind -in @('devspace','hermes-gpt')) {
            $desiredState = Read-WatchdogJson (Join-Path $InstallDir 'watchdog-tray-state.json')
            if ([string](Get-WatchdogProperty $desiredState.desired $change.service '') -ne 'stopped_by_user') { $startCandidate = $true }
        }
    }
    $tasks = @(Get-InstallTaskSnapshots $InstallDir)
    $legacyProcesses = @(Get-InstallLegacyProcessSnapshots $InstallDir)
    $transaction = Start-InstallTransaction $InstallDir @($configPath,(Join-Path $InstallDir 'config.json'),(Join-Path $InstallDir 'auth.json'),(Join-Path $InstallDir 'watchdog-tray-state.json')) $tasks $legacyProcesses
    Disable-InstallLegacyTasks $transaction
    Stop-InstallLegacyProcesses $transaction
    $bootstrap = Join-Path $PSScriptRoot 'devspace-watchdog-bootstrap.ps1'
    try { & $bootstrap -Mode CheckStopped -ConfigPath $configPath -RuntimeDirectory $InstallDir }
    catch { $hostWasRunning=$true }
    & $bootstrap -Mode Stop -ConfigPath $configPath -RuntimeDirectory $InstallDir
    & $bootstrap -Mode CheckStopped -ConfigPath $configPath -RuntimeDirectory $InstallDir
    $controlStopped = $true
    if ($change.service) {
        $result = Stop-WatchdogManagedService $change.service $config
        if (-not $result.success) { throw $result.error }
        Assert-StackServiceStopped $change.service $config
        $serviceStopped = $true
    }
    Write-WatchdogAtomicJson $configPath $change.config 40
    $candidateActivated = $true
    if ($startCandidate) {
        $result = Start-WatchdogManagedService $change.service $configPath $change.config
        if (-not $result.success) { throw $result.error }
        Assert-StackServiceReady $change.service $change.config
    }
    foreach ($task in $tasks) {
        if ($task.enabled) { Enable-ScheduledTask -TaskName $task.name -TaskPath $task.path -ErrorAction Stop | Out-Null }
        if ($task.running -and $task.enabled) { Start-ScheduledTask -TaskName $task.name -TaskPath $task.path -ErrorAction Stop }
    }
    if ($candidate.componentId -eq 'devspace-tray-fork' -and $candidate.installerPath) {
        $installer = [IO.Path]::GetFullPath([string]$candidate.installerPath)
        if (-not $installer.StartsWith([IO.Path]::GetFullPath([string]$candidate.root).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Candidate Tray installer is outside the staged package.' }
        & $installer -InstallDir $InstallDir -OriginalTransactionPath (Join-Path $transaction.backupPath 'transaction.json') -Confirm:$false
    } else {
        if ($hostWasRunning) { & (Join-Path $InstallDir 'devspace-watchdog-bootstrap.ps1') -Mode Run -ConfigPath $configPath }
        Restart-InstallLegacyProcesses $transaction
    }
    $transaction.completed=$true
    Write-Host "Staged $($candidate.componentId) activated; previous running/stopped state preserved. Backup: $($transaction.backupPath)"
} catch {
    $failure = $_
    if ($transaction -and -not $transaction.completed) {
        try {
            if ($controlStopped) {
                & (Join-Path $PSScriptRoot 'devspace-watchdog-bootstrap.ps1') -Mode Stop -ConfigPath $configPath -RuntimeDirectory $InstallDir
                & (Join-Path $PSScriptRoot 'devspace-watchdog-bootstrap.ps1') -Mode CheckStopped -ConfigPath $configPath -RuntimeDirectory $InstallDir
            }
            if ($serviceStopped -and $candidateActivated -and $change.service) {
                $stopped = Stop-WatchdogManagedService $change.service $change.config
                if (-not $stopped.success) { throw $stopped.error }
                Assert-StackServiceStopped $change.service $change.config
            }
            Undo-InstallTransaction $transaction
            Restart-InstallLegacyProcesses $transaction
            if ($serviceStopped -and $wasRunning) {
                $restored = Start-WatchdogManagedService $change.service $configPath $config
                if (-not $restored.success) { throw $restored.error }
                Assert-StackServiceReady $change.service $config
            }
            if ($controlStopped -and $hostWasRunning) { & (Join-Path $InstallDir 'devspace-watchdog-bootstrap.ps1') -Mode Run -ConfigPath $configPath }
        } catch { throw "ROLLBACK_FAILED: $($_.Exception.Message). Original failure: $($failure.Exception.Message). Backup: $($transaction.backupPath)" }
        throw "Component activation failed; original configuration restored. $($failure.Exception.Message)"
    }
    throw
} finally { Exit-StackOperation $lease }
