$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'watchdog-control-core.ps1')
function Assert-Capture($Value, $Message) { if (-not $Value) { throw $Message } }
$root = Join-Path ([IO.Path]::GetTempPath()) ('watchdog-capture-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$ConfigPath = Join-Path $root 'config.json'
$window = Join-Path $root 'watchdog-diagnostics-window.json'
$heartbeat = Join-Path $root 'watchdog-host-heartbeat.json'
$event = $null; $child = $null
try {
    Write-WatchdogCaptureEvent $ConfigPath 'disabled'
    Assert-Capture (-not [IO.Directory]::Exists((Join-Path $root 'watchdog-diagnostics'))) 'Disabled tracing wrote files.'
    [IO.File]::WriteAllText($window, (@{id='test';endUtc=[DateTimeOffset]::UtcNow.AddMinutes(3).ToString('o')} | ConvertTo-Json))
    [IO.File]::WriteAllText($ConfigPath, (@{stateDir=$root} | ConvertTo-Json))
    Write-WatchdogAtomicJson $heartbeat @{pid=123;processStartUtc='2026-10-12T00:00:00Z';timestamp=[DateTimeOffset]::UtcNow.ToString('o')}
    $reader = [IO.File]::OpenText($heartbeat)
    $blocked = $false
    try { Write-WatchdogAtomicJson $heartbeat @{pid=456} } catch { $blocked = $true }
    finally { $reader.Dispose() }
    Assert-Capture $blocked 'Expected replacement conflict while a normal .NET text reader is open.'
    $stream = [IO.File]::Open($heartbeat,'Open','Read',[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { Write-WatchdogAtomicJson $heartbeat @{pid=123;processStartUtc='fixture';timestamp=[DateTimeOffset]::UtcNow.ToString('o')} }
    finally { $stream.Dispose() }
    Assert-Capture (((Read-WatchdogCaptureText $heartbeat)|ConvertFrom-Json).pid -eq 123) 'Sharing-safe observation failed.'
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ConfigPath.ToLowerInvariant()))).Replace('-','').Substring(0,20) }
    finally { $sha.Dispose() }
    $event=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,"Local\DevSpaceWatchdogHostStop-$hash")
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments='-NoProfile -File "'+(Join-Path $PSScriptRoot 'devspace-watchdog-tray.ps1')+'" -Mode StopHost -ConfigPath "'+$ConfigPath+'"'
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.WindowStyle='Hidden'
    $child=[Diagnostics.Process]::Start($psi)
    Assert-Capture ($event.WaitOne(15000)) 'Real isolated StopHost helper did not set its named event.'
    Assert-Capture ($child.WaitForExit(15000)) 'Isolated helper failed to exit.'
    Assert-Capture ($child.ExitCode -eq 0) 'Stop helper failed.'
    $traces=@(Get-ChildItem (Join-Path $root 'watchdog-diagnostics\test') -Filter '*.jsonl' | ForEach-Object { Get-Content $_.FullName | ForEach-Object {$_|ConvertFrom-Json} })
    $sent=@($traces|Where-Object event -eq 'stop_signal_sending')
    Assert-Capture ($sent.Count -eq 1 -and $sent[0].pid -eq $child.Id -and $sent[0].target.pid -eq 123) 'Sender PID/target correlation missing.'
    Assert-Capture (@($traces|Where-Object event -eq 'stop_signal_sent').Count -eq 1) 'Post-send evidence missing.'
    Assert-Capture (@($traces|Where-Object event -eq 'atomic_write_failed').Count -eq 1) 'Sharing failure evidence missing.'
    [IO.File]::WriteAllText($window, (@{id='test';endUtc=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')}|ConvertTo-Json))
    Write-WatchdogCaptureEvent $ConfigPath 'expired'
    Assert-Capture (-not (Get-ChildItem (Join-Path $root 'watchdog-diagnostics\test') -Filter '*.jsonl' | Select-String '"event":"expired"')) 'Expired trace window still logged.'
    Write-Host 'Capture: isolated real stop sender/target, shared-delete reader, sharing-failure evidence, disabled/expired windows passed.'
} finally {
    if ($event) { $event.Dispose() }
    if ($child) { if (-not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(5000) }; $child.Dispose() }
    $resolved=[IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'watchdog-capture-test-*') { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
