import os, subprocess, pathlib, shutil
ROOT=pathlib.Path.cwd()
WORLD=ROOT/'.validation/live'
WORLD.mkdir()
env=os.environ.copy()
for k in ('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','FM_TASK_ID','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM'):
    env.pop(k,None)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Disposable Live Test',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Disposable Live Test',GIT_COMMITTER_EMAIL='test@example.invalid')
def cmd(*args, cwd=None, ok=True, visible=False, extra=None):
    e=env.copy();e.update(extra or {})
    r=subprocess.run([str(a) for a in args],cwd=cwd,env=e,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    if visible:
        print('$ '+' '.join(str(a) for a in args),flush=True);print(r.stdout,end='',flush=True);print('exit:',r.returncode,flush=True)
    if ok and r.returncode: raise AssertionError(r.stdout)
    return r

def git(p,*args):return cmd('git','-C',p,*args).stdout.strip()
def sha(p):return git(p,'rev-parse','HEAD')
def commit(p,name,text):
    (p/name).write_text(text);git(p,'add',name);git(p,'commit','-qm',name)
def init(name):
    w=WORLD/name;w.mkdir();home=w/'home'
    for d in ('state','data','config','projects'): (home/d).mkdir(parents=True,exist_ok=True)
    origin=w/'fork.git';up=w/'canonical.git';seed=w/'seed';main=w/'primary';canonical=w/'upstream';candidate=w/'candidate'
    git(w,'init','-q','--bare',origin);git(origin,'symbolic-ref','HEAD','refs/heads/main');git(w,'clone','-q',origin,seed)
    shutil.copyfile(ROOT/'AGENTS.md',seed/'AGENTS.md')
    (seed/'bin').mkdir();shutil.copyfile(ROOT/'bin/fm-guard.sh',seed/'bin/fm-guard.sh')
    (seed/'.gitignore').write_text('.fm-secondmate-home\ndata/\nstate/\nconfig/\nprojects/\n')
    git(seed,'add','AGENTS.md','bin','.gitignore')
    commit(seed,'shared.txt','original\n');git(seed,'push','-q','origin','main')
    git(w,'clone','-q','--bare',origin,up);git(w,'clone','-q',up,canonical)
    git(w,'clone','-q',origin,main);git(main,'worktree','add','-qb','integration',candidate,'main');git(candidate,'remote','add','canonical',up)
    return w,home,origin,up,seed,main,canonical,candidate

def product(home,root,*args,ok=True):
    extra=dict(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(root),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_PROJECTS_OVERRIDE=str(home/'projects'))
    return cmd(ROOT/'bin/fm-update.sh',*args,ok=ok,visible=True,extra=extra)
def prepare(w,home,origin,up,main,candidate,o,u,ok=True):
    before=sha(main)
    r=product(home,candidate,'--prepare-upstream',origin,'main',o,up,'main',u,w/'record',ok=ok)
    assert sha(main)==before
    assert 'restart-secondmates:' not in r.stdout
    return r

for mode in ('contained','fast-forward','divergent','conflict','interrupted'):
    print('\nSCENARIO preparation '+mode,flush=True)
    w,home,origin,up,seed,main,canonical,candidate=init(mode)
    if mode!='contained':
        commit(canonical,'shared.txt','canonical feature\n');git(canonical,'push','-q','origin','main')
    if mode in ('divergent','conflict'):
        if mode=='conflict':commit(seed,'shared.txt','personal version\n')
        else:commit(seed,'personal.sh','#!/bin/sh\nprintf "deliberate personal behavior\\n"\n')
        git(seed,'push','-q','origin','main');git(candidate,'fetch','-q','origin');git(candidate,'merge','-q','--ff-only',sha(seed))
    o,u=sha(candidate),sha(canonical)
    if mode=='interrupted':
        (w/'record').mkdir();(w/'record/events').write_text('interrupted unknown attempt\n')
    r=prepare(w,home,origin,up,main,candidate,o,u,ok=mode not in ('conflict','interrupted'))
    if mode=='conflict':
        assert r.returncode and git(candidate,'ls-files','-u')
        print('Persisted conflict paths:',(w/'record/conflicted-paths').read_text(),flush=True)
        print('Retained unmerged index:',git(candidate,'ls-files','-u'),flush=True)
        commit(candidate,'shared.txt','resolved personal and canonical behavior\n')
        r=prepare(w,home,origin,up,main,candidate,o,u)
        assert 'conflict-history: conflicted' in r.stdout
        print('Persisted events:',(w/'record/events').read_text(),flush=True)
    elif mode=='interrupted':
        assert r.returncode and sha(candidate)==o
        assert (w/'record/events').read_text()=='interrupted unknown attempt\n'
    else:
        h=sha(candidate);git(candidate,'merge-base','--is-ancestor',o,h);git(candidate,'merge-base','--is-ancestor',u,h)
        if mode=='divergent':
            r=cmd('bash',candidate/'personal.sh',visible=True);assert r.stdout=='deliberate personal behavior\n'
            print('Candidate parents:',git(candidate,'show','-s','--format=%P','HEAD'),flush=True)
        r=prepare(w,home,origin,up,main,candidate,o,u);assert sha(candidate)==h
    print('OBSERVED primary unchanged:',sha(main),flush=True)

print('\nSCENARIO preparation safety refusals',flush=True)
w,home,origin,up,seed,main,canonical,candidate=init('refusals')
o,u=sha(candidate),sha(canonical)
r=product(home,main,'--prepare-upstream',origin,'main',o,up,'main',u,w/'record',ok=False);assert r.returncode and sha(main)==o
(candidate/'unsaved').write_text('do not discard\n')
r=prepare(w,home,origin,up,main,candidate,o,u,ok=False);assert r.returncode and (candidate/'unsaved').read_text()=='do not discard\n'
(candidate/'unsaved').unlink()
commit(canonical,'new.txt','moving upstream\n');git(canonical,'push','-q','origin','main')
r=prepare(w,home,origin,up,main,candidate,o,u,ok=False);assert r.returncode and sha(candidate)==o

print('\nSCENARIO pinned consumption, independent origins, unsafe homes and repeat',flush=True)
w,home,origin,up,seed,main,canonical,candidate=init('consumption')
old=sha(main)
# Registered inactive homes exercise real disk convergence, without launching or inspecting any live session.
linked=w/'linked';dirty=w/'dirty';divergent=w/'divergent';independent=w/'independent';ownorigin=w/'own.git';ownseed=w/'own-seed'
for p in (linked,dirty,divergent):
    git(main,'worktree','add','-q','--detach',p,'main');(p/'.fm-secondmate-home').write_text(p.name+'\n')
(dirty/'unsaved').write_text('keep my work\n')
commit(divergent,'unique.txt','unlanded unique work\n');local=sha(divergent)
git(w,'clone','-q','--bare',origin,ownorigin);git(w,'clone','-q',ownorigin,ownseed);git(w,'clone','-q',ownorigin,independent);(independent/'.fm-secondmate-home').write_text('independent\n')
commit(ownseed,'own.txt','independent origin update\n');git(ownseed,'push','-q','origin','main');own=sha(ownseed)
(home/'data/secondmates.md').write_text(''.join(f'- {p.name} - disposable (home: {p}; scope: test; projects: none; added 2026-01-01)\n' for p in (linked,dirty,divergent,independent)))
commit(seed,'feature.txt','fork landed update\n');git(seed,'push','-q','origin','main');target=sha(seed)
r=product(home,main,'--consume-origin',target)
assert sha(main)==target and sha(linked)==target and sha(independent)==own
assert sha(dirty)==old and (dirty/'unsaved').read_text()=='keep my work\n' and sha(divergent)==local
assert git(independent,'remote','get-url','origin')==str(ownorigin)
print('OBSERVED primary/linked/independent heads:',sha(main),sha(linked),sha(independent),flush=True)
print('OBSERVED dirty and divergent heads preserved:',sha(dirty),sha(divergent),flush=True)
for p in (home/'state').rglob('*'):
    if p.is_file(): print('Persisted state',p.relative_to(home),p.read_text(),flush=True)
r=product(home,main,'--consume-origin',target);assert sha(main)==target and sha(divergent)==local

print('\nSCENARIO moving origin, dirty primary, active operation and divergent primary refuse before secondmate mutation',flush=True)
commit(seed,'later.txt','new moving origin\n');git(seed,'push','-q','origin','main');latest=sha(seed)
r=product(home,main,'--consume-origin',target,ok=False);assert r.returncode and sha(main)==target and sha(linked)==target
(main/'unsaved').write_text('primary private work\n')
r=product(home,main,'--consume-origin',latest,ok=False);assert r.returncode and sha(main)==target and sha(linked)==target and (main/'unsaved').read_text()=='primary private work\n'
(main/'unsaved').unlink()
mergehead=pathlib.Path(git(main,'rev-parse','--absolute-git-dir'))/'MERGE_HEAD';mergehead.write_text(target+'\n')
r=product(home,main,'--consume-origin',latest,ok=False);assert r.returncode and sha(main)==target and sha(linked)==target
mergehead.unlink()
commit(main,'local-primary.txt','unlanded primary\n');primary=sha(main)
r=product(home,main,'--consume-origin',latest,ok=False);assert r.returncode and sha(main)==primary and sha(linked)==target
print('OBSERVED every refused pin kept the primary and linked home at their prior heads',flush=True)
print('\nAll disposable live CLI scenarios completed. No forge publication, lifecycle or primary activation was attempted.',flush=True)
