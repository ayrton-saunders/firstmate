#!/usr/bin/env python3
"""Drive the real local inbox CLI with synthetic requests; not primary pickup proof."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

root = Path.cwd()
home = Path(tempfile.mkdtemp(prefix='.inbox-live-', dir=root))
children = []
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_'):
        del env[key]
env.update(FM_HOME=str(home), FM_STATE_OVERRIDE=str(home/'state'),
           FM_DATA_OVERRIDE=str(home/'data'), FM_CONFIG_OVERRIDE=str(home/'config'),
           FM_PROJECTS_OVERRIDE=str(home/'projects'))
cli = str(root/'bin/fm-inbox.sh')
for name in ('state', 'data', 'config', 'projects'):
    (home/name).mkdir()

def emit(args, p, elapsed=None):
    print('$ bin/fm-inbox.sh ' + ' '.join(args), flush=True)
    print(p.stdout, end='' if p.stdout.endswith('\n') else '\n', flush=True)
    if p.stderr:
        print('stderr: '+p.stderr, flush=True)
    print('exit='+str(p.returncode)+(f' elapsed={elapsed:.3f}s' if elapsed is not None else ''), flush=True)

def run(*args, code=0, body=None):
    start = time.monotonic()
    p = subprocess.run([cli, *args], env=env, input=body, text=True, capture_output=True, timeout=15)
    emit(args, p, time.monotonic()-start)
    assert p.returncode == code, (args, p.returncode, code)
    return p.stdout

def state():
    return {str(p.relative_to(home)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in home.rglob('*') if p.is_file()}

def begin(*args):
    p = subprocess.Popen([cli, *args], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    children.append(p)
    time.sleep(0.7)
    assert p.poll() is None, 'wait ended before the durable completion transition'
    return p

def finish(p, args, code):
    out, err = p.communicate(timeout=10)
    emit(args, subprocess.CompletedProcess(args, p.returncode, out, err))
    assert p.returncode == code
    return json.loads(out)

try:
    print('LOCAL REAL-CLI VALIDATION: disposable home, synthetic requests, no model or operational primary.', flush=True)
    print('\nSCENARIO 1: Caller submits once, sees pending receipts, and receives a final refusal during a running wait.')
    submitted = json.loads(run('note','--request-id','lab-outside-001','--json','Please perform the requested deployment and report its final result.'))
    nid = submitted['id']
    repeated = json.loads(run('note','--request-id','lab-outside-001','--json','Please perform the requested deployment and report its final result.'))
    assert repeated['id'] == nid
    run('receipts','--all-pending','--all-handled','--all-replies')
    run('drain')
    args = ('wait',nid,'--json','--timeout','8')
    p = begin(*args)
    final = 'Refused: publication requires explicit approval.\nNo deployment performed. "Quoted" café \\ done.'
    run('reply',nid,'-',body=final)
    answer = finish(p,args,0)
    assert answer['schema'] == 'fm-inbox-wait.v1'
    assert answer['outcome'] == 'answered' and answer['acknowledged'] is False
    assert answer['reply']['body'] == final
    run('drain','--ack',nid)
    before = state()
    again = json.loads(run('wait',nid,'--timeout','0','--json'))
    assert again['outcome'] == 'answered' and again['acknowledged'] is True
    assert again['reply'] == answer['reply']
    assert final in run('wait',nid,'--timeout','0')
    receipts = json.loads(run('receipts','--all-pending','--all-handled','--all-replies'))
    print('Receipts retained alongside wait output for comparison.', flush=True)
    assert before == state(), 'repeated reads mutated durable records'

    print('\nSCENARIO 2: Informational note is acknowledged during wait; no fabricated answer; missing note is distinct.')
    nid = json.loads(run('note','--json','Informational only; no work or response required.'))['id']
    args = ('wait',nid,'--timeout','8','--json')
    p = begin(*args)
    run('drain','--ack',nid)
    result = finish(p,args,2)
    assert result['outcome'] == 'handled' and result['acknowledged'] is True and result['reply'] is None
    result = json.loads(run('wait','never-submitted','--timeout','0','--json',code=4))
    assert result['outcome'] == 'unknown' and result['reply'] is None

    print('\nSCENARIO 3: Bounded timeout does not cancel or notify again; same id returns durable answer after retry.')
    nid = json.loads(run('note','--json','Please calculate 6 times 7.'))['id']
    before = state()
    start = time.monotonic()
    result = json.loads(run('wait',nid,'--timeout','1','--json',code=3))
    elapsed = time.monotonic()-start
    assert result['outcome'] == 'timeout' and result['acknowledged'] is False and result['reply'] is None
    assert 0.9 <= elapsed < 5, elapsed
    assert before == state(), 'timeout changed note, notification or other state'
    result = json.loads(run('wait',nid,'--timeout','0','--json',code=3))
    assert result['outcome'] == 'timeout' and before == state()
    run('reply',nid,'Result: 42')
    result = json.loads(run('wait',nid,'--timeout','0','--json'))
    assert result['outcome'] == 'answered' and result['reply']['body'] == 'Result: 42'
    assert (home/'state/inbox'/f'{nid}.note').is_file(), 'timeout or answer silently acknowledged work'

    print('\nSCENARIO 4: Invalid arguments and corrupt durable replies fail closed without queue mutation.')
    before = state()
    for timeout in ('-1','1.5','nope','86401','99999999999999999999999999999'):
        run('wait',nid,'--timeout',timeout,'--json',code=1)
    for args in [('wait',), ('wait','../outside','--json'), ('wait',nid,'extra'), ('wait',nid,'--bogus'), ('wait',nid,'--timeout')]:
        run(*args,code=1)
    assert before == state(), 'invalid arguments mutated state'
    bad = json.loads(run('note','--json','Corrupt-record adversarial case'))['id']
    path = home/'state/inbox/.replies'/bad
    path.write_text('seq=not-a-number\nat=2026-11-04T00:00:00Z\n--\nThis must not be represented as a real answer.\n')
    before = state()
    run('wait',bad,'--timeout','0','--json',code=1)
    assert before == state(), 'corrupt record read mutated state'
    print('\nAll four local real-CLI scenarios passed. Operational primary pickup was not attempted or simulated.', flush=True)
finally:
    for p in children:
        if p.poll() is None:
            p.terminate()
        p.communicate(timeout=10)
    shutil.rmtree(home)
    print('Disposable home removed; all started waiter processes reaped.', flush=True)
