import http.server, ssl, threading, subprocess, os, json, pathlib, shutil, re
ROOT=pathlib.Path.cwd(); V=ROOT/'.validation'; E=pathlib.Path('~/.no-mistakes/evidence/01M7Q34HC9WDACFJJR6J3DGE66')
A='PR must be raised via no-mistakes'; B='Stock macOS Bash snapshot compatibility'; HEAD='a'*40; NEW='b'*40
state={}; requests=[]
def runcheck(name,conclusion='SUCCESS',status='COMPLETED'):
 return dict(__typename='CheckRun',name=name,status=status,conclusion=conclusion,startedAt='2026-11-18T00:00:00Z',completedAt='2026-11-18T00:01:00Z',detailsUrl='https://github.com/lab/waivers/actions/runs/1')
def pr():
 return dict(id='PR_lab',number=88,url='https://github.com/lab/waivers/pull/88',state='MERGED' if state.get('merged') else 'OPEN',merged=bool(state.get('merged')),isInMergeQueue=False,isDraft=False,mergeable='MERGEABLE',mergeStateStatus='BEHIND' if state.get('behind') else 'CLEAN',headRefOid=state.get('head',HEAD),baseRefName='main',headRefName='integration',baseRepository=dict(id='R_lab',name='waivers',nameWithOwner='lab/waivers',owner=dict(login='lab')),headRepository=dict(id='R_lab',name='waivers',owner=dict(login='lab')),isCrossRepository=False,viewerCanUpdate=True,viewerCanDeleteHeadRef=False,reviewDecision='',autoMergeRequest=None,statusCheckRollup=dict(nodes=[dict(commit=dict(statusCheckRollup=dict(contexts=dict(nodes=state['checks'],pageInfo=dict(hasNextPage=False,endCursor='')))))]))
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(V/'cert.pem',V/'key.pem')
class Handler(http.server.BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*a):pass
 def do_CONNECT(self):
  if self.path not in ('api.github.com:443','github.com:443'): self.send_error(403); return
  self.send_response(200);self.end_headers();self.connection=ctx.wrap_socket(self.connection,server_side=True);self.rfile=self.connection.makefile('rb');self.wfile=self.connection.makefile('wb');self.close_connection=False
 def answer(self,body,code=200):
  if requests:requests[-1]['response']={'status':code,'body':body}
  b=json.dumps(body).encode(); self.send_response(code);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b)
 def handle_api(self):
  data=self.rfile.read(int(self.headers.get('Content-Length','0'))); payload=json.loads(data) if data else {}; path=self.path
  requests.append(dict(method=self.command,path=path,body=payload))
  if path=='/graphql':
   q=payload.get('query','')
   if '__type(' in q:
    names=re.findall(r'(\w+): __type',q)
    self.answer({'data':{n:{'fields':[{'name':x} for x in ['id','number','isInMergeQueue','statusCheckRollup','contexts','workflow','name']]} for n in names}});return
   if 'mergePullRequest' in q:
    state['merge_attempts']=state.get('merge_attempts',0)+1
    # Independent head-match contract of GitHub's mutation.
    inp=payload.get('variables',{}).get('input',{})
    expected=inp.get('expectedHeadOid')
    if expected != state.get('server_head',state.get('head',HEAD)):
     self.answer({'errors':[{'message':'Head branch was modified. Review and try again.'}]});return
    state['merged']=True; self.answer({'data':{'mergePullRequest':{'clientMutationId':None}}});return
   p=pr()
   if state.get('away_after_view') and 'statusCheckRollup' in q:
    cmd=[str(ROOT/'bin/fm-afk-contract.sh'),'enter','--words','merge when green']
    result=subprocess.run(cmd,env=state['env'],capture_output=True,text=True)
    state['away_setup']=[result.returncode,result.stdout,result.stderr];state['away_after_view']=False
   if state.get('push_after_view') and 'statusCheckRollup' in q:
    state['server_head']=NEW;state['push_after_view']=False
   if state.get('settle') and 'statusCheckRollup' in q:
    state['checks']=[runcheck('ci'),runcheck(A,'FAILURE'),runcheck(B,'CANCELLED')];state['settle']=False
   self.answer({'data':{'repository':{'id':'R_lab','name':'waivers','owner':{'login':'lab'},'viewerPermission':'ADMIN','mergeCommitAllowed':True,'squashMergeAllowed':True,'rebaseMergeAllowed':True,'defaultBranchRef':{'name':'main'},'pullRequest':p}}});return
  if '/branches/' in path and '/rules/' not in path:
   if state.get('rules_fail'):self.answer({'message':'Forbidden'},403);return
   self.answer({'name':'main','protected':True,'protection':{'required_status_checks':{'checks':[{'context':x,'app_id':state.get('app_id')} for x in state['required']],'contexts':state['required']}}});return
  if '/rules/branches/' in path:self.answer([]);return
  if '/check-suites' in path:self.answer({'total_count':1,'check_suites':[{'app':{'id':15368}}]});return
  if '/check-runs' in path:self.answer({'check_runs':[{'name':c['name'],'app':{'id':999},'head_sha':state.get('head',HEAD)} for c in state['checks']]});return
  if path.endswith('/update-branch'):
   assert payload['expected_head_sha']==HEAD
   state.update(head=NEW,behind=False,settle=True,checks=[runcheck('ci',None,'IN_PROGRESS'),runcheck(A,'FAILURE'),runcheck(B,'CANCELLED')]);self.answer({'message':'Updating pull request branch.'},202);return
  if path=='/repos/lab/waivers':self.answer({'id':1,'name':'waivers','full_name':'lab/waivers','owner':{'login':'lab'},'default_branch':'main','permissions':{'push':True}});return
  self.answer({'message':'unimplemented local route'},404)
 do_GET=handle_api
 do_POST=handle_api
 do_PUT=handle_api
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);server.daemon_threads=True
thread=threading.Thread(target=server.serve_forever);thread.start()
results=[];transcript=[]
def scenario(name,flags,expected=0,checks=None,required=None,message=None,attempts=None,url='https://github.com/lab/waivers/pull/88',executable='bin/fm-pr-merge.sh',**options):
 global state,requests
 d=V/name
 if d.exists():shutil.rmtree(d)
 d.mkdir();home=d/'home';(home/'state').mkdir(parents=True);(home/'config').mkdir();(home/'data').mkdir();(d/'tmp').mkdir()
 (home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
 (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
 wt=d/'wt';wt.mkdir();env={'PATH':os.environ['PATH'],'HOME':str(home),'FM_HOME':str(home),'TMPDIR':str(d/'tmp'),'GH_CONFIG_DIR':str(home/'gh'),'GH_TOKEN':'disposable-local-token','GH_PROMPT_DISABLED':'1','GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null','HTTPS_PROXY':f'http://127.0.0.1:{server.server_port}','HTTP_PROXY':f'http://127.0.0.1:{server.server_port}','NO_PROXY':'','SSL_CERT_FILE':str(V/'cert.pem'),'FM_PR_GITHUB_BRANCH_UPDATE_POLL_INTERVAL':'0','FM_PR_GITHUB_MERGEABLE_RETRY_DELAY':'1'}
 subprocess.run(['git','init','-q',str(wt)],env=env,check=True)
 subprocess.run(['git','-C',str(wt),'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','fixture','--allow-empty'],env=env,check=True)
 subprocess.run(['git','-C',str(wt),'update-ref','refs/remotes/origin/main','HEAD'],env=env,check=True)
 (home/'state/task-x1.meta').write_text(f'window=fm-task-x1\nworktree={wt}\nproject={d}/project\nkind=ship\nmode=no-mistakes\n')
 state=dict(checks=checks if checks is not None else [runcheck(A,'FAILURE'),runcheck(B,'CANCELLED')],required=required if required is not None else [A,B],env=env,**options);requests=[]
 if state.pop('away',False):
  s=subprocess.run([str(ROOT/'bin/fm-afk-contract.sh'),'enter','--words','merge when green'],env=env,capture_output=True,text=True);assert s.returncode==0,s.stderr
 cmd=[str(ROOT/executable),'task-x1',url,*flags]
 r=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=75)
 ok=r.returncode==expected and bool(state.get('merged'))==(expected==0)
 if expected!=0:ok=ok and not state.get('merged')
 if message:ok=ok and message in (r.stdout+r.stderr)
 if attempts is not None:ok=ok and state.get('merge_attempts',0)==attempts
 if expected==0:
  meta=(home/'state/task-x1.meta').read_text();ok=ok and 'pr=https://github.com/lab/waivers/pull/88' in meta and ('pr_head='+state.get('head',HEAD)) in meta
 if state.get('away_setup'):ok=ok and state['away_setup'][0]==0
 text=f'### {name}\n$ {executable} task-x1 {url} '+ ' '.join(json.dumps(x) for x in flags)+f'\nexit={r.returncode}; local forge merged={bool(state.get("merged"))}; merge mutation attempts={state.get("merge_attempts",0)}\n'+r.stdout+r.stderr
 transcript.append(text); print(text,flush=True)
 (E/f'{name}-http.json').write_text(json.dumps(requests,indent=2));results.append({'name':name,'ok':ok,'exit':r.returncode,'merged':bool(state.get('merged')),'attempts':state.get('merge_attempts',0)})
 if not ok:raise RuntimeError('scenario failed: '+name)
try:
 waivers=['--allow-red',A,'--allow-red',B]
 scenario('two-named-waivers',waivers,attempts=1)
 scenario('green-without-waivers',[],checks=[runcheck('ci')],required=['ci'],attempts=1)
 scenario('legacy-single-waiver',['--allow-red',A],checks=[runcheck(A,'FAILURE')],required=[A],attempts=1)
 scenario('one-waiver-refuses-cancelled',['--allow-red',A],expected=1,message="check '"+B+"' is not green",attempts=0)
 scenario('cancelled-is-not-missing',['--allow-red',A,'--allow-missing',B],expected=1,message="check '"+B+"' is not green",attempts=0)
 scenario('prefix-name-does-not-waive',waivers,expected=1,checks=[runcheck(A,'FAILURE'),runcheck(B,'CANCELLED'),runcheck(B+' extended','FAILURE')],message="check '"+B+" extended' is not green",attempts=0)
 scenario('red-waiver-cannot-cover-absence',waivers+['--allow-red','security'],required=[A,B,'security'],expected=1,message="required check 'security' has not reported",attempts=0)
 scenario('separate-missing-waiver-composes',waivers+['--allow-missing','security'],required=[A,B,'security'],attempts=1)
 scenario('away-refuses-repeated-waivers',waivers,away=True,expected=2,message='--allow-red is attended-only',attempts=0)
 scenario('away-arrives-during-preflight',waivers,away_after_view=True,expected=2,message='--allow-red is attended-only',attempts=0)
 scenario('qualified-head-mismatch-refuses',waivers+['--expected-head',NEW],expected=1,message='differs from expected qualified head',attempts=0)
 scenario('push-after-preflight-refuses',waivers,push_after_view=True,expected=1,message='Head branch was modified',attempts=1)
 scenario('required-source-unreadable-refuses',waivers,rules_fail=True,expected=1,message='branch protection summary for base branch main could not be read',attempts=0)
 scenario('wrong-producer-still-refuses',waivers,app_id=123,expected=1,message='has not reported',attempts=0)
 scenario('branch-update-waits-beside-waived-failures',waivers+['--update-branch'],checks=[runcheck('ci'),runcheck(A,'FAILURE'),runcheck(B,'CANCELLED')],required=['ci',A,B],behind=True,attempts=1)
 scenario('repeated-waiver-needs-name',['--allow-red',A,'--allow-red'],expected=2,message='--allow-red requires a check name',attempts=0)
 scenario('equals-waiver-remains-refused',['--allow-red='+A],expected=2,message='requires a separate check name argument',attempts=0)
 scenario('gitlab-repeated-waivers-refused',waivers,url='https://gitlab.example/lab/waivers/-/merge_requests/88',expected=2,message='--allow-red does not apply to GitLab',attempts=0)
 scenario('forgejo-repeated-waivers-refused',waivers,url='https://forgejo.example/lab/waivers/pulls/88',expected=2,message='--allow-red does not apply to Forgejo',attempts=0)
 scenario('before-fix-reproduces-one-waiver-limit',waivers,executable='bin/.waiver-before.sh',expected=2,message='--allow-red may be specified only once',attempts=0)
finally:
 server.shutdown();server.server_close();thread.join();(E/'live-cli-transcript.log').write_text('\n'.join(transcript));(E/'live-results.json').write_text(json.dumps(results,indent=2))
