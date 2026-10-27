"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { readReleasePolicy, installationTarget } = require("./stack-release-policy.cjs");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "release-policy-"));
try {
  const policy = readReleasePolicy(__dirname);
  assert.equal(policy.channel, "candidate", "unverified release must remain a candidate");
  assert.match(policy.components["hermes-gpt"].revision, /^[a-f0-9]{40}$/);
  const file = path.join(root, "stack-release-manifest.json");
  const changed = structuredClone(policy);
  changed.components["hermes-gpt"].revision = "master";
  fs.writeFileSync(file, JSON.stringify(changed));
  assert.throws(() => readReleasePolicy(root), /fixed revision/);
  changed.components["hermes-gpt"].revision = policy.components["hermes-gpt"].revision;
  changed.channel = "stable";
  fs.writeFileSync(file, JSON.stringify(changed));
  assert.throws(() => readReleasePolicy(root), /promotion evidence/);
  for (const [id, pin] of Object.entries(policy.components)) {
    const target = installationTarget(id);
    assert.equal(target.commit, pin.revision);
    assert.equal(target.version, pin.version);
    assert.equal(target.repository, pin.repository);
  }
  console.log("Release policy rejects floating pins and unsupported stable claims.");
} finally { fs.rmSync(root, { recursive: true, force: true }); }
