"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { execFileSync, spawn, spawnSync } = require("node:child_process");
const jobs = require("./stack-jobs.cjs");

const ps = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
const git = execFileSync("where.exe", ["git.exe"], { encoding: "utf8" }).trim().split(/\r?\n/)[0];
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check, description, timeout = 30000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { const value = await check(); if (value) return value; await wait(50); }
  throw new Error("Timed out: " + description);
}
function write(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, typeof value === "string" ? value : JSON.stringify(value, null, 2));
}
function gitRun(root, args) { return execFileSync(git, ["-C", root, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim(); }
function runGit(args) { return execFileSync(git, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim(); }
function request(base, route, { method = "GET", body, token, headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const target = new URL(route, base), encoded = body === undefined ? "" : JSON.stringify(body);
    const req = http.request(target, {
      method,
      headers: {
        ...(method === "POST" ? { "content-type": "application/json", origin: new URL(base).origin, "x-devspace-setup-token": token || "" } : {}),
        ...headers,
      },
    }, res => {
      let text = "";
      res.setEncoding("utf8"); res.on("data", chunk => { text += chunk; });
      res.on("end", () => { let data; try { data = JSON.parse(text); } catch {} resolve({ status: res.statusCode, text, data }); });
    });
    req.setTimeout(10000, () => req.destroy(new Error("fixture HTTP timeout")));
    req.on("error", reject); req.end(encoded);
  });
}
async function closeServer(server) {
  if (!server || server.exitCode !== null) return;
  const exited = new Promise(resolve => server.once("exit", resolve));
  server.kill(); await exited;
}
async function startServer(script, installDir, env) {
  const child = spawn(process.execPath, [script, "--no-open", "--install-dir", installDir], { windowsHide: true, env, stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "", stderr = "";
  child.stdout.on("data", chunk => { stdout += chunk.toString(); });
  child.stderr.on("data", chunk => { stderr += chunk.toString(); });
  try {
    const base = await until(() => {
      if (child.exitCode !== null) throw new Error("Setup fixture exited: " + stderr);
      return stdout.match(/DevSpace Stack Setup:\s+(http:\/\/127\.0\.0\.1:\d+\/)/)?.[1];
    }, "Setup HTTP announcement");
    const home = await request(base, "/");
    const token = home.text.match(/const setupToken="([^"]+)"/)?.[1];
    assert(token, "temporary Setup token rendered");
    return { child, base, token };
  } catch (error) { await closeServer(child); throw error; }
}
function cleanEnv(extra = {}) {
  const result = { ...process.env, ...extra };
  delete result.DEVSPACE_STACK_OPERATION_TOKEN; delete result.DEVSPACE_STACK_JOB_ID;
  return result;
}
function jobDone(installDir, id) { return ["completed", "failed", "rollback_failed"].includes(jobs.readJob(installDir, id)?.phase); }

const controlFixture = [
  "$ErrorActionPreference = 'Stop'",
  "function Get-WatchdogProperty($Object, [string]$Name, $Default = $null) { if ($null -eq $Object) { return $Default }; $property = $Object.PSObject.Properties[$Name]; if ($property) { return $property.Value }; return $Default }",
  "function ConvertTo-InstallMap($Value) { $result = [ordered]@{}; if ($null -eq $Value) { return $result }; foreach ($property in $Value.PSObject.Properties) { $result[$property.Name] = $property.Value }; return $result }",
  "function Read-WatchdogJson([string]$Path) { if (-not [IO.File]::Exists($Path)) { return $null }; return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }",
  "function Get-WatchdogFileSha256([string]$Path) { $sha = [Security.Cryptography.SHA256]::Create(); try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))).Replace('-', '').ToLowerInvariant()) } finally { $sha.Dispose() } }",
  "function Write-WatchdogAtomicJson([string]$Path, $Value, [int]$Retries = 40) { $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'; [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 40)); Move-Item -LiteralPath $temporary -Destination $Path -Force }",
  "function Test-WatchdogCommandToken([string]$CommandLine, [string]$Value) { return [bool]($Value -and $CommandLine -and $CommandLine.IndexOf($Value, [StringComparison]::OrdinalIgnoreCase) -ge 0) }",
  "function ConvertTo-WatchdogNativeArgument([string]$Value) { return $Value }",
  "function Get-TestServiceRunning { if (-not [IO.File]::Exists($env:STACK_E2E_SERVICE_STATE)) { return $false }; $last = @(Get-Content -LiteralPath $env:STACK_E2E_SERVICE_STATE)[-1]; return [bool]($last -and $last.StartsWith('start|', [StringComparison]::Ordinal)) }",
  "function Get-TestServiceIdentity($Config) { if ($Config.hermesAgentExe) { return [string]$Config.hermesAgentExe }; if ($Config.hermesServer) { return [string]$Config.hermesServer }; return [string]$Config.cliPath }",
  "function Add-TestServiceEvent([string]$Action, $Config) { Add-Content -LiteralPath $env:STACK_E2E_SERVICE_STATE -Value ($Action + '|' + (Get-TestServiceIdentity $Config)) }",
  "function Get-CimInstance { [CmdletBinding()] param([string]$ClassName, [string]$Filter); if ($Filter -or -not (Get-TestServiceRunning)) { return @() }; $config = Read-WatchdogJson $env:STACK_E2E_CONFIG_PATH; if ($config.hermesServer) { return @([pscustomobject]@{Name='python.exe'; ExecutablePath=[string]$config.hermesPython; CommandLine=([string]$config.hermesPython + ' ' + [string]$config.hermesServer + ' --http --host 127.0.0.1 --port ' + [string]$config.hermesPort); ProcessId=4242; ParentProcessId=0; CreationDate=(Get-Date).ToUniversalTime().ToString('o')}) }; return @([pscustomobject]@{Name='node.exe'; ExecutablePath=[string]$config.nodePath; CommandLine=([string]$config.nodePath + ' ' + [string]$config.cliPath + ' serve'); ProcessId=4242; ParentProcessId=0; CreationDate=(Get-Date).ToUniversalTime().ToString('o')}) }",
  "function Get-NetTCPConnection { [CmdletBinding()] param([int]$LocalPort, [string]$State); if (Get-TestServiceRunning) { return @([pscustomobject]@{OwningProcess=4242}) }; return @() }",
  "function Get-ScheduledTask { [CmdletBinding()] param([string]$TaskName, [string]$TaskPath); return @() }",
  "function Test-WatchdogManagedProcess($Process, [string]$Service, $Config) { if ($Service -eq 'hermes') { return [bool]($Process.Name -eq 'python.exe' -and [string]$Process.CommandLine -like ('*' + [string]$Config.hermesServer + '*') -and [string]$Process.CommandLine -like '* --port ' + [string]$Config.hermesPort + '*') }; return [bool]($Service -eq 'devspace' -and $Process.Name -eq 'node.exe' -and [string]$Process.CommandLine -like ('*' + [string]$Config.cliPath + '*') -and [string]$Process.CommandLine -like '* serve*') }",
  "function Get-WatchdogProcessLayer([string]$Service, $Config, $Processes) { $managed = @($Processes | Where-Object { Test-WatchdogManagedProcess $_ $Service $Config }); $pids = @($managed | ForEach-Object { [int]$_.ProcessId }); return [pscustomobject]@{processFound=($managed.Count -gt 0); listenerFound=($managed.Count -gt 0); identityConflict=$false; pid=if ($managed.Count) { $pids[0] } else { $null }; managedPids=$pids; listenerPids=$pids; unknownListenerPids=@()} }",
  "function Get-WatchdogServiceHealth([string]$Service, $Config, $Processes) { $running = Get-TestServiceRunning; return [pscustomobject]@{healthy=$running; protocolHealthy=$running; processFound=$running; listenerFound=$running; identityConflict=$false; error=''} }",
  "function Stop-WatchdogManagedService([string]$Service, $Config) { Add-TestServiceEvent 'stop' $Config; return [pscustomobject]@{success=$true; stopped=@(4242); error=''} }",
  "function Start-WatchdogManagedService([string]$Service, [string]$ConfigPath, $Config) { Add-TestServiceEvent 'start' $Config; if ([IO.File]::Exists($env:STACK_E2E_FORCE_ROLLBACK_FAILURE) -and -not $Config.hermesAgentExe) { return [pscustomobject]@{success=$false; pid=$null; error='forced rollback startup failure'} }; return [pscustomobject]@{success=$true; pid=4242; error=''} }",
].join("\n");
const bootstrapFixture = [
  "[CmdletBinding()]",
  "param([string]$Mode, [string]$ConfigPath, [string]$RuntimeDirectory)",
  "$ErrorActionPreference = 'Stop'",
  "$path = $env:STACK_E2E_BOOTSTRAP_STATE",
  "$lines = if ([IO.File]::Exists($path)) { @(Get-Content -LiteralPath $path) } else { @() }",
  "Add-Content -LiteralPath $path -Value $Mode",
  "if ($Mode -eq 'CheckStopped' -and @($lines | Where-Object { $_ -eq 'CheckStopped' }).Count -eq 0) { throw 'fixture host was running' }",
  "if ($Mode -eq 'Run' -and @($lines | Where-Object { $_ -eq 'Run' }).Count -eq 0) { throw 'forced host restart failure' }",
].join("\n");
const remoteFixture = [
  "const devLatest = process.env.STACK_E2E_DEV_LATEST; const hermesLatest = process.env.STACK_E2E_HERMES_LATEST;",
  "globalThis.fetch = async url => {",
  "  const value = String(url); let body; const hermes = value.includes('NousResearch/hermes-agent'); const latest = hermes ? hermesLatest : devLatest;",
  "  if (value.includes('registry.npmjs.org')) body = { name: '@waishnav/devspace', version: '1.0.1', dist: { integrity: 'sha512-YWJjZA==' }, gitHead: devLatest };",
  "  else if (value.includes('/releases/latest')) body = { tag_name: 'v0.1.0' };",
  "  else if (value.includes('/commits/')) body = { sha: latest };",
  "  else if (value.includes('/contents/package.json')) body = { encoding: 'base64', content: Buffer.from(JSON.stringify({ version: '1.0.1' })).toString('base64') };",
  "  else if (value.includes('/contents/pyproject.toml')) body = { encoding: 'base64', content: Buffer.from('version = \"0.1.0\"').toString('base64') };",
  "  else if (value.includes('/compare/')) body = { status: 'ahead' };",
  "  else throw new Error('unexpected fixture URL');",
  "  return { ok: true, status: 200, text: async () => JSON.stringify(body) };",
  "};",
].join("\n");

(async () => {
  assert.equal(process.platform, "win32", "component action E2E is Windows-only");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "devspace-component-action-e2e-"));
  let server;
  try {
    const packageRoot = path.join(root, "package"), scriptDir = path.join(packageRoot, "scripts", "windows");
    const installDir = path.join(root, "install"), activeRoot = path.join(root, "active");
    const remoteRoot = path.join(root, "remote.git"), authorRoot = path.join(root, "author");
    const hermesRemoteRoot = path.join(root, "hermes-agent.git"), hermesAuthorRoot = path.join(root, "hermes-author");
    const configPath = path.join(installDir, "devspace-watchdog.config.json");
    const serviceState = path.join(root, "service-events.log"), bootstrapState = path.join(root, "bootstrap-events.log"), forceRollbackFailure = path.join(root, "force-rollback-failure");
    fs.mkdirSync(scriptDir, { recursive: true }); fs.mkdirSync(installDir, { recursive: true });
    for (const file of ["devspace-stack-setup.cjs", "devspace-stack-setup.html", "stack-jobs.cjs", "stack-operation.ps1", "stack-management.cjs", "stack-setup-apply.cjs", "stack-apply-parameters.ps1", "stack-activate.ps1", "watchdog-install-transaction.ps1"]) fs.copyFileSync(path.join(__dirname, file), path.join(scriptDir, file));
    write(path.join(scriptDir, "watchdog-control-core.ps1"), controlFixture);
    write(path.join(scriptDir, "devspace-watchdog-bootstrap.ps1"), bootstrapFixture);
    write(path.join(installDir, "devspace-watchdog-bootstrap.ps1"), bootstrapFixture);
    write(path.join(scriptDir, "install-devspace-watchdog.ps1"), "param() ");
    write(path.join(scriptDir, "install-devspace-watchdog-tray.ps1"), "param() ");
    write(path.join(packageRoot, "package.json"), { name: "@fixture/devspace-stack", version: "0.0.1" });
    write(path.join(packageRoot, "dist", "cli.js"), "console.log('fixture package');");
    fs.writeFileSync(serviceState, "start|placeholder\n"); fs.writeFileSync(bootstrapState, "");

    runGit(["init", "--bare", remoteRoot]);
    fs.mkdirSync(authorRoot, { recursive: true });
    runGit(["-C", authorRoot, "init", "-b", "codex/windows-watchdog-tray-control-center"]);
    runGit(["-C", authorRoot, "config", "user.name", "fixture"]); runGit(["-C", authorRoot, "config", "user.email", "fixture@example.invalid"]);
    const sourceFiles = {
      "package.json": { name: "@waishnav/devspace", version: "1.0.0", scripts: { build: "node -e \"process.exit(0)\"", test: "node -e \"process.exit(0)\"", "test:windows-watchdog": "node -e \"process.exit(0)\"" } },
      "package-lock.json": { name: "@waishnav/devspace", version: "1.0.0", lockfileVersion: 3, requires: true, packages: { "": { name: "@waishnav/devspace", version: "1.0.0" } } },
      "dist/cli.js": "console.log('active');",
      "scripts/windows/devspace-stack-setup.cjs": "// management",
      "scripts/windows/stack-management.cjs": "// management",
      "scripts/windows/stack-host-management.ps1": "# management",
      "scripts/windows/install-devspace-watchdog-tray.ps1": "# management",
      "scripts/windows/devspace-watchdog-tray-ui.ps1": "# management",
    };
    for (const [file, contents] of Object.entries(sourceFiles)) write(path.join(authorRoot, file), contents);
    runGit(["-C", authorRoot, "add", "."]); runGit(["-C", authorRoot, "commit", "-m", "initial"]);
    const initialHead = gitRun(authorRoot, ["rev-parse", "HEAD"]);
    runGit(["-C", authorRoot, "remote", "add", "origin", remoteRoot]); runGit(["-C", authorRoot, "push", "origin", "HEAD:codex/windows-watchdog-tray-control-center"]);
    write(path.join(authorRoot, "package.json"), { ...sourceFiles["package.json"], version: "1.0.1" });
    write(path.join(authorRoot, "package-lock.json"), { ...sourceFiles["package-lock.json"], version: "1.0.1", packages: { "": { name: "@waishnav/devspace", version: "1.0.1" } } });
    write(path.join(authorRoot, "dist/cli.js"), "console.log('candidate');");
    runGit(["-C", authorRoot, "add", "."]); runGit(["-C", authorRoot, "commit", "-m", "candidate"]);
    const latestHead = gitRun(authorRoot, ["rev-parse", "HEAD"]);
    runGit(["-C", authorRoot, "push", "origin", "HEAD:codex/windows-watchdog-tray-control-center"]);
    runGit(["init", "--bare", hermesRemoteRoot]);
    fs.mkdirSync(hermesAuthorRoot, { recursive: true });
    runGit(["-C", hermesAuthorRoot, "init", "-b", "main"]);
    runGit(["-C", hermesAuthorRoot, "config", "user.name", "fixture"]); runGit(["-C", hermesAuthorRoot, "config", "user.email", "fixture@example.invalid"]);
    write(path.join(hermesAuthorRoot, "pyproject.toml"), "[build-system]\nrequires = []\nbuild-backend = \"backend\"\nbackend-path = [\".\"]\n\n[project]\nname = \"hermes-agent\"\nversion = \"0.1.0\"\n[project.optional-dependencies]\ndev = []\n[project.scripts]\nhermes = \"hermes_cli.main:main\"\n");
    write(path.join(hermesAuthorRoot, "backend.py"), [
      "import base64, hashlib, os, zipfile",
      "NAME = 'hermes_agent'; VERSION = '0.1.0'; DIST = NAME + '-' + VERSION + '.dist-info'",
      "def _files():",
      "    return {'hermes_cli/__init__.py': open('hermes_cli/__init__.py','rb').read(), 'hermes_cli/main.py': open('hermes_cli/main.py','rb').read(), DIST + '/METADATA': b'Metadata-Version: 2.1\\nName: hermes-agent\\nVersion: 0.1.0\\nProvides-Extra: dev\\n', DIST + '/WHEEL': b'Wheel-Version: 1.0\\nGenerator: fixture\\nRoot-Is-Purelib: true\\nTag: py3-none-any\\n', DIST + '/entry_points.txt': b'[console_scripts]\\nhermes = hermes_cli.main:main\\n'}",
      "def prepare_metadata_for_build_wheel(metadata_directory, config_settings=None):",
      "    target = os.path.join(metadata_directory, DIST); os.makedirs(target, exist_ok=True)",
      "    files = _files(); [open(os.path.join(metadata_directory, name), 'wb').write(data) for name, data in files.items() if name.startswith(DIST + '/')]; return DIST",
      "def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):",
      "    filename = NAME + '-' + VERSION + '-py3-none-any.whl'; files = _files(); record = []",
      "    for name, data in files.items(): record.append(name + ',sha256=' + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).decode().rstrip('=') + ',' + str(len(data)))",
      "    files[DIST + '/RECORD'] = ('\\n'.join(record) + '\\n').encode(); target = os.path.join(wheel_directory, filename)",
      "    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive:\n        [archive.writestr(name, data) for name, data in files.items()]",
      "    return filename",
    ].join("\n"));
    write(path.join(hermesAuthorRoot, "hermes_cli", "__init__.py"), "");
    write(path.join(hermesAuthorRoot, "hermes_cli", "main.py"), "import sys\ndef main():\n    if '--version' in sys.argv: print('hermes-agent 0.1.0')\n    elif '--help' in sys.argv: print('Usage: hermes-agent [OPTIONS]')\nif __name__ == '__main__': main()\n");
    write(path.join(hermesAuthorRoot, "pytest.py"), "if __name__ == '__main__': print('1 passed')\n");
    write(path.join(hermesAuthorRoot, "tests", "test_smoke.py"), "def test_smoke():\n    assert True\n");
    runGit(["-C", hermesAuthorRoot, "add", "."]); runGit(["-C", hermesAuthorRoot, "commit", "-m", "hermes-agent fixture"]);
    const hermesLatestHead = gitRun(hermesAuthorRoot, ["rev-parse", "HEAD"]);
    runGit(["-C", hermesAuthorRoot, "remote", "add", "origin", hermesRemoteRoot]); runGit(["-C", hermesAuthorRoot, "push", "origin", "HEAD:main"]);
    runGit(["clone", remoteRoot, activeRoot]); runGit(["-C", activeRoot, "checkout", "-B", "codex/windows-watchdog-tray-control-center", initialHead]);
    runGit(["-C", activeRoot, "remote", "set-url", "origin", "https://github.com/davidxyuan/devspace.git"]);
    runGit(["-C", activeRoot, "update-ref", "refs/remotes/origin/codex/windows-watchdog-tray-control-center", initialHead]);
    runGit(["-C", activeRoot, "branch", "--set-upstream-to", "origin/codex/windows-watchdog-tray-control-center"]);
    assert.equal(gitRun(activeRoot, ["status", "--porcelain"]), "");

    const pythonPath = execFileSync("where.exe", ["python.exe"], { encoding: "utf8" }).trim().split(/\r?\n/)[0];
    const oldHermesRoot = path.join(root, "old-hermes"), oldHermesServer = path.join(oldHermesRoot, "server.py");
    write(path.join(oldHermesRoot, "pyproject.toml"), "[project]\nname = \"hermes-gpt\"\nversion = \"0.5.0\"\n"); write(oldHermesServer, "# previous Hermes service fixture\n");
    const config = { stateDir: installDir, cliPath: path.join(activeRoot, "dist", "cli.js"), managementPackageRoot: activeRoot, nodePath: process.execPath, devspaceEnabled: true, hermesEnabled: true, hermesPython: pythonPath, hermesServer: oldHermesServer, hermesWorkingDirectory: oldHermesRoot, hermesPort: 18903, port: 18901, publicBaseUrl: "https://fixture.example.invalid", machineSlug: "component-e2e", routerPort: 18902 };
    write(configPath, config); write(path.join(installDir, "config.json"), { allowedRoots: [root] }); write(path.join(installDir, "auth.json"), { ownerToken: "fixture-owner" }); write(path.join(installDir, "watchdog-tray-state.json"), { desired: { devspace: "running", hermes: "running" } });
    fs.writeFileSync(serviceState, "start|" + oldHermesServer + "\n");
    const beforeConfig = fs.readFileSync(configPath), beforeAuth = fs.readFileSync(path.join(installDir, "auth.json")), beforeState = fs.readFileSync(path.join(installDir, "watchdog-tray-state.json"));
    const gitConfig = path.join(root, "gitconfig"); runGit(["config", "--file", gitConfig, "url." + remoteRoot + ".insteadOf", "https://github.com/davidxyuan/devspace.git"]); runGit(["config", "--file", gitConfig, "url." + hermesRemoteRoot + ".insteadOf", "https://github.com/NousResearch/hermes-agent.git"]);
    const preload = path.join(root, "remote-fixture.cjs"); write(preload, remoteFixture);
    const gitDir = path.dirname(git);
    const minimalPath = [gitDir, path.dirname(process.execPath), path.join(process.env.SystemRoot || "C:\\Windows", "System32"), path.join(process.env.SystemRoot || "C:\\Windows", "System32", "Wbem")].join(path.delimiter);
    const env = cleanEnv({ NODE_OPTIONS: "--require \"" + preload.replaceAll("\\", "/") + "\"", DEVSPACE_STACK_PACKAGE_ROOT: packageRoot, USERPROFILE: root, LOCALAPPDATA: path.join(root, "local"), PATH: minimalPath, GIT_CONFIG_GLOBAL: gitConfig, STACK_E2E_DEV_LATEST: latestHead, STACK_E2E_HERMES_LATEST: hermesLatestHead, STACK_E2E_CONFIG_PATH: configPath, STACK_E2E_SERVICE_STATE: serviceState, STACK_E2E_BOOTSTRAP_STATE: bootstrapState, STACK_E2E_FORCE_ROLLBACK_FAILURE: forceRollbackFailure });
    server = await startServer(path.join(scriptDir, "devspace-stack-setup.cjs"), installDir, env);
    await until(async () => (await request(server.base, "/api/components")).data?.components?.length === 12, "initial installed inventory");
    const refresh = await request(server.base, "/api/components/refresh", { method: "POST", token: server.token, body: { requestId: "component-refresh-e2e" } });
    assert.equal(refresh.status, 202, refresh.text);
    await until(() => jobDone(installDir, refresh.data.jobId), "remote inventory refresh");
    assert.equal(jobs.readJob(installDir, refresh.data.jobId).phase, "completed", JSON.stringify(jobs.readJob(installDir, refresh.data.jobId)));
    const inventory = (await request(server.base, "/api/components")).data;
    const agent = inventory.components.find(component => component.id === "hermes-agent");
    const install = agent.actions.find(action => action.id === "install");
    assert.equal(install.enabled, true, install.reason || "valid Hermes Agent install was not offered");
    const action = await request(server.base, "/api/components/action", { method: "POST", token: server.token, body: { componentId: "hermes-agent", action: "install", expectedRevision: inventory.revision, requestId: "component-action-e2e" } });
    assert.equal(action.status, 202, action.text);
    await until(() => jobDone(installDir, action.data.jobId), "full component action worker");
    const finished = jobs.readJob(installDir, action.data.jobId);
    assert.equal(finished.phase, "failed", JSON.stringify(finished));
    assert(finished.lines.some(line => /original configuration restored|Component activation failed/.test(line.text)), "activation failure did not report the rollback result");
    assert.deepEqual(fs.readFileSync(configPath), beforeConfig, "failed candidate did not restore configuration bytes");
    assert.deepEqual(fs.readFileSync(path.join(installDir, "auth.json")), beforeAuth, "failed candidate changed auth bytes");
    assert.deepEqual(fs.readFileSync(path.join(installDir, "watchdog-tray-state.json")), beforeState, "failed candidate changed tray state bytes");
    assert.equal(gitRun(activeRoot, ["rev-parse", "HEAD"]), initialHead, "active checkout was changed during candidate staging");
    assert.equal(gitRun(activeRoot, ["status", "--porcelain"]), "", "active checkout was dirtied during candidate staging");
    const serviceEvents = fs.readFileSync(serviceState, "utf8").trim().split(/\r?\n/);
    assert(serviceEvents.some(line => line === "stop|" + oldHermesServer), "previous service was not stopped");
    assert(serviceEvents.some(line => line.toLowerCase().includes(path.join("managed", "hermes-agent").toLowerCase())), "candidate service was not exercised");
    assert.equal(serviceEvents.at(-1), "start|" + oldHermesServer, "previous running service was not restored");
    const bootstrapEvents = fs.readFileSync(bootstrapState, "utf8").trim().split(/\r?\n/);
    assert.equal(bootstrapEvents.filter(line => line === "Run").length, 2, "host restart failure and rollback restart were not both exercised");
    assert(!JSON.stringify(finished).includes("fixture-owner"), "worker response leaked a configured secret");

    // A stopped-by-user service must stay stopped when activation fails.
    fs.rmSync(forceRollbackFailure, { force: true });
    fs.writeFileSync(serviceState, "stop|" + oldHermesServer + "\n");
    fs.writeFileSync(bootstrapState, "");
    write(path.join(installDir, "watchdog-tray-state.json"), { desired: { devspace: "running", hermes: "stopped_by_user" } });
    const stoppedBeforeConfig = fs.readFileSync(configPath), stoppedBeforeAuth = fs.readFileSync(path.join(installDir, "auth.json")), stoppedBeforeState = fs.readFileSync(path.join(installDir, "watchdog-tray-state.json"));
    const stoppedRefresh = await request(server.base, "/api/components/refresh", { method: "POST", token: server.token, body: { requestId: "component-refresh-stopped-e2e" } });
    assert.equal(stoppedRefresh.status, 202, stoppedRefresh.text);
    await until(() => jobDone(installDir, stoppedRefresh.data.jobId), "stopped-service inventory refresh");
    const stoppedInventory = (await request(server.base, "/api/components")).data;
    const stoppedAction = await request(server.base, "/api/components/action", { method: "POST", token: server.token, body: { componentId: "hermes-agent", action: "install", expectedRevision: stoppedInventory.revision, requestId: "component-action-stopped-e2e" } });
    assert.equal(stoppedAction.status, 202, stoppedAction.text);
    await until(() => jobDone(installDir, stoppedAction.data.jobId), "stopped-service component action worker");
    const stoppedFinished = jobs.readJob(installDir, stoppedAction.data.jobId);
    assert.equal(stoppedFinished.phase, "failed", JSON.stringify(stoppedFinished));
    assert.deepEqual(fs.readFileSync(configPath), stoppedBeforeConfig, "stopped service failure did not restore configuration bytes");
    assert.deepEqual(fs.readFileSync(path.join(installDir, "auth.json")), stoppedBeforeAuth, "stopped service failure changed auth bytes");
    assert.deepEqual(fs.readFileSync(path.join(installDir, "watchdog-tray-state.json")), stoppedBeforeState, "stopped service failure changed desired state");
    const stoppedEvents = fs.readFileSync(serviceState, "utf8").trim().split(/\r?\n/);
    assert(!stoppedEvents.some(line => line.startsWith("start|")), "stopped service was started during failed activation or rollback");
    assert(stoppedEvents.includes("stop|" + oldHermesServer), "stopped service was not inspected/stopped safely");
    assert.equal(JSON.parse(fs.readFileSync(path.join(installDir, "watchdog-tray-state.json"), "utf8")).desired.hermes, "stopped_by_user", "stopped_by_user intent was not preserved");
    assert.equal(fs.readFileSync(bootstrapState, "utf8").trim().split(/\r?\n/).filter(line => line === "Run").length, 2, "stopped-service activation failure and rollback restart were not both exercised");

    // Restore a running baseline before the injected rollback-failure case.
    fs.writeFileSync(serviceState, "start|" + oldHermesServer + "\n");
    write(path.join(installDir, "watchdog-tray-state.json"), { desired: { devspace: "running", hermes: "running" } });
    fs.writeFileSync(forceRollbackFailure, "force rollback failure");
    fs.writeFileSync(bootstrapState, "");
    const secondInventory = (await request(server.base, "/api/components")).data;
    const secondAction = await request(server.base, "/api/components/action", { method: "POST", token: server.token, body: { componentId: "hermes-agent", action: "install", expectedRevision: secondInventory.revision, requestId: "component-action-rollback-failure-e2e" } });
    assert.equal(secondAction.status, 202, secondAction.text);
    await until(() => jobDone(installDir, secondAction.data.jobId), "rollback failure component action worker");
    assert.equal(jobs.readJob(installDir, secondAction.data.jobId).phase, "rollback_failed", JSON.stringify(jobs.readJob(installDir, secondAction.data.jobId)));
    console.log("stack-component-action: /api/components/action worker staged a real candidate, failed activation, and restored service/configuration state.");
  } finally {
    if (server) await closeServer(server.child);
    const resolved = path.resolve(root), parent = path.resolve(os.tmpdir()) + path.sep;
    assert(resolved.startsWith(parent) && path.basename(resolved).startsWith("devspace-component-action-e2e-"));
    fs.rmSync(resolved, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
