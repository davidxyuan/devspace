# Regression: auto-recovered strict process must pass semantic health without Windows listener PID.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'watchdog-control-core.ps1')
function Assert-True($name, $value) { if (-not $value) { throw "Assertion failed: $name" } }
$fakeDir = Join-Path ([IO.Path]::GetTempPath()) ('watchdog-strict-e2e-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fakeDir) | Out-Null
try {
    $fakeCli=Join-Path $fakeDir 'bin\cli.js'
    $config=[pscustomobject]@{
        devspaceEnabled=$true
        port=17977
        nodePath='C:\Program Files\nodejs\node.exe'
        cliPath=$fakeCli
        stateDir=$fakeDir
        machineSlug='strict-e2e'
    }
    $proc=[pscustomobject]@{
        Name='node.exe'
        ProcessId=424201
        ExecutablePath=$config.nodePath
        CommandLine=('"'+$config.nodePath+'" "'+$config.cliPath+'" serve')
        CreationDate=Get-Date
    }
    $savedListener=(Get-Item Function:Get-WatchdogListenOwners).ScriptBlock
    $savedTcp=(Get-Item Function:Test-WatchdogTcpPortReachable).ScriptBlock
    $savedJson=(Get-Item Function:Invoke-WatchdogJsonProbe).ScriptBlock
    $savedMcp=(Get-Item Function:Invoke-WatchdogMcpProbe).ScriptBlock
    try {
        Set-Item Function:Get-WatchdogListenOwners -Value {param([int]$Port) @()}
        Set-Item Function:Test-WatchdogTcpPortReachable -Value {param([int]$Port) $true}
        Set-Item Function:Invoke-WatchdogJsonProbe -Value {
            param($Url,$Predicate)
            [pscustomobject]@{semanticHealthy=$true;httpReachable=$true;error='';status=200}
        }
        Set-Item Function:Invoke-WatchdogMcpProbe -Value {
            param($Url,[switch]$Local)
            [pscustomobject]@{protocolHealthy=$true;httpReachable=$true;behavior='oauth_challenge';error=''}
        }
        $health=Get-WatchdogServiceHealth 'devspace' $config @($proc)
        Assert-True 'strict process healthy without listener PID' $health.healthy
        Assert-True 'listener PID remains unavailable' (-not $health.listenerFound)
        Assert-True 'exact strict+semantic evidence marked' ($health.healthEvidence -eq 'strict_process_and_protocol')
        Assert-True 'no indeterminate after semantic success' (-not $health.busyIndeterminate)
        Set-Item Function:Invoke-WatchdogMcpProbe -Value {
            param($Url,[switch]$Local)
            [pscustomobject]@{protocolHealthy=$false;httpReachable=$true;behavior='wrong';error='bad endpoint'}
        }
        $bad=Get-WatchdogServiceHealth 'devspace' $config @($proc)
        Assert-True 'wrong MCP protocol rejects health' (-not $bad.healthy)
        Assert-True 'wrong protocol stays indeterminate' $bad.busyIndeterminate
        Set-Item Function:Invoke-WatchdogMcpProbe -Value $savedMcp
        Set-Item Function:Get-WatchdogListenOwners -Value {param([int]$Port) @(424202)}
        $unknown=Get-WatchdogServiceHealth 'devspace' $config @($proc)
        Assert-True 'unknown listener must fail closed' ($unknown.identityConflict -and -not $unknown.healthy)
        Set-Item Function:Get-WatchdogListenOwners -Value {param([int]$Port) @()}
        $unknownCmd=[pscustomobject]@{
            Name=$proc.Name; ProcessId=$proc.ProcessId
            ExecutablePath=$proc.ExecutablePath
            CommandLine='node.exe unauthorized.js'; CreationDate=$proc.CreationDate
        }
        $unverified=Get-WatchdogServiceHealth 'devspace' $config @($unknownCmd)
        Assert-True 'unverified process cannot pass protocol fallback' (-not $unverified.healthy)
    } finally {
        Set-Item Function:Get-WatchdogListenOwners -Value $savedListener
        Set-Item Function:Test-WatchdogTcpPortReachable -Value $savedTcp
        Set-Item Function:Invoke-WatchdogJsonProbe -Value $savedJson
        Set-Item Function:Invoke-WatchdogMcpProbe -Value $savedMcp
    }
    Write-Output 'strict-recovery-identity regression PASS'
} finally {
    Remove-Item $fakeDir -Recurse -Force -ErrorAction SilentlyContinue
}
