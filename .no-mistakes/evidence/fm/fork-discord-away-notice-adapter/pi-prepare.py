import importlib.util,json,os,shutil,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('live',Path.cwd()/'.live-validation/drive.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class PiLive(m.Live): pass
f=PiLive('test_live_selection_and_defaults');f.setUp()
f.contract('archive')
f.config['source']=str(m.ROOT)
f.config['projects']={'project':str(m.ROOT)}
f.enroll()
f.contract('enter','--spend','1')
f.hold()
(f.home/'state/task.meta').write_text('project='+str(m.ROOT)+'\n')
# Only synthetic private configuration, supplied to the real Pi process.
(Path.cwd()/'.live-validation/pi-world.json').write_text(json.dumps({'home':str(f.home),'config':f.config}))
print(f.home)
