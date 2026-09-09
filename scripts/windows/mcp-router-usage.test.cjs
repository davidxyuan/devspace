const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");
const { once } = require("node:events");

(async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "devspace-router-usage-"));
  const configPath = path.join(root, "config.json"), usagePath = path.join(root, "router-request-usage.json");
  const backend = http.createServer((req, res) => res.end("ok"));
  backend.listen(0, "127.0.0.1"); await once(backend, "listening");
  const reservation = http.createServer(); reservation.listen(0, "127.0.0.1"); await once(reservation, "listening");
  const port = reservation.address().port; await new Promise(resolve => reservation.close(resolve));
  const config = { stateDir:root, machineSlug:"usage", routerPort:port, port:backend.address().port, hermesEnabled:true, hermesPort:backend.address().port, publicBaseUrl:"https://usage.invalid" };
  let child;
  const request = (route, headers = {}) => new Promise((resolve, reject) => {
    const req = http.get({host:"127.0.0.1",port,path:route,headers,agent:false}, res => {
      let body = ""; res.setEncoding("utf8"); res.on("data", chunk => body += chunk); res.on("end", () => resolve(body));
    });
    req.setTimeout(3000, () => req.destroy(new Error("request timed out"))); req.on("error", reject);
  });
  const usage = async () => JSON.parse(await request("/__router/status")).connections.usage;
  async function stop() { if (child && child.exitCode === null) { const closed = once(child,"close"); child.kill(); await closed; } child = null; }
  async function start() {
    fs.writeFileSync(configPath, JSON.stringify(config));
    child = spawn(process.execPath, [path.join(__dirname,"mcp-router.cjs"),configPath], {windowsHide:true,stdio:["ignore","pipe","pipe"]});
    await new Promise((resolve,reject) => {
      const timer = setTimeout(() => reject(Error("router did not start")),5000);
      child.once("error", error => {clearTimeout(timer);reject(error);});
      child.once("exit", code => {clearTimeout(timer);reject(Error(`router exited ${code}`));});
      child.stdout.on("data", data => {if(String(data).includes("listening")){clearTimeout(timer);resolve();}});
    });
  }
  try {
    await start();
    const domain = {host:"usage.invalid"};
    await request("/usage/devspace_chatgpt/mcp",domain);
    await request("/usage/devspace_chatgpt/mcp?session=test",domain);
    await request("/usage/hermes_chatgpt/mcp",{"x-forwarded-host":"usage.invalid"});
    await request("/usage/devspace_chatgpt/mcp",{...domain,"user-agent":"DevSpace-Watchdog/1.0"});
    await request("/usage/devspace_chatgpt/authorize",domain);
    await request("/unknown",domain);
    await request("/usage/devspace_chatgpt/mcp");
    const expected = {devspace:2,hermes:1,watchdog:1,other:2,localOrUnknown:1,total:6};
    let state = await usage();
    for(const counts of Object.values(state.periods)) assert.deepEqual(counts,expected);
    assert.deepEqual((await usage()).periods.today,expected,"status polling must not inflate usage");
    assert(state.savedAt && !state.error);
    await stop(); await start();
    state = await usage(); assert.deepEqual(state.periods.today,expected,"history survives restart");
    assert.equal(state.periods.sinceStart.total,0,"process counters restart independently");

    await stop(); config.publicBaseUrl="https://second.invalid"; await start();
    assert.equal((await usage()).periods.today.total,0,"new domain does not inherit old usage");
    await request("/usage/devspace_chatgpt/mcp",{host:"second.invalid"});
    assert.equal((await usage()).periods.today.total,1);
    await stop(); config.publicBaseUrl="https://usage.invalid";
    const saved=JSON.parse(fs.readFileSync(usagePath,"utf8")), zero={devspace:0,hermes:0,watchdog:0,other:0,localOrUnknown:0};
    const past=new Date(); past.setDate(past.getDate()-63);
    saved.buckets.push({minute:Math.floor(past.getTime()/60000),day:"2000-01-01",domain:config.publicBaseUrl,counts:{...zero,devspace:99}});
    const yesterday=new Date(); yesterday.setDate(yesterday.getDate()-2);
    const day=`${yesterday.getFullYear()}-${String(yesterday.getMonth()+1).padStart(2,"0")}-${String(yesterday.getDate()).padStart(2,"0")}`;
    saved.buckets.push({minute:Math.floor(yesterday.getTime()/60000),day,domain:config.publicBaseUrl,counts:{...zero,devspace:7}});
    fs.writeFileSync(usagePath,JSON.stringify(saved)); await start();
    state=await usage(); assert.deepEqual(state.periods.today,expected); assert.deepEqual(state.periods.last24Hours,expected);
    const sameMonth = yesterday.getMonth() === new Date().getMonth();
    assert.equal(state.periods.thisMonth.total,6+(sameMonth?7:0),"calendar month aggregation");
    assert(!JSON.parse(fs.readFileSync(usagePath,"utf8")).buckets.some(b=>b.day==="2000-01-01"),"expired history pruned");

    const history=fs.readFileSync(usagePath); fs.unlinkSync(usagePath); fs.mkdirSync(usagePath);
    await request("/usage/devspace_chatgpt/mcp",domain);
    assert.match((await usage()).error,/could not be saved/);
    fs.rmdirSync(usagePath); fs.writeFileSync(usagePath,history);
    state=await usage(); assert.equal(state.error,null); assert.equal(state.periods.today.total,7,"write retry retains unsaved counts");
    await stop(); fs.writeFileSync(usagePath,"{broken history"); await start();
    state=await usage(); assert.match(state.error,/preserved/); assert.equal(state.persistenceEnabled,false);
    await request("/usage/devspace_chatgpt/mcp",domain); await usage();
    assert.equal(fs.readFileSync(usagePath,"utf8"),"{broken history","corruption must not be silently replaced with zeros");
    console.log("PASS: Router request usage classification, restart/domain isolation, calendar windows, retention, write recovery and corrupt-history preservation.");
  } finally {
    await stop(); await new Promise(resolve=>backend.close(resolve));
    assert(path.resolve(root).startsWith(path.resolve(os.tmpdir())+path.sep) && path.basename(root).startsWith("devspace-router-usage-"));
    fs.rmSync(root,{recursive:true,force:true});
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
