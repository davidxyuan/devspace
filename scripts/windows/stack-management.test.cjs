"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const crypto = require("node:crypto");
const { execFileSync, execFile } = require("node:child_process");
const { collectInventory, planComponentAction, executeComponentAction } = require("./stack-management.cjs");

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "devspace-management-test-"));
const installDir = path.join(temp, "installation");
const packageRoot = path.join(temp, "bundle");
const homeDir = path.join(temp, "home");
const toolDir = path.join(temp, "tools");
const nodePath = path.join(toolDir, "node.exe"), pythonPath = path.join(toolDir, "python.exe");
const gitPath = execFileSync(process.platform === "win32" ? "where.exe" : "which", ["git"], { encoding: "utf8" }).trim().split(/\r?\n/)[0];
function write(file, value) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, typeof value === "string" ? value : JSON.stringify(value, null, 2)); }
function git(root, args) { return execFileSync(gitPath, ["-C", root, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim(); }
function makeRepo(root, repo, branch, files) {
  fs.mkdirSync(root, { recursive: true });
  git(root, ["init", "-b", branch]); git(root, ["config", "user.name", "test"]); git(root, ["config", "user.email", "test@example.invalid"]);
  for (const [name, content] of Object.entries(files)) write(path.join(root, name), content);
  git(root, ["add", "."]); git(root, ["commit", "-m", "fixture"]); git(root, ["remote", "add", "origin", `https://github.com/${repo}.git`]);
  const head = git(root, ["rev-parse", "HEAD"]);
  git(root, ["update-ref", `refs/remotes/origin/${branch}`, head]); git(root, ["branch", "--set-upstream-to", `origin/${branch}`]);
  return head;
}
async function run(command, args, options = {}) {
  if (args.length === 1 && args[0] === "--version") return { stdout: path.basename(command).startsWith("node") ? "v24.14.0" : path.basename(command).startsWith("python") ? "Python 3.12.4" : path.basename(command).startsWith("ngrok") ? "ngrok version 3.39.8" : "git version 2.53.0.windows.1" };
  if (args.at(-1) === "--version" && args[0].endsWith("npm-cli.js")) return { stdout: "11.9.0" };
  return new Promise((resolve, reject) => execFile(command, args, { windowsHide: true, ...options }, (err, stdout, stderr) => err ? reject(err) : resolve({ stdout, stderr })));
}
const configPath = path.join(installDir, "devspace-watchdog.config.json");
const env = { PATH: `${toolDir}${path.delimiter}${path.dirname(gitPath)}`, LOCALAPPDATA: path.join(homeDir, "AppData", "Local") };
const base = { installDir, packageRoot, homeDir, env, nodePath, run };
const forkRoot = path.join(temp, "fork");
const forkBranch = "codex/windows-watchdog-tray-control-center";
const managementFiles = Object.fromEntries(["devspace-stack-setup.cjs", "stack-management.cjs", "stack-host-management.ps1", "install-devspace-watchdog-tray.ps1"].map(name => [`scripts/windows/${name}`, "// management fixture"]));
const nextHead = "a".repeat(40);
let networkCalls = 0, remoteMode = "ok", clock = Date.UTC(2026, 8, 5), compareStatus = "ahead";
const cache = {};
const fetch = async (url, options) => {
  networkCalls++;
  assert.equal(options.headers.Accept, "application/json", "npm registry does not accept GitHub-specific media types");
  if (remoteMode === "offline") throw new Error("sensitive-token-error");
  if (remoteMode === "rate") return { ok: false, status: 429, text: async () => "token=never-return" };
  let body;
  if (url.includes("registry.npmjs.org")) body = { name: "@waishnav/devspace", version: "1.0.5", dist: { integrity: "sha512-YWJjZA==" }, gitHead: nextHead };
  else if (url.endsWith("/releases/latest")) body = { tag_name: "v2026.8.31" };
  else if (url.includes("/commits/")) body = { sha: nextHead };
  else if (url.includes("/compare/")) body = { status: compareStatus };
  else if (url.includes("/contents/")) body = { encoding: "base64", content: Buffer.from(url.includes("package.json") ? JSON.stringify({ version: "1.0.5" }) : `version = "${url.includes("hermes-agent") ? "0.21.0" : "0.5.1"}"`).toString("base64") };
  else throw new Error(`Unexpected URL ${url}`);
  return { ok: true, text: async () => JSON.stringify(body) };
};
const collect = (extra = {}) => collectInventory({ ...base, fetch, cache, now: () => clock, ...extra });
const component = (i, id) => i.components.find((c) => c.id === id);
const action = (i, id, name) => component(i, id).actions.find((a) => a.id === name);
const request = (i, id, name) => ({ componentId: id, action: name, expectedRevision: i.revision });

(async () => {
  write(nodePath, "node fixture"); write(pythonPath, "python fixture"); write(path.join(toolDir, "node_modules", "npm", "bin", "npm-cli.js"), "npm fixture");
  write(path.join(packageRoot, "package.json"), { name: "@waishnav/devspace", version: "1.0.4" });
  write(path.join(packageRoot, "scripts", "windows", "install-devspace-watchdog-tray.ps1"), "# bundled installer");
  write(path.join(packageRoot, "scripts", "windows", "install-devspace-watchdog.ps1"), "# main installer");
  const forkHead = makeRepo(forkRoot, "davidxyuan/devspace", forkBranch, { ...managementFiles, "package.json": { name: "@waishnav/devspace", version: "1.0.4" }, "dist/cli.js": "console.log('fixture');" });
  const config = { cliPath: path.join(forkRoot, "dist", "cli.js"), nodePath, hermesPython: pythonPath, ngrokAuthtoken: "SECRET-NGROK", publicBaseUrl: "https://user:SECRET-PASSWORD@example.invalid", custom: { important: true } };
  write(configPath, config); write(path.join(installDir, "config.json"), { allowedRoots: [homeDir] }); write(path.join(installDir, "auth.json"), { ownerToken: "SECRET-OWNER" });
  const beforeConfig = fs.readFileSync(configPath), beforeAuth = fs.readFileSync(path.join(installDir, "auth.json"));

  let i = await collect();
  assert.equal(networkCalls, 0, "local inventory never performs remote requests");
  assert.equal(component(i, "node").installedVersion, "24.14.0");
  assert.equal(component(i, "node").detail, "");
  assert.equal(component(i, "devspace-tray-fork").source.head, forkHead);
  assert.equal(component(i, "devspace-tray-fork").source.dirty, false);
  assert.equal(action(i, "devspace-official", "install").enabled, false, "official package cannot silently replace active fork");
  assert.equal(action(i, "devspace-tray-fork", "update").enabled, false);
  assert.doesNotMatch(JSON.stringify(i), /SECRET|user:|PASSWORD/);

  i = await collect({ checkLatest: true });
  assert.equal(action(i, "devspace-tray-fork", "update").enabled, true);
  assert.equal(component(i, "hermes-agent").latest.tag, "v2026.8.31");
  assert.equal(component(i, "hermes-agent").latest.version, "0.21.0");
  const calls = networkCalls;
  await collect({ checkLatest: true }); assert.equal(networkCalls, calls, "TTL avoids repeated remote checks");
  const persisted = JSON.parse(JSON.stringify(i));
  await collect({ checkLatest: true, cache: persisted }); assert.equal(networkCalls, calls, "TTL survives a worker restart using persisted inventory");

  // A detached historical DevSpace checkout must expose migration explicitly and preserve its bytes.
  const historicalPackageRoot = path.join(temp, "historical-package");
  write(path.join(historicalPackageRoot, "scripts", "windows", "tested-stack-manifest.json"), { schemaVersion: 1, devspace: { repository: "https://github.com/davidxyuan/devspace.git", ref: forkBranch, revision: forkHead, version: "1.0.4" }, "hermes-gpt": { repository: "https://github.com/davidxyuan/hermes-gpt.git", ref: "codex/hermes-runtime-provider-fixes", revision: "b".repeat(40), version: "0.5.0" } });
  git(forkRoot, ["checkout", "--detach", forkHead]);
  compareStatus = "ahead";
  i = await collect({ packageRoot: historicalPackageRoot, checkLatest: true });
  assert.equal(component(i, "devspace-tray-fork").source.historical, true);
  assert.equal(action(i, "devspace-tray-fork", "migrate").enabled, true);
  const historicalPlan = planComponentAction(request(i, "devspace-tray-fork", "migrate"), i, { packageRoot: historicalPackageRoot });
  const historicalHeadBefore = git(forkRoot, ["rev-parse", "HEAD"]);
  const historicalStatusBefore = git(forkRoot, ["status", "--porcelain"]);
  let historicalStageRoot;
  const historicalRun = async (command, args, options = {}) => {
    if (args[0] === "clone") {
      historicalStageRoot = args.at(-1);
      write(path.join(historicalStageRoot, "package.json"), { name: "@waishnav/devspace", version: "1.0.5", scripts: { test: "node test.js", "test:windows-watchdog": "node watchdog-test.js" } });
      write(path.join(historicalStageRoot, "dist", "cli.js"), "// migrated candidate");
      for (const [name, contents] of Object.entries(managementFiles)) write(path.join(historicalStageRoot, name), contents);
      write(path.join(historicalStageRoot, "scripts", "windows", "devspace-watchdog-tray-ui.ps1"), "# candidate tray");
    }
    if (args[0] === "-C" && args[2] === "rev-parse") return { stdout: nextHead };
    return { stdout: "" };
  };
  await executeComponentAction(historicalPlan, { inventoryOptions: { ...base, packageRoot: historicalPackageRoot }, run: historicalRun, activate: async candidate => {
    assert.equal(candidate.action, "migrate");
    assert.equal(candidate.root, historicalStageRoot);
  } });
  assert.equal(git(forkRoot, ["rev-parse", "HEAD"]), historicalHeadBefore);
  assert.equal(git(forkRoot, ["status", "--porcelain"]), historicalStatusBefore);
  git(forkRoot, ["checkout", "-B", forkBranch]);
  git(forkRoot, ["update-ref", `refs/remotes/origin/${forkBranch}`, forkHead]);
  git(forkRoot, ["branch", "--set-upstream-to", `origin/${forkBranch}`]);

  // Historical Hermes GPT checkouts get the same explicit migration path and source preservation.
  const hermesHistoricalRoot = path.join(temp, "hermes-historical");
  const hermesHistoricalHead = makeRepo(hermesHistoricalRoot, "asimons81/hermes-gpt", "master", {
    "pyproject.toml": '[project]\nname="hermes-gpt"\nversion="0.5.0"',
    "server.py": "# historical Hermes server",
  });
  git(hermesHistoricalRoot, ["checkout", "--detach", hermesHistoricalHead]);
  const hermesHistoricalPackageRoot = path.join(temp, "hermes-history-package");
  write(path.join(hermesHistoricalPackageRoot, "scripts", "windows", "tested-stack-manifest.json"), { schemaVersion: 1, "hermes-gpt": { repository: "https://github.com/asimons81/hermes-gpt.git", ref: "master", revision: hermesHistoricalHead, version: "0.5.0" } });
  const hermesHistoricalConfig = { ...config, cliPath: path.join(forkRoot, "dist", "cli.js"), hermesWorkingDirectory: hermesHistoricalRoot, hermesPython: pythonPath };
  write(configPath, hermesHistoricalConfig);
  i = await collect({ packageRoot: hermesHistoricalPackageRoot, checkLatest: true });
  assert.equal(component(i, "hermes-gpt").source.historical, true);
  assert.equal(action(i, "hermes-gpt", "migrate").enabled, true);
  const hermesHistoricalPlan = planComponentAction(request(i, "hermes-gpt", "migrate"), i, { packageRoot: hermesHistoricalPackageRoot });
  const hermesHistoricalHeadBefore = git(hermesHistoricalRoot, ["rev-parse", "HEAD"]);
  const hermesHistoricalStatusBefore = git(hermesHistoricalRoot, ["status", "--porcelain"]);
  const hermesHistoricalBytesBefore = fs.readFileSync(path.join(hermesHistoricalRoot, "server.py"));
  let hermesHistoricalStageRoot;
  const hermesHistoricalRun = async (command, args, options = {}) => {
    if (args[0] === "clone") {
      hermesHistoricalStageRoot = args.at(-1);
      write(path.join(hermesHistoricalStageRoot, "pyproject.toml"), '[project]\nname="hermes-gpt"\nversion="0.5.1"\n[project.optional-dependencies]\ndev=["pytest"]');
      write(path.join(hermesHistoricalStageRoot, "server.py"), "# migrated Hermes server");
      write(path.join(hermesHistoricalStageRoot, "tests", "test_smoke.py"), "def test_smoke(): pass");
    }
    if (args[0] === "-C" && args[2] === "rev-parse") return { stdout: nextHead };
    if (args[0] === "-m" && args[1] === "venv") write(path.join(args[2], "Scripts", "python.exe"), "isolated python");
    if (args[0] === "-c" && args[1].includes("tomllib")) return { stdout: JSON.stringify({ extras: ["dev"], tests: true }) };
    return { stdout: "" };
  };
  await executeComponentAction(hermesHistoricalPlan, { inventoryOptions: { ...base, packageRoot: hermesHistoricalPackageRoot }, run: hermesHistoricalRun, activate: async candidate => {
    assert.equal(candidate.action, "migrate");
    assert.equal(candidate.kind, "hermes-gpt");
    assert.equal(candidate.root, hermesHistoricalStageRoot);
  } });
  assert.equal(git(hermesHistoricalRoot, ["rev-parse", "HEAD"]), hermesHistoricalHeadBefore);
  assert.equal(git(hermesHistoricalRoot, ["status", "--porcelain"]), hermesHistoricalStatusBefore);
  assert.deepEqual(fs.readFileSync(path.join(hermesHistoricalRoot, "server.py")), hermesHistoricalBytesBefore);
  const historicalManifestPath = path.join(hermesHistoricalPackageRoot, "scripts", "windows", "tested-stack-manifest.json");
  const historicalManifest = JSON.parse(fs.readFileSync(historicalManifestPath, "utf8"));
  for (const [label, change] of [
    ["repository mismatch", { repository: "attacker/hermes-gpt" }],
    ["revision mismatch", { revision: "c".repeat(40) }],
    ["version mismatch", { version: "0.5.9" }],
  ]) {
    write(historicalManifestPath, { ...historicalManifest, "hermes-gpt": { ...historicalManifest["hermes-gpt"], ...change } });
    const invalidHistorical = await collect({ packageRoot: hermesHistoricalPackageRoot, checkLatest: true });
    const invalidComponent = component(invalidHistorical, "hermes-gpt");
    assert.equal(invalidComponent.source.historical, false, `Hermes GPT ${label} must not be accepted as historical`);
    assert.equal(invalidComponent.actions.some(candidate => candidate.id === "migrate"), false, `Hermes GPT ${label} must not expose migration`);
  }
  write(historicalManifestPath, historicalManifest);
  write(configPath, config);

  // A separate clean manager checkout must update management files without changing the active DevSpace CLI.
  const managerRoot = path.join(temp, "manager");
  const managerHead = makeRepo(managerRoot, "davidxyuan/devspace", forkBranch, {
    "package.json": { name: "@waishnav/devspace", version: "1.0.5", scripts: { test: "node test.js", "test:windows-watchdog": "node watchdog-test.js" } },
    "dist/cli.js": "console.log('manager candidate');",
    "scripts/windows/devspace-stack-setup.cjs": "// manager",
    "scripts/windows/stack-management.cjs": "// manager",
    "scripts/windows/stack-host-management.ps1": "# manager",
    "scripts/windows/install-devspace-watchdog-tray.ps1": "# manager",
    "scripts/windows/devspace-watchdog-tray-ui.ps1": "# manager",
  });
  const officialRoot = path.join(temp, "official", "node_modules", "@waishnav", "devspace");
  write(path.join(officialRoot, "package.json"), { name: "@waishnav/devspace", version: "1.0.4" });
  write(path.join(officialRoot, "dist", "cli.js"), "// official CLI");
  const mixedConfig = { ...config, cliPath: path.join(officialRoot, "dist", "cli.js"), managementPackageRoot: managerRoot };
  write(configPath, mixedConfig);
  i = await collect({ checkLatest: true });
  assert.equal(component(i, "devspace-official").path, officialRoot);
  assert.equal(component(i, "devspace-official").installState, "installed");
  assert.equal(component(i, "devspace-tray-fork").activationKind, "management");
  assert.equal(component(i, "devspace-tray-fork").path, managerRoot);
  assert.equal(action(i, "devspace-tray-fork", "update").enabled, true);
  const managerPlan = planComponentAction(request(i, "devspace-tray-fork", "update"), i);
  assert.equal(managerPlan.activationKind, "management");
  assert.equal(managerPlan.sourcePath, managerRoot);
  write(path.join(managerRoot, "untracked.txt"), "preserve user work");
  i = await collect(); assert.equal(action(i, "devspace-tray-fork", "update").enabled, false);
  fs.unlinkSync(path.join(managerRoot, "untracked.txt"));
  write(configPath, { ...mixedConfig, managementPackageRoot: path.join(temp, "missing-manager") });
  i = await collect(); assert.equal(component(i, "devspace-tray-fork").installState, "partial");
  assert.equal(action(i, "devspace-tray-fork", "update").enabled, false);
  write(configPath, config);
  i = await collect({ checkLatest: true });

  const plan = planComponentAction({ ...request(i, "devspace-tray-fork", "update"), target: { repository: "attacker/repo" } }, i);
  assert.equal(plan.target.repository, "davidxyuan/devspace", "request cannot supply an update source");
  assert.equal(plan.target.commit, nextHead);
  assert.throws(() => planComponentAction({ ...request(i, "devspace-tray-fork", "update"), expectedRevision: "stale" }, i), /重新整理/);

  write(path.join(forkRoot, "untracked.txt"), "user work");
  let activated = false;
  await assert.rejects(executeComponentAction(plan, { inventoryOptions: base, activate: async () => { activated = true; } }), /已改變/);
  assert.equal(activated, false);
  i = await collect({ checkLatest: true });
  assert.equal(component(i, "devspace-tray-fork").source.dirty, true);
  assert.equal(component(i, "devspace-tray-fork").latest.comparison, "unknown", "matching HEAD never claims a dirty checkout is pristine");
  assert.equal(action(i, "devspace-tray-fork", "update").enabled, false, "untracked work blocks updates");
  assert.match(action(i, "devspace-tray-fork", "update").reason, /未追蹤/);
  fs.unlinkSync(path.join(forkRoot, "untracked.txt"));
  write(path.join(forkRoot, "dist", "cli.js"), "console.log('user change');");
  i = await collect(); assert.equal(component(i, "devspace-tray-fork").source.dirty, true);
  // Restore only this test-created fixture, never a user's checkout.
  write(path.join(forkRoot, "dist", "cli.js"), "console.log('fixture');");

  clock += 16 * 60 * 1000; remoteMode = "offline";
  i = await collect({ checkLatest: true });
  assert.equal(component(i, "devspace-tray-fork").latest.state, "offline");
  assert.equal(component(i, "devspace-tray-fork").latest.version, "1.0.5");
  assert.equal(action(i, "devspace-tray-fork", "update").enabled, false);
  assert.doesNotMatch(JSON.stringify(i), /sensitive-token/);
  remoteMode = "rate";
  i = await collect({ checkLatest: true }); assert.equal(component(i, "devspace-tray-fork").latest.state, "rate_limited");
  remoteMode = "ok"; compareStatus = "diverged";
  i = await collect({ checkLatest: true }); assert.equal(action(i, "devspace-tray-fork", "update").enabled, false, "divergence blocks update");
  clock += 16 * 60 * 1000; compareStatus = "behind";
  i = await collect({ checkLatest: true }); assert.equal(action(i, "devspace-tray-fork", "update").enabled, false, "ahead local checkout is not downgraded");

  const agentRoot = path.join(env.LOCALAPPDATA, "hermes", "hermes-agent");
  makeRepo(agentRoot, "davidxyuan/hermes-agent", "old-fork", { "pyproject.toml": '[project]\nname="hermes-agent"\nversion="0.20.0"', "package.json": { version: "1.0.0" }, "hermes_cli/main.py": "# fixture" });
  i = await collect({ checkLatest: true });
  assert.equal(component(i, "hermes-agent").installedVersion, "0.20.0", "Python product version precedes frontend package version");
  assert.equal(component(i, "hermes-agent").latest.version, "0.21.0");
  assert.equal(action(i, "hermes-agent", "update").enabled, false);
  assert.match(action(i, "hermes-agent", "update").reason, /來源未登錄/);
  git(agentRoot, ["remote", "set-url", "origin", "https://github.com/NousResearch/hermes-agent.git"]);
  git(agentRoot, ["checkout", "-B", "main"]);
  const agentHead = git(agentRoot, ["rev-parse", "HEAD"]);
  git(agentRoot, ["update-ref", "refs/remotes/origin/main", agentHead]);
  git(agentRoot, ["branch", "--set-upstream-to", "origin/main"]);
  compareStatus = "ahead";
  clock += 16 * 60 * 1000;
  i = await collect({ checkLatest: true });
  assert.equal(action(i, "hermes-agent", "update").enabled, true);
  const agentPlan = planComponentAction(request(i, "hermes-agent", "update"), i);
  let agentStageRoot, failAgentSmoke = false, agentSmokeMode = "version";
  const agentRun = async (command, args, options = {}) => {
    if (args[0] === "clone") {
      agentStageRoot = args.at(-1);
      write(path.join(agentStageRoot, "pyproject.toml"), '[project]\nname="hermes-agent"\nversion="0.21.0"\n[project.optional-dependencies]\ndev=["pytest"]');
      write(path.join(agentStageRoot, "hermes_cli", "main.py"), "# fixture");
      write(path.join(agentStageRoot, "tests", "test_smoke.py"), "def test_smoke(): pass");
    }
    if (args[0] === "-C" && args[2] === "rev-parse") return { stdout: nextHead };
    if (args[0] === "-m" && args[1] === "venv") {
      write(path.join(args[2], "Scripts", "python.exe"), "isolated python");
      write(path.join(args[2], "Scripts", "hermes.exe"), "agent executable");
    }
    if (args[0] === "-c" && args[1].includes("tomllib")) return { stdout: JSON.stringify({ extras: ["dev"], tests: true }) };
    if (path.basename(command).toLowerCase() === "hermes.exe" && ["--version", "--help"].includes(args[0])) {
      if (failAgentSmoke) throw Error("candidate Hermes Agent smoke failed");
      if (agentSmokeMode === "help") return { stdout: args[0] === "--version" ? "hermes-agent" : "Usage: hermes-agent [OPTIONS]" };
      if (agentSmokeMode === "invalid") return { stdout: "ready" };
      return { stdout: "hermes-agent 0.21.0" };
    }
    return { stdout: "" };
  };
  await executeComponentAction(agentPlan, { inventoryOptions: base, run: agentRun, activate: async candidate => {
    assert.equal(candidate.kind, "hermes-agent");
    assert.equal(candidate.agentSmoke, "version");
    assert.equal(candidate.hermesAgentExe, path.join(path.dirname(agentStageRoot), "venv", "Scripts", "hermes.exe"));
  } });
  agentSmokeMode = "help";
  await executeComponentAction(agentPlan, { inventoryOptions: base, run: agentRun, activate: async candidate => {
    assert.equal(candidate.agentSmoke, "help");
  } });
  agentSmokeMode = "invalid";
  failAgentSmoke = true;
  await assert.rejects(executeComponentAction(agentPlan, { inventoryOptions: base, run: agentRun, activate: async () => assert.fail("failed Hermes Agent smoke must not activate") }), /Hermes Agent.*smoke/);

  // Credentials embedded in an unrecognized Git remote are neither trusted nor returned.
  git(forkRoot, ["remote", "set-url", "origin", "https://user:SECRET-GIT@github.com/davidxyuan/devspace.git"]);
  i = await collect(); assert.doesNotMatch(JSON.stringify(i), /SECRET-GIT/);
  assert.equal(action(i, "devspace-tray-fork", "update").enabled, false);
  git(forkRoot, ["remote", "set-url", "origin", "https://github.com/davidxyuan/devspace.git"]);

  i = await collect();
  const trayPlan = planComponentAction(request(i, "tray", "install"), i);
  const result = await executeComponentAction(trayPlan, { inventoryOptions: base, activate: async (candidate) => { assert.equal(candidate.kind, "bundled"); return { verified: true }; } });
  assert.equal(result.activation.verified, true);
  const toolPlan = planComponentAction(request(i, "ngrok", "install"), i);
  await executeComponentAction(toolPlan, { inventoryOptions: base, activate: async (candidate) => { assert.equal(candidate.kind, "bundled"); assert.equal(candidate.componentId, "ngrok"); } });
  assert.deepEqual(fs.readFileSync(configPath), beforeConfig);
  assert.deepEqual(fs.readFileSync(path.join(installDir, "auth.json")), beforeAuth);

  // Exercise the real executor without downloading packages or changing any active repository.
  clock += 16 * 60 * 1000; compareStatus = "ahead";
  i = await collect({ checkLatest: true });
  const stagePlan = planComponentAction(request(i, "devspace-tray-fork", "update"), i);
  const commands = [];
  let stageRoot, mutateDuringStage = false, failCandidateTest = false;
  const stageRun = async (command, args, options = {}) => {
    commands.push({ command, args, cwd: options.cwd });
    if (args[0] === "clone") {
      assert.equal(args.at(-2), "https://github.com/davidxyuan/devspace.git");
      stageRoot = args.at(-1);
      assert.ok(stageRoot.startsWith(path.join(installDir, "managed") + path.sep));
      write(path.join(stageRoot, "package.json"), { name: "@waishnav/devspace", version: "1.0.5", scripts: { test: "node test.js", "test:windows-watchdog": "node watchdog-test.js" } });
      for (const [name, contents] of Object.entries(managementFiles)) write(path.join(stageRoot, name), contents);
      write(path.join(stageRoot, "dist", "cli.js"), "console.log('new candidate');");
      write(path.join(stageRoot, "scripts", "windows", "devspace-watchdog-tray-ui.ps1"), "# candidate tray");
      write(path.join(stageRoot, "scripts", "windows", "install-devspace-watchdog.ps1"), "# candidate installer");
      write(path.join(stageRoot, "scripts", "windows", "install-devspace-watchdog-tray.ps1"), "# candidate tray installer");
    }
    if (args[0] === "-C") { assert.equal(args[1], stageRoot); if (args[2] === "rev-parse") return { stdout: nextHead }; }
    if (args.includes("build") && mutateDuringStage) write(path.join(forkRoot, "new-user-work.txt"), "retain me");
    if (args.includes("test:windows-watchdog") && failCandidateTest) throw Error("candidate watchdog test failed");
    return { stdout: "" };
  };
  const staged = await executeComponentAction(stagePlan, { inventoryOptions: base, run: stageRun, activate: async (candidate) => {
    assert.equal(candidate.kind, "devspace"); assert.equal(candidate.commit, nextHead); assert.equal(candidate.root, stageRoot);
    assert.ok(fs.existsSync(path.join(path.dirname(stageRoot), "candidate.json")));
    return { verified: true };
  } });
  assert.equal(staged.activation.verified, true);
  assert.equal(git(forkRoot, ["rev-parse", "HEAD"]), forkHead);
  assert.equal(git(forkRoot, ["status", "--porcelain"]), "");
  assert.ok(commands.some((c) => c.args.includes("--detach")), "checkout is only used in the new candidate directory");
  assert.ok(commands.some((c) => c.args.at(-1) === "test" && c.cwd === stageRoot));
  assert.ok(commands.some((c) => c.args.at(-1) === "test:windows-watchdog" && c.cwd === stageRoot));
  assert.ok(commands.every((c) => !c.args.includes("pull") && !c.args.includes("reset") && !c.args.includes("stash") && !c.args.includes("--global")));
  failCandidateTest = true;
  await assert.rejects(executeComponentAction(stagePlan, { inventoryOptions: base, run: stageRun, activate: async () => assert.fail("failed candidate must not activate") }), /candidate watchdog test failed/);
  failCandidateTest = false;
  assert.deepEqual(fs.readFileSync(configPath), beforeConfig);
  mutateDuringStage = true;
  await assert.rejects(executeComponentAction(stagePlan, { inventoryOptions: base, run: stageRun, activate: async () => assert.fail("changed source must not activate") }), /準備候選版本時已改變/);
  assert.equal(fs.readFileSync(path.join(forkRoot, "new-user-work.txt"), "utf8"), "retain me");
  fs.unlinkSync(path.join(forkRoot, "new-user-work.txt"));
  mutateDuringStage = false;
  write(configPath, mixedConfig);
  i = await collect({ checkLatest: true });
  const refreshedManagerPlan = planComponentAction(request(i, "devspace-tray-fork", "update"), i);
  assert.equal(refreshedManagerPlan.activationKind, "management");
  await executeComponentAction(refreshedManagerPlan, { inventoryOptions: base, run: stageRun, activate: async candidate => {
    assert.equal(candidate.kind, "management");
    assert.equal(JSON.parse(fs.readFileSync(configPath)).cliPath, mixedConfig.cliPath);
  } });
  write(configPath, config);
  const badPlan = { ...stagePlan, target: { ...stagePlan.target, repository: "attacker/repo" } };
  await assert.rejects(executeComponentAction(badPlan, { inventoryOptions: base, run: stageRun, activate: async () => assert.fail() }), /不允許/);

  // A first official install uses an isolated prefix and verifies npm's locked integrity.
  write(configPath, { ...config, cliPath: "" });
  clock += 16 * 60 * 1000;
  i = await collect({ checkLatest: true });
  const npmPlan = planComponentAction(request(i, "devspace-official", "install"), i);
  let badIntegrity = false;
  const npmRun = async (command, args) => {
    if (args.includes("--prefix")) {
      const prefix = args[args.indexOf("--prefix") + 1];
      assert.ok(prefix.startsWith(path.join(installDir, "managed", "devspace-official") + path.sep));
      assert.ok(args.includes("@waishnav/devspace@1.0.5"));
      write(path.join(prefix, "node_modules", "@waishnav", "devspace", "package.json"), { name: "@waishnav/devspace", version: "1.0.5" });
      write(path.join(prefix, "node_modules", "@waishnav", "devspace", "dist", "cli.js"), "// candidate");
      write(path.join(prefix, "package-lock.json"), { packages: { "node_modules/@waishnav/devspace": { version: "1.0.5", integrity: badIntegrity ? "sha512-bad" : "sha512-YWJjZA==" } } });
    }
    return { stdout: "" };
  };
  await executeComponentAction(npmPlan, { inventoryOptions: base, run: npmRun, activate: async (candidate) => assert.equal(candidate.version, "1.0.5") });
  badIntegrity = true;
  await assert.rejects(executeComponentAction(npmPlan, { inventoryOptions: base, run: npmRun, activate: async () => assert.fail() }), /套件與已核對版本不符/);
  write(configPath, config);
  assert.deepEqual(fs.readFileSync(path.join(installDir, "auth.json")), beforeAuth);

  i = await collect({ checkLatest: true });
  const hermesPlan = planComponentAction(request(i, "hermes-gpt", "install"), i);
  let pythonRoot, failPythonTests = false, missingPythonTests = false;
  const pythonCommands = [];
  const pythonRun = async (command, args) => {
    pythonCommands.push({ command, args });
    if (args[0] === "clone") {
      pythonRoot = args.at(-1);
      assert.equal(args.at(-2), "https://github.com/asimons81/hermes-gpt.git");
      write(path.join(pythonRoot, "pyproject.toml"), '[project]\nname="hermes-gpt"\nversion="0.5.1"');
      write(path.join(pythonRoot, "server.py"), "# fixture server");
      write(path.join(pythonRoot, "requirements.txt"), "mcp\nuvicorn\n");
      write(path.join(pythonRoot, "requirements-dev.txt"), "pytest\n");
    }
    if (args[0] === "-C") { assert.equal(args[1], pythonRoot); if (args[2] === "rev-parse") return { stdout: nextHead }; }
    if (args[0] === "-m" && args[1] === "venv") write(path.join(args[2], "Scripts", "python.exe"), "isolated python");
    if (args[0] === "-c" && args[1].includes("tomllib")) return { stdout: JSON.stringify({ extras: ["dev"], tests: !missingPythonTests }) };
    if (args[1] === "pytest" && failPythonTests) throw Error("candidate Python tests failed");
    return { stdout: "" };
  };
  await executeComponentAction(hermesPlan, { inventoryOptions: base, run: pythonRun, activate: async (candidate) => {
    assert.equal(candidate.kind, "hermes-gpt"); assert.equal(candidate.root, pythonRoot);
    assert.equal(candidate.hermesServer, path.join(pythonRoot, "server.py"));
    assert.equal(candidate.pythonPath, path.join(path.dirname(pythonRoot), "venv", "Scripts", "python.exe"));
    assert.equal(candidate.runtimeRoot, path.dirname(pythonRoot));
    assert.equal(candidate.action, "install");
  } });
  assert.ok(pythonCommands.some((c) => c.args[0] === "-m" && c.args[1] === "venv"));
  assert.ok(pythonCommands.some((c) => c.args[0] === "-m" && c.args[1] === "pip" && c.args.at(-1) === `${pythonRoot}[dev]`));
  assert.ok(pythonCommands.some((c) => c.args[1] === "pytest"));
  failPythonTests = true;
  await assert.rejects(executeComponentAction(hermesPlan, { inventoryOptions: base, run: pythonRun, activate: async () => assert.fail("failed Python suite must not activate") }), /candidate Python tests failed/);
  failPythonTests = false; missingPythonTests = true;
  await assert.rejects(executeComponentAction(hermesPlan, { inventoryOptions: base, run: pythonRun, activate: async () => assert.fail("untested Python candidate must not activate") }), /沒有可驗證的測試套件/);
  assert.ok(pythonCommands.every((c) => !c.args.includes("update") && !c.args.includes("--user")));
  assert.deepEqual(fs.readFileSync(configPath), beforeConfig);

  const archiveRoot = path.join(temp, "archive", "node_modules", "@waishnav", "devspace");
  write(path.join(archiveRoot, "package.json"), { name: "@waishnav/devspace", version: "1.0.4" });
  write(path.join(archiveRoot, "dist", "cli.js"), "// workspace payload");
  for (const [name, contents] of Object.entries(managementFiles)) write(path.join(archiveRoot, name), contents);
  const digest = value => crypto.createHash("sha256").update(value).digest("hex");
  const files = ["dist/cli.js", "package.json", ...Object.keys(managementFiles)].map(name => ({ path: name, sha256: digest(fs.readFileSync(path.join(archiveRoot, name))) }));
  write(path.join(archiveRoot, "oneclick-payload.json"), { schemaVersion: 1, source: "workspace", dirty: true, head: forkHead, fingerprint: digest(files.map(f => `${f.path}:${f.sha256}`).join("\n")), files });
  write(configPath, { ...config, cliPath: path.join(archiveRoot, "dist", "cli.js") });
  i = await collect();
  assert.equal(component(i, "devspace-tray-fork").installState, "installed");
  assert.equal(component(i, "devspace-tray-fork").source.provenance, "workspace");
  assert.equal(component(i, "devspace-tray-fork").source.verified, true);
  assert.equal(component(i, "devspace-tray-fork").source.dirty, true);
  assert.equal(component(i, "devspace-official").installState, "missing", "workspace payload takes precedence over an npm-shaped directory name");
  write(path.join(archiveRoot, "dist", "cli.js"), "// changed since packaging");
  i = await collect(); assert.equal(component(i, "devspace-tray-fork").source.verified, false);
  assert.equal(action(i, "devspace-tray-fork", "update").enabled, false);
  write(configPath, config);

  const cleanBundleRoot = path.join(temp, "clean-bundle");
  write(path.join(cleanBundleRoot, "package.json"), { name: "@waishnav/devspace", version: "1.0.5" });
  write(path.join(cleanBundleRoot, "dist", "cli.js"), "// clean verified bundle");
  for (const [name, contents] of Object.entries(managementFiles)) write(path.join(cleanBundleRoot, name), contents);
  const cleanBundleFiles = ["dist/cli.js", "package.json", ...Object.keys(managementFiles)].map(name => ({ path: name, sha256: digest(fs.readFileSync(path.join(cleanBundleRoot, name))) }));
  const cleanBundleFingerprint = digest(cleanBundleFiles.map(f => `${f.path}:${f.sha256}`).join("\n"));
  const cleanProvenance = ["workspace", forkHead, "davidxyuan/devspace", forkBranch, `origin/${forkBranch}`, "origin", "false", cleanBundleFingerprint].join("\n");
  write(path.join(cleanBundleRoot, "oneclick-payload.json"), { schemaVersion: 1, source: "workspace", dirty: false, head: forkHead, repository: "davidxyuan/devspace", branch: forkBranch, trackingRef: `origin/${forkBranch}`, remoteName: "origin", fingerprint: cleanBundleFingerprint, provenanceFingerprint: digest(cleanProvenance), files: cleanBundleFiles });
  write(configPath, { ...config, cliPath: path.join(cleanBundleRoot, "dist", "cli.js") });
  i = await collect({ checkLatest: true });
  assert.equal(component(i, "devspace-tray-fork").source.verified, true);
  assert.equal(component(i, "devspace-tray-fork").source.provenanceVerified, true);
  assert.equal(component(i, "devspace-tray-fork").source.dirty, false);
  assert.equal(action(i, "devspace-tray-fork", "update").enabled, true, "clean verified bundle may use its registered update channel");
  const cleanPayloadPath = path.join(cleanBundleRoot, "oneclick-payload.json");
  const cleanPayload = JSON.parse(fs.readFileSync(cleanPayloadPath, "utf8"));
  for (const [label, change] of [
    ["missing repository", { repository: undefined }],
    ["wrong repository", { repository: "attacker/repo" }],
    ["wrong source", { source: "archive" }],
    ["branch mismatch", { branch: "main" }],
    ["tracking mismatch", { trackingRef: "origin/main" }],
    ["malformed HEAD", { head: "not-a-sha" }],
  ]) {
    const invalid = { ...cleanPayload, ...change };
    if (change.repository === undefined) delete invalid.repository;
    write(cleanPayloadPath, invalid);
    const invalidInventory = await collect();
    assert.equal(action(invalidInventory, "devspace-tray-fork", "update").enabled, false, `${label} must disable bundled Fork updates`);
    assert.equal(component(invalidInventory, "devspace-tray-fork").source.provenanceVerified, false, `${label} must fail provenance verification`);
  }
  write(cleanPayloadPath, cleanPayload);
  write(configPath, config);

  write(configPath, "{broken");
  i = await collect(); assert.ok(i.blockers.length); assert.ok(i.components.every((c) => c.actions.every((a) => !a.enabled)));
  write(configPath, config);
  const fresh = await collect({ installDir: path.join(temp, "fresh") });
  assert.equal(action(fresh, "hermes-gpt", "install").enabled, false);
  assert.match(action(fresh, "hermes-gpt", "install").reason, /精靈/);
  assert.equal(fs.existsSync(path.join(temp, "fresh")), false, "inventory does not write to installation");
  console.log("stack-management: discovery, pinned plans, source isolation, stale/dirty/offline safety and activation checks passed");
})().finally(() => {
  const resolved = path.resolve(temp);
  assert.ok(resolved.startsWith(path.resolve(os.tmpdir()) + path.sep) && path.basename(resolved).startsWith("devspace-management-test-"));
  fs.rmSync(resolved, { recursive: true, force: true });
}).catch((error) => { console.error(error); process.exitCode = 1; });
