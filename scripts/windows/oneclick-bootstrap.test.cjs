"use strict";

// Real bootstrap processes, with a harmless Node command fixture. No package manager is invoked.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");

if (process.platform !== "win32") { console.log("oneclick-bootstrap: Windows checks skipped on this platform"); process.exit(0); }
const tempBase = path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"), "Temp");
const root = fs.mkdtempSync(path.join(tempBase, "devspace-oneclick-bootstrap-test-"));
const powershell = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
const bootstrap = path.join(__dirname, "install-devspace-stack.ps1");
const digest = content => crypto.createHash("sha256").update(content).digest("hex");
const results = [];
function write(file, content) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, typeof content === "string" ? content : JSON.stringify(content, null, 2)); }
function ps(script, args = [], env = {}) {
  const childEnv = { ...process.env };
  // Windows environment names are case insensitive; remove aliases before overriding Path.
  const overrides = { PSModulePath: path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "Modules"), ...env };
  for (const [key, value] of Object.entries(overrides)) {
    for (const existing of Object.keys(childEnv)) if (existing.toLowerCase() === key.toLowerCase()) delete childEnv[existing];
    childEnv[key] = value;
  }
  const result = spawnSync(powershell, ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", script, ...args], { encoding: "utf8", timeout: 30000, windowsHide: true, env: childEnv });
  if (result.error) result.stderr = `${result.error.message}\n${result.stdout || ""}\n${result.stderr || ""}`;
  return result;
}
function nodeFixture(dir, version = "24.14.0", exitCode = 0) {
  const file = path.join(dir, `node-${version.replace(/[^\w.-]/g, "_")}-${exitCode}.cmd`);
  const log = path.join(dir, "node-launch.log");
  write(file, `@echo off\r\nif "%~1"=="--version" (\r\n  echo v${version}\r\n  exit /b ${exitCode}\r\n)\r\necho %*>>"${log}"\r\nexit /b 0\r\n`);
  return { file, log };
}
function test(name, check) {
  try { check(); results.push({ name, ok: true }); console.log(`PASS ${name}`); }
  catch (error) { results.push({ name, ok: false }); console.error(`FAIL ${name}: ${error.message}`); }
}
function fixture(name) {
  const dir = path.join(root, name), installDir = path.join(dir, "installation"), local = path.join(dir, "local"), packageRoot = path.join(dir, "package");
  const node = nodeFixture(path.join(dir, "tools"));
  const config = { nodePath: node.file, customSetting: "preserve", ngrokAuthtoken: "fixture-secret" };
  write(path.join(installDir, "devspace-watchdog.config.json"), config);
  write(path.join(installDir, "auth.json"), { ownerToken: "fixture-owner" });
  write(path.join(packageRoot, "package.json"), { name: "@waishnav/devspace", version: "1.0.4" });
  write(path.join(packageRoot, "scripts", "windows", "devspace-stack-setup.cjs"), "throw new Error('A fixture must never execute real setup');\n");
  const copiedBootstrap = path.join(packageRoot, "scripts", "windows", "install-devspace-stack.ps1");
  fs.copyFileSync(bootstrap, copiedBootstrap);
  const files = ["package.json", "scripts/windows/devspace-stack-setup.cjs", "scripts/windows/install-devspace-stack.ps1"].map(relative => ({ path: relative, sha256: digest(fs.readFileSync(path.join(packageRoot, relative))) }));
  function manifest(entries = files) {
    const fingerprint = digest(entries.map(file => `${file.path}:${file.sha256}`).join("\n"));
    write(path.join(packageRoot, "oneclick-payload.json"), { schemaVersion: 1, fingerprint, source: "workspace", head: "a".repeat(40), dirty: true, files: entries });
    return path.join(local, "DevSpaceStack", "packages", fingerprint);
  }
  // The child cannot resolve winget or a real PATH Node if a compatibility probe fails.
  // ProgramFiles is isolated too; this keeps negative cases from installing dependencies.
  return { dir, installDir, local, packageRoot, copiedBootstrap, node, files, manifest, invoke: (...args) => ps(copiedBootstrap, ["-InstallDir", installDir, "-NoOpen", ...args], { LOCALAPPDATA: local, ProgramFiles: path.join(dir, "programs"), PATH: path.join(process.env.SystemRoot || "C:\\Windows", "System32") }) };
}

try {
  test("InspectOnly reuses the configured compatible Node and preserves installation", () => {
    const f = fixture("inspect"), config = path.join(f.installDir, "devspace-watchdog.config.json"), before = fs.readFileSync(config);
    const result = f.invoke("-InspectOnly");
    assert.equal(result.status, 0, result.stderr);
    const detected = JSON.parse(result.stdout.trim());
    assert.equal(detected.nodePath, f.node.file); assert.equal(detected.nodeCompatible, true);
    assert.equal(detected.installDir, f.installDir);
    assert.equal(fs.existsSync(f.node.log), false, "InspectOnly never launches Setup");
    assert.equal(fs.existsSync(f.local), false, "InspectOnly never stages an install");
    assert.deepEqual(fs.readFileSync(config), before);
    assert.doesNotMatch(result.stdout, /fixture-secret|fixture-owner/);
  });

  test("invalid existing configuration fails before any install or copy", () => {
    const f = fixture("invalid-config"), config = path.join(f.installDir, "devspace-watchdog.config.json");
    write(config, "{invalid json");
    const result = f.invoke("-InspectOnly");
    assert.notEqual(result.status, 0);
    assert.equal(fs.readFileSync(config, "utf8"), "{invalid json");
    assert.equal(fs.existsSync(f.node.log), false); assert.equal(fs.existsSync(f.local), false);
  });

  test("actual Node probe rejects missing, old, future and failed runtimes", () => {
    const dir = path.join(root, "version-probes");
    const cases = [
      { version: "22.18.0", expected: false }, { version: "22.19.0", expected: true },
      { version: "24.14.0", expected: true }, { version: "26.0.0", expected: true },
      { version: "27.0.0", expected: false }, { version: "24.14.0", exitCode: 1, expected: false },
    ].map(c => ({ ...c, file: nodeFixture(dir, c.version, c.exitCode || 0).file }));
    cases.push({ file: path.join(dir, "missing.exe"), expected: false });
    const caseFile = path.join(dir, "cases.json"); write(caseFile, cases);
    const runner = path.join(dir, "probe.ps1");
    write(runner, `param([string]$Bootstrap,[string]$Cases)\n$ErrorActionPreference='Stop'\n$tokens=$null;$errors=$null\n$ast=[Management.Automation.Language.Parser]::ParseFile($Bootstrap,[ref]$tokens,[ref]$errors)\nif($errors.Count){throw 'Parser errors'}\n$function=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-StackNode'},$true)\nif(-not $function){throw 'Node detection function missing'}\n. ([scriptblock]::Create($function.Extent.Text))\nforeach($case in (Get-Content -LiteralPath $Cases -Raw | ConvertFrom-Json)){if((Test-StackNode $case.file) -ne $case.expected){throw ('Incorrect Node compatibility: '+$case.file)}}\nWrite-Output 'Node version matrix passed'\n`);
    const result = ps(runner, ["-Bootstrap", bootstrap, "-Cases", caseFile]);
    assert.equal(result.status, 0, result.stderr); assert.match(result.stdout, /matrix passed/);
    assert.equal(fs.existsSync(path.join(dir, "node-launch.log")), false);
  });

  test("missing Node and winget reports the prerequisite boundary without installing", () => {
    const f = fixture("missing-tools"), runner = path.join(f.dir, "missing-tools.ps1");
    // Windows restores ProgramFiles during startup, so isolate this branch using its actual AST
    // instead of hiding the machine's real Node or ever calling a package manager.
    write(runner, `param([string]$Bootstrap)\n$ErrorActionPreference='Stop'\n$tokens=$null;$errors=$null\n$ast=[Management.Automation.Language.Parser]::ParseFile($Bootstrap,[ref]$tokens,[ref]$errors)\n$guard=@($ast.EndBlock.Statements|Where-Object {$_.Extent.Text.StartsWith('if (-not $node)')})\nif($guard.Count -ne 1){throw 'Node installation guard missing'}\n$node=$null;$winget=$null\ntry {. ([scriptblock]::Create($guard[0].Extent.Text)); throw 'Missing prerequisites unexpectedly succeeded'}catch{if($_.Exception.Message -notmatch 'winget.*missing|App Installer'){throw};Write-Output 'Missing prerequisites reported without install'}\n`);
    const result = ps(runner, ["-Bootstrap", bootstrap]); assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /without install/);
    assert.equal(fs.existsSync(f.node.log), false); assert.equal(fs.existsSync(f.local), false);
  });

  test("valid package stages once, verifies existing files and launches only the Node fixture", () => {
    const f = fixture("valid"), destination = f.manifest();
    const config = path.join(f.installDir, "devspace-watchdog.config.json"), auth = path.join(f.installDir, "auth.json");
    const beforeConfig = fs.readFileSync(config), beforeAuth = fs.readFileSync(auth);
    let result = f.invoke(); assert.equal(result.status, 0, result.stderr);
    for (const file of f.files) assert.equal(digest(fs.readFileSync(path.join(destination, file.path))), file.sha256);
    assert.ok(fs.existsSync(path.join(destination, "oneclick-payload.json")));
    assert.match(fs.readFileSync(f.node.log, "utf8"), /--no-open/);
    assert.ok(fs.readFileSync(f.node.log, "utf8").includes(destination));
    result = ps(f.copiedBootstrap, ["-InstallDir", f.installDir, "-NoOpen"], { LOCALAPPDATA: f.local, PSModulePath: process.env.PSModulePath || path.join(process.env.SystemRoot, "System32", "WindowsPowerShell", "v1.0", "Modules"), PATH: path.join(process.env.SystemRoot, "System32") });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(f.node.log, "utf8").trim().split(/\r?\n/).length, 2);
    assert.deepEqual(fs.readFileSync(config), beforeConfig); assert.deepEqual(fs.readFileSync(auth), beforeAuth);
  });

  test("8.3 LOCALAPPDATA aliases do not reject a valid package", () => {
    const f = fixture("short-path"), destination = f.manifest();
    fs.mkdirSync(f.local, { recursive: true });
    const runner = path.join(f.dir, "short-path.ps1");
    write(runner, "param([string]$Directory)\n$ErrorActionPreference='Stop'\n$filesystem=New-Object -ComObject Scripting.FileSystemObject\n$filesystem.GetFolder($Directory).ShortPath\n");
    const resolved = ps(runner, ["-Directory", f.local]); assert.equal(resolved.status, 0, resolved.stderr);
    const result = ps(f.copiedBootstrap, ["-InstallDir", f.installDir, "-NoOpen"], { LOCALAPPDATA: resolved.stdout.trim(), PATH: path.join(process.env.SystemRoot, "System32") });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(fs.existsSync(path.join(destination, "scripts", "windows", "devspace-stack-setup.cjs")));
    assert.ok(fs.existsSync(f.node.log));
  });

  test("source tampering blocks Setup without altering existing configuration", () => {
    const f = fixture("source-tamper"); f.manifest();
    write(path.join(f.packageRoot, "scripts", "windows", "devspace-stack-setup.cjs"), "tampered");
    const result = f.invoke(); assert.notEqual(result.status, 0); assert.match(result.stderr, /integrity check/i);
    assert.equal(fs.existsSync(f.node.log), false);
    assert.equal(JSON.parse(fs.readFileSync(path.join(f.installDir, "devspace-watchdog.config.json"))).customSetting, "preserve");
  });

  test("modified managed package is preserved and refused", () => {
    const f = fixture("destination-tamper"), destination = f.manifest();
    write(path.join(destination, f.files[0].path), "user modification");
    const result = f.invoke(); assert.notEqual(result.status, 0); assert.match(result.stderr, /modified/i);
    assert.equal(fs.readFileSync(path.join(destination, f.files[0].path), "utf8"), "user modification");
    assert.equal(fs.existsSync(f.node.log), false);
  });

  test("manifest self-integrity and traversal checks fail before launch", () => {
    const f = fixture("manifest-tamper"); f.manifest();
    const manifestPath = path.join(f.packageRoot, "oneclick-payload.json");
    const manifest = JSON.parse(fs.readFileSync(manifestPath)); manifest.fingerprint = "b".repeat(64); write(manifestPath, manifest);
    let result = f.invoke(); assert.notEqual(result.status, 0); assert.match(result.stderr, /manifest integrity/i);
    const outside = path.join(f.dir, "outside.txt"); write(outside, "keep me");
    f.manifest([{ path: "../outside.txt", sha256: digest("keep me") }]);
    result = f.invoke(); assert.notEqual(result.status, 0); assert.match(result.stderr, /package file path/i);
    assert.equal(fs.readFileSync(outside, "utf8"), "keep me"); assert.equal(fs.existsSync(f.node.log), false);
  });

  test("destination junction cannot redirect package installation outside managed storage", () => {
    const f = fixture("destination-junction"), destination = f.manifest(), outside = path.join(f.dir, "outside");
    fs.mkdirSync(outside, { recursive: true }); fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.symlinkSync(outside, destination, "junction");
    try {
      const result = f.invoke();
      assert.notEqual(result.status, 0, "Bootstrap followed a managed-directory junction and launched Setup");
      assert.equal(fs.readdirSync(outside).length, 0, "Bootstrap copied payload outside managed storage");
      assert.equal(fs.existsSync(f.node.log), false);
    } finally { fs.unlinkSync(destination); }
  });

  console.log(`oneclick-bootstrap: ${results.filter(r => r.ok).length}/${results.length} checks passed; no real dependencies installed`);
  if (results.some(r => !r.ok)) process.exitCode = 1;
} finally {
  const resolved = path.resolve(root);
  assert.ok(resolved.startsWith(path.resolve(tempBase) + path.sep) && path.basename(resolved).startsWith("devspace-oneclick-bootstrap-test-"));
  fs.rmSync(resolved, { recursive: true, force: true });
}
