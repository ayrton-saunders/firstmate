import concurrent.futures, hashlib, json, os, pathlib, shutil, subprocess, sys
ROOT = pathlib.Path.cwd()
WORLD = ROOT / '.gate-test-tmp/live-domains'
WORLD.mkdir()
HOME = WORLD / 'home'
subprocess.run(['bash', 'bin/fm-lab-home.sh', 'create', str(HOME)], check=True, capture_output=True)
ENV = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
ENV.update(FM_HOME=str(HOME), PYTHONDONTWRITEBYTECODE='1')
DOMAINS = ('pristine-valets', 'galagoa-new')
configs = {}

def config(domain, target):
    instance = WORLD / 'domains' / domain / 'parent'
    (instance/'state').mkdir(parents=True)
    return dict(schema=2, enabled=True, home=str(HOME), source=str(ROOT),
                domain=domain, instance_root=str(instance),
                package_root=str(instance/'code/current'),
                python_executable=str(instance/'code/current/venv/bin/python'),
                journal=str(instance/'state/journal.sqlite'), ingress=str(instance/'state/ingress.sqlite'),
                egress=str(instance/'state/egress.sqlite'),
                mapping=dict(bridge_id=domain, owner_id='synthetic-owner', guild_id=domain+'-guild',
                             parent_channel_id=domain+'-channel', mapping_revision='pilot-v1', project_key='project'),
                projects={'project':str(ROOT)}, routes=[dict(target=target,project='project')])

def save(domain, data):
    path = HOME/'config/discord'/domain/'integration.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data))

for domain in DOMAINS:
    configs[domain] = config(domain, domain+'-mate')
    save(domain, configs[domain])
    (HOME/'state'/(domain+'-mate.meta')).write_text('kind=secondmate\nharness=pi\nspawn_gen=live-guard-generation\nbackend=tmux\n')
legacy = dict(configs[DOMAINS[0]])
legacy.pop('domain'); legacy.pop('instance_root')
legacy['mapping'] = dict(bridge_id='personal-discord-galagoa', project_key='galagoa', mapping_revision='pilot-v1')
legacy['projects'] = {'galagoa':str(ROOT)}
legacy['routes'] = [dict(target='legacy-mate',project='galagoa')]
legacy_path = HOME/'config/discord-integration.json'
legacy_path.write_text(json.dumps(legacy))
(HOME/'state/legacy-mate.meta').write_text('kind=secondmate\nharness=pi\nspawn_gen=legacy-generation\n')
original_legacy = legacy_path.read_bytes()

def run(surface, domain, expected, expected_error='', words='Synthetic reviewed context', target=None, extra=None, backend='tmux'):
    target = target or (domain+'-mate' if domain in DOMAINS else 'legacy-mate')
    if surface == 'hook':
        args = ['send',target,target,str(HOME/'state'/(target+'.meta')),backend]
        name = 'bin/fm-discord-hook.py'
    else:
        args = ['synthetic-request',target,words]
        name = 'bin/fm-discord-'+surface+'.py'
    env = dict(ENV)
    if domain is not None: env['FM_DISCORD_DOMAIN'] = domain
    env.update(extra or {})
    cmd = [sys.executable,'-I',str(ROOT/name),*args]
    p = subprocess.run(cmd, env=env, input=words if surface=='hook' else None,
                       capture_output=True,text=True,timeout=15)
    record = dict(surface=surface, binding=domain, target=target, input=words, exit=p.returncode,
                  stdout=p.stdout, stderr=p.stderr)
    print(json.dumps(record), flush=True)
    assert p.returncode == expected, record
    assert expected_error in p.stderr, record
    return record

try:
    print('SCENARIO 1: bound missing, disabled, invalid and symlink configs refuse instead of using enabled global config', flush=True)
    pristine = DOMAINS[0]
    path = HOME/'config/discord'/pristine/'integration.json'
    path.unlink()
    for surface in ('dispatch','reply','hook'):
        run(surface,pristine,1,'Bound domain configuration required')
    save(pristine,dict(configs[pristine],enabled=False))
    for surface in ('dispatch','reply','hook'):
        run(surface,pristine,1,'enabled')
    save(pristine,configs[pristine])
    for invalid in ('','../galagoa-new','Galagoa','x'*49):
        for surface in ('dispatch','reply','hook'):
            run(surface,invalid,1,'Invalid trusted domain binding',target=pristine+'-mate')
    path.unlink(); path.symlink_to(legacy_path)
    for surface in ('dispatch','reply','hook'):
        run(surface,pristine,1,'Bound domain configuration required')
    path.unlink(); save(pristine,configs[pristine])
    assert legacy_path.read_bytes() == original_legacy
    print('SCENARIO 1 COMPLETE: no global replacement or fallback; no journal created', flush=True)

    print('SCENARIO 2: cross-domain writable paths, shared mates and foreign mapping bindings refuse before runtime access', flush=True)
    attacks = [('egress',configs[DOMAINS[1]]['egress'],'writable path belongs to another domain'),
               ('routes',configs[DOMAINS[1]]['routes'],'separate mapped mates'),
               ('mapping',configs[DOMAINS[1]]['mapping'],'mapping belongs to another domain'),
               ('domain',DOMAINS[1],'domain/root mismatch'),
               ('python_executable',configs[DOMAINS[1]]['python_executable'],'runtime belongs to another domain')]
    for key,value,error in attacks:
        save(pristine,dict(configs[pristine],**{key:value}))
        for surface in ('dispatch','reply','hook'):
            run(surface,pristine,1,error)
    save(pristine,configs[pristine])
    print('SCENARIO 2 COMPLETE: rejected foreign custody and duplicate mate configuration', flush=True)

    print('SCENARIO 3: concurrent ordinary local hook checks select distinct domains while legacy remains usable; foreign Discord-lane target and parser-native input refuse', flush=True)
    with concurrent.futures.ThreadPoolExecutor() as pool:
        jobs = [pool.submit(run,'hook',domain,0,words='Reviewed synthetic context only for '+domain) for domain in DOMAINS]
        for job in jobs: job.result()
    run('hook',None,0,words='Existing personal/Galagoa synthetic context')
    for domain in DOMAINS:
        other = next(x for x in DOMAINS if x != domain)
        run('hook',domain,1,'cannot authorize an unmapped route',target=other+'-mate',extra={'FM_DISCORD_AUTH':'a'*32},backend='remote')
        run('hook',domain,1,'ordinary inbox text',words='/native-command')
        run('hook',domain,1,'generation fence',extra={'FM_SEND_EXPECTED_SPAWN_GEN':'foreign-generation'})
    assert legacy_path.read_bytes() == original_legacy
    journals = list((WORLD/'domains').rglob('*.sqlite'))
    assert not journals, journals
    assert not list((HOME/'state').glob('*.inbox')), 'guard-only check must not deliver'
    print(json.dumps(dict(result='SCENARIO 3 COMPLETE', global_config_sha256=hashlib.sha256(original_legacy).hexdigest(), global_config_unchanged=True, journals_created=0, inboxes_created=0, scope='Real hook routing guards only; no dispatch, return, model or Discord delivery claimed.')),flush=True)
finally:
    shutil.rmtree(WORLD)
