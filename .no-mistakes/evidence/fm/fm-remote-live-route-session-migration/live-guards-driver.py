import os, pathlib, subprocess, json, hashlib
root=pathlib.Path.cwd(); home=root/'.test-tmp'/'guards-home'
for d in ('data','state','config','projects'): (home/d).mkdir(parents=True,exist_ok=True)
evidence=pathlib.Path('~/.no-mistakes/evidence/01M72Z6XNH571S4DGC1JRZ35BS')
mate=home/'synthetic-mate'
line=f'- moving - Synthetic route (host: 127.0.0.1; root: {root}; home: {mate}; session: fm-lab-old; scope: test; projects: ; added 2026-10-31)\n'
meta=f'kind=secondmate\nendpoint_task_id=moving\nremote_host=127.0.0.1\nremote_root={root}\nhome={mate}\nworktree={mate}\nbackend=herdr\nremote_backend=herdr\nremote_herdr_session=fm-lab-old\nremote_target=fm-lab-old:w1:p1\n'
env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}
env.update(FM_HOME=str(home),FM_SSH_BIN=str(home/'no-transport-allowed'))
results=[]; log=[]
def check(name,ident,target,registry,metadata,expect):
    reg=home/'data/secondmates.md'; mp=home/'state/moving.meta'
    reg.write_text(registry); mp.write_text(metadata)
    before=(reg.read_bytes(),mp.read_bytes())
    cmd=[str(root/'bin/fm-remote-session-migrate.sh'),ident,target]
    p=subprocess.run(cmd,env=env,text=True,capture_output=True,timeout=15)
    unchanged=before==(reg.read_bytes(),mp.read_bytes())
    no_intent=not (home/'state/.remote-session-migration-moving').exists()
    passed=p.returncode!=0 and expect in (p.stdout+p.stderr) and unchanged and no_intent
    log.extend([f'CASE: {name}',f'$ FM_HOME=<disposable synthetic home> bin/fm-remote-session-migrate.sh {ident} {target!r}',p.stdout+p.stderr,f'exit={p.returncode}; registry and endpoint bytes unchanged={unchanged}; no migration intent={no_intent}\n'])
    results.append(dict(name=name,pass_=passed,exit=p.returncode))
for target in ('','default','bad/name','-bad','a'*65):
    check('invalid/reserved target '+repr(target),'moving',target,line,meta,'1-64 ASCII bytes')
check('missing route','absent','fm-lab-new',line,meta,'unregistered or duplicated route')
check('duplicate route ID','moving','fm-lab-new',line+line,meta,'unregistered or duplicated route')
check('disagreeing parent endpoint','moving','fm-lab-new',line,meta.replace('remote_herdr_session=fm-lab-old','remote_herdr_session=fm-lab-wrong'),'remote route disagrees')
sibling=f'- staying - Synthetic sibling (host: 127.0.0.1; root: {root}; home: {home}/sibling; session: fm-lab-taken; scope: test; projects: ; added 2026-10-31)\n'
check('registered target collision','moving','fm-lab-taken',line+sibling,meta,'registered-route collision')
check('target equals current session','moving','fm-lab-old',line,meta,'duplicate target')
(evidence/'live-cli-guards.log').write_text('\n'.join(log))
(evidence/'live-cli-guards.json').write_text(json.dumps(results,indent=2)+'\n')
print('\n'.join(log))
assert all(x['pass_'] for x in results),results
