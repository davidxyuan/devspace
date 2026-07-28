$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "capability-config.ps1")

if ((Get-TestedStackAction $false $null $null) -ne "Fresh") { throw "Missing install must select Fresh." }
if ((Get-TestedStackAction $true ([version]"1.0.3") ([version]"0.4.0")) -ne "Upgrade") { throw "Older pair must select Upgrade." }
if ((Get-TestedStackAction $true ([version]"1.0.3") ([version]"0.5.0")) -ne "UpgradeDevSpace") { throw "Older DevSpace must select UpgradeDevSpace." }
if ((Get-TestedStackAction $true ([version]"1.0.4") ([version]"0.4.0")) -ne "UpgradeHermes") { throw "Older Hermes must select UpgradeHermes." }
if ((Get-TestedStackAction $true ([version]"1.0.4") ([version]"0.5.0")) -ne "CapabilitiesOnly") { throw "Equal pair must select CapabilitiesOnly." }
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
try {
    New-HermesCapabilityConfig On On Off Off On Off On Off Off Off Off Off Off Off Off Off Off restricted @() | Out-Null
    throw "Unapproved runner broadening was accepted."
} catch {
    if ($_.Exception.Message -eq "Unapproved runner broadening was accepted.") { throw }
}
Write-Host "capability config tests passed."
