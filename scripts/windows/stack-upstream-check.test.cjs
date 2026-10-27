"use strict";
const assert = require("node:assert/strict");
const { checkUpstreams } = require("./stack-upstream-check.cjs");
const { readReleasePolicy } = require("./stack-release-policy.cjs");
(async () => {
  const pins = readReleasePolicy().components;
  const requested = [];
  const report = await checkUpstreams(async url => {
    requested.push(url);
    const body = url.includes("npmjs") ? { name: "@waishnav/devspace", version: pins["devspace-official"].version, gitHead: pins["devspace-official"].revision, dist: { integrity: pins["devspace-official"].integrity } }
      : url.endsWith("/releases/latest") ? { tag_name: "v0.14.0" } : { sha: "a".repeat(40) };
    return { ok: true, text: async () => JSON.stringify(body) };
  });
  assert.equal(report.components[0].changed, false);
  assert.equal(report.components[1].changed, true);
  assert.equal(report.components[1].upstream, "asimons81/hermes-gpt", "a candidate fork must not replace official release discovery");
  assert.ok(requested.includes("https://api.github.com/repos/asimons81/hermes-gpt/releases/latest"));
  assert.equal(report.components[2].upstream, "NousResearch/hermes-agent");
  const failed = await checkUpstreams(async () => ({ ok: false, status: 429 }));
  assert.ok(failed.components.every(c => c.state === "unverified" && !Object.hasOwn(c, "changed")));
  console.log("Upstream checks distinguish fixed releases, fork divergence, and unavailable evidence.");
})().catch(error => { console.error(error); process.exitCode = 1; });
