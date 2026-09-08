"use strict";
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const yaml = require('yaml');
const {readJson} = require('./stack-jobs.cjs');
const hash = value => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
function mergePolicy(text, config) {
  const slug = config.machineSlug;
  if (!/^[a-z0-9-]+$/.test(slug)) throw Error('Invalid station name.');
  const internal = new URL(config.ngrokAgentBaseUrl);
  if (internal.protocol !== 'https:' || !internal.hostname.endsWith('.internal') || internal.username || internal.password || internal.pathname !== '/' || internal.search || internal.hash) throw Error('Invalid internal endpoint.');
  const policy = yaml.parse(text || '{}', { maxAliasCount: 20 });
  if (!policy || typeof policy !== 'object' || Array.isArray(policy)) throw Error('Unsupported existing policy.');
  const rules = policy.on_http_request || [];
  if (!Array.isArray(rules) || rules.some(r => !r || typeof r !== 'object' || Array.isArray(r))) throw Error('Unsupported request rules.');
  const name = `DevSpace ${slug} router`;
  if (rules.filter(r => r.name === name).length > 1) throw Error('Duplicate station rules; review manually.');
  const rule = { name, expressions: [`req.url.path.startsWith("/${slug}/") || req.url.path.startsWith("/.well-known/oauth-authorization-server/${slug}/") || req.url.path.startsWith("/.well-known/oauth-protected-resource/${slug}/")`], actions: [{type:'forward-internal', config:{url:internal.origin}}] };
  const index = rules.findIndex(r => r.name === name);
  if (index >= 0) rules[index] = rule;
  else {
    if (rules.some(r => !r.expressions?.length && r.actions?.some(a => ['forward-internal','custom-response','deny','redirect'].includes(a.type)))) throw Error('An existing catch-all rule may shadow this station. Review rule placement manually.');
    // Keep preceding authentication and filtering rules ahead of the new route.
    rules.push(rule);
  }
  policy.on_http_request = rules;
  return yaml.stringify(policy);
}
function createCloudPolicy(installDir, fetcher = fetch) {
  const previews = new Map(); let busy = false;
  function readConfig() {
    try {
      const value = readJson(path.join(installDir,'devspace-watchdog.config.json'));
      if (!value || typeof value !== 'object' || Array.isArray(value)) throw Error();
      return value;
    } catch { throw Error('Watchdog configuration is missing or invalid.'); }
  }
  return async function handle(input, apply) {
    if (busy) throw Error('Cloud policy operation in progress.');
    busy = true;
    try {
      const config = readConfig();
      if (config.ngrokEndpointMode !== 'CloudEndpoint') throw Error('This installation uses Agent Endpoint; no Cloud Policy is needed.');
      if (typeof input?.apiKey !== 'string' || !input.apiKey || input.apiKey.length > 4096 || /[\r\n]/.test(input.apiKey)) throw Error('Enter an ngrok API Key.');
      if (!/^ep_[A-Za-z0-9]+$/.test(input.endpointId)) throw Error('Enter the Cloud Endpoint ID (ep_...).');
      const endpointPath = '/endpoints/' + input.endpointId;
      async function api(method, body) {
        let response;
        try { response = await fetcher('https://api.ngrok.com'+endpointPath, {method, redirect:'error', signal:AbortSignal.timeout(15000), headers:{Authorization:'Bearer '+input.apiKey,'ngrok-version':'2','content-type':'application/json'}, ...(body ? {body:JSON.stringify(body)} : {})}); }
        catch { throw Error('ngrok request failed or timed out. Check endpoint state before retrying an apply.'); }
        if (!response.ok) throw Error('ngrok API returned HTTP '+response.status);
        return response.json();
      }
      const remote = await api('GET');
      if (remote.id !== input.endpointId || remote.type !== 'cloud' || new URL(remote.url).origin !== new URL(config.publicBaseUrl).origin) throw Error('Cloud Endpoint identity does not match this installation.');
      const fingerprint = hash({config,policy:remote.traffic_policy, id:remote.id});
      const policy = mergePolicy(remote.traffic_policy,config);
      for (const [id,p] of previews) if (Date.now()-p.time > 300000) previews.delete(id);
      if (!apply) {
        if (previews.size >= 32) previews.delete(previews.keys().next().value);
        const previewId = crypto.randomUUID(); previews.set(previewId,{fingerprint,time:Date.now()});
        return {previewId,policy,domain:remote.url};
      }
      const preview = previews.get(input.previewId); previews.delete(input.previewId);
      if (!preview || preview.fingerprint !== fingerprint) throw Error('Preview expired or configuration changed. Preview again.');
      const backup = path.join(installDir,'configuration-backups','cloud-policy-'+Date.now()+'.json');
      fs.mkdirSync(path.dirname(backup),{recursive:true});
      fs.writeFileSync(backup,JSON.stringify({id:remote.id,url:remote.url,traffic_policy:remote.traffic_policy},null,2),{flag:'wx'});
      if (hash(readConfig()) !== hash(config)) throw Error('Local configuration changed. Preview again.');
      await api('PATCH',{traffic_policy:policy});
      const verified = await api('GET');
      if (hash(yaml.parse(verified.traffic_policy)) !== hash(yaml.parse(policy))) throw Error('Policy readback differs. Inspect ngrok before retrying; backup retained.');
      return {applied:true,backup,domain:remote.url};
    } finally { busy=false; }
  };
}
module.exports={mergePolicy,createCloudPolicy};
