import os, pathlib, subprocess, json, shutil
ROOT = pathlib.Path.cwd()
BASE = ROOT / '.live-validation' / 'product'
BASE.mkdir(parents=True, exist_ok=True)
ENV = os.environ.copy()
for k in list(ENV):
    if k.startswith('FM_') or k in ('GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_CONFIG_COUNT','TMUX','HERDR_SESSION','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
        ENV.pop(k, None)
ENV.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid',TMPDIR=str(ROOT / '.live-validation' / 'tmp'))

def run(*args, env=None, expected=0, show=False):
    p=subprocess.run([str(a) for a in args],env=env or ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if show:
        print('$ '+' '.join(str(a) for a in args),flush=True)
        print(p.stdout, end='',flush=True)
        print('exit:',p.returncode,flush=True)
    assert p.returncode == expected, (args,p.returncode,p.stdout)
    return p.stdout.strip()

def git(repo,*args,**kwargs): return run('git','-C',repo,*args,**kwargs)
def put(path,text): path.parent.mkdir(parents=True,exist_ok=True); path.write_text(text)
def commit(repo,name): git(repo,'add','-A'); git(repo,'commit','-qm',name); return git(repo,'rev-parse','HEAD')
def tip(repo): return git(repo,'rev-parse','HEAD')
def world(name):
    w=BASE/name; w.mkdir()
    for d in ('home/data','home/state','home/config'): (w/d).mkdir(parents=True,exist_ok=True)
    git(w,'init','-q','--bare',w/'origin.git'); git(w/'origin.git','symbolic-ref','HEAD','refs/heads/main')
    git(w,'clone','-q',w/'origin.git',w/'seed')
    put(w/'seed/AGENTS.md','Fixture instructions\n'); put(w/'seed/.gitignore','.fm-secondmate-home\ndata/\nstate/\nconfig/\nprojects/\n')
    put(w/'seed/bin/note','fixture data, not a script\n'); put(w/'seed/shared','base\n')
    commit(w/'seed','base'); git(w/'seed','push','-q','origin','main')
    git(w,'clone','-q','--bare',w/'origin.git',w/'upstream.git')
    git(w,'clone','-q',w/'origin.git',w/'primary')
    git(w/'primary','remote','add','upstream',w/'upstream.git')
    git(w,'clone','-q',w/'upstream.git',w/'upstream')
    git(w,'clone','-q',w/'origin.git',w/'mate')
    put(w/'mate/.fm-secondmate-home','solo\n')
    put(w/'home/data/secondmates.md',f'- solo - Disposable inactive mate (home: {w}/mate; scope: fixture; projects: none; added 2026-10-15)\n')
    put(w/'validator',f'#!/bin/bash\ntouch "{w}/VALIDATOR_WAS_CALLED"\nexit 99\n'); (w/'validator').chmod(0o755)
    put(w/'home/config/fork-publication','enabled\n'); put(w/'home/config/fork-validation',str(w/'validator')+'\n')
    return w

def update(w,*args,expected=0):
    env=ENV.copy(); env.update(FM_ROOT_OVERRIDE=str(w/'primary'),FM_HOME=str(w/'home'))
    return run(ROOT/'bin/fm-update.sh',*args,env=env,expected=expected,show=True)
def snapshots(w): return {p:tip(w/p) for p in ('primary','mate','origin.git','upstream.git')}
def no_old_actions(w):
    assert not (w/'VALIDATOR_WAS_CALLED').exists()
    for name in ('validation.log','push.log'):
        assert not list((w/'home').rglob(name))
    assert (w/'home/config/fork-publication').read_text()=='enabled\n'
    assert (w/'home/config/fork-validation').read_text()==str(w/'validator')+'\n'
def fields(text): return dict(line.split(': ',1) for line in text.splitlines() if line.startswith('integration-'))

print('REAL CLI / REAL GIT / LOCAL DISPOSABLE REMOTES; no command stubs or fleet endpoints',flush=True)
w=world('separation')
put(w/'seed/personal','fork contribution\n'); origin=commit(w/'seed','personal'); git(w/'seed','push','-q','origin','main')
put(w/'upstream/AGENTS.md','upstream instructions\n'); upstream=commit(w/'upstream','upstream'); git(w/'upstream','push','-q','origin','main')
# Make upstream unusable: origin-only consumption must still succeed.
git(w/'primary','remote','set-url','upstream',w/'does-not-exist.git')
out=update(w)
assert 'firstmate: updated' in out and 'secondmate solo: updated' in out
assert tip(w/'primary')==tip(w/'mate')==origin
assert not (w/'home/data/fork-sync').exists()
assert 'reread-firstmate: no' in out
no_old_actions(w)
print('OBSERVED origin-only convergence with unavailable upstream and poisonous legacy validator:',json.dumps(snapshots(w)),flush=True)
git(w/'primary','remote','set-url','upstream',w/'upstream.git')
before=snapshots(w); out=update(w,'--prepare-integration'); f=fields(out)
repo=pathlib.Path(f['integration-repo']); candidate=f['integration-candidate']
assert f['integration-origin']==origin and f['integration-upstream']==upstream and tip(repo)==candidate
for ancestor in (origin,upstream): git(repo,'merge-base','--is-ancestor',ancestor,candidate)
assert len(git(repo,'rev-list','--parents','-n1',candidate).split())==3
assert snapshots(w)==before and 'restart-secondmates:' not in out and 'reread-firstmate:' not in out
no_old_actions(w)
print('OBSERVED unpublished candidate retains both parents; all homes/remotes unchanged:',json.dumps(before),flush=True)
print('Candidate graph:\n'+git(repo,'log','--graph','--oneline','--all','-6'),flush=True)
# Only this fixture bare origin receives a local simulated approved landing; no hosted service or gate operation.
git(w/'seed','fetch','-q',repo,candidate); git(w/'seed','merge','-q','--ff-only',candidate); git(w/'seed','push','-q','origin','main')
out=update(w)
assert tip(w/'primary')==tip(w/'mate')==candidate and 'reread-firstmate: yes' in out
no_old_actions(w)
print('OBSERVED exact landed merge consumed without private CI or publication:',json.dumps(snapshots(w)),flush=True)
out=update(w); assert 'firstmate: already current' in out
out=update(w,'--prepare-integration'); assert 'fork upstream included:' in out and 'integration-candidate:' not in out
# Dirty primary must stop every mate even though origin has advanced.
put(w/'seed/new','new landed change\n'); newer=commit(w/'seed','advance'); git(w/'seed','push','-q','origin','main')
put(w/'primary/AGENTS.md','protected local edit\n'); before=snapshots(w)
out=update(w,expected=1)
assert 'dirty working tree' in out and 'restart-secondmates: none' in out and 'nudge-secondmates: none' in out
assert snapshots(w)==before and (w/'primary/AGENTS.md').read_text()=='protected local edit\n'
out=update(w,'--prepare-integration',expected=1); assert 'dirty primary' in out and snapshots(w)==before
print('OBSERVED dirty primary blocked consumption and preparation; protected edit and mate preserved:',json.dumps(before),flush=True)

# Adversarial private data appearing and disappearing in upstream history.
w=world('private-history')
put(w/'upstream/data/private','sensitive fixture\n'); git(w/'upstream','add','-f','data/private'); commit(w/'upstream','private'); git(w/'upstream','rm','-q','data/private'); commit(w/'upstream','remove'); git(w/'upstream','push','-q','origin','main')
before=snapshots(w); out=update(w,'--prepare-integration',expected=1)
assert 'private operational paths' in out and snapshots(w)==before; no_old_actions(w)
print('OBSERVED removed private path rejected from outgoing history; no live home changed',flush=True)

w=world('conflict')
put(w/'seed/shared','fork conflicting content\n'); commit(w/'seed','fork conflict'); git(w/'seed','push','-q','origin','main')
put(w/'upstream/shared','upstream conflicting content\n'); commit(w/'upstream','upstream conflict'); git(w/'upstream','push','-q','origin','main')
before=snapshots(w); out=update(w,'--prepare-integration',expected=1)
assert 'merge failed; unresolved paths' in out and snapshots(w)==before
attempt=next((w/'home/data/fork-sync').glob('attempt.*'))
assert (attempt/'conflicts').read_text().strip()=='shared'
assert (attempt/'repo/.git/MERGE_HEAD').exists() and not (w/'primary/.git/MERGE_HEAD').exists()
no_old_actions(w)
print('RETAINED conflict paths: '+(attempt/'conflicts').read_text(),flush=True)
print('RETAINED merge diagnostic:\n'+(attempt/'merge.log').read_text(),flush=True)
print('OBSERVED conflict retained only in isolated clone; primary/mate/remotes unchanged',flush=True)

w=world('unpublished')
put(w/'primary/local','unpublished work\n'); commit(w/'primary','local work'); before=snapshots(w)
out=update(w,'--prepare-integration',expected=1); assert 'unpublished or diverged work' in out and snapshots(w)==before
print('OBSERVED unpublished primary work refused and preserved',flush=True)
git(w/'primary','remote','remove','upstream'); before=snapshots(w)
out=update(w,'--prepare-integration',expected=1); assert 'requires a primary with upstream configured' in out and snapshots(w)==before
out=update(w,'--prepare-integration','extra',expected=1); assert 'usage:' in out and snapshots(w)==before
print('OBSERVED absent upstream and extra arguments refused without home convergence or restart actions',flush=True)
print('All disposable product scenarios completed successfully.',flush=True)
