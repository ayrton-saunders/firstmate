"""Execute stock hook/inbox CLIs against synthetic configs, without a package or transport substitute."""
import concurrent.futures
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path.cwd()
BASE = os.environ.copy()
for key in tuple(BASE):
    if key.startswith('FM_'):
        del BASE[key]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

with tempfile.TemporaryDirectory(prefix='.domain-live-', dir=ROOT) as temporary:
    home = Path(temporary)
    for folder in ('config', 'state', 'data', 'projects'):
        (home / folder).mkdir()
    env = dict(BASE, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(ROOT),
               FM_STATE_OVERRIDE=str(home / 'state'), FM_DATA_OVERRIDE=str(home / 'data'),
               FM_CONFIG_OVERRIDE=str(home / 'config'), FM_PROJECTS_OVERRIDE=str(home / 'projects'))
    configs = {}
    for domain in ('pristine-valets', 'galagoa-new'):
        instance = home / 'instances' / domain / 'parent'
        project = home / 'projects' / domain
        project.mkdir()
        config = dict(schema=2, enabled=True, home=str(home), domain=domain,
                      instance_root=str(instance), package_root=str(instance / 'code/current'),
                      python_executable=str(instance / 'code/current/venv/bin/python'),
                      journal=str(instance / 'state/journal'), ingress=str(instance / 'state/ingress'),
                      egress=str(instance / 'state/egress'), assets=str(instance / 'state/assets'),
                      routes=[dict(target=domain+'-mate', project=domain)], projects={domain: str(project)},
                      source=str(ROOT), capabilities=['runner-only'], peer_capabilities=[],
                      mapping=dict(bridge_id=domain, owner_id='synthetic-owner', guild_id='synthetic-guild',
                                   parent_channel_id='synthetic-channel', mapping_revision='test-v1', project_key=domain))
        path = home / 'config/discord' / domain / 'integration.json'
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(config))
        configs[domain] = (path, config)
        (home / 'state' / (domain+'-mate.meta')).write_text('backend=zellij\nwindow=lab:fm-'+domain+'-mate\nharness=codex\nkind=secondmate\nspawn_gen=synthetic-generation\n')
    global_config = copy.deepcopy(configs['galagoa-new'][1])
    for key in ('domain','instance_root','capabilities','peer_capabilities'):
        global_config.pop(key)
    global_config['routes'] = [dict(target='personal-galagoa', project='galagoa-new')]
    global_path = home / 'config/discord-integration.json'
    global_path.write_text(json.dumps(global_config))
    (home / 'state/personal-galagoa.meta').write_text('backend=zellij\nwindow=lab:fm-personal-galagoa\nharness=codex\nspawn_gen=legacy-generation\n')
    original = digest(global_path)

    def hook(label, domain, target, expected=0, contains='', text='synthetic reviewed local steer', extra=None):
        local_env = env.copy()
        if domain is not None:
            local_env['FM_DISCORD_DOMAIN'] = domain
        if extra:
            local_env.update(extra)
        command = ['python3', '-I', str(ROOT / 'bin/fm-discord-hook.py'), 'send', target,
                   'lab:fm-'+target, str(home / 'state' / (target+'.meta')), 'zellij']
        result = subprocess.run(command, env=local_env, input=text, text=True, capture_output=True, timeout=15)
        assert result.returncode == expected, (label, result.returncode, result.stderr)
        assert contains in result.stderr, (label, result.stderr)
        assert text not in result.stderr
        return f'{label}: exit={result.returncode}; stdout={result.stdout!r}; stderr={result.stderr.strip()!r}'

    print('SCENARIO 1: Real hook, concurrent synthetic local supervisory guards; no runtime or transport replacement')
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(hook, d+' own local steer', d, d+'-mate') for d in configs]
        for future in futures:
            print(future.result())
    print(hook('Unbound existing global route remains usable', None, 'personal-galagoa'))
    print('Global config byte digest unchanged:', digest(global_path) == original)
    assert digest(global_path) == original

    print('SCENARIO 2: Adversarial local configuration and route guards')
    print(hook('Invalid selector traversal', '../galagoa-new', 'pristine-valets-mate', 1, 'Invalid trusted domain binding'))
    print(hook('Missing domain cannot fall back to global', 'missing-domain', 'personal-galagoa', 1, 'Bound domain configuration required'))
    path, config = configs['pristine-valets']
    changed = copy.deepcopy(config); changed['enabled'] = False
    path.write_text(json.dumps(changed))
    print(hook('Disabled domain cannot fall back to global', 'pristine-valets', 'personal-galagoa', 1, 'must be enabled'))
    changed = copy.deepcopy(config); changed['egress'] = configs['galagoa-new'][1]['egress']
    path.write_text(json.dumps(changed))
    print(hook('Sibling writable egress rejected', 'pristine-valets', 'pristine-valets-mate', 1, 'writable path belongs to another domain'))
    changed = copy.deepcopy(config); changed['mapping'] = [{'bridge_id':'pristine-valets'}]
    path.write_text(json.dumps(changed))
    print(hook('Malformed bound mapping rejected', 'pristine-valets', 'pristine-valets-mate', 1, 'Malformed bound integration mapping'))
    path.write_text(json.dumps(config))
    for target in ('galagoa-new-mate','fm-galagoa-new-mate','personal-galagoa'):
        print(hook('Foreign target '+target, 'pristine-valets', target, 1, 'Route belongs to another domain'))
    print(hook('Parser native invocation rejected', 'pristine-valets', 'pristine-valets-mate', 1, 'parser-native invocation', text='/synthetic-command'))
    print(hook('Typed permit cannot authorize unrelated target', 'pristine-valets', 'unmapped', 1, 'cannot authorize an unmapped route', extra={'FM_DISCORD_AUTH':'1'*32}))
    assert not (home / 'instances').exists(), 'guard created runtime/journal data unexpectedly'
    assert digest(global_path) == original
    print('No package, journal, or transport installed; no runtime/journal directory created; original global config unchanged')

    print('SCENARIO 3: Real domain-only inbox preserves durable replies and reports reconciliation')
    global_path.unlink()
    def inbox(args, domain=None):
        local_env = env.copy()
        if domain is not None:
            local_env['FM_DISCORD_DOMAIN'] = domain
        result = subprocess.run(['bash', str(ROOT / 'bin/fm-inbox.sh'), *args], env=local_env,
                                text=True, capture_output=True, timeout=20)
        print('fm-inbox.sh', ' '.join(args), 'exit=', result.returncode,
              'stdout=', result.stdout.strip(), 'stderr=', result.stderr.strip())
        assert result.returncode == 0
        return result
    note = inbox(['note','--request-id','domain-live-request','--json','synthetic domain question'])
    ident = json.loads(note.stdout)['id']
    result = inbox(['reply','--json',ident,'synthetic durable domain reply'])
    assert 'Discord final needs reconciliation, do not resend' in result.stderr
    receipts = inbox(['receipts','--all-replies'])
    assert 'synthetic durable domain reply' in receipts.stdout
    bound = inbox(['drain'], 'missing-domain')
    assert 'readiness not renewed' in bound.stderr
    print('Durable reply readable after optional outcome refusal; missing bound readiness warns without losing note')
print('Disposable homes removed; all synchronous product processes completed')
