#!/usr/bin/env node
"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");
const jobsApi = require("./stack-jobs.cjs");
const management = require("./stack-management.cjs");
if (!process.argv.includes("--worker")) { delete process.env.DEVSPACE_STACK_OPERATION_TOKEN; delete process.env.DEVSPACE_STACK_JOB_ID; }

if (process.platform !== "win32") {
  console.error("devspace-stack setup currently supports Windows only.");
  process.exit(1);
}

const scriptDir = __dirname;
const packageRoot = path.resolve(process.env.DEVSPACE_STACK_PACKAGE_ROOT || path.join(scriptDir, "..", ".."));
const templatePath = path.join(scriptDir, "devspace-stack-setup.html");
const installerPath = path.join(scriptDir, "install-devspace-watchdog.ps1");
const cliPath = path.join(packageRoot, "dist", "cli.js");
const packageJsonPath = path.join(packageRoot, "package.json");
const installDirArgument = process.argv.indexOf("--install-dir");
const installDir = path.resolve(installDirArgument >= 0 ? process.argv[installDirArgument + 1] : (process.env.DEVSPACE_STACK_INSTALL_DIR || path.join(os.homedir(), ".devspace")));
const hermesDefaultDir = path.join(os.homedir(), "hermes-gpt");
const controlToken = crypto.randomBytes(24).toString("base64url");
const stateDirectory = jobsApi.managementDir(installDir);
const inventoryPath = path.join(stateDirectory, "inventory.json");
const terminalPhases = new Set(["completed", "failed"]);
const pendingRequests = new Map();
let cloudPolicy;
let cloudBusy = false;
let launching = false;
function launchWorker(type, input) {
  if (cloudBusy) throw new Error('Cloud policy operation is running. Retry when it completes.');
  const requestId = input.requestId;
  if (requestId && !/^[A-Za-z0-9_.:-]{8,100}$/.test(requestId)) throw new Error("Invalid request ID.");
  const key = requestId ? `${type}:${requestId}` : null;
  const fingerprint = crypto.createHash("sha256").update(JSON.stringify(input)).digest("hex");
  if (key && pendingRequests.has(key)) {
    const existing = pendingRequests.get(key);
    if (existing.fingerprint !== fingerprint) throw new Error("Request ID was already used for different parameters.");
    return existing.promise;
  }
  if (launching) throw new Error("Another stack operation is acquiring ownership.");
  launching = true;
  const promise = jobsApi.startWorker({ installDir, packageRoot, scriptDir, type, input }).finally(() => { launching = false; });
  if (key) {
    pendingRequests.set(key, { fingerprint, promise });
    if (pendingRequests.size > 128) pendingRequests.delete(pendingRequests.keys().next().value);
  }
  return promise;
}
function activeJob() {
  try { const job = jobsApi.activeJob(installDir); return job && !terminalPhases.has(job.phase) ? job : null; }
  catch { return null; }
}
function cachedInventory() {
  return readJson(inventoryPath) || { schemaVersion: 1, revision: "", checkedAt: null, refreshing: false, components: [], blockers: [] };
}
function configurationFingerprint() {
  const hash = crypto.createHash("sha256");
  for (const name of ["config.json", "devspace-watchdog.config.json", "auth.json"]) {
    const file = path.join(installDir, name);
    hash.update(name); hash.update(fs.existsSync(file) ? fs.readFileSync(file) : "missing");
  }
  return hash.digest("hex");
}

function readJson(filePath) {
  try { return JSON.parse(fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, "")); }
  catch { return null; }
}
const initialManagementRoot = readJson(path.join(installDir, "devspace-watchdog.config.json"))?.managementPackageRoot || "";

function originOf(value) {
  try { return new URL(String(value || "")).origin; }
  catch { return ""; }
}

function detectInstallState() {
  const configPath = path.join(installDir, "config.json");
  const watchdogPath = path.join(installDir, "devspace-watchdog.config.json");
  const authPath = path.join(installDir, "auth.json");
  const configExists = fs.existsSync(configPath);
  const watchdogExists = fs.existsSync(watchdogPath);
  const config = readJson(configPath) || {};
  const watchdog = readJson(watchdogPath) || {};
  const auth = readJson(authPath) || {};
  const trayHeartbeat = readJson(path.join(installDir, "watchdog-tray-heartbeat.json"));
  const trayFresh = Boolean(trayHeartbeat && Date.now() - Date.parse(trayHeartbeat.timestamp) < 15000);
  const trayInstalled = [
    "devspace-watchdog-bootstrap.ps1",
    "devspace-watchdog-tray.ps1",
    "devspace-watchdog-tray-ui.ps1",
    "run-devspace-watchdog-tray-hidden.vbs",
  ].every((name) => fs.existsSync(path.join(installDir, name)));
  const configValid = !configExists || Boolean(readJson(configPath));
  const watchdogValid = !watchdogExists || Boolean(readJson(watchdogPath));
  const state = !configValid || !watchdogValid ? "Ambiguous" : configExists && watchdogExists ? "Existing" : (!configExists && !watchdogExists ? "Fresh" : "Partial");
  const publicDomain = originOf(watchdog.ngrokEndpointMode === "AgentEndpoint" ? (watchdog.ngrokAgentBaseUrl || watchdog.publicBaseUrl) : watchdog.publicBaseUrl);
  const existingHermesDir = watchdog.hermesWorkingDirectory || hermesDefaultDir;
  return {
    state,
    configurationFingerprint: configurationFingerprint(),
    inventory: cachedInventory(),
    activeJob: activeJob(),
    activeJobId: activeJob()?.id || null,
    installDir,
    packageRoot,
    packageVersion: readJson(packageJsonPath)?.version || "unknown",
    packageCliReady: fs.existsSync(cliPath),
    components: {
      devspace: Boolean(watchdog.cliPath && fs.existsSync(watchdog.cliPath)),
      hermes: Boolean(watchdog.hermesServer && fs.existsSync(watchdog.hermesServer) && watchdog.hermesPython && fs.existsSync(watchdog.hermesPython)),
    },
    tray: {
      installed: trayInstalled,
      running: trayFresh,
      dashboard: trayFresh ? (trayHeartbeat.dashboard || "http://127.0.0.1:8777/") : "",
    },
    legacyPollerQuiesced: fs.existsSync(path.join(installDir, "legacy-watchdog-poller.disabled")),
    defaults: {
      machineName: watchdog.machineSlug || os.hostname(),
      mcpNameSuffix: watchdog.mcpNameSuffix ?? watchdog.machineSlug ?? os.hostname(),
      endpointMode: watchdog.ngrokEndpointMode || "AgentEndpoint",
      publicDomain,
      internalAgentEndpoint: watchdog.ngrokEndpointMode === "CloudEndpoint" ? (watchdog.ngrokAgentBaseUrl || "") : "",
      allowedRoots: Array.isArray(config.allowedRoots) ? config.allowedRoots.join(";") : process.cwd(),
      hermesDir: existingHermesDir,
      installDevspace: state === "Fresh" ? true : Boolean(watchdog.devspaceEnabled !== false),
      installHermes: state === "Fresh" ? true : Boolean(watchdog.hermesEnabled),
      installTray: true,
      installTools: true,
      userMode: true,
      noLegacyPoller: true,
      devspaceOwnerTokenConfigured: Boolean(auth.ownerToken),
    },
  };
}

function validateSetup(input) {
  if (!input || typeof input !== "object") throw new Error("Invalid setup request.");
  const detected = detectInstallState();
  if (["Partial", "Ambiguous"].includes(detected.state)) throw new Error("Incomplete or invalid configuration detected. Existing files were preserved; repair the reported configuration before applying setup.");
  if (input.configurationFingerprint !== detected.configurationFingerprint) throw new Error("Configuration changed since this form was loaded. Refresh and review it before applying.");
  if (input.updatePackageFromGithub || input.updateHermesSource) throw new Error("Use the component Safe Update action after checking its source and latest version.");
  const watchdog = readJson(path.join(installDir, "devspace-watchdog.config.json")) || {};
  const components = [];
  if (input.installDevspace || watchdog.devspaceEnabled !== false && watchdog.cliPath) components.push("DevSpace");
  if (input.installHermes || watchdog.hermesEnabled) components.push("Hermes");
  if (!components.length) throw new Error("Select DevSpace and/or Hermes.");
  if (!/^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$/.test(String(input.machineName || ""))) throw new Error("Machine name is invalid.");
  if (input.mcpNameSuffix !== undefined && !/^[A-Za-z0-9_-]{0,64}$/.test(String(input.mcpNameSuffix))) throw new Error("MCP name suffix must use letters, digits, underscore or hyphen (maximum 64).");
  if (!new Set(["AgentEndpoint", "CloudEndpoint"]).has(input.endpointMode)) throw new Error("Endpoint mode is invalid.");
  const domain = originOf(input.publicDomain);
  if (!domain || !domain.startsWith("https://")) throw new Error("ngrok/public domain must be a valid https:// origin.");
  if (input.endpointMode === "CloudEndpoint") {
    const internal = originOf(input.internalAgentEndpoint);
    if (!internal || !internal.startsWith("https://")) throw new Error("Cloud Endpoint requires a valid Internal Agent Endpoint https:// origin.");
  }
  const allowedRoots = String(input.allowedRoots || "").trim();
  if (input.installDevspace && !allowedRoots && !input.fullAccess) throw new Error("DevSpace needs at least one allowed root, or Full Access must be explicitly selected.");
  if (input.noLegacyPoller && !input.installTray) throw new Error("Tray-only mode requires Install Tray.");
  return {
    components,
    configurationFingerprint: detected.configurationFingerprint,
    existing: detected.state === "Existing",
    changes: Object.keys(input).filter(key => Object.hasOwn(detected.defaults, key) && input[key] !== detected.defaults[key]),
    machineName: String(input.machineName).trim(),
    mcpNameSuffix: String(input.mcpNameSuffix ?? detected.defaults.mcpNameSuffix),
    endpointMode: input.endpointMode,
    publicDomain: domain,
    internalAgentEndpoint: input.endpointMode === "CloudEndpoint" ? originOf(input.internalAgentEndpoint) : "",
    allowedRoots,
    hermesDir: path.resolve(String(input.hermesDir || hermesDefaultDir)),
    installTray: Boolean(input.installTray),
    installTools: Boolean(input.installTools),
    userMode: input.userMode !== false,
    noLegacyPoller: Boolean(input.noLegacyPoller),
    fullAccess: Boolean(input.fullAccess),
    ngrokAuthToken: String(input.ngrokAuthToken || ""),
    devspaceOwnerToken: String(input.devspaceOwnerToken || ""),
  };
}

async function startSetupJob(input) {
  const setup = validateSetup(input);
  const current = activeJob();
  if (current) {
    if (input.requestId && current.requestId === input.requestId) return current;
    throw new Error("Another stack operation is running.");
  }
  return launchWorker("setup", { ...setup, requestId: input.requestId });
}

async function refreshInventory(checkLatest = false) {
  const inventory = await management.collectInventory({ installDir, packageRoot, checkLatest, cache: cachedInventory() });
  jobsApi.writeJson(inventoryPath, inventory);
  return inventory;
}

async function runWorker() {
  let inputText = "";
  for await (const chunk of process.stdin) { inputText += chunk; if (inputText.length > 1024 * 1024) throw new Error("Worker input too large."); }
  const request = JSON.parse(inputText);
  const job = jobsApi.readJob(installDir, request.id);
  if (!job) throw new Error("Worker job not found.");
  jobsApi.writeJson(path.join(stateDirectory, "active.json"), { id: job.id });
  const context = { installDir, packageRoot, scriptDir, id: job.id };
  const input = request.input || {};
  const secrets = [input.ngrokAuthToken, input.devspaceOwnerToken].filter(Boolean);
  const run = (command, args, options) => jobsApi.runLogged(job, installDir, command, args, options, secrets);
  const log = text => { jobsApi.appendOutput(job, "setup", text, secrets); jobsApi.saveJob(installDir, job); };
  try {
    job.phase = "running"; job.step = request.type; jobsApi.saveJob(installDir, job);
    const apply = require("./stack-setup-apply.cjs");
    if (request.type === "refresh") {
      job.result = { checkedAt: (await refreshInventory(true)).checkedAt };
    } else if (request.type === "setup") {
      if (input.configurationFingerprint !== configurationFingerprint()) throw new Error("Configuration changed before installation acquired ownership.");
      job.result = await apply.applySetup(input, context, run);
    } else if (request.type === "component") {
      const inventory = cachedInventory();
      const plan = management.planComponentAction(input, inventory, context);
      const status = detectInstallState();
      job.result = await management.executeComponentAction(plan, { run, log, activate: (candidate, actionPlan) => {
        let setup = null;
        if (candidate.kind === "bundled" && status.state === "Existing") {
          setup = validateSetup({ ...status.defaults, installTray: true, noLegacyPoller: true, installTools: true, configurationFingerprint: status.configurationFingerprint });
        }
        return apply.activateCandidate(candidate, actionPlan, context, run, setup);
      } });
    } else { throw new Error("Unknown worker operation."); }
    job.exitCode = 0; job.phase = "completed"; job.step = "Verified";
  } catch (error) {
    log(error instanceof Error ? error.message : String(error));
    job.error = job.lines.at(-1)?.text || "Operation failed.";
    const failureText = `${job.error}\n${job.lines.map(line => line.text).join("\n")}`;
    job.exitCode = 1; job.phase = /rollback.*fail|recovery.*required/i.test(failureText) ? "rollback_failed" : "failed";
  } finally {
    try { if (request.type !== "refresh") await refreshInventory(false); } catch (error) { log(`Inventory refresh: ${error.message}`); }
    job.finishedAt = new Date().toISOString(); jobsApi.saveJob(installDir, job);
  }
  process.exitCode = job.exitCode;
}

function readRequestBody(req, limit = 65536) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) { reject(new Error("Request body too large.")); req.destroy(); return; }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function sendJson(res, status, value) {
  const body = Buffer.from(JSON.stringify(value), "utf8");
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": body.length,
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
  });
  res.end(body);
}

function safeMutation(req) {
  const host = String(req.headers.host || "");
  const origin = String(req.headers.origin || "");
  const expectedOrigin = `http://127.0.0.1:${server.address().port}`;
  if (host !== `127.0.0.1:${server.address().port}`) throw new Error("Invalid Host header.");
  if (origin !== expectedOrigin) throw new Error("Invalid Origin header.");
  if (String(req.headers["x-devspace-setup-token"] || "") !== controlToken) throw new Error("Invalid setup token.");
  if (!/^application\/json(?:;|$)/i.test(String(req.headers["content-type"] || ""))) throw new Error("Mutation requires JSON.");
  const configuredRoot = readJson(path.join(installDir, "devspace-watchdog.config.json"))?.managementPackageRoot;
  if (configuredRoot && path.resolve(configuredRoot).toLowerCase() !== packageRoot.toLowerCase() && path.resolve(configuredRoot).toLowerCase() !== (initialManagementRoot ? path.resolve(initialManagementRoot).toLowerCase() : "")) throw new Error("The management package changed after this Setup was opened. Reopen Setup from the current Tray before making changes.");
}

const template = fs.readFileSync(templatePath, "utf8");
const server = http.createServer(async (req, res) => {
  try {
    if (!req.socket.remoteAddress || !["127.0.0.1", "::1", "::ffff:127.0.0.1"].includes(req.socket.remoteAddress)) {
      sendJson(res, 403, { error: "Loopback only." }); return;
    }
    const url = new URL(req.url || "/", "http://127.0.0.1");
    if (String(req.headers.host || "") !== `127.0.0.1:${server.address().port}`) { sendJson(res, 403, { error: "Invalid Host header." }); return; }
    if (req.method === "GET" && url.pathname === "/") {
      const body = Buffer.from(template.replaceAll("{{SETUP_TOKEN}}", controlToken), "utf8");
      res.writeHead(200, {
        "content-type": "text/html; charset=utf-8",
        "content-length": body.length,
        "cache-control": "no-store",
        "content-security-policy": "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
        "x-frame-options": "DENY",
      });
      res.end(body); return;
    }
    if (req.method === "GET" && url.pathname === "/api/status") {
      sendJson(res, 200, { ok: true, ...detectInstallState() }); return;
    }
    if (req.method === "GET" && url.pathname === "/api/job") {
      const job = jobsApi.readJob(installDir, url.searchParams.get("id"));
      sendJson(res, job ? 200 : 404, job || { error: "Job not found." }); return;
    }
    if (req.method === "GET" && url.pathname === "/api/components") {
      sendJson(res, 200, { ...cachedInventory(), refreshing: activeJob()?.type === "refresh" }); return;
    }
    if (req.method === "POST" && ["/api/components/refresh", "/api/components/action"].includes(url.pathname)) {
      safeMutation(req);
      const payload = JSON.parse(await readRequestBody(req));
      const current = activeJob();
      if (current && payload.requestId && current.requestId === payload.requestId) { sendJson(res, 202, { ok: true, jobId: current.id }); return; }
      if (current) { sendJson(res, 409, { error: "Another stack operation is running.", jobId: current.id }); return; }
      const type = url.pathname.endsWith("refresh") ? "refresh" : "component";
      if (type === "component") management.planComponentAction(payload, cachedInventory(), { installDir, packageRoot });
      const job = await launchWorker(type, payload);
      sendJson(res, 202, { ok: true, jobId: job.id }); return;
    }
    if (req.method === 'POST' && ['/api/cloud/preview','/api/cloud/apply'].includes(url.pathname)) {
      safeMutation(req);
      const input = JSON.parse(await readRequestBody(req));
      if (activeJob() || launching || cloudBusy) throw Error('Installation is busy. Retry after it completes.');
      cloudBusy = true;
      try {
        cloudPolicy ||= require('./stack-cloud-policy.cjs').createCloudPolicy(installDir);
        sendJson(res,200,await cloudPolicy(input,url.pathname.endsWith('/apply')));
      } finally { cloudBusy = false; }
      return;
    }
    if (req.method === "POST" && url.pathname === "/api/apply") {
      safeMutation(req);
      const payload = JSON.parse(await readRequestBody(req));
      const job = await startSetupJob(payload);
      sendJson(res, 202, { ok: true, jobId: job.id }); return;
    }
    sendJson(res, 404, { error: "Not found." });
  } catch (error) {
    sendJson(res, 400, { error: error instanceof Error ? error.message : String(error) });
  }
});

function listen() {
  let port = 8788;
  const tryPort = () => {
    server.once("error", (error) => {
      if (error.code === "EADDRINUSE" && port < 8798) { port += 1; server.close(); setImmediate(tryPort); return; }
      throw error;
    });
    server.listen(port, "127.0.0.1", () => {
      const url = `http://127.0.0.1:${port}/`;
      jobsApi.writeJson(path.join(stateDirectory, "endpoint.json"), { installDir, port, token: controlToken, pid: process.pid, startedAt: new Date().toISOString() });
      console.log(`DevSpace Stack Setup: ${url}`);
      console.log("Keep this window open while installation/update is running.");
      if (!process.argv.includes("--no-open")) {
        const child = spawn(path.join(process.env.SystemRoot || "C:\\Windows", "System32", "rundll32.exe"), ["url.dll,FileProtocolHandler", url], { windowsHide: true, detached: true, stdio: "ignore" });
        child.unref();
      }
    });
  };
  tryPort();
}

if (require.main === module) {
  if (process.argv.includes("--worker")) runWorker().catch(error => { console.error(error.message); process.exitCode = 1; });
  else { listen(); refreshInventory(false).catch(() => {}); }
}
module.exports = { detectInstallState, validateSetup, configurationFingerprint, server, listen };
