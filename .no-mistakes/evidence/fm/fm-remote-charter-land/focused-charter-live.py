import os, pathlib, subprocess, tempfile, shutil, json, re, base64, time
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/ayrton/.no-mistakes/evidence/01M62C0MJKYRBZMJ096WY776RA')
W=pathlib.Path(tempfile.mkdtemp(prefix='.charter-live-',dir=ROOT))
ENV={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'GIT_'))}
ENV.update(GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Live Fixture',GIT_AUTHOR_EMAIL='fixture@example.invalid',GIT_COMMITTER_NAME='Live Fixture',GIT_COMMITTER_EMAIL='fixture@example.invalid',TMPDIR=str(W))
log=[]; results=[]; started=time.monotonic()
def run(args,env=None,cwd=None,stdin=None,ok=True):
    p=subprocess.run([str(x) for x in args],input=stdin,text=True,capture_output=True,cwd=cwd or ROOT,env=ENV| (env or {}),timeout=120)
    log.append('$ '+ ' '.join(str(x) for x in args)+'\n'+p.stdout+p.stderr+f'[exit {p.returncode}]\n')
    if ok: assert p.returncode==0,log[-1]
    return p

def section(text,name):
    return text.split('# '+name+'\n',1)[1].split('\n# ',1)[0]
def publish(brief,route,home,state,config,code):
    return run(['bash','-c','. "$1/bin/fm-secondmate-charter-lib.sh"; fm_secondmate_charter_for_route "$2" "$3" ios "$4" "$5" "$6" "$7"','_',ROOT,brief,route,code,state,config,home]).stdout

def exercise(charter,home,status,inbox,label):
    text=charter.read_text()
    command=re.search(r'^   `(echo .*?)`$',text,re.M).group(1)
    command=command.replace('{state}','done').replace('<epoch>',str(int(time.time()))).replace('{one short line}',label)
    status.parent.mkdir(parents=True,exist_ok=True)
    config=home/'config' if 'remote' in label else CURRENT_CONFIG
    config.mkdir(parents=True,exist_ok=True); (config/'fleet-ledger').touch()
    run(['bash','-c',command],cwd=home)
    assert label in status.read_text()
    ledger=status.parent/'fleet-ledger.jsonl'
    assert ledger.exists() and label in ledger.read_text(), 'real ledger did not record '+label
    inbox.mkdir(parents=True,exist_ok=True); (inbox/'handled').mkdir(exist_ok=True)
    (inbox/'NNN.msg').write_text('steer '+label+'\n')
    ack=next(s for s in re.findall(r'`([^`]+)`',next(l for l in text.splitlines() if 'moving it:' in l)) if s.startswith('mv '))
    run(['bash','-c',ack],cwd=home)
    assert (inbox/'handled/NNN.msg').read_text()=='steer '+label+'\n'
    assert not (inbox/'NNN.msg').exists()
    log.append('OBSERVED '+label+'\nstatus='+status.read_text()+'ledger='+ledger.read_text()+'acknowledged='+str(inbox/'handled/NNN.msg')+'\n')
    shutil.copy2(charter,E/(label+'-charter.md'))
    shutil.copy2(ledger,E/(label+'-ledger.jsonl'))
try:
    parent=W/'parent'; run([ROOT/'bin/fm-lab-home.sh','create',parent])
    old=W/'retired remote'; new=W/"replacement mate's home"
    env={'FM_HOME':str(parent),'FM_SECONDMATE_CHARTER':'Own the isolated domain.','FM_SECONDMATE_SCOPE':'Only routed domain work.'}
    run([ROOT/'bin/fm-brief.sh','ios','--secondmate','--no-projects','--parent-route','remote','--remote-home',old],env)
    brief=parent/'data/ios/brief.md'
    text=brief.read_text()
    assert str(old/'state/parent-replies.status') in text and str(parent/'state/ios.status') not in text
    # Adversarial authored instructions deliberately mention both previous and parent paths.
    note=f"Keep '{parent}/config' and '{old}/config' unchanged.\nKeep '{old}/bin/fm-fleet-ledger.sh' unchanged.\n"
    text=text.replace('# Charter\n','# Charter\n'+note).replace('# Routing scope\n','# Routing scope\n'+note)
    brief.write_text(text); retained=brief.read_bytes()
    for label,args in [
      ('remote-without-home',['--secondmate','--no-projects','--parent-route','remote']),
      ('home-with-local-route',['--secondmate','--no-projects','--remote-home',str(new)]),
      ('relative-remote-home',['--secondmate','--no-projects','--parent-route','remote','--remote-home','relative']),
      ('route-on-ship',['project','--mode','direct-PR','--parent-route','remote','--remote-home',str(new)]),
      ('unknown-route',['--secondmate','--no-projects','--parent-route','bogus'])]:
        p=run([ROOT/'bin/fm-brief.sh',label,*args],env,ok=False)
        assert p.returncode!=0 and not (parent/'data'/label/'brief.md').exists()
    results.append('route generation and invalid-route refusal: pass')
    # Materialize a standalone disposable code checkout, never another real checkout or fleet home.
    code=W/'code'; code.mkdir()
    archive=subprocess.run(['git','archive','HEAD'],capture_output=True,check=True).stdout
    subprocess.run(['tar','-xf','-','-C',str(code)],input=archive,check=True)
    run(['git','init','-q',code]); run(['git','-C',code,'add','.']); run(['git','-C',code,'commit','-qm','disposable runtime'])
    routed=publish(brief,'remote',new,parent/'state',parent/'config',code)
    routedfile=W/'routed.md'; routedfile.write_text(routed)
    for name in ['Charter','Routing scope']: assert section(routed,name)==section(text,name)
    manifest='schema=fm-remote-home-provision.v1\nid_b64=aW9z\ncharter_b64='+base64.b64encode(routed.encode()).decode()+'\nparent_host_b64=bGFi\nproject_count=0\n'
    for attempt in ['first','rerun']:
        run([ROOT/'bin/fm-remote-home-provision.sh'],{'FM_HOME':str(new),'FM_ROOT_OVERRIDE':str(code)},stdin=manifest)
        assert (new/'data/charter.md').read_text()==routed
        assert brief.read_bytes()==retained
    CURRENT_CONFIG=parent/'config'
    exercise(new/'data/charter.md',new,new/'state/parent-replies.status',new/'state/parent-route/ios.inbox','remote-republished')
    resolved=run(['bash','-c','. "$1/bin/fm-parent-channel-lib.sh"; fm_parent_channel_destination "$2" "$2/state"','_',ROOT,new]).stdout.strip()
    assert resolved==str(new/'state/parent-replies.status')
    assert not old.exists()
    results.append('retained remote publication, same-route retry, authored preservation, real append/ledger/ack: pass')
    # Real local seeder must rebind the remote retained charter to the parent, not child.
    child=W/'local-child'
    run([ROOT/'bin/fm-home-seed.sh','ios',child,'--no-projects'],{'FM_HOME':str(parent),'FM_ROOT_OVERRIDE':str(code)})
    localtext=(child/'data/charter.md').read_text()
    for name in ['Charter','Routing scope']: assert section(localtext,name)==section(text,name)
    exercise(child/'data/charter.md',child,parent/'state/ios.status',parent/'state/ios.inbox','local-return')
    assert brief.read_bytes()==retained and not old.exists()
    results.append('remote-to-local seeding reaches parent channel and inbox without altering authored sections: pass')
    for label,overrides in [('relative-home',{}),('relative-overrides',{'FM_STATE_OVERRIDE':'state-override','FM_CONFIG_OVERRIDE':'config-override'}),('absolute-spelling',{'FM_STATE_OVERRIDE':str(W/'absolute-state')+'/.','FM_CONFIG_OVERRIDE':str(W/'absolute-config')+'/.'})]:
        p=W/label; run([ROOT/'bin/fm-lab-home.sh','create',p])
        state=pathlib.Path(overrides.get('FM_STATE_OVERRIDE',str(p/'state')))
        config=pathlib.Path(overrides.get('FM_CONFIG_OVERRIDE',str(p/'config')))
        if not state.is_absolute(): state=W/state
        if not config.is_absolute(): config=W/config
        state.mkdir(parents=True,exist_ok=True); config.mkdir(parents=True,exist_ok=True)
        pe={'FM_HOME':label,'FM_ROOT_OVERRIDE':str(code),'FM_SECONDMATE_CHARTER':'Local domain','FM_SECONDMATE_SCOPE':'Local scope'}|overrides
        target=W/(label+'-child')
        run([ROOT/'bin/fm-home-seed.sh','ios',target,'--no-projects'],pe,cwd=W)
        CURRENT_CONFIG=config
        exercise(target/'data/charter.md',target,state/'ios.status',state/'ios.inbox',label)
        if label=='absolute-spelling':
            assert overrides['FM_STATE_OVERRIDE']+'/ios.status' in (target/'data/charter.md').read_text()
        results.append(label+' seeding executes from child against absolute parent paths: pass')
except Exception as exc:
    results.append('FAIL: '+repr(exc))
    raise
finally:
    log.append('\nRESULTS\n'+'\n'.join(results)+f'\nElapsed seconds: {time.monotonic()-started:.2f}\n')
    (E/'focused-charter-live.log').write_text('\n'.join(log))
    (E/'focused-charter-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(W)
    print('\n'.join(results))
    print(f'Elapsed seconds: {time.monotonic()-started:.2f}')
