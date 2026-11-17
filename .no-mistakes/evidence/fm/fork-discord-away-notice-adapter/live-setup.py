import os, sys, pathlib, importlib.util, unittest, shutil, json, subprocess, sqlite3
ROOT=pathlib.Path.cwd(); TMP=ROOT/'.notice-validation/worlds'; TMP.mkdir(exist_ok=True)
sys.argv=['fixture',str(ROOT),str(TMP),str(ROOT/'.notice-validation/parent')]
original=unittest.main;unittest.main=lambda **kwargs:None
spec=importlib.util.spec_from_file_location('fixtures',ROOT/'tests/fm-away-notice-fixture.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);unittest.main=original
class World(m.RealFacade):
 def setUp(self):
  super().setUp()
  saved=self.world/'saved-home';self.home.rename(saved)
  subprocess.run(['bash',str(ROOT/'bin/fm-lab-home.sh'),'create',str(self.home)],check=True,capture_output=True)
  shutil.copytree(saved,self.home,dirs_exist_ok=True);shutil.rmtree(saved)
  shutil.copyfile(ROOT/'bin/fm-captain-hold.sh',self.code/'bin/fm-captain-hold.sh')
  self.env['PATH']=os.environ['PATH'];self.env.pop('FM_GATE_REFUSE_BYPASS',None)
  self.env['GH_CONFIG_DIR']=str(self.world/'gh-config')
  (self.home/'data').mkdir(exist_ok=True)
  (self.home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/archive.md"\n')
  (self.home/'data/backlog.md').write_text('# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n')
 def hold(self,task='task',lifecycle=None):
  r=subprocess.run(['bash',str(self.code/'bin/fm-captain-hold.sh'),'hold',task,'--reason','A routine local choice','--title','Local choice'],env=self.env,text=True,capture_output=True)
  print('hold',task,r.returncode,r.stdout,r.stderr,flush=True)
  if r.returncode:raise RuntimeError('hold failed')
  (self.home/f'state/{task}.meta').write_text('project='+str(self.code)+'\n')
 def snapshot(self,label):
  print('\n'+label,flush=True)
  print(self.contract('read').stdout if False else self.call('reach').stdout,flush=True)
  print(json.dumps([{'kind':r['kind'],'state':r['state'],'error':r['error']} for r in self.rows()]),flush=True)
  print('parent events',json.dumps(self.events()),flush=True)
if __name__=='__main__':
 w=World('test_real_templates_dedupe_and_receipt_only_reconciliation');w.setUp();w.hold();w.report(host=True);w.snapshot('host report');w.report();w.snapshot('duplicate report');print(w.call('return').stdout)
