"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const http = require("node:http");
const { spawnSync } = require("node:child_process");

const PAYLOAD_FILES = [
  "watchdog-control-core.ps1",
  "stack-operation.ps1",
  "stack-host-management.ps1",
  "watchdog-install-transaction.ps1",
  "devspace-watchdog-tray.ps1",
  "devspace-watchdog-tray-ui.ps1",
  "devspace-watchdog-bootstrap.ps1",
  "devspace-control-center.html",
  "run-devspace-watchdog-tray-hidden.vbs",
  "uninstall-devspace-watchdog-tray.ps1",
  "restore-old-watchdog.ps1",
];
const BACKEND_FILES = ["devspace-watchdog.ps1", "mcp-router.cjs"];
const ALL_FILES = [...PAYLOAD_FILES, ...BACKEND_FILES];

function sha256File(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex").toUpperCase();
}
function normalizedText(file) {
  return fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
}
function contentEqual(left, right) {
  return sha256File(left) === sha256File(right) || normalizedText(left) === normalizedText(right);
}
function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
}
function writeJsonAtomic(file, value) {
  const temp = `${file}.node-update-${process.pid}-${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(value, null, 2), "utf8");
  for (let attempt = 0; ; attempt++) {
    try { fs.copyFileSync(temp, file); break; }
    catch (error) {
      if (!["EPERM", "EACCES", "EBUSY"].includes(error.code) || attempt >= 24) throw error;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 200);
    }
  }
  fs.rmSync(temp, { force: true });
}
function copyVerified(source, destination) {
  const temp = `${destination}.node-update-${process.pid}-${crypto.randomUUID()}.tmp`;
  fs.copyFileSync(source, temp);
  const expected = sha256File(source);
  if (sha256File(temp) !== expected) throw new Error(`Staged file hash mismatch: ${source}`);
  for (let attempt = 0; ; attempt++) {
    try { fs.copyFileSync(temp, destination); break; }
    catch (error) {
      if (!["EPERM", "EACCES", "EBUSY"].includes(error.code) || attempt >= 24) throw error;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 200);
    }
  }
  fs.rmSync(temp, { force: true });
  if (sha256File(destination) !== expected) throw new Error(`Installed file hash mismatch after copy: ${destination}`);
}
function supervisorTaskName(installDir) {
  const hash = crypto.createHash("sha256").update(path.resolve(installDir).toLowerCase(), "utf8").digest("hex").slice(0, 12);
  return `DevSpaceWatchdogSupervisor-${hash}`;
}
function buildPlan({ installDir, sourceDir, expectedMachineSlug = "" }) {
  installDir = path.resolve(installDir);
  sourceDir = path.resolve(sourceDir);
  const configPath = path.join(installDir, "devspace-watchdog.config.json");
  const recordPath = path.join(installDir, "watchdog-tray-install.json");
  if (!fs.existsSync(configPath) || !fs.existsSync(recordPath)) throw new Error("This updater requires an existing verified Watchdog Tray installation.");
  for (const name of ALL_FILES) {
    if (!fs.existsSync(path.join(sourceDir, name))) throw new Error(`Update source is missing: ${name}`);
    if (!fs.existsSync(path.join(installDir, name))) throw new Error(`Installed runtime file is missing: ${name}`);
  }
  const config = readJson(configPath);
  const record = readJson(recordPath);
  if (path.resolve(String(config.stateDir || "")) !== installDir) throw new Error("Watchdog stateDir does not match InstallDir.");
  if (expectedMachineSlug && String(config.machineSlug) !== expectedMachineSlug) throw new Error(`Machine slug mismatch: expected ${expectedMachineSlug}, found ${config.machineSlug}.`);
  if (path.resolve(String(record.installDir || "")) !== installDir) throw new Error("Tray install record belongs to another installation directory.");
  const installedMap = new Map((record.installedFiles || []).map(item => [String(item.name), item]));
  for (const name of PAYLOAD_FILES) {
    const entry = installedMap.get(name);
    if (!entry) throw new Error(`Tray install record does not track ${name}; use the full installer instead.`);
    const actual = sha256File(path.join(installDir, name));
    if (actual !== String(entry.sha256 || "").toUpperCase()) throw new Error(`Installed payload changed since the install record: ${name}`);
  }
  const changes = ALL_FILES.filter(name => !contentEqual(path.join(sourceDir, name), path.join(installDir, name))).map(name => ({
    name,
    sourceHash: sha256File(path.join(sourceDir, name)),
    targetHash: sha256File(path.join(installDir, name)),
  }));
  return { installDir, sourceDir, configPath, recordPath, config, record, installedMap, changes };
}
function httpJson({ port, method = "GET", pathname = "/api/status", body, timeoutMs = 5000 }) {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? null : Buffer.from(JSON.stringify(body));
    const request = http.request({ hostname: "127.0.0.1", port, path: pathname, method, timeout: timeoutMs,
      headers: payload ? { "content-type": "application/json", "content-length": payload.length } : undefined }, response => {
      const chunks = [];
      response.on("data", chunk => chunks.push(chunk));
      response.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        if ((response.statusCode || 500) >= 400) return reject(new Error(`${method} ${pathname} returned HTTP ${response.statusCode}: ${text.slice(0, 500)}`));
        try { resolve(JSON.parse(text)); } catch { reject(new Error(`${method} ${pathname} returned invalid JSON.`)); }
      });
    });
    request.on("timeout", () => request.destroy(new Error(`${method} ${pathname} timed out.`)));
    request.on("error", reject);
    if (payload) request.write(payload);
    request.end();
  });
}
function serviceAcceptable(name, service, allowHermesBusy) {
  if (!service || !service.enabled) return true;
  if (service.identityConflict) return false;
  if (service.healthy) return true;
  return name === "hermes" && allowHermesBusy && service.busyIndeterminate && service.processFound && service.listenerFound;
}
async function stableHealth(port, allowHermesBusy, attempts = 5) {
  let consecutive = 0;
  let last;
  for (let i = 0; i < attempts; i++) {
    last = await httpJson({ port });
    const ok = ["devspace", "hermes", "router", "ngrok"].every(name => serviceAcceptable(name, last.services?.[name], allowHermesBusy));
    if (ok) { consecutive++; if (consecutive >= 2) return last; }
    else consecutive = 0;
    if (i + 1 < attempts) await new Promise(resolve => setTimeout(resolve, 500));
  }
  throw new Error(`Watchdog services did not remain healthy for two consecutive checks. Last overall=${last?.overall?.label || "unknown"}`);
}
function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: options.cwd, windowsHide: true, encoding: "utf8", timeout: options.timeout || 60000 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${path.basename(command)} exited with code ${result.status}. ${String(result.stderr || result.stdout || "").trim()}`);
  return result;
}
function heartbeatFresh(file, role) {
  try {
    const value = readJson(file);
    if (String(value.role) !== role || !Number.isInteger(Number(value.pid)) || Number(value.pid) <= 0) return false;
    const age = Date.now() - Date.parse(String(value.timestamp));
    return Number.isFinite(age) && age >= -5000 && age <= 30000;
  } catch { return false; }
}
async function waitControlReady(installDir, port, timeoutMs = 45000) {
  const deadline = Date.now() + timeoutMs;
  do {
    try {
      await httpJson({ port, timeoutMs: 2500 });
      const host = heartbeatFresh(path.join(installDir, "watchdog-host-heartbeat.json"), "host");
      const tray = heartbeatFresh(path.join(installDir, "watchdog-tray-heartbeat.json"), "tray-ui");
      const sup = heartbeatFresh(path.join(installDir, "watchdog-supervisor-heartbeat.json"), "supervisor");
      if (host && tray && sup) return;
    } catch { }
    await new Promise(resolve => setTimeout(resolve, 500));
  } while (Date.now() < deadline);
  throw new Error("Updated Host/Tray/Supervisor did not become ready in time.");
}
function parseArgs(argv) {
  const args = { apply: false, allowHermesBusy: false };
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i];
    if (key === "--apply") args.apply = true;
    else if (key === "--allow-hermes-busy") args.allowHermesBusy = true;
    else if (key === "--install-dir") args.installDir = argv[++i];
    else if (key === "--source-dir") args.sourceDir = argv[++i];
    else if (key === "--expected-machine-slug") args.expectedMachineSlug = argv[++i];
    else throw new Error(`Unknown argument: ${key}`);
  }
  if (!args.installDir || !args.sourceDir) throw new Error("--install-dir and --source-dir are required.");
  return args;
}
async function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  const plan = buildPlan(args);
  const port = Number(plan.config.control?.dashboardPort || plan.config.dashboardPort || 8777);
  await stableHealth(port, args.allowHermesBusy);
  console.log(`Machine: ${plan.config.machineSlug}`);
  console.log(`InstallDir: ${plan.installDir}`);
  console.log(`Changed runtime files: ${plan.changes.length}`);
  for (const change of plan.changes) console.log(` - ${change.name}`);
  if (!plan.changes.length) { console.log("Installed Watchdog runtime already matches this source."); return { changed: 0, routerRestartRequired: false }; }
  if (!args.apply) { console.log("Preview only. Re-run with --apply to update this verified installation."); return { changed: plan.changes.length, routerRestartRequired: plan.changes.some(x => x.name === "mcp-router.cjs") }; }

  const lockPath = path.join(plan.installDir, "stack-management", "node-runtime-update.lock");
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });
  let lock;
  try { lock = fs.openSync(lockPath, "wx"); }
  catch (error) { if (error.code === "EEXIST") throw new Error("Another Node runtime update is already running."); throw error; }
  const backupDir = path.join(plan.installDir, "configuration-backups", `runtime-node-update-${new Date().toISOString().replace(/[-:TZ.]/g, "").slice(0, 14)}-${crypto.randomUUID().slice(0, 8)}`);
  fs.mkdirSync(backupDir, { recursive: false });
  const backups = [];
  const recordBackup = path.join(backupDir, "watchdog-tray-install.json");
  fs.copyFileSync(plan.recordPath, recordBackup);
  const recordBackupHash = sha256File(recordBackup);
  for (const change of plan.changes) {
    const src = path.join(plan.installDir, change.name);
    const dst = path.join(backupDir, change.name);
    fs.copyFileSync(src, dst);
    const hash = sha256File(dst);
    if (hash !== change.targetHash) throw new Error(`Backup hash mismatch for ${change.name}`);
    backups.push({ name: change.name, path: dst, sha256: hash });
  }
  writeJsonAtomic(path.join(backupDir, "runtime-update-manifest.json"), { schemaVersion: 1, createdAt: new Date().toISOString(), machineSlug: plan.config.machineSlug,
    sourceDir: plan.sourceDir, installDir: plan.installDir, files: backups, installRecordSha256: recordBackupHash });

  const powershell = path.join(process.env.WINDIR || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
  const bootstrap = path.join(plan.installDir, "devspace-watchdog-bootstrap.ps1");
  const configPath = plan.configPath;
  let copied = false;
  try {
    // Recheck immediately before taking the control plane down.
    const beforeStop = await httpJson({ port });
    if (beforeStop.mutationInProgress || beforeStop.activeJob) throw new Error("Dashboard reports a mutation/job in progress; refusing runtime update.");
    run(powershell, ["-NoProfile", "-File", bootstrap, "-Mode", "Stop", "-ConfigPath", configPath, "-RuntimeDirectory", plan.installDir], { timeout: 30000 });
    for (const change of plan.changes) copyVerified(path.join(plan.sourceDir, change.name), path.join(plan.installDir, change.name));
    copied = true;
    for (const name of PAYLOAD_FILES) {
      if (!plan.changes.some(change => change.name === name)) continue;
      const entry = plan.installedMap.get(name);
      entry.sha256 = sha256File(path.join(plan.installDir, name));
    }
    writeJsonAtomic(plan.recordPath, plan.record);
    run(powershell, ["-NoProfile", "-File", bootstrap, "-Mode", "Run", "-ConfigPath", configPath, "-RuntimeDirectory", plan.installDir], { timeout: 60000 });
    const taskName = supervisorTaskName(plan.installDir);
    run(path.join(process.env.WINDIR || "C:\\Windows", "System32", "schtasks.exe"), ["/Run", "/TN", taskName], { timeout: 15000 });
    await waitControlReady(plan.installDir, port);
  } catch (failure) {
    try {
      if (copied) {
        for (const item of backups) {
          if (sha256File(item.path) !== item.sha256) throw new Error(`Rollback backup hash mismatch: ${item.name}`);
          copyVerified(item.path, path.join(plan.installDir, item.name));
        }
        if (sha256File(recordBackup) !== recordBackupHash) throw new Error("Install-record rollback backup hash mismatch.");
        copyVerified(recordBackup, plan.recordPath);
      }
      run(powershell, ["-NoProfile", "-File", bootstrap, "-Mode", "Run", "-ConfigPath", configPath, "-RuntimeDirectory", plan.installDir], { timeout: 60000 });
      const taskName = supervisorTaskName(plan.installDir);
      run(path.join(process.env.WINDIR || "C:\\Windows", "System32", "schtasks.exe"), ["/Run", "/TN", taskName], { timeout: 15000 });
    } catch (rollback) {
      throw new Error(`Node runtime update failed: ${failure.message}. Rollback also needs attention: ${rollback.message}. Backup: ${backupDir}`);
    }
    throw new Error(`Node runtime update failed and payload was restored: ${failure.message}. Backup: ${backupDir}`);
  } finally {
    if (lock !== undefined) fs.closeSync(lock);
    fs.rmSync(lockPath, { force: true });
  }
  await stableHealth(port, args.allowHermesBusy);
  const routerRestartRequired = plan.changes.some(change => change.name === "mcp-router.cjs");
  console.log(`Watchdog runtime update complete. Backup: ${backupDir}`);
  console.log(`Router restart required: ${routerRestartRequired ? "YES" : "NO"}`);
  return { changed: plan.changes.length, routerRestartRequired, backupDir };
}

if (require.main === module) {
  main().catch(error => { console.error(error?.stack || String(error)); process.exitCode = 1; });
}
module.exports = { PAYLOAD_FILES, BACKEND_FILES, ALL_FILES, sha256File, contentEqual, supervisorTaskName, buildPlan, serviceAcceptable, parseArgs };
