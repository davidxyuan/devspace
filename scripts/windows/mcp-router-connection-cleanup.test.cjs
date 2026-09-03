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
    req.on("error", reject);
  });
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

async function main() {
  let backendRequestClosedResolve;
  const backendRequestClosed = new Promise((resolve) => { backendRequestClosedResolve = resolve; });
  const backend = http.createServer((req, res) => {
    req.once("close", backendRequestClosedResolve);
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(": connected\n\n");
  });
  const backendPort = await listen(backend);
  const routerPort = await getFreePort();
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "devspace-router-cleanup-"));
  const configPath = path.join(tempDir, "config.json");
  fs.writeFileSync(configPath, JSON.stringify({
    machineSlug: "cleanup-test",
    devspaceEnabled: true,
    hermesEnabled: false,
    port: backendPort,
    routerPort,
    publicBaseUrl: "https://example.invalid/cleanup-test/devspace_chatgpt",
    routerSuspectIdleSeconds: 1,
    mcpRoutes: [{
      name: "devspace_chatgpt_cleanup_test",
      service: "devspace",
      prefix: "/cleanup-test/devspace_chatgpt",
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
    await new Promise((resolve, reject) => {
      const req = http.get({
        host: "127.0.0.1",
        port: routerPort,
        path: "/cleanup-test/devspace_chatgpt/mcp",
      }, (res) => {
        res.once("data", async () => {
          try {
            await new Promise((done) => setTimeout(done, 1200));
            const live = await readRouterStatus(routerPort);
            assert.equal(live.connections.services.devspace.activeRequests, 1, "active DevSpace request was not counted");
            assert.equal(live.connections.services.devspace.streamingRequests, 1, "GET /mcp stream was not classified separately");
            assert.equal(live.connections.services.devspace.suspectRequests, 0, "idle GET /mcp stream was incorrectly marked suspect");
            assert.equal(live.connections.level, "GREEN", "single healthy MCP stream should not warn");
            res.destroy();
            resolve();
          } catch (error) { reject(error); }
        });
      });
      req.once("error", reject);
    });

    await Promise.race([
      backendRequestClosed,
      new Promise((_, reject) => setTimeout(() => reject(new Error("upstream request remained open after client disconnect")), 2000)),
    ]);
    const cleaned = await readRouterStatus(routerPort);
    assert.equal(cleaned.connections.services.devspace.activeRequests, 0, "closed DevSpace request remained active");
    assert.ok(cleaned.connections.cleanup.upstreamsDestroyed >= 1, "cleanup counter did not record destroyed upstream");

    await new Promise((resolve, reject) => {
      const req = http.request({
        host: "127.0.0.1",
        port: routerPort,
        path: "/cleanup-test/devspace_chatgpt/mcp",
        method: "POST",
        headers: { "content-type": "application/json" },
      }, (res) => {
        res.once("data", async () => {
          try {
            await new Promise((done) => setTimeout(done, 1200));
            const staleWork = await readRouterStatus(routerPort);
            assert.equal(staleWork.connections.services.devspace.activeRequests, 1, "POST work request was not counted");
            assert.equal(staleWork.connections.services.devspace.streamingRequests, 0, "POST work request was incorrectly classified as a stream");
            assert.equal(staleWork.connections.services.devspace.suspectRequests, 1, "idle POST work request was not marked suspect");
            assert.equal(staleWork.connections.level, "YELLOW", "stale POST work request should warn");
            res.destroy();
            resolve();
          } catch (error) { reject(error); }
        });
      });
      req.once("error", reject);
      req.end("{}");
    });
    await new Promise((done) => setTimeout(done, 100));
    const postCleaned = await readRouterStatus(routerPort);
    assert.equal(postCleaned.connections.services.devspace.activeRequests, 0, "closed POST work request remained active");
    assert.equal(cleaned.connections.thresholds.idleSocketConfirmations, 2, "idle socket cleanup must require repeated confirmation");
    assert.equal(child.exitCode, null, `router exited unexpectedly: ${stderr}`);
    console.log("PASS: MCP router distinguishes long-lived streams, warns on stale work, and closes upstreams on disconnect.");
  } finally {
    child.kill();
    await new Promise((resolve) => backend.close(resolve));
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exitCode = 1;
});
