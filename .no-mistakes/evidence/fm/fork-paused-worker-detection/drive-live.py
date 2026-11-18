#!/usr/bin/env python3
"""Real Firstmate CLI + private tmux + real Claude against synthetic localhost API.
Oracle: model refusal is stopped/decision-required, ordinary or newer turns are not.
All runtime fixtures are isolated beneath cwd/.t; no real credentials are used.
"""
import os, pathlib, subprocess, time, json, re, signal, shutil
root=pathlib.Path.cwd(); lab=root/'.t'; ev=pathlib.Path(__file__).parent
assert not lab.exists(); lab.mkdir(); (lab/'tmp').mkdir()
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')) and k not in ('TMUX','TMUX_PANE','TERM_PROGRAM')}
env.update(FM_HOME=str(lab/'home'), FM_BACKEND='tmux', TMPDIR=str(lab/'tmp'))
home=lab/'home'
for d in ('state','config','data','projects'): (home/d).mkdir(parents=True, exist_ok=True)
sock=str(lab/'s'); server=None; watch=None
log=[]
def run(args, **kw):
    p=subprocess.run(args, env=kw.pop('env',env), text=True, capture_output=True, timeout=kw.pop('timeout',25), **kw)
    if p.returncode: raise RuntimeError(f'{args}: exit {p.returncode}\n{p.stdout}\n{p.stderr}')
    return p.stdout
def tm(*args): return run(['tmux','-S',sock,*args])
def capture(name):
    s=tm('capture-pane','-p','-t','lab:fm-refused','-S','-40'); (ev/(name+'.txt')).write_text(s); return s

def crew(expected, label):
    out=run([str(root/'bin/fm-crew-state.sh'),'refused']); log.append(label+': '+out.strip())
    assert 'state: '+expected+' ·' in out, out
    return out

def launch_watch(label):
    global watch
    f=open(ev/(label+'.log'),'w')
    we=env|dict(FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999', FM_HOME_SUMMARY_INTERVAL='999999', FM_SECONDMATE_LIVENESS_SECS='99999999')
    watch=subprocess.Popen([str(root/'bin/fm-watch.sh')],env=we,stdout=f,stderr=f,start_new_session=True); f.close()
    return watch

def await_stop(label):
    rc=watch.wait(timeout=25); assert rc==0, (label,rc)
    out=(ev/(label+'.log')).read_text(); log.append(label+': '+out.strip())
    assert 'model safeguard stopped worker; decision required' in out, out

def acknowledge():
    p=subprocess.run([str(root/'bin/fm-wake-drain.sh')],env=env,text=True,capture_output=True,timeout=25)
    assert p.returncode==0,p.stderr
    (ev/'wake-drain.txt').write_text(p.stdout+p.stderr)
    match=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', p.stderr+p.stdout)
    assert match,p.stderr
    run([str(root/'bin/fm-wake-drain.sh'),'--ack-through',match[1],'--recovery-generation',match[2]])

def quiet_cycle(label):
    launch_watch(label)
    beat=home/'state/.last-watcher-beat'; before=beat.stat().st_mtime_ns if beat.exists() else 0
    deadline=time.monotonic()+25; changes=0
    while time.monotonic()<deadline:
        assert watch.poll() is None, (label, (ev/(label+'.log')).read_text())
        stamp=beat.stat().st_mtime_ns if beat.exists() else 0
        if stamp!=before: changes+=1; before=stamp
        if changes>=4: break
        time.sleep(.2)
    assert changes>=4, 'watcher did not finish polls'
    os.killpg(watch.pid,signal.SIGTERM); rc=watch.wait(timeout=10)
    assert rc in (0,143,-15),rc
    assert not (ev/(label+'.log')).read_text().strip(),(ev/(label+'.log')).read_text()
    log.append(label+': watcher completed multiple real polls without another notification')
    acknowledge()

def show_frame(text):
    (lab/'frame.txt').write_text(text)
    (lab/'frame.py').write_text('import pathlib,time\nprint(pathlib.Path('+repr(str(lab/'frame.txt'))+').read_text(), flush=True)\ntime.sleep(300)\n')
    tm('respawn-pane','-k','-t','lab:fm-refused', 'python3 '+str(lab/'frame.py'))
    time.sleep(.4)
try:
    server=subprocess.Popen(['python3',str(root/'tests/fixtures/fm-claude-refusal.py'),str(lab/'port'),'cyber'],env=env)
    for _ in range(100):
        if (lab/'port').exists(): break
        time.sleep(.1)
    port=(lab/'port').read_text()
    config=lab/'claude-config'; config.mkdir()
    key='sk-ant-synthetic-loopback-only'
    (config/'.claude.json').write_text(json.dumps({'hasCompletedOnboarding':True,'theme':'dark','customApiKeyResponses':{'approved':[key[-20:]],'rejected':[]},'projects':{str(lab):{'hasTrustDialogAccepted':True,'hasCompletedProjectOnboarding':True}}}))
    ce={'PATH':os.environ['PATH'],'HOME':str(lab/'claude-home'),'TERM':'xterm-256color','CLAUDE_CONFIG_DIR':str(config),'ANTHROPIC_API_KEY':key,'ANTHROPIC_BASE_URL':'http://127.0.0.1:'+port,'DISABLE_AUTOUPDATER':'1','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC':'1','TMPDIR':str(lab/'tmp')}
    run(['tmux','-S',sock,'-f','/dev/null','new-session','-d','-s','lab','-n','fm-refused','-x','40','-y','40','-c',str(lab),"claude 'say hi' --model claude-sonnet-4-6 --setting-sources '' --strict-mcp-config --tools ''"],env=ce)
    env['TMUX']=tm('display-message','-p','-t','lab:fm-refused','#{socket_path},#{pid},#{session_id}').strip().replace('$','')
    (home/'state/refused.meta').write_text('window=lab:fm-refused\nbackend=tmux\nkind=scout\nharness=claude\nworktree='+str(lab)+'\n')
    gen=run([str(root/'bin/fm-busy-event.sh'),'arm',str(home/'state'),'refused']).strip()
    run([str(root/'bin/fm-busy-event.sh'),'apply',str(home/'state'),'refused','busy','--gen',gen,'--source','claude-hook','--event','user-prompt-submit'])
    for _ in range(200):
        pane=tm('capture-pane','-p','-t','lab:fm-refused','-S','-40')
        if 'support.claude.com' in pane: break
        time.sleep(.1)
    pane=capture('real-claude-40-columns'); assert 'API Error:' in pane,pane
    crew('parked','real Claude narrow refusal with retained busy')
    launch_watch('first-stop'); await_stop('first-stop'); acknowledge(); quiet_cycle('same-stop')
    # Real terminal dimension change churns wrapping, but is the same stop episode.
    tm('resize-window','-t','lab','-x','64','-y','40'); time.sleep(1)
    capture('real-claude-resized-64-columns'); quiet_cycle('same-stop-after-resize')
    gen=run([str(root/'bin/fm-busy-event.sh'),'arm',str(home/'state'),'refused']).strip()
    launch_watch('new-generation'); await_stop('new-generation'); acknowledge()
    status=(home/'state/refused.status').read_text(); (ev/'persisted-decisions.txt').write_text(status)
    assert status.count('needs-decision')==1,status
    # Synthetic terminal text tests bounded-capture/fence and historical guards
    # against the real crew-state executable, not mocked backend functions.
    banner="API Error: Claude's safeguards flagged this message. https://support.claude.com/en/articles/15363606"
    show_frame('truncated tool output\n```\n⏺ '+banner)
    capture('truncated-fence'); crew('parked','synthetic terminal: real refusal after unmatched closing fence')
    show_frame('```\n    ⏺ '+banner+'\n```')
    capture('quoted-banner'); crew('working','synthetic terminal: quoted refusal is not a stop')
    show_frame('⏺ '+banner+'\n● Continuing the review now.')
    capture('resumed-turn'); crew('working','synthetic terminal: newer assistant turn cancels old stop')
    show_frame("Sonnet 4.6's safeguards stopped the response above · continuing once with that noted")
    capture('automatic-retry'); crew('working','synthetic terminal: automatic retry is not a terminal stop')
    (ev/'product-live-transcript.txt').write_text('\n'.join(log)+'\n')
    print('\n'.join(log))
finally:
    if watch and watch.poll() is None:
        os.killpg(watch.pid,signal.SIGTERM); watch.wait(timeout=10)
    subprocess.run(['tmux','-S',sock,'kill-server'],env=env,capture_output=True,timeout=10)
    if server: server.terminate(); server.wait(timeout=10)
    shutil.rmtree(lab)
