"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { readJson, writeJson, managementDir } = require("./stack-jobs.cjs");

function powershellPath() { return path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe"); }

function installerParameters(setup, { installDir, packageRoot }) {
  const watchdog = readJson(path.join(installDir, "devspace-watchdog.config.json")) || {};
  const result = { InstallDir: installDir, Components: setup.components, TaskLauncher: "PowerShell", ManagementPackageRoot: packageRoot };
  const change = key => !setup.existing || setup.changes.includes(key);
  const mapping = { publicDomain: "PublicBaseUrl", endpointMode: "NgrokEndpointMode", machineName: "MachineName", allowedRoots: "AllowedRoots", hermesDir: "HermesDir" };
  for (const [key, parameter] of Object.entries(mapping)) if (change(key) && setup[key]) result[parameter] = setup[key];
  if (change("mcpNameSuffix")) result.McpNameSuffix = setup.mcpNameSuffix ?? setup.machineName;
  if (setup.components.includes("DevSpace") && !(watchdog.cliPath && fs.existsSync(watchdog.cliPath))) {
    result.CliPath = path.join(packageRoot, "dist", "cli.js");
    result.NodePath = process.execPath;
    result.SkipNpmInstall = true;
  }
  if (watchdog.cliPath && fs.existsSync(watchdog.cliPath)) result.SkipNpmInstall = true;
  if (watchdog.hermesServer && fs.existsSync(watchdog.hermesServer) && watchdog.hermesPython && fs.existsSync(watchdog.hermesPython)) result.SkipHermesInstall = true;
  if (change("allowedRoots") && setup.allowedRoots) result.HermesAllowedRoots = setup.allowedRoots.split(/[;,]/).map(x => x.trim()).filter(Boolean);
  if (setup.fullAccess) result.FullAccess = true;
  if (setup.installTools) result.InstallTools = true;
  if (setup.endpointMode === "CloudEndpoint" && change("internalAgentEndpoint")) result.NgrokAgentBaseUrl = setup.internalAgentEndpoint;
  if (setup.userMode) { result.UserMode = true; result.NoElevate = true; }
  if (setup.installTray) result.InstallWatchdogTray = true;
  if (setup.noLegacyPoller) result.NoLegacyPoller = true;
  return result;
}

async function applySetup(setup, context, run) {
  const parameters = installerParameters(setup, context);
  if (parameters.CliPath) {
    if (!fs.existsSync(parameters.CliPath)) throw new Error("This package is missing the built DevSpace CLI.");
    try { await run(process.execPath, [parameters.CliPath, "help"], { cwd: context.packageRoot }); }
    catch {
      const npmCli = path.join(path.dirname(process.execPath), "node_modules", "npm", "bin", "npm-cli.js");
      if (!fs.existsSync(npmCli)) throw new Error("npm is missing beside the selected Node runtime. Repair Node.js LTS and reopen Setup.");
      await run(process.execPath, [npmCli, fs.existsSync(path.join(context.packageRoot, "package-lock.json")) ? "ci" : "install", "--omit=dev", "--no-audit", "--no-fund"], { cwd: context.packageRoot });
      await run(process.execPath, [parameters.CliPath, "help"], { cwd: context.packageRoot });
    }
  }
  // Splat JSON in PowerShell: arrays and literal path characters survive native CLI parsing.
  const parameterFile = path.join(managementDir(context.installDir), "jobs", `${context.id}.parameters.json`);
  writeJson(parameterFile, parameters);
  const env = { ...process.env };
  if (setup.ngrokAuthToken) env.NGROK_AUTHTOKEN = setup.ngrokAuthToken;
  if (setup.devspaceOwnerToken) env.DEVSPACE_OWNER_TOKEN = setup.devspaceOwnerToken;
  await run(powershellPath(), ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", path.join(context.scriptDir, "stack-apply-parameters.ps1"),
    "-ParameterPath", parameterFile, "-InstallerPath", path.join(context.scriptDir, "install-devspace-watchdog.ps1")], { env, cwd: context.packageRoot });
  return { installed: true, message: "Stack installation and local readiness checks completed." };
}

async function activateCandidate(candidate, plan, context, run, detectedSetup) {
  candidate.action = plan.action;
  if (candidate.kind === "tool") {
    const allowed = { node: "OpenJS.NodeJS.LTS", npm: "OpenJS.NodeJS.LTS", git: "Git.Git", python: "Python.Python.3.12" };
    if (!allowed[candidate.componentId] || candidate.packageId !== allowed[candidate.componentId]) throw new Error("Unsupported prerequisite action.");
    await run("winget.exe", ["install", "--id", candidate.packageId, "--exact", "--source", "winget", "--accept-package-agreements", "--accept-source-agreements", "--silent"]);
    return { message: "Prerequisite installed. Reopen Setup to refresh executable search paths." };
  }
  if (candidate.kind === "bundled") {
    if (!detectedSetup) throw new Error("Complete the installation settings before installing this component.");
    return applySetup(detectedSetup, context, run);
  }
  const candidateFile = path.join(managementDir(context.installDir), "jobs", `${context.id}.candidate.json`);
  writeJson(candidateFile, candidate);
  await run(powershellPath(), ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", path.join(context.scriptDir, "stack-activate.ps1"), "-InstallDir", context.installDir, "-CandidatePath", candidateFile]);
  return { message: "Candidate activated and verified. Reopen Setup to use updated management scripts.", version: candidate.version, commit: candidate.commit };
}
module.exports = { powershellPath, installerParameters, applySetup, activateCandidate };
