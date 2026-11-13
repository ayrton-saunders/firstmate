"""Drive real public CLIs with synthetic config and empty release directories.
Oracle: approved enrollment contract (accept in-tree existing canonical releases;
reject escaping/dangling roots and retain config/authority checks). No private
package, CLI, interpreter or lifecycle dependency is substituted.
"""
import copy, json, os, pathlib, shutil, subprocess, sys
root = pathlib.Path.cwd()
world = root / '.local-discord-validation/live'
world.mkdir()
home = world / 'home'
subprocess.run(['bash', 'bin/fm-lab-home.sh', 'create', str(home)], check=True, capture_output=True)
code = world / 'code'
(code / 'releases/r1').mkdir(parents=True)
(code / 'releases/r2').mkdir()
(code / 'current').symlink_to('releases/r1')
(world / 'outside').mkdir()
base = dict(schema=2, enabled=True, home=str(home), package_root=str(code/'current'),
            hashes={'personal_discord/retired.py': 'obsolete'}, journal=str(home/'parent.sqlite'),
            python_executable=str(pathlib.Path(sys.executable).resolve()), source=str(root),
            routes=[dict(target='mapped',project='sample')], projects={'sample':str(root)}, mapping={})
config_path = home/'config/discord-integration.json'
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
env['FM_HOME'] = str(home)
env['PYTHONDONTWRITEBYTECODE'] = '1'
failures=[]
results=[]
def drive(label, args=None, config=None, expected='', ok=False, auth=None):
    config_path.write_text(json.dumps(base if config is None else config))
    localenv=env.copy()
    if auth is not None: localenv['FM_DISCORD_AUTH']=auth
    cmd=[sys.executable, '-I', str(root/'bin/fm-discord-hook.py'), 'spawn', 'probe', str(world/'unmapped')]
    if args is not None: cmd=[sys.executable, '-I', str(root/'bin'/args[0]), *args[1:]]
    proc=subprocess.run(cmd, env=localenv, input='synthetic ordinary words', text=True, capture_output=True, timeout=15)
    passed=(proc.returncode == 0 if ok else proc.returncode != 0 and expected in proc.stderr)
    assert not (home/'parent.sqlite').exists(), 'unexpected journal creation'
    row=dict(label=label, command=cmd, exit=proc.returncode, stdout=proc.stdout, stderr=proc.stderr, matched_contract=passed)
    results.append(row)
    print(json.dumps(row), flush=True)
    if not passed: failures.append(label)
try:
    drive('current with stale legacy hashes passes real parent validation on unmapped spawn',ok=True)
    cfg=copy.deepcopy(base); cfg.pop('hashes')
    drive('current without hashes passes parent validation',config=cfg,ok=True)
    (code/'current').unlink(); (code/'current').symlink_to('releases/r2')
    drive('self-update switches current to second enrolled release without config changes',ok=True)
    cfg=copy.deepcopy(base); cfg['package_root']=str(code/'releases/r1')
    drive('canonical direct release remains accepted',config=cfg,ok=True)
    (code/'absolute').symlink_to(code/'releases/r1')
    cfg=copy.deepcopy(base); cfg['package_root']=str(code/'absolute')
    drive('absolute in-tree symlink accepted',config=cfg,ok=True)
    refusal='canonical release inside the enrolled code tree'
    links={'escape':'../outside','dangling':'releases/missing','loop':'loop',
           'tree':'.','leave-return':'../outside/back',
           'missing-parent':'releases/missing/../r1', 'file-parent':'releases/file/../r1'}
    (world/'outside/back').symlink_to(code/'releases/r1')
    (code/'releases/file').write_text('not a directory')
    for label,target in links.items():
        (code/label).symlink_to(target)
        cfg=copy.deepcopy(base); cfg['package_root']=str(code/label)
        drive('reject '+label+' symlink target',config=cfg,expected=refusal)
    for key,value,reason in [('home','/not-this-home','Integration schema/home mismatch'),
                             ('schema',1,'Integration schema/home mismatch'),
                             ('routes',[],'journal/routes/projects missing'),
                             ('projects',{},'journal/routes/projects missing'),
                             ('python_executable',str(world/'no-python'),'Pinned existing parent interpreter required')]:
        cfg=copy.deepcopy(base); cfg[key]=value
        drive('retain '+key+' guard',config=cfg,expected=reason)
    meta=home/'state/mapped.meta'; meta.write_text('spawn_gen=gen1\nharness=codex\n')
    send=['fm-discord-hook.py','send','mapped','mapped',str(meta),'tmux']
    drive('malformed Discord permit still refused',args=send,auth='bad',expected='typed parent-issued lane permit')
    meta.write_text('harness=codex\n')
    drive('missing endpoint generation still refused',args=send,auth='1'*32,expected='recorded lifecycle generation')
    cfg=copy.deepcopy(base); cfg['package_root']=str(code/'escape')
    for cli,args in [('fm-discord-hook.py',['ready']),('fm-discord-hook.py',['outcome','note']),
                     ('fm-discord-hook.py',['confirm-send','remote','receipt']),
                     ('fm-discord-dispatch.py',['request','mapped','Question']),
                     ('fm-discord-reply.py',['request','mapped','Approved answer'])]:
        drive('escaping release refused before private imports: '+cli+' '+args[0],args=[cli,*args],config=cfg,expected=refusal)
finally:
    (pathlib.Path(sys.argv[1])/'live-results.json').write_text(json.dumps(results,indent=2))
    shutil.rmtree(world)
print('Contract failures:',failures)
sys.exit(bool(failures))
