import os, pathlib, subprocess as sp, shutil, signal, time
R=pathlib.Path.cwd(); W=R/'.test-tmp/live-world'; W.mkdir()
E=pathlib.Path('/Users/ayrton/.no-mistakes/evidence/01M5N21ZK23Y4CP4FDF5FAG9X2/live-update.log')
log=E.open('w'); env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k.startswith('GIT_'): env.pop(k)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Live validation',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Live validation',GIT_COMMITTER_EMAIL='test@example.invalid')
def run(args,ok=True,e=None):
    p=sp.run(list(map(str,args)),env=e or env,text=True,stdout=sp.PIPE,stderr=sp.STDOUT)
    log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'[exit {p.returncode}]\n');log.flush()
    if ok: assert p.returncode==0,p.stdout
    return p

def git(d,*args): return run(['git','-C',d,*args]).stdout.strip()
def put(d,f,s): (d/f).write_text(s)
def commit(d,msg): git(d,'add','-A');git(d,'commit','-qm',msg);return git(d,'rev-parse','HEAD')
def world(n):
    w=W/n; w.mkdir(); origin=w/'origin.git';canonical=w/'canonical.git';seed=w/'seed';up=w/'up';main=w/'main';candidate=w/'candidate';home=w/'home';home.mkdir();(home/'data').mkdir();(home/'state').mkdir()
    run(['git','init','-q','--bare','--initial-branch=main',origin]);run(['git','clone','-q',origin,seed]);put(seed,'README','base\n');put(seed,'AGENTS.md','Disposable fixture home.\n');(seed/'bin').mkdir();put(seed,'bin/tool.sh','#!/bin/sh\nexit 0\n');commit(seed,'base');git(seed,'push','-q','origin','main')
    run(['git','clone','-q','--bare',origin,canonical]);run(['git','clone','-q',canonical,up]);run(['git','clone','-q',origin,main]);git(main,'remote','set-head','origin','main');git(main,'worktree','add','-qb','integration',candidate,'main');git(candidate,'remote','add','canonical',canonical)
    return w,origin,canonical,seed,up,main,candidate,home

def cli(root,home,*args,ok=True):
    e=env.copy();e.update(FM_ROOT_OVERRIDE=str(root),FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_PROJECTS_OVERRIDE=str(home/'projects'))
    return run([R/'bin/fm-update.sh',*args],ok,e)

def prepare(w,origin,canonical,main,candidate,home,o,u,ok=True): return cli(candidate,home,'--prepare-upstream',origin,'main',o,canonical,'main',u,w/'attempt',ok=ok)

try:
    log.write('SCENARIO: clean divergent integration preserves fork behavior and both ancestries without moving primary\n')
    w,origin,canonical,seed,up,main,c,home=world('clean')
    put(seed,'personal.sh','#!/bin/sh\nprintf "personal behavior\\n"\n');o=commit(seed,'personal customization');git(seed,'push','-q','origin','main');git(c,'fetch','-q','origin');git(c,'merge','-q','--ff-only',o)
    original=git(main,'rev-parse','HEAD');put(up,'upstream','latest upstream\n');u=commit(up,'canonical change');git(up,'push','-q','origin','main')
    p=prepare(w,origin,canonical,main,c,home,o,u);assert 'conflict-history: clean' in p.stdout
    h=git(c,'rev-parse','HEAD');git(c,'merge-base','--is-ancestor',o,h);git(c,'merge-base','--is-ancestor',u,h);assert run(['sh',c/'personal.sh']).stdout=='personal behavior\n';assert git(main,'rev-parse','HEAD')==original
    prepare(w,origin,canonical,main,c,home,o,u);assert git(c,'rev-parse','HEAD')==h
    log.write('PASS: clean preparation and repetition; primary unchanged; customization executed.\n')
    put(c,'unsaved','preserve\n');p=prepare(w,origin,canonical,main,c,home,o,u,False);assert p.returncode and 'dirty working tree' in p.stdout;assert (c/'unsaved').read_text()=='preserve\n';(c/'unsaved').unlink()
    log.write('PASS: dirty preparation refuses and preserves user data.\n')

    log.write('SCENARIO: pinned consumption refuses a moving origin; independent and unsafe secondmates retain their boundaries\n')
    independent=w/'independent.git';ownseed=w/'ownseed';sm=w/'independent-home';dirty=w/'dirty-home';diverged=w/'diverged-home'
    run(['git','clone','-q','--bare',origin,independent]);run(['git','clone','-q',independent,ownseed]);run(['git','clone','-q',independent,sm]);put(sm,'.fm-secondmate-home','independent\n')
    put(ownseed,'independent','own origin result\n');own=commit(ownseed,'independent change');git(ownseed,'push','-q','origin','main')
    for name,d in [('dirty',dirty),('diverged',diverged)]:
        git(main,'worktree','add','-q','--detach',d,'main');put(d,'.fm-secondmate-home',name+'\n')
    put(dirty,'README','uncommitted customization\n');put(diverged,'unique','unlanded work\n');protected=commit(diverged,'unique work')
    (home/'data/secondmates.md').write_text(''.join(f'- {name} - test (home: {d}; scope: test; projects: none; added 2026-01-01)\n' for name,d in [('independent',sm),('dirty',dirty),('diverged',diverged)]))
    put(seed,'fork-latest','fork update\n');target=commit(seed,'latest fork');git(seed,'push','-q','origin','main')
    before=git(main,'rev-parse','HEAD');p=cli(main,home,'--consume-origin',o,ok=False);assert p.returncode and 'origin moved' in p.stdout;assert git(main,'rev-parse','HEAD')==before
    smbefore=git(sm,'rev-parse','HEAD');assert smbefore!=own
    p=cli(main,home,'--consume-origin',target);assert git(main,'rev-parse','HEAD')==target;assert git(sm,'rev-parse','HEAD')==own;assert git(sm,'remote','get-url','origin')==str(independent)
    assert (dirty/'README').read_text()=='uncommitted customization\n';assert git(diverged,'rev-parse','HEAD')==protected;assert (home/'state/.secondmate-update-reconcile/diverged.pending').exists()
    cli(main,home,'--consume-origin',target)
    log.write('PASS: exact target consumed; own-origin secondmate updated independently; dirty/divergent copies retained; repeated outcomes reported.\n')

    log.write('SCENARIO: textual conflict is retained after resolution and repeat preparation\n')
    w,origin,canonical,seed,up,main,c,home=world('conflict')
    put(seed,'README','personal\n');o=commit(seed,'fork conflict');git(seed,'push','-q','origin','main');git(c,'fetch','-q','origin');git(c,'merge','-q','--ff-only',o)
    put(up,'README','upstream\n');u=commit(up,'canonical conflict');git(up,'push','-q','origin','main')
    p=prepare(w,origin,canonical,main,c,home,o,u,False);assert p.returncode and git(c,'ls-files','-u');put(c,'README','resolved with personal behavior\n');commit(c,'resolve conflict');p=prepare(w,origin,canonical,main,c,home,o,u);assert 'conflict-history: conflicted' in p.stdout
    log.write('PASS: conflict index preserved; successful resolution cannot erase conflict history.\n')

    log.write('SCENARIO: kill real preparation after merge; conflicted qualification retries cannot erase unknown provenance\n')
    w,origin,canonical,seed,up,main,c,home=world('interrupted')
    o=git(c,'rev-parse','HEAD');put(up,'upstream','canonical\n');u=commit(up,'canonical');git(up,'push','-q','origin','main')
    hooks=w/'hooks';hooks.mkdir();hook=hooks/'post-merge';marker=w/'merged';release=w/'release'
    hook.write_text(f'#!/bin/sh\ntouch "{marker}"\nwhile [ ! -e "{release}" ]; do sleep 0.05; done\n');hook.chmod(0o755);git(c,'config','core.hooksPath',hooks)
    e=env.copy();e.update(FM_ROOT_OVERRIDE=str(c),FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'))
    args=[str(R/'bin/fm-update.sh'),'--prepare-upstream',str(origin),'main',o,str(canonical),'main',u,str(w/'attempt')]
    p=sp.Popen(args,env=e,text=True,stdout=sp.PIPE,stderr=sp.STDOUT)
    for _ in range(200):
        if marker.exists():break
        time.sleep(.05)
    assert marker.exists(),'post-merge hook did not run';assert git(c,'rev-parse','HEAD')==u
    p.kill();release.touch();output=p.communicate(timeout=10)[0];log.write('$ '+' '.join(args)+'\n'+output+f'[killed exit {p.returncode} after actual merge]\n');assert p.returncode==-9
    assert (w/'attempt/events').read_text()=='unknown\n';h=git(c,'rev-parse','HEAD');git(c,'push','-q','origin','integration')
    # No forged normal-pipeline attestation: genuine evidence is unavailable in this phase.
    # A nonempty local diagnostic artifact permits exercising the earlier unknown-history safety boundary only.
    ev=w/'diagnostic';ev.write_text('Local diagnostic only; NOT Review/Test attestation.\n')
    for history in ['conflicted','clean','conflicted']:
        p=cli(c,home,'--qualify-upstream',w/'attempt',h,h,h,o,h,history,ev,ok=False)
        assert p.returncode and 'unknown conflict history' in p.stdout
    p=prepare(w,origin,canonical,main,c,home,o,u);assert 'conflict-history: unknown' in p.stdout
    assert not (w/'attempt/qualifications').exists();assert not (w/'attempt/landings').exists()
    log.write('Persisted events contract:\n'+(w/'attempt/events').read_text());log.write('PASS: actual interrupted merge remains unknown across public qualification and preparation retries.\n')
finally:
    log.flush();log.close();shutil.rmtree(W)
