"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawn } = require("node:child_process");

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "")); }
  catch (error) { if (error.code === "ENOENT") return null; throw error; }
}
function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(value));
  try {
    // Windows readers (including the Setup poller and antivirus) can briefly
    // hold the destination between two durable journal writes.
    for (let attempt = 0; ; attempt++) {
      try { fs.renameSync(temporary, file); break; }
      catch (error) {
        if (!['EPERM', 'EACCES', 'EBUSY'].includes(error.code) || attempt >= 20) throw error;
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
      }
    }
  }
  finally { if (fs.existsSync(temporary)) fs.unlinkSync(temporary); }
}
function managementDir(installDir) { return path.join(installDir, "stack-management"); }
function jobFile(installDir, id) {
  if (!/^[a-f0-9]{24}$/.test(id || "")) throw new Error("Invalid job ID.");
  return path.join(managementDir(installDir), "jobs", `${id}.json`);
}
function readJob(installDir, id) { return readJson(jobFile(installDir, id)); }
function saveJob(installDir, job) { job.updatedAt = new Date().toISOString(); writeJson(jobFile(installDir, job.id), job); }
function activeJob(installDir) {
  const record = readJson(path.join(managementDir(installDir), "active.json"));
  return record?.id ? readJob(installDir, record.id) : null;
}
function appendOutput(job, source, text, secrets = []) {
  for (let line of String(text || "").split(/\r?\n/)) {
    if (!line.trim()) continue;
    line = line.replace(/^(Owner password:\s*).+$/i, "$1[configured]")
      .replace(/((?:token|password|secret|authorization|api[_-]?key)\s*[:=]\s*)[^\s,;]+/ig, "$1[secret]")
      .replace(/https?:\/\/[^\s/@]+:[^\s/@]+@/g, "https://[credentials]@");
    for (const secret of secrets.filter(Boolean)) line = line.split(secret).join("[secret]");
    job.lines.push({ timestamp: new Date().toISOString(), source, text: line.slice(0, 4000) });
  }
  if (job.lines.length > 500) job.lines.splice(0, job.lines.length - 500);
}
function runLogged(job, installDir, command, args, options = {}, secrets = []) {
  return new Promise((resolve, reject) => {
    const { timeout = 30 * 60 * 1000, ...spawnOptions } = options;
    const child = spawn(command, args, { windowsHide: true, stdio: ["ignore", "pipe", "pipe"], ...spawnOptions });
    let stdout = "", stderr = "", timedOut = false;
    const partial = { stdout: "", stderr: "" };
    function output(source, chunk, final = false) {
      partial[source] += chunk;
      const last = final ? partial[source].length : partial[source].lastIndexOf("\n") + 1;
      if (last) { appendOutput(job, source, partial[source].slice(0, last), secrets); partial[source] = partial[source].slice(last); saveJob(installDir, job); }
    }
    child.stdout.on("data", chunk => { const text = chunk.toString("utf8"); stdout = (stdout + text).slice(-1024 * 1024); output("stdout", text); });
    child.stderr.on("data", chunk => { const text = chunk.toString("utf8"); stderr = (stderr + text).slice(-1024 * 1024); output("stderr", text); });
    // ponytail: one operation per installation; a timeout reports failure, never retries a mutation.
    const timer = setTimeout(() => {
      timedOut = true;
      appendOutput(job, "warning", "Command exceeded its expected duration. Keeping operation ownership until it exits; no concurrent changes are allowed.");
      saveJob(installDir, job);
    }, timeout);
    child.once("error", error => { clearTimeout(timer); reject(error); });
    child.once("close", code => {
      clearTimeout(timer); output("stdout", "", true); output("stderr", "", true);
      if (code === 0 && !timedOut) resolve({ stdout, stderr });
      else reject(new Error(`${path.basename(command)} ${timedOut ? "timed out" : `exited with code ${code}`}.`));
    });
  });
}

async function startWorker({ installDir, packageRoot, scriptDir, type, input = {}, inventory }) {
  const previous = activeJob(installDir);
  if (input.requestId && previous?.requestId === input.requestId) return previous;
  const id = crypto.randomBytes(12).toString("hex");
  const capsule = path.join(managementDir(installDir), "workers", id, "windows");
  fs.mkdirSync(capsule, { recursive: true });
  for (const file of fs.readdirSync(scriptDir, { withFileTypes: true })) {
    if (file.isFile() && /\.(?:ps1|cjs|html|json|vbs)$/.test(file.name) && !file.name.includes(".test.")) fs.copyFileSync(path.join(scriptDir, file.name), path.join(capsule, file.name));
  }
  const job = { id, type, componentId: input.componentId || null, action: input.action || null, requestId: input.requestId || null,
    phase: "queued", step: "Acquire operation ownership", startedAt: new Date().toISOString(), finishedAt: null, exitCode: null, result: null, error: null, lines: [] };
  saveJob(installDir, job);
  const ps = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
  const child = spawn(ps, ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", path.join(capsule, "stack-operation.ps1"),
    "-RunNode", process.execPath, "-WorkerScript", path.join(capsule, "devspace-stack-setup.cjs"), "-InstallDir", installDir], {
    windowsHide: true, stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, DEVSPACE_STACK_OPERATION_TOKEN: "", DEVSPACE_STACK_INSTALL_DIR: installDir, DEVSPACE_STACK_PACKAGE_ROOT: packageRoot },
  });
  const secrets = [input.ngrokAuthToken, input.devspaceOwnerToken].filter(Boolean);
  child.stdin.on("error", () => {});
  child.stdin.end(JSON.stringify({ id, type, input, inventory })); // credentials stay in anonymous pipes, never job files
  let ready = false, errors = "";
  return new Promise((resolve, reject) => {
    let stdout = "";
    child.stdout.on("data", chunk => {
      stdout += chunk.toString("utf8");
      if (!ready && stdout.includes("STACK_OPERATION_READY")) {
        ready = true;
        writeJson(path.join(managementDir(installDir), "active.json"), { id });
        child.unref(); resolve(job);
      }
    });
    child.stderr.on("data", chunk => { errors = (errors + chunk.toString("utf8")).slice(-16000); });
    child.once("error", reject);
    child.once("close", code => {
      const latest = readJob(installDir, id) || job;
      if (!["completed", "failed", "rollback_failed"].includes(latest.phase)) {
        latest.phase = ready ? "rollback_failed" : "failed"; latest.exitCode = code ?? 1; latest.finishedAt = new Date().toISOString();
        appendOutput(latest, "error", errors || "Management supervisor stopped before the operation completed.", secrets);
        latest.error = latest.lines.at(-1)?.text; saveJob(installDir, latest);
      }
      if (!ready) reject(new Error(latest.error || "Could not acquire stack operation ownership."));
    });
  });
}
module.exports = { readJson, writeJson, managementDir, jobFile, readJob, saveJob, activeJob, appendOutput, runLogged, startWorker };
