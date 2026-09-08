const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),yaml=require('yaml');
const {createCloudPolicy,mergePolicy}=require('./stack-cloud-policy.cjs');
(async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'cloud-policy-test-'));
 try {
 const config={machineSlug:'nt1',ngrokAgentBaseUrl:'https://nt1.internal',publicBaseUrl:'https://example.ngrok.app',ngrokEndpointMode:'CloudEndpoint'};
 fs.writeFileSync(path.join(root,'devspace-watchdog.config.json'),'\uFEFF'+JSON.stringify(config));
 let remote={id:'ep_test',type:'cloud',url:config.publicBaseUrl,traffic_policy:'on_http_request:\n  - name: other station\n    actions: []\n'},writes=0;
 const handle=createCloudPolicy(root,async(url,options)=>{if(options.method==='PATCH'){writes++;remote.traffic_policy=JSON.parse(options.body).traffic_policy;}return {ok:true,json:async()=>({...remote})};});
 const input={apiKey:'fixture-key',endpointId:'ep_test'};
 await assert.rejects(handle({...input,previewId:'missing'},true),/Preview/);
 const preview=await handle(input,false);assert.equal(writes,0);
 await handle({...input,previewId:preview.previewId},true);assert.equal(writes,1);
 assert.equal(yaml.parse(remote.traffic_policy).on_http_request[0].name,'other station');
 const authFirst=yaml.parse(mergePolicy('on_http_request:\n  - name: authentication\n    actions:\n      - type: basic-auth\n',config));
 assert.equal(authFirst.on_http_request[0].name,'authentication');
 assert.throws(()=>mergePolicy('on_http_request:\n  - actions:\n      - type: forward-internal\n',config),/catch-all/);
 assert.equal(yaml.parse(mergePolicy(remote.traffic_policy,config)).on_http_request.length,2);
 await assert.rejects(handle({...input,previewId:preview.previewId},true),/Preview/);
 remote.url='https://wrong.ngrok.app';await assert.rejects(handle(input,false),/identity/);
 console.log('Cloud policy: preview, identity, preserved routes, one-time apply and readback passed');
 }finally{fs.rmSync(root,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exitCode=1});
