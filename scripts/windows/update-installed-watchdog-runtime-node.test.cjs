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
