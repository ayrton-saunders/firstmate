import os, pathlib, subprocess, shutil
R=pathlib.Path.cwd(); W=R/'.test-work/live'; W.mkdir(parents=True,exist_ok=True)
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'GIT_')) or k in ('BASH_ENV','TASKS_AXI_FILE','TASKS_AXI_BACKEND'): env.pop(k,None)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Live validation',GIT_AUTHOR_EMAIL='live@example.invalid',GIT_COMMITTER_NAME='Live validation',GIT_COMMITTER_EMAIL='live@example.invalid')
def cmd(*args, e=None, ok=True, show=False):
    p=subprocess.run([str(x) for x in args],env=e or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if show: print('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'[exit {p.returncode}]',flush=True)
    if ok and p.returncode: raise RuntimeError(p.stdout)
    return p

def git(d,*args): return cmd('git','-C',d,*args).stdout.strip()
def write(d,f,s): (d/f).write_text(s)
def commit(d,msg): git(d,'add','-A'); git(d,'commit','-qm',msg); return git(d,'rev-parse','HEAD')
def world(name,conflict=False):
    w=W/name; w.mkdir(); home=w/'home'; (home/'state').mkdir(parents=True); (home/'data').mkdir(); (home/'state/.last-watcher-beat').touch()
    cmd('git','init','-q','--bare','--initial-branch=main',w/'origin.git')
    cmd('git','clone','-q',w/'origin.git',w/'seed')
    seed=w/'seed'; write(seed,'shared.txt','base\n'); write(seed,'.gitignore','.fm-secondmate-home\n'); shutil.copyfile(R/'AGENTS.md',seed/'AGENTS.md'); (seed/'bin').mkdir(); shutil.copyfile(R/'bin/fm-update.sh',seed/'bin/fm-update.sh'); commit(seed,'base'); git(seed,'push','-q','origin','main')
    cmd('git','clone','-q','--bare',w/'origin.git',w/'canonical.git'); cmd('git','clone','-q',w/'canonical.git',w/'upstream')
    write(seed,'shared.txt' if conflict else 'personal.sh','fork\n' if conflict else '#!/bin/sh\nprintf "personal behavior\\n"\n'); o=commit(seed,'personal customization'); git(seed,'push','-q','origin','main')
    cmd('git','clone','-q',w/'origin.git',w/'primary'); git(w/'primary','worktree','add','-qb','integration',w/'candidate'); git(w/'candidate','remote','add','canonical',w/'canonical.git')
    write(w/'upstream','shared.txt','upstream\n'); u=commit(w/'upstream','upstream change'); git(w/'upstream','push','-q','origin','main')
    return w,o,u

def product(w,root,*args,ok=True,extra=None):
    e=env.copy(); e.update(FM_HOME=str(w/'home'),FM_ROOT_OVERRIDE=str(root),FM_STATE_OVERRIDE=str(w/'home/state'),FM_DATA_OVERRIDE=str(w/'home/data'),FM_CONFIG_OVERRIDE=str(w/'home/config'),FM_PROJECTS_OVERRIDE=str(w/'home/projects'))
    if extra: e.update(extra)
    return cmd(R/'bin/fm-update.sh',*args,e=e,ok=ok,show=True)
def prepare(w,o,u,ok=True): return product(w,w/'candidate','--prepare-upstream',w/'origin.git','main',o,w/'canonical.git','main',u,w/'attempt',ok=ok)
print('SCENARIO isolated integration retains fork behavior and both histories',flush=True)
w,o,u=world('clean'); prepare(w,o,u); h=git(w/'candidate','rev-parse','HEAD'); git(w/'candidate','merge-base','--is-ancestor',o,h); git(w/'candidate','merge-base','--is-ancestor',u,h)
assert git(w/'primary','rev-parse','HEAD')==o
cmd('sh',w/'candidate/personal.sh',show=True); prepare(w,o,u); assert git(w/'candidate','rev-parse','HEAD')==h
print(f'primary unchanged={o}; candidate={h}; both parents retained',flush=True)
print('SCENARIO dirty primary and moving canonical preparation are refused',flush=True)
write(w/'candidate','unsaved','keep me'); assert prepare(w,o,u,False).returncode; assert (w/'candidate/unsaved').read_text()=='keep me'; (w/'candidate/unsaved').unlink()
write(w/'upstream','later.txt','later'); commit(w/'upstream','later'); git(w/'upstream','push','-q','origin','main'); assert prepare(w,o,u,False).returncode; assert git(w/'candidate','rev-parse','HEAD')==h
print('SCENARIO text conflict survives manual resolution and repeat preparation',flush=True)
c,co,cu=world('conflict',True); assert prepare(c,co,cu,False).returncode; assert git(c/'candidate','ls-files','-u'); write(c/'candidate','shared.txt','fork plus upstream resolution\n'); commit(c/'candidate','resolve conflict'); assert 'conflict-history: conflicted' in prepare(c,co,cu).stdout
print('SCENARIO unknown history remains unknown after SIGKILL during conflicted retry',flush=True)
# Public qualification records unknown before inspecting pipeline evidence. No fake successful attestation is used.
ch=git(c/'candidate','rev-parse','HEAD'); args=['--qualify-upstream',c/'attempt',ch,ch,ch,co,ch]
p=product(c,c/'candidate',*args,'unknown',c/'missing-evidence',ok=False); assert p.returncode
retained=(c/'attempt/events').read_text()
interrupt=c/'interrupt.bash'; interrupt.write_text('set -T\nstop_after_event() { if [ "$(tail -1 "$INTERRUPT_EVENTS")" = conflicted ]; then trap - DEBUG; kill -KILL "$$"; fi; }\ntrap stop_after_event DEBUG\n')
p=product(c,c/'candidate',*args,'conflicted',c/'missing-evidence',ok=False,extra={'BASH_ENV':str(interrupt),'INTERRUPT_EVENTS':str(c/'attempt/events')}); assert p.returncode==-9
assert (c/'attempt/events').read_text()==retained+'conflicted\n'
assert 'conflict-history: unknown' in prepare(c,co,cu).stdout
print('Persisted events after interruption:\n'+(c/'attempt/events').read_text(),flush=True)
print('SCENARIO pinned consumption preserves independent origins and unsafe homes',flush=True)
p,po,pu=world('consume'); cmd('git','clone','-q','--bare',p/'origin.git',p/'independent.git'); cmd('git','clone','-q',p/'independent.git',p/'ind-seed'); cmd('git','clone','-q',p/'independent.git',p/'own')
write(p/'ind-seed','independent.txt','own source\n'); own=commit(p/'ind-seed','independent update'); git(p/'ind-seed','push','-q','origin','main')
for id in ['dirty','divergent']:
    cmd('git','clone','-q',p/'origin.git',p/id)
write(p/'dirty','unsaved','local unsaved\n'); write(p/'divergent','unique.txt','unique work\n'); div=commit(p/'divergent','unique secondmate work')
for id in ['own','dirty','divergent']: write(p/id,'.fm-secondmate-home',id+'\n')
(p/'home/data/secondmates.md').write_text(''.join(f'- {id} - disposable (home: {p/id}; scope: validation; projects: none; added 2026-01-01)\n' for id in ['own','dirty','divergent']))
write(p/'seed','new.txt','fork landed bytes\n'); target=commit(p/'seed','advance fork'); git(p/'seed','push','-q','origin','main')
# An old pin must not silently consume the now-moving default.
assert product(p,p/'primary','--consume-origin',po,ok=False).returncode
assert git(p/'primary','rev-parse','HEAD')==po and git(p/'own','rev-parse','HEAD')==po
product(p,p/'primary','--consume-origin',target)
assert git(p/'primary','rev-parse','HEAD')==target
assert git(p/'own','rev-parse','HEAD')==own and git(p/'own','remote','get-url','origin')==str(p/'independent.git')
assert git(p/'dirty','rev-parse','HEAD')==po and (p/'dirty/unsaved').read_text()=='local unsaved\n'
assert git(p/'divergent','rev-parse','HEAD')==div
pending=p/'home/state/.secondmate-update-reconcile/divergent.pending'; print('Durable divergence record:\n'+pending.read_text(),flush=True)
product(p,p/'primary','--consume-origin',target)
print('ALL LIVE CLI SCENARIOS PASSED; no runtime primary was launched and no publication attestation synthesized',flush=True)
