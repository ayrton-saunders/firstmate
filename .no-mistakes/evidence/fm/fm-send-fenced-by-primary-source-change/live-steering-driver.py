import os, sys, json, hashlib, subprocess, pathlib, shutil
root=pathlib.Path.cwd(); lab=root/'.l'
env=os.environ.copy()
for k in ('FM_DISCORD_AUTH','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS'):
    env.pop(k,None)
env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/'t'),FM_SEND_SETTLE='0')
def run(args,check=True,**kw):
    p=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kw)
    if check and p.returncode: raise RuntimeError(f'{args}: {p.returncode}\n{p.stdout}\n{p.stderr}')
    return p
def tm(*a,**kw): return run(['tmux','-L','fm-lab',*a],**kw)
def send(target,text,auth=None,expected=0):
    if auth is None: env.pop('FM_DISCORD_AUTH',None)
    else: env['FM_DISCORD_AUTH']=auth
    p=run(['bash','bin/fm-send.sh',target,text],check=False)
    print(f'COMMAND fm-send.sh {target} [synthetic payload; bytes={len(text.encode())}] auth={"absent" if auth is None else "present"} EXIT={p.returncode}')
    print(p.stdout,end=''); print(p.stderr,end='')
    assert (p.returncode==0)==(expected==0), 'unexpected send result'
    return p
try:
    run(['bash','bin/fm-lab-home.sh','create',str(lab)])
    (lab/'t').mkdir()
    tm('new-session','-d','-s','workers','-n','fm-mapped','-x','120','-y','40','-c',str(root),'cat')
    tm('new-window','-t','workers','-n','fm-unmapped','-c',str(root),'cat')
    for target in ('mapped','unmapped'):
        (lab/f'state/{target}.meta').write_text(f'window=workers:fm-{target}\nbackend=tmux\nharness=pi\nkind=ship\nspawn_gen=live-synthetic-gen\n')
    package=lab/'package'; (package/'personal_discord').mkdir(parents=True)
    # No integration implementation or identity stub is supplied: this file is
    # solely a hash-pinned external-package artifact for the real pre-import fence.
    init=package/'personal_discord/__init__.py'; init.write_text('')
    config=dict(schema=2,enabled=True,home=str(lab),package_root=str(package),hashes={'personal_discord/__init__.py':hashlib.sha256(b'').hexdigest()},journal=str(lab/'journal'),routes=[dict(target='mapped',project='synthetic')],projects={'synthetic':str(root)},python_executable=shutil.which('python3.14'),source=str(lab/'previous-source'),source_commit='0'*40,source_digest='0'*64)
    cp=lab/'config/discord-integration.json'; cp.write_text(json.dumps(config)); original=cp.read_bytes()
    print('LIVE SETUP: real fm-send, real private tmux server 120x40, cat terminals as synthetic worker inputs; no Discord transport or identity implementation.')
    for target,auth in [('mapped',None),('unmapped',None),('unmapped','')]:
        send(target,'Continue synthetic local work.\nPreserve this second line.',auth)
    for target,count in [('mapped',1),('unmapped',2)]:
        messages=sorted((lab/f'state/{target}.inbox').glob('*.msg'))
        assert len(messages)==count
        for msg in messages:
            value=msg.read_text(); assert 'Continue synthetic local work.\nPreserve this second line.' in value
            print(f'DURABLE RECEIPT {target}/{msg.name}:\n{value}')
        print('TERMINAL '+target+':\n'+tm('capture-pane','-p','-t',f'workers:fm-{target}').stdout)
    for auth in ('', '0'*32):
        p=send('mapped','DO NOT DELIVER synthetic Discord payload',auth,expected=1)
        assert 'Discord lane fenced: stale source pin' in p.stderr
        assert 'DO NOT DELIVER' not in p.stderr
    assert len(list((lab/'state/mapped.inbox').glob('*.msg')))==1
    assert not (lab/'journal').exists()
    print('FENCE RECEIPT: mapped inbox remains one record; journal absent; payload withheld for both empty and typed Discord authority.')
    # Ordinary routing/payload protections must remain despite bypassing identity.
    for text in ('/native-command','x'*24577): send('mapped',text,expected=1)
    send('workers:fm-mapped','Explicit terminal must not bypass mapped identity',expected=1)
    meta=lab/'state/mapped.meta'; original_meta=meta.read_text()
    meta.write_text(original_meta.replace('spawn_gen=live-synthetic-gen\n',''))
    send('mapped','Missing generation must not deliver',expected=1)
    meta.write_text(original_meta)
    assert len(list((lab/'state/mapped.inbox').glob('*.msg')))==1
    assert cp.read_bytes()==original
    print('BOUNDARY RECEIPT: no additional mapped records, config pins unchanged, no journal created.')
    print('LIVE SCENARIOS COMPLETED')
finally:
    if (lab/'t'/f'tmux-{os.getuid()}'/'fm-lab').exists():
        p=tm('kill-server',check=False)
        print('CLEANUP private tmux kill-server exit='+str(p.returncode))
        if p.returncode: raise RuntimeError('private tmux cleanup failed')
    if lab.exists(): shutil.rmtree(lab)
    print('CLEANUP disposable home removed')
