"""Live local adapter + real private_notice facade + real gh-axi/gh against HTTPS GitHub emulator.
No Discord transport, real enrollment, production credentials, or model calls.
"""
import runpy, pathlib, os, sys, json, sqlite3, subprocess, threading, ssl, http.server, time, traceback, shutil
ROOT=pathlib.Path.cwd();EVIDENCE=pathlib.Path('~/.no-mistakes/evidence/01M7MMJBZB5SQMJ87M8EGHBAC2')
ns=runpy.run_path(str(ROOT/'.notice-validation/live.py'),run_name='local_driver');World=ns['World']
class Forge(http.server.BaseHTTPRequestHandler):
 mode='green'; race=None; head='a'*40; draft=False; state='open'; identity_calls=0; fail_final=False
 def log_message(self,*args):pass
 def send(self,code,body):
  self.send_response(code);self.send_header('content-type','application/json');self.end_headers();self.wfile.write(json.dumps(body).encode())
 def do_GET(self):
  cls=type(self);cls.identity_calls+=1
  print('HTTPS GET',self.path,'identity',cls.identity_calls,cls.head,cls.state,cls.draft,flush=True)
  if cls.fail_final and cls.identity_calls>=2:return self.send(503,{'message':'temporary local forge outage'})
  self.send(200,{'html_url':'https://github.com/owner/repo/pull/1','state':cls.state,'draft':cls.draft,'head':{'sha':cls.head}})
 def do_POST(self):
  cls=type(self);body=json.loads(self.rfile.read(int(self.headers['content-length'])))
  is_view='headRefOid' in body['query'];print('HTTPS GraphQL', 'view' if is_view else 'checks',cls.mode,flush=True)
  checks=[] if cls.mode=='none' else [{'__typename':'CheckRun','name':'build','status':'IN_PROGRESS' if cls.mode=='pending' else 'COMPLETED','conclusion':None if cls.mode=='pending' else 'FAILURE' if cls.mode=='red' else 'SUCCESS','checkSuite':{'workflowRun':{'workflow':{'name':'CI'}}},'startedAt':'2026-11-17T00:00:00Z','completedAt':'2026-11-17T00:01:00Z','detailsUrl':'https://github.com/owner/repo/actions/runs/1'}]
  result={'data':{'repository':{'pullRequest':{'headRefOid':cls.head,'id':'PR_local','number':1,'statusCheckRollup':{'nodes':[{'commit':{'statusCheckRollup':{'contexts':{'nodes':checks,'pageInfo':{'hasNextPage':False,'endCursor':None}}}}}]}}}}}
  self.send(200,result)
  if not is_view and cls.race:
   if cls.race=='head':cls.head='b'*40
   if cls.race=='draft':cls.draft=True
   if cls.race=='close':cls.state='closed'
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Forge)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(ROOT/'.notice-validation/cert.pem',ROOT/'.notice-validation/key.pem');server.socket=ctx.wrap_socket(server.socket,server_side=True)
thread=threading.Thread(target=server.serve_forever);thread.start()
results=[];worlds=[]
def fresh(name):
 Forge.mode='green';Forge.race=None;Forge.head='a'*40;Forge.draft=False;Forge.state='open';Forge.identity_calls=0;Forge.fail_final=False
 w=World('test_real_no_ci_pr_creates_one_notice');w._testMethodName=name;w.setUp();worlds.append(w)
 w.env.update(GH_HOST=f'localhost:{server.server_port}',GH_ENTERPRISE_TOKEN='disposable-local-token',GH_TOKEN='disposable-local-token',NODE_EXTRA_CA_CERTS=str(ROOT/'.notice-validation/cert.pem'),SSL_CERT_FILE=str(ROOT/'.notice-validation/cert.pem'))
 return w

def show(w,label):
 print('\nPRODUCT',label,flush=True);print(w.call('reach').stdout,flush=True)
 if (w.home/'state/away-notices.sqlite3').exists():print('adapter rows',json.dumps([{k:r[k] for k in ('kind','state','error','identity','notice_id')} for r in w.rows()]),flush=True)
 print('immutable parent events',json.dumps(w.events()),flush=True)
 with sqlite3.connect(w.config['journal']) as db:print('parent obligation phases',db.execute('SELECT phase FROM obligations').fetchall(),flush=True)

def check(name,fn):
 print('\n=== SCENARIO',name,'===',flush=True)
 try:fn();results.append({'name':name,'result':'pass'})
 except Exception as e:traceback.print_exc();results.append({'name':name,'result':'fail','error':str(e)})

def off_quiet():
 w=fresh('offquiet');w.selection.unlink();w.contract('archive');print(w.contract('enter','--spend','1','--words','Send @everyone to a public client Discord channel').stdout);w.hold();w.report(host=True);assert not w.events();assert w.call('reach').stdout.startswith('none\n');assert not (w.home/'state/away-notices.sqlite3').exists()
 w.contract('archive');w.selection.write_text(json.dumps({'reach':'discord-private','domain':'personal'}));w.env['FM_AFK_MODE']='quiet';print(w.contract('enter','--spend','1').stdout);w.report(host=True);assert not w.events();assert w.contract('mode').stdout.strip()=='quiet';show(w,'quiet makes no notice')

def host_dedupe():
 w=fresh('hostdedupe');w.hold();w.report(host=True);w.report(host=True);w.call('drain');assert len(w.events())==1;assert w.rows()[0]['state']=='owed';assert 'not proof of delivery' in w.call('reach').stdout
 r=subprocess.run(['bash',str(w.code/'bin/fm-captain-hold.sh'),'open','task','--identity'],env=w.env,text=True,capture_output=True);assert r.returncode==0
 assert not (w.home/'state/.branch-outcomes-processed').exists();assert len((w.home/'state/branch-outcomes.jsonl').read_text().splitlines())==2;assert 'secret' not in json.dumps(w.events());show(w,'duplicate host reports retain one event and an open hold')

def durability():
 w=fresh('durability');w.hold();p=w.home/'config/discord/personal/away-notices.json';saved=p.read_text();p.write_text('{');w.report(host=True);assert len(w.rows())==1 and w.rows()[0]['state']=='queued';assert not w.events();assert 'unavailable' in w.call('reach').stdout;assert len((w.home/'state/branch-outcomes.jsonl').read_text().splitlines())==1;show(w,'malformed enrollment retains typed intent and outcome');p.write_text(saved);w.call('drain');assert w.rows()[0]['state']=='owed' and len(w.events())==1;show(w,'configuration recovery drains original binding')

def shaping():
 w=fresh('shaping');w.hold();w.report(host=True);w.hold('other');(w.home/'state/other.meta').unlink();w.report(host=True,task='other');assert len(w.events())==1 and w.rows()[1]['state']=='queued';w.call('drain');assert len(w.events())==1;show(w,'distinct sensitive decision queued behind 30-second limit');print('Waiting 31 actual seconds (no clock/database manipulation)',flush=True);time.sleep(31);w.call('drain');assert len(w.events())==2 and w.rows()[1]['state']=='owed';assert w.events()[1]['template_id']=='sensitive-decision';assert w.events()[1]['text']=='A decision is waiting. Please review it in our usual conversation.';show(w,'eligible excess emitted once after actual spacing')

def domains():
 w=fresh('domains');w.hold();w.report(host=True);replacement=w.install_domain('private');w.switch_domain('private');w.hold('other');w.report(host=True,task='other');assert [r['state'] for r in w.rows()]==['withdrawn','owed'];show(w,'domain replacement disposes original obligation without retargeting');print(w.call('return').stdout);assert [r['state'] for r in w.rows()]==['withdrawn','withdrawn'];
 for config in (w.config,replacement):
  with sqlite3.connect(config['journal']) as db:
   assert db.execute('SELECT count(*) FROM events').fetchone()[0]==1;assert db.execute('SELECT phase FROM obligations').fetchone()[0]=='owner-disposed';print('original domain journal',config['domain'],db.execute("SELECT body FROM records WHERE family='notice-withdrawal'").fetchall(),flush=True)
 w=fresh('privacy');w.hold();w.report(host=True);w.enrollment['private_owner_only']=False;w.enroll();w.call('drain');assert w.rows()[0]['state']=='withdrawn';show(w,'positive privacy revocation withdraws owed notice')

def pr_readiness():
 for mode in ('green','none','red','pending'):
  w=fresh('readiness-'+mode);w.ready();Forge.mode=mode;w.report('pr-ready',host=True);assert bool(w.events())==(mode in ('green','none'));assert w.rows()[0]['state']==('owed' if mode in ('green','none') else 'queued');show(w,'real gh-axi on local GitHub '+mode)
 w=fresh('lostreadiness');w.ready();w.report('pr-ready',host=True);Forge.mode='pending';w.call('drain');assert w.rows()[0]['state']=='withdrawn';show(w,'same-head pending CI withdraws stale parent obligation')

def races():
 for prior in ('queued','owed'):
  for change in ('head','draft','close'):
   w=fresh('race-'+prior+'-'+change);w.ready()
   if prior=='owed':w.report('pr-ready',host=True);assert w.rows()[0]['state']=='owed'
   Forge.race=change;Forge.identity_calls=0
   if prior=='queued':w.report('pr-ready',host=True)
   else:w.call('drain')
   assert Forge.identity_calls==2;assert w.rows()[0]['state']=='withdrawn';assert len(w.events())==(1 if prior=='owed' else 0)
   if prior=='owed':
    with sqlite3.connect(w.config['journal']) as db:assert db.execute('SELECT phase FROM obligations').fetchone()[0]=='owner-disposed'
   show(w,'confirmation race '+prior+' '+change)

def final_errors():
 for prior in ('queued','owed'):
  w=fresh('final-error-'+prior);w.ready()
  if prior=='owed':w.report('pr-ready',host=True)
  Forge.identity_calls=0;Forge.fail_final=True
  if prior=='owed':w.call('drain')
  else:w.report('pr-ready',host=True)
  assert w.rows()[0]['state']==prior;assert w.rows()[0]['error'];show(w,'503 from final confirmation retains '+prior)
  Forge.fail_final=False;Forge.identity_calls=0;w.call('drain');assert w.rows()[0]['state']=='owed';assert not w.rows()[0]['error'];assert len(w.events())==1;show(w,'final-query recovery without duplicate approval')
try:
 for name,fn in [('Explicit reach off and quiet ignore transport prose',off_quiet),('Host held-decision reporting dedupes with independent bookkeeping',host_dedupe),('Enrollment-read failure preserves outcome and recovers typed intent',durability),('Real 30-second spacing retains distinct sensitive decision',shaping),('Domain replacement privacy revocation and return withdraw original obligations',domains),('PR ready no-CI pending and readiness-loss use real gh-axi locally',pr_readiness),('Final identity head draft closure races fence queued and owed notices',races),('Final forge query outage preserves work and recovers without duplicates',final_errors)]:check(name,fn)
finally:
 server.shutdown();thread.join();server.server_close()
 for w in worlds:shutil.rmtree(w.world)
 EVIDENCE.joinpath('live-results.json').write_text(json.dumps(results,indent=2)+'\n')
print('\nRESULTS',json.dumps(results),flush=True)
sys.exit(any(r['result']=='fail' for r in results))
