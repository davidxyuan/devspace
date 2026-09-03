#!/usr/bin/env node
"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

if (process.platform !== "win32") {
  console.error("devspace-stack setup currently supports Windows only.");
  process.exit(1);
}

const scriptDir = __dirname;
const packageRoot = path.resolve(scriptDir, "..", "..");
const templatePath = path.join(scriptDir, "devspace-stack-setup.html");
const installerPath = path.join(scriptDir, "install-devspace-watchdog.ps1");
const cliPath = path.join(packageRoot, "dist", "cli.js");
const packageJsonPath = path.join(packageRoot, "package.json");
const installDir = path.join(os.homedir(), ".devspace");
const hermesDefaultDir = path.join(os.homedir(), "hermes-gpt");
const controlToken = crypto.randomBytes(24).toString("base64url");
const jobs = new Map();
let activeJobId = null;

function readJson(filePath) {
  try { return JSON.parse(fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, "")); }
  catch { return null; }
}

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
  const state = configExists && watchdogExists ? "Existing" : (!configExists && !watchdogExists ? "Fresh" : "Partial");
  const publicDomain = originOf(watchdog.ngrokEndpointMode === "AgentEndpoint" ? (watchdog.ngrokAgentBaseUrl || watchdog.publicBaseUrl) : watchdog.publicBaseUrl);
  const existingHermesDir = watchdog.hermesWorkingDirectory || hermesDefaultDir;
  return {
    state,
    installDir,
    packageRoot,
    packageVersion: readJson(packageJsonPath)?.version || "unknown",
    packageCliReady: fs.existsSync(cliPath),
    components: {
      devspace: watchdog.devspaceEnabled !== false && (configExists || Boolean(watchdog.cliPath)),
      hermes: Boolean(watchdog.hermesEnabled || watchdog.hermesServer),
    },
    tray: {
      installed: fs.existsSync(path.join(installDir, "devspace-watchdog-tray-launcher.exe")),
      running: trayFresh,
      dashboard: trayFresh ? (trayHeartbeat.dashboard || "http://127.0.0.1:8777/") : "",
    },
    legacyPollerQuiesced: fs.existsSync(path.join(installDir, "legacy-watchdog-poller.disabled")),
    defaults: {
      machineName: watchdog.machineSlug || os.hostname(),
      endpointMode: watchdog.ngrokEndpointMode || "AgentEndpoint",
      publicDomain,
      internalAgentEndpoint: watchdog.ngrokEndpointMode === "CloudEndpoint" ? (watchdog.ngrokAgentBaseUrl || "") : "",
      allowedRoots: Array.isArray(config.allowedRoots) ? config.allowedRoots.join(";") : process.cwd(),
      hermesDir: existingHermesDir,
      installDevspace: state === "Fresh" ? true : Boolean(watchdog.devspaceEnabled !== false),
      installHermes: state === "Fresh" ? true : Boolean(watchdog.hermesEnabled),
      installTray: state === "Fresh" ? true : fs.existsSync(path.join(installDir, "devspace-watchdog-tray-launcher.exe")),
      installTools: true,
      userMode: true,
      noLegacyPoller: true,
      updatePackageFromGithub: false,
      updateHermesSource: false,
      devspaceOwnerTokenConfigured: Boolean(auth.ownerToken),
    },
  };
}

function validateSetup(input) {
  if (!input || typeof input !== "object") throw new Error("Invalid setup request.");
  const detected = detectInstallState();
  if (detected.state === "Partial") throw new Error("Partial/unknown existing installation detected. Setup refuses to overwrite it; repair or back it up first.");
  const components = [];
  if (input.installDevspace) components.push("DevSpace");
  if (input.installHermes) components.push("Hermes");
  if (!components.length) throw new Error("Select DevSpace and/or Hermes.");
  if (!/^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$/.test(String(input.machineName || ""))) throw new Error("Machine name is invalid.");
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
    machineName: String(input.machineName).trim(),
    endpointMode: input.endpointMode,
    publicDomain: domain,
    internalAgentEndpoint: input.endpointMode === "CloudEndpoint" ? originOf(input.internalAgentEndpoint) : "",
    allowedRoots,
    hermesDir: path.resolve(String(input.hermesDir || hermesDefaultDir)),
    installTray: Boolean(input.installTray),
    installTools: Boolean(input.installTools),
    userMode: input.userMode !== false,
    noLegacyPoller: Boolean(input.noLegacyPoller),
    updatePackageFromGithub: Boolean(input.updatePackageFromGithub),
    updateHermesSource: Boolean(input.updateHermesSource),
    fullAccess: Boolean(input.fullAccess),
    ngrokAuthToken: String(input.ngrokAuthToken || ""),
    devspaceOwnerToken: String(input.devspaceOwnerToken || ""),
  };
}

function powershellPath() {
  return path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
}

function appendJobOutput(job, source, text, secrets = []) {
  for (const raw of String(text || "").split(/\r?\n/)) {
    let line = raw.trimEnd();
    if (!line) continue;
    line = line.replace(/^(Owner password:\s*).+$/i, "$1[configured]");
    for (const secret of secrets.filter(Boolean)) line = line.split(secret).join("[secret]");
    job.lines.push({ timestamp: new Date().toISOString(), source, text: line });
    if (job.lines.length > 500) job.lines.splice(0, job.lines.length - 500);
  }
}

function runLogged(job, command, args, options = {}, secrets = []) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { windowsHide: true, stdio: ["ignore", "pipe", "pipe"], ...options });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { const text = chunk.toString("utf8"); stdout += text; appendJobOutput(job, "stdout", text, secrets); });
    child.stderr.on("data", (chunk) => { const text = chunk.toString("utf8"); stderr += text; appendJobOutput(job, "stderr", text, secrets); });
    child.once("error", reject);
    child.once("close", (code) => {
      if (code === 0) resolve({ stdout, stderr });
      else reject(new Error(`${path.basename(command)} exited with code ${code}.`));
    });
  });
}

function resolveNpmCli() {
  const candidate = path.join(path.dirname(process.execPath), "node_modules", "npm", "bin", "npm-cli.js");
  if (!fs.existsSync(candidate)) throw new Error("npm CLI was not found beside the active Node runtime. Install Node.js with npm, then rerun.");
  return candidate;
}

async function preparePackageRuntime(job, setup, secrets) {
  if (!setup.updatePackageFromGithub) return { root: packageRoot, installer: installerPath, cli: cliPath };
  const npmCli = resolveNpmCli();
  const spec = "github:davidxyuan/devspace#codex/windows-watchdog-tray-control-center";
  appendJobOutput(job, "setup", "Updating DevSpace package from GitHub before applying stack configuration.");
  await runLogged(job, process.execPath, [npmCli, "install", "-g", spec, "--no-audit", "--no-fund"], { cwd: packageRoot, env: process.env }, secrets);
  const rootResult = await runLogged(job, process.execPath, [npmCli, "root", "-g"], { cwd: packageRoot, env: process.env }, secrets);
  const globalRoot = rootResult.stdout.trim().split(/\r?\n/).filter(Boolean).pop();
  if (!globalRoot) throw new Error("npm global root could not be resolved after update.");
  const updatedRoot = path.join(globalRoot, "@waishnav", "devspace");
  const updatedInstaller = path.join(updatedRoot, "scripts", "windows", "install-devspace-watchdog.ps1");
  const updatedCli = path.join(updatedRoot, "dist", "cli.js");
  if (!fs.existsSync(updatedInstaller) || !fs.existsSync(updatedCli)) throw new Error("Updated global DevSpace package is incomplete.");
  return { root: updatedRoot, installer: updatedInstaller, cli: updatedCli };
}

async function updateHermesSourceIfRequested(job, setup, secrets) {
  if (!setup.updateHermesSource || !fs.existsSync(path.join(setup.hermesDir, ".git"))) return;
  appendJobOutput(job, "setup", "Checking Hermes source before fast-forward update.");
  const status = await runLogged(job, "git.exe", ["-C", setup.hermesDir, "status", "--porcelain", "--untracked-files=no"], { cwd: setup.hermesDir, env: process.env }, secrets);
  if (status.stdout.trim()) throw new Error("Hermes has tracked local changes. Source update was refused; commit/stash them or leave 'Update Hermes source' unchecked.");
  await runLogged(job, "git.exe", ["-C", setup.hermesDir, "pull", "--ff-only"], { cwd: setup.hermesDir, env: process.env }, secrets);
}

function startSetupJob(input) {
  if (activeJobId) throw new Error("Another setup/update job is already running.");
  const setup = validateSetup(input);
  if (!fs.existsSync(installerPath)) throw new Error(`Installer is missing: ${installerPath}`);
  if (setup.components.includes("DevSpace") && !setup.updatePackageFromGithub && !fs.existsSync(cliPath)) {
    throw new Error("This package does not contain dist/cli.js. Enable the GitHub package update or install a built package first.");
  }
  const id = crypto.randomBytes(8).toString("hex");
  const job = { id, phase: "running", startedAt: new Date().toISOString(), finishedAt: null, exitCode: null, lines: [] };
  jobs.set(id, job);
  activeJobId = id;

  const secrets = [setup.ngrokAuthToken, setup.devspaceOwnerToken].filter(Boolean);
  (async () => {
    try {
      const runtime = await preparePackageRuntime(job, setup, secrets);
      await updateHermesSourceIfRequested(job, setup, secrets);
      const args = ["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", runtime.installer,
    "-InstallDir", installDir,
    "-Components", setup.components.join(","),
    "-PublicBaseUrl", setup.publicDomain,
    "-NgrokEndpointMode", setup.endpointMode,
    "-MachineName", setup.machineName,
    "-McpNameSuffix", setup.machineName,
    "-HermesDir", setup.hermesDir,
    "-HermesRepo", "https://github.com/davidxyuan/hermes-gpt.git",
    "-TaskLauncher", "PowerShell",
  ];
  if (setup.components.includes("DevSpace")) args.push("-CliPath", runtime.cli, "-SkipNpmInstall");
  if (setup.allowedRoots) {
    args.push("-AllowedRoots", setup.allowedRoots);
    const hermesRoots = setup.allowedRoots.split(/[;,]/).map((value) => value.trim()).filter(Boolean);
    if (hermesRoots.length) args.push("-HermesAllowedRoots", ...hermesRoots);
  }
  if (setup.fullAccess) args.push("-FullAccess");
  if (setup.installTools) args.push("-InstallTools");
  if (setup.endpointMode === "CloudEndpoint") args.push("-NgrokAgentBaseUrl", setup.internalAgentEndpoint);
  if (setup.userMode) args.push("-UserMode", "-NoElevate");
  if (setup.installTray) args.push("-InstallWatchdogTray");
  if (setup.noLegacyPoller) args.push("-NoLegacyPoller");

      const env = { ...process.env };
      if (setup.ngrokAuthToken) env.NGROK_AUTHTOKEN = setup.ngrokAuthToken;
      if (setup.devspaceOwnerToken) env.DEVSPACE_OWNER_TOKEN = setup.devspaceOwnerToken;
      await runLogged(job, powershellPath(), args, { cwd: runtime.root, env }, secrets);
      job.exitCode = 0;
      job.phase = "completed";
    } catch (error) {
      appendJobOutput(job, "error", error instanceof Error ? error.message : String(error), secrets);
      job.exitCode = 1;
      job.phase = "failed";
    } finally {
      job.finishedAt = new Date().toISOString();
      activeJobId = null;
    }
  })();
  return job;
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
}

const template = fs.readFileSync(templatePath, "utf8");
const server = http.createServer(async (req, res) => {
  try {
    if (!req.socket.remoteAddress || !["127.0.0.1", "::1", "::ffff:127.0.0.1"].includes(req.socket.remoteAddress)) {
      sendJson(res, 403, { error: "Loopback only." }); return;
    }
    const url = new URL(req.url || "/", "http://127.0.0.1");
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
      sendJson(res, 200, { ok: true, ...detectInstallState(), activeJobId }); return;
    }
    if (req.method === "GET" && url.pathname === "/api/job") {
      const job = jobs.get(url.searchParams.get("id"));
      sendJson(res, job ? 200 : 404, job || { error: "Job not found." }); return;
    }
    if (req.method === "POST" && url.pathname === "/api/apply") {
      safeMutation(req);
      const payload = JSON.parse(await readRequestBody(req));
      const job = startSetupJob(payload);
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

listen();
