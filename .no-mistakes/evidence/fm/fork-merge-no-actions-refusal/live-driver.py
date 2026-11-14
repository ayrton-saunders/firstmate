import os, ssl, socketserver, http.server, threading, subprocess, json, pathlib, shutil
ROOT=pathlib.Path.cwd(); V=ROOT/'.validation'; E=pathlib.Path('~/.no-mistakes/evidence/01M7DB0VSQ7CH5VZPMT895ZBX5')
state={'suite':0,'workflow':'on: [push, pull_request]\njobs: {}','red':False,'merged':False,'unreadable':False}
HEAD='a'*40
requests=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_CONNECT(self):
  self.send_response(200); self.end_headers()
  ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(V/'cert.pem', V/'key.pem')
  self.connection=ctx.wrap_socket(self.connection,server_side=True)
  self.rfile=self.connection.makefile('rb'); self.wfile=self.connection.makefile('wb'); self.close_connection=False
  while not self.close_connection: self.handle_one_request()
 def do_GET(self): self.answer()
 def do_POST(self): self.answer()
 def answer(self):
  body=self.rfile.read(int(self.headers.get('Content-Length','0'))).decode(); requests.append((self.path,body))
  code=200; obj={}
  if self.path=='/graphql':
   q=json.loads(body).get('query','')
   pr={'id':'PR_fixture','number':1,'state':'MERGED' if state['merged'] else 'OPEN','isDraft':False,'mergeable':'MERGEABLE','mergeStateStatus':'CLEAN','headRefOid':HEAD,'baseRefName':'main','isInMergeQueue':False,'merged':state['merged'],'viewerCanUpdate':True,'maintainerCanModify':True,'headRepositoryOwner':{'login':'example'},'headRepository':{'name':'repo'},'baseRepository':{'name':'repo'},'commits':{'nodes':[{'commit':{'oid':HEAD,'statusCheckRollup':{'contexts':{'nodes':[{'__typename':'CheckRun','name':'ci','status':'COMPLETED','conclusion':'FAILURE' if state['red'] else 'SUCCESS'}],'pageInfo':{'hasNextPage':False}}}}}]}}
   pr['statusCheckRollup']=pr['commits']
   if 'mergePullRequest' in q:
    state['merged']=True; pr['state']='MERGED';pr['merged']=True
   obj={'data':{'repository':{'id':'R_fixture','name':'repo','owner':{'login':'example'},'defaultBranchRef':{'name':'main'},'mergeCommitAllowed':True,'squashMergeAllowed':True,'rebaseMergeAllowed':True,'pullRequest':pr},'mergePullRequest':{'pullRequest':pr}}}
   if 'PullRequest_fields2' in q: obj={'data':{'WorkflowRun':{'fields':[]}}}
   elif 'PullRequest_fields' in q: obj={'data':{'PullRequest':{'fields':[{'name':n} for n in ['isInMergeQueue','isDraft','mergeStateStatus','headRefOid','autoMergeRequest','reviewDecision']]},'StatusCheckRollupContextConnection':{'fields':[]}}}
   elif 'mutation' in q: obj={'data':{'mergePullRequest':{'clientMutationId':None}}}
  elif '/rules/' in self.path: obj=[]
  elif '/branches/' in self.path: obj={'name':'main','protected':False,'protection':{'enabled':False}}
  elif '/check-runs' in self.path: obj={'total_count':1,'check_runs':[{'name':'ci','app':{'id':15368},'status':'completed','conclusion':'failure' if state['red'] else 'success'}]}
  elif '/check-suites' in self.path:
   if state['unreadable']: code=503;obj={'message':'fixture suite read unavailable'}
   else: obj={'total_count':state['suite'],'check_suites':[]}
  elif '/contents/.github/workflows/' in self.path: obj=state['workflow']
  elif '/contents/.github/workflows' in self.path:
   if state['workflow'] is None: code=404;obj={'message':'Not Found'}
   else: obj=[{'name':'ci.yml','type':'file','path':'.github/workflows/ci.yml'}]
  elif self.path.startswith('/repos/example/repo'): obj={'id':1,'name':'repo','full_name':'example/repo','owner':{'login':'example'},'default_branch':'main','allow_squash_merge':True}
  else: code=404;obj={'message':'Unhandled '+self.path}
  raw=obj.encode() if isinstance(obj,str) else json.dumps(obj).encode()
  self.send_response(code); self.send_header('Content-Type','text/plain' if isinstance(obj,str) else 'application/json'); self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
class Server(socketserver.ThreadingMixIn,http.server.HTTPServer): daemon_threads=True
srv=Server(('127.0.0.1',0),Handler); t=threading.Thread(target=srv.serve_forever);t.start()
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ['GH_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_TOKEN','GH_HOST']: env.pop(k,None)
env.update(HOME=str(V/'user'),GH_CONFIG_DIR=str(V/'gh'),GH_TOKEN='disposable-not-a-real-token',HTTPS_PROXY=f'http://127.0.0.1:{srv.server_port}',HTTP_PROXY=f'http://127.0.0.1:{srv.server_port}',ALL_PROXY='',NO_PROXY='',SSL_CERT_FILE=str(V/'cert.pem'),TMPDIR=str(V),GH_PROMPT_DISABLED='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
def run(name, flags=(), workflow='on: [push, pull_request]\njobs: {}', suite=0,red=False,unreadable=False,away=False,url='https://github.com/example/repo/pull/1'):
 state.update(suite=suite,workflow=workflow,red=red,unreadable=unreadable,merged=False); requests.clear()
 home=V/name
 if home.exists(): shutil.rmtree(home)
 (home/'state').mkdir(parents=True);(home/'config').mkdir();(home/'data').mkdir()
 wt=home/'wt'; wt.mkdir()
 subprocess.run(['git','init','-q',str(wt)],env=env,check=True)
 subprocess.run(['git','-C',str(wt),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--allow-empty','-qm','fixture'],env=env,check=True)
 subprocess.run(['git','-C',str(wt),'update-ref','refs/remotes/origin/main','HEAD'],env=env,check=True)
 (home/'state/task-x1.meta').write_text(f'kind=ship\nmode=no-mistakes\nworktree={wt}\nproject={home}/project\n')
 e=env|{'FM_HOME':str(home),'GH_CONFIG_DIR':str(home/'gh'),'XDG_CACHE_HOME':str(home/'cache')}
 if away: subprocess.run(['bash','bin/fm-afk-contract.sh','enter','--words','merge task-x1 when green'],env=e,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 p=subprocess.run(['bash','bin/fm-pr-merge.sh','task-x1',url,*flags],env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=70)
 out=f'SCENARIO: {name}\nReal fm-pr-merge.sh + real gh, isolated HTTPS GitHub emulator; synthetic head {HEAD}\ncommand flags: {list(flags)}\nexit: {p.returncode}\n{p.stdout}{p.stderr}\nEmulator merged state: {state["merged"]}\nHTTP/GraphQL traffic:\n'+json.dumps(requests,indent=2)+'\n'
 (E/(name+'.log')).write_text(out);print(out[:3500],flush=True)
 return p
try:
 run('live-no-suite-refusal')
 run('live-indentless-refusal',workflow='on:\n- push\n- pull_request\njobs: {}')
 run('live-next-line-flow-refusal',workflow='on:\n [push, pull_request]\njobs: {}')
 run('live-quoted-hash-refusal',workflow='on: {workflow_dispatch: {inputs: {version: {description: "Release # number"}}}, pull_request: {}}\njobs: {}')
 run('live-waived-absence', ['--allow-no-actions'])
 run('live-no-pr-workflow', workflow='on: push\njobs: {}')
 run('live-suite-present',suite=1)
 run('live-waiver-red', ['--allow-no-actions'],red=True)
 run('live-waiver-unreadable', ['--allow-no-actions'],unreadable=True)
 run('live-waiver-value', ['--allow-no-actions=yes'])
 run('live-waiver-wrong-forge', ['--allow-no-actions'],url='https://gitlab.example/group/project/-/merge_requests/1')
 run('live-waiver-away', ['--allow-no-actions'],away=True)
finally:
 srv.shutdown();srv.server_close();t.join()
