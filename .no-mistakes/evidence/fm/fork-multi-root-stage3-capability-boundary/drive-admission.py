"""Manual local SDK/installed-ingress exercise; synthetic inactive enrollments only.
The fixture supplies private records and a trusted trampoline, NOT an adapter.
All admission, parsing, reservation and application reads use shipped code.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:3])
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('fixtures', root / 'tests/remote-capability.py')
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)
e = f.e

def refused(label, action, expected):
    try:
        action()
    except e.Refusal as error:
        print(label + ': REFUSED ' + str(error), flush=True)
        assert expected in str(error)
    else:
        raise AssertionError(label + ' unexpectedly permitted')

c = f.Capability(methodName='runTest')
c.setUp()
try:
    print('SCENARIO 1: typed SDK vocabulary and installed ingress (private synthetic lane)', flush=True)
    # Independently specified verb/class and body examples, not implementation table.
    samples = [
        ('observe', 'observe', {}), ('probe', 'observe', {'challenge':'new'}),
        ('reply-read','reply-read',{'task':'t','correlation':'c'}),
        ('reply-ack','reply-ack',{'task':'t','correlation':'c','result_digest':'0'*64}),
        ('task-answer','task-answer',{'task':'t','correlation':'c','text':'yes'}),
        ('task-steer','task-steer',{'task':'t','correlation':'c','text':'continue'}),
        ('inherit-apply','inherit',{'material':'captain-shared','content':'abc','content_digest':hashlib.sha256(b'abc').hexdigest()}),
        ('sync-verify','verify',{'parent_commit':'a'*40}),
        ('dispatch','dispatch',{'task':'t','instructions_digest':'0'*64}),
        ('launch','launch',{'task':'t','reader':'shell-entry','launch_digest':'0'*64}),
        ('relaunch','relaunch',{'task':'t','incarnation':'i','launch_digest':'0'*64}),
        ('stop','stop',{'task':'t','incarnation':'i'}),
        ('cleanup','cleanup',{'task':'t','incarnation':'i'}),
        ('repair-accepted','repair',{'resource':'worker-projection','accepted_commit':'a'*40}),
        ('update-prepare','prepare',{'operation':'op','target_commit':'b'*40,'source_digest':'0'*64,'resources_digest':'1'*64}),
        ('operation-step','transition',{'operation':'op','transition':'fence','expected_revision':1}),
        ('operation-status','operation-status',{'operation':'op'}),
        ('abort-before-stop','abort',{'operation':'op','expected_revision':1}),
    ]
    ingress = str(c.location / 'ingress')
    for verb, expected, body in samples:
        data = c.request(verb, body)
        actual = e.request_class(e.typed_request(data))
        assert actual == expected
        result = subprocess.run([ingress, 'inspect-request'], input=data, capture_output=True, timeout=20)
        print(f'{verb}: class={actual}; installed exit={result.returncode}; ' + (result.stdout or result.stderr).decode().strip(), flush=True)
        assert result.returncode == (0 if verb in ('observe','probe','sync-verify') else 126)
    refused('caller-supplied script', lambda:e.typed_request(c.request('observe', {'script':'evil.sh'})), 'unexpected typed body')
    refused('unknown provision verb', lambda:e.typed_request(c.request('provision')), 'unknown named verb')
    corrupted = json.loads(c.request()); corrupted['request_digest'] = '0'*64
    refused('changed request digest', lambda:e.stage_request(c.base,'lane-a',e.canonical(corrupted),c.operands), 'digest mismatch')
    print('SCENARIO 2: owner rejects reads before registration and retains pending/read leases', flush=True)
    for kind in ('shell-entry','source-module','python-import','callback'):
        refused(kind+' missing file, no nonce', lambda:e.read_registered_application(c.base,'lane-a',None,kind,c.operands), 'missing installed registration')
        code = ("print('fresh-"+kind+"')\n").encode()
        path = c.write_entry(kind,code)
        nonce = c.reserve(c.request(),code,kind)
        leases = e.population(c.location)['payload']['leases']
        print(kind+': durable reservation BEFORE read = '+leases[nonce]['state'], flush=True)
        assert leases[nonce]['state'] == 'pending'
        refused(kind+' cooperating mutation before read',lambda:c.fixture_move(path,b'changed'), 'prevents movement')
        loaded = e.read_registered_application(c.base,'lane-a',nonce,kind,c.operands)
        print(kind+': returned application bytes = '+repr(loaded),flush=True)
        assert loaded == code
        refused(kind+' reused nonce',lambda:e.read_registered_application(c.base,'lane-a',nonce,kind,c.operands), 'missing/unusable')
        refused(kind+' cooperating mutation after read',lambda:c.fixture_move(path,b'changed'), 'prevents movement')
    foreign = c.folder / 'foreign'; foreign.mkdir(mode=0o700)
    refused('foreign physical root',lambda:e.stage_request(c.base,'lane-a',c.request(),dict(c.operands,root=str(foreign))), 'foreign physical root')
    nonce = c.reserve(c.request(),b'not-present')
    c.gate('fenced')
    refused('fenced reservation read',lambda:e.read_registered_application(c.base,'lane-a',nonce,'shell-entry',c.operands), 'closed by fence')
    c.gate('released')
    with e.admission(c.base,'lane-a') as (_,gate):
        gate['payload']['generation'] += 1
        e.publish(c.location/'gate.json','gate',gate['revision']+1,gate['payload'])
    refused('stale generation read',lambda:e.read_registered_application(c.base,'lane-a',nonce,'shell-entry',c.operands), 'generation mismatch')
    print('SCENARIO 4a: installed enrollment cannot activate a reserved lane',flush=True)
    record=e.inventory(c.base); entry=record['payload']['entries']['lane-a']; entry['state']='reserved'; entry['revision']+=1; e.seal_claim(entry)
    e.publish(c.base/'claims.json','claims',record['revision']+1,record['payload'])
    result=subprocess.run([ingress,'inspect-request'],input=c.request(),capture_output=True,timeout=20,env=dict(os.environ,FM_REMOTE_JOB_ACTIVE='1',FM_FIXTURE='1'))
    print('reserved lane inspection: exit='+str(result.returncode)+' '+result.stderr.decode().strip(),flush=True)
    assert result.returncode==126 and b'inactive enrollment' in result.stderr
    for verb in ('activate','enroll','fixture-activate'):
        result=subprocess.run([ingress,verb],capture_output=True,timeout=20)
        print(verb+': exit='+str(result.returncode)+' '+result.stderr.decode().strip(),flush=True)
        assert result.returncode==126
finally:
    c.tearDown()

print('SCENARIO 3: real Bash A->M replacement, synthetic outside-owner trampoline (not adapter qualification)',flush=True)
for kind in ('shell-entry','source-module','python-import','callback'):
    for broken in (False,True):
        c=f.Capability(methodName='runTest'); c.setUp()
        try:
            fresh=b"print('M')\n"; request_path=c.folder/'request.json'
            command=[f.PYTHON,'-I','-S',str(c.driver()),str(c.base),'lane-a',kind,str(request_path),hashlib.sha256(fresh).hexdigest()]
            invocation=shlex.join(command)
            old=("#!/usr/bin/env bash\nprintf 'opened-A\\n'\nIFS= read -r resume\n"+('' if broken else 'exec ')+invocation+"\nprintf 'A-buffered\\n'\n").encode()
            path=c.write_entry(kind,old)
            process=subprocess.Popen(['bash',str(path)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                assert process.stdout.readline()=='opened-A\n'
                c.fixture_move(path,fresh)
                request_path.write_bytes(c.request('launch',{'task':'task-1','reader':kind,'launch_digest':hashlib.sha256(fresh).hexdigest()}))
                out,err=process.communicate('resume\n',timeout=30)
                print(f'{kind}, returning-guard={broken}: exit={process.returncode}, stdout={out!r}, stderr={err!r}',flush=True)
                assert process.returncode==0
                assert out==('M\nA-buffered\n' if broken else 'M\n')
            finally:
                if process.poll() is None:
                    process.kill(); process.communicate()
        finally:
            c.tearDown()
print('Local owner and installed ingress scenarios completed. No fleet/backend/agent launched.',flush=True)
