"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { installerParameters, applySetup } = require("./stack-setup-apply.cjs");

(async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "devspace-stack-apply-"));
  const installDir = path.join(root, "install");
  const packageRoot = path.join(root, "package");
  const scriptDir = path.join(root, "scripts");
  fs.mkdirSync(path.join(packageRoot, "dist"), { recursive: true });
  fs.mkdirSync(scriptDir, { recursive: true });
  fs.writeFileSync(path.join(packageRoot, "dist", "cli.js"), "// fixture\n");
  fs.writeFileSync(path.join(packageRoot, "package-lock.json"), "{}\n");

  const fakeNgrokToken = "fixture-ngrok-token-do-not-log";
  const setup = {
    components: ["DevSpace"],
    existing: false,
    changes: [],
    machineName: "fixture",
    mcpNameSuffix: "fixture",
    publicDomain: "https://fixture.example.test",
    endpointMode: "AgentEndpoint",
    allowedRoots: "D:\\",
    hermesDir: path.join(root, "hermes"),
    installTray: false,
    installTools: false,
    npmInsecureTls: true,
    userMode: true,
    noLegacyPoller: false,
    fullAccess: false,
    ngrokAuthToken: fakeNgrokToken,
    devspaceOwnerToken: "",
  };

  const calls = [];
  let cliProbeCount = 0;
  const run = async (file, args, options = {}) => {
    calls.push({ file, args, options });
    if (file === process.execPath && args[0] === path.join(packageRoot, "dist", "cli.js") && args[1] === "help") {
      cliProbeCount += 1;
      if (cliProbeCount === 1) throw new Error("fixture missing dependencies");
    }
  };

  try {
    const ownerSetup = { ...setup, components: ["DevSpace", "Hermes"], fullAccess: true };
    const ownerParams = installerParameters(ownerSetup, { installDir, packageRoot });
    assert.equal(ownerParams.FullAccess, true);
    assert.match(ownerParams.CapabilitySelection, /DevSpaceToolMode=full/);
    assert.match(ownerParams.CapabilitySelection, /DevSpaceSkills=On/);
    assert.match(ownerParams.CapabilitySelection, /DevSpaceSubagents=On/);
    assert.match(ownerParams.CapabilitySelection, /DevSpaceMcpTransport=stateless-json/);
    assert.match(ownerParams.CapabilitySelection, /HermesOperator=On/);
    assert.match(ownerParams.CapabilitySelection, /HermesOperatorDirect=On/);
    assert.match(ownerParams.CapabilitySelection, /HermesOwnerMode=On/);
    assert.match(ownerParams.CapabilitySelection, /HermesWorkspaceWrite=On/);
    assert.match(ownerParams.CapabilitySelection, /HermesTerminal=On/);
    assert.match(ownerParams.CapabilitySelection, /HermesRunner=On/);
    assert.match(ownerParams.CapabilitySelection, /HermesFilesystemScope=full/);

    const readOnlyParams = installerParameters({ ...setup, components: ["DevSpace", "Hermes"], fullAccess: false }, { installDir, packageRoot });
    assert.equal(readOnlyParams.CapabilitySelection, undefined, "Hermes owner/direct capabilities must remain opt-in via Full Access");

    await applySetup(setup, { installDir, packageRoot, scriptDir, id: "fixture-job" }, run);
    const npmCall = calls.find(call => call.file === process.execPath && String(call.args[0]).endsWith(path.join("npm", "bin", "npm-cli.js")));
    assert.ok(npmCall, "npm dependency recovery call was not made");
    assert.equal(npmCall.options.env.NODE_USE_SYSTEM_CA, "1");
    assert.equal(npmCall.options.env.npm_config_strict_ssl, "false");
    assert.equal(npmCall.options.env.NODE_TLS_REJECT_UNAUTHORIZED, "0");

    const installerCall = calls.at(-1);
    assert.equal(installerCall.options.env.NODE_TLS_REJECT_UNAUTHORIZED, process.env.NODE_TLS_REJECT_UNAUTHORIZED, "emergency npm TLS bypass leaked into the PowerShell installer");
    assert.equal(installerCall.options.env.npm_config_strict_ssl, process.env.npm_config_strict_ssl, "emergency npm TLS bypass leaked into the PowerShell installer");
    assert.equal(installerCall.options.env.NGROK_AUTHTOKEN, fakeNgrokToken, "ngrok token did not reach the installer child-process environment");
    const parameterFile = path.join(installDir, "stack-management", "jobs", "fixture-job.parameters.json");
    assert.equal(fs.readFileSync(parameterFile, "utf8").includes(fakeNgrokToken), false, "ngrok token leaked into installer parameter JSON");
    console.log("stack setup apply emergency npm TLS/token transport test passed.");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
