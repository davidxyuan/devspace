"use strict";
const fs = require("node:fs");
const { readReleasePolicy } = require("./stack-release-policy.cjs");

async function checkUpstreams(fetcher = fetch) {
  const policy = readReleasePolicy();
  async function get(url) {
    const response = await fetcher(url, { headers: { Accept: "application/json", "User-Agent": "Tray-release-check" }, redirect: "error", signal: AbortSignal.timeout(15000) });
    if (!response.ok) throw new Error(`Upstream HTTP ${response.status}`);
    const body = await response.text();
    if (body.length > 2 * 1024 * 1024) throw new Error("Upstream response exceeds limit");
    return JSON.parse(body);
  }
  const components = await Promise.all(Object.entries(policy.components).map(async ([id, pin]) => {
    const upstream = id === "hermes-agent" ? "NousResearch/hermes-agent" : id === "hermes-gpt" ? "asimons81/hermes-gpt" : pin.repository;
    try {
      let release;
      if (id === "devspace-official") {
        const pkg = await get("https://registry.npmjs.org/%40waishnav%2Fdevspace/latest");
        if (pkg.name !== "@waishnav/devspace" || !/^sha512-[A-Za-z0-9+/=]+$/.test(pkg.dist?.integrity || "")) throw new Error("Invalid npm release identity");
        release = { version: pkg.version, revision: pkg.gitHead, integrity: pkg.dist.integrity };
      } else {
        const latest = await get(`https://api.github.com/repos/${upstream}/releases/latest`);
        if (latest.draft || latest.prerelease || !/^[\w.-]+$/.test(latest.tag_name || "")) throw new Error("Invalid stable release tag");
        const commit = await get(`https://api.github.com/repos/${upstream}/commits/${encodeURIComponent(latest.tag_name)}`);
        release = { tag: latest.tag_name, revision: commit.sha };
      }
      if (!/^[a-f0-9]{40}$/i.test(release.revision || "")) throw new Error("Missing immutable release revision");
      return { id, pinned: pin, upstream, release, changed: upstream !== pin.repository || release.revision !== pin.revision || Boolean(release.integrity && release.integrity !== pin.integrity), state: "checked" };
    } catch (error) {
      return { id, upstream, state: "unverified", error: error.message };
    }
  }));
  return { checkedAt: new Date().toISOString(), candidateId: policy.id, scope: "release discovery only; never install, merge, or promote", components };
}
if (require.main === module) checkUpstreams().then(report => {
  const content = JSON.stringify(report, null, 2);
  if (process.argv[2]) fs.writeFileSync(process.argv[2], content, { flag: "wx" });
  else console.log(content);
  if (report.components.some(c => c.state !== "checked")) process.exitCode = 1;
}).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { checkUpstreams };
