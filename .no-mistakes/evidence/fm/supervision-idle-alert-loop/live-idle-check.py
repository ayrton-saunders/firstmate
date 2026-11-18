import os, subprocess as s, pathlib as p, tempfile, time, shutil, json, re
log=[]; results=[]
def note(msg):
 print(msg,flush=True); log.append(msg)
def expect(cond,msg):
 if not cond: raise AssertionError(msg)
 note('VERIFIED: '+msg)
ROOT=p.Path.cwd(); E=p.Path('~/.no-mistakes/evidence/01M7Q3PE8FPNF5WEDSVFKVQK3V')
lab=p.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=ROOT)); sockdir=None; children=[]
env=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_CREW_STATE_BIN','FM_TEST_SEAM','TMUX','TMUX_PANE']: env.pop(k,None)
env['FM_HOME']=str(lab)
env['PI_CODING_AGENT_DIR']=str(lab/'pi-config')
env['PI_TELEMETRY']='0'
def run(args,check=True,**kw):
 r=s.run(args,env=env,text=True,stdout=s.PIPE,stderr=s.STDOUT,**kw)
 if check and r.returncode: raise RuntimeError(f'{args}: rc={r.returncode} {r.stdout}')
 return r.stdout
def fm(name,*args,**kw): return run([str(ROOT/'bin'/('fm-'+name+'.sh')),*args],**kw)
def tm(*args,**kw): return run(['tmux','-S',socket,*args],**kw)
try:
 fm('lab-home','create',str(lab)); sockdir=fm('lab-home','tmux-dir',str(lab)).strip(); socket=f'{sockdir}/tmux-{os.getuid()}/fm-lab'
 env['TMUX_TMPDIR']=sockdir
 run(['tmux','-L','fm-lab','new-session','-d' ,'-s','primary','-n','fm-finished','-x','120','-y','36','-c',str(ROOT),'-e',f'FM_HOME={lab}','-e',f'PI_CODING_AGENT_DIR={lab}/pi-config','pi --no-session --no-extensions --no-mcp --no-skills --no-prompt-templates --no-themes --no-context-files --no-approve --offline'])
 env['TMUX']=tm('display-message','-p','-t','primary','#{socket_path},#{pid},0').strip()
 time.sleep(8)
 capture=tm('capture-pane','-p','-t','primary')
 (E/'initial-terminal.txt').write_text(capture)
 note('Real private tmux terminal: '+run(['bash','-c','. bin/fm-backend.sh; fm_backend_agent_state tmux primary:fm-finished']).strip())
 state=lab/'state'; task='finished'; win='primary:fm-finished'
 (lab/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
 (lab/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
 fm('tasks-axi','add',task,'Prepare a local synthetic release'); fm('tasks-axi','start',task)
 (state/'finished.meta').write_text(f'window={win}\nkind=ship\nharness=pi\nbackend=tmux\n')
 (state/'finished.status').write_text('working: preparing synthetic release\n')
 env.update(FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_STALE_ESCALATE_SECS='1',FM_PAUSE_RESURFACE_SECS='2',FM_SECONDMATE_LIVENESS_SECS='99999999')
 def ack():
  text=fm('wake-drain'); log.append('DRAIN:\n'+text)
  m=re.search(r'--ack-through (\d+) --recovery-generation ([\w.-]+)',text)
  if m: fm('wake-drain','--ack-through',m[1],'--recovery-generation',m[2])
 def watch(label,quiet=False):
  out=E/(label+'.watch.txt'); err=E/(label+'.watch.err')
  with out.open('w') as o,err.open('w') as e:
   proc=s.Popen([str(ROOT/'bin/fm-watch.sh')],env=env,stdout=o,stderr=e); children.append(proc)
   deadline=time.time()+45; beats=set()
   while time.time()<deadline and proc.poll() is None:
    b=state/'.last-watcher-beat'
    if b.exists(): beats.add(b.stat().st_mtime_ns)
    if quiet and len(beats)>=4: break
    time.sleep(.15)
   alive=proc.poll() is None
   if alive: proc.terminate()
   rc=proc.wait(timeout=15)
  text=out.read_text(); note(label+f': rc={rc}, poll-beacons={len(beats)}, output='+repr(text))
  if quiet: expect(alive and len(beats)>=4 and not text.strip(),label+' remains quiet over three completed real polling cycles')
  else: expect(not alive and bool(text.strip()),label+' surfaces an actionable notification')
  ack(); return text
 first=watch('initial-status')
 first=watch('first-idle')
 expect('stale: '+win in first,'idle worker is escalated before any handoff')
 decision='Approve publishing the prepared release?'
 fm('captain-hold','hold',task,'--reason',decision,'--open-ended','--idle-handoff')
 expect(fm('captain-hold','open',task,'--idle-state').strip()=='handed-off','real backlog and worker observation produce a matching handoff')
 watch('unchanged-handoff',True)
 tm('send-keys','-t','primary','-l','display-only draft, not submitted')
 time.sleep(1)
 watch('display-churn-handoff',True)
 results.append('attended: first idle notification then unchanged/display-only silence')
 for declaration in ['paused','captain-held']:
  with (state/'finished.status').open('a') as f:f.write(declaration+': awaiting release approval\n')
  watch(declaration+'-status')
  fm('captain-hold','hold',task,'--reason',decision,'--open-ended','--idle-handoff')
  watch(declaration+'-handoff',True)
 results.append('attended: paused and captain-held declarations cannot bypass a matching idle handoff')
 with (state/'finished.status').open('a') as f:f.write('blocked [key=artifact-expired]: the synthetic release artifact expired\nworking: checking for a replacement artifact\n')
 text=watch('new-blocker')
 expect('signal:' in text,'new blocker is delivered while the original captain decision is still open')
 expect(fm('captain-hold','open',task,'--idle-state').strip()=='held','changed status invalidates the idle receipt but preserves the decision')
 fm('captain-hold','hold',task,'--reason',decision,'--open-ended','--idle-handoff')
 (lab/'answer.txt').write_text('Proceed after replacing the expired artifact.\n')
 fm('captain-hold','answer',task,'--decision-file',str(lab/'answer.txt'),'--release')
 text=watch('answered-monitoring')
 expect('stale:' in text,'answering and releasing restores idle monitoring on the same terminal')
 results.append('new blocker invalidates handoff; answering restores ordinary idle monitoring')
 # Real hold conflicts must preserve the existing backlog, never replace a different call or date.
 fm('captain-hold','hold',task,'--reason',decision,'--until','2099-01-01')
 before=fm('tasks-axi','show',task,'--full')
 refused=run([str(ROOT/'bin/fm-captain-hold.sh'),'hold',task,'--reason',decision,'--open-ended','--idle-handoff'],check=False)
 note('dated-conflict refusal: '+refused)
 expect(before==fm('tasks-axi','show',task,'--full') and 'cannot replace' in refused,'idle handoff refuses to replace a dated deferral without changing the decision')
 fm('captain-hold','hold',task,'--reason',decision,'--open-ended')
 before=fm('tasks-axi','show',task,'--full')
 refused=run([str(ROOT/'bin/fm-captain-hold.sh'),'hold',task,'--reason','Use a different release channel?','--open-ended','--idle-handoff'],check=False)
 note('different-decision refusal: '+refused)
 expect(before==fm('tasks-axi','show',task,'--full') and 'cannot replace' in refused,'idle handoff refuses a different pending decision without changing it')
 results.append('conflicting decision and dated deferral are preserved')
 fm('captain-hold','hold',task,'--reason',decision,'--open-ended','--idle-handoff')
 gen=fm('busy-event','arm',str(state),task).strip()
 fm('busy-event','apply',str(state),task,'busy','--gen',gen,'--source','pi-ext','--event','agent-start')
 env['FM_BUSY_TURN_MAX_SECS']='1'
 expect(fm('captain-hold','open',task,'--idle-state').strip()=='handed-off','synthetic busy state does not itself invalidate the receipt; the busy guard must act')
 time.sleep(3)
 text=watch('synthetic-busy-bound')
 expect('stale:' in text,'a synthetic busy generation exceeding its bound is not silenced by an otherwise matching handoff')
 fm('busy-event','apply',str(state),task,'idle','--gen',gen,'--source','pi-ext','--event','agent-end')
 results.append('local synthetic busy generation is still bounded after an idle handoff')
 # Drive the real long-running away daemon, retaining its actual escalation buffer.
 # No submission is allowed into the model: the batch window is deliberately long.
 (lab/'answer2.txt').write_text('Resume checking the release.\n')
 fm('captain-hold','answer',task,'--decision-file',str(lab/'answer2.txt'),'--release')
 with (state/'finished.status').open('a') as f:f.write('working: checking the local release\n')
 fm('afk-contract','enter','--words','Hold decisions for return')
 tm('send-keys','-t','primary','C-u'); tm('send-keys','-t','primary','-l','away-mode initial observation')
 env.update(FM_SUPERVISOR_BACKEND='tmux',FM_SUPERVISOR_TARGET=win,FM_DAEMON_PRIMARY_HARNESS='pi',FM_ESCALATE_BATCH_SECS='999999',FM_MAX_DEFER_SECS='0',FM_WEDGE_ALARM_EXEC='discard',FM_HOUSEKEEPING_TICK='1')
 dout=(E/'away-daemon.log').open('w')
 daemon=s.Popen([str(ROOT/'bin/fm-supervise-daemon.sh')],env=env,stdout=dout,stderr=s.STDOUT); children.append(daemon)
 buf=state/'.subsuper-escalations'
 def buffer(): return buf.read_text() if buf.exists() else ''
 def until(pred,timeout=50):
  end=time.time()+timeout
  while time.time()<end:
   if pred():return True
   if daemon.poll() is not None:raise AssertionError('away daemon exited early')
   time.sleep(.3)
  return False
 expect(until(lambda:'possible wedge' in buffer()),'real away daemon buffers the initial persistent idle escalation')
 initial=buffer(); note('AWAY INITIAL BUFFER:\n'+initial)
 fm('captain-hold','hold',task,'--reason',decision,'--open-ended','--idle-handoff')
 tm('send-keys','-t','primary','C-u'); tm('send-keys','-t','primary','-l','another unsubmitted footer-only change')
 time.sleep(9)
 expect(buffer()==initial,'real away daemon does not repeat the handed-off idle escalation despite terminal churn')
 with (state/'finished.status').open('a') as f:f.write('paused: pipeline awaits release approval\n')
 fm('captain-hold','hold',task,'--reason',decision,'--open-ended','--idle-handoff')
 time.sleep(9)
 expect(buffer()==initial,'real away daemon paused routing cannot bypass the matching handoff')
 with (state/'finished.status').open('a') as f:f.write('blocked [key=new-artifact]: a new synthetic artifact is required\n')
 expect(until(lambda:'a new synthetic artifact is required' in buffer()),'real away daemon delivers a new blocker despite the outstanding captain decision')
 note('AWAY FINAL BUFFER:\n'+buffer())
 # Presence-gated shutdown must not submit anything into the isolated unauthenticated Pi terminal.
 (state/'.afk').unlink(missing_ok=True)
 daemon.terminate(); daemon_rc=daemon.wait(timeout=20); dout.close()
 expect(daemon_rc==0,'away daemon exits cleanly and reaps its watcher child')
 results.append('real away daemon escalates once, stays quiet across churn and paused declarations, and surfaces a new blocker')
 (E/'live-results.json').write_text(json.dumps(results,indent=2))
finally:
 (lab/'state/.afk').unlink(missing_ok=True)
 for proc in children:
  if proc.poll() is None: proc.terminate()
  proc.wait(timeout=15)
 if sockdir:
  tm('kill-server',check=False); fm('lab-home','teardown',str(lab),check=False)
 if (lab/'state/.supervise-daemon.log').exists(): shutil.copyfile(lab/'state/.supervise-daemon.log',E/'away-daemon-routing.log')
 shutil.rmtree(lab)
 (E/'live-transcript.log').write_text('\n\n'.join(log)+'\nLab server stopped; disposable home removed.\n')
