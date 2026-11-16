param([switch]$Native)
$ErrorActionPreference = 'Stop'
if ($Native -and ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:RUNNER_OS -cne 'Windows' -or $env:COMPUTERNAME -eq 'C02250073')) {
    throw 'Native launcher validation requires a disposable GitHub-hosted Windows runner.'
}
. (Join-Path $PSScriptRoot 'watchdog-control-core.ps1')
function Assert-Home([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Read-TestAst([string]$Name) {
    $errors=$null; $tokens=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw "Cannot parse $Name" }
    return $ast
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('hermes-home-' + [Guid]::NewGuid().ToString('N'))
$saved=$env:HERMES_HOME
try {
    [void][IO.Directory]::CreateDirectory($root)
    $profileHome=Join-Path $root ("profile ' & % ! " + [char]0x6e2c)
    [void][IO.Directory]::CreateDirectory($profileHome)
    $env:HERMES_HOME=Join-Path $root 'unrelated-inherited-home'
    $config=@{stateDir=$root;hermesHome=$profileHome;hermesEnabled=$true;hermesPort=14750;
        hermesPython=(Join-Path $root 'python.exe');hermesServer=(Join-Path $root 'server.py');hermesWorkingDirectory=$root;
        capabilities=@{hermes=@{ownerMode=$false;filesystemScope='restricted';allowedRoots=@()}}}
    foreach ($file in @($config.hermesPython,$config.hermesServer)) { [IO.File]::WriteAllText($file,'fixture') }
    Assert-Home ((Get-WatchdogHermesEnvironment $config).HERMES_HOME -eq $profileHome) 'Configured home must override the inherited/default profile.'
    foreach ($invalid in @('relative-home','C:relative','\root-relative',(Join-Path $root 'missing'),$config.hermesServer)) {
        $config.hermesHome=$invalid
        $failed=$false
        try { Get-WatchdogHermesEnvironment $config | Out-Null } catch { $failed=$true }
        Assert-Home $failed "Invalid configured home was accepted: $invalid"
    }
    $config.hermesHome=$profileHome
    $activation=Read-TestAst 'stack-activate.ps1'
    $gatewayGuard=$activation.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-HermesGatewayLauncherInstalled'},$true)
    & {
        Invoke-Expression $gatewayGuard.Extent.Text
        function Get-ScheduledTask { return @() }
        $inheritedGateway=Join-Path $env:HERMES_HOME 'gateway-service'
        [void][IO.Directory]::CreateDirectory($inheritedGateway)
        [IO.File]::WriteAllText((Join-Path $inheritedGateway 'Hermes_Gateway.cmd'),'unrelated')
        Assert-Home (-not (Test-HermesGatewayLauncherInstalled $config)) 'Update preflight inspected the inherited home.'
        $gateway=Join-Path $profileHome 'gateway-service'
        [void][IO.Directory]::CreateDirectory($gateway)
        [IO.File]::WriteAllText((Join-Path $gateway 'Hermes_Gateway.cmd'),'preserve')
        Assert-Home (Test-HermesGatewayLauncherInstalled $config) 'Update preflight missed the configured profile gateway.'
    }
    & {
        $capture=@{home=$null;fail=$false}
        function Start-WatchdogHiddenProcess {
            $capture.home=$env:HERMES_HOME
            if ($capture.fail) { throw 'injected launch failure' }
            return @{Id=42}
        }
        $result=Start-WatchdogManagedService 'hermes' (Join-Path $root 'config.json') $config
        Assert-Home ($result.success -and $capture.home -eq $profileHome) 'Tray launch ignored the configured home.'
        Assert-Home ($env:HERMES_HOME -eq (Join-Path $root 'unrelated-inherited-home')) 'Tray launch leaked its environment.'
        $capture.fail=$true
        $result=Start-WatchdogManagedService 'hermes' (Join-Path $root 'config.json') $config
        Assert-Home (-not $result.success -and $env:HERMES_HOME -eq (Join-Path $root 'unrelated-inherited-home')) 'Failed launch leaked its environment.'
    }
    $legacy=Read-TestAst 'devspace-watchdog-legacy.ps1'
    $start=$legacy.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-Hermes'},$true)
    & {
        Invoke-Expression $start.Extent.Text
        $hermesPython=$config.hermesPython; $hermesServer=$config.hermesServer; $hermesWorkingDirectory=$root; $hermesPort=$config.hermesPort
        $hermesCommand=Join-Path $root 'old-wrapper.cmd'
        [IO.File]::WriteAllText($hermesCommand,'old wrapper; preserve')
        $capture=@{home=$null;calls=0}
        function New-ProcessLogPath { return (Join-Path $root 'unused.log') }
        function Write-WatchdogLog { }
        function Start-Process { $capture.home=$env:HERMES_HOME; $capture.calls++ }
        Start-Hermes
        Assert-Home ($capture.home -eq $profileHome -and $capture.calls -eq 1) 'Legacy direct launch ignored the selected home.'
        Assert-Home ($env:HERMES_HOME -eq (Join-Path $root 'unrelated-inherited-home')) 'Legacy launch leaked its environment.'
        $hermesPython=Join-Path $root 'missing.exe'
        $failed=$false
        try { Start-Hermes } catch { $failed=$true }
        Assert-Home ($failed -and $capture.calls -eq 1) 'A custom profile must not fall back to an unverified old wrapper.'
    }
    $installer=Read-TestAst 'install-devspace-watchdog.ps1'
    $launcher=$installer.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$hermesCommandContent'},$true)
    Invoke-Expression $launcher.Extent.Text
    $guard=$installer.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if ($installHermes -and $watchdogConfig.hermesHome)')},$true)[0]
    & {
        function Fail([string]$Message) { throw $Message }
        $installHermes=$true; $watchdogConfig=$config.Clone()
        $watchdogConfig.hermesCommand=Join-Path $root 'known-wrapper.cmd'
        [IO.File]::WriteAllText($watchdogConfig.hermesCommand,'unrecognized; preserve')
        $failed=$false
        try { Invoke-Expression $guard.Extent.Text } catch { $failed=$true }
        Assert-Home ($failed -and [IO.File]::ReadAllText($watchdogConfig.hermesCommand) -eq 'unrecognized; preserve') 'Installer accepted or overwrote an unknown wrapper for a custom profile.'
        [IO.File]::WriteAllText($watchdogConfig.hermesCommand,$hermesCommandContent)
        Invoke-Expression $guard.Extent.Text
    }
    $upgrader=Read-TestAst 'upgrade-existing-tested-stack.ps1'
    $guard=$upgrader.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if ($watchdog.hermesHome)')},$true)[0]
    & {
        function Fail([string]$Message) { throw $Message }
        $watchdog=$config
        $failed=$false
        try { Invoke-Expression $guard.Extent.Text } catch { $failed=$true }
        Assert-Home $failed 'Legacy updater must not back up/restore the wrong profile.'
    }
    if ($Native) {
        $install=Join-Path $root ("install ' & ! " + [char]0x6e2c)
        [void][IO.Directory]::CreateDirectory($install)
        foreach ($file in @('watchdog-control-core.ps1','stack-operation.ps1')) {
            [IO.File]::Copy((Join-Path $PSScriptRoot $file),(Join-Path $install $file))
        }
        $wrapper=Join-Path $install 'run-hermes-gpt.cmd'
        [IO.File]::WriteAllText($wrapper,$hermesCommandContent,[Text.Encoding]::ASCII)
        $probe=Join-Path $install 'probe.py'
        [IO.File]::WriteAllText($probe,@'
import json, os, pathlib, sys
home = pathlib.Path(os.environ['HERMES_HOME'])
(home/'launch.json').write_text(json.dumps({'home': str(home), 'agent': os.environ.get('HERMES_AGENT_ROOT'), 'owner': os.environ.get('HERMES_GPT_OWNER_ACTIVE'), 'args': sys.argv[1:]}))
raise SystemExit(37)
'@)
        $agent=Join-Path $root 'agent-source'
        [void][IO.Directory]::CreateDirectory($agent)
        $config.hermesPython=(Get-Command python.exe).Source
        $config.hermesServer=$probe
        $config.hermesWorkingDirectory=$install
        $config.hermesAgentWorkingDirectory=$agent
        $config.hermesCommand=$wrapper
        $settingsPath=Join-Path $install 'devspace-watchdog.config.json'
        Write-WatchdogAtomicJson $settingsPath $config 10
        $report=@{head=$env:GITHUB_SHA;scope='Generated CMD launcher plus inert Python probe in a disposable Windows runner; not real GPT or TYO.';passed=$false;launches=@()}
        function Invoke-NativeWrapper {
            $child=Start-Process -FilePath $env:ComSpec -ArgumentList @('/d','/s','/c',('""' + $wrapper + '""')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'wrapper.out') -RedirectStandardError (Join-Path $root 'wrapper.err')
            try {
                Assert-Home ($child.WaitForExit(15000)) 'Wrapper did not exit within its test deadline.'
                return $child.ExitCode
            } finally { $child.Dispose() }
        }
        try {
            foreach ($selected in @($profileHome,(Join-Path $root 'second-profile'))) {
                [void][IO.Directory]::CreateDirectory($selected)
                $config.hermesHome=$selected
                $config.capabilities.hermes.ownerMode=($selected -ne $profileHome)
                Write-WatchdogAtomicJson $settingsPath $config 10
                $code=Invoke-NativeWrapper
                Assert-Home ($code -eq 37) "Wrapper did not preserve Python exit code: $code"
                $result=Read-WatchdogJson (Join-Path $selected 'launch.json')
                Assert-Home ($result.home -eq $selected -and $result.agent -eq $agent) 'Wrapper ignored the configured home or source.'
                Assert-Home ($result.owner -eq $(if($config.capabilities.hermes.ownerMode){'1'}else{$null})) 'Wrapper ignored the current Owner gate.'
                Assert-Home (($result.args -join ',') -eq '--http,--host,127.0.0.1,--port,14750') 'Wrapper changed the server arguments.'
                $report.launches+=@{home=$result.home;exitCode=$code;owner=$result.owner}
            }
            $config.hermesEnabled=$false
            Write-WatchdogAtomicJson $settingsPath $config 10
            $before=[IO.File]::ReadAllText((Join-Path $selected 'launch.json'))
            $code=Invoke-NativeWrapper
            Assert-Home ($code -ne 0 -and [IO.File]::ReadAllText((Join-Path $selected 'launch.json')) -eq $before) 'Disabled Hermes must not launch.'
            $report.disabledRejected=$true
            $report.passed=$true
        } catch { $report.error=$_.Exception.Message; throw }
        finally {
            foreach ($streamName in @('wrapper.out','wrapper.err')) {
                $streamPath=Join-Path $root $streamName
                if ([IO.File]::Exists($streamPath)) { $report[$streamName]=[IO.File]::ReadAllText($streamPath) }
            }
            Write-WatchdogAtomicJson (Join-Path $env:RUNNER_TEMP 'watchdog-hermes-home.json') $report 10
        }
    }
    Write-Output 'PASS configured Hermes home, invalid-path rejection, Tray/legacy launch selection and environment restoration.'
} finally {
    $env:HERMES_HOME=$saved
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
