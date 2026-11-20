$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows') {
    throw 'This test requires a disposable GitHub-hosted Windows runner.'
}
$prepared = Join-Path $env:RUNNER_TEMP 'hermes-pm-candidate'
$name = 'HermesLauncherTest-' + [Guid]::NewGuid().ToString('N')
$directory = New-Item -ItemType Directory -Path (Join-Path $env:RUNNER_TEMP $name)
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& "$prepared/runtime/Scripts/python.exe" -I -B -X utf8 "$PSScriptRoot/hermes-launcher.py" $prepared $directory.FullName $user
if ($LASTEXITCODE) { throw 'Official launcher exit-code checks failed' }
[xml]$xml = Get-Content -LiteralPath (Join-Path $directory 'task.xml') -Raw
$task = $xml.Task
if ($task.Principals.Principal.RunLevel -ne 'LeastPrivilege' -or $task.Principals.Principal.LogonType -ne 'InteractiveToken' -or
    $task.Settings.RestartOnFailure.Interval -ne 'PT1M' -or $task.Settings.RestartOnFailure.Count -lt 1) {
    throw 'Official task settings do not match the restart scenario'
}
# Exercise the real scheduler without installing a logon trigger. One retry suffices.
$triggers = $task.SelectSingleNode("*[local-name()='Triggers']")
$triggers.RemoveAll()
$trigger = $xml.CreateElement('TimeTrigger', $task.NamespaceURI)
$start = $xml.CreateElement('StartBoundary', $task.NamespaceURI)
$start.InnerText = (Get-Date).AddSeconds(15).ToString('yyyy-MM-ddTHH:mm:ss')
[void]$trigger.AppendChild($start)
[void]$triggers.AppendChild($trigger)
$task.Settings.RestartOnFailure.Count = '1'
$registered = Register-ScheduledTask -TaskName $name -TaskPath '\' -Xml $xml.OuterXml
$receipt = [ordered]@{ task=$name; source=$env:AGENT_REVISION; exitCodes=(Get-Content (Join-Path $directory 'exit-codes.json') -Raw | ConvertFrom-Json); runs=@(); removed=$false; passed=$false }
try {
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    do {
        Start-Sleep -Seconds 2
        $files = @(Get-ChildItem -LiteralPath (Join-Path $directory 'scheduled') -Filter 'launch-*.json' -File | Sort-Object Name)
        $status = Get-ScheduledTask -TaskName $name -TaskPath '\'
        $info = Get-ScheduledTaskInfo -TaskName $name -TaskPath '\'
        if ($files.Count -ge 2 -and $status.State -eq 'Ready') { break }
    } while ([DateTime]::UtcNow -lt $deadline)
    $receipt.runs = @($files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
    $receipt.lastTaskResult = $info.LastTaskResult
    if ($files.Count -ne 2 -or ($receipt.runs.code -join ',') -ne '37,0' -or $status.State -ne 'Ready' -or $info.LastTaskResult -ne 0) {
        throw "Expected one scheduled recovery after exit 37. Runs=$($files.Count), state=$($status.State), result=$($info.LastTaskResult)"
    }
    $receipt.passed = $true
} finally {
    try {
        $actual = Get-ScheduledTask -TaskName $name -TaskPath '\'
        if ($actual.State -eq 'Running' -or $actual.Actions.Count -ne 1 -or
            $actual.Actions[0].Execute -cne $registered.Actions[0].Execute -or $actual.Actions[0].Arguments -cne $task.Actions.Exec.Arguments -or
            $actual.Principal.UserId -ne $registered.Principal.UserId -or $actual.Description -cne $task.RegistrationInfo.Description) { throw 'Task identity or state changed' }
        Unregister-ScheduledTask -InputObject $actual -Confirm:$false
        $receipt.removed = $true
    } finally {
        $receipt | ConvertTo-Json -Depth 5 | Set-Content "$prepared/windows-launcher.json"
        $receipt | ConvertTo-Json -Depth 5 | Write-Output
    }
}
