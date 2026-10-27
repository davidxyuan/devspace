"use strict";
const fs = require("node:fs");
const path = require("node:path");

function readReleasePolicy(directory = __dirname) {
  const policy = JSON.parse(fs.readFileSync(path.join(directory, "stack-release-manifest.json"), "utf8").replace(/^\uFEFF/, ""));
  if (policy.schemaVersion !== 1 || policy.channel !== "candidate") throw new Error("Stable promotion evidence must be external to the immutable candidate artifact.");
  for (const id of ["devspace-official", "hermes-gpt", "hermes-agent"]) {
    const component = policy.components?.[id];
    if (!component || !/^[\w.-]+\/[\w.-]+$/.test(component.repository) || !/^[a-f0-9]{40}$/.test(component.revision))
      throw new Error(`Release component ${id} requires a repository and fixed revision.`);
    if (!/^\d+\.\d+\.\d+(?:-[\w.-]+)?$/.test(component.version)) throw new Error(`Invalid component version: ${id}`);
    if (id !== "devspace-official" && (!/^[\w./-]+$/.test(component.ref || "") || !/^[\w./-]+$/.test(component.updateBranch || ""))) throw new Error("Invalid component ref/update channel.");
  }
  if (!/^sha512-[A-Za-z0-9+/=]+$/.test(policy.components["devspace-official"].integrity)) throw new Error("Missing npm integrity.");
  return policy;
}

function installationTarget(id) {
  const pin = readReleasePolicy().components[id];
  if (!pin) throw new Error("Component has no release pin.");
  return { kind: id === "devspace-official" ? "npm" : "git", repository: pin.repository, branch: pin.updateBranch || "main", commit: pin.revision, version: pin.version, tag: pin.ref || null, integrity: pin.integrity || null };
}

if (require.main === module) {
  try { process.stdout.write(JSON.stringify(readReleasePolicy())); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
module.exports = { readReleasePolicy, installationTarget };
