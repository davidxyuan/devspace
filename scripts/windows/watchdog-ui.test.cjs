"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class Node {
  constructor(tag = "div") { this.tagName=tag; this.children=[];this.textContent="";this.value="";this.checked=false;this.disabled=false;this.dataset={};this.listeners={};this.classList={toggle(){}};this.elements=new Proxy({}, {get:(o,k)=>o[k]||(o[k]=new Node("input"))}); }
  append(...nodes) { this.children.push(...nodes); }
  appendChild(node) { this.append(node);return node; }
  replaceChildren(...nodes) { this.children=[...nodes]; }
  addEventListener(name, handler) { (this.listeners[name]??=[]).push(handler); }
  setAttribute() {}
  set innerHTML(_) { throw Error("Unsafe HTML insertion"); }
}
function harness(name) {
  const nodes=new Map(), timers=[], requests=[], saved=new Map();
  const query=selector=>{
    const field=/^\[name=([^\]]+)\]$/.exec(selector);
    if(field)return query("#setup-form").elements[field[1]];
    if(!nodes.has(selector))nodes.set(selector,new Node());
    return nodes.get(selector);
  };
  const sandbox={ console, URL, Date, Math, encodeURIComponent,
    document:{querySelector:query,querySelectorAll:()=>[],createElement:tag=>new Node(tag)},
    setTimeout:fn=>{timers.push(fn);return timers.length;},clearTimeout(){},
    sessionStorage:{getItem:key=>saved.get(key),setItem:(key,value)=>saved.set(key,value),removeItem:key=>saved.delete(key)},
    confirm:()=>true,alert(){},prompt:()=>null, navigator:{},window:{open(){}},
    fetch:async(url,options)=>{requests.push({url,options});return {ok:true,json:async()=>sandbox.response(url,options)};},
    response:()=>({schemaVersion:1,revision:"r1",components:[]})
  };
  vm.createContext(sandbox);
  let source=fs.readFileSync(path.join(__dirname,name),"utf8").match(/<script>([\s\S]*?)<\/script>/)[1].replace("{{DASHBOARD_PORT}}","17870");
  source=source.replace("initializeComponents();statusLoop();","").replace("resetNgrokProfileForm(); refreshNgrokProfiles(); initializeComponents(); statusLoop();","");
  vm.runInContext(source,sandbox,{filename:name});
  return {sandbox,query,requests,saved,run:script=>vm.runInContext(script,sandbox)};
}
async function exercise(name) {
  const h=harness(name), {run,query,sandbox,requests}=h;
  run("renderComponents()");
  assert.equal(query("#component-rows").children.length,12,"all component rows exist without discovery");
  assert(query("#component-rows").children.every(row=>row.children[1].textContent==="unknown / unknown"));
  sandbox.inventory={revision:"r1",checkedAt:"local time",remoteCheckedAt:"older remote time",components:[
    {id:"node",label:"Node.js",installState:"installed",runtimeState:"running",installedVersion:"22",source:{kind:"managed",dirty:false},latest:{state:"unavailable",reason:"offline"},actions:[{id:"update",label:"Update",enabled:false,reason:"Cannot check latest"}]},
    {id:"hermes-gpt",label:"<script>literal label</script>",installState:"missing",runtimeState:"stopped",source:{kind:"git",dirty:true},latest:{state:"available",version:"2",tag:"v2"},tested:{version:"1"},actions:[{id:"install",label:"Install",enabled:true}]}
  ]};
  run("renderComponents(inventory)");
  const rows=query("#component-rows").children;
  assert.equal(rows[0].children[1].textContent,"installed / running","offline latest does not erase installation");
  assert.match(rows[0].children[3].textContent,/offline/);
  assert.equal(rows[0].children[6].children[0].disabled,true);
  const hermes=rows.find(row=>row.dataset.componentId==="hermes-gpt");
  assert.equal(hermes.children[0].textContent,"<script>literal label</script>");
  assert.match(hermes.children[5].textContent,/Local changes present/);
  assert.match(hermes.children[3].textContent,/Tag: v2/);
  assert.match(hermes.children[4].textContent,/"version":"1"/);
  sandbox.response=(url)=>url==="/api/components/action"?{ok:true,jobId:"j1"}:{};
  await run('requestComponentAction(inventory.components[1],inventory.components[1].actions[0])');
  const posted=JSON.parse(requests.find(r=>r.url==="/api/components/action").options.body);
  assert.equal(posted.expectedRevision,"r1");assert.equal(posted.componentId,"hermes-gpt");assert(posted.requestId);
  assert.equal(run("management.jobId"),"j1");
  assert.equal(h.saved.get("devspace-management-job"),"j1");
  assert.equal(query("#components-refresh").disabled,true);
  let resolveJob;
  sandbox.response=()=>new Promise(resolve=>{resolveJob=resolve;});
  const first=run("pollManagementJob()");
  await Promise.resolve();await Promise.resolve();
  const count=requests.length;
  await run("pollManagementJob()");
  assert.equal(requests.length,count,"slow job request remains single flight");
  resolveJob({id:"j1",phase:"queued",lines:[]});await first;
  assert.equal(run("management.jobId"),"j1","queued is not terminal");
  sandbox.response=()=>{throw Error("temporary disconnect");};
  await run("pollManagementJob()");
  assert.match(query("#job-state").textContent,/Reconnecting/);
  assert.equal(run("management.jobId"),"j1","disconnect retains durable job");
  sandbox.response=url=>url.startsWith("/api/job")?{id:"j1",phase:"rollback_failed",error:"fixture failure",lines:[]}:{revision:"r2",components:[]};
  run(name==="devspace-stack-setup.html"?"refresh = async()=>{}":"refreshStatus = async()=>{}");
  await run("pollManagementJob()");
  assert.equal(run("management.jobId"),null,"rollback failure releases poll and keeps error visible");
  assert.match(query("#job-state").textContent,/fixture failure/);
  run('attachManagementStatus({activeJobId:"j1",activeJob:{id:"j1",phase:"running"}})');
  assert.equal(run("management.jobId"),null,"stale status cannot restart completed job");
  run('attachManagementStatus({activeJobId:"j2",activeJob:{id:"j2",phase:"queued"}})');
  assert.equal(run("management.jobId"),"j2","page reconnects to another active job");
  run('attachManagementStatus({activeJobId:"older-status",activeJob:{id:"older-status",phase:"running"}})');
  assert.equal(run("management.jobId"),"j2","late status cannot replace the job being tracked");
}
(async()=>{
  await exercise("devspace-stack-setup.html");
  await exercise("devspace-control-center.html");
  const h=harness("devspace-stack-setup.html");
  h.sandbox.initial={state:"Existing",configurationFingerprint:"original",defaults:{machineName:"station",allowedRoots:"D:\\projects",endpointMode:"AgentEndpoint",fullAccess:true},packageVersion:"1",tray:{}};
  h.run("fill(initial)");
  const form=h.query("#setup-form");
  form.elements.machineName.value="my unsaved station";
  form.listeners.input[0]({target:{name:"machineName"}});
  form.elements.ngrokAuthToken.value="unsaved secret";
  form.listeners.input[0]({target:{name:"ngrokAuthToken"}});
  h.sandbox.next={...h.sandbox.initial,configurationFingerprint:"external update",defaults:{...h.sandbox.initial.defaults,machineName:"different station"}};
  h.run("fill(next)");
  assert.equal(form.elements.machineName.value,"my unsaved station","refresh preserves form edits");
  assert.equal(form.elements.ngrokAuthToken.value,"unsaved secret","refresh does not clear pending secret");
  assert.equal(h.run("readForm().configurationFingerprint"),"original","dirty form keeps original conflict fingerprint");
  form.elements.ngrokAuthToken.value="";
  assert.equal(h.run("readForm().ngrokAuthToken"),"","blank secret keeps current token");
  assert.equal(h.run("readForm().fullAccess"),true,"refresh preserves existing full access setting");
  assert.equal(h.run('"updatePackageFromGithub" in readForm()'),false);
  assert.equal(h.run('"updateHermesSource" in readForm()'),false);
  let acceptApply;
  h.sandbox.response=()=>new Promise(resolve=>{acceptApply=resolve;});
  const applying=h.run("apply({preventDefault(){}})");
  await new Promise(setImmediate);
  form.elements.machineName.value="edit made during submit";
  form.listeners.input[0]({target:{name:"machineName"}});
  form.elements.ngrokAuthToken.value="new secret typed during submit";
  form.listeners.input[0]({target:{name:"ngrokAuthToken"}});
  acceptApply({ok:true,jobId:"apply-fixture"});
  await applying;
  assert.equal(form.elements.ngrokAuthToken.value,"new secret typed during submit","accepting prior submit preserves a newer secret edit");
  assert.equal(h.run('editedFields.has("machineName")'),true,"accepting prior submit preserves newer field edit tracking");
  console.log("watchdog UI tests passed (mock DOM, offline inventory, delayed job requests, edited forms).");
})().catch(error=>{console.error(error);process.exitCode=1;});
