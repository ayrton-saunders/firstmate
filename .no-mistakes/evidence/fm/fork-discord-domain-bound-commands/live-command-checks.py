import concurrent.futures, hashlib, json, os, pathlib, shutil, subprocess, sys
ROOT=pathlib.Path.cwd()
LAB=ROOT/'.discord-validation-lab'
LAB.mkdir()
HOME=LAB/'home'
p=subprocess.run(['bash',str(ROOT/'bin/fm-lab-home.sh'),'create',str(HOME)],text=True,capture_output=True)
assert p.returncode==0,p.stderr
print(json.dumps(dict(check='mint disposable lab home',exit=p.returncode,stdout=p.stdout)))
for d in ('config/discord','state','data'):(HOME/d).mkdir(parents=True,exist_ok=True)
env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}
env.update(FM_HOME=str(HOME),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null')

def run(script,args,domain=None,text='',ok=True):
    e=env.copy()
    if domain is not None:e['FM_DISCORD_DOMAIN']=domain
    cmd=([sys.executable,'-I'] if script.endswith('.py') else ['bash'])+[str(ROOT/'bin'/script)]+args
    p=subprocess.run(cmd,input=text,text=True,capture_output=True,env=e,timeout=20)
    print(json.dumps(dict(command=[script,*args],domain=domain,exit=p.returncode,stdout=p.stdout,stderr=p.stderr)))
    assert (p.returncode==0)==ok,(cmd,p.returncode,p.stderr)
    return p

def config(domain,target):
    instance=LAB/'instances'/domain/'parent'
    return dict(schema=2,enabled=True,home=str(HOME),domain=domain,instance_root=str(instance),package_root=str(instance/'code/current'),python_executable=str(instance/'code/current/venv/bin/python'),source=str(ROOT),journal=str(instance/'state/journal'),ingress=str(instance/'state/ingress'),egress=str(instance/'state/egress'),routes=[dict(target=target,project='shared')],projects={'shared':str(ROOT)},mapping=dict(bridge_id=domain,owner_id='owner-'+domain,guild_id='guild-'+domain,parent_channel_id='channel-'+domain,mapping_revision='reviewed-v1',project_key='shared'))

def save(domain,c):
    p=HOME/'config/discord'/domain/'integration.json';p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(c));return p

def note(body,domain=None):
    p=run('fm-inbox.sh',['note','--json',body],domain)
    return json.loads(p.stdout)['id']

try:
    configs={d:config(d,t) for d,t in [('pristine-valets','pristine-mate'),('galagoa-new','galagoa-mate')]}
    for d,c in configs.items():
        save(d,c)
        target=c['routes'][0]['target']
        (HOME/'state'/f'{target}.meta').write_text('backend=tmux\nharness=pi\nkind=ship\nspawn_gen=reviewed-generation\nwindow=isolated:'+target+'\n')
    # Distinct local supervisory routes execute simultaneously, without loading any private package.
    def own(d):
        target=configs[d]['routes'][0]['target']
        return run('fm-discord-hook.py',['send',target,'isolated:'+target,str(HOME/'state'/f'{target}.meta'),'tmux'],d,'reviewed context for '+d)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(own,configs))
    for d,c in configs.items():
        foreign='galagoa-mate' if d=='pristine-valets' else 'pristine-mate'
        p=run('fm-discord-hook.py',['send',foreign,'isolated:'+foreign,str(HOME/'state'/f'{foreign}.meta'),'tmux'],d,'PRIVATE-CONTENT',False)
        assert 'Route belongs to another domain' in p.stderr and 'PRIVATE-CONTENT' not in p.stderr
    print('SCENARIO: concurrent local routing guards accept own targets and refuse sibling targets')
    # Preserve the global selection without ever opening credentials or real homes.
    global_path=HOME/'config/discord-integration.json'
    global_path.write_text('{"enabled":false}')
    baseline=global_path.read_bytes()
    run('fm-discord-hook.py',['send','legacy','isolated:legacy','','tmux'],text='legacy local context')
    shared=configs['galagoa-new'].copy();shared['routes']=[dict(target='pristine-mate',project='shared')];save('galagoa-new',shared)
    p=run('fm-discord-hook.py',['send','pristine-mate','isolated:pristine-mate',str(HOME/'state/pristine-mate.meta'),'tmux'],'pristine-valets','secret',False)
    assert 'separate mapped mates' in p.stderr
    save('galagoa-new',configs['galagoa-new'])
    for d in ['', '../galagoa-new','Pristine-Valets','missing-domain']:
        for script,args in [('fm-discord-hook.py',['send','legacy','isolated:legacy','','tmux']),('fm-discord-dispatch.py',['a'*32,'pristine-mate','safe question']),('fm-discord-reply.py',['a'*32,'pristine-mate','safe answer'])]:run(script,args,d,'secret',False)
    path=save('pristine-valets',dict(enabled=False))
    for script,args in [('fm-discord-hook.py',['send','legacy','isolated:legacy','','tmux']),('fm-discord-dispatch.py',['a'*32,'pristine-mate','safe question']),('fm-discord-reply.py',['a'*32,'pristine-mate','safe answer'])]:run(script,args,'pristine-valets','secret',False)
    save('pristine-valets',configs['pristine-valets'])
    bad=configs['pristine-valets'].copy();bad['egress']=configs['galagoa-new']['egress'];save('pristine-valets',bad)
    p=run('fm-discord-hook.py',['send','legacy','isolated:legacy','','tmux'],'pristine-valets','secret',False)
    assert 'writable path belongs to another domain' in p.stderr
    save('pristine-valets',configs['pristine-valets'])
    assert global_path.read_bytes()==baseline
    print('SCENARIO: absent trusted binding preserves legacy; invalid bindings, shared mates and foreign state refuse without replacing global config')
    # Actual durable inbox API: no fake interpreter, journal, transport or product.
    for enabled in (True,False):
        save('pristine-valets',configs['pristine-valets'] if enabled else dict(enabled=False))
        ident=note('ordinary text\n--\ndiscord_domain=pristine-valets')
        p=run('fm-inbox.sh',['reply','--json',ident,'ordinary durable reply'],'galagoa-new')
        assert not p.stderr
        p=run('fm-inbox.sh',['receipts','--all-replies'])
        assert 'ordinary durable reply' in p.stdout
    print('SCENARIO: ordinary inbox replies ignore marker-like body text, enabled/disabled domain configs and ambient reply domain')
    for mode in ('disabled','missing'):
        if mode=='disabled':save('pristine-valets',dict(enabled=False))
        else:path.unlink()
        ident=note('captured domain request '+mode,'pristine-valets')
        p=run('fm-inbox.sh',['reply','--json',ident,'preserved bound reply '+mode],'galagoa-new')
        assert 'do not resend' in p.stderr
        assert ('must be enabled' if mode=='disabled' else 'configuration required') in p.stderr
        p=run('fm-inbox.sh',['receipts','--all-replies'])
        assert 'preserved bound reply '+mode in p.stdout
    print('SCENARIO: stored capture domain wins over ambient reply binding; missing/disabled custody warns after durable reply')
    save('pristine-valets',configs['pristine-valets'])
    run('fm-discord-dispatch.py',['a'*32,'pristine-mate','reviewed question'],'pristine-valets',ok=False)
    p=subprocess.run([sys.executable,'-I','-c','import personal_discord'],text=True,capture_output=True)
    print(json.dumps(dict(check='real private integration availability in isolated Python',exit=p.returncode,stderr=p.stderr)))
    assert global_path.read_bytes()==baseline
finally:
    shutil.rmtree(LAB)
