param([Parameter(Mandatory)][string]$Prepared, [Parameter(Mandatory)][string]$ProfileHome,
      [Parameter(Mandatory)][string]$ReportPath, [Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:RUNNER_OS -cne 'Windows' -or $env:COMPUTERNAME -eq 'C02250073') {
    throw 'Paired Hermes validation requires a disposable GitHub-hosted Windows runner.'
}
. (Join-Path $PSScriptRoot 'watchdog-control-core.ps1')
function Assert-Pair([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
foreach ($path in @($Prepared,$ProfileHome,$ReportPath,$ConfigPath)) {
    Assert-Pair ([IO.Path]::GetFullPath($path).StartsWith([IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) 'Probe paths must stay inside the disposable runner directory.'
}
Assert-Pair (-not [IO.File]::Exists($ReportPath)) 'Previous probe evidence must be preserved.'
$preparation = Read-WatchdogJson (Join-Path $Prepared 'preparation.json')
$state = Read-WatchdogJson (Join-Path $ProfileHome '.devspace-gateway.json')
Assert-Pair ($preparation.state -eq 'prepared' -and $preparation.pair.state -eq 'verified') 'Pair preparation did not pass.'
Assert-Pair ($state.phase -eq 'running' -and [IO.Path]::GetFullPath($state.prepared) -eq [IO.Path]::GetFullPath($Prepared)) 'Gateway must be running the same prepared version.'
$verifiedOutput = & $preparation.python -I -B -X utf8 (Join-Path $PSScriptRoot 'hermes-gateway-supervisor.py') pair-config --prepared $Prepared --home $ProfileHome
Assert-Pair ($LASTEXITCODE -eq 0) 'Prepared pair changed; no GPT service may be started.'
$verifiedConfig = $verifiedOutput | ConvertFrom-Json
$config = Read-WatchdogJson $ConfigPath
$work = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ConfigPath))
Assert-Pair ($config.stateDir -eq $work) 'Probe configuration installation identity changed.'
foreach ($entry in $verifiedConfig.PSObject.Properties) {
    Assert-Pair ($config.($entry.Name) -ceq $entry.Value) "Configuration does not select the verified pair: $($entry.Name)"
}
$port = [int]$config.hermesPort
Assert-Pair ($port -gt 0 -and $port -le 65535 -and $config.hermesEnabled) 'Invalid paired probe endpoint.'
$observed = @{}
$report = @{head=$env:GITHUB_SHA;startedAt=[DateTimeOffset]::UtcNow.ToString('o');passed=$false;
    prepared=$Prepared;home=$ProfileHome;config=$config;gatewayBefore=$state.gateway;processes=@();
    scope='Real paired GPT started/stopped by Tray service functions alongside the selected Gateway on one disposable profile. Readonly loopback MCP; no production task or deployment.'}
$attempted = $false
try {
    foreach ($path in @($config.hermesPython,$config.hermesServer,$config.hermesAgentExe)) {
        Assert-Pair ([IO.File]::Exists($path)) "Prepared entry point is missing: $path"
    }
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    Assert-Pair (@($processes | Where-Object { Test-WatchdogManagedProcess $_ 'hermes' $config }).Count -eq 0) 'An existing GPT process must not be adopted.'
    $attempted = $true
    $started = Start-WatchdogManagedService 'hermes' $configPath $config
    Assert-Pair $started.success "Tray launch failed: $($started.error)"
    $report.launch = $started
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(90)
    do {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        $roots = @($processes | Where-Object { Test-WatchdogManagedProcess $_ 'hermes' $config })
        if ($roots.Count) {
            $ids = @(Get-WatchdogProcessTreeOrder @($roots | ForEach-Object { [int]$_.ProcessId }) $processes)
            foreach ($process in @($processes | Where-Object { [int]$_.ProcessId -in $ids })) {
                $key = "$($process.ProcessId):$($process.CreationDate.ToUniversalTime().Ticks)"
                $observed[$key] = @{pid=[int]$process.ProcessId;startUtc=$process.CreationDate.ToUniversalTime().ToString('o')}
            }
        }
        $health = Get-WatchdogServiceHealth 'hermes' $config $processes
        if ($health.healthy) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    $report.health = $health
    Assert-Pair $health.healthy "Tray did not verify paired GPT health: $($health.error)"
    $mcpReport = [IO.Path]::ChangeExtension($ReportPath, '.mcp.json')
    & $config.hermesPython -I -B -X utf8 (Join-Path $PSScriptRoot 'stack-hermes-mcp-smoke.py') $config.hermesServer $config.hermesAgentWorkingDirectory $mcpReport --url "http://127.0.0.1:$port/mcp" --home $ProfileHome
    Assert-Pair ($LASTEXITCODE -eq 0) 'Live paired MCP source, profile or readonly call verification failed.'
    $report.mcp = Read-WatchdogJson $mcpReport
    Assert-Pair $report.mcp.passed 'MCP probe did not finish.'
    $after = Read-WatchdogJson (Join-Path $ProfileHome '.devspace-gateway.json')
    Assert-Pair ($after.phase -eq 'running' -and $after.gateway.pid -eq $state.gateway.pid -and $after.gateway.startTime -eq $state.gateway.startTime) 'GPT validation replaced or stopped the Gateway.'
    $report.gatewayUnchanged = $true
    $report.passed = $true
} catch { $report.error=$_.Exception.Message; throw }
finally {
    try {
        if ($attempted) {
            $stopped = Stop-WatchdogManagedService 'hermes' $config
            Assert-Pair $stopped.success "Paired GPT cleanup failed: $($stopped.error)"
            $report.stop = $stopped
            $remaining = @(Get-CimInstance Win32_Process -ErrorAction Stop)
            $layer = Get-WatchdogProcessLayer 'hermes' $config $remaining
            Assert-Pair (-not $layer.listenerFound -and -not $layer.identityConflict -and @($remaining | Where-Object { Test-WatchdogManagedProcess $_ 'hermes' $config }).Count -eq 0) 'Paired GPT has not released its processes and listener.'
            foreach ($item in $observed.Values) {
                $current = @($remaining | Where-Object { [int]$_.ProcessId -eq $item.pid -and [Math]::Abs(($_.CreationDate.ToUniversalTime() - [datetime]$item.startUtc).Ticks) -lt 10 })
                Assert-Pair ($current.Count -eq 0) "Observed GPT child is still alive: $($item.pid)"
            }
            $report.observedProcessesExited = $true
        }
    } catch { $report.cleanupError=$_.Exception.Message; $report.passed=$false }
    $report.processes = @($observed.Values)
    $report.finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Write-WatchdogAtomicJson $ReportPath $report 30
    foreach ($log in @(Get-ChildItem -LiteralPath $work -Filter '*.log' -File)) {
        Copy-Item -LiteralPath $log.FullName -Destination ($ReportPath + '.' + $log.Name) -ErrorAction Stop
    }
}
Assert-Pair $report.passed 'Paired GPT validation or cleanup failed.'
