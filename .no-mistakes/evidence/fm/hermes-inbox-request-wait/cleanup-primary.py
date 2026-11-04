import os,pathlib,signal,subprocess,time,json
lab=pathlib.Path.cwd()/'.validation-primary'
socketdir=(lab/'state/.fm-lab-tmux-dir').read_text().strip()
env=dict(os.environ,TMUX_TMPDIR=socketdir)
server,pane=map(int,subprocess.check_output(['tmux','-L','fm-lab','display-message','-p','#{pid} #{pane_pid}'],env=env,text=True).split())
roots={server,pane}
watch=lab/'state/.watch.lock/pid'
if watch.exists():roots.add(int(watch.read_text().strip()))
def snapshot():
    rows={}
    for line in subprocess.check_output(['ps','-axo','pid=,ppid=,stat=,lstart='],text=True).splitlines():
        f=line.split(None,3)
        if len(f)==4:rows[int(f[0])]=(int(f[1]),f[2],f[3])
    return rows
rows=snapshot(); owned=set(roots)
while True:
    expanded=owned|{pid for pid,(parent,_,_) in rows.items() if parent in owned}
    if expanded==owned:break
    owned=expanded
identities={pid:rows[pid][2] for pid in owned if pid in rows}
subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,check=True)
def live():
    rows=snapshot()
    return [pid for pid,start in identities.items() if pid in rows and rows[pid][2]==start and not rows[pid][1].startswith('Z')]
time.sleep(1)
for sig in [signal.SIGTERM,signal.SIGKILL]:
    for pid in live():
        try:os.kill(pid,sig)
        except ProcessLookupError:pass
    for _ in range(30):
        if not live():break
        time.sleep(.1)
survivors=live()
print(json.dumps({'recorded_owned_processes':sorted(identities),'survivors':survivors,'private_tmux_stopped':True}))
assert not survivors
subprocess.run(['bin/fm-lab-home.sh','teardown',str(lab)],check=True)
