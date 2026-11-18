"use strict";
const assert = require("node:assert/strict");
const { checkUpstreams } = require("./stack-upstream-check.cjs");
const { readReleasePolicy } = require("./stack-release-policy.cjs");
(async () => {
  const pins = readReleasePolicy().components;
  const requested = [];
  const latest = "a".repeat(40);
  const fetchRelease = async url => {
    requested.push(url);
    const body = url.includes("npmjs") ? { name: "@waishnav/devspace", version: pins["devspace-official"].version, gitHead: pins["devspace-official"].revision, dist: { integrity: pins["devspace-official"].integrity } }
      : url.endsWith("/releases/latest") ? { tag_name: "v0.14.0" }
      : url.includes("/compare/") ? { base_commit: { sha: latest }, merge_base_commit: { sha: url.includes("hermes-gpt/") ? latest : "b".repeat(40) } }
      : { sha: latest };
    return { ok: true, text: async () => JSON.stringify(body) };
  };
  const report = await checkUpstreams(fetchRelease);
  assert.equal(report.components[0].changed, false);
  assert.equal(report.components[1].changed, false, "a fork with local fixes already includes this official release");
  assert.equal(report.components[1].upstream, "asimons81/hermes-gpt", "a candidate fork must not replace official release discovery");
  assert.ok(requested.includes("https://api.github.com/repos/asimons81/hermes-gpt/releases/latest"));
  assert.equal(report.components[2].upstream, "NousResearch/hermes-agent");
  assert.equal(report.components[2].changed, true, "a diverged fork does not include the new official release");
  const missingGitHead = await checkUpstreams(async url => {
    if (url.includes("npmjs")) return { ok: true, text: async () => JSON.stringify({ name: "@waishnav/devspace", version: "1.1.1", dist: { integrity: pins["devspace-official"].integrity } }) };
    if (url.includes("/compare/")) return { ok: false, status: 404 };
    return fetchRelease(url);
  });
  assert.ok(requested.includes("https://api.github.com/repos/Waishnav/devspace/commits/v1.1.1"));
  assert.equal(missingGitHead.components[0].changed, true);
  assert.equal(missingGitHead.components[0].release.revision, null);
  assert.equal(missingGitHead.components[0].release.sourceTagRevision, latest);
  assert.ok(missingGitHead.components.slice(1).every(c => c.state === "unverified" && !Object.hasOwn(c, "changed")));
  const failed = await checkUpstreams(async () => ({ ok: false, status: 429 }));
  assert.ok(failed.components.every(c => c.state === "unverified" && !Object.hasOwn(c, "changed")));
  console.log("Upstream checks distinguish fixed releases, fork divergence, and unavailable evidence.");
})().catch(error => { console.error(error); process.exitCode = 1; });
