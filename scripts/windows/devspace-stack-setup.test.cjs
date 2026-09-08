"use strict";

const assert = require("node:assert/strict");
const http = require("node:http");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");

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
  const repoRoot = path.resolve(__dirname, "..", "..");
  const packageJson = JSON.parse(fs.readFileSync(path.join(repoRoot, "package.json"), "utf8"));
  assert.equal(packageJson.bin?.["devspace-stack"], "scripts/windows/devspace-stack-setup.cjs");

  const cliHelp = spawnSync(process.execPath, [path.join(repoRoot, "dist", "cli.js"), "help"], { encoding: "utf8" });
  assert.equal(cliHelp.status, 0, cliHelp.stderr || "devspace help failed");
  assert.match(cliHelp.stdout, /devspace stack\s+Open the Windows Stack Setup \/ Update Dashboard/);

  const script = path.join(__dirname, "devspace-stack-setup.cjs");
  const setupSource = fs.readFileSync(script, "utf8");
  assert.doesNotMatch(setupSource, /devspace-watchdog-tray-launcher\.exe/);
  for (const requiredTrayFile of [
    "devspace-watchdog-bootstrap.ps1",
    "devspace-watchdog-tray.ps1",
    "devspace-watchdog-tray-ui.ps1",
    "run-devspace-watchdog-tray-hidden.vbs",
  ]) assert.match(setupSource, new RegExp(requiredTrayFile.replaceAll(".", "\\.")));
  assert.doesNotMatch(setupSource, /-ExecutionPolicy["', ]+Bypass/);

  const isolated = fs.mkdtempSync(path.join(os.tmpdir(), "devspace-setup-http-"));
  const watchdogConfig = path.join(isolated, "devspace-watchdog.config.json");
  fs.writeFileSync(watchdogConfig, JSON.stringify({ managementPackageRoot: path.join(isolated, "previous-package") }));
  fs.writeFileSync(path.join(isolated, "config.json"), "{}");
  const child = spawn(process.execPath, [script, "--no-open", "--install-dir", isolated], { stdio: ["ignore", "pipe", "pipe"] });
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
    assert.match(htmlResponse.body, /User Mode/);
    assert.match(htmlResponse.body, /Tray-only/);

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

    const token = htmlResponse.body.match(/const setupToken="([^"]+)"/)[1];
    const mutationOptions = { method: "POST", headers: { "content-type": "application/json", origin: baseUrl.replace(/\/$/, ""), "x-devspace-setup-token": token } };
    const currentInstaller = await request(`${baseUrl}api/components/action`, mutationOptions, "{}");
    assert.equal(currentInstaller.status, 400);
    assert.doesNotMatch(currentInstaller.body, /management package changed/, "A newly opened installer may replace the previous management package");
    fs.writeFileSync(watchdogConfig, JSON.stringify({ managementPackageRoot: path.join(isolated, "newer-package") }));
    const staleInstaller = await request(`${baseUrl}api/components/action`, mutationOptions, "{}");
    assert.equal(staleInstaller.status, 400);
    assert.match(staleInstaller.body, /management package changed/, "An older tab cannot change an installation updated after the tab opened");

    console.log("PASS: Stack Setup exposes npm/CLI entry points, supports User Mode/Tray-only, is loopback-readable, and rejects unauthorized mutations.");
  } finally {
    child.kill();
    await new Promise(resolve => child.once("exit", resolve));
    fs.rmSync(isolated, {recursive:true,force:true});
  }
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exitCode = 1;
});
