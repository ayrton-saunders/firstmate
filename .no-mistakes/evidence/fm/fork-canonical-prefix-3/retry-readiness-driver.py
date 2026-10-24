import os, pathlib, subprocess, tempfile, shutil
root=pathlib.Path.cwd(); world=pathlib.Path(tempfile.mkdtemp(prefix='readiness-live-',dir=root/'.test-tmp'))
env=dict(os.environ)
for k in list(env):
    if k.startswith(('FM_','GIT_','TASKS_AXI_')) or k in ('TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION','HERDR_SOCKET_PATH'): env.pop(k,None)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid',TMPDIR=str(root/'.test-tmp'))
def run(*args):
    p=subprocess.run(list(map(str,args)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    print('$ '+' '.join(map(str,args))+'\n'+p.stdout+'exit='+str(p.returncode),flush=True)
    assert p.returncode==0
    return p.stdout.strip()
try:
    tools=world/'tools';tools.mkdir()
    for name in ('jq','python3','git'):
        (tools/name).symlink_to(shutil.which(name))
    env['PATH']=str(tools)+':/usr/bin:/bin:/usr/sbin:/sbin'
    assert shutil.which('gh',path=env['PATH']) is None
    parent=world/'parent';home=world/'mate';repo=world/'repo'
    for h in (parent,home): run(root/'bin/fm-lab-home.sh','create',h)
    run('git','init',repo);run('git','-C',repo,'commit','--allow-empty','-m','disposable head')
    head=run('git','-C',repo,'rev-parse','HEAD');run('git','-C',repo,'update-ref','refs/remotes/origin/lab',head)
    (home/'.fm-secondmate-home').write_text('mate-x\n')
    (home/'.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home='+str(parent)+'\n')
    (parent/'state/mate-x.meta').write_text('kind=secondmate\nhome='+str(home)+'\n')
    (parent/'data/secondmates.md').write_text('- mate-x - disposable scope (home: '+str(home)+'; scope: lab; projects: lab; added 2026-10-24)\n')
    (home/'state/child.meta').write_text('kind=ship\nmode=no-mistakes\nworktree='+str(repo)+'\nproject='+str(repo)+'\n')
    (home/'config/ready-after-green').touch()
    env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(root),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_PROJECTS_OVERRIDE=str(home/'projects'))
    url='https://github.com/disposable-lab/example/pull/7';channel=parent/'state/mate-x.status';status=home/'state/child.status'
    for prefix in ('done [key=fix]:','done : ','done [at=10:30] [key=fix]:','done: [key=fix]'):
        if channel.exists():channel.unlink()
        status.write_text('done: PR '+url+' checks green\n'+prefix+' checks pending after another push\n')
        run(root/'bin/fm-pr-check.sh','child',url)
        assert not channel.exists() or 'child-pr-child' not in channel.read_text()
        print('WITHHELD: latest '+prefix+' pending supersedes earlier green',flush=True)
        with status.open('a') as f:f.write(prefix+' PR '+url+'0 checks green\n')
        run(root/'bin/fm-pr-check.sh','child',url)
        assert not channel.exists() or 'child-pr-child' not in channel.read_text()
        print('WITHHELD: PR 70 cannot authorize PR 7',flush=True)
        with status.open('a') as f:f.write(prefix+' PR '+url+' checks green, awaiting approval.\nnote: waiting\n')
        run(root/'bin/fm-pr-check.sh','child',url)
        assert 'child child PR ready: '+url in channel.read_text()
        print('PARENT OUTPUT: '+channel.read_text(),flush=True)
    print('PASS: real local registration honors latest keyed/spaced exact-URL reports without any forge access',flush=True)
finally:
    shutil.rmtree(world);print('CLEANUP: private readiness world removed',flush=True)
