$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'oneclick-fresh-vm.test.ps1'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$function = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-FreshVmWorkRoot'
}, $true)
if (-not $function) { throw 'Fresh-VM work path guard is missing.' }
# Load only the filesystem guard; never execute the VM installer or bypass its host protection.
. ([scriptblock]::Create($function.Extent.Text))
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$root = Join-Path $tempBase ('devspace-fresh-vm-guard-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $fresh = Join-Path $root 'new [literal]'
    if ((New-FreshVmWorkRoot $fresh) -ne $fresh -or -not [IO.Directory]::Exists($fresh)) {
        throw 'A new literal work directory was not created.'
    }
    $sentinel = Join-Path $fresh 'keep.txt'
    [IO.File]::WriteAllText($sentinel, 'user-data')
    $existingFile = Join-Path $root 'existing-file'
    [IO.File]::WriteAllText($existingFile, 'existing-file-data')
    foreach ($path in @($fresh, $existingFile)) {
        $rejected = $false
        try { New-FreshVmWorkRoot $path | Out-Null }
        catch {
            if ($_.Exception.Message -notmatch 'already exists; preserved') { throw }
            $rejected = $true
        }
        if (-not $rejected) { throw "Existing path was accepted: $path" }
    }
    if ([IO.File]::ReadAllText($sentinel) -ne 'user-data' -or
        [IO.File]::ReadAllText($existingFile) -ne 'existing-file-data') { throw 'Existing data changed.' }
    Write-Output 'PASS fresh literal directory; existing directory and file preserved (3 cases)'
} finally {
    $item = Get-Item -LiteralPath $root -Force
    if ($item.FullName -ne $root -or -not $item.FullName.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Test cleanup identity changed; preserved.' }
    Remove-Item -LiteralPath $root -Recurse -Force
}
