import {createServer} from 'node:http';
import {readFileSync,writeFileSync,existsSync} from 'node:fs';
import {resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const root=process.cwd(), lab=resolve('.live-validation'), home=`${lab}/home`, agentDir=`${lab}/agent`, cwd=`${lab}/repo`;
const sdk='/Users/ayrton/.local/lib/node_modules/@earendil-works/pi-coding-agent';
process.env.PI_CODING_AGENT_DIR=agentDir;
process.env.FM_HOME=home;
for (const key of ['FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']) delete process.env[key];
process.env.FM_ROOT_OVERRIDE=root;
let requests=0, acknowledge=false;
const server=createServer(async(req,res)=>{
 let body='';for await(const chunk of req) body+=chunk;
 const parsed=JSON.parse(body); requests++;
 console.log(JSON.stringify({httpRequest:requests,path:req.url,messageRoles:parsed.messages.map(m=>m.role)}));
 res.writeHead(200,{'content-type':'text/event-stream'});
 const emit=(delta,finish=null)=>res.write(`data: ${JSON.stringify({id:'isolated-probe',object:'chat.completion.chunk',created:1,model:'probe',choices:[{index:0,delta,finish_reason:finish}]})}\n\n`);
 if(acknowledge){acknowledge=false;emit({role:'assistant',tool_calls:[{index:0,id:'ack-outcome',type:'function',function:{name:'fm_branch_processed',arguments:'{"through":1}'}}]});emit({},'tool_calls');}
 else {emit({role:'assistant',content:'OK'});emit({},'stop');}
 res.end('data: [DONE]\n\n');
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const port=server.address().port;
writeFileSync(`${agentDir}/models.json`,JSON.stringify({providers:{'local-probe':{baseUrl:`http://127.0.0.1:${port}/v1`,api:'openai-completions',apiKey:'disposable-local-only',models:[{id:'probe',name:'probe',contextWindow:32768,maxTokens:256}]}}}));
const {DefaultResourceLoader,ModelRuntime,ModelRegistry,SessionManager,SettingsManager,createAgentSession}=await import(`${sdk}/dist/index.js`);
console.log(JSON.stringify({piVersion:JSON.parse(readFileSync(`${sdk}/package.json`)).version,head:spawnSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).stdout.trim()}));
const events=[],errors=[]; let afkOnProcessing=false;
const settingsManager=SettingsManager.create(cwd,agentDir);
const loader=new DefaultResourceLoader({cwd,agentDir,settingsManager,noExtensions:true,additionalExtensionPaths:[`${cwd}/.pi/extensions/fm-branch-supervision.ts`,`${cwd}/.pi/extensions/fm-primary-pi-watch.ts`],noSkills:true,noThemes:true,noContextFiles:true,noPromptTemplates:true,extensionFactories:[{name:'observe-live-contract',factory(pi){pi.on('before_agent_start',event=>{const row={type:'before_agent_start',messageType:event.messageType,hasPrompt:'prompt' in event,customType:event.message?.customType};events.push(row);console.log(JSON.stringify(row));if(event.message?.customType==='fm-branch-process') acknowledge=true;if(afkOnProcessing&&event.message?.customType==='fm-branch-process') {const entered=spawnSync(`${root}/bin/fm-afk-contract.sh`,['enter','--words','Defer isolated outcome delivery while away'],{env:process.env,encoding:'utf8'});assert.equal(entered.status,0,entered.stderr);} });}}]});
let session;
try {
 await loader.reload();
 const loaded=loader.getExtensions(); console.log(JSON.stringify({extensionErrors:loaded.errors,extensions:loaded.extensions.map(x=>x.path)})); assert.equal(loaded.errors.length,0);
 const modelRuntime=await ModelRuntime.create({authPath:`${agentDir}/auth.json`,modelsPath:`${agentDir}/models.json`});
 const registry=new ModelRegistry(modelRuntime);await registry.refresh();
 const sm=SessionManager.create(cwd,`${lab}/sessions`);
 ({session}=await createAgentSession({cwd,agentDir,resourceLoader:loader,settingsManager,sessionManager:sm,modelRuntime,model:registry.find('local-probe','probe'),noTools:'builtin'}));
 await session.bindExtensions({abortHandler:()=>{void session.abort();},onError:error=>{errors.push(error);console.log(JSON.stringify({extensionError:error}));}});
 // Bind without ownership, then acquire only our disposable home's lock. This
 // exercises lazy branch ownership without starting a primary watcher lifecycle.
 writeFileSync(`${home}/state/.lock`,`${process.pid}\n`);
 await session.prompt('Please report the isolated validation result.');
 assert.equal(session.getLastAssistantText(),'OK');
 console.log('USER_PROMPT: completed with OK');
 await session.sendCustomMessage({customType:'unrelated-outcome-probe',content:'An unrelated custom outcome',display:false},{triggerTurn:true});
 await session.waitForIdle();
 assert(events.some(e=>e.messageType==='custom'&&e.customType==='unrelated-outcome-probe'&&!e.hasPrompt));
 assert.equal(errors.length,0);
 console.log('CUSTOM_NO_PROMPT: completed with OK and no extension error');
 // Append through the real durable product API, then let the normal next turn
 // reconcile, display and deliver it. The endpoint returns the real ack tool.
 const append=spawnSync(`${root}/bin/fm-branch-outcome.sh`,['append','--task','probe-task','--verdict','captain','--summary','Isolated outcome ready for review'],{encoding:'utf8',env:process.env});
 assert.equal(append.status,0,append.stderr); console.log(`OUTCOME_APPEND: ${append.stdout.trim()}`);
 await session.prompt('Check the current isolated outcomes.');
 await session.waitForIdle();
 // Delivery may finish on the serialized extension chain after settlement.
 for(let i=0;i<200&&!existsSync(`${home}/state/.branch-outcomes-processed`);i++) await new Promise(r=>setTimeout(r,50));
 assert.equal(readFileSync(`${home}/state/.branch-outcomes-processed`,'utf8').trim(),'1');
 const visible=sm.getEntries().filter(e=>e.customType==='fm-branch-visible-outcome');
 assert.equal(visible.length,1);assert.equal(visible[0].data.summary,'Isolated outcome ready for review');
 assert.equal(errors.length,0);
 console.log(JSON.stringify({outcomeVisible:visible[0],processedThrough:1,requests,errors}));
 console.log('DURABLE_OUTCOME: displayed once and acknowledged through 1');
 const second=spawnSync(`${root}/bin/fm-branch-outcome.sh`,['append','--task','probe-task','--verdict','captain','--summary','Outcome deferred by away posture'],{encoding:'utf8',env:process.env});
 assert.equal(second.status,0,second.stderr);
 afkOnProcessing=true;
 const beforeAway=requests;
 await session.prompt('Collect the next isolated outcome.');
 for(let i=0;i<200&&!existsSync(`${home}/state/.afk-contract`);i++) await new Promise(r=>setTimeout(r,50));
 assert(existsSync(`${home}/state/.afk-contract`),'dedicated processing startup did not run');
 await session.waitForIdle();
 await new Promise(r=>setTimeout(r,300));
 assert.equal(requests,beforeAway+1,'away processing incorrectly contacted provider');
 assert.equal(readFileSync(`${home}/state/.branch-outcomes-processed`,'utf8').trim(),'1');
 assert.equal(errors.length,0);
 console.log(JSON.stringify({awayProcessingAbortedBeforeProvider:true,processedThrough:1,requests,errors}));
 // A user turn must not be mistaken for the custom processing run in away mode.
 afkOnProcessing=false; acknowledge=false;
 await session.prompt('This is a genuine user turn while away.');
 assert.equal(session.getLastAssistantText(),'OK');
 assert.equal(requests,beforeAway+2);
 assert.equal(errors.length,0);
 console.log('AWAY_BOUNDARY: custom processing aborted without losing pending outcome; genuine user turn completed');
 console.log(JSON.stringify({sessionFile:sm.getSessionFile(),events}));
} finally {if(session){await session.abort(); session.dispose();} await new Promise(r=>server.close(r));}
