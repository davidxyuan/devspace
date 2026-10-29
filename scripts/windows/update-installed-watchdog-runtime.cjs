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
const BACKEND_FILES = ["devspace-watchdog.ps1", "devspace-watchdog-legacy.ps1", "mcp-router.cjs"];
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
  if (!service || typeof service.enabled !== "boolean") return false;
  if (!service.enabled) return true;
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
function kasperskyEndpointSecurityActive() {
  const roots = [process.env["ProgramFiles(x86)"], process.env.ProgramFiles]
    .filter(Boolean)
    .map(root => path.join(root, "Kaspersky Lab"));
  if (roots.some(root => fs.existsSync(root))) return true;
  const tasklist = path.join(process.env.WINDIR || "C:\\Windows", "System32", "tasklist.exe");
  try {
    const result = spawnSync(tasklist, ["/FI", "IMAGENAME eq avp.exe", "/FO", "CSV", "/NH"], { windowsHide: true, encoding: "utf8", timeout: 5000 });
    return result.status === 0 && /"avp\.exe"/i.test(String(result.stdout || ""));
  } catch { return false; }
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
function applyWithPowerShell(args) {
  const powershell = path.join(process.env.WINDIR || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
  const parameters = ["-NoProfile", "-File", path.join(__dirname, "update-installed-watchdog-runtime.ps1"),
    "-InstallDir", path.resolve(args.installDir), "-SourceDir", path.resolve(args.sourceDir), "-Apply"];
  if (args.expectedMachineSlug) parameters.push("-ExpectedMachineSlug", args.expectedMachineSlug);
  if (args.allowHermesBusy) parameters.push("-AllowHermesBusyTransport");
  // The shared transaction owns its OS-held lease through validation and rollback.
  // Do not kill that owner on a Node-side timeout during a file replacement.
  const result = spawnSync(powershell, parameters, { windowsHide: true, stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`PowerShell runtime update failed (exit ${result.status}, signal ${result.signal || "none"}); inspect its diagnostics and backup.`);
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
  if (kasperskyEndpointSecurityActive()) {
    throw new Error("Kaspersky Endpoint Security is active; batch updater Apply is disabled before any file writes. Use verified file-by-file deployment plus the existing Bootstrap/Dashboard lifecycle, or an IT-approved allowlist for the exact reviewed artifact.");
  }

  applyWithPowerShell(args);
  return { changed: plan.changes.length, routerRestartRequired: false };
}

if (require.main === module) {
  main().catch(error => { console.error(error?.stack || String(error)); process.exitCode = 1; });
}
module.exports = { PAYLOAD_FILES, BACKEND_FILES, ALL_FILES, sha256File, contentEqual, supervisorTaskName, buildPlan, serviceAcceptable, parseArgs, kasperskyEndpointSecurityActive, applyWithPowerShell };
