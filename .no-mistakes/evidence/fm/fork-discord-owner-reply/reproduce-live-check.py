import hashlib, json, os, pathlib, sqlite3, subprocess, sys
root=pathlib.Path.cwd()
world=root/'.validation-tmp/live-world'
world.mkdir()
home=world/'home'; home.mkdir()
files={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in ('bin/fm-inbox.sh','bin/fm-send.sh','bin/fm-spawn.sh','bin/fm-discord-hook.py')}
identity={'source_commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'source_digest':hashlib.sha256(json.dumps(files,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()}
identity['home_identity']=hashlib.sha256(str(home).encode()).hexdigest()
config={'schema':2,'enabled':True,'source':str(root),'home':str(home),**{k:identity[k] for k in ('source_commit','source_digest')},'journal':str(world/'not-live-parent.sqlite')}
manifest={'schema':2,'enabled':True,'parent_identity':identity,'journal':str(world/'not-live-transport.sqlite')}
cp=world/'parent.json'; mp=world/'transport.json'
def save():
    cp.write_text(json.dumps(config)); mp.write_text(json.dumps(manifest))
save()
parent=world/'parent-snapshot.sqlite'; transport=world/'transport-snapshot.sqlite'
for p,epoch in ((parent,'a'*32),(transport,'b'*32)):
    with sqlite3.connect(p) as db:
        db.executescript('CREATE TABLE identity(singleton INTEGER PRIMARY KEY,schema_version INTEGER,epoch TEXT,fenced INTEGER,delivery_fenced INTEGER); CREATE TABLE state(family TEXT,id TEXT,revision INTEGER,body TEXT,PRIMARY KEY(family,id));')
        db.execute('INSERT INTO identity VALUES(1,2,?,0,0)',(epoch,))
        if p==transport: db.execute('INSERT INTO state VALUES(?,?,?,?)',('remote-epoch','parent',1,json.dumps({'identity':identity,'epoch':'a'*32})))
def snapshot():
    return {str(p.relative_to(world)):(p.read_bytes(),p.stat().st_mtime_ns) for p in world.rglob('*') if p.is_file()}
def invoke(name,command,expected,phrase,env=None):
    before=snapshot()
    p=subprocess.run(command,text=True,capture_output=True,env=env,timeout=20)
    print('\nSCENARIO:',name)
    print('$', ' '.join(str(a).replace(str(root),'<worktree>') for a in command))
    print('exit:',p.returncode)
    print((p.stdout+p.stderr).strip())
    assert p.returncode==expected,(name,p.stderr)
    assert phrase in p.stdout+p.stderr
    assert before==snapshot(),'command mutated disposable inputs'
    print('Input bytes and mtimes unchanged; no new files or journal sidecars.')
    return p
cmd=[sys.executable,'-I',str(root/'bin/fm-discord-verify-pins.py'),'--parent-config',str(cp),'--transport-manifest',str(mp)]
invoke('Owner checks matching source/config/manifest without opening journals',cmd,0,'journal epoch and fences not checked')
full=cmd+['--parent-journal-snapshot',str(parent),'--transport-journal-snapshot',str(transport)]
invoke('Owner verifies reconciled offline snapshots with clear fences',full,0,'fences are clear (offline snapshots only)')
manifest['parent_identity']={**identity,'source_commit':'0'*40}; save()
invoke('Wrong transport identity stops preflight',cmd,1,'source_commit mismatch')
manifest['parent_identity']=identity; save()
for path,role in ((parent,'parent'),(transport,'transport')):
    for field in ('fenced','delivery_fenced'):
        with sqlite3.connect(path) as db: db.execute('UPDATE identity SET '+field+'=1')
        invoke(role+' '+field+' stops offline readiness claim',full,1,role+' intake or delivery remains fenced')
        with sqlite3.connect(path) as db: db.execute('UPDATE identity SET '+field+'=0')
with sqlite3.connect(parent) as db: db.execute('UPDATE identity SET epoch=?',('c'*32,))
invoke('Restored parent epoch requires reconciliation',full,1,'remembered parent epoch mismatch')
with sqlite3.connect(parent) as db: db.execute('UPDATE identity SET epoch=?',('a'*32,))
sidecar=pathlib.Path(str(parent)+'-wal'); sidecar.write_bytes(b'uncheckpointed offline data')
invoke('Offline snapshot with WAL is refused rather than ignored',full,1,'standalone offline journal snapshots required')
sidecar.unlink()
(home/'config').mkdir(); (home/'config/discord-integration.json').write_text('{invalid configuration')
# Guard scenarios use real entrypoints, no replacement package or journal API.
environment={k:v for k,v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE'))}
environment.update(FM_HOME=str(home),FM_GATE_REFUSE_BYPASS='')
for marker in ('1',''):
    environment['NO_MISTAKES_GATE']=marker
    for entry,words in (('reply','Approved answer.'),('dispatch','Harmless question?')):
        invoke('Gate marker '+repr(marker)+' blocks '+entry+' before malformed configuration', [sys.executable,'-I',str(root/('bin/fm-discord-'+entry+'.py')),'request','domain',words],1,'parent lifecycle authority required',environment)
lab=world/'lab'; lab.mkdir()
subprocess.run(['bash',str(root/'bin/fm-lab-home.sh'),'create',str(lab)],check=True,capture_output=True)
(lab/'config/discord-integration.json').write_text('{invalid configuration')
environment['FM_HOME']=str(lab)
invoke('Marked lab passes authority guard and reaches configuration validation',[sys.executable,'-I',str(root/'bin/fm-discord-reply.py'),'request','domain','Approved answer.'],1,'verify pinned configuration',environment)
environment['FM_STATE_OVERRIDE']=str(world/'wrong-state')
invoke('Marked lab cannot redirect state to another directory',[sys.executable,'-I',str(root/'bin/fm-discord-reply.py'),'request','domain','Approved answer.'],1,'parent lifecycle authority required',environment)
print('\nPrivate runtime availability:')
p=subprocess.run([sys.executable,'-I','-c','import importlib.util; print("personal_discord:", importlib.util.find_spec("personal_discord"))'],text=True,capture_output=True,check=True)
print(p.stdout.strip())
print('No approved private release is supplied in this repository; fake integration fixtures were not counted as live dispatch/publication.')
