"use strict";

const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const crypto = require("node:crypto");
const { execFile } = require("node:child_process");

const SOURCES = Object.freeze({
  "devspace-official": { repository: "Waishnav/devspace", branch: "main", kind: "npm", package: "@waishnav/devspace" },
  "devspace-tray-fork": { repository: "davidxyuan/devspace", branch: "codex/windows-watchdog-tray-control-center", kind: "git" },
  "hermes-gpt": { repository: "asimons81/hermes-gpt", branch: "master", kind: "git" },
  "hermes-agent": { repository: "NousResearch/hermes-agent", branch: "main", kind: "git", release: true },
});
const LABELS = { node: "Node.js", npm: "npm", git: "Git", python: "Python", "devspace-official": "DevSpace 官方", "devspace-tray-fork": "DevSpace Fork / Tray", "hermes-gpt": "Hermes GPT", "hermes-agent": "Hermes Agent", router: "MCP Router", ngrok: "ngrok", "legacy-watchdog": "舊版 Watchdog", tray: "Watchdog Tray" };
const TOOL_PACKAGES = { node: "OpenJS.NodeJS.LTS", npm: "OpenJS.NodeJS.LTS", git: "Git.Git", python: "Python.Python.3.12" };
const SHA = /^[a-f0-9]{40}$/i;
const VERSION = /^\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?$/;
const TTL = 15 * 60 * 1000;
const MANAGEMENT_FILES = ["devspace-stack-setup.cjs", "stack-management.cjs", "stack-host-management.ps1", "install-devspace-watchdog-tray.ps1"];

function hash(value) { return crypto.createHash("sha256").update(value).digest("hex"); }
function json(file) { try { return JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "")); } catch { return null; } }
function exists(file) { return typeof file === "string" && file.length > 0 && fs.existsSync(file); }
function textFile(file) { try { return fs.readFileSync(file, "utf8"); } catch { return ""; } }
function fileHash(file) { try { return hash(fs.readFileSync(file)); } catch { return null; } }
function bundleFingerprint(root) {
  const files = [path.join(root, "package.json")];
  function walk(dir) {
    if (!exists(dir)) return;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const file = path.join(dir, entry.name);
      if (entry.isSymbolicLink()) throw new Error("隨附安裝檔不可使用連結。");
      if (entry.isDirectory()) walk(file); else if (entry.isFile()) files.push(file);
    }
  }
  walk(path.join(root, "dist")); walk(path.join(root, "scripts", "windows"));
  return hash(JSON.stringify(files.map((file) => [path.relative(root, file), fileHash(file)])));
}
function safePath(value) { return typeof value === "string" && value && !/[\r\n\0]/.test(value) ? path.resolve(value) : null; }
function samePath(a, b) { return a && b && path.resolve(a).toLowerCase() === path.resolve(b).toLowerCase(); }
function repository(value) {
  const match = String(value || "").trim().match(/^(?:https:\/\/github\.com\/|git@github\.com:)([a-z0-9_.-]+\/[a-z0-9_.-]+?)(?:\.git)?\/?$/i);
  return match ? match[1] : null;
}
function sameRepository(a, b) { return a && b && a.toLowerCase() === b.toLowerCase(); }
function repositoryId(value) { return /^[a-z0-9_.-]+\/[a-z0-9_.-]+$/i.test(value || "") ? value : repository(value); }
function productVersion(root) {
  const pythonVersion = textFile(path.join(root, "pyproject.toml")).match(/^version\s*=\s*["']([^"']+)["']/m)?.[1];
  if (pythonVersion) return pythonVersion;
  const pkg = json(path.join(root, "package.json"));
  if (pkg && VERSION.test(pkg.version || "")) return pkg.version;
  return null;
}
function defaultRun(command, args, options = {}) {
  return new Promise((resolve, reject) => execFile(command, args, { windowsHide: true, timeout: 15000, maxBuffer: 16 * 1024 * 1024, ...options }, (error, stdout, stderr) => error ? reject(new Error(`${path.basename(command)} failed.`)) : resolve({ stdout, stderr })));
}
async function attempt(run, command, args, options) { try { return String((await run(command, args, options)).stdout || "").trim(); } catch { return null; } }
function findExecutable(names, env) {
  for (const dir of String(env.PATH || env.Path || "").split(path.delimiter)) {
    if (!dir) continue;
    for (const name of names) { const file = path.join(dir.replace(/^"|"$/g, ""), name); if (exists(file)) return path.resolve(file); }
  }
  return null;
}
function configuredPath(value, fallback) { return safePath(value) || fallback || null; }
function receiptFor(root) {
  let dir = root;
  for (let i = 0; i < 5; i++, dir = path.dirname(dir)) {
    const receipt = json(path.join(dir, "candidate.json"));
    if (receipt && samePath(receipt.root, root)) return receipt;
  }
  return null;
}
async function inspectSource(root, git, run) {
  if (!root || !exists(root)) return { kind: "unknown", repository: null, branch: null, head: null, trackingRef: null, dirty: null, fingerprint: null };
  const receipt = receiptFor(root);
  if (!exists(path.join(root, ".git"))) {
    const payload = json(path.join(root, "oneclick-payload.json"));
    if (payload?.schemaVersion === 1 && Array.isArray(payload.files)) {
      const validFiles = payload.files.length > 0 && payload.files.every((file) => file && typeof file.path === "string" && !/[:\0\r\n]/.test(file.path) && !path.isAbsolute(file.path) && !file.path.split(/[\\/]/).includes("..") && /^[a-f0-9]{64}$/.test(file.sha256 || "") && fileHash(path.join(root, file.path)) === file.sha256);
      const canonical = payload.files.map((file) => `${file?.path}:${file?.sha256}`).join("\n");
      const verified = validFiles && hash(canonical) === payload.fingerprint;
      const provenance = [payload.source, payload.head, payload.repository, payload.branch, payload.trackingRef, payload.remoteName, payload.dirty ? "true" : "false", payload.fingerprint].join("\n");
      const provenanceVerified = typeof payload.dirty === "boolean" && hash(provenance) === payload.provenanceFingerprint;
      return { kind: "bundled", repository: repositoryId(payload.repository), branch: typeof payload.branch === "string" ? payload.branch : null, head: SHA.test(payload.head || "") ? payload.head : null, trackingRef: typeof payload.trackingRef === "string" ? payload.trackingRef : null, remoteName: typeof payload.remoteName === "string" ? payload.remoteName : null, dirty: payload.dirty !== false || !verified, fingerprint: hash(JSON.stringify([payload.fingerprint, hash(provenance), provenanceVerified, verified])), bundleFingerprint: /^[a-f0-9]{64}$/.test(payload.fingerprint || "") ? payload.fingerprint : null, provenance: typeof payload.source === "string" ? payload.source : null, provenanceVerified, verified };
    }
    const pkg = json(path.join(root, "package.json"));
    const npmLocation = path.basename(root) === "devspace" && path.basename(path.dirname(root)) === "@waishnav" && path.basename(path.resolve(root, "..", "..")) === "node_modules";
    const official = pkg?.name === "@waishnav/devspace" && (npmLocation || sameRepository(receipt?.repository, SOURCES["devspace-official"].repository) || sameRepository(repository(typeof pkg.repository === "string" ? pkg.repository : pkg.repository?.url), SOURCES["devspace-official"].repository));
    return { kind: official ? "npm" : "bundled", repository: official ? SOURCES["devspace-official"].repository : (receipt?.repository || null), branch: receipt?.branch || null, head: receipt?.commit || null, trackingRef: null, dirty: null, fingerprint: hash(JSON.stringify([fileHash(path.join(root, "package.json")), fileHash(path.join(root, "dist", "cli.js")), fileHash(path.join(root, "pyproject.toml")), fileHash(path.join(root, "server.py"))])) };
  }
  if (!git) return { kind: "git", repository: null, branch: null, head: null, trackingRef: null, dirty: null, fingerprint: null };
  const get = (args) => attempt(run, git, ["-C", root, ...args]);
  const [remote, head, branch, tracking, status, diff] = await Promise.all([
    get(["remote", "get-url", "origin"]), get(["rev-parse", "HEAD"]), get(["symbolic-ref", "--quiet", "--short", "HEAD"]), get(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]), get(["status", "--porcelain=v1", "--untracked-files=all"]), get(["diff", "HEAD", "--binary"]),
  ]);
  const trackingRemote = branch ? await get(["config", "--get", `branch.${branch}.remote`]) : null;
  const trackingUrl = trackingRemote && trackingRemote !== "." ? await get(["remote", "get-url", trackingRemote]) : remote;
  const resolvedBranch = branch || (receipt && receipt.commit === head ? receipt.branch : null);
  return { kind: "git", repository: repository(trackingUrl), branch: resolvedBranch, head: SHA.test(head || "") ? head : null, trackingRef: tracking || (receipt && receipt.commit === head ? `origin/${receipt.branch}` : null), remoteName: trackingRemote || "origin", dirty: status === null ? null : Boolean(status), fingerprint: status === null || diff === null ? null : hash(JSON.stringify([remote, trackingUrl, head, resolvedBranch, tracking, status, diff])), managed: Boolean(receipt && receipt.commit === head) };
}
function registeredSource(id, source) {
  const canonical = SOURCES[id];
  if (!canonical) return null;
  if (id === "devspace-official" && source.kind === "git") return { ...canonical, kind: "git" };
  if (id === "hermes-gpt" && sameRepository(source.repository, "davidxyuan/hermes-gpt") && (source.branch === "codex/hermes-runtime-provider-fixes" || source.historical)) return { ...canonical, repository: "davidxyuan/hermes-gpt", branch: "codex/hermes-runtime-provider-fixes" };
  return canonical;
}
function sourceProblem(id, source) {
  const registered = registeredSource(id, source);
  if (!registered || !sameRepository(source.repository, registered.repository)) return "來源未登錄；保留既有安裝，不自動切換官方或 Fork。";
  if (source.historical) return "已識別固定的歷史版本；請使用明確的移轉操作，保留原始工作目錄。";
  if (source.kind === "npm" && id === "devspace-official") return null;
  const trustedBundle = id === "devspace-tray-fork" && source.kind === "bundled" && source.provenance === "workspace" && source.verified && source.provenanceVerified;
  if (source.kind !== "git" && !trustedBundle || !source.head || source.dirty === null) return "無法確認工作目錄及版本身分。";
  if (source.dirty) return "工作目錄有修改或未追蹤檔案，更新已停用。";
  if (source.branch !== registered.branch || source.trackingRef !== `${source.remoteName || "origin"}/${registered.branch}`) return "目前分支或追蹤來源不同，更新不會自動切換來源。";
  return null;
}
function knownHistorical(source, version, tested) {
  return Boolean(tested && source.kind === "git" && source.dirty === false && !source.branch && !source.trackingRef && !source.managed && sameRepository(source.repository, repositoryId(tested.repository)) && source.head === tested.revision && SHA.test(tested.revision || "") && version === tested.version);
}
async function requestJson(url, fetcher) {
  let response;
  try { response = await fetcher(url, { headers: { Accept: "application/json", "User-Agent": "DevSpace-Stack-Manager" }, signal: AbortSignal.timeout(12000), redirect: "error" }); }
  catch { const e = new Error("無法連線；保留上次查詢結果。"); e.state = "offline"; throw e; }
  if (!response.ok) { const e = new Error(response.status === 403 || response.status === 429 ? "遠端查詢受到速率限制；稍後再試。" : "遠端版本資訊暫時無法取得。"); e.state = response.status === 403 || response.status === 429 ? "rate_limited" : "unknown"; throw e; }
  const body = await response.text();
  if (body.length > 2 * 1024 * 1024) throw new Error("遠端回覆過大。");
  return JSON.parse(body);
}
async function latestSource(source, installed, fetcher) {
  if (source.kind === "npm") {
    const pkg = await requestJson("https://registry.npmjs.org/%40waishnav%2Fdevspace/latest", fetcher);
    if (pkg.name !== "@waishnav/devspace" || !VERSION.test(pkg.version || "") || !/^sha512-[A-Za-z0-9+/=]+$/.test(pkg.dist?.integrity || "")) throw new Error("套件版本身分不完整。");
    let tag = null;
    try {
      const release = await requestJson(`https://api.github.com/repos/${source.repository}/releases/latest`, fetcher);
      if (release.tag_name === `v${pkg.version}` || release.tag_name === pkg.version) tag = release.tag_name;
    } catch { /* npm's pinned release is usable without GitHub release metadata. */ }
    return { version: pkg.version, tag, commit: SHA.test(pkg.gitHead || "") ? pkg.gitHead : null, url: tag ? `https://github.com/${source.repository}/releases/tag/${tag}` : "https://www.npmjs.com/package/@waishnav/devspace", integrity: pkg.dist.integrity, comparison: installed.installedVersion === pkg.version ? "identical" : "unknown" };
  }
  const base = `https://api.github.com/repos/${source.repository}`;
  let ref = source.branch, tag = null;
  if (source.release) {
    const release = await requestJson(`${base}/releases/latest`, fetcher);
    if (typeof release.tag_name !== "string" || !/^[a-zA-Z0-9._/-]{1,160}$/.test(release.tag_name)) throw new Error("發行標籤無效。");
    ref = tag = release.tag_name;
  }
  const commit = await requestJson(`${base}/commits/${encodeURIComponent(ref)}`, fetcher);
  if (!SHA.test(commit.sha || "")) throw new Error("遠端提交身分無效。");
  let version = null;
  try {
    const filename = source.repository.toLowerCase().endsWith("/devspace") ? "package.json" : "pyproject.toml";
    const content = await requestJson(`${base}/contents/${filename}?ref=${commit.sha}`, fetcher);
    if (content.encoding === "base64" && typeof content.content === "string") {
      const raw = Buffer.from(content.content, "base64").toString("utf8");
      version = filename === "package.json" ? JSON.parse(raw).version : raw.match(/^version\s*=\s*["']([^"']+)["']/m)?.[1];
      if (!VERSION.test(version || "")) version = null;
    }
  } catch { /* A release tag remains useful when its product version is unavailable. */ }
  let comparison = installed.source?.head === commit.sha ? "identical" : "unknown";
  if (installed.source?.head && comparison !== "identical" && (!sourceProblem(installed.id, installed.source) || installed.source.historical)) {
    const compare = await requestJson(`${base}/compare/${installed.source.head}...${commit.sha}`, fetcher);
    comparison = ["ahead", "behind", "diverged", "identical"].includes(compare.status) ? compare.status : "unknown";
  }
  return { version: version || null, tag, commit: commit.sha, url: `https://github.com/${source.repository}/${tag ? `releases/tag/${encodeURIComponent(tag)}` : `commit/${commit.sha}`}`, comparison };
}
function emptyLatest(reason = "尚未查詢；按檢查更新取得遠端版本。") { return { state: "unknown", version: null, tag: null, commit: null, url: null, checkedAt: null, reason }; }
function newerVersion(a, b) {
  if (!VERSION.test(a || "") || !VERSION.test(b || "") || a.includes("-") || b.includes("-")) return null;
  const aa = a.split(".").map(Number), bb = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) { if (aa[i] !== bb[i]) return aa[i] > bb[i]; }
  return false;
}

async function collectInventory(options = {}) {
  const installDir = path.resolve(options.installDir || path.join(os.homedir(), ".devspace"));
  const packageRoot = path.resolve(options.packageRoot || path.join(__dirname, "..", ".."));
  const env = options.env || process.env, run = options.run || defaultRun, fetcher = options.fetch || globalThis.fetch;
  const now = options.now ? Number(options.now()) : Date.now(), checkedAt = new Date(now).toISOString();
  const cache = options.cache || {}, remoteCache = cache.remote || (cache.remote = {});
  const configPath = path.join(installDir, "devspace-watchdog.config.json"), config = json(configPath);
  const blockers = exists(configPath) && !config ? ["既有 Watchdog 設定損壞；請先修復，未覆寫設定。"] : [];
  const w = config || {}, home = options.homeDir || os.homedir(), local = env.LOCALAPPDATA || path.join(home, "AppData", "Local");
  const manifest = json(path.join(packageRoot, "scripts", "windows", "tested-stack-manifest.json")) || {};
  const toolPaths = {
    node: configuredPath(w.nodePath, options.nodePath || process.execPath),
    git: findExecutable(["git.exe", "git"], env),
    python: configuredPath(w.hermesPython, findExecutable(["python.exe", "python3", "python"], env)),
    ngrok: configuredPath(w.ngrokPath, findExecutable(["ngrok.exe", "ngrok"], env)),
  };
  const npmCli = toolPaths.node && path.join(path.dirname(toolPaths.node), "node_modules", "npm", "bin", "npm-cli.js");
  toolPaths.npm = exists(npmCli) ? npmCli : null;
  const components = [];
  function component(id, file, installed, version, source = {}) {
    const entry = { id, label: LABELS[id], installState: installed, runtimeState: "unknown", installedVersion: version || null, path: file || null, source: { kind: "unknown", repository: null, branch: null, head: null, trackingRef: null, dirty: null, fingerprint: null, ...source }, latest: emptyLatest(), tested: null, actions: [], detail: "" };
    components.push(entry); return entry;
  }
  await Promise.all(Object.keys(toolPaths).map(async (id) => {
    const file = toolPaths[id];
    const raw = exists(file) ? await attempt(run, id === "npm" ? toolPaths.node : file, id === "npm" ? [file, "--version"] : ["--version"]) : null;
    const version = raw?.match(/(?:^|[^\d])v?(\d+\.\d+(?:\.\d+)?(?:[-+][\w.-]+)?)\b/)?.[1] || null;
    const entry = component(id, file, !file ? "missing" : !exists(file) || !version ? "partial" : "installed", version, { kind: "executable", fingerprint: fileHash(file) });
    entry.runtimeState = "n/a";
    const nums = version?.split(".").map(Number) || [];
    if (id === "node" && version && !(nums[0] >= 22 && nums[0] < 27 && (nums[0] !== 22 || nums[1] >= 19))) entry.detail = "需要 Node.js >=22.19 且 <27。";
    if (id === "python" && version && !(nums[0] === 3 && nums[1] >= 11 && nums[1] < 14)) entry.detail = "Hermes Agent 需要 Python >=3.11 且 <3.14。";
    entry.actions = [{ id: "install", label: "安裝", enabled: entry.installState === "missing", reason: entry.installState !== "missing" ? "保留已偵測到的程式；不重複安裝。" : null }];
  }));
  const activeRoot = safePath(w.cliPath) ? path.dirname(path.dirname(path.resolve(w.cliPath))) : null;
  const activeSource = await inspectSource(activeRoot, toolPaths.git, run);
  const officialActive = sameRepository(activeSource.repository, SOURCES["devspace-official"].repository);
  const official = component("devspace-official", officialActive ? activeRoot : null, officialActive ? exists(w.cliPath) ? "installed" : "partial" : "missing", officialActive ? productVersion(activeRoot) : null, officialActive ? activeSource : {});
  if (!officialActive && activeRoot) official.detail = "DevSpace 執行程式使用另一個來源，不會自動切換。";
  const activeFork = sameRepository(activeSource.repository, SOURCES["devspace-tray-fork"].repository) || activeRoot && activeSource.kind === "bundled";
  const managerRoot = safePath(w.managementPackageRoot) || (activeFork ? activeRoot : null);
  const managerSource = managerRoot && samePath(managerRoot, activeRoot) ? { ...activeSource } : await inspectSource(managerRoot, toolPaths.git, run);
  const managerVersion = managerRoot ? productVersion(managerRoot) : null;
  managerSource.historical = knownHistorical(managerSource, managerVersion, manifest.devspace);
  const managerRecognized = sameRepository(managerSource.repository, SOURCES["devspace-tray-fork"].repository) || managerRoot && managerSource.kind === "bundled";
  const managerReady = managerRoot && (MANAGEMENT_FILES.every(name => exists(path.join(managerRoot, "scripts", "windows", name))) || managerSource.historical && exists(w.cliPath) && samePath(managerRoot, activeRoot));
  const manager = component("devspace-tray-fork", managerRoot, !managerRoot ? "missing" : managerRecognized && managerReady ? "installed" : "partial", managerVersion, managerSource);
  manager.activationKind = activeFork && samePath(managerRoot, activeRoot) ? "devspace" : "management";
  manager.previousManagementRoot = managerRoot;
  if (managerRoot && !managerReady) manager.detail = "已設定管理程式來源，但必要的管理檔案不完整；不會改用其他來源。";
  else if (manager.activationKind === "management") manager.detail = "Tray／管理程式獨立於 DevSpace 執行程式；更新保留現有執行程式。";
  const hermesRoot = configuredPath(w.hermesWorkingDirectory, path.join(home, "hermes-gpt"));
  const hermes = component("hermes-gpt", hermesRoot, exists(path.join(hermesRoot, "server.py")) ? "installed" : exists(hermesRoot) || w.hermesEnabled ? "partial" : "missing", productVersion(hermesRoot), await inspectSource(hermesRoot, toolPaths.git, run));
  if (hermes.installState === "installed" && !exists(w.hermesPython || path.join(hermesRoot, ".venv", "Scripts", "python.exe"))) { hermes.installState = "partial"; hermes.detail = "找到 Hermes GPT 原始碼，但 Python 執行環境不完整。"; }
  const agentExecutable = safePath(w.hermesAgentExe) || findExecutable(["hermes.exe", "hermes.cmd", "hermes"], env);
  const agentReceipt = agentExecutable ? json(path.resolve(path.dirname(agentExecutable), "..", "..", "candidate.json")) : null;
  const managedAgent = agentReceipt?.kind === "hermes-agent" && samePath(agentReceipt.hermesAgentExe, agentExecutable) ? safePath(agentReceipt.root) : null;
  const agentRoot = safePath(w.hermesAgentWorkingDirectory) || managedAgent || (agentExecutable && /[\\/]venv[\\/]Scripts[\\/]/i.test(agentExecutable) ? path.resolve(path.dirname(agentExecutable), "..", "..") : path.join(local, "hermes", "hermes-agent"));
  const agent = component("hermes-agent", agentRoot, exists(path.join(agentRoot, "pyproject.toml")) && exists(path.join(agentRoot, "hermes_cli")) ? "installed" : exists(agentRoot) || agentExecutable ? "partial" : "missing", productVersion(agentRoot), await inspectSource(agentRoot, toolPaths.git, run));
  if (agentExecutable && !exists(agentRoot)) agent.detail = "偵測到 Hermes 命令，但無法確認其安裝來源。";
  const routerPath = configuredPath(w.routerPath, path.join(installDir, "mcp-router.cjs"));
  component("router", routerPath, exists(routerPath) ? "installed" : w.routerEnabled ? "partial" : "missing", null, { kind: "bundled", fingerprint: fileHash(routerPath) });
  const trayFiles = ["devspace-watchdog-bootstrap.ps1", "devspace-watchdog-tray.ps1", "devspace-watchdog-tray-ui.ps1", "run-devspace-watchdog-tray-hidden.vbs"];
  const trayCount = trayFiles.filter((name) => exists(path.join(installDir, name))).length;
  component("tray", installDir, trayCount === trayFiles.length ? "installed" : trayCount ? "partial" : "missing", null, { kind: "bundled", fingerprint: hash(JSON.stringify(trayFiles.map((name) => fileHash(path.join(installDir, name))))) });
  const legacyPath = path.join(installDir, "devspace-watchdog.ps1");
  const legacy = component("legacy-watchdog", legacyPath, exists(legacyPath) ? "installed" : "missing", null, { kind: "bundled", fingerprint: fileHash(legacyPath) });
  legacy.detail = exists(path.join(installDir, "legacy-watchdog-poller.disabled")) ? "舊排程已標記停用；檔案保留供回復。" : "排程與程序身分會在移轉前再次驗證。";
  for (const entry of components) {
    if (entry.id === "devspace-tray-fork") entry.tested = manifest.devspace || null;
    if (entry.id === "hermes-gpt") { entry.tested = manifest["hermes-gpt"] || null; entry.source.historical = knownHistorical(entry.source, entry.installedVersion, entry.tested); }
    if (options.runtimeStates && ["running", "stopped", "unknown", "n/a"].includes(options.runtimeStates[entry.id])) entry.runtimeState = options.runtimeStates[entry.id];
  }
  await Promise.all(components.filter((c) => SOURCES[c.id]).map(async (entry) => {
    // Official upstream remains visible even when a local fork cannot be updated.
    const source = sourceProblem(entry.id, entry.source) && !entry.source.historical ? SOURCES[entry.id] : registeredSource(entry.id, entry.source);
    const key = `${source.repository}#${source.kind === "npm" ? "npm" : source.release ? "release" : source.branch}:${entry.source.head || entry.installedVersion || "missing"}`;
    const previous = cache.components?.find((c) => c.id === entry.id);
    const previousMatches = previous && previous.source?.head === entry.source.head && previous.installedVersion === entry.installedVersion && sameRepository(previous.latest?.repository, source.repository) && previous.latest?.branch === source.branch;
    const cached = remoteCache[key] || (previousMatches && previous.latest.checkedAt ? previous.latest : null);
    entry.latest = cached ? { ...cached } : emptyLatest();
    if (!options.checkLatest || (cached && now - Date.parse(cached.checkedAt) < (options.cacheTtlMs ?? TTL))) return;
    try {
      entry.latest = { state: "current", ...(await latestSource(source, entry, fetcher)), repository: source.repository, branch: source.branch, checkedAt, reason: null };
      remoteCache[key] = { ...entry.latest };
    } catch (error) {
      entry.latest = { ...(cached || emptyLatest()), state: error.state || "unknown", reason: error.state ? error.message : "遠端版本資訊無法驗證；保留上次結果。" };
    }
  }));
  for (const entry of components) {
    if (SOURCES[entry.id]) {
      const missing = entry.installState === "missing", problem = !missing ? sourceProblem(entry.id, entry.source) : null;
      if (problem && !entry.source.historical && entry.source.kind === "git") entry.latest.comparison = "unknown";
      const latest = entry.latest, current = latest.state === "current" && now - Date.parse(latest.checkedAt) < TTL;
      const updateAvailable = entry.source.kind === "npm" ? newerVersion(latest.version, entry.installedVersion) === true : latest.comparison === "ahead";
      const devspaceConflict = entry.id === "devspace-official" && activeRoot && !samePath(activeRoot, entry.path);
      const installedConfig = Boolean(config && json(path.join(installDir, "config.json")));
      const installReason = devspaceConflict ? "另一個 DevSpace 來源已啟用，禁止隱含切換。" : !installedConfig ? "請先使用一鍵安裝精靈設定工作目錄與連線。" : !current && entry.id !== "devspace-tray-fork" ? "先檢查更新，取得可驗證的安裝版本。" : null;
      entry.actions = [
        { id: "install", label: "安裝", enabled: missing && !installReason && !blockers.length, reason: missing ? installReason : "已偵測到安裝，不重複安裝。" },
        { id: "update", label: "更新", enabled: !missing && entry.installState === "installed" && !problem && current && updateAvailable && !blockers.length, reason: missing ? "尚未安裝。" : problem || (entry.installState !== "installed" ? entry.detail || "既有安裝不完整。" : !current ? "先檢查更新；離線或過期資訊不會用來更新。" : !updateAvailable ? latest.comparison === "identical" ? "已是此來源的最新版本。" : "無法確認安全向前更新；可能在遠端之前或已分歧。" : null) },
      ];
      if (entry.source.historical) entry.actions.push({ id: "migrate", label: "移轉歷史版本", enabled: entry.installState === "installed" && current && ["ahead", "identical"].includes(latest.comparison) && !blockers.length, reason: !current ? "先查詢並固定目前已登錄來源的版本。" : !["ahead", "identical"].includes(latest.comparison) ? "無法確認歷史版本至目前來源的提交關係。" : null });
      if (problem && !missing) entry.detail = entry.detail || problem;
    } else if (["tray", "router", "legacy-watchdog"].includes(entry.id)) {
      const installer = path.join(packageRoot, "scripts", "windows", "install-devspace-watchdog-tray.ps1");
      const ready = Boolean(config && exists(installer) && !blockers.length);
      entry.actions = [{ id: entry.id === "legacy-watchdog" ? "migrate" : entry.installState === "installed" ? "repair" : "install", label: entry.id === "legacy-watchdog" ? "移轉至 Tray" : entry.installState === "installed" ? "修復" : "安裝", enabled: ready && (entry.id !== "legacy-watchdog" || entry.installState === "installed"), reason: !ready ? "請先使用一鍵安裝精靈完成基本設定。" : entry.id === "legacy-watchdog" && entry.installState === "missing" ? "沒有偵測到舊版檔案。" : null }];
    }
    if (blockers.length) for (const action of entry.actions) { action.enabled = false; action.reason = blockers[0]; }
  }
  components.sort((a, b) => Object.keys(LABELS).indexOf(a.id) - Object.keys(LABELS).indexOf(b.id));
  const evidence = { installDir, packageRoot, configurationFingerprint: hash(textFile(configPath)), components: components.map(({ id, installState, installedVersion, path: p, source, activationKind, previousManagementRoot }) => ({ id, installState, installedVersion, path: p, source, activationKind, previousManagementRoot })) };
  const inventory = { schemaVersion: 1, installDir, packageRoot, revision: hash(JSON.stringify(evidence)), configurationFingerprint: evidence.configurationFingerprint, checkedAt, remoteCheckedAt: components.map((c) => c.latest.checkedAt).filter(Boolean).sort().at(-1) || null, refreshing: false, components, blockers };
  return inventory;
}

function planComponentAction(request, inventory, context = {}) {
  if (!request || !inventory || request.expectedRevision !== inventory.revision) throw new Error("安裝狀態已改變；請重新整理後再操作。");
  const component = inventory.components.find((c) => c.id === request.componentId);
  const action = component?.actions.find((a) => a.id === request.action);
  if (!component || !action?.enabled) throw new Error(action?.reason || "此元件操作不受支援。");
  const installDir = safePath(context.installDir || inventory.installDir), packageRoot = safePath(context.packageRoot || inventory.packageRoot);
  if (!installDir || !packageRoot) throw new Error("缺少安裝位置。");
  let target;
  if (TOOL_PACKAGES[component.id]) target = { kind: "winget", packageId: TOOL_PACKAGES[component.id] };
  else if (["tray", "router", "legacy-watchdog", "ngrok"].includes(component.id) || component.id === "devspace-tray-fork" && request.action === "install") target = { kind: "bundled", repository: SOURCES["devspace-tray-fork"].repository, payloadFingerprint: bundleFingerprint(packageRoot) };
  else {
    const registered = request.action === "install" ? SOURCES[component.id] : registeredSource(component.id, component.source);
    if (!registered || !sameRepository(component.latest.repository, registered.repository)) throw new Error("版本來源與已登錄來源不符。");
    target = { kind: registered.kind, repository: registered.repository, branch: registered.branch, commit: component.latest.commit, version: component.latest.version, tag: component.latest.tag, integrity: component.latest.integrity || null };
    if (target.kind === "git" && !SHA.test(target.commit || "")) throw new Error("缺少固定提交版本。");
    if (target.kind === "npm" && (!VERSION.test(target.version || "") || !/^sha512-[A-Za-z0-9+/=]+$/.test(target.integrity || ""))) throw new Error("缺少固定 npm 版本及完整性資料。");
  }
  return { schemaVersion: 1, componentId: component.id, action: request.action, activationKind: component.activationKind || null, expectedRevision: inventory.revision, installDir, packageRoot, sourcePath: component.path, sourceFingerprint: component.source.fingerprint, target, stages: target.kind === "winget" || target.kind === "bundled" ? ["revalidate", "activate", "verify"] : ["revalidate", "stage", "validate", "activate", "verify"] };
}

async function executeComponentAction(plan, callbacks = {}) {
  if (!plan || plan.schemaVersion !== 1 || !LABELS[plan.componentId] || typeof callbacks.activate !== "function") throw new Error("元件操作計畫無效。");
  const run = callbacks.run || defaultRun, log = callbacks.log || (() => {});
  const inventory = await collectInventory({ installDir: plan.installDir, packageRoot: plan.packageRoot, checkLatest: false, ...(callbacks.inventoryOptions || {}) });
  if (inventory.revision !== plan.expectedRevision) throw new Error("安裝狀態在執行前已改變；操作已取消。");
  const component = inventory.components.find((c) => c.id === plan.componentId);
  if (component.source.fingerprint !== plan.sourceFingerprint || !samePath(component.path || plan.installDir, plan.sourcePath || plan.installDir)) throw new Error("元件身分在執行前已改變。");
  if ((component.activationKind || null) !== plan.activationKind) throw new Error("元件啟用範圍已改變。");
  const target = plan.target, tool = (id) => inventory.components.find((c) => c.id === id);
  let candidate;
  if (target.kind === "winget") {
    if (target.packageId !== TOOL_PACKAGES[plan.componentId] || plan.action !== "install" || component.installState !== "missing") throw new Error("工具安裝計畫無效。");
    candidate = { kind: "tool", componentId: plan.componentId, packageId: target.packageId };
  } else if (target.kind === "bundled") {
    if (!["tray", "router", "legacy-watchdog", "devspace-tray-fork", "ngrok"].includes(plan.componentId) || bundleFingerprint(plan.packageRoot) !== target.payloadFingerprint) throw new Error("隨附安裝程式在執行前已改變。");
    candidate = { kind: plan.componentId === "devspace-tray-fork" ? (plan.activationKind === "management" ? "management" : "devspace") : "bundled", componentId: plan.componentId, root: plan.packageRoot, version: productVersion(plan.packageRoot), cliPath: path.join(plan.packageRoot, "dist", "cli.js"), installerPath: path.join(plan.packageRoot, "scripts", "windows", ["tray", "legacy-watchdog", "devspace-tray-fork"].includes(plan.componentId) ? "install-devspace-watchdog-tray.ps1" : "install-devspace-watchdog.ps1") };
    if (!exists(candidate.installerPath)) throw new Error("隨附安裝程式不完整。");
  } else {
    const registered = plan.action === "install" ? SOURCES[plan.componentId] : registeredSource(plan.componentId, component.source);
    if (!registered || target.kind !== registered.kind || !sameRepository(target.repository, registered.repository) || target.branch !== registered.branch || plan.action === "update" && sourceProblem(plan.componentId, component.source) || plan.action === "migrate" && !component.source.historical) throw new Error("不允許切換或覆寫此來源。");
    const requiredTools = target.kind === "npm" ? ["node", "npm"] : plan.componentId.startsWith("devspace-") ? ["git", "node", "npm"] : ["git", "python"];
    for (const id of requiredTools) if (tool(id)?.installState !== "installed" || tool(id).detail) throw new Error(`請先安裝相容的 ${LABELS[id]}。`);
    if (target.kind === "git" && !SHA.test(target.commit || "") || target.kind === "npm" && (!VERSION.test(target.version || "") || !/^sha512-[A-Za-z0-9+/=]+$/.test(target.integrity || ""))) throw new Error("固定版本不完整。");
    const managed = path.join(plan.installDir, "managed", plan.componentId);
    const canonicalInstall = fs.realpathSync(plan.installDir);
    for (const dir of [path.join(plan.installDir, "managed"), managed]) {
      if (exists(dir) && (fs.lstatSync(dir).isSymbolicLink() || !fs.realpathSync(dir).toLowerCase().startsWith(canonicalInstall.toLowerCase() + path.sep))) throw new Error("候選安裝目錄不可指向安裝位置以外。");
    }
    fs.mkdirSync(managed, { recursive: true });
    const stage = fs.mkdtempSync(path.join(managed, `${(target.commit || target.version).slice(0, 40)}-`));
    let root;
    log(`建立獨立候選版本：${stage}`);
    const invoke = async (command, args, options = {}) => { const result = await run(command, args, { timeout: 20 * 60 * 1000, ...options }); if (result?.exitCode && result.exitCode !== 0) throw new Error(`${path.basename(command)} failed.`); return result; };
    if (target.kind === "npm") {
      await invoke(tool("node").path, [tool("npm").path, "install", "--prefix", stage, "--save-exact", "--no-audit", "--no-fund", "--registry=https://registry.npmjs.org", `@waishnav/devspace@${target.version}`]);
      root = path.join(stage, "node_modules", "@waishnav", "devspace");
      const locked = json(path.join(stage, "package-lock.json"))?.packages?.["node_modules/@waishnav/devspace"];
      if (locked?.integrity !== target.integrity || locked?.version !== target.version) throw new Error("下載套件與已核對版本不符。");
    } else {
      root = path.join(stage, "payload");
      await invoke(tool("git").path, ["clone", "--no-checkout", "--filter=blob:none", "--", `https://github.com/${target.repository}.git`, root]);
      await invoke(tool("git").path, ["-C", root, "fetch", "--depth=1", "origin", target.commit]);
      await invoke(tool("git").path, ["-C", root, "checkout", "--detach", target.commit]);
      const head = await attempt(run, tool("git").path, ["-C", root, "rev-parse", "HEAD"]);
      if (head !== target.commit) throw new Error("候選版本提交不符。");
      if (plan.componentId.startsWith("devspace-")) {
        await invoke(tool("node").path, [tool("npm").path, "ci", "--no-audit", "--no-fund"], { cwd: root });
        await invoke(tool("node").path, [tool("npm").path, "run", "build"], { cwd: root });
        if (plan.componentId === "devspace-tray-fork") {
          const scripts = json(path.join(root, "package.json"))?.scripts || {};
          if (typeof scripts.test !== "string" || typeof scripts["test:windows-watchdog"] !== "string") throw new Error("候選 DevSpace Fork 缺少 npm test 或 npm run test:windows-watchdog；更新已停用。");
          await invoke(tool("node").path, [tool("npm").path, "test"], { cwd: root });
          await invoke(tool("node").path, [tool("npm").path, "run", "test:windows-watchdog"], { cwd: root });
        }
      } else {
        const venv = path.join(stage, "venv");
        await invoke(tool("python").path, ["-m", "venv", venv]);
        const python = path.join(venv, "Scripts", "python.exe");
        if (plan.componentId === "hermes-gpt" && exists(path.join(root, "requirements.txt"))) await invoke(python, ["-m", "pip", "install", "-r", path.join(root, "requirements.txt")]);
        const declared = await invoke(python, ["-c", "import json,pathlib,tomllib; p=pathlib.Path('.'); d=tomllib.loads((p/'pyproject.toml').read_text(encoding='utf-8')); groups=d.get('project',{}).get('optional-dependencies',{}); print(json.dumps({'extras':[k for k in ('dev','test','tests') if k in groups], 'tests':any(p.glob('test_*.py')) or any((p/'tests').rglob('test_*.py'))}))"], { cwd: root });
        const pythonTests = JSON.parse(declared.stdout);
        if (!pythonTests.tests || !Array.isArray(pythonTests.extras) || pythonTests.extras.some(name => !["dev", "test", "tests"].includes(name))) throw new Error("候選 Hermes 沒有可驗證的測試套件；尚未啟用。");
        for (const requirement of ["requirements-dev.txt", "requirements-test.txt"]) if (exists(path.join(root, requirement))) await invoke(python, ["-m", "pip", "install", "-r", path.join(root, requirement)]);
        await invoke(python, ["-m", "pip", "install", root + (pythonTests.extras.length ? `[${pythonTests.extras.join(",")}]` : "")]);
        candidate = { kind: plan.componentId, componentId: plan.componentId, root, version: productVersion(root), commit: target.commit, pythonPath: python, ...(plan.componentId === "hermes-gpt" ? { hermesServer: path.join(root, "server.py") } : { hermesAgentExe: path.join(venv, "Scripts", "hermes.exe") }) };
        const check = plan.componentId === "hermes-gpt" ? "import ast,pathlib; ast.parse(pathlib.Path('server.py').read_text(encoding='utf-8')); import mcp,uvicorn" : "import hermes_cli.main";
        await invoke(python, ["-c", check], { cwd: root });
        if (!exists(candidate.hermesServer || candidate.hermesAgentExe)) throw new Error("候選 Hermes 執行入口不存在。");
        await invoke(python, ["-m", "pytest", "-q"], { cwd: root });
        if (plan.componentId === "hermes-agent") {
          let smoke = "", versionOk = false;
          try {
            const result = await invoke(candidate.hermesAgentExe, ["--version"], { cwd: root });
            smoke = `${result.stdout || ""}${result.stderr || ""}`;
            versionOk = /\d+\.\d+\.\d+/.test(smoke);
          } catch { /* --help below is the supported fallback for CLIs without --version. */ }
          if (!versionOk) {
            try {
              const result = await invoke(candidate.hermesAgentExe, ["--help"], { cwd: root });
              smoke = `${result.stdout || ""}${result.stderr || ""}`;
            } catch { /* report the common validation error below */ }
          }
          if (!versionOk && !/(?:hermes|usage|options|help)/i.test(smoke)) throw new Error("候選 Hermes Agent 執行入口未通過 smoke test；更新已停用。");
          candidate.agentSmoke = versionOk ? "version" : "help";
        }
        candidate.validation = "tested";
      }
    }
    if (plan.componentId.startsWith("devspace-")) {
      if (json(path.join(root, "package.json"))?.name !== "@waishnav/devspace") throw new Error("候選 DevSpace 套件身分不符。");
      candidate = { kind: plan.componentId === "devspace-tray-fork" && plan.activationKind === "management" ? "management" : "devspace", componentId: plan.componentId, root, version: productVersion(root), commit: target.commit, cliPath: path.join(root, "dist", "cli.js"), nodePath: tool("node").path, installerPath: path.join(root, "scripts", "windows", plan.componentId === "devspace-tray-fork" ? "install-devspace-watchdog-tray.ps1" : "install-devspace-watchdog.ps1") };
      if (!exists(candidate.cliPath)) throw new Error("候選 DevSpace 執行入口不存在。");
      await invoke(tool("node").path, ["--check", candidate.cliPath]);
      await invoke(tool("node").path, [candidate.cliPath, "help"], { cwd: root });
      if (plan.componentId === "devspace-tray-fork" && (!exists(candidate.installerPath) || !exists(path.join(root, "scripts", "windows", "devspace-watchdog-tray-ui.ps1")))) throw new Error("此 Fork 版本未包含所需 Tray 安裝檔。");
    }
    if (target.version && candidate.version !== target.version) throw new Error("候選程式版本與遠端資訊不符。");
    candidate.runtimeRoot = stage;
    candidate.action = plan.action;
    fs.writeFileSync(path.join(stage, "candidate.json"), JSON.stringify({ ...candidate, repository: target.repository, branch: target.branch, tag: target.tag, validatedAt: new Date().toISOString() }, null, 2));
  }
  candidate.action = plan.action;
  if (candidate.root && !candidate.runtimeRoot) candidate.runtimeRoot = candidate.root;
  const beforeActivation = await collectInventory({ installDir: plan.installDir, packageRoot: plan.packageRoot, checkLatest: false, ...(callbacks.inventoryOptions || {}) });
  if (beforeActivation.revision !== plan.expectedRevision) throw new Error("安裝狀態在準備候選版本時已改變；尚未套用更新。");
  log("候選版本已驗證，交由安裝交易套用並檢查健康狀態。");
  const result = await callbacks.activate(candidate, plan);
  return { candidate, activation: result ?? null };
}

module.exports = { collectInventory, planComponentAction, executeComponentAction };
