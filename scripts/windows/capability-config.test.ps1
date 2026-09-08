$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "capability-config.ps1")

$manifestFixture = Join-Path ([IO.Path]::GetTempPath()) ('devspace-manifest-test-' + [guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($manifestFixture)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'capability-config.ps1') -Destination (Join-Path $manifestFixture 'capability-config.ps1')
    [IO.File]::WriteAllText((Join-Path $manifestFixture 'tested-stack-manifest.json'), '{"schemaVersion":1,"devspace":{"version":"2.1.0"},"hermes-gpt":{"version":"3.0.0"}}')
    & {
        . (Join-Path $manifestFixture 'capability-config.ps1')
        if ((Get-TestedStackAction $true ([version]'2.0.0') ([version]'3.0.0')) -ne 'UpgradeDevSpace') { throw 'Default tested versions were not loaded from the shared manifest.' }
        if ((Get-TestedStackAction $true ([version]'2.0.0') ([version]'3.0.0') ([version]'2.0.0') ([version]'3.0.0')) -ne 'CapabilitiesOnly') { throw 'Explicit tested versions were ignored.' }
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($manifestFixture)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

if ((Get-TestedStackAction $false $null $null) -ne "Fresh") { throw "Missing install must select Fresh." }
if ((Get-TestedStackAction $true ([version]"1.0.3") ([version]"0.4.0")) -ne "Upgrade") { throw "Older pair must select Upgrade." }
if ((Get-TestedStackAction $true ([version]"1.0.3") ([version]"0.5.0")) -ne "UpgradeDevSpace") { throw "Older DevSpace must select UpgradeDevSpace." }
if ((Get-TestedStackAction $true ([version]"1.0.4") ([version]"0.4.0")) -ne "UpgradeHermes") { throw "Older Hermes must select UpgradeHermes." }
$plan = Get-TestedStackPlan $true ([version]"1.0.4") ([version]"0.5.0") ([version]"1.0.4") ([version]"0.5.0") "d" "h" "d" "h"
if ($plan.action -ne "CapabilitiesOnly" -or $plan.devspaceState -ne "Keep" -or $plan.hermesState -ne "Keep") {
    throw "Current tested pair must return a structured CapabilitiesOnly plan."
}
try {
    Get-TestedStackAction $true ([version]"1.0.4") ([version]"0.5.0") ([version]"1.0.4") ([version]"0.5.0") "wrong" "h" "d" "h" | Out-Null
    throw "Equal labels with a non-pinned commit were accepted."
} catch {
    if ($_.Exception.Message -eq "Equal labels with a non-pinned commit were accepted.") { throw }
}
foreach ($versions in @(@("1.0.5","0.5.0"), @("1.0.4","0.5.1"), @("1.0.5","0.4.0"))) {
    try {
        Get-TestedStackAction $true ([version]$versions[0]) ([version]$versions[1]) | Out-Null
        throw "Unsafe version pair was accepted: $versions"
    } catch {
        if ($_.Exception.Message -like "Unsafe version pair*") { throw }
    }
}
try {
    ConvertFrom-CapabilitySelection "HermesTerminal=Maybe" | Out-Null
    throw "Invalid capability was accepted."
} catch {
    if ($_.Exception.Message -eq "Invalid capability was accepted.") { throw }
}
$selection = ConvertFrom-CapabilitySelection " HermesTerminal = On ; DevSpaceToolMode = full ; DevSpaceMcpTransport = stateless-json "
if ($selection.HermesTerminal -ne "On" -or $selection.DevSpaceToolMode -ne "full" -or $selection.DevSpaceMcpTransport -ne "stateless-json") { throw "Capability whitespace normalization failed." }
$dev = New-DevSpaceCapabilityConfig full full On On stateless-json
if ($dev.mcpTransport -ne "stateless-json") { throw "DevSpace MCP transport normalization failed." }
try {
    New-DevSpaceCapabilityConfig full full On On invalid | Out-Null
    throw "Invalid DevSpace MCP transport was accepted."
} catch {
    if ($_.Exception.Message -eq "Invalid DevSpace MCP transport was accepted.") { throw }
}
try {
    New-HermesCapabilityConfig On On Off Off On Off On Off Off Off Off Off Off Off Off Off Off restricted @() | Out-Null
    throw "Unapproved runner broadening was accepted."
} catch {
    if ($_.Exception.Message -eq "Unapproved runner broadening was accepted.") { throw }
}
$full = New-HermesCapabilityConfig On On On On On On On On On On On On On On On On On full @("C:\", "C:\")
if ($full.allowedRoots.Count -ne 1 -or -not $full.ownerMode -or -not $full.runnerWrite) { throw "Full capability profile normalization failed." }
Write-Host "capability config tests passed."
