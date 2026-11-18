import os, pathlib, subprocess, collections, json, shutil
root=pathlib.Path.cwd()
tmp=root/'.validation-tmp'/'selection'
tmp.mkdir(parents=True,exist_ok=True)
evidence=pathlib.Path('~/.no-mistakes/evidence/01M7Q347TWJ63EVPVBKV3ZZRJD')
log=[]
def run(args,env=None,ok=True):
 p=subprocess.run([str(a) for a in args],cwd=root,env=env,text=True,capture_output=True,timeout=45)
 log.append('$ '+' '.join(map(str,args))+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
 if ok: assert p.returncode==0, log[-1]
 return p
try:
 base=tmp/'base'; (base/'bin').mkdir(parents=True,exist_ok=True)
 if not (base/'tests').exists(): (base/'tests').symlink_to(root/'tests',target_is_directory=True)
 old=base/'bin'/'fm-test-run.sh'
 old.write_bytes(subprocess.check_output(['git','show','9ea9711fe729ed9dd22994257920c55f04f68670:bin/fm-test-run.sh']))
 old.chmod(0o755)
 runner=root/'bin/fm-test-run.sh'
 def listed(exe,lane): return run([exe,'--list','--lane',lane]).stdout.splitlines()
 lanes=run([runner,'--list-lanes']).stdout.splitlines()
 serial=[x for x in lanes if x.startswith('portable-serial-')]
 all_serial=listed(runner,'portable-serial'); selected=[]
 for lane in serial:
  current=listed(runner,lane); previous=listed(old,lane)
  assert current==previous, lane+' changed membership/order'
  selected+=current
 assert collections.Counter(selected)==collections.Counter(all_serial)
 old_parallel=[]; new_parallel=[]
 for lane in ['portable-parallel-1','portable-parallel-2']:
  old_parallel+=listed(old,lane); new_parallel+=listed(runner,lane)
 assert collections.Counter(old_parallel)==collections.Counter(new_parallel)
 assert len(new_parallel)==len(set(new_parallel))==26
 assert 'tests/fm-pi-primary-types.test.sh' in listed(runner,'portable-parallel-1')
 log.append('OBSERVED: all eleven serial shard memberships/orders unchanged from base; serial union exact; all 26 parallel scripts retained exactly once; Pi typecheck remains in lane 1.\n')
 fake=tmp/'fakebin'; fake.mkdir(exist_ok=True)
 sorter=fake/'sort'; sorter.write_text('#!/usr/bin/env bash\n"'+shutil.which('sort')+'" "$@"\nexit 42\n'); sorter.chmod(0o755)
 env=os.environ.copy(); env['PATH']=str(fake)+os.pathsep+env['PATH']
 p=run([runner,'--list','--lane',serial[0]],env,False)
 assert p.returncode!=0 and 'could not pack portable serial shards' in p.stderr and not p.stdout.strip()
 p=run([runner,'--check-coverage'],env,False)
 assert p.returncode!=0 and 'FM_TEST_COVERAGE ok' not in p.stdout
 p=run([runner,'--list','--lane','portable-serial-1of12'],ok=False)
 assert p.returncode!=0 and not p.stdout.strip()
 log.append('OBSERVED: failed sorter rows rejected by shard listing and coverage guard; invalid shard total rejected.\n')
 # Inventory-only mode exits before any linter is resolved or executed.
 lint=root/'bin/fm-lint.sh'
 lint_env=os.environ.copy(); lint_env['CI']='true'
 complete=run([lint,'--list-files'],lint_env).stdout.splitlines()
 for n in [2,4]:
  union=[]
  for i in range(1,n+1):
   args=[lint,'--partition',f'{i}of{n}','--list-files']
   paths=run(args).stdout.splitlines(); assert paths
   assert paths==run(args).stdout.splitlines()
   union+=paths
  assert collections.Counter(union)==collections.Counter(complete)
 log.append('OBSERVED: two-way and four-way inventory-only lint partitions are nonempty, deterministic, and cover the canonical inventory exactly once. No lint analysis executed.\n')
 print('Selection and adversarial CLI checks passed')
finally:
 (evidence/'selection-cli.log').write_text('\n'.join(log))
