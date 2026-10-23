import os, subprocess, pathlib, shutil
R=pathlib.Path.cwd(); W=R/'.gate-live'; W.mkdir()
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k.startswith('GIT_'): env.pop(k)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid',TMPDIR=str(R/'.gate-test-tmp'))
def run(args,e=None,ok=True):
    p=subprocess.run([str(x) for x in args],env=e or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    print('$ '+' '.join(map(str,args)),flush=True); print(p.stdout,end='',flush=True); print('exit:',p.returncode,flush=True)
    if ok: assert p.returncode==0
    return p

def g(d,*a): return run(['git','-C',d,*a]).stdout.strip()
def write(p,s): p.parent.mkdir(parents=True,exist_ok=True); p.write_text(s)
def commit(d,msg): g(d,'add','-A'); g(d,'commit','-qm',msg); return g(d,'rev-parse','HEAD')
def world(name,mode='divergent'):
    d=W/name; d.mkdir(); home=d/'home'
    for c in ['state','data','config','projects']: (home/c).mkdir(parents=True)
    fork=d/'fork.git'; canon=d/'canonical.git'; seed=d/'seed'; up=d/'up'; main=d/'main'; candidate=d/'candidate'
    run(['git','init','-q','--bare','--initial-branch=main',fork]); run(['git','clone','-q',fork,seed])
    write(seed/'README.md','base\n'); write(seed/'AGENTS.md','lab fixture\n'); write(seed/'bin/fixture.sh','exit 0\n'); write(seed/'.gitignore','.fm-secondmate-home\ndata/\nstate/\nconfig/\nprojects/\n')
    commit(seed,'base'); g(seed,'push','-q','origin','main')
    run(['git','clone','-q','--bare',fork,canon]); run(['git','clone','-q',canon,up])
    if mode!='contained':
        write(up/'README.md','canonical\n'); commit(up,'canonical'); g(up,'push','-q','origin','main')
    if mode in ['divergent','conflict']:
        if mode=='conflict': write(seed/'README.md','personal\n')
        else: write(seed/'personal.sh','printf "deliberate personal behavior\\n"\n')
        commit(seed,'personal customization'); g(seed,'push','-q','origin','main')
    run(['git','clone','-q',fork,main]); g(main,'worktree','add','-qb','integration',candidate,'main'); g(main,'remote','add','canonical',canon)
    e=env.copy(); e.update(FM_ROOT_OVERRIDE=str(candidate),FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_PROJECTS_OVERRIDE=str(home/'projects'))
    return dict(d=d,home=home,fork=fork,canon=canon,main=main,candidate=candidate,seed=seed,up=up,e=e,o=g(main,'rev-parse','HEAD'),u=g(up,'rev-parse','HEAD'),record=d/'attempt')
def cli(w,*a,ok=True,extra=None,primary=False):
    e=w['e'].copy()
    if primary:e['FM_ROOT_OVERRIDE']=str(w['main'])
    e.update(extra or {})
    return run([R/'bin/fm-update.sh',*a],e,ok)
def prep(w,**kw):return cli(w,'--prepare-upstream',w['fork'],'main',w['o'],w['canon'],'main',w['u'],w['record'],**kw)
def heading(s): print('\n### '+s,flush=True)
try:
    heading('Contained, fast-forward, and divergent integration preserve both histories without moving active source')
    for mode in ['contained','ff','divergent']:
        w=world(mode,mode); prep(w); h=g(w['candidate'],'rev-parse','HEAD')
        g(w['candidate'],'merge-base','--is-ancestor',w['o'],h);g(w['candidate'],'merge-base','--is-ancestor',w['u'],h)
        assert g(w['main'],'rev-parse','HEAD')==w['o']
        assert g(w['fork'],'rev-parse','main')==w['o']
        if mode=='divergent':assert run(['bash',w['candidate']/'personal.sh']).stdout=='deliberate personal behavior\n'
        p=prep(w); assert 'conflict-history: clean' in p.stdout; assert g(w['candidate'],'rev-parse','HEAD')==h
    heading('Merge conflict retains index and permanent conflicted history after resolution')
    w=world('conflict','conflict');p=prep(w,ok=False);assert p.returncode!=0
    assert g(w['candidate'],'ls-files','-u');write(w['candidate']/'README.md','resolved personal and canonical\n');commit(w['candidate'],'resolve')
    assert 'conflict-history: conflicted' in prep(w).stdout
    assert g(w['main'],'rev-parse','HEAD')==w['o']
    heading('Unsafe preparation refuses dirty copy, primary copy, and moving source without changing candidate')
    w=world('guards'); h=w['o'];write(w['candidate']/'untracked','keep me\n')
    assert prep(w,ok=False).returncode!=0;assert (w['candidate']/'untracked').read_text()=='keep me\n';(w['candidate']/'untracked').unlink()
    assert prep(w,ok=False,primary=True).returncode!=0
    write(w['up']/'later','moved\n');commit(w['up'],'move source');g(w['up'],'push','-q','origin','main')
    assert prep(w,ok=False).returncode!=0;assert g(w['candidate'],'rev-parse','HEAD')==h;assert not w['record'].exists()
    heading('Interrupted preparation remains unknown across conflicted qualification retries')
    w=world('interruption','ff'); hook=w['d']/'interrupt.bash'
    write(hook,'''set -T
interrupt() {
 if [ -f "$EVENTS" ] && [ "$(< "$EVENTS")" = unknown ] && [ "$(git -C "$CANDIDATE" rev-parse HEAD)" != "$OLD" ]; then
  trap - DEBUG
  kill -KILL "$$"
 fi
}
trap interrupt DEBUG
''')
    assert prep(w,ok=False,extra={'BASH_ENV':str(hook),'EVENTS':str(w['record']/'events'),'CANDIDATE':str(w['candidate']),'OLD':w['o']}).returncode!=0
    assert (w['record']/'events').read_text()=='unknown\n';h=g(w['candidate'],'rev-parse','HEAD');assert h==w['u']
    # Qualification is refused before any genuine evidence could authorize landing.
    evidence=pathlib.Path('/Users/ayrton/.no-mistakes/evidence/01M5N4TJW593J0BXGY34H02RHB/updater-targeted.log')
    for history in ['conflicted','clean','conflicted']:
        p=cli(w,'--qualify-upstream',w['record'],h,h,h,w['o'],h,history,evidence,ok=False)
        assert p.returncode!=0 and 'unknown conflict history' in p.stdout
    retained=(w['record']/'events').read_text()
    write(hook,'''set -T
interrupt() {
 if [ "$(tail -1 "$EVENTS")" = conflicted ] && [ "$(wc -l < "$EVENTS")" -gt "$LINES" ]; then
  trap - DEBUG
  kill -KILL "$$"
 fi
}
trap interrupt DEBUG
''')
    p=cli(w,'--qualify-upstream',w['record'],h,h,h,w['o'],h,'conflicted',evidence,ok=False,extra={'BASH_ENV':str(hook),'EVENTS':str(w['record']/'events'),'LINES':str(len(retained.splitlines()))})
    assert p.returncode in [-9,137]
    assert (w['record']/'events').read_text()==retained+'unknown\nconflicted\n'
    assert 'conflict-history: unknown' in prep(w).stdout
    for history in ['clean','conflicted']:
        p=cli(w,'--qualify-upstream',w['record'],h,h,h,w['o'],h,history,evidence,ok=False)
        assert p.returncode!=0 and 'unknown conflict history' in p.stdout
    print('Persisted append-only public task events:',(w['record']/'events').read_text(),flush=True)
    assert not (w['record']/'qualifications').exists()
    heading('Pinned origin consumption preserves independent secondmate origin and private data')
    w=world('consumption','contained'); sm=w['d']/'independent'; remote=w['d']/'independent.git'
    run(['git','clone','-q','--bare',w['fork'],remote]);run(['git','clone','-q',remote,sm]);write(sm/'.fm-secondmate-home','sm1\n');write(sm/'data/private','private secondmate data\n')
    write(w['home']/'data/secondmates.md',f'| sm1 | isolated fixture | {sm} |\n')
    # Registry schema consumed by the actual updater, no fake endpoint is advertised.
    write(w['home']/'state/sm1.meta',f'kind=secondmate\nhome={sm}\nworktree={sm}\nproject={sm}\n')
    write(w['seed']/'README.md','updated fork\n');target=commit(w['seed'],'advance fork');g(w['seed'],'push','-q','origin','main')
    p=cli(w,'--consume-origin',w['o'],ok=False,primary=True);assert p.returncode!=0;assert 'origin moved' in p.stdout
    assert g(w['main'],'rev-parse','HEAD')==w['o'];assert g(sm,'rev-parse','HEAD')==w['o']
    write(w['main']/'untracked','preserve dirty\n');assert cli(w,'--consume-origin',target,ok=False,primary=True).returncode!=0
    assert (w['main']/'untracked').read_text()=='preserve dirty\n';(w['main']/'untracked').unlink()
    p=cli(w,'--consume-origin',target,primary=True);assert g(w['main'],'rev-parse','HEAD')==target
    assert 'secondmate sm1: already current' in p.stdout
    assert g(sm,'rev-parse','HEAD')==w['o'];assert g(sm,'remote','get-url','origin')==str(remote);assert (sm/'data/private').read_text()=='private secondmate data\n'
    assert 'restart-secondmates: none' in p.stdout
    heading('Dirty and uniquely divergent homes are skipped, without erasing local content')
    write(sm/'untracked','secondmate dirty\n');p=cli(w,'--consume-origin',target,primary=True);assert 'secondmate sm1: skipped: dirty' in p.stdout;assert (sm/'untracked').read_text()=='secondmate dirty\n';(sm/'untracked').unlink()
    # Advance its own origin differently so local unique work is genuinely divergent.
    tmp=w['d']/'remote-seed';run(['git','clone','-q',remote,tmp]);write(tmp/'remote-only','remote\n');commit(tmp,'independent remote');g(tmp,'push','-q','origin','main')
    write(sm/'local-only','preserve unique local\n');local=commit(sm,'unique local');p=cli(w,'--consume-origin',target,primary=True)
    assert 'secondmate sm1: skipped:' in p.stdout;assert g(sm,'rev-parse','HEAD')==local;assert (sm/'local-only').read_text()=='preserve unique local\n'
    markers=list((w['home']/'state/.secondmate-update-reconcile').glob('*'));assert markers
    for marker in markers:print('Persisted reconciliation:',marker.read_text(),flush=True)
    heading('All live CLI assertions passed; no forge publication or primary activation performed')
finally:
    shutil.rmtree(W)
