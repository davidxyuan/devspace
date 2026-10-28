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
assert.ok(updaterSource.indexOf("kasperskyEndpointSecurityActive()") < updaterSource.indexOf("const lockPath = path.join(plan.installDir"),
  "Kaspersky guard must execute before lock/backup/copy mutation begins");

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

// Exercise the actual transaction and file copies; never invoke installed processes or tasks.
async function transactionChecks() {
  const vm = require("node:vm");
  for (const scenario of ["healthy", "readiness", "partial-start", "copy", "stop", "supervisor", "check", "busy", "backup"]) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "watchdog-rollback-'"));
    const installDir = path.join(root, "installed"), sourceDir = path.join(root, "source");
    const events = [];
    let running = true, launches = 0, failedCopy = false;
    try {
      fs.mkdirSync(installDir); fs.mkdirSync(sourceDir);
      fs.mkdirSync(path.join(installDir, "configuration-backups"));
      for (const name of [...PAYLOAD_FILES, ...BACKEND_FILES]) {
        fs.writeFileSync(path.join(installDir, name), `old ${name}`);
        fs.writeFileSync(path.join(sourceDir, name), `old ${name}`);
      }
      if (scenario === "healthy" && process.platform === "win32") {
        for (const directory of [installDir, sourceDir]) {
          fs.writeFileSync(path.join(directory, "devspace-watchdog-bootstrap.ps1"), "param($Mode,$ConfigPath,$RuntimeDirectory)\n[IO.File]::AppendAllText((Join-Path $RuntimeDirectory 'modes.log'), ($Mode + \"`n\"))");
          fs.writeFileSync(path.join(directory, "watchdog-install-transaction.ps1"), "function Wait-InstallSupervisorTaskStopped($InstallDir) { [IO.File]::AppendAllText((Join-Path $InstallDir 'modes.log'), \"supervisor-stopped`n\") }");
        }
      }
      const changed = [PAYLOAD_FILES[0], "mcp-router.cjs"];
      for (const name of changed) fs.writeFileSync(path.join(sourceDir, name), `new ${name}`);
      fs.writeFileSync(path.join(installDir, "devspace-watchdog.config.json"), JSON.stringify({stateDir: installDir, machineSlug: "fixture"}));
      const recordPath = path.join(installDir, "watchdog-tray-install.json");
      const originalRecord = JSON.stringify({installDir, installedFiles: PAYLOAD_FILES.map(name => ({name, sha256: sha256File(path.join(installDir, name))}))});
      fs.writeFileSync(recordPath, originalRecord);
      const fakeFs = Object.create(fs);
      fakeFs.copyFileSync = (source, target) => {
        if (scenario === "backup" && target.startsWith(path.join(installDir, "configuration-backups"))) throw new Error("fixture backup disk failure");
        const installedWrite = path.dirname(target) === installDir && !path.basename(target).includes(".node-update-");
        if (installedWrite) {
          assert.equal(running, false, `${scenario}: overwriting a running role`);
          events.push(`write:${path.basename(target)}`);
        }
        fs.copyFileSync(source, target);
        if (installedWrite && scenario === "copy" && !failedCopy) {
          failedCopy = true;
          throw new Error("fixture copy failed after replacing one file");
        }
      };
      const fixture = {
        health: async () => ({}),
        status: async () => ({activeJob: scenario === "busy"}),
        ready: async () => { if (scenario !== "healthy") throw new Error("fixture readiness failed"); },
        run: (command, args) => {
          const mode = args.includes("-Mode") ? args[args.indexOf("-Mode") + 1] : null;
          if (mode === "Stop" || args.includes("-Command")) {
            events.push("Stop");
            if (scenario === "stop" && launches) throw new Error("fixture stop failed");
            running = false;
            if (args.includes("-Command")) {
              const script = args.at(-1);
              const quotedSource = sourceDir.replace(/'/g, "''");
              assert.ok(script.includes(quotedSource), "cleanup must use the source helpers, not partially replaced installed scripts");
              assert.ok(script.indexOf("-Mode Stop") < script.indexOf("Wait-InstallSupervisorTaskStopped"));
              assert.ok(script.indexOf("Wait-InstallSupervisorTaskStopped") < script.indexOf("-Mode CheckStopped"));
              if (scenario === "healthy" && process.platform === "win32") {
                const child = require("node:child_process").spawnSync(command, args, {windowsHide: true, encoding: "utf8", timeout: 15000});
                assert.equal(child.status, 0, child.error?.message || child.stderr);
                assert.equal(fs.readFileSync(path.join(installDir, "modes.log"), "utf8"), "Stop\nsupervisor-stopped\nCheckStopped\n");
              }
              events.push("supervisor-stopped");
              if (scenario === "supervisor" && launches) throw new Error("fixture supervisor still running");
              events.push("CheckStopped");
              if (scenario === "check" && launches) throw new Error("fixture role still running");
            }
          } else if (mode === "Run") {
            events.push("Run"); running = true; launches++;
            if (scenario === "partial-start" && launches === 1) throw new Error("fixture partially started");
          } else {
            assert.equal(path.basename(command), "schtasks.exe");
            assert.deepEqual(Array.from(args), ["/Run", "/TN", supervisorTaskName(installDir)]);
            events.push("start-supervisor");
          }
          return {status: 0};
        },
      };
      const context = vm.createContext({module: {exports: {}}, process, Buffer, console: {log() {}}, fixture,
        require: name => name === "node:fs" ? fakeFs : name === "node:child_process" ? {spawnSync() { throw new Error("Unexpected real process request"); }} : require(name)});
      vm.runInContext(updaterSource + "\nstableHealth=fixture.health; httpJson=fixture.status; run=fixture.run; waitControlReady=fixture.ready; kasperskyEndpointSecurityActive=()=>false; module.exports.main=main;", context);
      let failure;
      try { await context.module.exports.main(["--install-dir", installDir, "--source-dir", sourceDir, "--apply"]); }
      catch (error) { failure = error; }
      if (scenario === "healthy") {
        assert.equal(failure, undefined);
        for (const name of changed) assert.equal(fs.readFileSync(path.join(installDir, name), "utf8"), `new ${name}`);
      } else if (["busy", "backup"].includes(scenario)) {
        assert.match(failure?.message || "", scenario === "busy" ? /mutation\/job in progress/ : /fixture backup disk failure/);
        assert.deepEqual(events, [], "preflight failure must not start or stop anything");
        for (const name of changed) assert.equal(fs.readFileSync(path.join(installDir, name), "utf8"), `old ${name}`);
        assert.equal(fs.readFileSync(recordPath, "utf8"), originalRecord);
      } else if (["stop", "supervisor", "check"].includes(scenario)) {
        assert.match(failure?.message || "", /Rollback also needs attention/);
        assert.equal(launches, 1, "unproven stop must not relaunch a mixed runtime");
        for (const name of changed) assert.equal(fs.readFileSync(path.join(installDir, name), "utf8"), `new ${name}`);
      } else {
        assert.match(failure?.message || "", /payload was restored/);
        for (const name of changed) assert.equal(fs.readFileSync(path.join(installDir, name), "utf8"), `old ${name}`, `${scenario}: partial update not restored`);
        assert.equal(fs.readFileSync(recordPath, "utf8"), originalRecord);
        const firstRestore = events.findIndex((event, i) => event.startsWith("write:") && events.slice(0, i).filter(e => e === "CheckStopped").length === 2);
        assert.ok(firstRestore > 0, `${scenario}: no stop proof before restore`);
        assert.equal(events[firstRestore - 1], "CheckStopped");
      }
      assert.equal(fs.existsSync(path.join(installDir, "stack-management", "node-runtime-update.lock")), false, "lock must be released");
    } finally {
      assert.equal(path.dirname(root), path.resolve(os.tmpdir()));
      fs.rmSync(root, {recursive: true, force: true});
    }
  }
  console.log("PASS: runtime transaction success, partial copy/start, readiness failure, stopped-role proof, busy preflight, and backup failure.");
}
transactionChecks().catch(error => { console.error(error); process.exitCode = 1; });
