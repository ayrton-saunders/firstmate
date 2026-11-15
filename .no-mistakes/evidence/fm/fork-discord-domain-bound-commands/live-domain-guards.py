"""Drive actual command boundaries with disposable local configs; no package doubles."""
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path.cwd()
PY = shutil.which('python3.14')
assert PY
lab = Path(tempfile.mkdtemp(prefix='.fm-domain-live-', dir=ROOT))
base_env = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('HERDR_ENV', 'TMUX')}

def run(label, command, domain=None, expected=0, contains=None, words='Reviewed synthetic context', extra=None):
    env = dict(base_env, FM_HOME=str(lab))
    if domain is not None:
        env['FM_DISCORD_DOMAIN'] = domain
    env.update(extra or {})
    p = subprocess.run(command, input=words, text=True, capture_output=True, env=env, timeout=20)
    print(f'[{label}] exit={p.returncode}\n{p.stdout}{p.stderr}', flush=True)
    assert p.returncode == expected, label
    if contains:
        assert contains in p.stdout + p.stderr, label
    return p

hook = [PY, '-I', str(ROOT/'bin/fm-discord-hook.py')]
try:
    subprocess.run(['bash', 'bin/fm-lab-home.sh', 'create', str(lab)], check=True, capture_output=True)
    configs = {}
    for domain in ('pristine-valets', 'galagoa-new'):
        instance = lab/'instances'/domain/'parent'
        (instance/'state').mkdir(parents=True)
        (instance/'code/current/venv/bin').mkdir(parents=True)
        (instance/'code/current/venv/bin/python').symlink_to(PY)
        config = dict(schema=2, enabled=True, home=str(lab), source=str(ROOT),
                      domain=domain, instance_root=str(instance),
                      package_root=str(instance/'code/current'),
                      python_executable=str(instance/'code/current/venv/bin/python'),
                      mapping=dict(bridge_id=domain, owner_id='synthetic-owner', guild_id=domain,
                                   parent_channel_id=domain, project_key='sample', mapping_revision='pilot-v1'),
                      projects={'sample':str(ROOT)}, routes=[dict(target=domain+'-mate', project='sample')],
                      **{k:str(instance/'state'/(k+'.sqlite')) for k in ('journal','ingress','egress')})
        path = lab/'config/discord'/domain/'integration.json'
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(config))
        configs[domain] = (path, config)
    legacy = dict(configs['galagoa-new'][1])
    for k in ('domain', 'instance_root'):
        legacy.pop(k)
    legacy['mapping'] = dict(bridge_id='personal-discord-galagoa', project_key='galagoa', mapping_revision='pilot-v1')
    legacy['projects'] = {'galagoa':str(ROOT)}
    legacy['routes'] = [dict(target='legacy-mate', project='galagoa')]
    global_path = lab/'config/discord-integration.json'
    global_path.write_text(json.dumps(legacy))
    original = global_path.read_bytes()
    run('No selector preserves existing global routing while domain configs coexist', hook+['send','unmapped','local:unmapped','', 'tmux'])
    assert global_path.read_bytes() == original
    with concurrent.futures.ThreadPoolExecutor() as pool:
        futures = [pool.submit(run, 'Concurrent '+d+' refuses permit on sibling route',
                              hook+['send', other+'-mate', other+'-mate', '', 'tmux'], d, 1,
                              'Discord permit cannot authorize an unmapped route',
                              extra={'FM_DISCORD_AUTH':'a'*32})
                   for d, other in [('pristine-valets','galagoa-new'),('galagoa-new','pristine-valets')]]
        for f in futures:
            f.result()
    for selector in ('', '../galagoa-new', '/galagoa-new', 'Galagoa'):
        run('Untrusted selector '+repr(selector), hook+['send','x','x','','tmux'], selector, 1,
            'Invalid trusted domain binding')
    path, config = configs['pristine-valets']
    for key, value, error in [('egress', configs['galagoa-new'][1]['egress'], 'Integration writable path belongs to another domain'),
                              ('routes', configs['galagoa-new'][1]['routes'], 'Bound domains require separate mapped mates')]:
        path.write_text(json.dumps(dict(config, **{key:value})))
        run('Refuse foreign '+key, hook+['send','x','x','','tmux'], 'pristine-valets', 1, error)
        path.write_text(json.dumps(config))
    global_path.unlink()
    for mode in ('disabled','missing'):
        if mode == 'disabled':
            path.write_text(json.dumps(dict(config, enabled=False)))
        else:
            path.unlink()
        error = 'Bound domain configuration must be enabled' if mode == 'disabled' else 'Bound domain configuration required'
        run('No global config: '+mode+' bound hook refuses', hook+['send','x','x','','tmux'], 'pristine-valets', 1, error)
        note = run(mode+' bound inbox capture', ['bash','bin/fm-inbox.sh','note','--json','synthetic domain request'], 'pristine-valets')
        ident = json.loads(note.stdout)['id']
        run(mode+' bound readiness reports refusal', ['bash','bin/fm-inbox.sh','drain'], 'pristine-valets', contains='readiness not renewed')
        run(mode+' bound durable reply reports outcome refusal', ['bash','bin/fm-inbox.sh','reply',ident,'reviewed synthetic answer'], 'pristine-valets', contains='do not resend')
    path.write_text(json.dumps(config))
    (lab/'state/pristine-valets-mate.meta').write_text('kind=secondmate\nspawn_gen=synthetic-gen\n')
    run('Actual dispatch reaches unavailable enrolled package boundary',
        [PY,'-I','bin/fm-discord-dispatch.py','synthetic-request','pristine-valets-mate','Reviewed synthetic question'],
        'pristine-valets', 1)
    probe = subprocess.run([PY,'-I','-c','import personal_discord'], capture_output=True, text=True)
    print('[Approved private package availability probe] exit='+str(probe.returncode)+'\n'+probe.stderr)
    assert probe.returncode != 0
    assert not list((lab/'instances').rglob('*.sqlite'))
    print('No journal or egress was created by refusal checks. All local guard assertions passed.')
finally:
    shutil.rmtree(lab)
    print('Disposable local home removed; no child services started.')
