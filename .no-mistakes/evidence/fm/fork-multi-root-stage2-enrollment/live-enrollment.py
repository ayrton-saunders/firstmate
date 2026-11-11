"""Disposable product driver: real enrollment API, installed ingress, OS locks.
No substituted product functions, services, SSH, or runtime backend actions.
Oracle: stage-2 acceptance requires exclusion, isolated recovery, exact repair,
coherent records, and no lane authority from bootstrap completion.
"""
import importlib.util
import json
import multiprocessing as mp
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
ROOT = Path.cwd()
spec = importlib.util.spec_from_file_location('enrollment', ROOT / 'bin/fm-remote-enrollment.py')
e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e)
SOURCE = (ROOT / 'bin/fm-remote-enrollment.py').read_bytes()
ORIGIN = '4c96fb169f0171c6a806275e180b0bd4bc7a255d'
BUNDLE = e.bundle_bytes(SOURCE, ORIGIN)[0]
PYTHON = str(Path(sys.executable).resolve())
CTX = mp.get_context('fork')
LAB = ROOT / '.nm-enrollment-live'
assert not LAB.exists()
LAB.mkdir(mode=0o700)

def emit(label, value):
    print(label + ': ' + json.dumps(value, sort_keys=True), flush=True)

def folder(name):
    p = LAB / name
    p.mkdir(mode=0o700)
    return p

def authority(p):
    base = p / 'authority'
    e.initialize(base)
    return base

def request(p, name):
    for role in ('root', 'home'):
        (p / (name + '-' + role)).mkdir(mode=0o700)
    return dict(name=name, binding=str(uuid.uuid4()), fleet=str(uuid.uuid4()), route=name,
                root=str(p / (name + '-root')), home=str(p / (name + '-home')),
                backend='herdr', session='fm-lab-' + name,
                socket=str(p / (name + '.sock')), service='dev.fixture.' + name, commit='a'*40)

def reserve(base, req, interpreter=PYTHON):
    return e.reserve(base, req, BUNDLE, interpreter)

def install(base, req):
    e.install(base, req['name'], SOURCE, ORIGIN)

def refuse(label, action):
    try:
        action()
    except (ValueError, OSError) as exc:
        emit(label, {'refused': str(exc)})
        return
    raise AssertionError('unexpected acceptance: ' + label)

def ingress(base, req, verb='diagnose', expect=0):
    command = [str(e.instance(base, req['name']) / 'ingress'), verb]
    r = subprocess.run(command, capture_output=True, text=True, timeout=20,
                       cwd=LAB, env=dict(os.environ, PYTHONPATH=str(LAB), PYTHONSTARTUP=str(LAB/'json.py')))
    emit('installed ' + verb, {'argv':command,'exit':r.returncode,'stdout':r.stdout.strip(),'stderr':r.stderr.strip()})
    assert r.returncode == expect
    return json.loads(r.stdout) if expect == 0 else r.stderr

def snapshot(p):
    return {str(f.relative_to(p)):(f.lstat().st_ino, f.lstat().st_mode, f.lstat().st_mtime_ns,
                                 f.read_bytes() if f.is_file() else None)
            for f in [p, *sorted(p.rglob('*'))]}

def repo(p):
    subprocess.run(['git','init','-q',str(p)], check=True, capture_output=True)

try:
    # 1. Independent processes contend against the unmodified kernel.
    for resource in ('root','home','root-home','ancestor','name','binding','session','socket','service',
                     'common-git','home-storage','alternates','inode-alias','object-hardlink'):
        p = folder('race-' + resource); base = authority(p)
        a,b = request(p,'alpha'),request(p,'beta')
        if resource == 'root-home': b['home'] = a['root']
        elif resource == 'ancestor':
            repo(a['root']); child = Path(a['root'])/'child'; child.mkdir(mode=0o700); b['root'] = str(child)
        elif resource in ('common-git','home-storage'):
            role = 'home' if resource == 'home-storage' else 'root'
            repo(a[role]); (Path(b[role])/'.git').write_text('gitdir: '+a[role]+'/.git\n')
        elif resource == 'alternates':
            repo(a['root']); repo(b['root'])
            (Path(b['root'])/'.git/objects/info/alternates').write_text(a['root']+'/.git/objects\n')
        elif resource == 'inode-alias':
            alias=p/'alias'; alias.symlink_to(a['root']); b['root']=str(alias)
        elif resource == 'object-hardlink':
            repo(a['home']); repo(b['home'])
            obj=Path(a['home'])/'.git/objects/object'; obj.write_bytes(b'synthetic shared storage')
            os.link(obj,Path(b['home'])/'.git/objects/object')
        else: b[resource] = a[resource]
        start=CTX.Barrier(2); q=CTX.Queue()
        def contender(req):
            start.wait(10)
            try: q.put({'name':req['name'],'claim':reserve(base,req),'result':'acquired'})
            except (ValueError,OSError) as exc: q.put({'name':req['name'],'result':'refused','reason':str(exc)})
        children=[CTX.Process(target=contender,args=(req,)) for req in (a,b)]
        for c in children: c.start()
        answers=[q.get(timeout=20) for _ in children]
        for c in children:
            c.join(20)
            if c.is_alive(): c.kill(); c.join(); raise AssertionError('race timed out')
            assert c.exitcode == 0
        q.close(); q.join_thread()
        emit('race '+resource, answers)
        assert sum(x['result']=='acquired' for x in answers) == (0 if resource=='object-hardlink' else 1)
        assert all(x.get('claim',{}).get('state','reserved')=='reserved' for x in answers)
    emit('SCENARIO concurrent exclusion','PASS')

    # 2. Kill a real process after reservation, and separately a lock owner.
    p=folder('crash'); base=authority(p); a=request(p,'pending'); b=request(p,'rival'); b['root']=a['root']
    parent,child=CTX.Pipe()
    def reserving():
        child.send(reserve(base,a)); time.sleep(60)
    c=CTX.Process(target=reserving); c.start(); assert parent.poll(20)
    pending=parent.recv(); c.kill(); c.join(10); assert not c.is_alive()
    emit('killed reserving process',{'exit':c.exitcode,'persisted':e.claim(base,a['name'])})
    refuse('pending root excludes rival after death',lambda:reserve(base,b))
    lockfile=base/'inventory.lock'; inode=lockfile.stat().st_ino
    parent2,child2=CTX.Pipe()
    def holding():
        with e.lock(lockfile): child2.send(True); time.sleep(60)
    c=CTX.Process(target=holding); c.start(); assert parent2.poll(10); parent2.recv(); c.kill(); c.join(10)
    assert c.exitcode is not None
    with e.lock(lockfile): assert lockfile.stat().st_ino==inode
    install(base,a); answer=ingress(base,a,'resume')
    assert answer['state']=='reserved' and answer['ordinary']=='closed' and answer['bootstrap']=='complete'
    refuse('completed bootstrap still excludes rival',lambda:reserve(base,b))
    emit('stable kernel lock',{'inode_before':inode,'inode_after':lockfile.stat().st_ino,'killed_owner_exit':c.exitcode})
    emit('SCENARIO pending crash and reconciliation','PASS')

    # 3. Broken application imports cannot affect the real installed executable.
    p=folder('recovery'); base=authority(p); a=request(p,'rescued'); repo(a['root'])
    app=Path(a['root'])/'bin'; app.mkdir(mode=0o700)
    for name in ('fm-remote-entrypoint.sh','fm-remote-job-lib.sh'): (app/name).write_text('exit 99\n')
    (LAB/'json.py').write_text("raise RuntimeError('poison application import')\n")
    (LAB/'sitecustomize.py').write_text("raise RuntimeError('poison site import')\n")
    reserve(base,a); install(base,a)
    before=snapshot(base); answer=ingress(base,a); assert snapshot(base)==before
    assert answer['bootstrap']=='pending'
    answer=ingress(base,a,'resume'); assert answer['state']=='reserved' and answer['ordinary']=='closed'
    shutil.rmtree(a['root']); shutil.rmtree(a['home']); before=snapshot(base)
    for verb in ('diagnose','resume'):
        answer=ingress(base,a,verb); assert answer['missing']==['root','home'] and answer['ordinary']=='closed'
    assert snapshot(base)==before and not Path(a['root']).exists() and not Path(a['home']).exists()
    absent=p/'absent'; before=snapshot(p); refuse('absent authority read',lambda:e.diagnose(absent,'unknown')); assert snapshot(p)==before
    emit('SCENARIO independent read-only recovery','PASS')

    # 4. Each installed byte contract can be repaired only with accepted release.
    p=folder('repair'); base=authority(p); a=request(p,'repair'); reserve(base,a); install(base,a); ingress(base,a,'resume')
    location=e.instance(base,a['name']); claims=(base/'claims.json').read_bytes(); selection=(location/'bootstrap-selection.json').read_bytes()
    for path in [location/'bundles'/BUNDLE/n for n in ('enrollment.py','manifest.json')]+[location/'loader.py',location/'ingress']:
        original=path.read_bytes(); mode=path.stat().st_mode & 0o777
        for damage in ('missing','corrupt','mode'):
            if damage=='missing': path.unlink()
            elif damage=='corrupt': path.write_bytes(b'damaged installed release')
            else: path.chmod(0o666)
            refuse('damaged '+path.name+' '+damage,lambda:e.resume(base,a['name']))
            refuse('reject bundle switching',lambda:e.install(base,a['name'],b'wrong release',ORIGIN))
            install(base,a)
            assert path.read_bytes()==original and path.stat().st_mode & 0o777==mode
            assert ingress(base,a,'resume')['bootstrap']=='complete'
            assert (base/'claims.json').read_bytes()==claims and (location/'bootstrap-selection.json').read_bytes()==selection
    emit('SCENARIO exact accepted repair','PASS')

    # 5. Authority placement, private modes, identities and coherent records.
    p=folder('safety'); base=authority(p)
    public=p/'public'; public.mkdir(mode=0o755); public.chmod(0o755)
    refuse('public parent refuses initialization',lambda:e.initialize(public/'authority')); assert not (public/'authority').exists()
    for role in ('root','home'):
        a=request(p,'inside-'+role); repo(a[role]); inner=Path(a[role])/'authority'; e.initialize(inner)
        before=(inner/'claims.json').read_bytes(); refuse('authority inside '+role,lambda:reserve(inner,a)); assert (inner/'claims.json').read_bytes()==before
    a=request(p,'tool'); repo(a['root']); tool=Path(a['root'])/'python'; shutil.copyfile(PYTHON,tool); tool.chmod(0o700)
    refuse('interpreter inside application root',lambda:reserve(base,a,str(tool)))
    a=request(p,'safe'); reserve(base,a); install(base,a); ingress(base,a,'resume')
    for directory in (base,p):
        directory.chmod(0o755)
        try:
            before=snapshot(base); ingress(base,a,'diagnose',126); ingress(base,a,'resume',126)
            refuse('private directory preflight reserve',lambda:reserve(base,request(p,'bad-'+directory.name)))
            refuse('private directory preflight install',lambda:install(base,a)); assert snapshot(base)==before
        finally: directory.chmod(0o700)
    loc=e.instance(base,a['name']); descriptor=loc/'descriptor.json'; old=descriptor.read_bytes()
    for data in (b'{',old[:-8],b'{"schema":1,"schema":1}'):
        descriptor.write_bytes(data); ingress(base,a,'diagnose',126)
    descriptor.write_bytes(old)
    selection=loc/'bootstrap-selection.json'; old_selection=selection.read_bytes()
    e.publish(selection,'selection',2,{'bundle':'f'*64,'abi':1,'claim':e.claim(base,a['name'])['digest']}); ingress(base,a,'resume',126)
    selection.write_bytes(old_selection)
    oldroot=Path(a['root']); oldroot.rename(p/'original-root'); oldroot.mkdir(mode=0o700)
    ingress(base,a,'diagnose',126); oldroot.rmdir(); (p/'original-root').rename(oldroot)
    ptr=Path(a['home'])/'.fm-enrolled-resource'; original=ptr.read_bytes()
    e.publish(ptr,'pointer',1,{'binding':str(uuid.uuid4()),'claim':e.claim(base,a['name'])['digest'],'role':'home'})
    ingress(base,a,'resume',126); ptr.write_bytes(original)
    before=snapshot(base); ingress(base,a,'dispatch',126); assert snapshot(base)==before
    record=e.inventory(base); record['payload']['entries'][a['name']]['state']='retired'
    record['payload']['entries'][a['name']]['revision']+=1; e.seal_claim(record['payload']['entries'][a['name']])
    e.publish(base/'claims.json','claims',record['revision']+1,record['payload'])
    for resource in ('root','home','name','binding','session','socket','service'):
        b=request(p,'retired-'+resource); b[resource]=a[resource]
        refuse('retired excludes '+resource,lambda:reserve(base,b))
    ingress(base,a,'resume',126)
    emit('SCENARIO guarded placement and coherent authority','PASS')
finally:
    shutil.rmtree(LAB)
    emit('cleanup',{'removed':str(LAB),'exists':LAB.exists()})
