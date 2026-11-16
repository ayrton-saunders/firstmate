import os, pathlib, subprocess, json, time, hashlib, shutil
root = pathlib.Path.cwd()
home = root / '.gate-test-tmp' / 'manual-home'
home.mkdir()
env = dict(os.environ)
for k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE'):
    env.pop(k, None)
env['FM_HOME'] = str(home)
cli = str(root / 'bin/fm-inbox.sh')
def call(*args, expected=0, stdin=None):
    p = subprocess.run([cli, *args], env=env, input=stdin, text=True, capture_output=True)
    print('$ bin/fm-inbox.sh ' + ' '.join(args), flush=True)
    print(p.stdout, end='', flush=True)
    if p.stderr: print(p.stderr, end='', flush=True)
    print('exit=' + str(p.returncode), flush=True)
    assert p.returncode == expected, (args,p.returncode,expected)
    return p.stdout

def snapshot():
    return {str(p.relative_to(home)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (home/'state').rglob('*') if p.is_file()}

try:
    print('SCENARIO 1: synthetic outside request, deduplicated retry, bounded read-only timeout and retry', flush=True)
    first = json.loads(call('note','--request-id','lab-request-001','--json','Compute 6 times 7; return the final result.'))
    nid = first['id']
    replay = json.loads(call('note','--request-id','lab-request-001','--json','Compute 6 times 7; return the final result.'))
    assert replay['id'] == nid and replay['outcome'] == 'replay'
    before = snapshot()
    start = time.monotonic()
    result = json.loads(call('wait',nid,'--timeout','1','--json',expected=3))
    elapsed = time.monotonic()-start
    assert result['outcome'] == 'timeout' and result['reply'] is None and result['acknowledged'] is False
    assert 0.9 <= elapsed < 4, elapsed
    assert before == snapshot(), 'wait mutated durable state'
    result = json.loads(call('wait',nid,'--timeout','0','--json',expected=3))
    assert result['outcome'] == 'timeout' and before == snapshot()
    call('receipts','--all-pending','--all-handled','--all-replies')
    print('Observed bounded timeout after %.3fs; all durable state byte-identical; retry retains original note.' % elapsed, flush=True)

    print('SCENARIO 2: caller is already waiting when a local operator publishes a durable terminal reply',flush=True)
    waiter = subprocess.Popen([cli,'wait',nid,'--timeout','15','--json'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        time.sleep(1)
        assert waiter.poll() is None, 'wait returned before completion'
        body = 'Result: 42\nQuoted "value", slash \\ and unicode café\n\n'
        call('reply',nid,'-',stdin=body)
        output, err = waiter.communicate(timeout=5)
        print('$ earlier running wait returns without another caller prompt\n'+output+'exit='+str(waiter.returncode),flush=True)
        assert waiter.returncode == 0 and not err
        result = json.loads(output)
        assert result['schema'] == 'fm-inbox-wait.v1' and result['outcome']=='answered'
        assert result['acknowledged'] is False and result['reply']['body']==body[:-1]
        call('drain','--ack',nid)
        final = json.loads(call('wait',nid,'--timeout','0','--json'))
        assert final['outcome']=='answered' and final['acknowledged'] is True
        assert final['reply']==result['reply']
        call('wait',nid,'--timeout','0')
        call('receipts','--all-pending','--all-handled','--all-replies')
    finally:
        if waiter.poll() is None: waiter.kill()
        waiter.wait()

    print('SCENARIO 3: no fabricated answer for bare acknowledgement, missing id, invalid input, or corrupt reply',flush=True)
    note = json.loads(call('note','--json','Information only; no work requested.'))['id']
    waiter = subprocess.Popen([cli,'wait',note,'--timeout','15','--json'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        time.sleep(0.5)
        assert waiter.poll() is None
        call('drain','--ack',note)
        output, err = waiter.communicate(timeout=5)
        print('$ earlier running wait returns on bare acknowledgement\n'+output+'exit='+str(waiter.returncode),flush=True)
        result = json.loads(output)
        assert waiter.returncode == 2 and result['outcome']=='handled' and result['reply'] is None
    finally:
        if waiter.poll() is None: waiter.kill()
        waiter.wait()
    missing = json.loads(call('wait','absent','--timeout','0','--json',expected=4))
    assert missing['outcome']=='unknown'
    for value in ('-1','1.5','nope','86401','999999999999999999999999'):
        call('wait',nid,'--timeout',value,expected=1)
    for args in (('wait',),('wait','../bad','--json'),('wait','x','y'),('wait','x','--bogus'),('wait','x','--timeout')):
        call(*args,expected=1)
    # Inject a corrupt serialized reply as an adversarial durable-state input.
    record = home/'state'/'inbox'/'.replies'/note
    record.write_text('seq=invalid\nat=synthetic\n--\nNot a valid answer\n')
    call('wait',note,'--timeout','0','--json',expected=1)
    print('All three local CLI scenarios completed with expected output and exit statuses.',flush=True)
finally:
    shutil.rmtree(home)
