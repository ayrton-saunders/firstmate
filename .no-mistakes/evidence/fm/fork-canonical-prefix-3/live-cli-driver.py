import os, pathlib, subprocess, tempfile, shutil, json
root = pathlib.Path.cwd()
world = pathlib.Path(tempfile.mkdtemp(prefix='cli-live-', dir=root/'.test-tmp'))
env = dict(os.environ)
for k in list(env):
    if k.startswith(('FM_', 'TASKS_AXI_', 'GIT_')) or k in ('TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION','HERDR_SOCKET_PATH','REX_SESSION','REX_BLOCK'):
        env.pop(k, None)
env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_AUTHOR_NAME='Lab', GIT_AUTHOR_EMAIL='lab@example.invalid', GIT_COMMITTER_NAME='Lab', GIT_COMMITTER_EMAIL='lab@example.invalid', TMPDIR=str(root/'.test-tmp'))
def run(args, cwd=root, extra=None, ok=True):
    p=subprocess.run([str(a) for a in args],cwd=cwd,env=env | (extra or {}),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    print('$ '+ ' '.join(map(str,args)), flush=True)
    print(p.stdout.rstrip(), flush=True)
    print('exit='+str(p.returncode), flush=True)
    if ok: assert p.returncode==0, p.stdout
    return p

def git(*args,cwd=None): return run(['git',*args],cwd=cwd or world).stdout.strip()
try:
    home=world/'home'
    run([root/'bin/fm-lab-home.sh','create',home])
    e={'FM_HOME':str(home), 'FM_ROOT_OVERRIDE':str(root), 'FM_STATE_OVERRIDE':str(home/'state'), 'FM_DATA_OVERRIDE':str(home/'data'), 'FM_CONFIG_OVERRIDE':str(home/'config'), 'FM_PROJECTS_OVERRIDE':str(home/'projects')}
    print('SCENARIO ownership is home-local, idempotent, canonical and retirement is irreversible')
    url='https://github.com/disposable-lab/example/pull/7'
    c=root/'bin/fm-contributions.sh'
    run([c,'enroll','lab-task',url],extra=e)
    run([c,'enroll','lab-task',url],extra=e)
    owned=json.loads(run([c,'owned'],extra=e).stdout)
    assert owned==[{'url':url,'tasks':['lab-task'],'final':False}]
    run([c,'retire','lab-task',url,'captain','Disposable test record only'],extra=e)
    assert json.loads(run([c,'owned'],extra=e).stdout)==[]
    assert run([c,'enroll','lab-task',url],extra=e,ok=False).returncode!=0
    for bad in ('https://github.com.evil.invalid/o/r/pull/1','https://github.com/o/r/pull/1?next=2','https://github.com/o/r/issues/1'):
        assert run([c,'enroll','lab-task',bad],extra=e,ok=False).returncode!=0
    assert run([c,'enroll','../escape',url],extra=e,ok=False).returncode!=0
    other=world/'other'
    run([root/'bin/fm-lab-home.sh','create',other])
    assert json.loads(run([c,'owned'],extra=e|{'FM_HOME':str(other),'FM_STATE_OVERRIDE':str(other/'state'),'FM_DATA_OVERRIDE':str(other/'data'),'FM_CONFIG_OVERRIDE':str(other/'config')}).stdout)==[]
    print('SCENARIO PASS: ownership and retirement')
    print('SCENARIO health opt-in disabled performs no state mutation; empty opted-in home polls safely')
    before=sorted(str(p.relative_to(home)) for p in home.rglob('*'))
    health=root/'bin/fm-pr-health.sh'
    assert run([health,'poll'],extra=e).stdout==''
    assert before==sorted(str(p.relative_to(home)) for p in home.rglob('*'))
    assert run([health,'arm'],extra=e,ok=False).returncode!=0
    (home/'config/pr-health-monitor').touch()
    run([health,'poll'],extra=e)
    state=json.loads((home/'state/pr-health.json').read_text())
    print(json.dumps(state,sort_keys=True),flush=True)
    assert state['prs']=={} and state['branches']=={} and not state['ownership_error']
    print('SCENARIO PASS: health opt-in')
    print('SCENARIO updater consumes only exact local fork default and preserves dirty or moved targets')
    origin=world/'fork.git'; seed=world/'seed'; checkout=world/'checkout'
    git('init','--bare',origin);git('symbolic-ref','HEAD','refs/heads/main',cwd=origin)
    git('clone',origin,seed)
    (seed/'README.md').write_text('initial\n')
    git('add','README.md',cwd=seed);git('commit','-m','initial',cwd=seed);git('push','origin','main',cwd=seed)
    git('clone',origin,checkout)
    first=git('rev-parse','HEAD',cwd=checkout)
    (seed/'README.md').write_text('updated\n')
    git('commit','-am','advance',cwd=seed);git('push','origin','main',cwd=seed)
    second=git('rev-parse','HEAD',cwd=seed)
    (home/'state/.last-watcher-beat').touch()
    u=e|{'FM_ROOT_OVERRIDE':str(checkout)}
    update=root/'bin/fm-update.sh'
    assert run([update,'--consume-origin',first],extra=u,ok=False).returncode!=0
    assert git('rev-parse','HEAD',cwd=checkout)==first
    run([update,'--consume-origin',second],extra=u)
    assert git('rev-parse','HEAD',cwd=checkout)==second
    assert git('show','-s','--format=%P','HEAD',cwd=checkout)==first
    run([update,'--consume-origin',second],extra=u)
    (checkout/'README.md').write_text('UNLANDED LOCAL EDIT\n')
    (seed/'README.md').write_text('third upstream\n')
    git('commit','-am','advance again',cwd=seed);git('push','origin','main',cwd=seed)
    third=git('rev-parse','HEAD',cwd=seed)
    assert run([update,'--consume-origin',third],extra=u,ok=False).returncode!=0
    assert git('rev-parse','HEAD',cwd=checkout)==second
    assert (checkout/'README.md').read_text()=='UNLANDED LOCAL EDIT\n'
    print('Preserved working copy content: '+(checkout/'README.md').read_text().strip())
    print('SCENARIO PASS: exact-head updater, single-parent fast forward, idempotence, dirty refusal')
finally:
    shutil.rmtree(world)
    print('CLEANUP: disposable CLI world removed',flush=True)
