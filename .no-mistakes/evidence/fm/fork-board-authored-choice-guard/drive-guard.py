import os,json,subprocess,pathlib,hashlib
root=pathlib.Path.cwd()
board=pathlib.Path(os.environ['FM_HOME'])/'.lavish/bearings-board.html'
original=json.loads((root/'.gate-test/original.json').read_text())
counter=json.loads((root/'.gate-test/counterfactual.json').read_text())
def drive(name,payload,expected):
    p=root/'.gate-test/attempt.json'; p.write_text(json.dumps(payload))
    before=board.read_bytes()
    out=subprocess.run(['bin/fm-bearings-board.sh','build',str(p)],text=True,capture_output=True)
    print(f'CASE {name}\nexit={out.returncode}\n{out.stdout}{out.stderr}',flush=True)
    assert out.returncode!=0, name
    for message in expected: assert message in out.stderr,(name,message)
    assert board.read_bytes()==before, 'Rejected payload changed the existing board'
    print('Existing board bytes unchanged; sha256='+hashlib.sha256(before).hexdigest(),flush=True)
drive('Original six freeform-only decisions',original,['an authored choice is required']+[f'held-call-{i}' for i in range(1,7)])
p=json.loads(json.dumps(counter)); p['captains_call'][3]['options']=[]
drive('One empty decision among valid decisions and credential',p,['held-call-4','an authored choice is required'])
p=json.loads(json.dumps(original)); p['captains_call'][0]['options']=[{'value':'reconcile','label':'My own alternative'}]
drive('Attempt to supply reserved Reconcile as an authored option',p,['does not satisfy'])
p=json.loads(json.dumps(counter)); p['captains_call'][0]['options'].append({'value':'reconcile','label':'My own Reconcile'})
drive('Attempt to add authored Reconcile alongside substantive choices',p,['does not satisfy'])
# A single authored alternative suffices; explicit freeform is not required.
p=json.loads(json.dumps(counter)); p['captains_call']=p['captains_call'][:1]
p['captains_call'][0]['options']=[{'value':'proceed','label':'Proceed as planned'}]
p['captains_call'][0]['allow_freeform']=False
(root/'.gate-test/single-choice.json').write_text(json.dumps(p))
# End in the valid counterfactual for an independently reviewed browser result.
out=subprocess.run(['bin/fm-bearings-board.sh','build',str(root/'.gate-test/counterfactual.json')],text=True,capture_output=True)
print(f'CASE Restore valid authored counterfactual\nexit={out.returncode}\n{out.stdout}{out.stderr}',flush=True)
assert out.returncode==0
