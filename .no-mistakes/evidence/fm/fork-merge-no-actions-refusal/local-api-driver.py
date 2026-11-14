import http.server, socketserver, ssl, threading, subprocess, os, json, pathlib, shutil, urllib.parse
ROOT=pathlib.Path.cwd(); WORK=ROOT/'.local-validation'; E=pathlib.Path('~/.no-mistakes/evidence/01M7DB0VSQ7CH5VZPMT895ZBX5')
HEAD='a'*40
state={}; requests=[]
class API(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_CONNECT(self):
  if self.path not in ('api.github.com:443','github.com:443'): raise RuntimeError(self.path)
  self.send_response(200); self.end_headers()
  self.connection=ctx.wrap_socket(self.connection,server_side=True); self.rfile=self.connection.makefile('rb'); self.wfile=self.connection.makefile('wb'); self.close_connection=False
  self.handle_one_request()
 def do_GET(self): self.respond()
 def do_POST(self): self.respond()
 def do_PATCH(self): self.respond()
 def do_PUT(self): self.respond()
 def respond(self):
  body=self.rfile.read(int(self.headers.get('Content-Length',0))).decode(); path=urllib.parse.urlsplit(self.path).path
  requests.append({'method':self.command,'path':self.path,'body':body})
  code=200
  pr={'id':'PR_fixture','number':7,'url':'https://github.com/example/repo/pull/7','state':'MERGED' if state.get('merged') else 'OPEN','isDraft':False,'mergeable':'MERGEABLE','mergeStateStatus':'CLEAN','headRefOid':HEAD,'baseRefName':'main','title':'Synthetic local PR','headRefName':'feature','maintainerCanModify':True,'viewerCanMergeAsAdmin':False,'merged':state.get('merged',False),'mergedAt':'2026-01-01T00:00:00Z' if state.get('merged') else None,'isInMergeQueue':False,'mergeQueueEntry':None,'autoMergeRequest':None,'headRepositoryOwner':{'login':'example'},'headRepository':{'name':'repo','nameWithOwner':'example/repo','owner':{'login':'example'}},'baseRepository':{'id':'REPO_fixture','name':'repo','nameWithOwner':'example/repo','owner':{'login':'example'},'defaultBranchRef':{'name':'main'},'squashMergeAllowed':True,'mergeCommitAllowed':True,'rebaseMergeAllowed':True},'statusCheckRollup':{'nodes':[]}}
  if state.get('status_only'): pr['statusCheckRollup']={'nodes':[{'__typename':'StatusContext','context':'external-ci','state':'SUCCESS'}]}
  if state.get('red'): pr['statusCheckRollup']={'nodes':[{'__typename':'CheckRun','name':'lint','status':'COMPLETED','conclusion':'FAILURE'}]}
  # gh pr view flattens commit statusCheckRollup contexts into public JSON.
  pr['statusCheckRollup']={'nodes':[{'commit':{'oid':HEAD,'statusCheckRollup':{'contexts':dict(pr['statusCheckRollup'],pageInfo={'hasNextPage':False,'endCursor':None})}}}]}
  if path in ('/graphql','/api/graphql'):
   q=json.loads(body).get('query','')
   if '__type(' in q:
    out={'data':{}}
    import re
    for alias in re.findall(r'(\w+): __type',q): out['data'][alias]={'fields':[{'name':x} for x in ('id','isInMergeQueue','isMergeQueueEnabled','mergeQueue','mergeStateStatus','statusCheckRollup','pageInfo','workflow')]}
   elif 'mutation' in q and 'mergePullRequest' in q:
    state['merged']=True; out={'data':{'mergePullRequest':{'clientMutationId':None}}}
   else: out={'data':{'repository':{'id':'REPO_fixture','name':'repo','nameWithOwner':'example/repo','owner':{'login':'example'},'pullRequest':pr,'hasIssuesEnabled':True,'defaultBranchRef':{'name':'main'},'squashMergeAllowed':True,'mergeCommitAllowed':True,'rebaseMergeAllowed':True},'viewer':{'login':'local-validator'}}}
  elif path.endswith('/branches/main') and '/rules/' not in path: out={'name':'main','protected':False,'protection':{'enabled':False}}
  elif path.endswith('/rules/branches/main'): out=[{'type':'deletion'}]
  elif '/check-suites' in path:
   if state.get('error')=='suites': code=503; out={'message':'synthetic unavailable'}
   else: out={'total_count':state.get('suites',0),'check_suites':[]}
  elif path.endswith('/contents/.github/workflows'):
   if state.get('error')=='listing': code=503; out={'message':'synthetic unavailable'}
   elif state.get('workflow') is None: code=404; out={'message':'Not Found'}
   else: out=[{'name':'ci.yml','type':'file'}]
  elif path.endswith('/contents/.github/workflows/ci.yml'):
   if state.get('error')=='file': code=503; out={'message':'synthetic unavailable'}
   else: out=state['workflow']
  else: code=500; out={'message':'Unhandled emulator endpoint '+path}
  data=out.encode() if isinstance(out,str) else json.dumps(out).encode()
  self.send_response(code); self.send_header('Content-Type','text/plain' if isinstance(out,str) else 'application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
class Server(socketserver.ThreadingMixIn,http.server.HTTPServer): daemon_threads=True
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(WORK/'cert.pem',WORK/'key.pem')
server=Server(('127.0.0.1',0),API); thread=threading.Thread(target=server.serve_forever); thread.start()
shutil.rmtree(WORK/'user',ignore_errors=True)
shutil.rmtree(WORK/'cache',ignore_errors=True)
env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','HERDR_','GH_','GITHUB_','TASKS_AXI_')) or k.lower() in ('https_proxy','http_proxy','all_proxy','no_proxy'): env.pop(k,None)
env.update(HOME=str(WORK/'user'),FM_HOME=str(WORK/'home'),GH_CONFIG_DIR=str(WORK/'gh'),GH_TOKEN='disposable-local-token',GH_PROMPT_DISABLED='1',GH_NO_UPDATE_NOTIFIER='1',GH_NO_EXTENSION_UPDATE_NOTIFIER='1',HTTPS_PROXY=f'http://127.0.0.1:{server.server_port}',SSL_CERT_FILE=str(WORK/'cert.pem'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GH_TELEMETRY='0',XDG_CACHE_HOME=str(WORK/'cache'))
for p in ('user','gh','home/state','home/config','home/data','wt'): (WORK/p).mkdir(parents=True,exist_ok=True)
subprocess.run(['git','init','-q',str(WORK/'wt')],check=True,env=env)
subprocess.run(['git','-C',str(WORK/'wt'),'-c','user.name=Validator','-c','user.email=validator@example.invalid','commit','--allow-empty','-qm','fixture'],check=True,env=env)
results=[]
def run(name,expected=1,args=(),message=None,url='https://github.com/example/repo/pull/7',**config):
 global state,requests
 state=dict(config); requests=[]
 home=WORK/'home'; shutil.rmtree(home/'state'); (home/'state').mkdir()
 (home/'state/task-x1.meta').write_text(f'window=fm-task-x1\nworktree={WORK}/wt\nproject={WORK}/wt\nkind=ship\nmode=no-mistakes\n')
 setup=''
 if config.get('away'):
  setup_result=subprocess.run(['bash','bin/fm-afk-contract.sh','enter','--words','merge task-x1 when green'],env=env,capture_output=True,text=True,timeout=10)
  setup=f'fm-afk-contract.sh enter --words "merge task-x1 when green": exit={setup_result.returncode}\n{setup_result.stdout}{setup_result.stderr}'
  if setup_result.returncode: raise RuntimeError(setup)
 cmd=['bash','bin/fm-pr-merge.sh','task-x1',url,*args]
 result=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=35)
 merged=state.get('merged',False)
 log=f'{setup}$ {" ".join(cmd)}\nSynthetic API input: {json.dumps(config)}\nexit={result.returncode}; merge mutation observed={merged}\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}\nAPI REQUESTS:\n{json.dumps(requests,indent=2)}\n'
 log+='PERSISTED TASK METADATA:\n'+(home/'state/task-x1.meta').read_text()
 (E/(name+'.log')).write_text(log)
 ok=result.returncode==expected and merged==(expected==0) and 'could not read the GitHub pull request state' not in result.stderr and 'branch rules for base branch main could not be read' not in result.stderr
 if name.startswith('missing-actions'): ok=ok and 'has no GitHub Actions check suite although' in result.stderr
 if message: ok=ok and message in result.stderr
 if expected==0:
  ok=ok and 'pr_head='+HEAD in (home/'state/task-x1.meta').read_text() and any('expectedHeadOid' in r['body'] and HEAD in r['body'] for r in requests if 'mergePullRequest' in r['body'])
 if config.get('error'): ok=ok and any(config['error'].replace('suites','check-suites') in r['path'] or '/contents/.github/workflows' in r['path'] for r in requests)
 results.append({'name':name,'ok':ok,'exit':result.returncode,'merged':merged})
 print(name,ok,result.returncode,merged,flush=True)
 if not ok: print(result.stdout,result.stderr,flush=True)
 return ok
try:
 run('missing-actions-refused',workflow='on: pull_request\njobs: {}')
 for name,body in [('indentless','on:\n- pull_request\njobs: {}'),('column-zero','on: [push,\npull_request]\njobs: {}'),('next-line-flow','on:\n [push, pull_request]\njobs: {}'),('next-line-map','on:\n {push: {}, pull_request: {}}\njobs: {}'),('quoted-hash','on: {workflow_dispatch: {inputs: {version: {description: "Release # number"}}}, pull_request: {}}\njobs: {}')]:
  run('missing-actions-'+name,workflow=body)
 run('missing-actions-status-only',status_only=True,workflow='on: pull_request\njobs: {}')
 run('suite-present',expected=0,suites=1,workflow='on: pull_request\njobs: {}',message='every unwaived check green')
 for name,body in [('no-directory',None),('other-events','on: [push, pull_request_target, pull_request_review]\njobs: {}'),('property','on: push\njobs:\n a:\n  if: github.event.pull_request.number')]:
  run('exempt-'+name,expected=0,workflow=body,message='every unwaived check green')
 run('waiver-merge',expected=0,args=['--allow-no-actions'],workflow='on: pull_request\njobs: {}',message='waived by --allow-no-actions')
 run('waiver-red',args=['--allow-no-actions'],red=True,workflow='on: pull_request\njobs: {}',message="check 'lint' is not green")
 for error,message in [('suites','GitHub Actions check suites at head'),('listing','workflow directory on base branch main could not be read'),('file','workflow .github/workflows/ci.yml on base branch main could not be read')]:
  run('unreadable-'+error,error=error,workflow='on: pull_request\njobs: {}',message=message)
 run('waiver-unreadable',args=['--allow-no-actions'],error='suites',workflow='on: pull_request\njobs: {}',message='GitHub Actions check suites at head')
 run('waiver-away',expected=2,args=['--allow-no-actions'],away=True,workflow='on: pull_request\njobs: {}',message='--allow-no-actions is attended-only')
 run('waiver-non-github',expected=2,args=['--allow-no-actions'],url='https://gitlab.example/group/repo/-/merge_requests/7',message='--allow-no-actions applies only to GitHub')
finally:
 server.shutdown(); server.server_close(); thread.join(); (E/'live-results.json').write_text(json.dumps(results,indent=2))
