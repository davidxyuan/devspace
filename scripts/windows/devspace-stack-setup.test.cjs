"use strict";

const assert = require("node:assert/strict");
const http = require("node:http");
const path = require("node:path");
const { spawn } = require("node:child_process");

function request(url, options = {}, body = "") {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const req = http.request({
      host: target.hostname,
      port: target.port,
      path: target.pathname + target.search,
      method: options.method || "GET",
      headers: options.headers || {},
    }, (res) => {
      let text = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { text += chunk; });
      res.on("end", () => resolve({ status: res.statusCode, body: text, headers: res.headers }));
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

async function main() {
  const script = path.join(__dirname, "devspace-stack-setup.cjs");
  const child = spawn(process.execPath, [script, "--no-open"], { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (chunk) => { stderr += chunk.toString("utf8"); });
  const baseUrl = await new Promise((resolve, reject) => {
    let stdout = "";
    const timer = setTimeout(() => reject(new Error(`setup server did not announce URL: ${stderr}`)), 6000);
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString("utf8");
      const match = stdout.match(/DevSpace Stack Setup:\s+(http:\/\/127\.0\.0\.1:\d+\/)/);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
    child.once("error", (error) => { clearTimeout(timer); reject(error); });
    child.once("exit", (code) => {
      if (code !== null && code !== 0) { clearTimeout(timer); reject(new Error(`setup server exited ${code}: ${stderr}`)); }
    });
  });

  try {
    const statusResponse = await request(`${baseUrl}api/status`);
    assert.equal(statusResponse.status, 200);
    const status = JSON.parse(statusResponse.body);
    assert.equal(status.ok, true);
    assert.ok(["Fresh", "Existing", "Partial"].includes(status.state));
    assert.equal(typeof status.packageVersion, "string");

    const htmlResponse = await request(baseUrl);
    assert.equal(htmlResponse.status, 200);
    assert.match(htmlResponse.body, /DevSpace Stack Setup/);
    assert.match(htmlResponse.body, /Install \/ Update/);

    const badOrigin = await request(`${baseUrl}api/apply`, {
      method: "POST",
      headers: { "content-type": "application/json", origin: "https://evil.invalid", host: new URL(baseUrl).host },
    }, "{}");
    assert.equal(badOrigin.status, 400);
    assert.match(badOrigin.body, /Invalid Origin header/);

    const badToken = await request(`${baseUrl}api/apply`, {
      method: "POST",
      headers: { "content-type": "application/json", origin: baseUrl.replace(/\/$/, ""), host: new URL(baseUrl).host, "x-devspace-setup-token": "wrong" },
    }, "{}");
    assert.equal(badToken.status, 400);
    assert.match(badToken.body, /Invalid setup token/);

    console.log("PASS: Stack Setup dashboard is loopback-readable and rejects unauthorized mutations.");
  } finally {
    child.kill();
  }
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exitCode = 1;
});
