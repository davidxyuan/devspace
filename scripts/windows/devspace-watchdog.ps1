param(
    [switch]$Once,
    [string]$ConfigPath
)

$ErrorActionPreference = "Continue"

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot "devspace-watchdog.config.json"
}

function Read-WatchdogConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Missing watchdog config: $ConfigPath"
    }
    Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
}

$config = Read-WatchdogConfig
$stateDir = [string]$config.stateDir
$port = [int]$config.port
$devspaceEnabled = if ($null -eq $config.devspaceEnabled) { $true } else { [bool]$config.devspaceEnabled }
$retiredPorts = @($config.retiredPorts)
$nodePath = [string]$config.nodePath
$cliPath = [string]$config.cliPath
$ngrokPath = [string]$config.ngrokPath
$publicBaseUrl = [string]$config.publicBaseUrl
$publicHost = ([Uri]$publicBaseUrl).Host
$ngrokAgentBaseUrl = if ($config.ngrokAgentBaseUrl) { [string]$config.ngrokAgentBaseUrl } else { $publicBaseUrl }
$ngrokAgentHost = ([Uri]$ngrokAgentBaseUrl).Host
$ngrokBinding = [string]$config.ngrokBinding
$ngrokManagedHosts = @($publicHost, $ngrokAgentHost) | Where-Object { $_ } | Select-Object -Unique
$manageNgrok = if ($null -eq $config.manageNgrok) { [bool]$ngrokPath } else { [bool]$config.manageNgrok }
$publicUpstreamPort = if ($config.publicUpstreamPort) { [int]$config.publicUpstreamPort } else { $port }
$upstream = "http://127.0.0.1:$publicUpstreamPort"
$routerPath = [string]$config.routerPath
$routerPort = if ($config.routerPort) { [int]$config.routerPort } else { 0 }
$hermesCommand = [string]$config.hermesCommand
$hermesPython = [string]$config.hermesPython
$hermesServer = [string]$config.hermesServer
$hermesWorkingDirectory = [string]$config.hermesWorkingDirectory
$hermesFullAccess = if ($null -eq $config.hermesFullAccess) { $false } else { [bool]$config.hermesFullAccess }
$hermesPort = if ($config.hermesPort) { [int]$config.hermesPort } else { 0 }
$hermesEnabled = if ($null -eq $config.hermesEnabled) { [bool]$hermesPort } else { [bool]$config.hermesEnabled }
$logPath = Join-Path $stateDir "devspace-watchdog.log"
$ngrokOutPath = Join-Path $stateDir "ngrok-watchdog.log"
$ngrokErrPath = Join-Path $stateDir "ngrok-watchdog.err.log"
$restartRequestPath = Join-Path $stateDir "restart-devspace.flag"
$stopPidRequestPath = Join-Path $stateDir "stop-pids.txt"
$mutexName = "Local\DevSpaceWatchdog-$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($stateDir)).Replace('+', '-').Replace('/', '_').TrimEnd('='))"

$env:PORT = "$port"
$env:DEVSPACE_TRUST_PROXY = "true"
$env:DEVSPACE_PUBLIC_BASE_URL = $publicBaseUrl

function Write-WatchdogLog([string]$message) {
    $timestamp = Get-Date -Format o
    $line = "$timestamp $message"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath) | Out-Null

    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $encoding = New-Object System.Text.UTF8Encoding($false)
            $stream = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $writer = New-Object System.IO.StreamWriter($stream, $encoding)
                try {
                    $writer.WriteLine($line)
                } finally {
                    $writer.Dispose()
                }
            } finally {
                $stream.Dispose()
            }
            return
        } catch {
            Start-Sleep -Milliseconds (100 * ($attempt + 1))
        }
    }
}

function Test-IsElevated {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Remove-LegacyScheduledTask {
    if (-not (Test-IsElevated)) {
        return
    }

    $legacyTaskName = "DevSpaceNgrokWatchdog"
    $legacyTask = Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
    if (-not $legacyTask) {
        return
    }

    try {
        Write-WatchdogLog "removing legacy scheduled task $legacyTaskName"
        Stop-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false -ErrorAction Stop
    } catch {
        Write-WatchdogLog "failed to remove legacy scheduled task ${legacyTaskName}: $($_.Exception.Message)"
    }
}

function Get-ProcessInfo([int]$processId) {
    if ($processId -le 0) {
        return $null
    }
    Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction SilentlyContinue
}

function Stop-ProcessTree([int]$processId, [string]$reason) {
    if ($processId -le 0 -or $processId -eq $PID) {
        return
    }
    $process = Get-ProcessInfo $processId
    if (-not $process) {
        return
    }
    Write-WatchdogLog "stopping PID $processId ($($process.Name)): $reason"
    try {
        Stop-Process -Id $processId -Force -ErrorAction Stop
    } catch {
        Write-WatchdogLog "Stop-Process failed for PID ${processId}: $($_.Exception.Message); trying taskkill"
        & taskkill.exe /PID $processId /T /F | Out-Null
    }
}

function Get-ListenOwners([int]$listenPort) {
    @(
        Get-NetTCPConnection -LocalPort $listenPort -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique |
            Where-Object { $_ -and $_ -ne 0 }
    )
}

function Is-DevSpaceServe($process) {
    if (-not $process -or $process.Name -ne "node.exe") {
        return $false
    }
    $cmd = [string]$process.CommandLine
    return $cmd -like "*$cliPath*" -and $cmd -match "serve"
}

function Stop-RetiredPortListeners {
    foreach ($retiredPort in $retiredPorts) {
        foreach ($ownerPid in Get-ListenOwners ([int]$retiredPort)) {
            $owner = Get-ProcessInfo $ownerPid
            if ($owner -and ($owner.Name -eq "node.exe" -or $owner.Name -eq "powershell.exe")) {
                Stop-ProcessTree $ownerPid "retired DevSpace port $retiredPort must be stopped"
            } else {
                Write-WatchdogLog "port $retiredPort is listening by non-DevSpace PID $ownerPid; leaving it alone"
            }
        }
    }
}

function Invoke-RestartIfRequested {
    if (-not (Test-Path -LiteralPath $restartRequestPath)) {
        return
    }

    Write-WatchdogLog "restart request detected; stopping managed DevSpace stack"
    foreach ($ownerPid in Get-ListenOwners $port) {
        Stop-ProcessTree $ownerPid "restart request for DevSpace port $port"
    }
    if ($hermesPort) {
        foreach ($ownerPid in Get-ListenOwners $hermesPort) {
            Stop-ProcessTree $ownerPid "restart request for Hermes port $hermesPort"
        }
    }
    if ($routerPort) {
        foreach ($ownerPid in Get-ListenOwners $routerPort) {
            Stop-ProcessTree $ownerPid "restart request for MCP router port $routerPort"
        }
    }

    $managedProcesses = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                (Is-DevSpaceServe $_) -or
                    ($hermesServer -and ([string]$_.CommandLine) -like "*$hermesServer*") -or
                    ($routerPath -and ([string]$_.CommandLine) -like "*$routerPath*") -or
                    (Is-NgrokForDevSpace $_)
            }
    )
    foreach ($proc in $managedProcesses) {
        Stop-ProcessTree $proc.ProcessId "restart request for managed DevSpace stack"
    }

    Remove-Item -LiteralPath $restartRequestPath -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Invoke-StopPidRequests {
    if (-not (Test-Path -LiteralPath $stopPidRequestPath)) {
        return
    }
    if (-not (Test-IsElevated)) {
        Write-WatchdogLog "stop-pids request found but watchdog is not elevated"
        return
    }

    $pidLines = @(Get-Content -LiteralPath $stopPidRequestPath -ErrorAction SilentlyContinue)
    foreach ($line in $pidLines) {
        $trimmed = ([string]$line).Trim()
        if (-not $trimmed) {
            continue
        }
        $requestedPid = 0
        if ([int]::TryParse($trimmed, [ref]$requestedPid)) {
            Stop-ProcessTree $requestedPid "administrator watchdog stop-pids request"
        } else {
            Write-WatchdogLog "ignoring invalid stop-pids entry: $trimmed"
        }
    }

    Remove-Item -LiteralPath $stopPidRequestPath -Force -ErrorAction SilentlyContinue
}

function Test-LocalDevSpace {
    try {
        Invoke-WebRequest -Uri "http://127.0.0.1:$port/mcp" -UseBasicParsing -TimeoutSec 5 | Out-Null
        return $true
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 401) {
            return $true
        }
        Write-WatchdogLog "local DevSpace health check failed: $($_.Exception.Message)"
        return $false
    }
}

function New-ServeLogPath([string]$kind) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Join-Path $stateDir "devspace-serve-$stamp.$kind.log"
}

function New-ProcessLogPath([string]$name, [string]$kind) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Join-Path $stateDir "$name-$stamp.$kind.log"
}

function Start-DevSpace {
    if (-not (Test-Path -LiteralPath $nodePath)) {
        Write-WatchdogLog "node executable missing: $nodePath"
        return
    }
    if (-not (Test-Path -LiteralPath $cliPath)) {
        Write-WatchdogLog "DevSpace CLI missing: $cliPath"
        return
    }

    $outPath = New-ServeLogPath "out"
    $errPath = New-ServeLogPath "err"
    Write-WatchdogLog "starting devspace serve on 127.0.0.1:$port; stdout=$outPath; stderr=$errPath"
    Start-Process `
        -FilePath $nodePath `
        -ArgumentList @($cliPath, "serve") `
        -WindowStyle Hidden `
        -RedirectStandardOutput $outPath `
        -RedirectStandardError $errPath | Out-Null
}

function Ensure-DevSpace {
    if (-not $devspaceEnabled) {
        return
    }

    Stop-RetiredPortListeners

    $listeners = @(Get-ListenOwners $port)
    if ($listeners.Count -gt 1) {
        $keep = $listeners[0]
        foreach ($extraPid in $listeners | Where-Object { $_ -ne $keep }) {
            Stop-ProcessTree $extraPid "extra listener on DevSpace port $port"
        }
        $listeners = @(Get-ListenOwners $port)
    }

    $serveProcesses = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { Is-DevSpaceServe $_ }
    )
    foreach ($proc in $serveProcesses) {
        if ($listeners -notcontains $proc.ProcessId) {
            Stop-ProcessTree $proc.ProcessId "extra devspace serve process not owning port $port"
        }
    }

    $listeners = @(Get-ListenOwners $port)
    if ($listeners.Count -eq 0) {
        Start-DevSpace
        Start-Sleep -Seconds 5
        if (-not (Test-LocalDevSpace)) {
            Write-WatchdogLog "DevSpace did not become healthy after start"
        }
        return
    }

    if (-not (Test-LocalDevSpace)) {
        foreach ($ownerPid in $listeners) {
            Stop-ProcessTree $ownerPid "unhealthy DevSpace listener on port $port"
        }
        Start-Sleep -Seconds 2
        Start-DevSpace
    }
}

function Test-HttpOk([string]$url) {
    try {
        Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 | Out-Null
        return $true
    } catch {
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode.value__
            return $status -ge 200 -and $status -lt 500
        }
        return $false
    }
}

function Start-Hermes {
    $outPath = New-ProcessLogPath "hermes-gpt" "out"
    $errPath = New-ProcessLogPath "hermes-gpt" "err"
    Write-WatchdogLog "starting hermes-gpt on 127.0.0.1:$hermesPort; stdout=$outPath; stderr=$errPath"

    if ($hermesPython -and $hermesServer -and (Test-Path -LiteralPath $hermesPython) -and (Test-Path -LiteralPath $hermesServer)) {
        $previousHermesHome = $env:HERMES_HOME
        $previousWrite = $env:HERMES_GPT_ENABLE_WRITE
        $previousMemoryWrite = $env:HERMES_GPT_ENABLE_MEMORY_WRITE
        $previousSessionSearch = $env:HERMES_GPT_ENABLE_SESSION_SEARCH
        $previousTerminal = $env:HERMES_GPT_ENABLE_TERMINAL
        $previousOperatorEnabled = $env:HERMES_GPT_OPERATOR_ENABLED
        $previousOperatorLevel = $env:HERMES_GPT_OPERATOR_LEVEL
        $previousOperatorApplyMode = $env:HERMES_GPT_OPERATOR_APPLY_MODE
        $previousOwnerAck = $env:HERMES_GPT_OWNER_ACK
        try {
            $env:HERMES_HOME = Join-Path $env:LOCALAPPDATA "hermes"
            if ($hermesFullAccess) {
                $env:HERMES_GPT_ENABLE_WRITE = "1"
                $env:HERMES_GPT_ENABLE_MEMORY_WRITE = "1"
                $env:HERMES_GPT_ENABLE_SESSION_SEARCH = "1"
                $env:HERMES_GPT_ENABLE_TERMINAL = "1"
                $env:HERMES_GPT_OPERATOR_ENABLED = "1"
                $env:HERMES_GPT_OPERATOR_LEVEL = "owner"
                $env:HERMES_GPT_OPERATOR_APPLY_MODE = "direct"
                $env:HERMES_GPT_OWNER_ACK = "I_UNDERSTAND_THIS_CAN_MUTATE_MY_MACHINE"
            } else {
                Remove-Item Env:\HERMES_GPT_ENABLE_WRITE -ErrorAction SilentlyContinue
                Remove-Item Env:\HERMES_GPT_ENABLE_MEMORY_WRITE -ErrorAction SilentlyContinue
                Remove-Item Env:\HERMES_GPT_ENABLE_SESSION_SEARCH -ErrorAction SilentlyContinue
                Remove-Item Env:\HERMES_GPT_ENABLE_TERMINAL -ErrorAction SilentlyContinue
                Remove-Item Env:\HERMES_GPT_OPERATOR_ENABLED -ErrorAction SilentlyContinue
                Remove-Item Env:\HERMES_GPT_OPERATOR_LEVEL -ErrorAction SilentlyContinue
                Remove-Item Env:\HERMES_GPT_OPERATOR_APPLY_MODE -ErrorAction SilentlyContinue
                Remove-Item Env:\HERMES_GPT_OWNER_ACK -ErrorAction SilentlyContinue
            }

            Start-Process `
                -FilePath $hermesPython `
                -ArgumentList @($hermesServer, "--http", "--host", "127.0.0.1", "--port", "$hermesPort") `
                -WorkingDirectory $(if ($hermesWorkingDirectory) { $hermesWorkingDirectory } else { Split-Path $hermesServer }) `
                -WindowStyle Hidden `
                -RedirectStandardOutput $outPath `
                -RedirectStandardError $errPath | Out-Null
        } finally {
            $env:HERMES_HOME = $previousHermesHome
            $env:HERMES_GPT_ENABLE_WRITE = $previousWrite
            $env:HERMES_GPT_ENABLE_MEMORY_WRITE = $previousMemoryWrite
            $env:HERMES_GPT_ENABLE_SESSION_SEARCH = $previousSessionSearch
            $env:HERMES_GPT_ENABLE_TERMINAL = $previousTerminal
            $env:HERMES_GPT_OPERATOR_ENABLED = $previousOperatorEnabled
            $env:HERMES_GPT_OPERATOR_LEVEL = $previousOperatorLevel
            $env:HERMES_GPT_OPERATOR_APPLY_MODE = $previousOperatorApplyMode
            $env:HERMES_GPT_OWNER_ACK = $previousOwnerAck
        }
        return
    }

    if (-not $hermesCommand -or -not (Test-Path -LiteralPath $hermesCommand)) {
        Write-WatchdogLog "Hermes command missing: $hermesCommand"
        return
    }

    Write-WatchdogLog "starting hermes-gpt through legacy command wrapper: $hermesCommand"
    Start-Process `
        -FilePath "cmd.exe" `
        -ArgumentList @("/c", "`"$hermesCommand`"") `
        -WindowStyle Hidden `
        -RedirectStandardOutput $outPath `
        -RedirectStandardError $errPath | Out-Null
}

function Ensure-Hermes {
    if (-not $hermesEnabled -or -not $hermesPort) {
        return
    }

    $listeners = @(Get-ListenOwners $hermesPort)
    if ($listeners.Count -eq 0) {
        Start-Hermes
        Start-Sleep -Seconds 4
    }
}

function Start-Router {
    if (-not $routerPath -or -not (Test-Path -LiteralPath $routerPath)) {
        Write-WatchdogLog "MCP router missing: $routerPath"
        return
    }

    $outPath = New-ProcessLogPath "mcp-router" "out"
    $errPath = New-ProcessLogPath "mcp-router" "err"
    Write-WatchdogLog "starting MCP router on 127.0.0.1:$routerPort; stdout=$outPath; stderr=$errPath"
    Start-Process `
        -FilePath $nodePath `
        -ArgumentList @($routerPath, $ConfigPath) `
        -WorkingDirectory (Split-Path $routerPath) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $outPath `
        -RedirectStandardError $errPath | Out-Null
}

function Ensure-Router {
    if (-not $routerPort) {
        return
    }

    $listeners = @(Get-ListenOwners $routerPort)
    if ($listeners.Count -eq 0) {
        Start-Router
        Start-Sleep -Seconds 2
    }

    if (-not (Test-HttpOk "http://127.0.0.1:$routerPort/__router/status")) {
        foreach ($ownerPid in Get-ListenOwners $routerPort) {
            Stop-ProcessTree $ownerPid "unhealthy MCP router on port $routerPort"
        }
        Start-Sleep -Seconds 1
        Start-Router
    }
}

function Is-NgrokForDevSpace($process) {
    if (-not $process -or $process.Name -ne "ngrok.exe") {
        return $false
    }
    $cmd = [string]$process.CommandLine
    if ($cmd -like "*$upstream*") {
        return $true
    }
    foreach ($hostName in $ngrokManagedHosts) {
        if ($cmd -like "*$hostName*") {
            return $true
        }
    }
    return $false
}

function Is-GoodNgrok($process) {
    if (-not (Is-NgrokForDevSpace $process)) {
        return $false
    }
    $cmd = [string]$process.CommandLine
    return $cmd -like "*$ngrokAgentHost*" -and $cmd -like "*$upstream*"
}

function Test-NgrokTunnel {
    try {
        $response = Invoke-RestMethod -Uri "http://127.0.0.1:4040/api/tunnels" -TimeoutSec 5
        foreach ($tunnel in @($response.tunnels)) {
            if ([string]$tunnel.public_url -eq $ngrokAgentBaseUrl -and [string]$tunnel.config.addr -eq $upstream) {
                return $true
            }
        }
    } catch {
        Write-WatchdogLog "ngrok API health check failed: $($_.Exception.Message)"
    }
    return $false
}

function Start-Ngrok {
    if (-not $ngrokPath -or -not (Test-Path -LiteralPath $ngrokPath)) {
        Write-WatchdogLog "ngrok executable missing: $ngrokPath"
        return
    }

    $ngrokArgs = @("http", $upstream)
    $ngrokArgs += @("--url", $ngrokAgentBaseUrl)
    if ($ngrokBinding) {
        $ngrokArgs += @("--binding", $ngrokBinding)
    }
    $ngrokArgs += @("--log", "stdout")

    Write-WatchdogLog "starting ngrok agent endpoint $ngrokAgentBaseUrl for public $publicBaseUrl -> $upstream"
    Start-Process `
        -FilePath $ngrokPath `
        -ArgumentList $ngrokArgs `
        -WorkingDirectory (Split-Path $ngrokPath) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $ngrokOutPath `
        -RedirectStandardError $ngrokErrPath | Out-Null
}

function Ensure-Ngrok {
    if (-not $manageNgrok) {
        return
    }

    $ngroks = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { Is-NgrokForDevSpace $_ }
    )
    $good = @($ngroks | Where-Object { Is-GoodNgrok $_ })
    $keepPid = $null
    if ($good.Count -gt 0) {
        $keepPid = $good[0].ProcessId
    }

    foreach ($proc in $ngroks) {
        if (-not $keepPid -or $proc.ProcessId -ne $keepPid) {
            Stop-ProcessTree $proc.ProcessId "duplicate or wrong ngrok tunnel for $ngrokAgentHost"
        }
    }

    if (Test-NgrokTunnel) {
        return
    }

    if ($keepPid) {
        Write-WatchdogLog "ngrok tunnel for $ngrokAgentHost is not healthy yet; keeping PID $keepPid so the agent can reconnect"
        return
    }

    foreach ($proc in $ngroks) {
        Stop-ProcessTree $proc.ProcessId "ngrok tunnel for $ngrokAgentHost is not healthy"
    }
    Start-Ngrok
}

function Invoke-WatchdogCycle {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $hasLock = $false
    try {
        $hasLock = $mutex.WaitOne(0)
        if (-not $hasLock) {
            return
        }

        Write-WatchdogLog "watchdog started as $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name); elevated=$(Test-IsElevated); mode=$(if ($Once) { "once" } else { "loop" }); port=$port; public=$publicBaseUrl"
        Remove-LegacyScheduledTask
        Invoke-StopPidRequests
        Invoke-RestartIfRequested
        Ensure-DevSpace
        Ensure-Hermes
        Ensure-Router
        Ensure-Ngrok
    } catch {
        Write-WatchdogLog "watchdog error: $($_.Exception.Message)"
    } finally {
        if ($hasLock) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

if ($Once) {
    Invoke-WatchdogCycle
    exit 0
}

while ($true) {
    Invoke-WatchdogCycle
    Start-Sleep -Seconds 10
}
