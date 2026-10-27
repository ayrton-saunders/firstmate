import os,json,shutil,subprocess,tempfile
from pathlib import Path
root=Path.cwd(); evidence=Path('/Users/ayrton/.no-mistakes/evidence/01M5ZFKDJ61NKC25YHP94CHGRM/default-inbox.json'); records=[]
with tempfile.TemporaryDirectory(dir=root/'.no-mistakes/test-scratch') as tmp:
    home=Path(tmp)/'home'; home.mkdir(); shutil.copytree(root/'bin',home/'bin')
    for d in ('config','state','data','user-home'): (home/d).mkdir()
    (home/'config/discord-integration.json').write_text('{"enabled":false}')
    env={k:v for k,v in os.environ.items() if k!='FM_HOME' and not k.endswith('_OVERRIDE')}; env['HOME']=str(home/'user-home'); env['PYTHONDONTWRITEBYTECODE']='1'
    def run(*args):
        p=subprocess.run(['/bin/bash',str(home/'bin/fm-inbox.sh'),*args],env=env,text=True,capture_output=True,timeout=20)
        records.append({'args':args,'code':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
        assert p.returncode==0 and not p.stderr,p.stderr
        return p.stdout
    note=json.loads(run('note','--request-id','unset-default-live','--json','Disposable default-home request'))['id']
    assert 'Disposable default-home request' in run('drain')
    run('reply','--json',note,'Disposable default-home answer')
    assert 'Disposable default-home answer' in run('receipts','--all-replies')
evidence.write_text(json.dumps(records,indent=2))
print('Actual default-home inbox note/drain/reply/receipts succeeded with FM_HOME absent.')
