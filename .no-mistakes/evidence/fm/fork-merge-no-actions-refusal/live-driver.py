import os, json, ssl, socketserver, threading, subprocess, pathlib, http.server, shutil, sys
ROOT=pathlib.Path.cwd(); BASE=ROOT/'.live-validation'; E=pathlib.Path('~/.no-mistakes/evidence/01M7C7WNFVD2C14PE054N44WQG')
HEAD='a'*40
state={}; requests=[]
class API(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*a): pass
    def do_CONNECT(self):
        if self.path != 'api.github.com:443':
            self.send_error(403); return
        self.send_response(200); self.end_headers()
        self.connection=context.wrap_socket(self.connection,server_side=True)
        self.rfile=self.connection.makefile('rb'); self.wfile=self.connection.makefile('wb')
        self.close_connection=False
    def do_GET(self): self.route()
    def do_POST(self): self.route()
    def do_PATCH(self): self.route()
    def route(self):
        body=self.rfile.read(int(self.headers.get('Content-Length',0)))
        requests.append({'method':self.command,'path':self.path,'body':body.decode()})
        code=200; result={}; raw=False
        p=self.path
        if p=='/graphql':
            obj=json.loads(body); q=obj.get('query','')
            if '__type(' in q:
                names=['PullRequest','StatusCheckRollupContextConnection'] if 'PullRequest_fields{' in q else ['WorkflowRun']
                result={'data':{n:{'fields':[{'name':x} for x in (['isInMergeQueue','mergeStateStatus','statusCheckRollup'] if n=='PullRequest' else [])]} for n in names}}
            elif 'mergePullRequest' in q:
                state['merged']=True
                result={'data':{'mergePullRequest':{'clientMutationId':None}}}
            else:
                pr={'id':'PR_local','number':1,'state':'MERGED' if state.get('merged') else 'OPEN','merged':bool(state.get('merged')),'isInMergeQueue':False,'isDraft':False,'mergeable':'MERGEABLE','mergeStateStatus':'CLEAN','headRefOid':HEAD,'baseRefName':'main','headRefName':'feature','headRepositoryOwner':{'login':'example'},'headRepository':{'id':'R_local','name':'repo','nameWithOwner':'example/repo'},'baseRepository':{'id':'R_local','name':'repo','nameWithOwner':'example/repo'},'url':'https://github.com/example/repo/pull/1','viewerCanUpdate':True,'statusCheckRollup':{'nodes':[{'commit':{'statusCheckRollup':{'contexts':{'nodes':state.get('checks',[]),'pageInfo':{'hasNextPage':False,'endCursor':None}}}}}]}}
                result={'data':{'repository':{'id':'R_local','name':'repo','nameWithOwner':'example/repo','defaultBranchRef':{'name':'main'},'pullRequest':pr,'hasIssuesEnabled':True,'mergeCommitAllowed':True,'squashMergeAllowed':True,'rebaseMergeAllowed':True}}}
        elif '/branches/' in p and '/rules/' not in p: result={'name':'main','protected':False,'protection':{'enabled':False}}
        elif '/rules/branches/' in p: result=state.get('rules',[])
        elif '/check-suites?' in p:
            if state.get('suite_error'): code=503; result={'message':'unavailable'}
            elif state.get('malformed'): result={'unexpected':True}
            else: result={'total_count':state.get('suites',0),'check_suites':([{'id':1,'app':{'id':15368}}] if state.get('suites') else [])}
        elif '/check-runs' in p: result={'total_count':0,'check_runs':[]}
        elif '/contents/.github/workflows?' in p:
            if state.get('listing_error'): code=503; result={'message':'unavailable'}
            elif state.get('workflow') is None: code=404; result={'message':'Not Found'}
            else: result=[{'name':'ci.yml','type':'file','path':'.github/workflows/ci.yml'}]
        elif '/contents/.github/workflows/ci.yml?' in p:
            if state.get('file_error'): code=503; result={'message':'unavailable'}
            else: result=state['workflow']; raw=True
        else: code=404; result={'message':'unimplemented '+p}
        data=result.encode() if raw else json.dumps(result).encode()
        self.send_response(code); self.send_header('Content-Type','text/plain' if raw else 'application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
class Server(socketserver.ThreadingMixIn,http.server.HTTPServer): daemon_threads=True
subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(BASE/'key.pem'),'-out',str(BASE/'cert.pem'),'-days','1','-subj','/CN=api.github.com','-addext','subjectAltName=DNS:api.github.com'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(BASE/'cert.pem',BASE/'key.pem')
server=Server(('127.0.0.1',0),API); thread=threading.Thread(target=server.serve_forever); thread.start()
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_','GITHUB_','GH_','HERDR_')) or k in ('TMUX','NO_MISTAKES_GATE','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY'): env.pop(k,None)
env.update(XDG_CACHE_HOME=str(BASE/'cache'),HOME=str(BASE/'user'),GH_CONFIG_DIR=str(BASE/'gh'),GH_TOKEN='local-synthetic-token',GH_PROMPT_DISABLED='1',GH_NO_UPDATE_NOTIFIER='1',GH_NO_EXTENSION_UPDATE_NOTIFIER='1',HTTPS_PROXY=f'http://127.0.0.1:{server.server_port}',HTTP_PROXY=f'http://127.0.0.1:{server.server_port}',NO_PROXY='',SSL_CERT_FILE=str(BASE/'cert.pem'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',TMPDIR=str(BASE/'tmp'))
(BASE/'user').mkdir(exist_ok=True); (BASE/'gh').mkdir(exist_ok=True)
results=[]
def case(name, settings, args=(), expected=1, needle=None, away=False, url='https://github.com/example/repo/pull/1'):
    state.clear(); state.update(settings); requests.clear()
    home=BASE/name
    subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True,capture_output=True,env=env)
    wt=home/'fixture'; wt.mkdir()
    for cmd in [['git','init','-q',str(wt)],['git','-C',str(wt),'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','--allow-empty','-qm','fixture']]: subprocess.run(cmd,env=env,check=True)
    (home/'state/task-x1.meta').write_text(f'window=fm-task-x1\nworktree={wt}\nproject={home}/project\nkind=ship\nmode=no-mistakes\n')
    e=env|{'FM_HOME':str(home)}
    if away:
        r=subprocess.run(['bin/fm-afk-contract.sh','enter','--words','merge task-x1 when green'],env=e,capture_output=True,text=True)
        if r.returncode: raise RuntimeError(r.stderr)
    cmd=['bin/fm-pr-merge.sh','task-x1',url,*args]
    r=subprocess.run(cmd,env=e,capture_output=True,text=True,timeout=60)
    merged=bool(state.get('merged'))
    ok=r.returncode==expected and (not needle or needle in r.stderr+r.stdout) and merged==(expected==0)
    artifact={'name':name,'command':' '.join(cmd),'exit':r.returncode,'expected_exit':expected,'merged_in_local_api':merged,'pass':ok,'stdout':r.stdout,'stderr':r.stderr,'requests':requests.copy(),'persisted_meta':(home/'state/task-x1.meta').read_text()}
    (E/(name+'.json')).write_text(json.dumps(artifact,indent=2))
    results.append(artifact)
    print(name, 'PASS' if ok else 'FAIL',r.returncode,flush=True)
    if not ok: print(r.stdout,r.stderr,requests,flush=True)
    shutil.rmtree(home)
try:
    workflow='on: pull_request\njobs: {}\n'
    case('no-suite-refused',{'workflow':workflow},needle='has no GitHub Actions check suite')
    for variant, body in {'mapping':'on:\n  pull_request:\n', 'block-list':'on:\n  - push\n  - pull_request # checks\n', 'flow-list':'on: [push, pull_request]\n','quoted':'"on":\n  "pull_request":\n'}.items():
        case('no-suite-'+variant,{'workflow':body},needle='has no GitHub Actions check suite')
    success={'__typename':'StatusContext','context':'ci','state':'SUCCESS','createdAt':'2026-11-14T00:00:00Z'}
    case('status-only-refused',{'workflow':workflow,'checks':[success],'rules':[{'type':'required_status_checks','parameters':{'required_status_checks':[{'context':'ci'}]}}]},needle='has no GitHub Actions check suite')
    case('suite-present-merges',{'workflow':workflow,'suites':1},expected=0,needle='every unwaived check green')
    case('no-workflows-merges',{'workflow':None},expected=0,needle='every unwaived check green')
    case('other-events-merges',{'workflow':'on:\n  pull_request_target:\n  push:\n'},expected=0,needle='every unwaived check green')
    case('waiver-merges',{'workflow':workflow},['--allow-no-actions'],0,'waived by --allow-no-actions')
    case('waiver-red-refused',{'workflow':workflow,'checks':[{'__typename':'StatusContext','context':'lint','state':'FAILURE','createdAt':'2026-11-14T00:00:00Z'}]},['--allow-no-actions'],1,"check 'lint' is not green")
    case('waiver-missing-refused',{'workflow':workflow,'rules':[{'type':'required_status_checks','parameters':{'required_status_checks':[{'context':'ci'}]}}]},['--allow-no-actions'],1,'required')
    for name, settings, needle in [('suite-read-error',{'suite_error':True},'check suites at head'),('suite-malformed',{'malformed':True},'check suites at head'),('workflow-list-error',{'listing_error':True},'workflow directory'),('workflow-file-error',{'file_error':True},'workflow .github/workflows/ci.yml')]:
        case(name,{'workflow':workflow}|settings,needle=needle)
    case('waiver-suite-read-error',{'suite_error':True},['--allow-no-actions'],1,'check suites at head')
    case('waiver-away-refused',{'workflow':workflow},['--allow-no-actions'],2,'attended-only',away=True)
    case('waiver-value-refused',{},['--allow-no-actions=yes'],2,'takes no value')
    case('waiver-gitlab-refused',{},['--allow-no-actions'],2,'applies only to GitHub',url='https://gitlab.example/group/repo/-/merge_requests/1')
    case('waiver-forgejo-refused',{},['--allow-no-actions'],2,'applies only to GitHub',url='https://forgejo.example/group/repo/pulls/1')
finally:
    server.shutdown(); server.server_close(); thread.join()
    (E/'live-results.json').write_text(json.dumps([{'name':r['name'],'pass':r['pass'],'exit':r['exit']} for r in results],indent=2))
sys.exit(0 if all(r['pass'] for r in results) else 1)
