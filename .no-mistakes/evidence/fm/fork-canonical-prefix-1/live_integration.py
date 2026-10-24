import pathlib, subprocess, os, shutil
r=pathlib.Path.cwd(); b=r/'.test-phase-tmp'/'integration'; b.mkdir()
e=os.environ.copy()
for k in list(e):
    if k.startswith(('FM_', 'GIT_', 'TASKS_AXI_')): e.pop(k,None)
e.update(GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Local validation',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Local validation',GIT_COMMITTER_EMAIL='test@example.invalid')
log=[]
def run(*args,code=0,show=False):
    p=subprocess.run([str(x) for x in args],env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if show: log.extend(['$ '+' '.join(map(str,args)),p.stdout.strip(),f'exit={p.returncode}'])
    assert p.returncode==code,(args,p.stdout,p.returncode)
    return p.stdout.strip()
def git(d,*args):return run('git','-C',d,*args)
try:
    seed=b/'seed'; fork=b/'fork.git'; upstream=b/'canonical.git'; primary=b/'primary'; candidate=b/'candidate'; author=b/'upstream-author'; home=b/'home'; record=b/'record'
    run('git','init','-q','-b','main',seed)
    (seed/'configuration.md').write_text('Shared baseline\n'); git(seed,'add','.'); git(seed,'commit','-qm','Shared baseline')
    run('git','clone','-q','--bare',seed,fork); run('git','clone','-q','--bare',seed,upstream)
    run('git','clone','-q',fork,primary); run('git','clone','-q',upstream,author)
    (primary/'configuration.md').write_text('Fork updates\n'); git(primary,'commit','-qam','Preserve fork behavior'); git(primary,'push','-q','origin','main')
    (author/'configuration.md').write_text('Canonical evidence guards\n'); git(author,'commit','-qam','Canonical behavior'); git(author,'push','-q','origin','main')
    o=git(primary,'rev-parse','HEAD'); u=git(author,'rev-parse','HEAD')
    git(primary,'worktree','add','-qb','historical-prefix',candidate,'main'); git(candidate,'remote','add','canonical',str(upstream))
    e.update(FM_ROOT_OVERRIDE=str(candidate),FM_HOME=str(home)); (home/'state').mkdir(parents=True)
    args=[r/'bin/fm-update.sh','--prepare-upstream',fork,'main',o,upstream,'main',u,record]
    run(*args,code=1,show=True)
    assert git(candidate,'ls-files','-u')
    assert (record/'events').read_text().find('conflicted')>=0
    assert git(primary,'rev-parse','HEAD')==o and not git(primary,'status','--porcelain')
    log.append('Observed: genuine content conflict retained in isolated candidate; active primary unchanged; conflict provenance recorded.')
    (candidate/'configuration.md').write_text('Fork updates\nCanonical evidence guards\n'); git(candidate,'add','.'); git(candidate,'commit','-qm','Retain both fork and canonical behavior')
    out=run(*args,show=True); assert 'conflict-history: conflicted' in out
    h=git(candidate,'rev-parse','HEAD'); assert git(candidate,'show','-s','--format=%P',h)==o+' '+u
    log.append('Actual merge parents: '+git(candidate,'show','-s','--format=%P',h))
    log.append('Retained behavior:\n'+(candidate/'configuration.md').read_text())
    assert git(primary,'rev-parse','HEAD')==o
    (candidate/'unlanded').write_text('must not discard\n'); before=git(candidate,'rev-parse','HEAD')
    out=run(*args,code=1,show=True); assert 'dirty working tree; preserve it' in out
    assert git(candidate,'rev-parse','HEAD')==before and (candidate/'unlanded').read_text()=='must not discard\n'
    log.append('Observed: dirty candidate refused without losing unlanded work; no qualification, landing, activation, or fleet update attempted.')
finally:
    pathlib.Path('/Users/ayrton/.no-mistakes/evidence/01M5PS2RV5DXG4RYWK86BGQ2M7/live-integration-transcript.log').write_text('\n'.join(log)+'\n')
    shutil.rmtree(b)
