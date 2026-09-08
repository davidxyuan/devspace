"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const http = require("node:http");
const { spawn, spawnSync } = require("node:child_process");
const jobs = require("./stack-jobs.cjs");
const ps = path.join(process.env.SystemRoot || "C:\\Windows","System32","WindowsPowerShell","v1.0","powershell.exe");
const wait = ms => new Promise(resolve=>setTimeout(resolve,ms));
async function until(check, description, timeout=15000) {
  const end=Date.now()+timeout;
  while(Date.now()<end) { const result=await check();if(result)return result;await wait(40); }
  throw Error("Timed out: "+description);
}
function request(base, route, {method="GET", body, token, headers={}}={}) {
  return new Promise((resolve,reject)=>{
    const target=new URL(route,base), encoded=body===undefined?"":JSON.stringify(body);
    const req=http.request(target,{method,headers:{...(method==="POST"?{"content-type":"application/json",origin:new URL(base).origin,"x-devspace-setup-token":token||""}:{}),...headers}},res=>{
      let text="";res.setEncoding("utf8");res.on("data",s=>text+=s);
      res.on("end",()=>{let data;try{data=JSON.parse(text)}catch{}resolve({status:res.statusCode,text,data})});
    });
    req.setTimeout(8000,()=>req.destroy(Error("fixture HTTP timeout")));
    req.on("error",reject);req.end(encoded);
  });
}
function cleanEnv(extra={}) {
  const result={...process.env,...extra};delete result.DEVSPACE_STACK_OPERATION_TOKEN;delete result.DEVSPACE_STACK_JOB_ID;return result;
}
async function closeServer(child) {
  if(!child||child.exitCode!==null)return;
  const exited=new Promise(resolve=>child.once("exit",resolve));
  child.kill();await exited;
}
async function startServer(script, installDir, env) {
  const child=spawn(process.execPath,[script,"--no-open","--install-dir",installDir],{windowsHide:true,env,stdio:["ignore","pipe","pipe"]});
  let stdout="",stderr="";
  child.stdout.on("data",data=>stdout+=data.toString());
  child.stderr.on("data",data=>stderr+=data.toString());
  try {
    const base=await until(()=>{if(child.exitCode!==null)throw Error("Setup fixture exited: "+stderr);return stdout.match(/DevSpace Stack Setup:\s+(http:\/\/127\.0\.0\.1:\d+\/)/)?.[1]},"Setup HTTP announcement");
    const home=await request(base,"/");
    const token=home.text.match(/const setupToken="([^"]+)"/)?.[1];
    assert(token,"temporary Setup token rendered");
    return {child,base,token};
  } catch(error) { await closeServer(child);throw error; }
}
function runPs(file,args,env) {
  const result=spawnSync(ps,["-NoLogo","-NoProfile","-NonInteractive","-File",file,...args],{windowsHide:true,env,encoding:"utf8",timeout:12000});
  if(result.error)throw result.error;
  return result;
}
async function testLeases(root, helper) {
  const target=path.join(root,"lock-fixture"), release=path.join(root,"release-lock"), ready=path.join(root,"held-lock.json");
  fs.mkdirSync(target,{recursive:true});
  const fixture=path.join(root,"lease-fixture.ps1");
  fs.writeFileSync(fixture,`param($Helper,$Root,$Action,$Ready,$Release)
$ErrorActionPreference='Stop'
. $Helper
if($Action -eq 'Hold') {
  $lease=$null
  try {
    $lease=Enter-StackOperation $Root
    [IO.File]::WriteAllText($Ready,(@{token=$lease.token;pid=$PID}|ConvertTo-Json -Compress))
    $deadline=[DateTimeOffset]::UtcNow.AddSeconds(25)
    while(-not [IO.File]::Exists($Release) -and [DateTimeOffset]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 40}
    if(-not [IO.File]::Exists($Release)){throw 'fixture release timeout'}
  } finally {Exit-StackOperation $lease}
} elseif($Action -eq 'Busy') {
  @{busy=(Test-StackOperationBusy $Root)}|ConvertTo-Json -Compress
} else {
  $lease=$null
  try {
    $lease=Enter-StackOperation $Root
    @{joined=$lease.joined;token=$lease.token}|ConvertTo-Json -Compress
  } catch {[Console]::Error.WriteLine($_.Exception.Message);exit 7}
  finally {Exit-StackOperation $lease}
}
`);
  const args=["-Helper",helper,"-Root",target,"-Ready",ready,"-Release",release];
  const owner=spawn(ps,["-NoProfile","-NonInteractive","-File",fixture,...args,"-Action","Hold"],{windowsHide:true,env:cleanEnv(),stdio:["ignore","pipe","pipe"]});
  let ownerError="";owner.stderr.on("data",d=>ownerError+=d);
  try {
    await until(()=>fs.existsSync(ready),"cross-process lease owner");
    const token=JSON.parse(fs.readFileSync(ready,"utf8")).token;
    let result=runPs(fixture,[...args,"-Action","Busy"],cleanEnv());
    assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout).busy,true);
    result=runPs(fixture,[...args,"-Action","Enter"],cleanEnv());
    assert.equal(result.status,7,"unjoined process cannot acquire live FileShare lock");
    assert.match(result.stderr,/Another stack/);
    result=runPs(fixture,[...args,"-Action","Enter"],{...cleanEnv(),DEVSPACE_STACK_OPERATION_TOKEN:"wrong-fixture-token"});
    assert.equal(result.status,7,"wrong token cannot join");
    result=runPs(fixture,[...args,"-Action","Enter"],{...cleanEnv(),DEVSPACE_STACK_OPERATION_TOKEN:token});
    assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout).joined,true,"matching inherited token joins live owner");
    result=runPs(fixture,[...args,"-Action","Busy"],cleanEnv());
    assert.equal(JSON.parse(result.stdout).busy,true,"joined child exit does not release owner");
  } finally {
    fs.writeFileSync(release,"release only fixture owner");
    await until(()=>owner.exitCode!==null,"fixture lock owner graceful exit");
  }
  assert.equal(owner.exitCode,0,ownerError);
  const lock=path.join(target,"stack-management","operation.lock");
  fs.writeFileSync(lock,JSON.stringify({token:"stale-fixture-token",pid:2147483647,startedAt:"1900-01-01T00:00:00Z"}));
  let result=runPs(fixture,[...args,"-Action","Busy"],cleanEnv());
  assert.equal(JSON.parse(result.stdout).busy,false,"stale record alone is not a live lease");
  result=runPs(fixture,[...args,"-Action","Enter"],{...cleanEnv(),DEVSPACE_STACK_OPERATION_TOKEN:"stale-fixture-token"});
  assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout).joined,false,"stale token cannot impersonate a joined owner");
  assert.notEqual(JSON.parse(result.stdout).token,"stale-fixture-token");
  console.log("PASS: cross-process owner, valid/invalid joins, child release, and stale lease file.");
  const id="d".repeat(24), directory=path.join(target,"stack-management");
  jobs.saveJob(target,{id,phase:"running",startedAt:"1900-01-01T00:00:00Z",lines:[]});
  jobs.writeJson(path.join(directory,"active.json"),{id});
  jobs.writeJson(path.join(directory,"jobs",id+".owner.json"),{token:"reserved-fixture-token"});
  result=runPs(fixture,[...args,"-Action","Busy"],cleanEnv());
  assert.equal(JSON.parse(result.stdout).busy,true,"durable running reservation blocks after live handle is gone, without age expiry");
  result=runPs(fixture,[...args,"-Action","Enter"],cleanEnv());
  assert.equal(result.status,7,"unrelated mutation cannot bypass orphaned active job");
  result=runPs(fixture,[...args,"-Action","Enter"],{...cleanEnv(),DEVSPACE_STACK_OPERATION_TOKEN:"reserved-fixture-token"});
  assert.equal(result.status,7,"orphaned job requires both exact job identity and token");
  result=runPs(fixture,[...args,"-Action","Enter"],{...cleanEnv(),DEVSPACE_STACK_JOB_ID:id,DEVSPACE_STACK_OPERATION_TOKEN:"reserved-fixture-token"});
  assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout).joined,false);
  assert.equal(JSON.parse(result.stdout).token,"reserved-fixture-token","authorized sequential child reclaims lease without changing operation token");
  jobs.saveJob(target,{id,phase:"rollback_failed",lines:[]});
  result=runPs(fixture,[...args,"-Action","Enter"],cleanEnv());
  assert.equal(result.status,7,"rollback failure retains fail-closed reservation");
  jobs.saveJob(target,{id,phase:"completed",lines:[]});
  result=runPs(fixture,[...args,"-Action","Busy"],cleanEnv());
  assert.equal(JSON.parse(result.stdout).busy,false,"completed job releases durable reservation");
  console.log("PASS: orphaned reservation, exact participant reclaim, rollback failure, and completed release.");
}
async function testRedaction(root) {
  const installDir=path.join(root,"redaction"), id="c".repeat(24);
  const job={id,type:"fixture",phase:"running",lines:[]};
  jobs.saveJob(installDir,job);
  const credential="fixture-secret-split-across-chunks", auth="fixture-auth-value";
  const writer=path.join(root,"chunk-writer.cjs");
  fs.writeFileSync(writer,`process.stdout.write("plain fixture-secret-");setTimeout(()=>{process.stdout.write("split-across-chunks\\nAuthorization: fixture-");process.stderr.write("Owner pass");setTimeout(()=>{process.stdout.write("auth-value\\nhttps://user:pass@example.invalid/path\\n");process.stderr.write("word: fixture-secret-split-across-chunks");},60);},60);`);
  await jobs.runLogged(job,installDir,process.execPath,[writer],{env:cleanEnv()},[credential,auth]);
  const durable=fs.readFileSync(jobs.jobFile(installDir,id),"utf8");
  for(const value of [credential,auth,"user:pass","fixture-secret-","split-across-chunks"])assert(!durable.includes(value),"durable journal must redact cross-chunk credential "+value);
  assert.match(durable,/\[secret\]|\[configured\]|\[credentials\]/);
  assert.equal(jobs.readJob(installDir,id).lines.length,4);
  console.log("PASS: stdout/stderr credential chunks and final partial lines are redacted in durable JSON.");
}
async function testSetupHttp(root) {
  const packageRoot=path.join(root,"package"), scriptDir=path.join(packageRoot,"scripts","windows"), installDir=path.join(root,"install");
  fs.mkdirSync(scriptDir,{recursive:true});fs.mkdirSync(installDir,{recursive:true});
  for(const file of ["devspace-stack-setup.cjs","devspace-stack-setup.html","stack-jobs.cjs","stack-operation.ps1","stack-management.cjs","stack-setup-apply.cjs","stack-apply-parameters.ps1"])
    fs.copyFileSync(path.join(__dirname,file),path.join(scriptDir,file));
  fs.writeFileSync(path.join(packageRoot,"package.json"),JSON.stringify({name:"fixture-stack",version:"1.0.0"}));
  fs.mkdirSync(path.join(packageRoot,"dist"),{recursive:true});
  fs.writeFileSync(path.join(packageRoot,"dist","cli.js"),'console.log("fixture help");');
  const applyContacted=path.join(root,"apply-started"), applyGate=path.join(root,"apply-release");
  fs.writeFileSync(path.join(scriptDir,"install-devspace-watchdog.ps1"),`param([string]$InstallDir,[string]$CliPath,[string]$NodePath,[string]$PublicBaseUrl,[string]$MachineName,[string]$McpNameSuffix,[string]$ManagementPackageRoot,[string]$TaskLauncher,[string[]]$Components,[switch]$InstallWatchdogTray,[switch]$NoLegacyPoller,[switch]$UserMode,[switch]$NoElevate,[switch]$InstallTools,[switch]$FullAccess,[string[]]$HermesAllowedRoots,[string]$NgrokEndpointMode,[string]$HermesDir,[string]$NgrokAgentBaseUrl,[switch]$SkipNpmInstall,[switch]$SkipHermesInstall)
$ErrorActionPreference='Stop'
[IO.File]::WriteAllText($env:STACK_APPLY_CONTACTED,'started')
while(-not [IO.File]::Exists($env:STACK_APPLY_GATE)){Start-Sleep -Milliseconds 30}
[IO.File]::WriteAllText((Join-Path $InstallDir 'apply-succeeded.txt'),($CliPath+'|'+$MachineName))`);
  const gate=path.join(root,"release-remote-check"), contacted=path.join(root,"remote-check-started"), preload=path.join(root,"offline-preload.cjs");  fs.writeFileSync(preload,`const fs=require("node:fs");globalThis.fetch=async()=>{fs.writeFileSync(process.env.STACK_TEST_CONTACTED,"fixture only");const until=Date.now()+20000;while(!fs.existsSync(process.env.STACK_TEST_GATE)&&Date.now()<until)await new Promise(r=>setTimeout(r,30));throw Error("offline fixture: no external network");};`);
const env=cleanEnv({NODE_OPTIONS:'--require "'+preload.replaceAll("\\","/")+'"',DEVSPACE_STACK_PACKAGE_ROOT:packageRoot,STACK_TEST_GATE:gate,STACK_TEST_CONTACTED:contacted,STACK_APPLY_GATE:applyGate,STACK_APPLY_CONTACTED:applyContacted,USERPROFILE:root,LOCALAPPDATA:path.join(root,"local"),PATH:path.dirname(process.execPath)});
  const setup=path.join(scriptDir,"devspace-stack-setup.cjs");
  const lockProbe=path.join(root,"probe-operation.ps1");
  fs.writeFileSync(lockProbe,"param($Helper,$Root) . $Helper; @{busy=(Test-StackOperationBusy $Root)} | ConvertTo-Json -Compress");
  const operationBusy=()=>{
    const result=runPs(lockProbe,["-Helper",path.join(scriptDir,"stack-operation.ps1"),"-Root",installDir],cleanEnv());
    assert.equal(result.status,0,result.stderr);
    return JSON.parse(result.stdout).busy;
  };
  let server, jobId;
  const failures=[];
  try {
    server=await startServer(setup,installDir,env);
    await until(async()=>{const r=await request(server.base,"/api/components");return r.data?.components?.length===12},"real read-only local inventory");
    const initialStatus=await request(server.base,"/api/status");
    fs.rmSync(applyContacted,{force:true}); fs.rmSync(applyGate,{force:true});
    const applyResponse=await request(server.base,"/api/apply",{method:"POST",token:server.token,body:{requestId:"setup-apply-fixture",configurationFingerprint:initialStatus.data.configurationFingerprint,installDevspace:true,installHermes:false,machineName:"fixture-machine",endpointMode:"AgentEndpoint",publicDomain:"https://fixture.example.invalid",allowedRoots:root,fullAccess:false,installTools:false,installTray:true,noLegacyPoller:false,userMode:true}});
    assert.equal(applyResponse.status,202,applyResponse.text); const applyJobId=applyResponse.data.jobId;
    await until(()=>{
      if(fs.existsSync(applyContacted))return true;
      const current=jobs.readJob(installDir,applyJobId);
      if(["failed","rollback_failed"].includes(current?.phase))throw Error("Apply worker failed before fixture installer: "+(current.error||JSON.stringify(current.lines?.slice(-3))));
      return false;
    },"valid apply worker reaches fixture installer");
    await closeServer(server.child); server=await startServer(setup,installDir,env);
    assert.equal((await request(server.base,"/api/status")).data.activeJobId,applyJobId,"Setup restart discovers active apply worker");
    fs.writeFileSync(applyGate,"release apply fixture");
    await until(()=>["completed","failed","rollback_failed"].includes(jobs.readJob(installDir,applyJobId)?.phase),"apply worker completion");
    assert.equal(jobs.readJob(installDir,applyJobId).phase,"completed");
    assert.equal(fs.existsSync(path.join(installDir,"apply-succeeded.txt")),true,"real /api/apply completed through the durable worker");
    await until(()=>!operationBusy(),"apply supervisor releases ownership");
    console.log("PASS: valid /api/apply survives Setup restart and completes through the durable worker.");
    for(const route of ["/api/components/refresh","/api/components/action","/api/apply"]) {
      let response=await request(server.base,route,{method:"POST",body:{},token:"wrong"});
      assert.equal(response.status,400,"unauthorized mutation "+route);
      assert.match(response.text,/Invalid setup token/);
      response=await request(server.base,route,{method:"POST",body:{},token:server.token,headers:{origin:"https://other.invalid"}});
      assert.equal(response.status,400);assert.match(response.text,/Invalid Origin/);
    }
    const wrongHost=await request(server.base,"/api/components",{headers:{host:"attacker.invalid"}});
    assert.equal(wrongHost.status,403);
    const before=Date.now();
    const launch=await request(server.base,"/api/components/refresh",{method:"POST",token:server.token,body:{requestId:"refresh-fixture"}});
    const launchMs=Date.now()-before;
    const jobDirectory=path.join(installDir,"stack-management","jobs");
    const launchEvidence=launch.status===202?"":fs.existsSync(jobDirectory)?fs.readdirSync(jobDirectory).filter(file=>/^[a-f0-9]{24}\.json$/.test(file)).map(file=>fs.readFileSync(path.join(jobDirectory,file),"utf8")).join("\n"):"no durable job";
    assert.equal(launch.status,202,launch.text+" "+launchEvidence);jobId=launch.data.jobId;
    assert(launchMs<6000,"202 returns before gated remote work can finish");
    assert(!fs.existsSync(gate));
    await until(()=>fs.existsSync(contacted),"worker reaches controlled remote fixture");
    assert.equal(jobs.readJob(installDir,jobId).phase,"running");
    const leaseRecord=JSON.parse(fs.readFileSync(path.join(installDir,"stack-management","operation.lock"),"utf8"));
    assert(leaseRecord.pid&&leaseRecord.token,"real PowerShell supervisor owns live lock");
    const privateOwner=jobs.readJson(path.join(installDir,"stack-management","jobs",jobId+".owner.json"));
    assert(privateOwner?.token,"supervisor wrote private participant proof");
    for(const route of ["/api/status","/api/components","/api/job?id="+jobId]) {
      const visible=await request(server.base,route);
      assert(!visible.text.includes(privateOwner.token),"owner token must not appear in "+route);
    }
    assert.equal((await request(server.base,"/api/job?id="+jobId+".owner")).status,400,"job API rejects private owner suffix");
    assert.equal((await request(server.base,"/stack-management/jobs/"+jobId+".owner.json")).status,404,"private owner file is not served");
    const cachedStart=Date.now();
    const cached=await request(server.base,"/api/components");
    const cachedMs=Date.now()-cachedStart;
    assert.equal(cached.status,200);assert.equal(cached.data.components.length,12);assert.equal(cached.data.refreshing,true);
    assert(cachedMs<1000,"cached GET stays responsive during remote check");
    const duplicate=await request(server.base,"/api/components/refresh",{method:"POST",token:server.token,body:{requestId:"refresh-fixture"}});
    assert.equal(duplicate.status,202);assert.equal(duplicate.data.jobId,jobId,"duplicate request reuses running job");
    const parallel=await request(server.base,"/api/components/refresh",{method:"POST",token:server.token,body:{requestId:"different-fixture"}});
    assert.equal(parallel.status,409);assert.equal(parallel.data.jobId,jobId);
    fs.writeFileSync(gate,"release first fixture");
    await until(()=>["completed","failed","rollback_failed"].includes(jobs.readJob(installDir,jobId)?.phase),"first refresh completion");
    assert.equal(jobs.readJob(installDir,jobId).phase,"completed");
    await until(()=>!operationBusy(),"first supervisor releases ownership");
    // Two matching submissions before supervisor readiness must still represent one operation.
    fs.unlinkSync(gate);fs.unlinkSync(contacted);
    const concurrent=await Promise.all([1,2].map(()=>request(server.base,"/api/components/refresh",{method:"POST",token:server.token,body:{requestId:"simultaneous-fixture"}})));
    const accepted=concurrent.filter(r=>r.status===202);
    if(accepted.length)jobId=accepted[0].data.jobId;
    if(!concurrent.every(r=>r.status===202&&r.data.jobId===jobId))failures.push("Simultaneous identical request IDs must both return 202 and the same job: "+JSON.stringify(concurrent.map(r=>({status:r.status,data:r.data}))));
    assert.equal(failures.length,0,failures.join("\n"));
    await until(()=>fs.existsSync(contacted),"concurrent fixture begins gated remote check");
    console.log(`PASS: async refresh 202 in ${launchMs}ms, cached GET in ${cachedMs}ms; active/simultaneous duplicate IDs and busy rejection.`);
    await closeServer(server.child);
    server=await startServer(setup,installDir,env);
    const reconnected=await request(server.base,"/api/status");
    assert.equal(reconnected.data.activeJobId,jobId,"restarted Setup discovers surviving job");
    const active=await request(server.base,"/api/job?id="+jobId);
    assert.equal(active.status,200);assert.equal(active.data.phase,"running");
    assert.equal(operationBusy(),true,"surviving worker remains exclusively reserved after Setup exits");
    fs.writeFileSync(gate,"release read-only remote fixture");
    await until(()=>["completed","failed","rollback_failed"].includes(jobs.readJob(installDir,jobId)?.phase),"surviving refresh worker completion");
    const finished=await request(server.base,"/api/job?id="+jobId);
    assert.equal(finished.data.phase,"completed",finished.text);
    assert.equal(finished.data.exitCode,0);
    await until(()=>!operationBusy(),"supervisor releases ownership");
    console.log("PASS: authenticated HTTP 202, responsive cached GET, duplicate/busy jobs, and durable worker across Setup restart.");

  } finally {
    fs.writeFileSync(gate,"always release only fixture workers");
    if(jobId)await until(()=>["completed","failed","rollback_failed"].includes(jobs.readJob(installDir,jobId)?.phase),"fixture worker cleanup").catch(()=>{});
    if(server)await closeServer(server.child);
    await until(()=>!operationBusy(),"fixture supervisor graceful cleanup").catch(()=>{});
  }
}
(async()=>{
  assert.equal(process.platform,"win32","Windows FileShare integration test");
  const root=fs.mkdtempSync(path.join(os.tmpdir(),"devspace-stack-jobs-test-"));
  try {
    const part=process.argv[2]||"all";
    assert(["all","leases","redaction","http"].includes(part),"unknown test part");
    if(["all","leases"].includes(part))await testLeases(root,path.join(__dirname,"stack-operation.ps1"));
    if(["all","redaction"].includes(part))await testRedaction(root);
    if(["all","http"].includes(part))await testSetupHttp(root);
    console.log("stack jobs integration tests passed; only temporary servers, workers and read-only local discovery ran.");
  } finally {
    const resolved=path.resolve(root), parent=path.resolve(os.tmpdir())+path.sep;
    assert(resolved.startsWith(parent)&&path.basename(resolved).startsWith("devspace-stack-jobs-test-"));
    fs.rmSync(resolved,{recursive:true,force:true,maxRetries:20,retryDelay:100});
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
