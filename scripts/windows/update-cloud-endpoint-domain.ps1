[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$NewDomain,

    [string]$MachineName,

    [string]$StateDir = (Join-Path $env:USERPROFILE ".devspace"),

    [SecureString]$UpdateNgrokAuthToken,

    [switch]$DryRun,

    [Parameter(DontShow = $true)]
    [switch]$SkipServiceRestart,

    [Parameter(DontShow = $true)]
    [switch]$SkipPublicVerification,

    [Parameter(DontShow = $true)]
    [switch]$SimulateVerificationFailure
)

$ErrorActionPreference = "Stop"

function ConvertTo-SafeMachineSlug([string]$Value) {
    $slug = ([string]$Value).Trim().ToLowerInvariant()
    if (-not $slug -or $slug -notmatch '^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$') {
        throw "MachineName must contain only lowercase letters, digits, and internal hyphens."
    }
    return $slug
}

function ConvertTo-HttpsOrigin([string]$Value) {
    $candidate = ([string]$Value).Trim()
    if (-not $candidate) {
        throw "NewDomain cannot be empty."
    }
    if ($candidate -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $candidate = "https://$candidate"
    }

    $uri = $null
    if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri)) {
        throw "NewDomain is not a valid absolute HTTPS host or origin."
    }
    if ($uri.Scheme -ne "https") {
        throw "NewDomain must use HTTPS."
    }
    if ($uri.UserInfo) {
        throw "NewDomain must not contain user-info."
    }
    if ($uri.Query) {
        throw "NewDomain must not contain a query string."
    }
    if ($uri.Fragment) {
        throw "NewDomain must not contain a fragment."
    }
    if ($uri.AbsolutePath -and $uri.AbsolutePath -ne "/") {
        throw "NewDomain must not contain a path. Do not append /mcp."
    }
    if (-not $uri.Host -or [Uri]::CheckHostName($uri.Host) -eq [UriHostNameType]::Unknown) {
        throw "NewDomain must contain a valid host."
    }
    if (-not $uri.IsDefaultPort) {
        throw "NewDomain must not specify a custom port."
    }

    return "https://$($uri.IdnHost.ToLowerInvariant())"
}

function Join-OriginPath([string]$Origin, [string]$Path) {
    return $Origin.TrimEnd("/") + "/" + $Path.TrimStart("/")
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required file not found: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function ConvertTo-JsonText($Value, [int]$Depth = 20) {
    return ($Value | ConvertTo-Json -Depth $Depth) + [Environment]::NewLine
}

function Set-ObjectProperty($Object, [string]$Name, $Value) {
    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        $property.Value = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-UpdatedAllowedHosts($Existing, [string]$OldHost, [string]$NewHost) {
    $hosts = @()
    foreach ($item in @($Existing)) {
        $text = ([string]$item).Trim()
        if ($text -and $text -ne $OldHost) {
            $hosts += $text
        }
    }
    $hosts += $NewHost
    return @($hosts | Select-Object -Unique)
}

function Test-ExpectedRoutes($Config, [string]$MachineSlug) {
    $devspacePrefix = "/$MachineSlug/devspace_chatgpt"
    $hermesPrefix = "/$MachineSlug/hermes_chatgpt"
    $routes = @($Config.mcpRoutes)
    if (-not ($routes | Where-Object { [string]$_.prefix -eq $devspacePrefix -and [string]$_.service -eq "devspace" })) {
        throw "Watchdog config does not contain the expected DevSpace route: $devspacePrefix"
    }
    if (-not ($routes | Where-Object { [string]$_.prefix -eq $hermesPrefix -and [string]$_.service -eq "hermes" })) {
        throw "Watchdog config does not contain the expected Hermes route: $hermesPrefix"
    }
}

function Test-CloudEndpointFiles($Config, [string]$MachineSlug) {
    if ([string]$Config.ngrokEndpointMode -ne "CloudEndpoint") {
        return
    }
    foreach ($propertyName in @("cloudEndpointPolicyPath", "cloudEndpointRulePath")) {
        $path = [string]$Config.$propertyName
        if (-not $path -or -not (Test-Path -LiteralPath $path)) {
            throw "Cloud Endpoint file is missing: $propertyName"
        }
        $content = Get-Content -LiteralPath $path -Raw
        if ($content -notmatch [regex]::Escape("/$MachineSlug/")) {
            throw "Cloud Endpoint file does not preserve the /$MachineSlug/ routes: $path"
        }
        if ($content -notmatch "forward-internal") {
            throw "Cloud Endpoint file does not contain forward-internal: $path"
        }
    }
}

function Get-ActiveMetadataFiles([string]$Root, [string[]]$ExcludedPaths) {
    $excluded = @{}
    foreach ($path in $ExcludedPaths) {
        if ($path) {
            $excluded[[System.IO.Path]::GetFullPath($path).ToLowerInvariant()] = $true
        }
    }

    $patterns = @(
        "*oauth*.json", "*metadata*.json", "*resource*.json", "*issuer*.json",
        "*redirect*.json", "*endpoint*.json", "*router*.json"
    )
    $files = @()
    foreach ($pattern in $patterns) {
        $files += Get-ChildItem -LiteralPath $Root -File -Filter $pattern -ErrorAction SilentlyContinue
    }
    return @(
        $files |
            Where-Object {
                $_.Name -notmatch '(?i)(\.bak\.|\.backup\.|before-|\.log$)' -and
                -not $excluded.ContainsKey($_.FullName.ToLowerInvariant())
            } |
            Sort-Object FullName -Unique |
            Select-Object -ExpandProperty FullName
    )
}

function New-FilePlan(
    [string]$WatchdogConfigPath,
    [string]$DevSpaceConfigPath,
    $WatchdogConfig,
    [string]$OldOrigin,
    [string]$NewOrigin,
    [string]$OldHost,
    [string]$NewHost,
    [string]$DevSpacePublicBaseUrl
) {
    $plan = New-Object System.Collections.Generic.List[object]

    $updatedWatchdog = $WatchdogConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    Set-ObjectProperty $updatedWatchdog "publicBaseUrl" $DevSpacePublicBaseUrl
    Set-ObjectProperty $updatedWatchdog "allowedHosts" (Get-UpdatedAllowedHosts $updatedWatchdog.allowedHosts $OldHost $NewHost)
    if ([string]$updatedWatchdog.ngrokEndpointMode -eq "AgentEndpoint") {
        Set-ObjectProperty $updatedWatchdog "ngrokAgentBaseUrl" $NewOrigin
    }
    $plan.Add([pscustomobject]@{
        Path = $WatchdogConfigPath
        Content = ConvertTo-JsonText $updatedWatchdog 30
        Kind = "watchdog/router config"
    })

    $devspaceConfig = Read-JsonFile $DevSpaceConfigPath
    Set-ObjectProperty $devspaceConfig "publicBaseUrl" $DevSpacePublicBaseUrl
    if ($devspaceConfig.PSObject.Properties["allowedHosts"]) {
        Set-ObjectProperty $devspaceConfig "allowedHosts" (Get-UpdatedAllowedHosts $devspaceConfig.allowedHosts $OldHost $NewHost)
    }
    $plan.Add([pscustomobject]@{
        Path = $DevSpaceConfigPath
        Content = ConvertTo-JsonText $devspaceConfig 20
        Kind = "DevSpace config"
    })

    foreach ($propertyName in @("cloudEndpointPolicyPath", "cloudEndpointRulePath")) {
        $path = [string]$WatchdogConfig.$propertyName
        if ($path) {
            $content = Get-Content -LiteralPath $path -Raw
            $content = $content.Replace($OldOrigin, $NewOrigin).Replace($OldHost, $NewHost)
            $plan.Add([pscustomobject]@{
                Path = $path
                Content = $content
                Kind = "ngrok Cloud Endpoint policy/rule"
            })
        }
    }

    $explicitPaths = @($plan | Select-Object -ExpandProperty Path)
    foreach ($path in @(Get-ActiveMetadataFiles $StateDir $explicitPaths)) {
        $content = Get-Content -LiteralPath $path -Raw
        if ($content.Contains($OldOrigin) -or $content.Contains($OldHost)) {
            $content = $content.Replace($OldOrigin, $NewOrigin).Replace($OldHost, $NewHost)
            $plan.Add([pscustomobject]@{
                Path = $path
                Content = $content
                Kind = "OAuth/MCP metadata"
            })
        }
    }

    return @($plan | Sort-Object Path -Unique)
}

function New-Backup([object[]]$Plan, [string]$Root) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupDir = Join-Path $Root "cloud-endpoint-domain-backups\$stamp"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $records = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($item in $Plan) {
        $index++
        $leaf = [System.IO.Path]::GetFileName([string]$item.Path)
        $backupPath = Join-Path $backupDir ("{0:D2}-{1}" -f $index, $leaf)
        Copy-Item -LiteralPath $item.Path -Destination $backupPath -Force
        $records.Add([pscustomobject]@{ Original = [string]$item.Path; Backup = $backupPath })
    }
    $recordArray = $records.ToArray()
    $manifestPath = Join-Path $backupDir "manifest.json"
    $manifestText = ConvertTo-JsonText -Value $recordArray -Depth 10
    [System.IO.File]::WriteAllText($manifestPath, $manifestText, (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Directory = $backupDir; Records = $recordArray }
}

function Restore-Backup($Backup) {
    foreach ($record in @($Backup.Records)) {
        Copy-Item -LiteralPath $record.Backup -Destination $record.Original -Force
    }
}

function Write-FilePlan([object[]]$Plan) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($item in $Plan) {
        $path = [string]$item.Path
        $tempPath = "$path.tmp.$([Guid]::NewGuid().ToString('N'))"
        try {
            [System.IO.File]::WriteAllText($tempPath, [string]$item.Content, $utf8)
            Move-Item -LiteralPath $tempPath -Destination $path -Force
        } finally {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ListeningProcess([int]$Port) {
    $connection = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $connection) {
        return $null
    }
    return Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$connection.OwningProcess)" -ErrorAction SilentlyContinue
}

function Stop-ExpectedListener([int]$Port, [string]$ExpectedPath, [string]$Label) {
    if (-not $Port) {
        return
    }
    $process = Get-ListeningProcess $Port
    if (-not $process) {
        return
    }
    $commandLine = [string]$process.CommandLine
    if ($ExpectedPath -and $commandLine -notlike "*$ExpectedPath*") {
        throw "$Label port $Port is owned by an unexpected process (PID $($process.ProcessId)); refusing to stop it."
    }
    Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
}

function Stop-NgrokForHost([string]$NgrokPath, [string]$HostName) {
    if (-not $NgrokPath -or -not $HostName) {
        return
    }
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ([string]$_.ExecutablePath -eq $NgrokPath -or [string]$_.CommandLine -like "*$NgrokPath*") -and
        [string]$_.CommandLine -like "*$HostName*"
    })) {
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
    }
}

function Wait-ForListener([int]$Port, [int]$TimeoutSeconds = 45) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Get-ListeningProcess $Port) {
            return
        }
        Start-Sleep -Milliseconds 750
    } while ((Get-Date) -lt $deadline)
    throw "Port $Port did not return within $TimeoutSeconds seconds."
}

function Invoke-WatchdogOnce([string]$Root, [string]$WatchdogConfigPath) {
    $watchdogScript = Join-Path $Root "devspace-watchdog.ps1"
    if (-not (Test-Path -LiteralPath $watchdogScript)) {
        throw "Installed watchdog script not found: $watchdogScript"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watchdogScript -Once -ConfigPath $WatchdogConfigPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "The DevSpace watchdog failed to run once."
    }
}

function Restart-RequiredServices($Config, [string]$WatchdogConfigPath, [string]$OldHost) {
    $hermesBefore = Get-ListeningProcess ([int]$Config.hermesPort)
    Stop-ExpectedListener ([int]$Config.port) ([string]$Config.cliPath) "DevSpace"
    Stop-ExpectedListener ([int]$Config.routerPort) ([string]$Config.routerPath) "Router"
    if ([string]$Config.ngrokEndpointMode -eq "AgentEndpoint") {
        Stop-NgrokForHost ([string]$Config.ngrokPath) $OldHost
    }

    Invoke-WatchdogOnce $StateDir $WatchdogConfigPath
    Wait-ForListener ([int]$Config.port)
    Wait-ForListener ([int]$Config.routerPort)
    if ($Config.hermesEnabled -and $Config.hermesPort) {
        Wait-ForListener ([int]$Config.hermesPort)
        $hermesAfter = Get-ListeningProcess ([int]$Config.hermesPort)
        if ($hermesBefore -and $hermesAfter -and $hermesBefore.ProcessId -ne $hermesAfter.ProcessId) {
            Write-Warning "Hermes restarted even though the domain update did not request it."
        }
    }
}

function Invoke-HttpStatus([string]$Url, [int[]]$AllowedStatuses) {
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10
        $status = [int]$response.StatusCode
    } catch {
        if (-not $_.Exception.Response) {
            throw "HTTP request failed for ${Url}: $($_.Exception.Message)"
        }
        $status = [int]$_.Exception.Response.StatusCode.value__
    }
    if ($AllowedStatuses -notcontains $status) {
        throw "Unexpected HTTP $status from $Url"
    }
    return $status
}

function Test-McpHeaders([string]$Url) {
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    try {
        $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $Url)
        $request.Headers.TryAddWithoutValidation("Accept", "application/json, text/event-stream") | Out-Null
        $request.Headers.TryAddWithoutValidation("ngrok-skip-browser-warning", "true") | Out-Null
        $payload = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"devspace-domain-updater","version":"1.0"}}}'
        $request.Content = New-Object System.Net.Http.StringContent($payload, [System.Text.Encoding]::UTF8, "application/json")
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        if ($status -eq 404 -or $status -eq 429 -or $status -ge 500) {
            throw "MCP endpoint returned HTTP ${status}: $Url"
        }
        return $status
    } finally {
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Set-NgrokAuthtoken([string]$NgrokPath, [SecureString]$Token) {
    if (-not $Token) {
        return
    }
    if (-not $NgrokPath -or -not (Test-Path -LiteralPath $NgrokPath)) {
        throw "ngrok executable was not found; cannot update the authtoken."
    }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
    try {
        $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        & $NgrokPath config add-authtoken $plainText | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "ngrok config add-authtoken failed."
        }
    } finally {
        if ($plainText) { $plainText = $null }
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

$StateDir = [System.IO.Path]::GetFullPath($StateDir)
$watchdogConfigPath = Join-Path $StateDir "devspace-watchdog.config.json"
$devspaceConfigPath = Join-Path $StateDir "config.json"
$watchdogConfig = Read-JsonFile $watchdogConfigPath
$existingMachineSlug = ConvertTo-SafeMachineSlug ([string]$watchdogConfig.machineSlug)
$machineSlug = if ($MachineName) { ConvertTo-SafeMachineSlug $MachineName } else { $existingMachineSlug }
if ($machineSlug -ne $existingMachineSlug) {
    throw "MachineName '$machineSlug' does not match the installed machine '$existingMachineSlug'."
}

Test-ExpectedRoutes $watchdogConfig $machineSlug
Test-CloudEndpointFiles $watchdogConfig $machineSlug

$newOrigin = ConvertTo-HttpsOrigin $NewDomain
$oldPublicBaseUrl = ([string]$watchdogConfig.publicBaseUrl).TrimEnd("/")
$oldUri = [Uri]$oldPublicBaseUrl
$oldOrigin = $oldUri.GetLeftPart([UriPartial]::Authority).TrimEnd("/")
$oldHost = $oldUri.Host.ToLowerInvariant()
$newHost = ([Uri]$newOrigin).Host.ToLowerInvariant()
$devspacePublicBaseUrl = Join-OriginPath $newOrigin "/$machineSlug/devspace_chatgpt"
$hermesPublicBaseUrl = Join-OriginPath $newOrigin "/$machineSlug/hermes_chatgpt"
$devspaceMcpUrl = "$devspacePublicBaseUrl/mcp"
$hermesMcpUrl = "$hermesPublicBaseUrl/mcp"

$plan = New-FilePlan $watchdogConfigPath $devspaceConfigPath $watchdogConfig $oldOrigin $newOrigin $oldHost $newHost $devspacePublicBaseUrl

Write-Host "Old domain: $oldOrigin"
Write-Host "New domain: $newOrigin"
Write-Host "Machine: $machineSlug"
Write-Host "Files inspected/updated:"
foreach ($item in $plan) {
    Write-Host "- $($item.Path) [$($item.Kind)]"
}
Write-Host "DevSpace MCP URL:"
Write-Host $devspaceMcpUrl
Write-Host "Hermes MCP URL:"
Write-Host $hermesMcpUrl
if ($UpdateNgrokAuthToken) {
    Write-Host "ngrok authtoken update requested (value redacted)."
}

if ($DryRun) {
    Write-Host "Dry Run complete. No files were modified and no services were restarted."
    exit 0
}

$backup = $null
try {
    $backup = New-Backup $plan $StateDir
    Write-Host "Backup directory: $($backup.Directory)"
    Set-NgrokAuthtoken ([string]$watchdogConfig.ngrokPath) $UpdateNgrokAuthToken
    Write-FilePlan $plan

    $updatedConfig = Read-JsonFile $watchdogConfigPath
    Test-ExpectedRoutes $updatedConfig $machineSlug
    Test-CloudEndpointFiles $updatedConfig $machineSlug
    if ([string]$updatedConfig.publicBaseUrl -ne $devspacePublicBaseUrl) {
        throw "Updated watchdog publicBaseUrl is incorrect."
    }
    if (@($updatedConfig.allowedHosts) -notcontains $newHost) {
        throw "Updated watchdog allowedHosts does not contain $newHost."
    }

    if (-not $SkipServiceRestart) {
        Restart-RequiredServices $updatedConfig $watchdogConfigPath $oldHost
    }

    if ($SimulateVerificationFailure) {
        throw "Simulated verification failure."
    }

    if (-not $SkipPublicVerification) {
        Invoke-HttpStatus "http://127.0.0.1:$([int]$updatedConfig.routerPort)/__router/status" @(200) | Out-Null
        Invoke-HttpStatus "http://127.0.0.1:$([int]$updatedConfig.port)/healthz" @(200) | Out-Null
        $devspaceStatus = Test-McpHeaders $devspaceMcpUrl
        $hermesStatus = Test-McpHeaders $hermesMcpUrl
        Write-Host "Public MCP handshake status: DevSpace=$devspaceStatus Hermes=$hermesStatus"
    }
} catch {
    $failure = $_
    Write-Warning "Domain update failed: $($failure.Exception.Message)"
    if ($backup) {
        Restore-Backup $backup
        Write-Warning "Original files restored from $($backup.Directory)"
        if (-not $SkipServiceRestart) {
            try {
                $restoredConfig = Read-JsonFile $watchdogConfigPath
                Restart-RequiredServices $restoredConfig $watchdogConfigPath $newHost
            } catch {
                Write-Warning "Rollback files succeeded, but service recovery needs attention: $($_.Exception.Message)"
            }
        }
    }
    throw $failure
}

Write-Host "Cloud Endpoint domain update completed successfully."
Write-Host "DevSpace MCP URL:"
Write-Host $devspaceMcpUrl
Write-Host "Hermes MCP URL:"
Write-Host $hermesMcpUrl
Write-Host "In ChatGPT Apps, remove the old URLs and add these new /mcp URLs again so the tool schema is refreshed."
if (-not $UpdateNgrokAuthToken) {
    Write-Host "When changing ngrok accounts, run this only in a trusted local PowerShell session:"
    Write-Host "ngrok config add-authtoken <NEW_TOKEN>"
}
