"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const net = require("node:net");
const { spawn } = require("node:child_process");
const { once } = require("node:events");
const { randomBytes } = require("node:crypto");
const { devspaceEntrypoint } = require("./stack-node-build.cjs");

async function smoke(packageRoot) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "devspace-release-smoke-"));
  const probe = net.createServer();
  let child, output = "";
  try {
    await new Promise((resolve, reject) => { probe.once("error", reject); probe.listen(0, "127.0.0.1", resolve); });
    const port = probe.address().port;
    await new Promise(resolve => probe.close(resolve));
    const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^(DEVSPACE_|PORT$|HOST$)/i.test(key)));
    const configDir = path.join(temp, "config"), stateDir = path.join(temp, "state");
    fs.mkdirSync(configDir);
    fs.writeFileSync(path.join(configDir, "config.json"), JSON.stringify({ allowedRoots: [temp], stateDir }));
    const base = `http://127.0.0.1:${port}`;
    Object.assign(env, {
      HOST: "127.0.0.1", PORT: String(port), DEVSPACE_CONFIG_DIR: configDir,
      DEVSPACE_STATE_DIR: stateDir, DEVSPACE_WORKTREE_ROOT: path.join(temp, "worktrees"),
      DEVSPACE_AGENT_DIR: path.join(temp, "agents"), DEVSPACE_PUBLIC_BASE_URL: base,
      DEVSPACE_OAUTH_OWNER_TOKEN: randomBytes(32).toString("hex"), DEVSPACE_SUBAGENTS: "0", DEVSPACE_SKILLS: "0",
    });
    const pkg = JSON.parse(fs.readFileSync(path.join(packageRoot, "package.json"), "utf8"));
    const cli = devspaceEntrypoint(packageRoot);
    child = spawn(process.execPath, [cli, "serve"], { cwd: temp, env, windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
    child.stdout.on("data", data => { output = (output + data).slice(-16000); });
    child.stderr.on("data", data => { output = (output + data).slice(-16000); });
    let spawnError;
    child.on("error", error => { spawnError = error; });
    const deadline = Date.now() + 30000;
    let healthy = false;
    while (Date.now() < deadline) {
      if (spawnError) throw spawnError;
      if (child.exitCode !== null) throw new Error(`Candidate exited before readiness: ${output}`);
      try {
        const response = await fetch(base + "/healthz", { signal: AbortSignal.timeout(1000) });
        if (response.ok) { healthy = true; break; }
      } catch { /* poll only the disposable candidate's reserved port */ }
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.ok(healthy, `Candidate failed readiness: ${output}`);
    const metadata = await fetch(base + "/.well-known/oauth-authorization-server", { signal: AbortSignal.timeout(5000) });
    assert.equal(metadata.status, 200);
    const document = await metadata.json();
    assert.equal(new URL(document.token_endpoint).origin, base);
    const protectedRequest = await fetch(base + "/mcp", { method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "release-smoke", version: "1" } } }), signal: AbortSignal.timeout(5000) });
    assert.equal(protectedRequest.status, 401, "MCP must require authentication");
    assert.ok(fs.existsSync(path.join(stateDir, "devspace.sqlite")), "candidate must initialize its isolated database");
    return { success: true, version: pkg.version, checks: ["real-cli-start", "healthz", "oauth-discovery", "mcp-auth-required", "isolated-database"], scope: "local candidate startup; not ChatGPT streaming or a soak" };
  } finally {
    if (probe.listening) await new Promise(resolve => probe.close(resolve));
    if (child && child.exitCode === null && child.pid) {
      const exited = once(child, "exit");
      child.kill(); // Only the test-owned process object, never a discovered PID.
      await exited;
    }
    fs.rmSync(temp, { recursive: true, force: true });
  }
}
if (require.main === module) smoke(path.resolve(process.argv[2] || path.join(__dirname, "../.."))).then(result => console.log(JSON.stringify(result)))
  .catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { smoke };
