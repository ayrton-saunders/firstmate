import os, pathlib, subprocess, tempfile, shutil, base64, json
R=pathlib.Path.cwd(); E=pathlib.Path(__file__).parent
W=pathlib.Path(tempfile.mkdtemp(prefix='.charter-live-',dir=R)); results=[]; transcript=[]
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_'): del env[k]
def run(args,home=None,cwd=None,extra=None,input=None,ok=True):
    e=env.copy()
    if home: e['FM_HOME']=str(home)
    if extra: e.update(extra)
    p=subprocess.run([str(x) for x in args],cwd=cwd or R,env=e,input=input,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    transcript.append('$ '+ ' '.join(map(str,args))+'\n'+p.stdout+'exit='+str(p.returncode)+'\n')
    if ok and p.returncode: raise RuntimeError(p.stdout)
    return p

def scaffold(id,home,route=None,destination=None):
    args=[R/'bin/fm-brief.sh',id,'--secondmate','--no-projects']
    if route: args+=['--parent-route',route]
    if destination: args+=['--remote-home',destination]
    run(args,home,extra={'FM_SECONDMATE_CHARTER':"Own domain. Keep '"+str(home)+"/config' unchanged.", 'FM_SECONDMATE_SCOPE':'domain'})
    return home/'data'/id/'brief.md'

def exercise(charter,child,status,inbox,ledger=False):
    text=charter.read_text()
    append=next(l.split('`')[1] for l in text.splitlines() if l.startswith('   `echo '))
    append=append.replace('{state}','done').replace('<epoch>','123').replace('{one short line}','live judgement')
    ack=next(l.split('`')[1] for l in text.splitlines() if 'moving it:' in l)
    status.parent.mkdir(parents=True,exist_ok=True)
    (inbox/'handled').mkdir(parents=True,exist_ok=True)
    (inbox/'NNN.msg').write_text('live steering\n')
    run(['bash','-c',append],child,cwd=child)
    run(['bash','-c',ack],child,cwd=child)
    assert 'done [at=123]: live judgement' in status.read_text()
    assert not (inbox/'NNN.msg').exists() and (inbox/'handled/NNN.msg').read_text()=='live steering\n'
    transcript.append('persisted status: '+str(status)+'\n'+status.read_text()+'acknowledged: '+str(inbox/'handled/NNN.msg')+'\n')
    if ledger:
        assert (status.parent/'fleet-ledger.jsonl').is_file()
        transcript.append('ledger: '+(status.parent/'fleet-ledger.jsonl').read_text()+'\n')

def publish(brief,dest,home,id):
    p=run(['bash','-c','. "$1"; fm_secondmate_charter_for_route "$2" remote "$3" "$4" "$5" "$6" "$7"','_',R/'bin/fm-secondmate-charter-lib.sh',brief,id,R,home/'state',home/'config',dest],home)
    manifest='schema=fm-remote-home-provision.v1\nid_b64='+base64.b64encode(id.encode()).decode()+'\ncharter_b64='+base64.b64encode(p.stdout.encode()).decode()+'\nparent_host_b64='+base64.b64encode(b'disposable-parent').decode()+'\nproject_count=0\n'
    run([R/'bin/fm-remote-home-provision.sh'],dest,input=manifest)
    return dest/'data/charter.md'
try:
    run(['git','clone','--quiet','--no-hardlinks',R,W/'code-root'])
    R=W/'code-root'
    parent=W/'parent'; run([R/'bin/fm-lab-home.sh','create',parent])
    remote=W/"remote home'one"
    brief=scaffold('mate',parent,'remote',remote)
    shutil.copyfile(brief,E/'fresh-remote-charter.md')
    charter=publish(brief,remote,parent,'mate')
    assert "Keep '"+str(parent)+"/config' unchanged." in charter.read_text()
    exercise(charter,remote,remote/'state/parent-replies.status',remote/'state/parent-route/mate.inbox')
    results.append('Fresh remote charter: judgement and steering acknowledgement use host-local paths, including spaces and apostrophes.')
    moved=W/'remote home two'
    charter2=publish(brief,moved,parent,'mate')
    shutil.copyfile(charter2,E/'rebound-remote-charter.md')
    (moved/'config/fleet-ledger').touch()
    exercise(charter2,moved,moved/'state/parent-replies.status',moved/'state/parent-route/mate.inbox',True)
    assert "Keep '"+str(parent)+"/config' unchanged." in charter2.read_text()
    assert remote.as_posix() not in charter2.read_text()
    results.append('Remote relocation: reused persisted brief publishes new host-local routes and ledger, preserving authored config instruction.')
    local=W/'local-child'
    run([R/'bin/fm-home-seed.sh','mate',local,'--no-projects'],parent)
    (parent/'config/fleet-ledger').touch()
    exercise(local/'data/charter.md',local,parent/'state/mate.status',parent/'state/mate.inbox',True)
    shutil.copyfile(local/'data/charter.md',E/'rebound-local-charter.md')
    assert "Keep '"+str(parent)+"/config' unchanged." in (local/'data/charter.md').read_text()
    results.append('Remote-to-local publication: retained remote brief appends and acknowledges on the parent, preserving authored content.')
    relative=W/'relative-parent'; run([R/'bin/fm-lab-home.sh','create',relative])
    child=W/'relative-child'
    run([R/'bin/fm-home-seed.sh','relative',child,'--no-projects'],'relative-parent',cwd=W,extra={'FM_SECONDMATE_CHARTER':'Own relative domain.','FM_SECONDMATE_SCOPE':'relative'})
    (relative/'config/fleet-ledger').touch()
    exercise(child/'data/charter.md',child,relative/'state/relative.status',relative/'state/relative.inbox',True)
    results.append('Relative FM_HOME: published commands run from the child and reach absolute parent state/config paths.')
    for axis in ['state','config','absolute']:
        p=W/('parent-'+axis); run([R/'bin/fm-lab-home.sh','create',p])
        c=W/('child-'+axis)
        state=p/'state'; config=p/'config'
        extra={'FM_SECONDMATE_CHARTER':'Own '+axis+' domain.','FM_SECONDMATE_SCOPE':axis}
        if axis=='state': extra['FM_STATE_OVERRIDE']='parent-state/state'
        if axis=='config': extra['FM_CONFIG_OVERRIDE']='parent-config/config'
        if axis=='absolute':
            extra['FM_STATE_OVERRIDE']=str(p)+'/./state'
            extra['FM_CONFIG_OVERRIDE']=str(p)+'/./config'
        run([R/'bin/fm-home-seed.sh',axis,c,'--no-projects'],p,cwd=W,extra=extra)
        (config/'fleet-ledger').touch()
        exercise(c/'data/charter.md',c,state/(axis+'.status'),state/(axis+'.inbox'),True)
        if axis=='absolute':
            t=(c/'data/charter.md').read_text()
            assert str(p)+'/./state/'+axis+'.status' in t and str(p)+'/./config' in t
        results.append(axis+' publication: append, ledger, and steering acknowledgement work from the child; accepted absolute spelling retained.')
    # Route flags must fail before a brief is created.
    cases=[['bad1','--secondmate','--no-projects','--parent-route','remote'],['bad2','--secondmate','--no-projects','--parent-route','remote','--remote-home','relative'],['bad3','--secondmate','--no-projects','--parent-route','wrong'],['bad4','--secondmate','--no-projects','--remote-home',str(remote)],['bad5','--scout','alpha','--parent-route','remote','--remote-home',str(remote)]]
    for args in cases:
        p=run([R/'bin/fm-brief.sh']+args,parent,ok=False)
        assert p.returncode!=0 and not (parent/'data'/args[0]/'brief.md').exists()
    results.append('Invalid route combinations: rejected without emitting briefs.')
    baseline=R/'bin/.charter-baseline-brief.sh'
    baseline.write_text(subprocess.check_output(['git','show','bff6bf5a1c823d6137b461714a5d40a9335db33a:bin/fm-brief.sh'],text=True))
    run(['bash',baseline,'stable','--secondmate','--no-projects'],parent,extra={'FM_SECONDMATE_CHARTER':'Own stable domain.','FM_SECONDMATE_SCOPE':'stable'})
    old=(parent/'data/stable/brief.md').read_bytes()
    (parent/'data/stable/brief.md').unlink()
    run([R/'bin/fm-brief.sh','stable','--secondmate','--no-projects'],parent,extra={'FM_SECONDMATE_CHARTER':'Own stable domain.','FM_SECONDMATE_SCOPE':'stable'})
    assert old==(parent/'data/stable/brief.md').read_bytes()
    results.append('Default local scaffold: byte-for-byte identical to base-commit output.')
finally:
    (R/'bin/.charter-baseline-brief.sh').unlink(missing_ok=True)
    shutil.rmtree(W)
    (E/'charter-live-transcript.log').write_text('\n'.join(transcript))
    (E/'charter-live-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
