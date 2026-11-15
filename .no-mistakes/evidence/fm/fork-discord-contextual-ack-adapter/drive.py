import json, os, shutil, subprocess, sys, time
from pathlib import Path
ROOT=Path.cwd()
WORK=ROOT/'.local-ack-validation'
EVID=Path('~/.no-mistakes/evidence/01M7GAJZRX8PBRP2K8B50ABWAT')
sys.path.insert(0,str(ROOT/'firstmate-discord'))
from personal_discord.journal import Journal, digest
from personal_discord.parent import Parent
from personal_discord.protocol import request_id, utc

PY=shutil.which('python3.14')
records=[]

def setup(name):
    home=WORK/name
    subprocess.run(['bash','bin/fm-lab-home.sh','create',str(home)],check=True,capture_output=True)
    mapping=dict(bridge_id='isolated-ack-lab',owner_id='1',guild_id='4',parent_channel_id='5',mapping_revision='1',project_key='invoice-lab')
    j=Journal(home/'state/parent.sqlite3',create=True)
    e=Journal(home/'state/egress.sqlite3',create=True)
    j.fence(False); e.fence(False); e.close()
    parent=Parent(j,mapping)
    ready=parent.renew_readiness()
    origin={**mapping, 'thread_id':'5','source_message_id':str(((int(time.time())*1000-1420070400000)<<22)+100)}
    ident=request_id(origin)
    scope=dict(origin=origin,text='Compare invoice totals with the receipts.',context=[],context_manifest=dict(observed_at=utc(time.time()),truncated=False,gaps=[],max_messages=30,max_age_seconds=86400,cross_channel_followed=False),assets=[],assets_required=False)
    request=dict(id=ident,**scope,scope_digest=digest(scope),readiness={k:ready[k] for k in ('epoch','expires')},historical=False)
    parent.capture(request,note_id='synthetic-custody-receipt')
    corr='0123456789abcdef'
    binding=dict(generation='accepted-generation',work_id='invoice-mate',correlation=corr,scope_digest=request['scope_digest'],kind='read-only')
    parent.prepare_dispatch(ident,binding=binding)
    # Synthetic routed-work input to the actual approval API; no worker is launched.
    pending=home/'state/pending-replies'; pending.mkdir()
    (pending/corr).write_text(f'corr_id={corr}\ntask_id=invoice-mate\nparent_home={home}\nphase=awaiting_report\ndelivered_epoch={int(time.time())}\n')
    config=dict(schema=2,enabled=True,home=str(home),source=str(ROOT),python_executable=PY,package_root=str(ROOT/'firstmate-discord'),journal=str(j.path),egress=str(home/'state/egress.sqlite3'),ingress=str(home/'state/ingress.sqlite3'),mapping=mapping,routes=[dict(target='invoice-mate',project='invoice-lab')],projects={'invoice-lab':str(home/'projects')})
    (home/'config/discord-integration.json').write_text(json.dumps(config))
    return home,j,parent,ident,request,binding

def command(home,body):
    path=home/'wording.py'
    path.write_text('import json,sys\nfrom pathlib import Path\np=Path(__file__).parent\ndata=json.load(sys.stdin)\nwith (p/"wording-inputs.jsonl").open("a") as f: f.write(json.dumps(data)+"\\n")\n'+body)
    (home/'config/discord-acknowledgement.json').write_text(json.dumps(dict(enabled=True,wording_command=[PY,'-I',str(path)])))

def invoke(home,ident,delay='well-over-30s',python=None):
    env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE'))}
    env.update(FM_HOME=str(home),PYTHONDONTWRITEBYTECODE='1')
    p=subprocess.run([python or PY,'-I',str(ROOT/'bin/fm-discord-acknowledge.py'),ident,'invoice-mate',delay,'Checking invoice totals against receipts.'],env=env,text=True,capture_output=True,timeout=45)
    return dict(exit=p.returncode,stdout=p.stdout,stderr=p.stderr)

def approvals(j):
    return [json.loads(r['body']) for r in j.db.execute("SELECT body FROM records WHERE family='approved-update'")]
def events(j):
    return [json.loads(r['body']) for r in j.db.execute('SELECT body FROM events ORDER BY sequence')]
def save(name,data):
    records.append(dict(scenario=name,**data)); print(json.dumps(records[-1]),flush=True)
    (EVID/'local-product.json').write_text(json.dumps(records,indent=2))

def silence(r): assert r==dict(exit=0,stdout='',stderr=''),r

try:
    h,j,p,i,req,b=setup('inactive')
    silence(invoke(h,i))
    command(h,'print("I am checking the invoice totals against the receipts.")\n')
    switch=h/'config/discord-acknowledgement.json'
    cfg=json.loads(switch.read_text());cfg['enabled']=False;switch.write_text(json.dumps(cfg))
    silence(invoke(h,i))
    switch.write_text('invalid configuration'); (h/'config/discord-integration.json').write_text('invalid configuration')
    silence(invoke(h,i,'imminent'))
    assert not approvals(j) and not events(j) and not (h/'wording-inputs.jsonl').exists()
    save('Inactive and imminent paths',dict(approvals=approvals(j),events=events(j),wording_calls=0,result='pass')); j.close()

    h,j,p,i,req,b=setup('slow')
    command(h,'print("I am checking the invoice totals against the receipts.")\n')
    r=invoke(h,i,python=shutil.which('python3')); silence(r)
    a=approvals(j); ev=events(j)
    assert len(a)==1 and len(ev)==1 and ev[0]['origin']==req['origin'] and ev[0]['generation']==b['generation']
    assert a[0]['caption_policy']=='contextual-ack-v1'
    silence(invoke(h,i)); assert len(events(j))==1
    p.emit(i,event_id='synthetic.final',generation=b['generation'],kind='final',safe_text='The invoice totals match the receipts.',terminal=True,approved=True)
    from personal_discord.integration import Integration
    environment={k:str(v) for k,v in {'HOME':h,'FM_HOME':h,'FM_ROOT_OVERRIDE':h,'FM_STATE_OVERRIDE':h/'state','FM_DATA_OVERRIDE':h/'data','FM_CONFIG_OVERRIDE':h/'config','FM_PROJECTS_OVERRIDE':h/'projects'}.items()}
    e=Journal(h/'state/egress.sqlite3'); integration=Integration(p,h/'state/ingress.sqlite3',e,source=ROOT,home=h,environment=environment); integration.publish()
    ev=events(j); assert [x['text'] for x in ev]==['I am checking the invoice totals against the receipts.','The invoice totals match the receipts.']
    save('Slow local approval, interpreter re-exec, replay and immediate final',dict(cli=r,original_origin=req['origin'],binding=b,approval=a,events=ev,result='pass')); e.close(); j.close()

    h,j,p,i,req,b=setup('closed')
    command(h,'print("I am checking the invoice totals against the receipts.")\n')
    p.emit(i,event_id='already.final',generation=b['generation'],kind='final',safe_text='The invoice totals match the receipts.',terminal=True,approved=True)
    before=events(j); r=invoke(h,i);silence(r)
    assert events(j)==before and not approvals(j)
    save('Closed final window silently carries on',dict(cli=r,approvals=approvals(j),events=events(j),result='pass'));j.close()

    h,j,p,i,req,b=setup('conflict')
    command(h,'sys.path.insert(0,'+repr(str(ROOT/'firstmate-discord'))+')\nfrom personal_discord.journal import Journal\nj=Journal(p/"state/parent.sqlite3")\nr,s=j.state("request",'+repr(i)+')\nwith j.transaction(): j.update("request",'+repr(i)+',r,{**s,"synthetic_concurrent_revision":True})\nj.close()\nprint("I am checking the invoice totals against the receipts.")\n')
    r=invoke(h,i);silence(r)
    assert not approvals(j) and not events(j)
    assert len((h/'wording-inputs.jsonl').read_text().splitlines())==1
    save('Concurrent revision Conflict silently carries on without retry',dict(cli=r,current_revision=j.state('request',i)[0],approvals=approvals(j),events=events(j),wording_calls=1,result='pass'));j.close()

    h,j,p,i,req,b=setup('unsafe')
    attempts=[]
    for text in ['Two\nlines','é'*201,'','Checking the repository.','Checking ~/private.txt.']:
        command(h,'print('+repr(text)+')\n')
        r=invoke(h,i); assert r['exit']==1 and not r['stdout'] and not approvals(j) and not events(j),r
        attempts.append(dict(proposed=text,cli=r))
    command(h,'sys.exit(7)\n'); r=invoke(h,i); assert r['exit']==1 and not approvals(j)
    attempts.append(dict(proposed='wording command exits 7',cli=r))
    command(h,'print("I am checking the invoice totals against the receipts.")\n')
    (h/'wording-inputs.jsonl').unlink()
    rev,state=j.state('request',i)
    with j.transaction(): j.update('request',i,rev,{**state,'generation':'different-generation'})
    r=invoke(h,i); assert r['exit']==1 and not (h/'wording-inputs.jsonl').exists() and not approvals(j)
    save('Unsafe copy, failed wording and stale binding cannot approve',dict(attempts=attempts,stale_binding_cli=r,approvals=approvals(j),events=events(j),result='pass'));j.close()
finally:
    pass
