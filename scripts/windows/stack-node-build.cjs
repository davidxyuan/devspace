"use strict";
const fs = require("node:fs");
const path = require("node:path");

function devspaceEntrypoint(root) {
  const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  const bin = typeof pkg.bin === "string" ? pkg.bin : pkg.bin?.devspace;
  if (pkg.name !== "@waishnav/devspace" || typeof bin !== "string" || !bin || path.isAbsolute(bin) || /[:\0\r\n]/.test(bin)) throw new Error("Invalid DevSpace entrypoint.");
  const cli = path.resolve(root, bin);
  const canonicalRoot = fs.realpathSync(root) + path.sep;
  if (!cli.startsWith(path.resolve(root) + path.sep) || !fs.existsSync(cli) || !fs.realpathSync(cli).startsWith(canonicalRoot) || !fs.statSync(cli).isFile()) throw new Error("DevSpace entrypoint must be inside its package.");
  return cli;
}

// The source controls its build contract. Install a declared manager only inside
// the disposable candidate; never replace a machine-wide npm/pnpm installation.
async function buildNodeCandidate({ root, stage, node, npm, invoke, windowsTests }) {
  const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  const hasNpm = fs.existsSync(path.join(root, "package-lock.json"));
  const hasPnpm = fs.existsSync(path.join(root, "pnpm-lock.yaml"));
  const declared = pkg.packageManager;
  const match = typeof declared === "string" && /^(npm|pnpm)@(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$/.exec(declared);
  if (declared && !match || hasNpm === hasPnpm || !declared && hasPnpm)
    throw new Error("候選來源必須提供單一鎖檔；pnpm 必須宣告固定 packageManager 版本。");
  const manager = match ? match[1] : "npm";
  if (manager === "npm" && !hasNpm || manager === "pnpm" && !hasPnpm)
    throw new Error("候選來源的 packageManager 與鎖檔不符。");
  if (typeof pkg.scripts?.build !== "string" || typeof pkg.scripts?.test !== "string" || windowsTests && typeof pkg.scripts?.["test:windows-watchdog"] !== "string")
    throw new Error("候選來源缺少 build/test 或 test:windows-watchdog 驗證指令。");
  let cli = npm;
  let bin = path.dirname(node);
  if (match) {
    const toolsRoot = path.join(stage, "build-tools");
    await invoke(node, [npm, "install", "--prefix", toolsRoot, "--save-exact", "--ignore-scripts", "--engine-strict", "--no-audit", "--no-fund", "--registry=https://registry.npmjs.org", declared]);
    cli = path.join(toolsRoot, "node_modules", manager, "bin", manager === "pnpm" ? "pnpm.cjs" : "npm-cli.js");
    const installed = await invoke(node, [cli, "--version"]);
    if (installed.stdout.trim() !== match[2]) throw new Error("候選建置工具版本與宣告不符。");
    bin = path.join(toolsRoot, "node_modules", ".bin");
  }
  const environment = { ...process.env };
  const pathKey = Object.keys(environment).find(k => k.toLowerCase() === "path") || "PATH";
  environment[pathKey] = [bin, path.dirname(node), environment[pathKey] || ""].join(path.delimiter);
  const run = args => invoke(node, [cli, ...args], { cwd: root, env: environment });
  await run(manager === "pnpm" ? ["install", "--frozen-lockfile"] : ["ci", "--no-audit", "--no-fund"]);
  await run(["run", "build"]);
  await run(["test"]);
  if (windowsTests) await run(["run", "test:windows-watchdog"]);
  return { packageManager: declared || "npm", lockfile: manager === "pnpm" ? "pnpm-lock.yaml" : "package-lock.json" };
}
module.exports = { buildNodeCandidate, devspaceEntrypoint };
