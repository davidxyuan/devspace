"use strict";
const fs = require("node:fs");
const { readReleasePolicy } = require("./stack-release-policy.cjs");

async function checkUpstreams(fetcher = fetch, githubToken = process.env.TRAY_UPSTREAM_GITHUB_TOKEN) {
  const policy = readReleasePolicy();
  async function get(url) {
    const endpoint = new URL(url);
    const headers = { Accept: "application/json", "User-Agent": "Tray-release-check" };
    if (githubToken && endpoint.origin === "https://api.github.com") headers.Authorization = `Bearer ${githubToken}`;
    const response = await fetcher(url, { headers, redirect: "error", signal: AbortSignal.timeout(15000) });
    if (!response.ok) throw new Error(`${endpoint.hostname} HTTP ${response.status}`);
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
        if (pkg.name !== "@waishnav/devspace" || !/^\d+\.\d+\.\d+$/.test(pkg.version || "") || !/^sha512-[A-Za-z0-9+/=]+$/.test(pkg.dist?.integrity || "")) throw new Error("Invalid npm release identity");
        release = { version: pkg.version, integrity: pkg.dist.integrity, revision: pkg.gitHead ?? null };
        if (release.revision === null) {
          const commit = await get(`https://api.github.com/repos/${upstream}/commits/v${pkg.version}`);
          if (!/^[a-f0-9]{40}$/i.test(commit.sha || "")) throw new Error("Invalid official version tag");
          // A repository tag identifies source for review. It does not attest to the npm build.
          release.sourceTagRevision = commit.sha;
        }
      } else {
        const latest = await get(`https://api.github.com/repos/${upstream}/releases/latest`);
        if (latest.draft || latest.prerelease || !/^[\w.-]+$/.test(latest.tag_name || "")) throw new Error("Invalid stable release tag");
        const commit = await get(`https://api.github.com/repos/${upstream}/commits/${encodeURIComponent(latest.tag_name)}`);
        release = { tag: latest.tag_name, revision: commit.sha };
      }
      if (!/^[a-f0-9]{40}$/i.test(release.revision ?? release.sourceTagRevision ?? "")) throw new Error("Missing immutable release revision");
      let changed = (release.revision ?? release.sourceTagRevision) !== pin.revision;
      if (id === "devspace-official") changed ||= release.version !== pin.version || release.integrity !== pin.integrity;
      if (upstream !== pin.repository && changed) {
        // Later pages omit the GitHub file diff. The comparison totals cover the full range.
        const comparison = await get(`https://api.github.com/repos/${pin.repository}/compare/${release.revision}...${pin.revision}?per_page=1&page=2`);
        if (comparison.base_commit?.sha !== release.revision || !/^[a-f0-9]{40}$/i.test(comparison.merge_base_commit?.sha || ""))
          throw new Error("Could not verify the fork's common ancestor");
        release.commonAncestor = comparison.merge_base_commit.sha;
        changed = release.commonAncestor !== release.revision;
      }
      return { id, pinned: pin, upstream, release, changed, state: "checked" };
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
