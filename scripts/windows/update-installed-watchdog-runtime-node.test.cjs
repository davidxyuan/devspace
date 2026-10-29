"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {
  PAYLOAD_FILES,
  BACKEND_FILES,
  sha256File,
  contentEqual,
  supervisorTaskName,
  buildPlan,
  serviceAcceptable,
  parseArgs,
} = require("./update-installed-watchdog-runtime.cjs");
const updaterSource = fs.readFileSync(path.join(__dirname, "update-installed-watchdog-runtime.cjs"), "utf8");
assert.match(updaterSource, /Kaspersky Endpoint Security is active; batch updater Apply is disabled before any file writes/,
  "Kaspersky-managed machines must fail closed before batch mutation");


const root = fs.mkdtempSync(path.join(os.tmpdir(), "devspace-node-runtime-update-test-"));
const installDir = path.join(root, "installed");
const sourceDir = path.join(root, "source");
fs.mkdirSync(installDir, { recursive: true });
fs.mkdirSync(sourceDir, { recursive: true });
try {
  for (const name of [...PAYLOAD_FILES, ...BACKEND_FILES]) {
    const text = `fixture ${name}\r\nline two\r\n`;
    fs.writeFileSync(path.join(installDir, name), text, "utf8");
    fs.writeFileSync(path.join(sourceDir, name), text.replace(/\r\n/g, "\n"), "utf8");
  }
  fs.writeFileSync(path.join(sourceDir, "mcp-router.cjs"), "fixture mcp-router.cjs\nline two\nnew router line\n", "utf8");
  const config = { stateDir: installDir, machineSlug: "fixture", control: { dashboardPort: 18777 } };
  fs.writeFileSync(path.join(installDir, "devspace-watchdog.config.json"), JSON.stringify(config), "utf8");
  const record = {
    installDir,
    installedFiles: PAYLOAD_FILES.map(name => ({ name, sha256: sha256File(path.join(installDir, name)) })),
  };
  fs.writeFileSync(path.join(installDir, "watchdog-tray-install.json"), JSON.stringify(record), "utf8");

  assert.equal(contentEqual(path.join(installDir, "devspace-watchdog-tray.ps1"), path.join(sourceDir, "devspace-watchdog-tray.ps1")), true,
    "line-ending-only differences should be ignored");
  const plan = buildPlan({ installDir, sourceDir, expectedMachineSlug: "fixture" });
  assert.deepEqual(plan.changes.map(item => item.name), ["mcp-router.cjs"], "only semantic runtime changes should be planned");
  assert.match(supervisorTaskName(installDir), /^DevSpaceWatchdogSupervisor-[a-f0-9]{12}$/, "supervisor task name should be stable and bounded");

  for (const service of [undefined, null, {}, { healthy: true }, { enabled: null }, { enabled: 0 }, { enabled: "false", healthy: true }]) {
    assert.equal(serviceAcceptable("devspace", service, false), false, "missing or invalid service state must block updates");
  }
  assert.equal(serviceAcceptable("devspace", { enabled: false }, false), true, "explicitly disabled services remain supported");
  assert.equal(serviceAcceptable("devspace", { enabled: true, healthy: true }, false), true);

  assert.equal(serviceAcceptable("hermes", { enabled: true, healthy: false, busyIndeterminate: true, processFound: true, listenerFound: true, identityConflict: false }, true), true,
    "active Hermes transport may be accepted only with proven process/listener identity");
  assert.equal(serviceAcceptable("hermes", { enabled: true, healthy: false, busyIndeterminate: true, processFound: true, listenerFound: false, identityConflict: false }, true), false,
    "busy Hermes without a listener must fail closed");
  assert.equal(serviceAcceptable("hermes", { enabled: true, healthy: false, busyIndeterminate: true, processFound: true, listenerFound: true, identityConflict: true }, true), false,
    "identity conflict must always fail closed");

  const parsed = parseArgs(["--install-dir", installDir, "--source-dir", sourceDir, "--expected-machine-slug", "fixture", "--allow-hermes-busy", "--apply"]);
  assert.equal(parsed.apply, true);
  assert.equal(parsed.allowHermesBusy, true);
  assert.equal(parsed.expectedMachineSlug, "fixture");

  fs.appendFileSync(path.join(installDir, "devspace-watchdog-tray.ps1"), "tampered\n");
  assert.throws(() => buildPlan({ installDir, sourceDir, expectedMachineSlug: "fixture" }), /Installed payload changed since the install record/,
    "recorded payload tampering must block the update before mutation");

  console.log("PASS: Node runtime updater provenance, semantic diff, task identity, and Hermes-busy safety checks.");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}

// Apply must use the same locked transaction as the PowerShell entry point.
async function delegationChecks() {
  const vm = require("node:vm");
  const installDir = path.resolve(os.tmpdir(), "runtime fixture-'$();-測試");
  const sourceDir = path.resolve(__dirname);
  for (const scenario of ["preview", "healthy", "guard", "health", "child-failure", "spawn-failure"]) {
    const invocations = [];
    const fixture = {
      plan: () => ({installDir, sourceDir, config: {machineSlug: "fixture"}, changes: [{name: "mcp-router.cjs"}]}),
      health: async () => { if (scenario === "health") throw new Error("fixture unhealthy"); },
      guarded: () => scenario === "guard",
    };
    const context = vm.createContext({module: {exports: {}}, __dirname, process, Buffer, console: {log() {}}, fixture,
      require: name => name === "node:child_process" ? {spawnSync(command, args, options) {
        invocations.push({command, args: Array.from(args), options});
        return scenario === "spawn-failure" ? {error: new Error("fixture cannot spawn")}
          : {status: scenario === "child-failure" ? 7 : 0};
      }} : require(name)});
    vm.runInContext(updaterSource + "\nbuildPlan=fixture.plan; stableHealth=fixture.health; kasperskyEndpointSecurityActive=fixture.guarded; module.exports.main=main;", context);
    const argv = ["--install-dir", installDir, "--source-dir", sourceDir, "--expected-machine-slug", "fixture", "--allow-hermes-busy"];
    if (scenario !== "preview") argv.push("--apply");
    let failure, result;
    try { result = await context.module.exports.main(argv); } catch (error) { failure = error; }
    if (["preview", "guard", "health"].includes(scenario)) {
      assert.equal(invocations.length, 0, `${scenario}: must not invoke a mutation`);
      if (scenario !== "preview") assert.match(failure?.message || "", scenario === "guard" ? /Kaspersky/ : /fixture unhealthy/);
      else assert.equal(result.changed, 1);
      continue;
    }
    assert.equal(invocations.length, 1);
    const call = invocations[0];
    assert.equal(path.basename(call.command), "powershell.exe");
    assert.deepEqual(call.args, ["-NoProfile", "-File", path.join(__dirname, "update-installed-watchdog-runtime.ps1"),
      "-InstallDir", installDir, "-SourceDir", sourceDir, "-Apply", "-ExpectedMachineSlug", "fixture", "-AllowHermesBusyTransport"]);
    assert.equal(call.options.windowsHide, true);
    assert.equal(call.options.shell, undefined, "paths must remain literal arguments");
    assert.equal(call.options.timeout, undefined, "the lock owner must not be killed midway through rollback");
    if (scenario === "healthy") {
      assert.equal(failure, undefined);
      assert.equal(result.routerRestartRequired, false, "the shared transaction handles its router restart");
    } else assert.match(failure?.message || "", scenario === "child-failure" ? /exit 7/ : /fixture cannot spawn/);
  }
  console.log("PASS: preview, guarded apply, shared PowerShell delegation, literal paths, and child failure propagation.");
}
delegationChecks().catch(error => { console.error(error); process.exitCode = 1; });
