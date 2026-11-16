import assert from 'node:assert/strict';
import http from 'node:http';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
const root=process.cwd();
const world=JSON.parse(readFileSync(root+'/.live-validation/pi-world.json','utf8'));
const home=world.home, agentDir=root+'/.live-validation/pi-agent';
mkdirSync(agentDir,{recursive:true});
process.env.PI_CODING_AGENT_DIR=agentDir;
process.env.PI_OFFLINE='1';process.env.PI_TELEMETRY='0';
for(const k of Object.keys(process.env)) if(k.startsWith('FM_')||k.startsWith('TASKS_AXI_')) delete process.env[k];
process.env.FM_HOME=home;process.env.FM_ROOT_OVERRIDE=root;
let requests=0;
const server=http.createServer(async(req,res)=>{
 let raw='';for await(const data of req)raw+=data;
 const body=JSON.parse(raw);requests++;
 console.log('Local provider request', requests, 'tools:', (body.tools??[]).map(t=>t.function.name).join(','));
 const toolDone=(body.messages??[]).some(m=>m.role==='tool');
 const delta=toolDone?{content:'Synthetic branch report recorded.'}:{tool_calls:[{index:0,id:'synthetic-report-'+requests,type:'function',function:{name:'fm_branch_report',arguments:JSON.stringify({task:'task',verdict:'captain',summary:'synthetic secret @everyone must stay local',notice:'decision'})}}]};
 res.writeHead(200,{'content-type':'text/event-stream'});
 res.write('data: '+JSON.stringify({id:'chatcmpl-local-'+requests,object:'chat.completion.chunk',created:Math.floor(Date.now()/1000),model:'synthetic',choices:[{index:0,delta:{role:'assistant',...delta},finish_reason:null}]})+'\n\n');
 res.write('data: '+JSON.stringify({id:'chatcmpl-local-'+requests,object:'chat.completion.chunk',created:Math.floor(Date.now()/1000),model:'synthetic',choices:[{index:0,delta:{},finish_reason:toolDone?'stop':'tool_calls'}]})+'\n\n');
 res.end('data: [DONE]\n\n');
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
writeFileSync(agentDir+'/models.json',JSON.stringify({providers:{'away-local':{baseUrl:`http://127.0.0.1:${server.address().port}/v1`,api:'openai-completions',apiKey:'synthetic-local-only',models:[{id:'synthetic',name:'Synthetic local tool calls',reasoning:false,input:['text'],contextWindow:128000,maxTokens:4096,cost:{input:0,output:0,cacheRead:0,cacheWrite:0}}]}}}));
writeFileSync(home+'/config/supervision-branch-model','away-local/synthetic\n');
writeFileSync(home+'/state/.lock',String(process.pid)+'\n');
writeFileSync(home+'/state/.wake-queue','1\t1\theartbeat\theartbeat\theartbeat: synthetic local decision\n');
const sdk=await import('~/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/index.js');
let session;
try{
 let api;
 const runtime=await sdk.ModelRuntime.create({authPath:agentDir+'/auth.json',modelsPath:agentDir+'/models.json'});
 const model=runtime.getModel('away-local','synthetic');assert(model);
 const settings=sdk.SettingsManager.inMemory({compaction:{enabled:false},retry:{enabled:false}});
 const loader=new sdk.DefaultResourceLoader({cwd:root,agentDir,noExtensions:true,noSkills:true,noPromptTemplates:true,noThemes:true,noContextFiles:true,additionalExtensionPaths:[root+'/.pi/extensions/fm-branch-supervision.ts'],extensionFactories:[pi=>{api=pi;}]});
 await loader.reload();
 const loaded=loader.getExtensions();console.log('Extension load errors:',JSON.stringify(loaded.errors));assert.equal(loaded.errors.length,0);
 ({session}=await sdk.createAgentSession({cwd:root,agentDir,resourceLoader:loader,sessionManager:sdk.SessionManager.inMemory(root),settingsManager:settings,modelRuntime:runtime,model,thinkingLevel:'off',tools:[]}));
 session.extensionRunner.onError(e=>console.log('EXTENSION ERROR',JSON.stringify(e)));
 await session.bindExtensions({});
 const offer={message:'heartbeat: synthetic local decision',projects:[root],heartbeat:true,eligible:true,accepted:false,settlement:Promise.resolve(),accept(p){this.accepted=true;this.settlement=p;}};
 api.events.emit('fm-branch-supervision:dispatch',offer);
 console.log('Branch offer accepted:',offer.accepted);assert(offer.accepted);
 await Promise.race([offer.settlement,new Promise((_,reject)=>{const timer=setTimeout(()=>reject(new Error('branch timeout')),60000);timer.unref();})]);
 console.log('Real Pi branch settled. Provider request count:',requests);assert(requests>=2);
 const outcomes=readFileSync(home+'/state/branch-outcomes.jsonl','utf8').trim().split('\n').map(JSON.parse);
 console.log('Durable outcomes:',JSON.stringify(outcomes));assert.equal(outcomes.length,1);assert.equal(outcomes[0].summary,'synthetic secret @everyone must stay local');
 const py=spawnSync('python3.14',['-I','-c',`import json,sqlite3; c=sqlite3.connect(${JSON.stringify(world.config.journal)}); print(json.dumps([json.loads(r[0]) for r in c.execute('SELECT body FROM events')]))`],{encoding:'utf8'});
 assert.equal(py.status,0,py.stderr);const events=JSON.parse(py.stdout);console.log('Real parent events:',JSON.stringify(events));assert.equal(events.length,1);assert.equal(events[0].text,'A decision is waiting for the Personal work. Please review it in our usual conversation.');assert(!JSON.stringify(events).includes('secret'));
 console.log('Pi report-tool -> durable outcome -> real adapter -> real parent obligation: confirmed (not delivered).');
} finally {
 if(session){await session.extensionRunner.emit({type:'session_shutdown'});session.dispose();}
 server.closeAllConnections();await new Promise(r=>server.close(r));
}
