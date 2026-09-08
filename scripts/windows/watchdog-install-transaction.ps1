# Installer-only helpers. Keep runtime state and secrets out of public inventory.
. (Join-Path $PSScriptRoot 'watchdog-control-core.ps1')

function Get-InstallSupervisorTaskSpec([string]$InstallDir) {
    $root = [IO.Path]::GetFullPath($InstallDir)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant()))).Replace('-', '').Substring(0,12).ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{
        name = "DevSpaceWatchdogSupervisor-$hash"
        executable = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "' + (Join-Path $root 'devspace-watchdog-bootstrap.ps1') + '" -Mode Watch -ScheduledSupervisor -ConfigPath "' + (Join-Path $root 'devspace-watchdog.config.json') + '"'
        user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
}

function Assert-InstallSupervisorTask($Task, $Spec) {
    $taskUser = [string]$Task.Principal.UserId
    if ($taskUser -and $taskUser -notmatch '^S-1-') {
        try { $taskUser = ([Security.Principal.NTAccount]::new($taskUser)).Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { throw 'Cannot resolve supervisor task account identity.' }
    }
    if (-not $Task -or $Task.TaskPath -ne '\' -or $Task.TaskName -ne $Spec.name -or
        @($Task.Actions).Count -ne 1 -or $Task.Actions[0].Execute -ne $Spec.executable -or
        $Task.Actions[0].Arguments -cne $Spec.arguments -or $taskUser -ne $Spec.user -or
        [string]$Task.Principal.LogonType -ne 'Interactive' -or [string]$Task.Principal.RunLevel -ne 'Limited' -or
        @($Task.Triggers | Where-Object { $null -ne $_ }).Count -ne 0 -or -not $Task.Settings.Enabled -or
        [string]$Task.Settings.MultipleInstances -ne 'IgnoreNew' -or [string]$Task.Settings.ExecutionTimeLimit -ne 'PT0S') {
        throw 'Supervisor scheduled task identity/settings changed; refusing to use or remove it.'
    }
}

function Wait-InstallSupervisorTaskStopped([string]$InstallDir) {
    $spec = Get-InstallSupervisorTaskSpec $InstallDir
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    do {
        $task = Get-ScheduledTask -TaskName $spec.name -TaskPath '\' -ErrorAction SilentlyContinue
        if (-not $task) { return }
        Assert-InstallSupervisorTask $task $spec
        if ([string]$task.State -notin @('Running','Queued')) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'Supervisor task has not exited after lifecycle stop; retaining task and payload.'
}

function Remove-InstallSupervisorTask([string]$InstallDir) {
    Wait-InstallSupervisorTaskStopped $InstallDir
    $spec = Get-InstallSupervisorTaskSpec $InstallDir
    $task = Get-ScheduledTask -TaskName $spec.name -TaskPath '\' -ErrorAction SilentlyContinue
    if (-not $task) { return }
    Assert-InstallSupervisorTask $task $spec
    Unregister-ScheduledTask -TaskName $spec.name -TaskPath '\' -Confirm:$false -ErrorAction Stop
}

function Resolve-InstallApprovedExecutable([string]$Executable) {
    if (-not $Executable) { return '' }
    $name = [IO.Path]::GetFileName($Executable)
    $approved = @()
    if ($name -eq 'powershell.exe') {
        $approved = @((Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'), (Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'))
    } elseif ($name -in @('wscript.exe','cscript.exe')) { $approved = @((Join-Path $env:WINDIR "System32\$name"), (Join-Path $env:WINDIR "SysWOW64\$name")) }
    elseif ($name -eq 'pwsh.exe') {
        $command = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { $approved = @([string]$command.Source) }
    }
    if (-not [IO.Path]::IsPathRooted($Executable)) {
        if ($Executable -ne $name) { return '' }
        $command = Get-Command $Executable -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { return '' }
        $Executable = [string]$command.Source
    }
    $resolved = [IO.Path]::GetFullPath($Executable)
    if ($resolved -in $approved) { return $resolved }
    return ''
}
function ConvertTo-InstallMap($Value) {
    $result = [ordered]@{}
    if ($null -eq $Value) { return $result }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { $result[$key] = $Value[$key] }
    } else {
        foreach ($property in $Value.PSObject.Properties) { $result[$property.Name] = $property.Value }
    }
    return $result
}

function Merge-InstallDefaults($Existing, $Defaults) {
    $result = ConvertTo-InstallMap $Existing
    foreach ($key in $Defaults.Keys) {
        if (-not $result.Contains($key)) { $result[$key] = $Defaults[$key] }
    }
    return $result
}

function Test-InstallTaskIdentity($Task, [string]$InstallDir) {
    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) { return $false }
    $action = $actions[0]
    $approvedExecutable = Resolve-InstallApprovedExecutable ([string]$action.Execute)
    if (-not $approvedExecutable) { return $false }
    $exe = [IO.Path]::GetFileName($approvedExecutable)
    $arguments = [string]$action.Arguments
    $root = [IO.Path]::GetFullPath($InstallDir)
    $scriptPath = [regex]::Escape((Join-Path $root 'devspace-watchdog.ps1'))
    $configPath = [regex]::Escape((Join-Path $root 'devspace-watchdog.config.json'))
    $vbsPath = [regex]::Escape((Join-Path $root 'run-devspace-watchdog-hidden.vbs'))
    if ($exe -in @('powershell.exe', 'pwsh.exe')) {
        return $arguments -notmatch '(?i)(?:^|\s)"?-(?:Command|EncodedCommand)"?(?=\s|$)' -and
            $arguments -match ('(?i)(?:^|\s)(?:"-File"|-File)\s+(?:"' + $scriptPath + '"|' + $scriptPath + ')(?=\s|$)') -and
            $arguments -match ('(?i)(?:^|\s)(?:"-ConfigPath"|-ConfigPath)\s+(?:"' + $configPath + '"|' + $configPath + ')(?=\s|$)')
    }
    return $exe -in @('wscript.exe', 'cscript.exe') -and
        $arguments -match ('(?i)^\s*(?:(?://B|//NoLogo)\s+)*(?:"' + $vbsPath + '"|' + $vbsPath + ')(?:\s+(?:"?-(?:Once|NgrokOnly)"?))*\s*$')
}

function Get-InstallLegacyProcessSnapshots([string]$InstallDir) {
    $scriptPath = Join-Path ([IO.Path]::GetFullPath($InstallDir)) 'devspace-watchdog.ps1'
    $configPath = Join-Path ([IO.Path]::GetFullPath($InstallDir)) 'devspace-watchdog.config.json'
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop)) {
        $command = [string]$process.CommandLine
        if (-not $command) { throw "Cannot inspect PowerShell PID $($process.ProcessId) to exclude an active legacy watchdog." }
        if (-not (Test-WatchdogCommandToken $command $scriptPath)) { continue }
        $approved = Resolve-InstallApprovedExecutable ([string]$process.ExecutablePath)
        $commandTask = [pscustomobject]@{Actions=@([pscustomobject]@{Execute=[string]$process.ExecutablePath;Arguments=$command})}
        if (-not $approved -or -not $process.CreationDate -or -not (Test-WatchdogCommandToken $command $configPath) -or -not (Test-InstallTaskIdentity $commandTask $InstallDir)) {
            throw "Legacy watchdog PID $($process.ProcessId) has incomplete executable/configuration identity; stop it explicitly before migration."
        }
        if ([int]$process.ProcessId -eq $PID) { throw 'Installer cannot own the legacy watchdog process identity.' }
        [pscustomobject]@{ pid=[int]$process.ProcessId; executable=$approved; creationUtc=([datetime]$process.CreationDate).ToUniversalTime().ToString('o'); once=(Test-WatchdogCommandToken $command '-Once'); ngrokOnly=(Test-WatchdogCommandToken $command '-NgrokOnly') }
    }
}

function Stop-InstallLegacyProcesses($Transaction) {
    foreach ($snapshot in @($Transaction.legacyProcesses)) {
        $matches = @(Get-InstallLegacyProcessSnapshots $Transaction.installDir | Where-Object pid -EQ $snapshot.pid)
        if (-not $matches.Count) { continue }
        if ($matches.Count -ne 1 -or $matches[0].creationUtc -ne $snapshot.creationUtc -or $matches[0].executable -ne $snapshot.executable) { throw 'Legacy watchdog PID was reused; migration is blocked.' }
        $process = Get-Process -Id $snapshot.pid -ErrorAction Stop
        try {
            if ([Math]::Abs(($process.StartTime.ToUniversalTime() - ([datetime]$snapshot.creationUtc).ToUniversalTime()).Ticks) -ge 10) { throw 'Legacy watchdog process creation time changed.' }
            $process.Kill()
            if (-not $process.WaitForExit(3000)) { throw 'Legacy watchdog did not exit.' }
            $Transaction.stoppedLegacyProcesses += $snapshot
        } finally { $process.Dispose() }
    }
    if (@(Get-InstallLegacyProcessSnapshots $Transaction.installDir).Count) { throw 'Legacy watchdog remains active; migration cannot continue.' }
}

function Restart-InstallLegacyProcesses($Transaction) {
    foreach ($snapshot in @($Transaction.stoppedLegacyProcesses)) {
        if ($snapshot.once) { continue } # A completed one-shot poll is not a persistent service.
        if (-not (Resolve-InstallApprovedExecutable ([string]$snapshot.executable))) { throw 'Legacy watchdog restart executable is not approved.' }
        if (@(Get-InstallLegacyProcessSnapshots $Transaction.installDir | Where-Object { -not $_.once -and $_.ngrokOnly -eq $snapshot.ngrokOnly }).Count) { continue }
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',(Join-Path $Transaction.installDir 'devspace-watchdog.ps1'),'-ConfigPath',(Join-Path $Transaction.installDir 'devspace-watchdog.config.json'))
        if ($snapshot.ngrokOnly) { $arguments += '-NgrokOnly' }
        $nativeArguments = @($arguments | ForEach-Object { ConvertTo-WatchdogNativeArgument $_ }) -join ' '
        $child = Start-Process -FilePath $snapshot.executable -ArgumentList $nativeArguments -WindowStyle Hidden -PassThru -ErrorAction Stop
        if (-not $child) { throw 'Previous legacy watchdog could not be restarted.' }
        if ($child.WaitForExit(250)) { $code=$child.ExitCode; $child.Dispose(); throw "Previous legacy watchdog exited during rollback startup (exit $code)." }
        $child.Dispose()
    }
}

function Get-InstallTaskSnapshots([string]$InstallDir) {
    $names = @('DevSpaceNgrokWatchdog', 'DevSpaceNgrokWatchdogPoller', 'DevSpaceNgrokWatchdogUserPoller', 'DevSpace Serve Watchdog')
    $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object TaskName -In $names)
    if (@($tasks | Group-Object TaskName | Where-Object Count -gt 1).Count) { throw 'Duplicate supported watchdog task names are ambiguous; no task was changed.' }
    foreach ($task in $tasks) {
        if (-not (Test-InstallTaskIdentity $task $InstallDir)) {
            throw "Scheduled task '$($task.TaskPath)$($task.TaskName)' does not belong to this installation; no task was changed."
        }
        [pscustomobject]@{ name=[string]$task.TaskName; path=[string]$task.TaskPath; enabled=[bool]$task.Settings.Enabled; running=([string]$task.State -eq 'Running'); xml=(Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath) }
    }
}

function Start-InstallTransaction([string]$InstallDir, [string[]]$Paths, [object[]]$Tasks, [object[]]$LegacyProcesses = @()) {
    $backup = Join-Path $InstallDir ('configuration-backups\stack-install-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($backup)
    $files = @()
    foreach ($target in @($Paths | Select-Object -Unique)) {
        $target = [IO.Path]::GetFullPath($target)
        $exists = [IO.File]::Exists($target)
        $saved = Join-Path $backup ('file-' + $files.Count)
        if ($exists) { [IO.File]::Copy($target, $saved, $false) }
        $files += [pscustomobject]@{ target=$target; existed=$exists; backup=$saved; sha256=$(if ($exists) { Get-WatchdogFileSha256 $saved } else { '' }) }
    }
    $transaction = [pscustomobject]@{ schemaVersion=1; installDir=$InstallDir; backupPath=$backup; files=$files; tasks=@($Tasks); disabledTasks=@(); createdTasks=@(); legacyProcesses=@($LegacyProcesses); stoppedLegacyProcesses=@(); completed=$false }
    [IO.File]::WriteAllText((Join-Path $backup 'transaction.json'), ($transaction | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    return $transaction
}

function Disable-InstallLegacyTasks($Transaction) {
    foreach ($snapshot in $Transaction.tasks) {
        $task = Get-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop
        if (-not (Test-InstallTaskIdentity $task $Transaction.installDir) -or
            (Export-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path) -ne $snapshot.xml) {
            throw "Legacy task changed after inspection: $($snapshot.name)"
        }
        Disable-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop | Out-Null
        $Transaction.disabledTasks += $snapshot.name
        if ($snapshot.running) { Stop-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop }
    }
}

function Undo-InstallTransaction($Transaction) {
    # Verify every backup before restoring any byte.
    foreach ($item in $Transaction.files) {
        if ($item.existed -and (-not [IO.File]::Exists($item.backup) -or (Get-WatchdogFileSha256 $item.backup) -ne $item.sha256)) {
            throw "Installation rollback backup is missing or corrupt: $($item.backup)"
        }
    }
    foreach ($created in @($Transaction.createdTasks)) {
        $task = Get-ScheduledTask -TaskName $created.name -TaskPath $created.path -ErrorAction SilentlyContinue
        if (-not $task) { continue }
        if (-not (Test-InstallTaskIdentity $task $Transaction.installDir)) { throw 'New scheduled task changed owner during rollback.' }
        if ([string]$task.State -eq 'Running') { Stop-ScheduledTask -TaskName $created.name -TaskPath $created.path -ErrorAction Stop }
        Unregister-ScheduledTask -TaskName $created.name -TaskPath $created.path -Confirm:$false -ErrorAction Stop
    }
    foreach ($item in $Transaction.files) {
        if ($item.existed) { [IO.File]::Copy($item.backup, $item.target, $true) }
        elseif ([IO.File]::Exists($item.target)) { [IO.File]::Delete($item.target) }
    }
    foreach ($snapshot in $Transaction.tasks) {
        if ($snapshot.name -notin $Transaction.disabledTasks) { continue }
        $task = Get-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop
        if (-not (Test-InstallTaskIdentity $task $Transaction.installDir)) { throw "Legacy task identity changed during rollback: $($snapshot.name)" }
        if ($snapshot.enabled) { Enable-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop | Out-Null }
        else { Disable-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop | Out-Null }
        if ($snapshot.running -and $snapshot.enabled) { Start-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop }
    }
}

function Restore-InstallLegacyTaskBackups($Manifest, [string]$BackupPath, [string]$InstallDir, [switch]$StartPreviouslyRunning) {
    foreach ($snapshot in @($Manifest.legacyTasks)) {
        if ([string]$snapshot.name -notmatch '^[A-Za-z0-9 _.()-]{1,100}$' -or [string]$snapshot.xml -ne "$($snapshot.name).xml") { throw 'Invalid legacy task backup identity.' }
        $xmlPath = Join-Path $BackupPath ([string]$snapshot.xml)
        if (-not [IO.File]::Exists($xmlPath) -or (Get-WatchdogFileSha256 $xmlPath) -ne [string]$snapshot.sha256) { throw 'Legacy task backup is missing or corrupt.' }
        $xmlText = [IO.File]::ReadAllText($xmlPath)
        [xml]$xml = $xmlText
        $actions = @($xml.Task.Actions.Exec | ForEach-Object { [pscustomobject]@{Execute=[string]$_.Command;Arguments=[string]$_.Arguments} })
        if (-not (Test-InstallTaskIdentity ([pscustomobject]@{Actions=$actions}) $InstallDir)) { throw 'Legacy task XML targets another installation.' }
        $current = Get-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction SilentlyContinue
        if ($current -and -not (Test-InstallTaskIdentity $current $InstallDir)) { throw 'Current legacy task has an unknown owner.' }
        Register-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -Xml $xmlText -Force -ErrorAction Stop | Out-Null
        if ($snapshot.enabled) { Enable-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop | Out-Null }
        else { Disable-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop | Out-Null }
        if ($StartPreviouslyRunning -and $snapshot.enabled -and $snapshot.running) { Start-ScheduledTask -TaskName $snapshot.name -TaskPath $snapshot.path -ErrorAction Stop }
    }
}
