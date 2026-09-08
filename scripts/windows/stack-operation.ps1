[CmdletBinding()]
param([string]$RunNode, [string]$WorkerScript, [Alias('InstallDir')][string]$OperationInstallDir)

function Get-StackOperationPath([string]$InstallDir) {
    Join-Path ([IO.Path]::GetFullPath($InstallDir)) 'stack-management\operation.lock'
}

function Get-PendingStackOperation([string]$InstallDir) {
    $directory = Join-Path ([IO.Path]::GetFullPath($InstallDir)) 'stack-management'
    $activePath = Join-Path $directory 'active.json'
    if (-not [IO.File]::Exists($activePath)) { return $null }
    $active = [IO.File]::ReadAllText($activePath) | ConvertFrom-Json
    if ([string]$active.id -notmatch '^[a-f0-9]{24}$') { throw 'Invalid management operation record; recovery is required.' }
    $record = [IO.File]::ReadAllText((Join-Path $directory "jobs\$($active.id).json")) | ConvertFrom-Json
    if ($record.phase -in @('completed','failed')) { return $null }
    return $record
}

function Test-StackOperationParticipant([string]$InstallDir, $Pending) {
    if (-not $Pending -or $env:DEVSPACE_STACK_JOB_ID -cne [string]$Pending.id -or -not $env:DEVSPACE_STACK_OPERATION_TOKEN) { return $false }
    try {
        $owner = [IO.File]::ReadAllText((Join-Path $InstallDir "stack-management\jobs\$($Pending.id).owner.json")) | ConvertFrom-Json
        return $owner.token -ceq $env:DEVSPACE_STACK_OPERATION_TOKEN
    } catch { return $false }
}

function Test-StackOperationBusy([string]$InstallDir) {
    # Durable reservation outlives a console/supervisor crash. Never expire it by age.
    if (Get-PendingStackOperation $InstallDir) { return $true }
    $path = Get-StackOperationPath $InstallDir
    if (-not [IO.File]::Exists($path)) { return $false }
    try {
        $stream = [IO.File]::Open($path, 'Open', 'ReadWrite', 'Read')
        $stream.Dispose()
        return $false
    } catch [IO.IOException] { return $true }
}

function Enter-StackOperation([string]$InstallDir) {
    $path = Get-StackOperationPath $InstallDir
    [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
    try { $stream = [IO.File]::Open($path, 'OpenOrCreate', 'ReadWrite', 'Read') }
    catch [IO.IOException] {
        # A child installer joins only the operation inherited from its supervisor.
        if ($env:DEVSPACE_STACK_OPERATION_TOKEN) {
            try {
                $ownerStream = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
                $ownerReader = New-Object IO.StreamReader($ownerStream)
                try { $owner = $ownerReader.ReadToEnd() | ConvertFrom-Json } finally { $ownerReader.Dispose() }
                if ($owner.token -ceq $env:DEVSPACE_STACK_OPERATION_TOKEN -and (Test-StackOperationBusy $InstallDir)) {
                    return [pscustomobject]@{ joined=$true; stream=$null; token=$owner.token; previousToken=$env:DEVSPACE_STACK_OPERATION_TOKEN }
                }
            } catch { }
        }
        throw 'Another stack installation, update or repair is running.'
    }
    $previousToken = $env:DEVSPACE_STACK_OPERATION_TOKEN
    $pending = $null
    try {
        $pending = Get-PendingStackOperation $InstallDir
        if ($pending -and -not (Test-StackOperationParticipant $InstallDir $pending)) { throw 'A stack job is still running or requires recovery. Inspect its recorded backup before another mutation.' }
    } catch { $stream.Dispose(); throw }
    $token = if ($pending) { $env:DEVSPACE_STACK_OPERATION_TOKEN } else { [guid]::NewGuid().ToString('N') }
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((@{pid=$PID; token=$token; startedAt=[DateTimeOffset]::UtcNow.ToString('o')} | ConvertTo-Json -Compress))
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $env:DEVSPACE_STACK_OPERATION_TOKEN = $token
        return [pscustomobject]@{ joined=$false; stream=$stream; token=$token; previousToken=$previousToken }
    } catch { $stream.Dispose(); throw }
}

function Exit-StackOperation($Lease) {
    if ($null -eq $Lease -or $Lease.joined) { return }
    try { $Lease.stream.SetLength(0); $Lease.stream.Flush($true) }
    finally {
        $Lease.stream.Dispose()
        if ($env:DEVSPACE_STACK_OPERATION_TOKEN -ceq $Lease.token) { $env:DEVSPACE_STACK_OPERATION_TOKEN = $Lease.previousToken }
    }
}

if ($RunNode) {
    $ErrorActionPreference = 'Stop'
    [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    $lease = $null
    try {
        $lease = Enter-StackOperation $OperationInstallDir
        $inputJson = [Console]::In.ReadToEnd()
        $workerRequest = $inputJson | ConvertFrom-Json
        if ([string]$workerRequest.id -notmatch '^[a-f0-9]{24}$') { throw 'Invalid worker job identity.' }
        $workerJobPath = Join-Path $OperationInstallDir "stack-management\jobs\$($workerRequest.id).json"
        $env:DEVSPACE_STACK_JOB_ID = [string]$workerRequest.id
        $ownerPath = Join-Path $OperationInstallDir "stack-management\jobs\$($workerRequest.id).owner.json"
        [IO.File]::WriteAllText($ownerPath, (@{token=$lease.token;supervisorPid=$PID}|ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $RunNode
        # WorkerScript is a local generated capsule path, never a browser-supplied command.
        if ($WorkerScript.Contains('"') -or $WorkerScript.Contains("`n") -or $WorkerScript.Contains("`r")) { throw 'Invalid worker path.' }
        $psi.Arguments = '"' + $WorkerScript + '" --worker'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = 'Hidden'
        $psi.RedirectStandardInput = $true
        $child = [Diagnostics.Process]::Start($psi)
        try {
            $child.StandardInput.Write($inputJson)
            $child.StandardInput.Close()
            [Console]::Out.WriteLine('STACK_OPERATION_READY')
            $child.WaitForExit()
            $resultCode = $child.ExitCode
        } finally { $child.Dispose() }
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        $resultCode = 1
    } finally {
        if ($lease -and $workerJobPath -and [IO.File]::Exists($workerJobPath)) {
            try {
                $record = [IO.File]::ReadAllText($workerJobPath) | ConvertFrom-Json
                if ($record.phase -notin @('completed','failed','rollback_failed')) {
                    $record.phase = 'rollback_failed'; $record.exitCode = 1
                    $record.error = 'Worker stopped unexpectedly. Inspect the recorded backup before further installation changes.'
                    $record.finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
                    $temporary = $workerJobPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
                    [IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json -Depth 30 -Compress), (New-Object Text.UTF8Encoding($false)))
                    [IO.File]::Replace($temporary,$workerJobPath,$null)
                    $resultCode = 1
                }
            } catch { [Console]::Error.WriteLine('Could not finalize interrupted job; retain its operation record for recovery.') }
        }
        Exit-StackOperation $lease
    }
    exit $resultCode
}
