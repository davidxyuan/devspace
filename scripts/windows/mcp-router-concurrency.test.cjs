const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

function listen(server, port = 0) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", () => {
      server.removeListener("error", reject);
      resolve(server.address().port);
    });
  });
}

function getFreePort() {
  const server = net.createServer();
  return listen(server).then((port) => new Promise((resolve) => server.close(() => resolve(port))));
}

function waitForRouter(port, deadlineMs = 5000) {
  const deadline = Date.now() + deadlineMs;
  return new Promise((resolve, reject) => {
    const attempt = () => {
      const req = http.get({ host: "127.0.0.1", port, path: "/__router/status" }, (res) => {
        res.resume();
        if (res.statusCode === 200) return resolve();
        if (Date.now() >= deadline) return reject(new Error(`router returned ${res.statusCode}`));
        setTimeout(attempt, 50);
      });
      req.on("error", () => {
        if (Date.now() >= deadline) return reject(new Error("router did not become ready"));
        setTimeout(attempt, 50);
      });
    };
    attempt();
  });
}

function readRouterStatus(port) {
  return new Promise((resolve, reject) => {
    const req = http.get({ host: "127.0.0.1", port, path: "/__router/status" }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { body += chunk; });
      res.on("end", () => {
        try { resolve(JSON.parse(body)); }
        catch (error) { reject(error); }
      });
    });
    req.once("error", reject);
  });
}

function postTool(port, id, toolName, toolArgs = {}) {
  const payload = JSON.stringify({
    jsonrpc: "2.0",
    id,
    method: "tools/call",
    params: { name: toolName, arguments: toolArgs },
  });
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: "127.0.0.1",
      port,
      method: "POST",
      path: "/parallel-test/devspace_chatgpt/mcp",
      headers: {
        "content-type": "application/json",
        "content-length": Buffer.byteLength(payload),
      },
    }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { body += chunk; });
      res.on("end", () => resolve({ status: res.statusCode, body }));
    });
    req.once("error", reject);
    req.end(payload);
  });
}

async function main() {
  const arrivals = [];
  let allArrivedResolve;
  const allArrived = new Promise((resolve) => { allArrivedResolve = resolve; });
  let releaseResolve;
  const release = new Promise((resolve) => { releaseResolve = resolve; });

  const backend = http.createServer((req, res) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", async () => {
      const payload = JSON.parse(body || "{}");
      arrivals.push({ id: payload.id, toolName: payload.params?.name || "" });
      if (arrivals.length === 3) allArrivedResolve();
      await release;
      const delay = payload.id === "read" ? 150 : payload.id === "write" ? 250 : 350;
      setTimeout(() => {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ jsonrpc: "2.0", id: payload.id, result: { ok: true } }));
      }, delay);
    });
  });

  const backendPort = await listen(backend);
  const routerPort = await getFreePort();
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "devspace-router-concurrency-"));
  const configPath = path.join(tempDir, "config.json");
  fs.writeFileSync(configPath, JSON.stringify({
    machineSlug: "parallel-test",
    devspaceEnabled: true,
    hermesEnabled: false,
    port: backendPort,
    routerPort,
    publicBaseUrl: "https://example.invalid/parallel-test/devspace_chatgpt",
    routerConnectionWarnCount: 10,
    routerConnectionCriticalCount: 20,
    mcpRoutes: [{
      name: "devspace_chatgpt_parallel_test",
      service: "devspace",
      prefix: "/parallel-test/devspace_chatgpt",
      targetHost: "127.0.0.1",
      targetPort: backendPort,
    }],
  }));

  const routerPath = path.join(__dirname, "mcp-router.cjs");
  const child = spawn(process.execPath, [routerPath, configPath], { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (chunk) => { stderr += chunk; });

  try {
    await waitForRouter(routerPort);
    const baseline = await readRouterStatus(routerPort);
    const startedAt = Date.now();
    const pending = [
      postTool(routerPort, "read", "read", { path: "alpha/read-only.txt" }),
      postTool(routerPort, "write", "write", { path: "beta/output.txt", content: "isolated" }),
      postTool(routerPort, "test", "workspace_run_test", { command: "npm test", timeout: 120 }),
    ];

    await Promise.race([
      allArrived,
      new Promise((_, reject) => setTimeout(() => reject(new Error("three concurrent requests did not reach the backend within 2 seconds")), 2000)),
    ]);

    const live = await readRouterStatus(routerPort);
    assert.equal(arrivals.length, 3, "backend did not receive all three requests concurrently");
    assert.equal(live.connections.services.devspace.activeRequests, 3, "router did not expose three simultaneous DevSpace requests");
    assert.equal(live.connections.services.devspace.longRunningRequests, 1, "long-running test request was not classified independently");
    assert.equal(live.connections.services.devspace.suspectRequests, 0, "healthy concurrent requests were marked suspect");
    assert.equal(live.connections.level, "GREEN", "three healthy concurrent requests should remain green");
    assert.equal(live.connections.cleanup.requestsStarted - baseline.connections.cleanup.requestsStarted, 3, "router did not count all three requests");

    releaseResolve();
    const results = await Promise.race([
      Promise.all(pending),
      new Promise((_, reject) => setTimeout(() => reject(new Error("parallel requests did not all complete within 2 seconds")), 2000)),
    ]);
    const elapsedMs = Date.now() - startedAt;
    assert.deepEqual(results.map((result) => result.status), [200, 200, 200]);
    assert.ok(elapsedMs < 1600, `requests appear serialized; elapsed=${elapsedMs}ms`);

    const finished = await readRouterStatus(routerPort);
    assert.equal(finished.connections.services.devspace.activeRequests, 0, "completed parallel requests remained active");
    assert.equal(finished.connections.cleanup.requestsCompleted - baseline.connections.cleanup.requestsCompleted, 3, "not all parallel requests completed");
    assert.equal(finished.connections.cleanup.requestsAborted - baseline.connections.cleanup.requestsAborted, 0, "parallel requests were aborted");
    assert.deepEqual(new Set(arrivals.map((item) => item.toolName)), new Set(["read", "write", "workspace_run_test"]));
    assert.equal(child.exitCode, null, `router exited unexpectedly: ${stderr}`);
    console.log(`PASS: MCP router forwarded 3 tool calls concurrently (${elapsedMs} ms), tracked them independently, and completed all without aborts.`);
  } finally {
    releaseResolve?.();
    child.kill();
    await new Promise((resolve) => backend.close(resolve));
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exitCode = 1;
});
