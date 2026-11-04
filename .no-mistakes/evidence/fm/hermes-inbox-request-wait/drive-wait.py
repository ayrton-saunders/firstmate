"""Drive the real inbox CLI with synthetic local requests, no simulated primary.
Oracle: fm-inbox --help's public outcomes/exit codes and author's durable wait intent.
Rejects premature handled success, lost replies, cancellation on timeout, invented answers.
"""
import os, pathlib, subprocess, json, time, shutil
root = pathlib.Path.cwd()
home = root / '.wait-live-home'
evidence = pathlib.Path('~/.no-mistakes/evidence/01M6KJKFYDRYW2GRP6S8EH13QT')
assert not home.exists()
home.mkdir()
env = os.environ.copy()
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
    env.pop(key, None)
env['FM_HOME'] = str(home)
children = []
log = (evidence / 'wait-cli-transcript.log').open('w')
def emit(text):
    log.write(text+'\n'); log.flush()
def run(*args, code=0, stdin=None):
    emit('$ bin/fm-inbox.sh '+ ' '.join(args))
    start = time.monotonic()
    p = subprocess.run([str(root/'bin/fm-inbox.sh'), *args], env=env, input=stdin, capture_output=True, text=True, timeout=15)
    emit(p.stdout.rstrip()); emit(p.stderr.rstrip())
    emit('exit=%d elapsed=%.3fs' % (p.returncode, time.monotonic()-start))
    assert p.returncode == code, (args, p.returncode, p.stdout,p.stderr)
    return p.stdout

def submit(text, request):
    return json.loads(run('note','--request-id',request,'--json',text))['id']

def wait_async(id):
    args = ['wait',id,'--timeout','20','--json']
    emit('$ bin/fm-inbox.sh '+' '.join(args)+' [caller now waits]')
    p = subprocess.Popen([str(root/'bin/fm-inbox.sh'),*args],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    children.append(p)
    time.sleep(.6)
    assert p.poll() is None, 'wait terminated before terminal outcome'
    return p

def finish(p,code):
    out,err=p.communicate(timeout=8)
    emit(out.rstrip()); emit(err.rstrip()); emit('wait exit=%d' % p.returncode)
    assert p.returncode==code
    return json.loads(out)
try:
    emit('Local real CLI, synthetic requests and operator-recorded replies; not an LLM pickup proof.')
    id=submit('Compute 19 plus 23 and report the result.','local-answer-1')
    assert submit('Compute 19 plus 23 and report the result.','local-answer-1') == id
    q=(home/'state/.wake-queue').read_bytes()
    p=wait_async(id)
    body='Result: 42\nQuoted "answer", slash \\ and unicode café\nsecond line'
    run('reply',id,'-',stdin=body)
    result=finish(p,0)
    assert result['schema']=='fm-inbox-wait.v1'
    assert result['outcome']=='answered' and result['acknowledged'] is False
    assert result['reply']['body']==body
    run('drain','--ack',id)
    reread=json.loads(run('wait',id,'--timeout','0','--json'))
    assert reread['outcome']=='answered' and reread['acknowledged'] is True
    assert reread['reply']==result['reply']
    assert body in run('wait',id,'--timeout','0')
    assert q==(home/'state/.wake-queue').read_bytes(), 'wait changed wake queue'
    emit('SCENARIO durable answer before ack, after ack, retry dedup and separate-process reread: PASS')

    id=submit('For information only: the dock is quiet.','local-info-1')
    p=wait_async(id)
    run('drain','--ack',id)
    handled=finish(p,2)
    assert handled['outcome']=='handled' and handled['acknowledged'] is True and handled['reply'] is None
    unknown=json.loads(run('wait','absent-local-id','--timeout','0','--json',code=4))
    assert unknown['outcome']=='unknown' and unknown['reply'] is None
    emit('SCENARIO bare handled and unknown are distinct and never invent an answer: PASS')

    id=submit('Pending synthetic work: no consumer is running.','local-pending-1')
    q=(home/'state/.wake-queue').read_bytes()
    n=(home/'state/inbox'/f'{id}.note').read_bytes()
    start=time.monotonic()
    timed=json.loads(run('wait',id,'--timeout','1','--json',code=3))
    elapsed=time.monotonic()-start
    assert .95 <= elapsed < 5, elapsed
    assert timed['outcome']=='timeout' and timed['reply'] is None
    assert n==(home/'state/inbox'/f'{id}.note').read_bytes()
    for value in ['-1','1.5','bad','86401','999999999999999999999999999999']:
        run('wait',id,'--timeout',value,'--json',code=1)
    for args in [('wait',),('wait','../bad'),('wait',id,'extra'),('wait',id,'--bogus'),('wait',id,'--timeout')]:
        run(*args,code=1)
    run('reply',id,'Unable to finish: synthetic dependency unavailable.')
    after=json.loads(run('wait',id,'--timeout','0','--json'))
    assert after['outcome']=='answered' and after['reply']['body']=='Unable to finish: synthetic dependency unavailable.'
    assert q==(home/'state/.wake-queue').read_bytes()
    # Adversarial durable record corruption; never represent it as successful completion.
    (home/'state/inbox/.replies'/id).write_text('seq=not-a-sequence\n--\ncorrupt\n')
    run('wait',id,'--timeout','0','--json',code=1)
    emit('SCENARIO bounded timeout preserves request, retry retrieves real failure reply, invalid input/corrupt reply fail safely: PASS')
finally:
    for p in children:
        if p.poll() is None:
            p.terminate(); p.communicate(timeout=5)
    shutil.rmtree(home)
    log.close()
print('Live CLI scenarios complete; see wait-cli-transcript.log')
