"""Disposable direct CLI checks: no private-package replacement or network."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

repo = Path.cwd()
root = repo / '.validation-tmp/manual'
root.mkdir(parents=True)
home = root / 'home'
(home / 'config/discord').mkdir(parents=True)
(home / 'state').mkdir()
base = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'REX_', 'TASKS_AXI_'))}
base.update(HOME=str(home), FM_HOME=str(home), PYTHONDONTWRITEBYTECODE='1')
hook = ['python3', '-I', str(repo / 'bin/fm-discord-hook.py')]
paths = {}
configs = {}

def config(domain, target, bound=True):
    instance = root / 'instances' / domain / 'parent'
    project = root / 'projects' / domain
    project.mkdir(parents=True)
    c = dict(schema=2, enabled=True, home=str(home), package_root=str(instance / 'code/current'),
             python_executable=str(instance / 'code/current/venv/bin/python'),
             journal=str(instance / 'state/journal.sqlite'), source=str(repo),
             routes=[dict(target=target, project=domain)], projects={domain: str(project)})
    if bound:
        c.update(domain=domain, instance_root=str(instance),
                 ingress=str(instance / 'state/ingress'), egress=str(instance / 'state/egress'),
                 mapping=dict(bridge_id=domain, owner_id='owner-'+domain, guild_id='guild-'+domain,
                              parent_channel_id='channel-'+domain, mapping_revision='v1', project_key=domain))
    p = home / ('config/discord/'+domain+'/integration.json' if bound else 'config/discord-integration.json')
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(c))
    paths[domain], configs[domain] = p, c
    (home / ('state/'+target+'.meta')).write_text('backend=rex\nharness=codex\nspawn_gen=gen-'+domain+'\n')

config('legacy', 'galagoa', False)
config('pristine-valets', 'pristine-mate')
config('galagoa-new', 'new-mate')
legacy_digest = hashlib.sha256(paths['legacy'].read_bytes()).hexdigest()

def run(label, domain, target, expected, diagnostic='', payload='reviewed local context'):
    env = dict(base)
    if domain is not None:
        env['FM_DISCORD_DOMAIN'] = domain
    args = hook + ['send', target, 'fixture:'+target, str(home / ('state/'+target.removeprefix('fm-')+'.meta')), 'tmux']
    r = subprocess.run(args, input=payload, text=True, capture_output=True, env=env, timeout=15)
    assert (r.returncode == 0) == expected, (label, r.returncode, r.stderr)
    assert diagnostic in r.stderr, (label, r.stderr)
    assert payload not in r.stderr
    return f'{label}\n  command: FM_DISCORD_DOMAIN={domain!r} fm-discord-hook.py send {target} ... tmux\n  exit: {r.returncode}; stderr: {r.stderr.strip() or "(silent)"}'

try:
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        jobs = [pool.submit(run, 'Concurrent own-domain local routing: '+d, d, t, True)
                for d,t in [('pristine-valets','pristine-mate'),('galagoa-new','new-mate')]]
        for j in jobs:
            print(j.result(), flush=True)
    print(run('Unbound global route still works', None, 'galagoa', True), flush=True)
    for domain, target in [('pristine-valets','galagoa'),('pristine-valets','new-mate'),('galagoa-new','pristine-mate'),('pristine-valets','fm-new-mate')]:
        print(run('Foreign mapped local target is refused', domain, target, False, 'Route belongs to another domain'), flush=True)
    print(run('Native invocation cannot use local supervisory authority', 'pristine-valets', 'pristine-mate', False, 'parser-native', '/unsafe'), flush=True)
    for domain, diagnostic in [('', 'Invalid trusted domain binding'), ('../legacy','Invalid trusted domain binding'), ('missing-domain','Bound domain configuration required')]:
        print(run('Invalid/missing trusted binding never falls back', domain, 'galagoa', False, diagnostic), flush=True)
    original = paths['pristine-valets'].read_text()
    paths['pristine-valets'].write_text('{"enabled":false}')
    print(run('Disabled bound config never falls back', 'pristine-valets', 'galagoa', False, 'must be enabled'), flush=True)
    paths['pristine-valets'].write_text(original)
    for label, mutate, diagnostic in [
        ('Foreign writable state', lambda c: c.update(egress=configs['galagoa-new']['egress']), 'writable path belongs to another domain'),
        ('Malformed mapping', lambda c: c.update(mapping=[]), 'Malformed bound integration mapping'),
        ('Shared mate', lambda c: c.update(routes=[dict(target='new-mate',project='pristine-valets')]), 'separate mapped mates'),
    ]:
        c = json.loads(original)
        mutate(c)
        paths['pristine-valets'].write_text(json.dumps(c))
        print(run(label+' refuses before package access', 'pristine-valets', 'pristine-mate', False, diagnostic), flush=True)
    paths['pristine-valets'].write_text(original)
    assert hashlib.sha256(paths['legacy'].read_bytes()).hexdigest() == legacy_digest
    assert not list((root/'instances').glob('**/*'))
    print('Legacy global configuration bytes unchanged; no runtime, journal, ingress or egress files created.', flush=True)

    # Actual durable inbox owner: no Discord package, fake lifecycle owner or transport.
    paths['legacy'].unlink()
    def inbox(*args):
        r = subprocess.run(['bash', str(repo/'bin/fm-inbox.sh'), *args], env=base, capture_output=True, text=True, timeout=20)
        assert r.returncode == 0, (args, r.stderr)
        print('fm-inbox.sh '+ ' '.join(args)+'\n  stdout: '+r.stdout.strip()+'\n  stderr: '+(r.stderr.strip() or '(silent)'), flush=True)
        return r
    note = json.loads(inbox('note', '--request-id', 'local-domain-reconciliation', '--json', 'synthetic reviewed question').stdout)
    inbox('drain')
    reply = inbox('reply', '--json', note['id'], 'synthetic durable approved reply')
    assert 'Reply outcome requires domain reconciliation' in reply.stderr and 'do not resend' in reply.stderr
    receipts = inbox('receipts', '--all-replies')
    assert 'synthetic durable approved reply' in receipts.stdout
    print('Domain-only unbound reply remains durable and warns to reconcile without resending.', flush=True)
finally:
    shutil.rmtree(root)
