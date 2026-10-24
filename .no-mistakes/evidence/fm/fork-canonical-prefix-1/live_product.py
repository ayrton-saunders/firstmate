import os, pathlib, subprocess, json, shutil, hashlib, tomllib
root=pathlib.Path.cwd(); base=root/'.test-phase-tmp'/'live'; base.mkdir()
evidence=pathlib.Path('/Users/ayrton/.no-mistakes/evidence/01M5PS2RV5DXG4RYWK86BGQ2M7/live-cli-transcript.log')
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'GIT_', 'TASKS_AXI_')) or k in ('NO_MISTAKES_GATE','RELAY_PARENT_HOME'): env.pop(k,None)
env.update(GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Local validation',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Local validation',GIT_COMMITTER_EMAIL='test@example.invalid')
home=base/'home'; (home/'state').mkdir(parents=True); (home/'config').mkdir(); env['FM_HOME']=str(home); env['FM_TOOL_UPDATE_INTERVAL']='0'
log=[]
def run(*args,expected=0,show=True):
    p=subprocess.run([str(a) for a in args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if show: log.extend(['$ '+' '.join(str(a) for a in args),p.stdout.strip(),f'exit={p.returncode}'])
    assert p.returncode==expected,(args,p.stdout,p.returncode)
    return p.stdout
def git(repo,*args): return run('git','-C',repo,*args,show=False).strip()
try:
    source=base/'canonical'; watched=base/'fork'
    run('git','init','-q','-b','main',source,show=False)
    (source/'version').write_text('historical\n'); git(source,'add','version'); git(source,'commit','-qm','Historical version')
    run('git','clone','-q',source,watched,show=False)
    old=git(watched,'rev-parse','HEAD')
    (source/'version').write_text('next historical prefix\n'); git(source,'commit','-qam','Next prefix')
    git(watched,'fetch','-q','origin')
    conf=home/'config'/'watched-tools.json'
    conf.write_text(json.dumps({'tools':[{'name':'firstmate','git':{'repo':str(watched),'remote':'origin','branch':'main'}}]}))
    before=git(watched,'show-ref')
    out=run(root/'bin/fm-tool-update-check.sh','check')
    assert '1 commit behind origin/main' in out,out
    assert git(watched,'rev-parse','HEAD')==old and git(watched,'show-ref')==before and not git(watched,'status','--porcelain')
    log.append('Observed: update reports one incoming commit; HEAD, all refs, and working files remain unchanged.')
    assert run(root/'bin/fm-tool-update-check.sh','check').strip()==''
    git(watched,'merge','--ff-only','origin/main')
    assert run(root/'bin/fm-tool-update-check.sh','check').strip()==''
    log.append('Observed: repeated notification suppressed; after explicit local fast-forward the check is quiet.')
    conf.write_text(json.dumps({'tools':[{'name':'python','command':'python3','version_url':'http://127.0.0.1/9'}]}))
    out=run(root/'bin/fm-tool-update-check.sh','check'); assert 'version_url must be one https URL' in out
    cfg=base/'herdr.toml'; cfg.write_text('[ui]\ntheme = "default"\n')
    run(root/'bin/fm-herdr-groups.sh','sidebar-config','--apply',cfg)
    data=tomllib.loads(cfg.read_text()); assert 'spaces' in data['ui']['sidebar'] and 'agents' in data['ui']['sidebar']
    log.append('Generated public configuration:\n'+cfg.read_text())
    before=cfg.read_bytes(); backups=list(base.glob('herdr.toml.bak-*')); assert len(backups)==1
    assert backups[0].read_text()=='[ui]\ntheme = "default"\n'
    run(root/'bin/fm-herdr-groups.sh','sidebar-config','--apply',cfg,expected=1)
    assert cfg.read_bytes()==before and list(base.glob('herdr.toml.bak-*'))==backups
    collision=base/'collision.toml'; collision.write_text('ui.sidebar.agents = { label = "existing" }\n'); before=collision.read_bytes()
    run(root/'bin/fm-herdr-groups.sh','sidebar-config','--apply',collision,expected=1)
    assert collision.read_bytes()==before and not list(base.glob('collision.toml.bak-*'))
    invalid=base/'invalid.toml'; invalid.write_text('[broken\n'); before=invalid.read_bytes()
    run(root/'bin/fm-herdr-groups.sh','sidebar-config','--apply',invalid,expected=1)
    assert invalid.read_bytes()==before and not list(base.glob('invalid.toml.bak-*'))
    log.append('Observed: duplicate, dotted-table collision, and invalid TOML all refused before any file or backup mutation. No Herdr endpoint used or reloaded.')
finally:
    evidence.write_text('\n'.join(log)+'\n'); shutil.rmtree(base)
print(evidence)
