$script:WatchdogServiceNames = @("devspace", "hermes", "router", "ngrok")

function Get-WatchdogProperty($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Set-WatchdogProperty($Object, [string]$Name, $Value) {
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $Object.$Name = $Value
    }
}

function Copy-WatchdogObject($Value) {
    return ($Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
}

function ConvertTo-WatchdogIso([DateTimeOffset]$Value) {
    return $Value.ToUniversalTime().ToString("o")
}

function Get-WatchdogFileSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::Open([System.IO.Path]::GetFullPath($Path), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try { return [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace("-", "") }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Protect-WatchdogText([string]$Value, [int]$MaximumLength = 500) {
    if ([string]::IsNullOrEmpty($Value)) { return "" }
    $clean = $Value -replace "[\r\n\t]+", " "
    $clean = $clean -replace '(?i)(token|secret|password|passwd|api[_-]?key|authorization)\s*[:=]\s*[^ ,;]+', '$1=[redacted]'
    if ($clean.Length -gt $MaximumLength) { return $clean.Substring(0, $MaximumLength) }
    return $clean
}

function Write-WatchdogAtomicText([string]$Path, [string]$Text) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    if (-not [System.IO.Directory]::Exists($directory)) {
        [void][System.IO.Directory]::CreateDirectory($directory)
    }
    $temporary = Join-Path $directory ("." + [System.IO.Path]::GetFileName($fullPath) + "." + [Guid]::NewGuid().ToString("N") + ".tmp")
    $replacementBackup = Join-Path $directory ("." + [System.IO.Path]::GetFileName($fullPath) + "." + [Guid]::NewGuid().ToString("N") + ".bak")
    $encoding = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, $encoding)
        if ([System.IO.File]::Exists($fullPath)) {
            [System.IO.File]::Replace($temporary, $fullPath, $replacementBackup, $true)
            if ([System.IO.File]::Exists($replacementBackup)) { [System.IO.File]::Delete($replacementBackup) }
        } else {
            [System.IO.File]::Move($temporary, $fullPath)
        }
    } finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
        if ([System.IO.File]::Exists($replacementBackup)) { [System.IO.File]::Delete($replacementBackup) }
    }
}

function Write-WatchdogAtomicJson([string]$Path, $Value, [int]$Depth = 20) {
    Write-WatchdogAtomicText $Path (($Value | ConvertTo-Json -Depth $Depth) + [Environment]::NewLine)
}

function Read-WatchdogJson([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { throw "Missing JSON file: $Path" }
    return ([System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($Path), [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}

function Get-WatchdogOrigin([string]$Value, [string]$FieldName, [switch]$RequireInternal, [switch]$AllowPath) {
    try { $uri = [Uri]$Value } catch { throw "$FieldName must be a complete HTTPS origin." }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne "https" -or -not $uri.Host) {
        throw "$FieldName must be a complete HTTPS origin."
    }
    if ($uri.UserInfo -or $uri.Query -or $uri.Fragment -or (-not $AllowPath -and $uri.AbsolutePath -ne "/" -and $uri.AbsolutePath -ne "")) {
        throw "$FieldName cannot contain credentials, a path, query, or fragment."
    }
    if ($uri.Host -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$' -or $uri.Host -match '\.\.' -or
        $uri.Host -in @("localhost", "127.0.0.1", "::1")) {
        throw "$FieldName has an invalid public host."
    }
    if ($RequireInternal -and -not $uri.Host.EndsWith(".internal", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$FieldName must use an ngrok .internal host."
    }
    return $uri.GetLeftPart([System.UriPartial]::Authority).TrimEnd("/")
}

function Assert-WatchdogPort($Value, [string]$FieldName) {
    $portValue = 0
    if (-not [int]::TryParse([string]$Value, [ref]$portValue) -or $portValue -lt 1 -or $portValue -gt 65535) {
        throw "$FieldName must be an integer from 1 through 65535."
    }
    return $portValue
}

function Assert-WatchdogSlug([string]$Value, [string]$FieldName, [switch]$AllowEmpty) {
    $slug = ([string]$Value).Trim().ToLowerInvariant()
    if ($AllowEmpty -and -not $slug) { return "" }
    if ($slug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "$FieldName must contain lowercase letters, digits, and single hyphens only."
    }
    return $slug
}

function Assert-WatchdogRoutePath([string]$Value, [string]$FieldName) {
    $path = ([string]$Value).Trim()
    if ($path.Length -gt 160 -or $path -notmatch '^/[a-z0-9._~-]+(?:/[a-z0-9._~-]+)*$' -or
        $path.Contains("//") -or @($path.Split("/") | Where-Object { $_ -eq ".." }).Count -gt 0) {
        throw "$FieldName must be a lowercase absolute URL path without traversal, query, fragment, or shell characters."
    }
    return $path
}

function Assert-WatchdogDisplayName([string]$Value, [string]$FieldName) {
    $name = ([string]$Value).Trim()
    if (-not $name -or $name.Length -gt 64 -or $name -match '[\x00-\x1f\x7f]') {
        throw "$FieldName must contain 1 through 64 printable characters."
    }
    return $name
}

function Get-WatchdogPrimaryRoute($Config, [string]$Service) {
    $machineSlug = [string](Get-WatchdogProperty $Config "machineSlug" "")
    $routes = @(Get-WatchdogProperty $Config "mcpRoutes" @())
    $matching = @($routes | Where-Object { [string](Get-WatchdogProperty $_ "service" "") -eq $Service })
    if ($matching.Count -eq 0) { return $null }
    $machinePrefix = "/$machineSlug/"
    $primary = @($matching | Where-Object { ([string](Get-WatchdogProperty $_ "prefix" "")).StartsWith($machinePrefix, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
    if ($primary.Count) { return $primary[0] }
    return $matching[0]
}

function Get-WatchdogEditableConfig($Config) {
    $publicValue = [string](Get-WatchdogProperty $Config "publicBaseUrl" "")
    $publicOrigin = Get-WatchdogOrigin $publicValue "Public Domain" -AllowPath
    $machineSlug = Assert-WatchdogSlug ([string](Get-WatchdogProperty $Config "machineSlug" "")) "Machine Slug"
    $devspaceRoute = Get-WatchdogPrimaryRoute $Config "devspace"
    $hermesRoute = Get-WatchdogPrimaryRoute $Config "hermes"
    $control = Get-WatchdogProperty $Config "controlCenter" $null
    $labels = Get-WatchdogProperty $control "displayNames" $null
    return [pscustomobject][ordered]@{
        endpointMode = [string](Get-WatchdogProperty $Config "ngrokEndpointMode" "AgentEndpoint")
        publicDomain = $publicOrigin
        internalAgentEndpoint = [string](Get-WatchdogProperty $Config "ngrokAgentBaseUrl" $publicOrigin)
        ngrokInspectorPort = [int](Get-WatchdogProperty $Config "ngrokInspectorPort" 4040)
        routerPort = [int](Get-WatchdogProperty $Config "routerPort" 8765)
        machineSlug = $machineSlug
        mcpNameSuffix = [string](Get-WatchdogProperty $Config "mcpNameSuffix" "")
        devspaceDisplayName = [string](Get-WatchdogProperty $labels "devspace" ((Get-Culture).TextInfo.ToTitleCase($machineSlug) + " DevSpace"))
        hermesDisplayName = [string](Get-WatchdogProperty $labels "hermes" ((Get-Culture).TextInfo.ToTitleCase($machineSlug) + " Hermes"))
        devspaceRoutePath = if ($devspaceRoute) { [string](Get-WatchdogProperty $devspaceRoute "prefix" "/$machineSlug/devspace_chatgpt") } else { "/$machineSlug/devspace_chatgpt" }
        hermesRoutePath = if ($hermesRoute) { [string](Get-WatchdogProperty $hermesRoute "prefix" "/$machineSlug/hermes_chatgpt") } else { "/$machineSlug/hermes_chatgpt" }
    }
}

function ConvertTo-WatchdogEditableConfig($InputObject, $CurrentConfig) {
    if ($null -eq $InputObject) { throw "Configuration input is required." }
    $endpointMode = [string](Get-WatchdogProperty $InputObject "endpointMode" "")
    if ($endpointMode -notin @("AgentEndpoint", "CloudEndpoint")) { throw "Endpoint Mode must be AgentEndpoint or CloudEndpoint." }
    $publicDomain = Get-WatchdogOrigin ([string](Get-WatchdogProperty $InputObject "publicDomain" "")) "Public Domain"
    $internal = [string](Get-WatchdogProperty $InputObject "internalAgentEndpoint" "")
    if ($endpointMode -eq "CloudEndpoint") {
        $internal = Get-WatchdogOrigin $internal "Internal Agent Endpoint" -RequireInternal
    } else {
        $internal = $publicDomain
    }
    $inspectorPort = Assert-WatchdogPort (Get-WatchdogProperty $InputObject "ngrokInspectorPort" 0) "ngrok Inspector Port"
    $routerPort = Assert-WatchdogPort (Get-WatchdogProperty $InputObject "routerPort" 0) "Router Port"
    $machineSlug = Assert-WatchdogSlug ([string](Get-WatchdogProperty $InputObject "machineSlug" "")) "Machine Slug"
    $suffix = Assert-WatchdogSlug ([string](Get-WatchdogProperty $InputObject "mcpNameSuffix" "")) "MCP Name Suffix" -AllowEmpty
    $devspaceRoute = Assert-WatchdogRoutePath ([string](Get-WatchdogProperty $InputObject "devspaceRoutePath" "")) "DevSpace Route Path"
    $hermesRoute = Assert-WatchdogRoutePath ([string](Get-WatchdogProperty $InputObject "hermesRoutePath" "")) "Hermes Route Path"
    if ($devspaceRoute -eq $hermesRoute) { throw "DevSpace and Hermes route paths must be different." }
    $devspacePort = [int](Get-WatchdogProperty $CurrentConfig "port" 0)
    $hermesPort = [int](Get-WatchdogProperty $CurrentConfig "hermesPort" 0)
    $control = Get-WatchdogProperty $CurrentConfig "controlCenter" $null
    $dashboardPort = [int](Get-WatchdogProperty $control "dashboardPort" 8777)
    if (-not [bool](Get-WatchdogProperty $CurrentConfig "ngrokWebAddrSupported" $true) -and $inspectorPort -ne 4040) {
        throw "This ngrok build does not support --web-addr; ngrok Inspector Port must remain 4040."
    }
    $ports = @($devspacePort, $hermesPort, $routerPort, $inspectorPort, $dashboardPort) | Where-Object { $_ -gt 0 }
    if (@($ports | Group-Object | Where-Object { $_.Count -gt 1 }).Count) {
        throw "DevSpace, Hermes, Router, ngrok Inspector, and Dashboard ports must be distinct."
    }
    return [pscustomobject][ordered]@{
        endpointMode = $endpointMode
        publicDomain = $publicDomain
        internalAgentEndpoint = $internal
        ngrokInspectorPort = $inspectorPort
        routerPort = $routerPort
        machineSlug = $machineSlug
        mcpNameSuffix = $suffix
        devspaceDisplayName = Assert-WatchdogDisplayName ([string](Get-WatchdogProperty $InputObject "devspaceDisplayName" "")) "DevSpace Display Name"
        hermesDisplayName = Assert-WatchdogDisplayName ([string](Get-WatchdogProperty $InputObject "hermesDisplayName" "")) "Hermes Display Name"
        devspaceRoutePath = $devspaceRoute
        hermesRoutePath = $hermesRoute
    }
}

function New-WatchdogNgrokRule([string]$MachineSlug, [string]$InternalUrl, [string[]]$RoutePaths = @()) {
    $machinePrefix = "/$MachineSlug/"
    $authorizationPrefix = "/.well-known/oauth-authorization-server/$MachineSlug/"
    $resourcePrefix = "/.well-known/oauth-protected-resource/$MachineSlug/"
    $clauses = @(
        "req.url.path.startsWith(`"$machinePrefix`")",
        "req.url.path.startsWith(`"$authorizationPrefix`")",
        "req.url.path.startsWith(`"$resourcePrefix`")"
    )
    foreach ($candidate in @($RoutePaths | Select-Object -Unique)) {
        $route = Assert-WatchdogRoutePath $candidate "MCP Route Path"
        if ($route.StartsWith($machinePrefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        foreach ($prefix in @($route, "/.well-known/oauth-authorization-server$route", "/.well-known/oauth-protected-resource$route")) {
            $clauses += "req.url.path == `"$prefix`""
            $clauses += "req.url.path.startsWith(`"$prefix/`")"
        }
    }
    $expression = $clauses -join " || "
    return @"
- name: DevSpace $MachineSlug router
  expressions:
    - $expression
  actions:
    - type: forward-internal
      config:
        url: $InternalUrl
        binding: internal
"@
}

function New-WatchdogNgrokPolicy([string]$MachineSlug, [string]$InternalUrl, [string[]]$RoutePaths = @()) {
    $rule = New-WatchdogNgrokRule $MachineSlug $InternalUrl $RoutePaths
    return "on_http_request:`n" + ($rule -replace "(?m)^", "  ")
}

function Get-WatchdogGeneratedCloudFiles($Editable, [string]$StateDir) {
    if ([string](Get-WatchdogProperty $Editable "endpointMode" "") -ne "CloudEndpoint") { return @() }
    $slug = Assert-WatchdogSlug ([string](Get-WatchdogProperty $Editable "machineSlug" "")) "Machine Slug"
    $root = [System.IO.Path]::GetFullPath($StateDir)
    return @(
        [pscustomobject]@{ key="cloudEndpointPolicyPath"; name="ngrok-cloud-endpoint-$slug.policy.yml"; path=(Join-Path $root "ngrok-cloud-endpoint-$slug.policy.yml") },
        [pscustomobject]@{ key="cloudEndpointRulePath"; name="ngrok-cloud-endpoint-$slug.rule.yml"; path=(Join-Path $root "ngrok-cloud-endpoint-$slug.rule.yml") }
    )
}

function Get-WatchdogConfiguredCloudFiles($Config, [string]$StateDir) {
    $root = [System.IO.Path]::GetFullPath($StateDir)
    $files = @()
    foreach ($field in @("cloudEndpointPolicyPath", "cloudEndpointRulePath")) {
        $candidate = [string](Get-WatchdogProperty $Config $field "")
        if (-not $candidate) { continue }
        $full = [System.IO.Path]::GetFullPath($candidate)
        $name = [System.IO.Path]::GetFileName($full)
        if ([System.IO.Path]::GetDirectoryName($full) -ne $root -or $name -notmatch '^ngrok-cloud-endpoint-[a-z0-9]+(?:-[a-z0-9]+)*\.(policy|rule)\.yml$') {
            throw "$field must name a generated ngrok policy file directly under stateDir."
        }
        $files += [pscustomobject]@{ key=$field; name=$name; path=$full }
    }
    return $files
}

function New-WatchdogProposedConfig($CurrentConfig, $Editable) {
    $proposed = Copy-WatchdogObject $CurrentConfig
    $currentEditable = Get-WatchdogEditableConfig $CurrentConfig
    Set-WatchdogProperty $proposed "machineSlug" $Editable.machineSlug
    Set-WatchdogProperty $proposed "mcpNameSuffix" $Editable.mcpNameSuffix
    Set-WatchdogProperty $proposed "routerPort" ([int]$Editable.routerPort)
    Set-WatchdogProperty $proposed "publicUpstreamPort" ([int]$Editable.routerPort)
    Set-WatchdogProperty $proposed "ngrokInspectorPort" ([int]$Editable.ngrokInspectorPort)
    Set-WatchdogProperty $proposed "ngrokEndpointMode" $Editable.endpointMode
    Set-WatchdogProperty $proposed "ngrokAgentBaseUrl" $(if ($Editable.endpointMode -eq "CloudEndpoint") { $Editable.internalAgentEndpoint } else { $Editable.publicDomain })
    Set-WatchdogProperty $proposed "ngrokBinding" $(if ($Editable.endpointMode -eq "CloudEndpoint") { "internal" } else { "" })
    Set-WatchdogProperty $proposed "publicBaseUrl" ($Editable.publicDomain.TrimEnd("/") + $Editable.devspaceRoutePath)
    $control = Get-WatchdogProperty $proposed "controlCenter" $null
    if ($null -eq $control) { $control = [pscustomobject]@{} }
    Set-WatchdogProperty $control "displayNames" ([pscustomobject][ordered]@{ devspace=$Editable.devspaceDisplayName; hermes=$Editable.hermesDisplayName })
    Set-WatchdogProperty $proposed "controlCenter" $control

    $suffixText = if ($Editable.mcpNameSuffix) { "_" + $Editable.mcpNameSuffix } else { "" }
    foreach ($route in @(Get-WatchdogProperty $proposed "mcpRoutes" @())) {
        $service = [string](Get-WatchdogProperty $route "service" "")
        $prefix = [string](Get-WatchdogProperty $route "prefix" "")
        $isPrimary = ($service -eq "devspace" -and $prefix -eq $currentEditable.devspaceRoutePath) -or
            ($service -eq "hermes" -and $prefix -eq $currentEditable.hermesRoutePath)
        if ($isPrimary -and $service -eq "devspace") {
            Set-WatchdogProperty $route "prefix" $Editable.devspaceRoutePath
            Set-WatchdogProperty $route "name" ("devspace_chatgpt" + $suffixText)
        } elseif ($isPrimary -and $service -eq "hermes") {
            Set-WatchdogProperty $route "prefix" $Editable.hermesRoutePath
            Set-WatchdogProperty $route "name" ("hermes_chatgpt" + $suffixText)
        }
    }

    $stateDirValue = [string](Get-WatchdogProperty $proposed "stateDir" "")
    if (-not $stateDirValue) { throw "Watchdog configuration has no stateDir." }
    $stateDir = [System.IO.Path]::GetFullPath($stateDirValue)
    if ($Editable.endpointMode -eq "CloudEndpoint") {
        foreach ($file in Get-WatchdogGeneratedCloudFiles $Editable $stateDir) {
            Set-WatchdogProperty $proposed $file.key $file.path
        }
    } else {
        Set-WatchdogProperty $proposed "cloudEndpointPolicyPath" ""
        Set-WatchdogProperty $proposed "cloudEndpointRulePath" ""
    }
    return $proposed
}

function New-WatchdogConfigImpact($CurrentConfig, $RequestedEditable) {
    $current = Get-WatchdogEditableConfig $CurrentConfig
    $changes = @()
    $fields = [ordered]@{
        endpointMode = "Endpoint Mode"
        publicDomain = "Public Domain"
        internalAgentEndpoint = "Internal Agent Endpoint"
        ngrokInspectorPort = "ngrok Inspector Port"
        routerPort = "Router Port"
        machineSlug = "Machine Slug"
        mcpNameSuffix = "Internal MCP Name / Suffix"
        devspaceDisplayName = "DevSpace Display Name"
        hermesDisplayName = "Hermes Display Name"
        devspaceRoutePath = "DevSpace Route Path"
        hermesRoutePath = "Hermes Route Path"
    }
    foreach ($entry in $fields.GetEnumerator()) {
        $before = [string](Get-WatchdogProperty $current $entry.Key "")
        $after = [string](Get-WatchdogProperty $RequestedEditable $entry.Key "")
        if ($before -cne $after) {
            $changes += [pscustomobject]@{ field=$entry.Key; label=$entry.Value; before=$before; after=$after }
        }
    }
    $changedFields = @($changes | ForEach-Object { $_.field })
    $redFields = @("publicDomain", "devspaceRoutePath", "hermesRoutePath")
    $displayFields = @("devspaceDisplayName", "hermesDisplayName")
    $level = if (@($changedFields | Where-Object { $_ -in $redFields }).Count) { "RED" } elseif (@($changedFields | Where-Object { $_ -notin $displayFields }).Count) { "YELLOW" } else { "GREEN" }
    $restarts = @()
    if (@($changedFields | Where-Object { $_ -in @("publicDomain", "devspaceRoutePath", "machineSlug") }).Count) { $restarts += "devspace" }
    if (@($changedFields | Where-Object { $_ -in @("routerPort", "machineSlug", "mcpNameSuffix", "devspaceRoutePath", "hermesRoutePath") }).Count) { $restarts += "router" }
    if (@($changedFields | Where-Object { $_ -in @("endpointMode", "publicDomain", "internalAgentEndpoint", "ngrokInspectorPort", "routerPort", "machineSlug") }).Count) { $restarts += "ngrok" }
    $restarts = @($restarts | Select-Object -Unique)
    $dashboardAction = ($changedFields -contains "endpointMode") -or ($changedFields -contains "publicDomain") -or
        ($RequestedEditable.endpointMode -eq "CloudEndpoint" -and @($changedFields | Where-Object { $_ -in @("internalAgentEndpoint", "machineSlug", "devspaceRoutePath", "hermesRoutePath") }).Count -gt 0)
    return [pscustomobject][ordered]@{
        level = $level
        changes = $changes
        requiresServiceRestart = $restarts
        requiresNgrokDashboardAction = [bool]$dashboardAction
        requiresChatGptReconnect = ($level -eq "RED")
        oldDevSpaceUrl = $current.publicDomain.TrimEnd("/") + $current.devspaceRoutePath + "/mcp"
        newDevSpaceUrl = $RequestedEditable.publicDomain.TrimEnd("/") + $RequestedEditable.devspaceRoutePath + "/mcp"
        oldHermesUrl = $current.publicDomain.TrimEnd("/") + $current.hermesRoutePath + "/mcp"
        newHermesUrl = $RequestedEditable.publicDomain.TrimEnd("/") + $RequestedEditable.hermesRoutePath + "/mcp"
        trafficPolicy = if ($RequestedEditable.endpointMode -eq "CloudEndpoint") { New-WatchdogNgrokPolicy $RequestedEditable.machineSlug $RequestedEditable.internalAgentEndpoint @($RequestedEditable.devspaceRoutePath, $RequestedEditable.hermesRoutePath) } else { "" }
    }
}

function Get-WatchdogControlSettings($Config) {
    $control = Get-WatchdogProperty $Config "controlCenter" $null
    $settings = [pscustomobject][ordered]@{
        dashboardPort = Assert-WatchdogPort (Get-WatchdogProperty $control "dashboardPort" 8777) "Dashboard Port"
        localProbeSeconds = [int](Get-WatchdogProperty $control "localProbeSeconds" 5)
        publicProbeSeconds = [int](Get-WatchdogProperty $control "publicProbeSeconds" 45)
        failureThreshold = [int](Get-WatchdogProperty $control "failureThreshold" 2)
        maxRecoveryAttempts = [int](Get-WatchdogProperty $control "maxRecoveryAttempts" 5)
        backoffSeconds = @(Get-WatchdogProperty $control "backoffSeconds" @(0,10,30,60,120))
        logMaxBytes = [int](Get-WatchdogProperty $control "logMaxBytes" 2097152)
        historyLimit = [int](Get-WatchdogProperty $control "historyLimit" 500)
    }
    if ($settings.localProbeSeconds -lt 3 -or $settings.localProbeSeconds -gt 60) { throw "localProbeSeconds must be from 3 through 60." }
    if ($settings.publicProbeSeconds -lt 30 -or $settings.publicProbeSeconds -gt 600) { throw "publicProbeSeconds must be from 30 through 600." }
    if ($settings.failureThreshold -lt 2 -or $settings.failureThreshold -gt 10) { throw "failureThreshold must be from 2 through 10." }
    if ($settings.maxRecoveryAttempts -lt 1 -or $settings.maxRecoveryAttempts -gt 10) { throw "maxRecoveryAttempts must be from 1 through 10." }
    if ($settings.logMaxBytes -lt 65536 -or $settings.logMaxBytes -gt 16777216) { throw "logMaxBytes must be from 65536 through 16777216." }
    if ($settings.historyLimit -lt 50 -or $settings.historyLimit -gt 5000) { throw "historyLimit must be from 50 through 5000." }
    $backoff = @()
    foreach ($value in $settings.backoffSeconds) {
        $seconds = 0
        if (-not [int]::TryParse([string]$value, [ref]$seconds) -or $seconds -lt 0 -or $seconds -gt 3600) { throw "backoffSeconds entries must be from 0 through 3600." }
        $backoff += $seconds
    }
    if ($backoff.Count -eq 0) { throw "backoffSeconds cannot be empty." }
    for ($i = 1; $i -lt $backoff.Count; $i++) {
        if ($backoff[$i] -lt $backoff[$i - 1]) { throw "backoffSeconds must be nondecreasing." }
    }
    $settings.backoffSeconds = $backoff
    return $settings
}

function New-WatchdogRecoveryRecord {
    return [pscustomobject][ordered]@{
        phase = "Checking"
        consecutiveFailures = 0
        attemptCount = 0
        lastError = ""
        lastRecoveryUtc = $null
        nextRetryUtc = $null
        lastHealthyUtc = $null
    }
}

function New-WatchdogState($Config, [switch]$SafeMode) {
    $desired = [ordered]@{}
    $recovery = [ordered]@{}
    foreach ($service in $script:WatchdogServiceNames) {
        $desired[$service] = "running"
        $recovery[$service] = New-WatchdogRecoveryRecord
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        desired = [pscustomobject]$desired
        maintenanceMode = [bool]$SafeMode
        recovery = [pscustomobject]$recovery
        updatedUtc = ConvertTo-WatchdogIso ([DateTimeOffset]::UtcNow)
        stateLoadError = ""
    }
}

function Repair-WatchdogState($State, $Config) {
    if ($null -eq $State) { return New-WatchdogState $Config }
    $desired = Get-WatchdogProperty $State "desired" $null
    if ($null -eq $desired) { $desired = [pscustomobject]@{}; Set-WatchdogProperty $State "desired" $desired }
    $recovery = Get-WatchdogProperty $State "recovery" $null
    if ($null -eq $recovery) { $recovery = [pscustomobject]@{}; Set-WatchdogProperty $State "recovery" $recovery }
    foreach ($service in $script:WatchdogServiceNames) {
        $value = [string](Get-WatchdogProperty $desired $service "running")
        if ($value -notin @("running", "stopped_by_user")) { throw "Invalid desired state for $service." }
        Set-WatchdogProperty $desired $service $value
        $record = Get-WatchdogProperty $recovery $service $null
        if ($null -eq $record) {
            Set-WatchdogProperty $recovery $service (New-WatchdogRecoveryRecord)
        } else {
            $template = New-WatchdogRecoveryRecord
            foreach ($property in $template.PSObject.Properties) {
                if ($null -eq $record.PSObject.Properties[$property.Name]) { Set-WatchdogProperty $record $property.Name $property.Value }
            }
            if ([int]$record.consecutiveFailures -lt 0 -or [int]$record.attemptCount -lt 0) { throw "Invalid recovery counters for $service." }
        }
    }
    Set-WatchdogProperty $State "schemaVersion" 1
    Set-WatchdogProperty $State "maintenanceMode" ([bool](Get-WatchdogProperty $State "maintenanceMode" $false))
    Set-WatchdogProperty $State "stateLoadError" ([string](Get-WatchdogProperty $State "stateLoadError" ""))
    return $State
}

function Read-WatchdogState([string]$Path, $Config) {
    if (-not [System.IO.File]::Exists($Path)) { return New-WatchdogState $Config }
    try {
        return Repair-WatchdogState (Read-WatchdogJson $Path) $Config
    } catch {
        $safe = New-WatchdogState $Config -SafeMode
        $safe.stateLoadError = Protect-WatchdogText $_.Exception.Message
        return $safe
    }
}

function Save-WatchdogState([string]$Path, $State) {
    $State.updatedUtc = ConvertTo-WatchdogIso ([DateTimeOffset]::UtcNow)
    Write-WatchdogAtomicJson $Path $State 20
}

function Set-WatchdogDesiredState($State, [string]$Service, [string]$Desired) {
    if ($Service -notin $script:WatchdogServiceNames) { throw "Unknown service: $Service" }
    if ($Desired -notin @("running", "stopped_by_user")) { throw "Invalid desired state: $Desired" }
    Set-WatchdogProperty $State.desired $Service $Desired
    if ($Desired -eq "running") {
        Set-WatchdogProperty $State.recovery $Service (New-WatchdogRecoveryRecord)
    } else {
        $record = Get-WatchdogProperty $State.recovery $Service (New-WatchdogRecoveryRecord)
        $record.phase = "ManualStop"
        $record.nextRetryUtc = $null
        Set-WatchdogProperty $State.recovery $Service $record
    }
}

function Reset-WatchdogRecoveryForRetry($State, [string]$Service) {
    if ($Service -notin $script:WatchdogServiceNames) { throw "Unknown service: $Service" }
    Set-WatchdogProperty $State.desired $Service "running"
    Set-WatchdogProperty $State.recovery $Service (New-WatchdogRecoveryRecord)
}

function Update-WatchdogRecoveryDecision($State, [string]$Service, $Health, $Settings, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow) {
    $record = Get-WatchdogProperty $State.recovery $Service $null
    if ($null -eq $record) { $record = New-WatchdogRecoveryRecord; Set-WatchdogProperty $State.recovery $Service $record }
    $desired = [string](Get-WatchdogProperty $State.desired $Service "running")
    if ($desired -eq "stopped_by_user") {
        $record.phase = "ManualStop"; $record.nextRetryUtc = $null
        return [pscustomobject]@{ action="None"; reason="stopped_by_user"; record=$record }
    }
    if ([bool]$State.maintenanceMode) {
        $record.phase = "Maintenance"; $record.nextRetryUtc = $null
        return [pscustomobject]@{ action="None"; reason="maintenance"; record=$record }
    }
    if ([bool](Get-WatchdogProperty $Health "healthy" $false)) {
        $record.phase = "Healthy"
        $record.consecutiveFailures = 0
        $record.attemptCount = 0
        $record.lastError = ""
        $record.nextRetryUtc = $null
        $record.lastHealthyUtc = ConvertTo-WatchdogIso $Now
        return [pscustomobject]@{ action="None"; reason="healthy"; record=$record }
    }
    $record.lastError = Protect-WatchdogText ([string](Get-WatchdogProperty $Health "error" "health check failed"))
    $record.consecutiveFailures = [int]$record.consecutiveFailures + 1
    if ([bool](Get-WatchdogProperty $Health "identityConflict" $false)) {
        $record.phase = "RecoveryFailed"; $record.nextRetryUtc = $null
        return [pscustomobject]@{ action="None"; reason="identity_conflict"; record=$record }
    }
    if ([bool](Get-WatchdogProperty $Health "busyIndeterminate" $false)) {
        $record.phase = "Confirming"; $record.nextRetryUtc = $null
        return [pscustomobject]@{ action="None"; reason="busy_indeterminate"; record=$record }
    }
    if ([int]$record.consecutiveFailures -lt [int]$Settings.failureThreshold) {
        $record.phase = if ([int]$record.consecutiveFailures -eq 1) { "Suspect" } else { "Confirming" }
        return [pscustomobject]@{ action="None"; reason="confirming"; record=$record }
    }
    if ([int]$record.attemptCount -ge [int]$Settings.maxRecoveryAttempts) {
        $record.phase = "RecoveryFailed"; $record.nextRetryUtc = $null
        return [pscustomobject]@{ action="None"; reason="max_retry"; record=$record }
    }
    if ($record.nextRetryUtc) {
        $next = [DateTimeOffset]::Parse([string]$record.nextRetryUtc)
        if ($Now -lt $next) {
            $record.phase = "Confirming"
            return [pscustomobject]@{ action="Wait"; reason="backoff"; record=$record }
        }
    } else {
        $index = [Math]::Min([int]$record.attemptCount, $Settings.backoffSeconds.Count - 1)
        $delay = [int]$Settings.backoffSeconds[$index]
        $record.nextRetryUtc = ConvertTo-WatchdogIso $Now.AddSeconds($delay)
        if ($delay -gt 0) {
            $record.phase = "Confirming"
            return [pscustomobject]@{ action="Wait"; reason="backoff"; record=$record }
        }
    }
    $record.attemptCount = [int]$record.attemptCount + 1
    $record.phase = "Recovering"
    $record.lastRecoveryUtc = ConvertTo-WatchdogIso $Now
    $record.nextRetryUtc = $null
    return [pscustomobject]@{ action="Recover"; reason="confirmed_failure"; record=$record }
}

function Complete-WatchdogRecoveryAttempt($State, [string]$Service, $Result) {
    $record = Get-WatchdogProperty $State.recovery $Service (New-WatchdogRecoveryRecord)
    if (-not [bool](Get-WatchdogProperty $Result "success" $false)) {
        $record.lastError = Protect-WatchdogText ([string](Get-WatchdogProperty $Result "error" "recovery dispatch failed"))
    }
    Set-WatchdogProperty $State.recovery $Service $record
}

function Write-WatchdogEvent([string]$StateDir, $Config, [string]$Service, [string]$Event, [string]$Cause, [string]$Action, [string]$Result) {
    $settings = Get-WatchdogControlSettings $Config
    $path = Join-Path $StateDir "watchdog-tray-events.jsonl"
    if ([System.IO.File]::Exists($path) -and (Get-Item -LiteralPath $path).Length -ge $settings.logMaxBytes) {
        $rotated = "$path.1"
        if ([System.IO.File]::Exists($rotated)) { [System.IO.File]::Delete($rotated) }
        [System.IO.File]::Move($path, $rotated)
    }
    $entry = [pscustomobject][ordered]@{
        timestamp = ConvertTo-WatchdogIso ([DateTimeOffset]::UtcNow)
        service = $Service
        event = $Event
        cause = Protect-WatchdogText $Cause
        action = Protect-WatchdogText $Action
        result = Protect-WatchdogText $Result
    }
    $line = ($entry | ConvertTo-Json -Compress) + [Environment]::NewLine
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try {
        $writer = New-Object System.IO.StreamWriter($stream, $encoding)
        try { $writer.Write($line) } finally { $writer.Dispose() }
    } finally { $stream.Dispose() }
}

function Get-WatchdogEventHistory([string]$StateDir, $Config, [int]$Limit = 0) {
    $settings = Get-WatchdogControlSettings $Config
    if ($Limit -le 0 -or $Limit -gt $settings.historyLimit) { $Limit = $settings.historyLimit }
    $entries = @()
    foreach ($path in @((Join-Path $StateDir "watchdog-tray-events.jsonl.1"), (Join-Path $StateDir "watchdog-tray-events.jsonl"))) {
        if (-not [System.IO.File]::Exists($path)) { continue }
        foreach ($line in [System.IO.File]::ReadAllLines($path)) {
            if (-not $line) { continue }
            try { $entries += ($line | ConvertFrom-Json) } catch { }
        }
    }
    return @($entries | Select-Object -Last $Limit | Sort-Object timestamp -Descending)
}

function Get-WatchdogBackupRoot([string]$StateDir) {
    return Join-Path ([System.IO.Path]::GetFullPath($StateDir)) "configuration-backups"
}

function New-WatchdogConfigurationBackup([string]$ConfigPath, $CurrentConfig, $AfterEditable, [string]$ChangeType) {
    $stateDir = [System.IO.Path]::GetFullPath([string](Get-WatchdogProperty $CurrentConfig "stateDir" (Split-Path -Parent $ConfigPath)))
    $root = Get-WatchdogBackupRoot $stateDir
    [void][System.IO.Directory]::CreateDirectory($root)
    $id = (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $directory = Join-Path $root $id
    [void][System.IO.Directory]::CreateDirectory($directory)
    $files = @()
    $known = @(
        [pscustomobject]@{ key="watchdogConfig"; source=[System.IO.Path]::GetFullPath($ConfigPath); name="devspace-watchdog.config.json" },
        [pscustomobject]@{ key="devspaceConfig"; source=(Join-Path $stateDir "config.json"); name="config.json" }
    )
    foreach ($file in Get-WatchdogConfiguredCloudFiles $CurrentConfig $stateDir) {
        $known += [pscustomobject]@{ key=$file.key; source=$file.path; name=$file.name }
    }
    foreach ($file in Get-WatchdogGeneratedCloudFiles $AfterEditable $stateDir) {
        if ([System.IO.File]::Exists($file.path) -and $file.path -notin @($known | ForEach-Object { $_.source })) {
            $known += [pscustomobject]@{ key=$file.key; source=$file.path; name=$file.name }
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $stateDir -File -Filter "ngrok-cloud-endpoint-*.yml" -ErrorAction SilentlyContinue)) {
        if ($file.Name -match '^ngrok-cloud-endpoint-[a-z0-9]+(?:-[a-z0-9]+)*\.(policy|rule)\.yml$' -and $file.FullName -notin @($known | ForEach-Object { $_.source })) {
            $key = if ($file.Name.EndsWith(".policy.yml", [System.StringComparison]::OrdinalIgnoreCase)) { "cloudEndpointPolicyPath" } else { "cloudEndpointRulePath" }
            $known += [pscustomobject]@{ key=$key; source=$file.FullName; name=$file.Name }
        }
    }
    foreach ($item in $known) {
        if (-not [System.IO.File]::Exists($item.source)) { continue }
        $destination = Join-Path $directory $item.name
        [System.IO.File]::Copy($item.source, $destination, $false)
        $files += [pscustomobject]@{ key=$item.key; name=$item.name; sha256=(Get-WatchdogFileSha256 $destination) }
    }
    $removeOnRestore = @(
        Get-WatchdogGeneratedCloudFiles $AfterEditable $stateDir |
            Where-Object { -not [System.IO.File]::Exists($_.path) } |
            ForEach-Object { $_.name }
    )
    $manifest = [pscustomobject][ordered]@{
        id = $id
        timestamp = ConvertTo-WatchdogIso ([DateTimeOffset]::UtcNow)
        changeType = $ChangeType
        before = Get-WatchdogEditableConfig $CurrentConfig
        after = $AfterEditable
        files = $files
        removeOnRestore = $removeOnRestore
    }
    Write-WatchdogAtomicJson (Join-Path $directory "manifest.json") $manifest 20
    return $manifest
}

function Get-WatchdogConfigurationBackups([string]$StateDir) {
    $root = Get-WatchdogBackupRoot $StateDir
    if (-not [System.IO.Directory]::Exists($root)) { return @() }
    $items = @()
    foreach ($directory in Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name -Descending) {
        $manifestPath = Join-Path $directory.FullName "manifest.json"
        if (-not [System.IO.File]::Exists($manifestPath)) { continue }
        try {
            $manifest = Read-WatchdogJson $manifestPath
            $items += [pscustomobject]@{ id=$manifest.id; timestamp=$manifest.timestamp; changeType=$manifest.changeType; before=$manifest.before; after=$manifest.after }
        } catch { }
    }
    return $items
}

function Restore-WatchdogBackupPayload([string]$ConfigPath, [string]$StateDir, [string]$Directory, $Manifest) {
    $allowedTargets = @{
        watchdogConfig = [System.IO.Path]::GetFullPath($ConfigPath)
        devspaceConfig = Join-Path $StateDir "config.json"
    }
    $writes = @()
    foreach ($file in @($Manifest.files)) {
        $name = [System.IO.Path]::GetFileName([string]$file.name)
        $source = Join-Path $Directory $name
        if (-not [System.IO.File]::Exists($source)) { throw "Backup payload missing: $name" }
        if ((Get-WatchdogFileSha256 $source) -ne [string]$file.sha256) { throw "Backup payload hash mismatch: $name" }
        $target = $allowedTargets[[string]$file.key]
        if (-not $target -and [string]$file.key -in @("cloudEndpointPolicyPath", "cloudEndpointRulePath") -and $name -match '^ngrok-cloud-endpoint-[a-z0-9]+(?:-[a-z0-9]+)*\.(policy|rule)\.yml$') {
            $target = Join-Path $StateDir $name
        }
        if (-not $target) { throw "Backup contains an unsupported target." }
        $writes += [pscustomobject]@{ source=$source; target=$target }
    }
    $deletes = @()
    foreach ($nameValue in @(Get-WatchdogProperty $Manifest "removeOnRestore" @())) {
        $name = [string]$nameValue
        if ([System.IO.Path]::GetFileName($name) -ne $name -or $name -notmatch '^ngrok-cloud-endpoint-[a-z0-9]+(?:-[a-z0-9]+)*\.(policy|rule)\.yml$') {
            throw "Backup contains an unsupported generated-file target."
        }
        $deletes += (Join-Path $StateDir $name)
    }
    foreach ($item in $writes) { Write-WatchdogAtomicText $item.target ([System.IO.File]::ReadAllText($item.source, [System.Text.Encoding]::UTF8)) }
    foreach ($target in $deletes) { if ([System.IO.File]::Exists($target)) { [System.IO.File]::Delete($target) } }
}

function Set-WatchdogConfiguration([string]$ConfigPath, $RequestedInput) {
    $current = Read-WatchdogJson $ConfigPath
    $editable = ConvertTo-WatchdogEditableConfig $RequestedInput $current
    $impact = New-WatchdogConfigImpact $current $editable
    if (@($impact.changes).Count -eq 0) { throw "No configuration changes to apply." }
    $proposed = New-WatchdogProposedConfig $current $editable
    $currentCloudFiles = @(Get-WatchdogConfiguredCloudFiles $current ([string]$current.stateDir))
    $backup = New-WatchdogConfigurationBackup $ConfigPath $current $editable "apply"
    $stateDir = [System.IO.Path]::GetFullPath([string]$proposed.stateDir)
    try {
        if ($editable.endpointMode -eq "CloudEndpoint") {
            $routePaths = @($editable.devspaceRoutePath, $editable.hermesRoutePath)
            Write-WatchdogAtomicText ([string]$proposed.cloudEndpointPolicyPath) ((New-WatchdogNgrokPolicy $editable.machineSlug $editable.internalAgentEndpoint $routePaths) + [Environment]::NewLine)
            Write-WatchdogAtomicText ([string]$proposed.cloudEndpointRulePath) ((New-WatchdogNgrokRule $editable.machineSlug $editable.internalAgentEndpoint $routePaths) + [Environment]::NewLine)
        }
        $devspaceConfigPath = Join-Path $stateDir "config.json"
        if ([System.IO.File]::Exists($devspaceConfigPath)) {
            $devspaceConfig = Read-WatchdogJson $devspaceConfigPath
            Set-WatchdogProperty $devspaceConfig "publicBaseUrl" ([string]$proposed.publicBaseUrl)
            Write-WatchdogAtomicJson $devspaceConfigPath $devspaceConfig 10
        }
        Write-WatchdogAtomicJson $ConfigPath $proposed 30
        $proposedCloudPaths = @(Get-WatchdogConfiguredCloudFiles $proposed $stateDir | ForEach-Object { $_.path })
        foreach ($file in $currentCloudFiles) {
            if ($file.path -notin $proposedCloudPaths -and [System.IO.File]::Exists($file.path)) { [System.IO.File]::Delete($file.path) }
        }
    } catch {
        $applyError = $_.Exception.Message
        $backupDirectory = Join-Path (Get-WatchdogBackupRoot $stateDir) $backup.id
        try { Restore-WatchdogBackupPayload $ConfigPath $stateDir $backupDirectory $backup }
        catch { throw "Configuration apply failed, and automatic rollback also failed: $applyError; rollback: $($_.Exception.Message)" }
        throw "Configuration apply failed; the previous files were restored automatically: $applyError"
    }
    return [pscustomobject]@{ config=$proposed; editable=$editable; impact=$impact; backup=$backup }
}

function Restore-WatchdogConfigurationBackup([string]$ConfigPath, [string]$BackupId) {
    if ($BackupId -notmatch '^\d{8}-\d{6}-[a-f0-9]{8}$') { throw "Invalid backup identifier." }
    $current = Read-WatchdogJson $ConfigPath
    $stateDir = [System.IO.Path]::GetFullPath([string]$current.stateDir)
    $root = [System.IO.Path]::GetFullPath((Get-WatchdogBackupRoot $stateDir))
    $directory = [System.IO.Path]::GetFullPath((Join-Path $root $BackupId))
    if (-not $directory.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or -not [System.IO.Directory]::Exists($directory)) {
        throw "Backup was not found."
    }
    $manifest = Read-WatchdogJson (Join-Path $directory "manifest.json")
    $safetyBackup = New-WatchdogConfigurationBackup $ConfigPath $current (Get-WatchdogEditableConfig $current) "rollback-before-$BackupId"
    $createdByRestore = @(
        $manifest.files |
            Where-Object { [string]$_.name -match '^ngrok-cloud-endpoint-[a-z0-9]+(?:-[a-z0-9]+)*\.(policy|rule)\.yml$' -and -not [System.IO.File]::Exists((Join-Path $stateDir ([string]$_.name))) } |
            ForEach-Object { [string]$_.name }
    )
    if ($createdByRestore.Count) {
        $safetyBackup.removeOnRestore = @((@($safetyBackup.removeOnRestore) + $createdByRestore) | Select-Object -Unique)
        Write-WatchdogAtomicJson (Join-Path (Join-Path $root $safetyBackup.id) "manifest.json") $safetyBackup 20
    }
    try {
        Restore-WatchdogBackupPayload $ConfigPath $stateDir $directory $manifest
    } catch {
        $restoreError = $_.Exception.Message
        $safetyDirectory = Join-Path $root $safetyBackup.id
        try { Restore-WatchdogBackupPayload $ConfigPath $stateDir $safetyDirectory $safetyBackup }
        catch { throw "Backup restore failed, and restoring the pre-rollback safety copy also failed: $restoreError; safety restore: $($_.Exception.Message)" }
        throw "Backup restore failed; the pre-rollback safety copy was restored: $restoreError"
    }
    return [pscustomobject]@{ restored=$BackupId; config=(Read-WatchdogJson $ConfigPath); safetyBackup=$safetyBackup }
}

function Read-WatchdogLimitedStream($Stream, [int]$MaximumBytes = 262144, [int]$TimeoutMilliseconds = 5000, [switch]$StopAtEventMessage) {
    $buffer = New-Object byte[] 8192
    $memory = New-Object System.IO.MemoryStream
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    try {
        while ($true) {
            $remaining = [Math]::Max(1, [int]($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds)
            $readTask = $Stream.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $readTask.Wait($remaining)) { throw "HTTP response body timed out." }
            $read = $readTask.Result
            if ($read -le 0) { break }
            if (($memory.Length + $read) -gt $MaximumBytes) { throw "HTTP response exceeded $MaximumBytes bytes." }
            $memory.Write($buffer, 0, $read)
            if ($StopAtEventMessage) {
                $partial = [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
                if ($partial -match '(?ms)^data:\s*.+?\r?\n\r?\n') { break }
            }
        }
        return [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
    } finally { $memory.Dispose() }
}

function Invoke-WatchdogHttpRequest(
    [string]$Url,
    [string]$Method = "GET",
    [string]$Body = "",
    [int]$TimeoutSeconds = 4,
    [switch]$Local
) {
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    if ($Local) { $handler.UseProxy = $false }
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $request = $null
    $response = $null
    $stream = $null
    try {
        $httpMethod = New-Object System.Net.Http.HttpMethod -ArgumentList $Method
        $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList $httpMethod, $Url
        [void]$request.Headers.TryAddWithoutValidation("Accept", "application/json, text/event-stream")
        [void]$request.Headers.TryAddWithoutValidation("ngrok-skip-browser-warning", "true")
        [void]$request.Headers.TryAddWithoutValidation("User-Agent", "DevSpace-Watchdog/1.0")
        if ($Body) { $request.Content = New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, "application/json") }
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $headers = @{}
        foreach ($header in $response.Headers) { $headers[$header.Key.ToLowerInvariant()] = ($header.Value -join ", ") }
        foreach ($header in $response.Content.Headers) { $headers[$header.Key.ToLowerInvariant()] = ($header.Value -join ", ") }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $contentType = [string]$response.Content.Headers.ContentType
        $responseBody = Read-WatchdogLimitedStream $stream 262144 ($TimeoutSeconds * 1000) -StopAtEventMessage:($contentType -match '(?i)text/event-stream')
        return [pscustomobject]@{ reachable=$true; status=[int]$response.StatusCode; body=$responseBody; headers=$headers; error="" }
    } catch {
        return [pscustomobject]@{ reachable=$false; status=0; body=""; headers=@{}; error=(Protect-WatchdogText $_.Exception.Message) }
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Test-WatchdogJsonRpcBody([string]$Body) {
    $candidates = @($Body)
    if ($Body -match '(?m)^data:\s*(.+)$') {
        $candidates = @([regex]::Matches($Body, '(?m)^data:\s*(.+)$') | ForEach-Object { $_.Groups[1].Value })
    }
    foreach ($candidate in $candidates) {
        try { $message = $candidate | ConvertFrom-Json } catch { continue }
        if ([string](Get-WatchdogProperty $message "jsonrpc" "") -ne "2.0") { continue }
        $result = Get-WatchdogProperty $message "result" $null
        if ($result -and ((Get-WatchdogProperty $result "protocolVersion" $null) -or (Get-WatchdogProperty $result "serverInfo" $null))) { return $true }
    }
    return $false
}

function Test-WatchdogMcpResponse([int]$Status, [string]$Body, $Headers) {
    $protocolHealthy = $false
    $behavior = "http_$Status"
    if ($Status -eq 401) {
        $challenge = [string]$Headers["www-authenticate"]
        $protocolHealthy = $challenge -match '(?i)^Bearer\b' -and $challenge -match '(?i)resource_metadata='
        $behavior = if ($protocolHealthy) { "oauth_challenge" } else { "unexpected_401" }
    } elseif ($Status -ge 200 -and $Status -lt 300) {
        $protocolHealthy = Test-WatchdogJsonRpcBody $Body
        $behavior = if ($protocolHealthy) { "jsonrpc" } else { "non_mcp_success" }
    }
    return [pscustomobject]@{ protocolHealthy=[bool]$protocolHealthy; behavior=$behavior }
}

function Invoke-WatchdogMcpProbe([string]$Url, [switch]$Local) {
    $payload = '{"jsonrpc":"2.0","id":"devspace-watchdog-health","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"devspace-watchdog","version":"1.0"}}}'
    $response = Invoke-WatchdogHttpRequest $Url "POST" $payload 5 -Local:$Local
    $protocolHealthy = $false
    $behavior = "unreachable"
    if ($response.reachable) {
        $classification = Test-WatchdogMcpResponse $response.status $response.body $response.headers
        $protocolHealthy = $classification.protocolHealthy
        $behavior = $classification.behavior
    }
    return [pscustomobject]@{
        httpReachable = [bool]$response.reachable
        protocolHealthy = [bool]$protocolHealthy
        status = [int]$response.status
        behavior = $behavior
        error = if ($protocolHealthy) { "" } elseif ($response.error) { $response.error } else { "MCP probe returned $behavior" }
    }
}

function Invoke-WatchdogJsonProbe([string]$Url, [scriptblock]$Validator) {
    $response = Invoke-WatchdogHttpRequest $Url "GET" "" 4 -Local
    $semantic = $false
    $json = $null
    if ($response.reachable -and $response.status -eq 200) {
        try { $json = $response.body | ConvertFrom-Json; $semantic = [bool](& $Validator $json) } catch { $semantic = $false }
    }
    return [pscustomobject]@{
        httpReachable = [bool]$response.reachable
        semanticHealthy = [bool]$semantic
        status = [int]$response.status
        json = $json
        error = if ($semantic) { "" } elseif ($response.error) { $response.error } else { "HTTP endpoint did not return the expected semantic response." }
    }
}

function Get-WatchdogListenOwners([int]$Port) {
    return @(
        Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique |
            Where-Object { $_ -and $_ -ne 0 }
    )
}

function Test-WatchdogCommandContains([string]$CommandLine, [string]$Value) {
    return $Value -and $CommandLine -and $CommandLine.IndexOf($Value, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-WatchdogCommandToken([string]$CommandLine, [string]$Value) {
    if (-not $Value -or -not $CommandLine) { return $false }
    return [regex]::IsMatch($CommandLine, '(?i)(?:^|\s)"?' + [regex]::Escape($Value) + '"?(?=$|\s)')
}

function Test-WatchdogExecutablePath($Process, [string]$ExpectedPath) {
    if (-not $Process -or -not $ExpectedPath -or -not [string](Get-WatchdogProperty $Process "ExecutablePath" "")) { return $false }
    try {
        return [System.IO.Path]::GetFullPath([string]$Process.ExecutablePath).Equals(
            [System.IO.Path]::GetFullPath($ExpectedPath),
            [System.StringComparison]::OrdinalIgnoreCase
        )
    } catch { return $false }
}

function Test-WatchdogManagedProcess($Process, [string]$Service, $Config) {
    if (-not $Process) { return $false }
    $name = [string]$Process.Name
    $command = [string]$Process.CommandLine
    switch ($Service) {
        "devspace" {
            return $name -eq "node.exe" -and
                (Test-WatchdogExecutablePath $Process ([string](Get-WatchdogProperty $Config "nodePath" ""))) -and
                (Test-WatchdogCommandContains $command ([string](Get-WatchdogProperty $Config "cliPath" ""))) -and
                (Test-WatchdogCommandToken $command "serve")
        }
        "hermes" {
            $python = [string](Get-WatchdogProperty $Config "hermesPython" "")
            $server = [string](Get-WatchdogProperty $Config "hermesServer" "")
            $wrapper = [string](Get-WatchdogProperty $Config "hermesCommand" "")
            $port = [string](Get-WatchdogProperty $Config "hermesPort" "")
            $directCommand = $server -and $name -eq "python.exe" -and
                (Test-WatchdogCommandContains $command $server) -and
                (Test-WatchdogCommandToken $command "--port") -and
                (Test-WatchdogCommandToken $command $port)
            # uv/venv on Windows can launch the configured venv python.exe as a
            # parent shim while the actual listener is owned by the underlying
            # managed Python runtime. The exact server path + exact port tokens
            # still uniquely identify this Hermes instance, so do not require
            # the listener child executable path to equal the venv shim path.
            $direct = $python -and $directCommand
            $wrapped = $wrapper -and $name -eq "cmd.exe" -and (Test-WatchdogCommandContains $command $wrapper)
            return [bool]($direct -or $wrapped)
        }
        "router" {
            return $name -eq "node.exe" -and
                (Test-WatchdogExecutablePath $Process ([string](Get-WatchdogProperty $Config "nodePath" ""))) -and
                (Test-WatchdogCommandContains $command ([string](Get-WatchdogProperty $Config "routerPath" "")))
        }
        "ngrok" {
            if ($name -ne "ngrok.exe" -or -not (Test-WatchdogExecutablePath $Process ([string](Get-WatchdogProperty $Config "ngrokPath" "")))) { return $false }
            $upstreamPort = [int](Get-WatchdogProperty $Config "publicUpstreamPort" (Get-WatchdogProperty $Config "routerPort" 0))
            $upstream = "http://127.0.0.1:$upstreamPort"
            $agentUrl = [string](Get-WatchdogProperty $Config "ngrokAgentBaseUrl" (Get-WatchdogProperty $Config "publicBaseUrl" ""))
            try { $agentHost = ([Uri]$agentUrl).Host } catch { $agentHost = "" }
            $binding = [string](Get-WatchdogProperty $Config "ngrokBinding" "")
            $bindingMatches = -not $binding -or ((Test-WatchdogCommandToken $command "--binding") -and (Test-WatchdogCommandToken $command $binding))
            $webSupported = [bool](Get-WatchdogProperty $Config "ngrokWebAddrSupported" $true)
            $inspector = "127.0.0.1:$([int](Get-WatchdogProperty $Config 'ngrokInspectorPort' 4040))"
            $inspectorMatches = -not $webSupported -or ((Test-WatchdogCommandToken $command "--web-addr") -and (Test-WatchdogCommandToken $command $inspector))
            return (Test-WatchdogCommandToken $command $upstream) -and (Test-WatchdogCommandToken $command $agentHost) -and $bindingMatches -and $inspectorMatches
        }
    }
    return $false
}

function Test-WatchdogServiceEnabled([string]$Service, $Config) {
    switch ($Service) {
        "devspace" { return [bool](Get-WatchdogProperty $Config "devspaceEnabled" $true) }
        "hermes" { return [bool](Get-WatchdogProperty $Config "hermesEnabled" $false) -and [int](Get-WatchdogProperty $Config "hermesPort" 0) -gt 0 }
        "router" { return [int](Get-WatchdogProperty $Config "routerPort" 0) -gt 0 }
        "ngrok" { return [bool](Get-WatchdogProperty $Config "manageNgrok" $false) }
    }
    return $false
}

function Get-WatchdogServicePort([string]$Service, $Config) {
    switch ($Service) {
        "devspace" { return [int](Get-WatchdogProperty $Config "port" 0) }
        "hermes" { return [int](Get-WatchdogProperty $Config "hermesPort" 0) }
        "router" { return [int](Get-WatchdogProperty $Config "routerPort" 0) }
        "ngrok" { return [int](Get-WatchdogProperty $Config "ngrokInspectorPort" 4040) }
    }
    return 0
}

function Get-WatchdogProcessLayer([string]$Service, $Config, $Processes) {
    $port = Get-WatchdogServicePort $Service $Config
    $listeners = if ($port -gt 0) { @(Get-WatchdogListenOwners $port) } else { @() }
    $managed = @($Processes | Where-Object { Test-WatchdogManagedProcess $_ $Service $Config })
    $managedPids = @($managed | ForEach-Object { [int]$_.ProcessId })
    $managedListeners = @($listeners | Where-Object { $_ -in $managedPids })
    $unknownListeners = @($listeners | Where-Object { $_ -notin $managedPids })
    $primary = @($managed | Where-Object { [int]$_.ProcessId -in $managedListeners } | Select-Object -First 1)
    if ($primary.Count -eq 0) { $primary = @($managed | Select-Object -First 1) }
    $uptime = $null
    if ($primary.Count -and $primary[0].CreationDate) {
        try { $uptime = [Math]::Max(0, [int]([DateTimeOffset]::Now - [DateTimeOffset]$primary[0].CreationDate).TotalSeconds) } catch { }
    }
    return [pscustomobject]@{
        processFound = ($managed.Count -gt 0)
        listenerFound = ($managedListeners.Count -gt 0)
        identityConflict = ($unknownListeners.Count -gt 0)
        pid = if ($primary.Count) { [int]$primary[0].ProcessId } else { $null }
        uptimeSeconds = $uptime
        managedPids = $managedPids
        listenerPids = $listeners
        unknownListenerPids = $unknownListeners
    }
}

function New-WatchdogDisabledHealth([string]$Service, [int]$Port) {
    return [pscustomobject][ordered]@{
        service=$Service; enabled=$false; healthy=$true; processFound=$false; listenerFound=$false
        identityConflict=$false; busyIndeterminate=$false; pid=$null; port=$Port; uptimeSeconds=$null
        httpReachable=$false; protocolHealthy=$false; error=""; detail="disabled"
    }
}

function Get-WatchdogServiceHealth([string]$Service, $Config, $Processes) {
    $port = Get-WatchdogServicePort $Service $Config
    if (-not (Test-WatchdogServiceEnabled $Service $Config)) { return New-WatchdogDisabledHealth $Service $port }
    $layer = Get-WatchdogProcessLayer $Service $Config $Processes
    $httpReachable = $false
    $protocolHealthy = $false
    $detail = ""
    $probeError = ""
    if ($layer.listenerFound -and -not $layer.identityConflict) {
        switch ($Service) {
            "devspace" {
                $healthProbe = Invoke-WatchdogJsonProbe "http://127.0.0.1:$port/healthz" { param($json) [bool](Get-WatchdogProperty $json "ok" $false) -and [string](Get-WatchdogProperty $json "name" "") -eq "devspace" }
                $mcpProbe = Invoke-WatchdogMcpProbe "http://127.0.0.1:$port/mcp" -Local
                $httpReachable = $healthProbe.httpReachable -or $mcpProbe.httpReachable
                $protocolHealthy = $healthProbe.semanticHealthy -and $mcpProbe.protocolHealthy
                $detail = "healthz=$($healthProbe.semanticHealthy); mcp=$($mcpProbe.behavior)"
                $probeError = if (-not $healthProbe.semanticHealthy) { $healthProbe.error } else { $mcpProbe.error }
            }
            "hermes" {
                $mcpProbe = Invoke-WatchdogMcpProbe "http://127.0.0.1:$port/mcp" -Local
                $httpReachable = $mcpProbe.httpReachable
                $protocolHealthy = $mcpProbe.protocolHealthy
                $detail = "mcp=$($mcpProbe.behavior)"
                $probeError = $mcpProbe.error
            }
            "router" {
                $machineSlug = [string](Get-WatchdogProperty $Config "machineSlug" "")
                $routerProbe = Invoke-WatchdogJsonProbe "http://127.0.0.1:$port/__router/status" { param($json) [bool](Get-WatchdogProperty $json "ok" $false) -and [string](Get-WatchdogProperty $json "machine" "") -eq $machineSlug -and $null -ne (Get-WatchdogProperty $json "routes" $null) }
                $httpReachable = $routerProbe.httpReachable
                $protocolHealthy = $routerProbe.semanticHealthy
                $detail = "router_status=$($routerProbe.semanticHealthy)"
                $probeError = $routerProbe.error
            }
            "ngrok" {
                $inspector = Invoke-WatchdogHttpRequest "http://127.0.0.1:$port/api/tunnels" "GET" "" 4 -Local
                $matched = $false
                $active = ""
                if ($inspector.reachable -and $inspector.status -eq 200) {
                    try {
                        $payload = $inspector.body | ConvertFrom-Json
                        $expectedUrl = [string](Get-WatchdogProperty $Config "ngrokAgentBaseUrl" (Get-WatchdogProperty $Config "publicBaseUrl" ""))
                        $upstreamPort = [int](Get-WatchdogProperty $Config "publicUpstreamPort" (Get-WatchdogProperty $Config "routerPort" 0))
                        $expectedUpstream = "http://127.0.0.1:$upstreamPort"
                        foreach ($tunnel in @(Get-WatchdogProperty $payload "tunnels" @())) {
                            $active = [string](Get-WatchdogProperty $tunnel "public_url" "")
                            $address = [string](Get-WatchdogProperty (Get-WatchdogProperty $tunnel "config" $null) "addr" "")
                            if ($active.TrimEnd("/") -eq $expectedUrl.TrimEnd("/") -and $address -eq $expectedUpstream) { $matched = $true; break }
                        }
                    } catch { $probeError = Protect-WatchdogText $_.Exception.Message }
                }
                $httpReachable = $inspector.reachable
                $protocolHealthy = $matched
                $detail = if ($matched) { "tunnel=$active" } else { "expected tunnel not active" }
                if (-not $probeError -and -not $matched) { $probeError = if ($inspector.error) { $inspector.error } else { "ngrok Inspector did not report the expected endpoint and upstream." } }
            }
        }
    }
    $healthy = $layer.processFound -and $layer.listenerFound -and -not $layer.identityConflict -and $protocolHealthy
    $busy = $Service -in @("devspace", "hermes") -and $layer.processFound -and $layer.listenerFound -and -not $layer.identityConflict -and -not $healthy
    $error = if ($layer.identityConflict) { "Configured port is owned by an unrecognized process; automatic mutation is blocked." } elseif (-not $layer.processFound) { "Managed process is missing." } elseif (-not $layer.listenerFound) { "Managed process is not listening on the configured port." } elseif (-not $protocolHealthy) { $probeError } else { "" }
    return [pscustomobject][ordered]@{
        service=$Service; enabled=$true; healthy=[bool]$healthy; processFound=[bool]$layer.processFound; listenerFound=[bool]$layer.listenerFound
        identityConflict=[bool]$layer.identityConflict; busyIndeterminate=[bool]$busy; pid=$layer.pid; port=$port; uptimeSeconds=$layer.uptimeSeconds
        httpReachable=[bool]$httpReachable; protocolHealthy=[bool]$protocolHealthy; error=(Protect-WatchdogText $error); detail=$detail
    }
}

function Get-WatchdogOptionalToolStatus($Config, $Processes) {
    $userProfile = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath('UserProfile') }
    $appData = if ($env:APPDATA) { $env:APPDATA } else { [Environment]::GetFolderPath('ApplicationData') }
    $codexPath = [string](Get-WatchdogProperty $Config "codexPath" "")
    if (-not $codexPath -and $appData) {
        foreach ($candidate in @((Join-Path $appData 'npm\codex.cmd'), (Join-Path $appData 'npm\codex.exe'))) {
            if ([System.IO.File]::Exists($candidate)) { $codexPath = $candidate; break }
        }
    }
    if (-not $codexPath) {
        try { $command = Get-Command codex -CommandType Application -ErrorAction Stop | Select-Object -First 1; $codexPath = [string]$command.Source } catch { }
    }
    $codexInstalled = [bool]($codexPath -and [System.IO.File]::Exists($codexPath))
    $codexRunning = @($Processes | Where-Object { ([string]$_.Name).ToLowerInvariant() -eq 'codex.exe' }).Count -gt 0

    $skillRoot = [string](Get-WatchdogProperty $Config "codexSkillRoot" "")
    if (-not $skillRoot -and $userProfile) { $skillRoot = Join-Path $userProfile '.codex\skills' }
    $officialSkill = $codexInstalled -and [System.IO.File]::Exists((Join-Path $skillRoot 'codex-with-chatgpt\SKILL.md'))
    $tyoSkill = $codexInstalled -and [System.IO.File]::Exists((Join-Path $skillRoot 'tyo-c2c-orchestrator\SKILL.md'))

    $openCodexHome = [string](Get-WatchdogProperty $Config "openCodexHome" "")
    if (-not $openCodexHome -and $userProfile) { $openCodexHome = Join-Path $userProfile '.opencodex' }
    $openCodexInstalled = [System.IO.Directory]::Exists($openCodexHome)
    $openCodexTrayScript = if ($openCodexInstalled) { Join-Path $openCodexHome 'opencodex-tray.ps1' } else { '' }
    $openCodexTrayLauncher = if ($openCodexInstalled) { Join-Path $openCodexHome 'opencodex-tray.vbs' } else { '' }
    $openCodexTrayInstalled = [System.IO.File]::Exists($openCodexTrayScript) -and [System.IO.File]::Exists($openCodexTrayLauncher)
    $openCodexTrayRunning = @($Processes | Where-Object { ([string]$_.CommandLine) -like '*opencodex-tray.ps1*' }).Count -gt 0
    $openCodexProxyRunning = @($Processes | Where-Object {
        $commandLine = [string]$_.CommandLine
        $commandLine -like '*opencodex*' -and $commandLine -match '(?i)(^|\s)start(\s|$)'
    }).Count -gt 0
    $openCodexProxyHealthy = $false
    $openCodexPort = 10100
    if ($openCodexInstalled) {
        foreach ($runtimeFile in @((Join-Path $openCodexHome 'runtime-port.json'), (Join-Path $openCodexHome 'config.json'))) {
            if (-not [System.IO.File]::Exists($runtimeFile)) { continue }
            try {
                $runtime = Read-WatchdogJson $runtimeFile
                $candidatePort = [int](Get-WatchdogProperty $runtime 'port' 0)
                if ($candidatePort -gt 0 -and $candidatePort -le 65535) { $openCodexPort = $candidatePort; break }
            } catch { }
        }
        if ($openCodexProxyRunning) {
            $probe = Invoke-WatchdogJsonProbe "http://127.0.0.1:$openCodexPort/healthz" { param($json) [string](Get-WatchdogProperty $json 'status' '') -eq 'ok' -and [string](Get-WatchdogProperty $json 'service' '') -eq 'opencodex' }
            $openCodexProxyHealthy = [bool]$probe.semanticHealthy
        }
    }

    return [pscustomobject][ordered]@{
        codex = [pscustomobject][ordered]@{
            installed=$codexInstalled; path=$codexPath; running=[bool]$codexRunning
            officialC2c=[bool]$officialSkill; tyoC2c=[bool]$tyoSkill
            visible=[bool]$codexInstalled
        }
        openCodex = [pscustomobject][ordered]@{
            installed=[bool]$openCodexInstalled; home=$openCodexHome; port=$openCodexPort
            proxyRunning=[bool]$openCodexProxyRunning; proxyHealthy=[bool]$openCodexProxyHealthy
            trayInstalled=[bool]$openCodexTrayInstalled; trayRunning=[bool]$openCodexTrayRunning
            repairTrayAvailable=([bool]$openCodexTrayInstalled -and -not [bool]$openCodexTrayRunning)
            visible=[bool]$openCodexInstalled
        }
    }
}

function Repair-WatchdogOptionalTool([string]$Tool, $Status) {
    if ($Tool -ne 'opencodex-tray') { return [pscustomobject]@{ success=$false; error='Unsupported optional tool repair.' } }
    $openCodex = Get-WatchdogProperty $Status 'openCodex' $null
    if (-not [bool](Get-WatchdogProperty $openCodex 'installed' $false)) { return [pscustomobject]@{ success=$false; error='OpenCodex is not installed; automatic installation is intentionally disabled.' } }
    if ([bool](Get-WatchdogProperty $openCodex 'trayRunning' $false)) { return [pscustomobject]@{ success=$true; error='already running' } }
    $home = [string](Get-WatchdogProperty $openCodex 'home' '')
    $launcher = Join-Path $home 'opencodex-tray.vbs'
    if (-not [System.IO.File]::Exists($launcher)) { return [pscustomobject]@{ success=$false; error='OpenCodex Tray launcher is missing.' } }
    try {
        $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
        [void](Start-Process -FilePath $wscript -ArgumentList @('//B','//NoLogo',$launcher) -WindowStyle Hidden -PassThru)
        return [pscustomobject]@{ success=$true; error='' }
    } catch {
        return [pscustomobject]@{ success=$false; error=(Protect-WatchdogText $_.Exception.Message) }
    }
}

function Get-WatchdogHealthSnapshot([string]$ConfigPath, [switch]$IncludePublic) {
    $config = Read-WatchdogJson $ConfigPath
    [void](Get-WatchdogControlSettings $config)
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $services = [ordered]@{}
    foreach ($service in $script:WatchdogServiceNames) { $services[$service] = Get-WatchdogServiceHealth $service $config $processes }
    $optionalTools = Get-WatchdogOptionalToolStatus $config $processes
    $public = $null
    if ($IncludePublic) {
        $editable = Get-WatchdogEditableConfig $config
        $devspaceUrl = $editable.publicDomain.TrimEnd("/") + $editable.devspaceRoutePath + "/mcp"
        $hermesUrl = $editable.publicDomain.TrimEnd("/") + $editable.hermesRoutePath + "/mcp"
        $public = [pscustomobject][ordered]@{
            checkedUtc = ConvertTo-WatchdogIso ([DateTimeOffset]::UtcNow)
            devspace = if ([bool](Get-WatchdogProperty $config "devspaceEnabled" $true)) { Invoke-WatchdogMcpProbe $devspaceUrl } else { $null }
            hermes = if ([bool](Get-WatchdogProperty $config "hermesEnabled" $false)) { Invoke-WatchdogMcpProbe $hermesUrl } else { $null }
        }
    }
    return [pscustomobject][ordered]@{
        timestamp = ConvertTo-WatchdogIso ([DateTimeOffset]::UtcNow)
        services = [pscustomobject]$services
        optionalTools = $optionalTools
        public = $public
    }
}

function ConvertTo-WatchdogNativeArgument([string]$Value) {
    if ($Value.Contains('"') -or $Value.Contains("`r") -or $Value.Contains("`n")) { throw "Invalid native process argument." }
    $match = [regex]::Match($Value, '\\+$')
    $extra = if ($match.Success) { "\" * $match.Value.Length } else { "" }
    return '"' + $Value + $extra + '"'
}

function Start-WatchdogHiddenProcess([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [string]$OutPath, [string]$ErrPath) {
    if (-not [System.IO.File]::Exists($FilePath)) { throw "Executable is missing: $FilePath" }
    $argumentText = (@($Arguments) | ForEach-Object { ConvertTo-WatchdogNativeArgument ([string]$_) }) -join " "
    $parameters = @{
        FilePath = $FilePath
        ArgumentList = $argumentText
        NoNewWindow = $true
        PassThru = $true
    }
    if ($WorkingDirectory) { $parameters.WorkingDirectory = $WorkingDirectory }
    if ($OutPath) { $parameters.RedirectStandardOutput = $OutPath }
    if ($ErrPath) { $parameters.RedirectStandardError = $ErrPath }
    return Start-Process @parameters
}

function New-WatchdogServiceLogPath([string]$StateDir, [string]$Service, [string]$Kind) {
    [void][System.IO.Directory]::CreateDirectory($StateDir)
    return Join-Path $StateDir ("$Service-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".$Kind.log")
}

function Invoke-WithWatchdogEnvironment($Variables, [scriptblock]$Action) {
    $before = @{}
    foreach ($key in $Variables.Keys) { $before[$key] = [Environment]::GetEnvironmentVariable($key, "Process") }
    try {
        foreach ($key in $Variables.Keys) { [Environment]::SetEnvironmentVariable($key, $Variables[$key], "Process") }
        return & $Action
    } finally {
        foreach ($key in $Variables.Keys) { [Environment]::SetEnvironmentVariable($key, $before[$key], "Process") }
    }
}

function Get-WatchdogHermesEnvironment($Config) {
    $values = @{
        HERMES_HOME = Join-Path $env:LOCALAPPDATA "hermes"
    }
    $caps = Get-WatchdogProperty (Get-WatchdogProperty $Config "capabilities" $null) "hermes" $null
    if ($caps) {
        $gates = [ordered]@{
            HERMES_GPT_ENABLE_CODEX="bridge"; HERMES_GPT_ENABLE_MCP="bridge"; HERMES_GPT_ENABLE_SESSION_SEARCH="readOnlyTools"
            HERMES_GPT_ENABLE_VISION="vision"; HERMES_GPT_ENABLE_WEB="web"; HERMES_GPT_ENABLE_DIAGNOSTICS="diagnostics"
            HERMES_GPT_ENABLE_CODEX_RUNNER="runner"; HERMES_GPT_ALLOW_CODEX_WRITE="runnerWrite"; HERMES_GPT_ENABLE_WRITE="workspaceWrite"
            HERMES_GPT_ENABLE_MEMORY_WRITE="memoryWrite"; HERMES_GPT_ENABLE_TERMINAL="terminal"; HERMES_GPT_OPERATOR_ENABLED="operator"
            HERMES_GPT_ENABLE_CRON="cron"; HERMES_GPT_ALLOW_CRON_WRITE="cronWrite"; HERMES_GPT_ALLOW_SKILL_WRITE="skillWrite"
            HERMES_GPT_ALLOW_PRIVATE_NETWORK="privateNetwork"
        }
        foreach ($gate in $gates.GetEnumerator()) { $values[$gate.Key] = if ([bool](Get-WatchdogProperty $caps $gate.Value $false)) { "1" } else { $null } }
        $values["HERMES_GPT_ALLOW_WRITE"] = if ([bool](Get-WatchdogProperty $caps "cronWrite" $false) -or [bool](Get-WatchdogProperty $caps "skillWrite" $false)) { "1" } else { $null }
        $roots = @(Get-WatchdogProperty $caps "allowedRoots" @())
        if ([string](Get-WatchdogProperty $caps "filesystemScope" "restricted") -eq "full") { $roots = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root }) }
        $rootText = $roots -join ","
        $values["HERMES_GPT_CODEX_ALLOWED_ROOTS"] = $rootText
        $values["HERMES_GPT_OPERATOR_ALLOWED_PATHS"] = $rootText
        $ownerMode = [bool](Get-WatchdogProperty $caps "ownerMode" $false)
        $values["HERMES_GPT_OPERATOR_LEVEL"] = if ($ownerMode) { "owner" } elseif ([bool](Get-WatchdogProperty $caps "workspaceWrite" $false) -or [bool](Get-WatchdogProperty $caps "runner" $false)) { "workspace" } elseif ([bool](Get-WatchdogProperty $caps "skillWrite" $false)) { "skills_config" } elseif ([bool](Get-WatchdogProperty $caps "cronWrite" $false)) { "cron" } else { "read_only" }
        $values["HERMES_GPT_OPERATOR_APPLY_MODE"] = if ([bool](Get-WatchdogProperty $caps "operatorDirect" $false)) { "direct" } else { "dry_run" }
        $values["HERMES_GPT_OWNER_ACK"] = if ($ownerMode) { "I_UNDERSTAND_THIS_CAN_MUTATE_MY_MACHINE" } else { $null }
    }
    return $values
}

function Start-WatchdogManagedService([string]$Service, [string]$ConfigPath, $Config) {
    try {
        if (-not (Test-WatchdogServiceEnabled $Service $Config)) { throw "$Service is disabled in configuration." }
        $stateDir = [System.IO.Path]::GetFullPath([string]$Config.stateDir)
        $outPath = New-WatchdogServiceLogPath $stateDir $Service "out"
        $errPath = New-WatchdogServiceLogPath $stateDir $Service "err"
        $process = $null
        switch ($Service) {
            "devspace" {
                $node = [string]$Config.nodePath; $cli = [string]$Config.cliPath
                if (-not [System.IO.File]::Exists($cli)) { throw "DevSpace CLI is missing: $cli" }
                $caps = Get-WatchdogProperty (Get-WatchdogProperty $Config "capabilities" $null) "devspace" $null
                $environment = @{
                    PORT = [string]$Config.port
                    DEVSPACE_TRUST_PROXY = "true"
                    DEVSPACE_PUBLIC_BASE_URL = [string]$Config.publicBaseUrl
                    DEVSPACE_TOOL_MODE = [string](Get-WatchdogProperty $caps "toolMode" "minimal")
                    DEVSPACE_WIDGETS = [string](Get-WatchdogProperty $caps "widgets" "off")
                    DEVSPACE_SKILLS = if ([bool](Get-WatchdogProperty $caps "skills" $false)) { "1" } else { "0" }
                    DEVSPACE_SUBAGENTS = if ([bool](Get-WatchdogProperty $caps "subagents" $false)) { "1" } else { "0" }
                }
                $process = Invoke-WithWatchdogEnvironment $environment { Start-WatchdogHiddenProcess $node @($cli, "serve") (Split-Path -Parent $cli) $outPath $errPath }
            }
            "hermes" {
                $python = [string]$Config.hermesPython; $server = [string]$Config.hermesServer
                if (-not [System.IO.File]::Exists($server)) { throw "Hermes server is missing: $server" }
                $working = [string](Get-WatchdogProperty $Config "hermesWorkingDirectory" (Split-Path -Parent $server))
                $environment = Get-WatchdogHermesEnvironment $Config
                $process = Invoke-WithWatchdogEnvironment $environment { Start-WatchdogHiddenProcess $python @($server, "--http", "--host", "127.0.0.1", "--port", [string]$Config.hermesPort) $working $outPath $errPath }
            }
            "router" {
                $node = [string]$Config.nodePath; $router = [string]$Config.routerPath
                if (-not [System.IO.File]::Exists($router)) { throw "Router is missing: $router" }
                $process = Start-WatchdogHiddenProcess $node @($router, $ConfigPath) (Split-Path -Parent $router) $outPath $errPath
            }
            "ngrok" {
                $ngrok = [string]$Config.ngrokPath
                $upstreamPort = [int](Get-WatchdogProperty $Config "publicUpstreamPort" $Config.routerPort)
                $arguments = @("http", "http://127.0.0.1:$upstreamPort", "--url", [string]$Config.ngrokAgentBaseUrl)
                $webSupported = [bool](Get-WatchdogProperty $Config "ngrokWebAddrSupported" $true)
                if ($webSupported) { $arguments += @("--web-addr", "127.0.0.1:$([int]$Config.ngrokInspectorPort)") }
                if ([string](Get-WatchdogProperty $Config "ngrokBinding" "")) { $arguments += @("--binding", [string]$Config.ngrokBinding) }
                $arguments += @("--log", "stdout")
                $process = Start-WatchdogHiddenProcess $ngrok $arguments (Split-Path -Parent $ngrok) $outPath $errPath
            }
            default { throw "Unknown service: $Service" }
        }
        return [pscustomobject]@{ success=$true; pid=if ($process) { $process.Id } else { $null }; error="" }
    } catch {
        return [pscustomobject]@{ success=$false; pid=$null; error=(Protect-WatchdogText $_.Exception.Message) }
    }
}

function Get-WatchdogProcessTreeOrder([int[]]$RootPids, $Processes) {
    $ordered = New-Object System.Collections.Generic.List[int]
    $seen = @{}
    function Add-WatchdogChildren([int]$Parent) {
        if ($script:WatchdogTreeSeen[$Parent]) { return }
        $script:WatchdogTreeSeen[$Parent] = $true
        foreach ($child in @($script:WatchdogTreeProcesses | Where-Object { [int]$_.ParentProcessId -eq $Parent })) { Add-WatchdogChildren ([int]$child.ProcessId) }
        $script:WatchdogTreeOrder.Add($Parent)
    }
    $script:WatchdogTreeSeen = $seen
    $script:WatchdogTreeProcesses = $Processes
    $script:WatchdogTreeOrder = $ordered
    foreach ($root in $RootPids) { Add-WatchdogChildren $root }
    $result = @($ordered)
    Remove-Variable WatchdogTreeSeen,WatchdogTreeProcesses,WatchdogTreeOrder -Scope Script -ErrorAction SilentlyContinue
    return $result
}

function Stop-WatchdogManagedService([string]$Service, $Config) {
    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $layer = Get-WatchdogProcessLayer $Service $Config $processes
        if ($layer.identityConflict) { throw "Configured port is owned by an unrecognized process; refusing to stop it." }
        $roots = @($processes | Where-Object { Test-WatchdogManagedProcess $_ $Service $Config } | ForEach-Object { [int]$_.ProcessId })
        foreach ($processId in Get-WatchdogProcessTreeOrder $roots $processes) {
            if ($processId -gt 0 -and $processId -ne $PID) {
                try { Stop-Process -Id $processId -Force -ErrorAction Stop }
                catch { if (Get-Process -Id $processId -ErrorAction SilentlyContinue) { throw } }
            }
        }
        return [pscustomobject]@{ success=$true; stopped=$roots; error="" }
    } catch {
        return [pscustomobject]@{ success=$false; stopped=@(); error=(Protect-WatchdogText $_.Exception.Message) }
    }
}

function Restart-WatchdogManagedService([string]$Service, [string]$ConfigPath, $Config) {
    $stopped = Stop-WatchdogManagedService $Service $Config
    if (-not $stopped.success) { return $stopped }
    return Start-WatchdogManagedService $Service $ConfigPath $Config
}

function Invoke-WatchdogServiceRecovery([string]$Service, [string]$ConfigPath, $Config, $Health) {
    if ([bool](Get-WatchdogProperty $Health "identityConflict" $false)) { return [pscustomobject]@{ success=$false; error="Identity conflict blocks automatic recovery." } }
    if ([bool](Get-WatchdogProperty $Health "busyIndeterminate" $false)) { return [pscustomobject]@{ success=$false; error="Busy or indeterminate service blocks automatic recovery." } }
    $stopped = Stop-WatchdogManagedService $Service $Config
    if (-not $stopped.success) { return $stopped }
    return Start-WatchdogManagedService $Service $ConfigPath $Config
}
