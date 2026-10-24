import pathlib, tempfile, subprocess, os, shutil
root=pathlib.Path.cwd(); world=pathlib.Path(tempfile.mkdtemp(prefix='archive-live-',dir=root/'.test-tmp'))
env=dict(os.environ)
for k in list(env):
    if k.startswith(('FM_','TASKS_AXI_','GIT_')) or k in ('TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION','HERDR_SOCKET_PATH','REX_SESSION','REX_BLOCK'): env.pop(k,None)
env.update(TMPDIR=str(root/'.test-tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
def run(args, extra, cwd=root, ok=True):
    p=subprocess.run(list(map(str,args)),cwd=cwd,env=env|extra,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    print('$ '+' '.join(map(str,args))+'\n'+p.stdout.rstrip()+'\nexit='+str(p.returncode),flush=True)
    if ok: assert p.returncode==0,p.stdout
    return p
try:
    for scope in ('repository','user'):
        home=world/scope; run([root/'bin/fm-lab-home.sh','create',home],{})
        axi=home/'isolated-user'; (axi/'.tasks-axi').mkdir(parents=True)
        config='backend = "markdown"\n[markdown]\npath = "data/backlog.md"\ndone_keep = 10\n'
        target='archive = "data/done#archive.md" # real retention output\n'
        (home/'.tasks.toml').write_text(config+(target if scope=='repository' else ''))
        (axi/'.tasks-axi/config.toml').write_text('[markdown]\n'+('archive = "data/foreign#user.md"\n' if scope=='repository' else target))
        (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        e={'HOME':str(axi),'FM_HOME':str(home),'FM_STATE_OVERRIDE':str(home/'state'),'FM_DATA_OVERRIDE':str(home/'data'),'FM_CONFIG_OVERRIDE':str(home/'config'),'FM_ROOT_OVERRIDE':str(root)}
        tasks=root/'bin/fm-tasks-axi.sh'; hold=root/'bin/fm-captain-hold.sh'; id='lab-archive-review'; call='lab-archive-call'
        run(['tasks-axi','add',id,'Review archive semantics','--kind','scout','--repo','sample','--start'],e,cwd=home)
        (home/f'data/{id}').mkdir(); (home/f'data/{id}/report.md').write_text('# Review\n\nOne local decision.\n')
        (home/f'state/{id}.meta').write_text('kind=scout\nmode=scout\nharness=codex\nspawn_gen=lab-archive\n')
        (home/f'state/{id}.status').write_text('done: report complete\n')
        run([hold,'hold',call,'--title','Choose archive option','--reason','local disposable decision','--repo','sample','--origin',id],e)
        run([hold,'complete',id,call],e)
        run([hold,'verify',id],e) # An open recorded hold correctly satisfies inventory review; it is not an answer gate.
        decision=home/'decision.txt';decision.write_text('Use the disposable archive option.\n')
        run([hold,'answer',call,'--decision-file',decision],e)
        p=home/'.tasks.toml';p.write_text(p.read_text().replace('done_keep = 10','done_keep = 0'))
        run([tasks,'add','lab-retention','Trigger real retention','--kind','ship','--repo','sample'],e)
        run([tasks,'done','lab-retention'],e)
        archive=home/'data/done#archive.md'; assert archive.is_file(); text=archive.read_text(); print('GENERATED ARCHIVE:\n'+text,flush=True); assert call in text
        assert run([tasks,'show',call],e,ok=False).returncode!=0,'call did not leave active backlog'
        for header in ('[markdown]','["markdown"]','[ "markdown" ]'):
            for p in (home/'.tasks.toml',axi/'.tasks-axi/config.toml'):
                p.write_text(p.read_text().replace('[markdown]',header).replace('["markdown"]',header).replace('[ "markdown" ]',header))
            snapshots=[p.read_bytes() for p in (home/'.tasks.toml',axi/'.tasks-axi/config.toml')]
            print('SCENARIO '+scope+' archive reader header '+header,flush=True)
            run([hold,'verify',id],e)
            run([hold,'complete',id,call],e)
            assert snapshots==[p.read_bytes() for p in (home/'.tasks.toml',axi/'.tasks-axi/config.toml')]
        assert not (home/'data/foreign#user.md').exists()
        for p in (home/'.tasks.toml',axi/'.tasks-axi/config.toml'):
            p.write_text(p.read_text().replace('[ "markdown" ]','[markdown]'))
        bad='lab-unanswered-call'
        run([hold,'hold',bad,'--title','Unanswered archive option','--reason','must not invent an answer','--repo','sample','--origin',id],e)
        run([hold,'complete',id,call,bad],e)
        run([tasks,'done',bad],e) # External closure deliberately omits Firstmate's recorded answer.
        assert bad in archive.read_text()
        refused=run([hold,'verify',id],e,ok=False)
        assert refused.returncode!=0 and bad in refused.stdout
        print('SCENARIO PASS: '+scope+' archive lookup preserves hash paths, TOML semantics and config; archived unanswered closure refuses',flush=True)
finally:
    shutil.rmtree(world); print('CLEANUP: disposable archive world removed',flush=True)
