import hashlib,json,os,pathlib,subprocess,threading,time,shutil
root=pathlib.Path.cwd(); home=root/'.validation-inbox'; home.mkdir()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6KJKFYDRYW2GRP6S8EH13QT')
env=dict(os.environ)
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
    env.pop(key,None)
env['FM_HOME']=str(home)
log=[]
def run(*args,input=None,code=0):
    p=subprocess.run([str(root/'bin/fm-inbox.sh'),*args],input=input,text=True,capture_output=True,env=env)
    log.append({'command':'fm-inbox.sh '+' '.join(args),'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    assert p.returncode==code,(args,p.returncode,p.stderr)
    return json.loads(p.stdout) if p.stdout and ('--json' in args or (args and args[0]=='receipts')) else p.stdout

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
try:
    # Oracle: documented outside-caller contract, with independent arithmetic answer.
    note=run('note','--request-id','synthetic-work-1','--json','Calculate 19 + 23 and report the result')
    note_id=note['id']; assert note['saved'] and note['announced']
    replay=run('note','--request-id','synthetic-work-1','--json','retry of the same request')
    assert replay['id']==note_id and replay['outcome']=='replay'
    queue=home/'state/.wake-queue'; record=home/'state/inbox'/f'{note_id}.note'
    before=(digest(queue),digest(record))
    started=time.monotonic()
    snapshot=run('wait',note_id,'--timeout','1','--json',code=3)
    elapsed=time.monotonic()-started
    assert snapshot['outcome']=='timeout' and snapshot['reply'] is None and not snapshot['acknowledged']
    assert 0.9<=elapsed<4 and before==(digest(queue),digest(record))
    log.append({'observation':'Bounded timeout leaves original note and wake bytes unchanged','elapsed_seconds':elapsed})
    # A separate real product process publishes after the waiter is already blocked.
    errors=[]
    body='Result: 42\nQuoted "value", slash \\ and café'
    def responder():
        try:
            time.sleep(1)
            run('reply','--json',note_id,'-',input=body)
        except BaseException as e:errors.append(repr(e))
    thread=threading.Thread(target=responder); thread.start()
    started=time.monotonic(); answer=run('wait',note_id,'--timeout','20','--json'); elapsed=time.monotonic()-started
    thread.join(); assert not errors,errors
    assert answer['schema']=='fm-inbox-wait.v1' and answer['outcome']=='answered' and answer['reply']['body']==body
    assert not answer['acknowledged'] and 0.8<=elapsed<5
    run('drain','--ack',note_id)
    durable=run('wait',note_id,'--timeout','0','--json')
    assert durable['outcome']=='answered' and durable['acknowledged'] and durable['reply']==answer['reply']
    receipts=run('receipts','--all-pending','--all-handled','--all-replies')
    human=run('wait',note_id); assert body in human
    assert digest(queue)==before[0]
    log.append({'observation':'New caller process reads the exact durable final reply after acknowledgement; waiting never appended a wake','wait_seconds':elapsed})
    # Oracle: documented distinct outcomes/exit statuses, not fabricated success.
    notification=run('note','--json','FYI only; no work or answer needed')['id']
    run('drain','--ack',notification)
    handled=run('wait',notification,'--timeout','0','--json',code=2)
    assert handled['outcome']=='handled' and handled['acknowledged'] and handled['reply'] is None
    unknown=run('wait','nonexistent-note','--json','--timeout','0',code=4)
    assert unknown['outcome']=='unknown' and unknown['reply'] is None
    for timeout in ['-1','1.5','86401','bad','999999999999999999']:
        run('wait',note_id,'--timeout',timeout,code=1)
    for args in [('wait',),('wait','../escape'),('wait','x','y'),('wait','x','--bogus'),('wait','x','--timeout')]:
        run(*args,code=1)
    corrupt_id=run('note','--json','Synthetic damaged durable reply')['id']
    (home/'state/inbox/.replies'/corrupt_id).write_text('seq=not-a-number\n--\nNot a valid answer\n')
    run('wait',corrupt_id,'--timeout','0','--json',code=1)
    print('Live public CLI contract scenarios passed; see cli-contract.json for actual commands, replies, states and errors.')
finally:
    (evidence/'cli-contract.json').write_text(json.dumps(log,indent=2,ensure_ascii=False)+'\n')
    shutil.rmtree(home)
