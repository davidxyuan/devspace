function Convert-CapabilitySwitch([string]$Value) {
    if ($Value -notin @("On", "Off")) { throw "Capability values must be On or Off." }
    return $Value -eq "On"
}

function New-DevSpaceCapabilityConfig(
    [string]$ToolMode,
    [string]$Widgets,
    [string]$Skills,
    [string]$Subagents
) {
    if ($ToolMode -notin @("minimal", "full", "codex")) { throw "Invalid DevSpace tool mode: $ToolMode" }
    if ($Widgets -notin @("off", "changes", "full")) { throw "Invalid DevSpace widgets mode: $Widgets" }
    [ordered]@{
        toolMode = $ToolMode
        widgets = $Widgets
        skills = Convert-CapabilitySwitch $Skills
        subagents = Convert-CapabilitySwitch $Subagents
    }
}

function New-HermesCapabilityConfig(
    [string]$Bridge, [string]$ReadOnlyTools, [string]$Vision, [string]$Web,
    [string]$Diagnostics, [string]$Runner, [string]$RunnerWrite,
    [string]$WorkspaceWrite, [string]$MemoryWrite, [string]$Terminal,
    [string]$Operator, [string]$OperatorDirect, [string]$OwnerMode,
    [string]$Cron, [string]$CronWrite, [string]$SkillWrite,
    [string]$PrivateNetwork, [string]$FilesystemScope, [string[]]$AllowedRoots
) {
    if ($FilesystemScope -notin @("restricted", "full")) { throw "Invalid Hermes filesystem scope: $FilesystemScope" }
    $values = [ordered]@{
        bridge = Convert-CapabilitySwitch $Bridge
        readOnlyTools = Convert-CapabilitySwitch $ReadOnlyTools
        vision = Convert-CapabilitySwitch $Vision
        web = Convert-CapabilitySwitch $Web
        diagnostics = Convert-CapabilitySwitch $Diagnostics
        runner = Convert-CapabilitySwitch $Runner
        runnerWrite = Convert-CapabilitySwitch $RunnerWrite
        workspaceWrite = Convert-CapabilitySwitch $WorkspaceWrite
        memoryWrite = Convert-CapabilitySwitch $MemoryWrite
        terminal = Convert-CapabilitySwitch $Terminal
        operator = Convert-CapabilitySwitch $Operator
        operatorDirect = Convert-CapabilitySwitch $OperatorDirect
        ownerMode = Convert-CapabilitySwitch $OwnerMode
        cron = Convert-CapabilitySwitch $Cron
        cronWrite = Convert-CapabilitySwitch $CronWrite
        skillWrite = Convert-CapabilitySwitch $SkillWrite
        privateNetwork = Convert-CapabilitySwitch $PrivateNetwork
        filesystemScope = $FilesystemScope
        allowedRoots = @($AllowedRoots | Where-Object { $_ })
    }
    if ($values.runnerWrite -and -not $values.runner) { throw "Runner write requires Runner." }
    if (($values.runner -or $values.workspaceWrite -or $values.cronWrite -or $values.skillWrite -or $values.operatorDirect) -and -not $values.operator) {
        throw "Mutation and direct-apply capabilities require Operator."
    }
    if (($values.runner -or $values.workspaceWrite -or $values.cronWrite -or $values.skillWrite) -and -not $values.operatorDirect) {
        throw "Runner and mutation capabilities require Operator direct apply."
    }
    if ($values.cronWrite -and -not $values.cron) { throw "Cron write requires Cron." }
    if ($values.ownerMode -and (-not $values.operator -or -not $values.operatorDirect)) {
        throw "Owner mode requires Operator and direct apply."
    }
    if (($values.runner -or $values.workspaceWrite -or $values.operatorDirect) -and
        $values.filesystemScope -eq "restricted" -and $values.allowedRoots.Count -eq 0) {
        throw "Runner, workspace write, and direct apply require at least one allowed root."
    }
    return $values
}

function ConvertFrom-CapabilitySelection([string]$Selection) {
    $allowed = @{
        DevSpaceToolMode = @("minimal", "full", "codex")
        DevSpaceWidgets = @("off", "changes", "full")
        DevSpaceSkills = @("On", "Off"); DevSpaceSubagents = @("On", "Off")
        HermesBridge = @("On", "Off"); HermesReadOnlyTools = @("On", "Off")
        HermesVision = @("On", "Off"); HermesWeb = @("On", "Off")
        HermesDiagnostics = @("On", "Off"); HermesRunner = @("On", "Off")
        HermesRunnerWrite = @("On", "Off"); HermesWorkspaceWrite = @("On", "Off")
        HermesMemoryWrite = @("On", "Off"); HermesTerminal = @("On", "Off")
        HermesOperator = @("On", "Off"); HermesOperatorDirect = @("On", "Off")
        HermesOwnerMode = @("On", "Off"); HermesCron = @("On", "Off")
        HermesCronWrite = @("On", "Off"); HermesSkillWrite = @("On", "Off")
        HermesPrivateNetwork = @("On", "Off")
        HermesFilesystemScope = @("restricted", "full")
    }
    $result = @{}
    foreach ($item in @($Selection -split ";")) {
        if (-not $item.Trim()) { continue }
        $parts = $item.Split("=", 2)
        if ($parts.Count -ne 2 -or -not $allowed.ContainsKey($parts[0])) {
            throw "Unknown capability selection: $item"
        }
        if ($parts[1] -notin $allowed[$parts[0]]) {
            throw "Invalid value '$($parts[1])' for capability '$($parts[0])'."
        }
        $result[$parts[0]] = $parts[1]
    }
    return $result
}

function Get-TestedStackAction(
    [bool]$Recognized,
    [version]$DevSpaceVersion,
    [version]$HermesVersion,
    [version]$PinnedDevSpace = [version]"1.0.4",
    [version]$PinnedHermes = [version]"0.5.0",
    [string]$DevSpaceCommit = "",
    [string]$HermesCommit = "",
    [string]$PinnedDevSpaceCommit = "",
    [string]$PinnedHermesCommit = ""
) {
    if (-not $Recognized) { return "Fresh" }
    if ($DevSpaceVersion -gt $PinnedDevSpace -or $HermesVersion -gt $PinnedHermes) {
        throw "Newer or unknown tested-stack versions are not safe to change."
    }

    $upgradeDevSpace = $DevSpaceVersion -lt $PinnedDevSpace
    $upgradeHermes = $HermesVersion -lt $PinnedHermes

    if (-not $upgradeDevSpace -and $PinnedDevSpaceCommit -and $DevSpaceCommit -ne $PinnedDevSpaceCommit) {
        throw "DevSpace version matches but the pinned tested commit does not."
    }
    if (-not $upgradeHermes -and $PinnedHermesCommit -and $HermesCommit -ne $PinnedHermesCommit) {
        throw "Hermes-GPT version matches but the pinned tested commit does not."
    }

    if ($upgradeDevSpace -and $upgradeHermes) { return "Upgrade" }
    if ($upgradeDevSpace) { return "UpgradeDevSpace" }
    if ($upgradeHermes) { return "UpgradeHermes" }
    return "CapabilitiesOnly"
}
