import os, pathlib, subprocess, json, shutil
root=pathlib.Path.cwd()
lab=root/'.test-phase-tmp'/'live-cli'
lab.mkdir()
env=os.environ.copy()
for k in list(env):
    if k.startswith(('GIT_', 'FM_')): env.pop(k)
env.update(GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='validation@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='validation@example.invalid',GIT_TERMINAL_PROMPT='0')
transcript=[]
def command(args, cwd=None, expected=0, product=False, e=None):
    p=subprocess.run([str(a) for a in args],cwd=cwd,env=e or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if product:
        transcript.append({'command':' '.join(str(a) for a in args),'exit':p.returncode,'output':p.stdout})
    if expected is not None: assert p.returncode==expected, (args,p.returncode,p.stdout)
    return p

def git(cwd,*args): return command(['git','-C',cwd,*args]).stdout.strip()
def commit(cwd,msg):
    git(cwd,'add','-A'); git(cwd,'commit','-qm',msg)
def emit(s): transcript.append(s)
try:
    for mode in ['fast-forward','divergent','conflict','ancestry-only']:
        w=lab/mode; w.mkdir()
        fork=w/'fork.git'; canonical=w/'canonical.git'; seed=w/'seed'; upstream=w/'upstream'; main=w/'main'; task=w/'task'; home=w/'home'; record=w/'record'
        git(w,'init','-q','--bare',str(fork)); git(fork,'symbolic-ref','HEAD','refs/heads/main')
        git(w,'clone','-q',str(fork),str(seed))
        (seed/'bin').mkdir(); (seed/'bin'/'tool.sh').write_text('echo baseline\n'); (seed/'README.md').write_text('baseline\n')
        commit(seed,'initial'); git(seed,'push','-q','origin','main')
        git(w,'clone','-q','--bare',str(fork),str(canonical)); git(w,'clone','-q',str(canonical),str(upstream))
        (upstream/'bin'/'tool.sh').write_text('echo upstream\n'); (upstream/'README.md').write_text('canonical\n'); commit(upstream,'upstream change')
        if mode=='ancestry-only': git(upstream,'revert','--no-edit','HEAD')
        git(upstream,'push','-q','origin','main'); u=git(upstream,'rev-parse','HEAD')
        if mode in ['divergent','conflict']:
            (seed/'personal.sh').write_text('test "$(bash "$(dirname "$0")/bin/tool.sh")" = upstream\necho personal-interoperability-ok\n')
            if mode=='conflict': (seed/'README.md').write_text('personal\n')
            commit(seed,'personal behavior'); git(seed,'push','-q','origin','main')
        git(w,'clone','-q',str(fork),str(main)); o=git(main,'rev-parse','HEAD')
        git(main,'worktree','add','-qb','integration',str(task),'main'); git(task,'remote','add','canonical',str(canonical))
        for folder in ['state','data','config','projects']: (home/folder).mkdir(parents=True,exist_ok=True)
        e=env.copy(); e.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(task),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_PROJECTS_OVERRIDE=str(home/'projects'))
        def cli(*args,expected=0): return command([root/'bin/fm-update.sh',*args],expected=expected,product=True,e=e)
        emit({'scenario':mode})
        cli('--prepare-upstream',fork,'main',o,canonical,'main',u,record,expected=1 if mode=='conflict' else 0)
        if mode=='conflict':
            assert git(task,'ls-files','-u')
            (task/'README.md').write_text('personal and canonical\n'); commit(task,'resolve real conflict')
        h=git(task,'rev-parse','HEAD'); tree=git(task,'rev-parse','HEAD^{tree}')
        outputs=[]
        outputs.append(command(['bash',task/'bin/tool.sh'],product=True).stdout)
        if (task/'personal.sh').exists(): outputs.append(command(['bash',task/'personal.sh'],product=True).stdout)
        evidence=w/'execution.txt'; evidence.write_text('Inspection at '+h+'\n'+git(task,'diff',u,h,'--')+'\nCommand: bash bin/tool.sh; bash personal.sh if present\n'+''.join(outputs))
        git(task,'push','-q','origin','integration')
        t=git(task,'commit-tree',tree,'-p',o,'-p',h,'-m','tested merge')
        cli('--qualify-upstream','--focused',record,h,h,t,o,t,'clean',evidence)
        emit({'recorded_evidence':(record/'evidence').read_text(),'qualifications':(record/'qualifications').read_text(),'events':(record/'events').read_text()})
        # Attack final-head coverage and provenance after a valid qualification.
        cli('--qualify-upstream','--focused',record,h,o,t,o,t,'clean',evidence,expected=1)
        bad=git(task,'commit-tree',tree,'-p',h,'-p',o,'-m','wrong parents')
        cli('--qualify-upstream','--focused',record,h,h,bad,o,bad,'clean',evidence,expected=1)
        if mode=='ancestry-only': cli('--qualify-upstream',record,h,h,t,o,t,'clean',evidence,expected=1)
        git(task,'push','-q','origin',t+':refs/heads/main')
        cli('--verify-landed',record,t)
        assert git(main,'rev-parse','HEAD')==o
        assert git(canonical,'rev-parse','main')==u
        emit({'primary_unchanged':o,'canonical_unchanged':u,'activation':'not performed'})
    emit({'result':'all direct CLI assertions passed'})
finally:
    out=pathlib.Path('/Users/ayrton/.no-mistakes/evidence/01M5V07C9A1K8EEEJXH4YW0C4V/updater-live-cli.json')
    out.write_text(json.dumps(transcript,indent=2)+'\n')
    shutil.rmtree(lab)
