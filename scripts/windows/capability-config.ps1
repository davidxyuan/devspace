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
        allowedRoots = @($AllowedRoots | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_) } | Select-Object -Unique)
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
        $key = $parts[0].Trim()
        $value = if ($parts.Count -eq 2) { $parts[1].Trim() } else { "" }
        if ($parts.Count -ne 2 -or -not $allowed.ContainsKey($key)) {
            throw "Unknown capability selection: $item"
        }
        if ($value -notin $allowed[$key]) {
            throw "Invalid value '$value' for capability '$key'."
        }
        $result[$key] = $value
    }
    return $result
}

function Get-TestedComponentState(
    [string]$Name,
    [version]$CurrentVersion,
    [version]$PinnedVersion,
    [string]$CurrentCommit = "",
    [string]$PinnedCommit = ""
) {
    if ($null -eq $CurrentVersion) { throw "$Name version is unknown." }
    if ($CurrentVersion -gt $PinnedVersion) {
        throw "$Name $CurrentVersion is newer than tested version $PinnedVersion; downgrade is refused."
    }
    if ($CurrentVersion -lt $PinnedVersion) {
        return [pscustomobject]@{ name=$Name; state="Upgrade"; currentVersion=$CurrentVersion; pinnedVersion=$PinnedVersion }
    }
    if ($PinnedCommit -and $CurrentCommit -ne $PinnedCommit) {
        throw "$Name version matches $PinnedVersion but commit '$CurrentCommit' does not match tested commit '$PinnedCommit'."
    }
    return [pscustomobject]@{ name=$Name; state="Keep"; currentVersion=$CurrentVersion; pinnedVersion=$PinnedVersion }
}

function Get-TestedStackPlan(
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
    if (-not $Recognized) {
        return [pscustomobject]@{ action="Fresh"; devspaceState="Fresh"; hermesState="Fresh" }
    }
    $dev = Get-TestedComponentState "DevSpace" $DevSpaceVersion $PinnedDevSpace $DevSpaceCommit $PinnedDevSpaceCommit
    $hermes = Get-TestedComponentState "Hermes-GPT" $HermesVersion $PinnedHermes $HermesCommit $PinnedHermesCommit
    $action = if ($dev.state -eq "Upgrade" -and $hermes.state -eq "Upgrade") {
        "Upgrade"
    } elseif ($dev.state -eq "Upgrade") {
        "UpgradeDevSpace"
    } elseif ($hermes.state -eq "Upgrade") {
        "UpgradeHermes"
    } else {
        "CapabilitiesOnly"
    }
    return [pscustomobject]@{ action=$action; devspaceState=$dev.state; hermesState=$hermes.state }
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
    return (Get-TestedStackPlan $Recognized $DevSpaceVersion $HermesVersion $PinnedDevSpace $PinnedHermes $DevSpaceCommit $HermesCommit $PinnedDevSpaceCommit $PinnedHermesCommit).action
}
