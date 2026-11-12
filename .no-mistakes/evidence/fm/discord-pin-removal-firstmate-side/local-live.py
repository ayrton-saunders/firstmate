"""Disposable live local CLI scenarios; no private Discord implementation is mocked."""
import json, os, pathlib, shutil, subprocess, sys
ROOT = pathlib.Path.cwd()
LAB = ROOT / '.l'
LOG = pathlib.Path('~/.no-mistakes/evidence/01M77XY7AC8X3YDB3MWF2RKJFR/local-live.log')
env = dict(os.environ)
for key in list(env):
    if key.startswith('FM_') or key in ('TMUX', 'TMUX_PANE'):
        env.pop(key)
env.update(FM_HOME=str(LAB), TMUX_TMPDIR=str(LAB / 'tmux'), PYTHONDONTWRITEBYTECODE='1')
tmux = ['tmux', '-L', 'fm-lab']
lines = []
def run(args, *, stdin=None, expect=0, changes=None):
    p = subprocess.run(args, input=stdin, text=True, capture_output=True,
                       env=env | (changes or {}), timeout=30)
    lines.append('$ ' + ' '.join(map(str, args)))
    lines.append(f'exit={p.returncode}\n{p.stdout}{p.stderr}')
    assert p.returncode == expect, (args, p.returncode, p.stderr)
    return p

def config_write(config):
    (LAB / 'config/discord-integration.json').write_text(json.dumps(config))

def refuse(args, expected, config, *, changes=None, stdin='DO-NOT-ECHO-SYNTHETIC-SECRET'):
    config_write(config)
    p = run(args, stdin=stdin, expect=1, changes=changes)
    assert expected in p.stderr, p.stderr
    assert 'DO-NOT-ECHO-SYNTHETIC-SECRET' not in p.stderr
    assert 'Traceback' not in p.stderr
    assert not (LAB / 'journal').exists()

assert not LAB.exists()
try:
    run(['bash', 'bin/fm-lab-home.sh', 'create', str(LAB)])
    (LAB / 'tmux').mkdir()
    run(tmux + ['new-session', '-d', '-s', 'fm-lab-discord', '-n', 'fm-mapped',
                '-x', '120', '-y', '30', '-c', str(ROOT), 'cat'])
    (LAB / 'state/mapped.meta').write_text('window=fm-lab-discord:fm-mapped\nbackend=tmux\nkind=ship\nspawn_gen=local-live-generation\n')
    config = dict(schema=2, enabled=True, home=str(LAB),
                  package_root=str(LAB / 'unavailable-private-package'), hashes={},
                  journal=str(LAB / 'journal'), routes=[dict(target='mapped', project='fixture')],
                  projects={'fixture': str(ROOT)}, python_executable=str(LAB / 'unavailable-python'),
                  source='/descriptive/not-an-identity', source_commit='0' * 40, source_digest='1' * 64)
    send = ['bash', 'bin/fm-send.sh', 'mapped']
    for n, mode in enumerate(('present', 'stale', 'absent'), 1):
        c = dict(config)
        if mode == 'stale':
            c.update(source_commit='stale-public-status', source_digest='stale-public-status')
        if mode == 'absent':
            c.pop('source_commit'); c.pop('source_digest')
        config_write(c)
        text = f'Local live steering: source status {mode}'
        run(send + [text], changes={'FM_SEND_SETTLE': '0'})
        receipt = LAB / f'state/mapped.inbox/{n:03}.msg'
        assert receipt.is_file() and text in receipt.read_text()
        lines.append(f'Durable inbox receipt {receipt.name}:\n{receipt.read_text()}')
        assert not (LAB / 'journal').exists()
    lines.append('Real private tmux endpoint readback:')
    run(tmux + ['capture-pane', '-p', '-t', 'fm-lab-discord:fm-mapped'])
    assert len(list((LAB / 'state/mapped.inbox').glob('*.msg'))) == 3
    lines.append('LOCAL SOURCE STATUS SCENARIO: durably queued all three steers without invoking private interpreter, package or journal. The cat endpoint is not an agent: fm-send explicitly retained the records for recovery and did not type a doorbell. This proves durable local admission only, not agent execution.')

    # Independently specified retained boundary: wrong home must never enqueue.
    c = dict(config, home=str(ROOT / 'another-synthetic-home'))
    refuse(send + ['DO-NOT-ECHO-SYNTHETIC-SECRET'], 'Integration schema/home mismatch', c)
    c = dict(config, schema=1)
    refuse(send + ['DO-NOT-ECHO-SYNTHETIC-SECRET'], 'Integration schema/home mismatch', c)
    refuse(send + ['/parser-command'], 'ordinary inbox text', config)
    refuse(send + ['DO-NOT-ECHO-SYNTHETIC-SECRET'], 'generation fence conflicts', config,
           changes={'FM_SEND_EXPECTED_SPAWN_GEN': 'wrong-generation'})

    # Full verifier can be exercised up to permit admission with a hash manifest
    # over inert synthetic release bytes; no journal/routing module is provided.
    package = LAB / 'synthetic-release'
    (package / 'personal_discord').mkdir(parents=True)
    release = package / 'personal_discord/__init__.py'
    release.write_bytes(b'# synthetic unexecuted release bytes\n')
    import hashlib
    c = dict(config, package_root=str(package), python_executable=shutil.which('python3.14'),
             hashes={'personal_discord/__init__.py': hashlib.sha256(release.read_bytes()).hexdigest()})
    hook = ['python3.14', '-I', 'bin/fm-discord-hook.py', 'send', 'mapped',
            'fm-lab-discord:fm-mapped', str(LAB / 'state/mapped.meta'), 'tmux']
    for mode in ('stale', 'absent'):
        d = dict(c)
        if mode == 'stale': d.update(source_commit='obsolete', source_digest='obsolete')
        else: d.pop('source_commit'); d.pop('source_digest')
        refuse(hook, 'typed parent-issued lane permit', d, changes={'FM_DISCORD_AUTH': ''})
    # Imported callers must retain safe home and release-integrity diagnostics.
    for name in ('dispatch', 'reply'):
        command = ['python3.14', '-I', f'bin/fm-discord-{name}.py', 'a' * 32, 'mapped', 'Harmless local question']
        refuse(command, 'Integration schema/home mismatch', dict(c, home='/wrong-public-home'))
        refuse(command, 'Integration release hash mismatch', dict(c, hashes={}))
    config_write(c)
    (LAB / 'config/discord-integration.json').write_text('{"enabled":true,"enabled":false}')
    p = run(['python3.14', '-I', 'bin/fm-discord-hook.py', 'send'], expect=1)
    assert 'Duplicate configuration field' in p.stderr
    assert len(list((LAB / 'state/mapped.inbox').glob('*.msg'))) == 3
    lines.append('LOCAL REFUSAL SCENARIO: home/schema, parser, generation, typed permit, duplicate configuration and imported release checks refused with named diagnostics; no rejected steer enqueued or journal opened.')
finally:
    if (LAB / 'tmux').exists():
        p = subprocess.run(tmux + ['kill-server'], env=env, capture_output=True, text=True, timeout=10)
        lines.append(f'private tmux cleanup exit={p.returncode}: {p.stderr}')
    if LAB.exists(): shutil.rmtree(LAB)
    lines.append('Disposable home removed; private server stopped.')
    LOG.write_text('\n'.join(lines) + '\n')
print('Local live scenarios passed; evidence:', LOG)
