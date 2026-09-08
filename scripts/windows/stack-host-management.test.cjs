"use strict";
const assert=require("node:assert/strict");
const fs=require("node:fs");
const path=require("node:path");
const os=require("node:os");
const http=require("node:http");
const {spawn}=require("node:child_process");
const jobs=require("./stack-jobs.cjs");
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(check,label,timeout=18000){const end=Date.now()+timeout;while(Date.now()<end){const result=await check();if(result)return result;await pause(40)}throw Error("Timed out: "+label)}
function request(base,route,method="GET",body){
  return new Promise((resolve,reject)=>{
    const text=body===undefined?"":JSON.stringify(body),req=http.request(new URL(route,base),{method,headers:{"content-type":"application/json","content-length":Buffer.byteLength(text)}},res=>{
      let value="";res.setEncoding("utf8");res.on("data",chunk=>value+=chunk);res.on("end",()=>{let data;try{data=JSON.parse(value)}catch{}resolve({status:res.statusCode,text:value,data})});
    });
    req.setTimeout(14000,()=>req.destroy(Error("fixture proxy request timeout")));
    req.on("error",error=>reject(new Error(method+" "+route+": "+error.message)));req.end(text);
  });
}
async function main(){
  assert.equal(process.platform,"win32");
  const root=fs.mkdtempSync(path.join(os.tmpdir(),"devspace-host-proxy-test-")),packageRoot=path.resolve(__dirname,"..",".."),installDir=path.join(root,"install");
  fs.mkdirSync(installDir,{recursive:true});
  const endpointPath=path.join(installDir,"stack-management","endpoint.json");
  const gate=path.join(root,"release-network"),contacted=path.join(root,"network-started"),owned=path.join(root,"owned-managers"),listenerEvidence=path.join(root,"listeners.jsonl");
  const preload=path.join(root,"fixture-preload.cjs"),hostReady=path.join(root,"host-ready.json"),hostStop=path.join(root,"host-stop"),harness=path.join(root,"host-harness.ps1");
  fs.writeFileSync(preload,`const fs=require("node:fs"),path=require("node:path");globalThis.fetch=async()=>{fs.writeFileSync(process.env.STACK_HOST_CONTACTED,"no external network");const end=Date.now()+20000;while(!fs.existsSync(process.env.STACK_HOST_GATE)&&Date.now()<end)await new Promise(r=>setTimeout(r,30));throw Error("controlled offline fixture")};if(process.argv[1]?.endsWith("devspace-stack-setup.cjs")&&!process.argv.includes("--worker")){const net=require("node:net"),listen=net.Server.prototype.listen;net.Server.prototype.listen=function(...args){this.once("listening",()=>fs.appendFileSync(process.env.STACK_HOST_LISTENERS,JSON.stringify({pid:process.pid,address:this.address()})+"\\n"));return listen.apply(this,args)};fs.appendFileSync(process.env.STACK_HOST_OWNED,String(process.pid)+"\\n");setInterval(()=>{if(fs.existsSync(path.join(process.env.STACK_HOST_ROOT,"stop-"+process.pid)))process.exit(0)},50).unref()}`);
  const env={...process.env,NODE_OPTIONS:'--require "'+preload.replaceAll("\\","/")+'"',DEVSPACE_STACK_PACKAGE_ROOT:packageRoot,USERPROFILE:root,LOCALAPPDATA:path.join(root,"local"),PATH:path.dirname(process.execPath),STACK_HOST_ROOT:root,STACK_HOST_GATE:gate,STACK_HOST_CONTACTED:contacted,STACK_HOST_OWNED:owned,STACK_HOST_LISTENERS:listenerEvidence};
  delete env.DEVSPACE_STACK_OPERATION_TOKEN;delete env.DEVSPACE_STACK_JOB_ID;
  fs.writeFileSync(harness,`param($Root,$PackageRoot,$NodePath,$ReadyPath,$StopPath)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
function Import-Functions($File,$Names) {
  $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($File,[ref]$null,[ref]$errors)
  if($errors.Count){throw $errors[0].Message}
  foreach($name in $Names) {
    $definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if(-not $definition){throw "Missing fixture dependency $name"}
    # Function imports are the only execution from the full production Host.
    . ([scriptblock]::Create($definition.Extent.Text.Replace("function $name", "function script:$name")))
  }
}
$windows=Join-Path $PackageRoot 'scripts\\windows'
Import-Functions (Join-Path $windows 'watchdog-control-core.ps1') @('Read-WatchdogJson','Get-WatchdogProperty')
Import-Functions (Join-Path $windows 'devspace-watchdog-tray.ps1') @('Read-LoopbackHttpRequest','Write-LoopbackHttpResponse','Write-ControlJson')
$ConfigPath=Join-Path $Root 'devspace-watchdog.config.json'
$script:config=[pscustomobject]@{nodePath=$NodePath;managementPackageRoot=$PackageRoot;cliPath=(Join-Path $PackageRoot 'dist\\cli.js')}
. (Join-Path $windows 'stack-host-management.ps1')
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
$listener.Start()
[IO.File]::WriteAllText($ReadyPath,(@{port=$listener.LocalEndpoint.Port;pid=$PID}|ConvertTo-Json -Compress))
$ticks=0;$deadline=[DateTimeOffset]::UtcNow.AddSeconds(100)
try {
  while(-not [IO.File]::Exists($StopPath) -and [DateTimeOffset]::UtcNow -lt $deadline) {
    $ticks++
    Complete-StackManagementProxies
    if($listener.Pending()) {
      $client=$listener.AcceptTcpClient();$deferred=$false
      try {
        $request=Read-LoopbackHttpRequest $client
        if($request.path -eq '/fixture/status') {Write-ControlJson $request.stream 200 @{ticks=$ticks;inventory=(Get-CachedStackInventory);activeProxyCount=$script:componentProxies.Count}}
        else {$deferred=[bool](Start-StackManagementProxy $request)}
      } catch {try {Write-ControlJson $client.GetStream() 500 @{error=$_.Exception.Message}}catch{}}
      finally {if(-not $deferred){$client.Dispose()}}
    }
    Start-Sleep -Milliseconds 10
  }
} finally {
  $listener.Stop()
  $end=[DateTimeOffset]::UtcNow.AddSeconds(10)
  while($script:componentProxies.Count -gt 0 -and [DateTimeOffset]::UtcNow -lt $end){Complete-StackManagementProxies;Start-Sleep -Milliseconds 20}
}
`);
  let manager,host,fake,heldResponse,jobId,portBlocker,blockedPort;
  let hostErrors="",managerError="",managerOutput="",fakeMode="delay",fakeRequests=[];
  function managerPids(){return fs.existsSync(owned)?fs.readFileSync(owned,"utf8").trim().split(/\s+/).filter(Boolean).map(Number):[]}
  async function stopManager(pid){fs.writeFileSync(path.join(root,"stop-"+pid),"stop this fixture manager");await until(()=>{try{process.kill(pid,0);return false}catch(e){return e.code==="ESRCH"}},"fixture manager cooperative exit")}
  try{
    // Hold one free preferred port to exercise the real EADDRINUSE fallback.
    // Already occupied listeners belong to other processes and are left untouched.
    for(let port=8788;port<=8794;port++){
      const candidate=http.createServer((_req,res)=>{res.writeHead(503);res.end("fixture port reservation")});
      const bound=await new Promise((resolve,reject)=>{candidate.once("error",error=>error.code==="EADDRINUSE"?resolve(false):reject(error));candidate.listen(port,"127.0.0.1",()=>resolve(true))});
      if(bound){portBlocker=candidate;blockedPort=port;break}
    }
    assert(portBlocker,"one preferred Setup port is available for isolated reservation");
    const script=path.join(__dirname,"devspace-stack-setup.cjs");
    manager=spawn(process.execPath,[script,"--no-open","--install-dir",installDir],{windowsHide:true,env,stdio:["ignore","pipe","pipe"]});
    manager.stderr.on("data",chunk=>managerError+=chunk);manager.stdout.on("data",chunk=>managerOutput+=chunk);
    await until(()=>{if(manager.exitCode!==null)throw Error(managerError);return jobs.readJson(endpointPath)},"temporary Setup endpoint");
    const initialEndpoint=jobs.readJson(endpointPath),managerBase="http://127.0.0.1:"+initialEndpoint.port+"/";
    assert.equal(initialEndpoint.pid,manager.pid,"endpoint belongs to the initial test manager");
    assert.notEqual(initialEndpoint.port,blockedPort,"manager skips the occupied preferred port");
    const boundListeners=fs.readFileSync(listenerEvidence,"utf8").trim().split("\n").map(line=>JSON.parse(line));
    assert(boundListeners.some(item=>item.pid===manager.pid&&item.address.port===initialEndpoint.port),"advertised port must match an actual listening socket");
    await until(async()=>{const result=await request(managerBase,"/api/components");return result.data?.components?.length===12},"initial read-only inventory");
    await new Promise(resolve=>portBlocker.close(resolve));portBlocker=null;
    const ps=path.join(process.env.SystemRoot||"C:\\Windows","System32","WindowsPowerShell","v1.0","powershell.exe");
    host=spawn(ps,["-NoLogo","-NoProfile","-NonInteractive","-File",harness,"-Root",installDir,"-PackageRoot",packageRoot,"-NodePath",process.execPath,"-ReadyPath",hostReady,"-StopPath",hostStop],{windowsHide:true,env,stdio:["ignore","pipe","pipe"]});
    host.stderr.on("data",chunk=>hostErrors+=chunk);
    await until(()=>{if(host.exitCode!==null)throw Error("Host harness: "+hostErrors);return jobs.readJson(hostReady)},"isolated Host proxy listener");
    const proxyBase="http://127.0.0.1:"+jobs.readJson(hostReady).port+"/";
    let response=await request(proxyBase,"/api/components");
    assert.equal(response.status,200,response.text);assert.equal(response.data.components.length,12,"actual GET is forwarded through real PowerShell runspace");
    fake=http.createServer((req,res)=>{
      fakeRequests.push({method:req.method,path:req.url});
      const send=value=>{res.writeHead(200,{"content-type":"application/json; charset=utf-8"});res.end(JSON.stringify(value))};
      if(req.url==="/api/status")send({installDir,packageRoot:fakeMode==="mismatch"?path.join(root,"wrong-package"):packageRoot});
      else if(fakeMode==="error"){res.writeHead(400,{"content-type":"application/json"});res.end(JSON.stringify({error:"Preview requires Cloud Endpoint"}));}
      else if(fakeMode==="delay")heldResponse=()=>send({schemaVersion:1,revision:"delayed-fixture",components:[]});
      else send({wrongManager:true});
    });
    await new Promise(resolve=>fake.listen(0,"127.0.0.1",resolve));
    jobs.writeJson(endpointPath,{installDir,port:fake.address().port,token:"fake-local-token",pid:process.pid});
    const delayed=request(proxyBase,"/api/components");
    await until(()=>heldResponse,"proxy awaiting delayed response");
    const first=await request(proxyBase,"/fixture/status");
    await pause(180);
    const started=Date.now(),second=await request(proxyBase,"/fixture/status"),cachedMs=Date.now()-started;
    assert.equal(second.status,200);assert.equal(second.data.inventory.components.length,12);
    assert(second.data.ticks-first.data.ticks>=5,"Host loop keeps pumping during slow proxy request");
    assert.equal(second.data.activeProxyCount,1);
    assert(cachedMs<750,"cached Host response remains responsive");
    heldResponse();heldResponse=null;
    response=await delayed;assert.equal(response.status,200,response.text);assert.equal(response.data.revision,"delayed-fixture");
    console.log(`PASS: real async proxy GET and cached Host loop response in ${cachedMs}ms during blocked remote response.`);
    fakeMode="error";
    response=await request(proxyBase,"/api/components");
    assert.equal(response.status,400);assert.equal(response.data.error,"Preview requires Cloud Endpoint","manager rejection body survives PowerShell error stream consumption");

    await stopManager(manager.pid);
    fakeMode="mismatch";fakeRequests=[];
    jobs.writeJson(endpointPath,{installDir,port:fake.address().port,token:"fake-local-token",pid:process.pid});
    response=await request(proxyBase,"/api/components");
    assert.equal(response.status,200,response.text);assert.equal(response.data.components.length,12,"identity mismatch launches correct configured package");
    assert(fakeRequests.length>0&&fakeRequests.every(r=>r.path==="/api/status"),"mismatched manager never receives requested component operation");
    const recovered=jobs.readJson(endpointPath);
    assert.notEqual(recovered.port,fake.address().port);assert(managerPids().includes(recovered.pid));
    const actualStatus=await request("http://127.0.0.1:"+recovered.port+"/","/api/status");
    assert.equal(path.resolve(actualStatus.data.installDir),installDir);assert.equal(path.resolve(actualStatus.data.packageRoot),packageRoot);
    response=await request(proxyBase,"/api/components/refresh","POST",{requestId:"host-proxy-refresh-fixture"});
    assert.equal(response.status,202,response.text);jobId=response.data.jobId;
    await until(()=>fs.existsSync(contacted),"actual refresh worker reaches offline fixture");
    const statusDuringWork=await request(proxyBase,"/fixture/status");assert.equal(statusDuringWork.status,200);
    response=await request(proxyBase,"/api/job?id="+jobId);
    assert.equal(response.status,200,response.text);assert.equal(response.data.phase,"running");
    fs.writeFileSync(gate,"release fixture-only refresh");
    await until(()=>["completed","failed","rollback_failed"].includes(jobs.readJob(installDir,jobId)?.phase),"proxied refresh completion");
    assert.equal(jobs.readJob(installDir,jobId).phase,"completed");
    console.log("PASS: mismatched manager receives only identity probe; configured package starts; actual POST returns 202 and GET job reconnects.");
  } catch(error) {
    if(hostErrors)error.message+="; Host harness: "+hostErrors;
    error.message+="; manager exit="+manager?.exitCode+" signal="+manager?.signalCode+" stderr="+managerError+" stdout="+managerOutput;
    if(fs.existsSync(listenerEvidence))error.message+="; listeners="+fs.readFileSync(listenerEvidence,"utf8");
    throw error;
  } finally {
    fs.writeFileSync(gate,"always release fixture worker");
    if(heldResponse){heldResponse();heldResponse=null}
    if(jobId)await until(()=>["completed","failed","rollback_failed"].includes(jobs.readJob(installDir,jobId)?.phase),"fixture job cleanup").catch(()=>{});
    fs.writeFileSync(hostStop,"stop isolated harness");
    if(host)await until(()=>host.exitCode!==null,"Host harness graceful exit").catch(()=>{});
    for(const pid of managerPids())await stopManager(pid).catch(()=>{});
    if(fake)await new Promise(resolve=>fake.close(resolve));
    if(portBlocker)await new Promise(resolve=>portBlocker.close(resolve));
    const resolved=path.resolve(root),parent=path.resolve(os.tmpdir())+path.sep;
    assert(resolved.startsWith(parent)&&path.basename(resolved).startsWith("devspace-host-proxy-test-"));
    fs.rmSync(resolved,{recursive:true,force:true,maxRetries:20,retryDelay:100});
  }
  console.log("Host management proxy integration passed; only isolated loopback managers/harness and read-only refresh ran.");
}
main().catch(error=>{console.error(error);process.exitCode=1});
