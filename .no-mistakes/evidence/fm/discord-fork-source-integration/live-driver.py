import os, sys, json, asyncio, subprocess, tempfile, shutil
from pathlib import Path
ROOT=Path.cwd(); SCR=ROOT/'.no-mistakes/test-scratch'; E=Path('/Users/ayrton/.no-mistakes/evidence/01M5ZFKDJ61NKC25YHP94CHGRM')
sys.path[:0]=[str(SCR/'core'),str(SCR/'core/tests')]
os.environ['FIRSTMATE_SOURCE']=str(ROOT)
from test_flow import Flow
from personal_discord.routing import Routing
from personal_discord.journal import canonical
records=[]; real_run=subprocess.run

def run(cmd, **kw):
    r=real_run(cmd,**kw)
    if any(str(x).endswith(('fm-send.sh','fm-inbox.sh','fm-discord-hook.py')) for x in cmd):
        records.append({'command':[str(x).replace(str(ROOT),'$SOURCE') for x in cmd], 'returncode':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
    return r
subprocess.run=run
real_temp=tempfile.TemporaryDirectory

def lab_temp(*a,**kw):
    kw['dir']=str(SCR)
    t=real_temp(*a,**kw)
    run(['/bin/bash',str(ROOT/'bin/fm-lab-home.sh'),'create',str(Path(t.name)/'home')],check=True,capture_output=True,text=True)
    return t

async def main():
    f=Flow(); tempfile.TemporaryDirectory=lab_temp
    try: f.setUp()
    finally: tempfile.TemporaryDirectory=real_temp
    sock='.no-mistakes/test-scratch/live.sock'; tm=['tmux','-S',sock]
    try:
        run(tm+['new-session','-d','-s','fm-lab-discord','-n','fm-domain','-x','100','-y','30','cat'],check=True)
        for win in ('fm-galagoa','fm-unrelated'):
            run(tm+['new-window','-d','-t','fm-lab-discord','-n',win,'cat'],check=True)
        f.env['PATH']=os.environ['PATH']; f.env['TMUX']=sock+',1,0'
        for k in list(f.env):
            if k.endswith('_OVERRIDE'): del f.env[k]
        # Every command runs from the source so the relative private socket is exact.
        def send(text,token=None,target='domain'):
            env=dict(f.env)
            if token: env['FM_DISCORD_AUTH']=token
            return run(['/bin/bash',str(ROOT/'bin/fm-send.sh'),target,text],env=env,cwd=ROOT,text=True,capture_output=True,timeout=30)
        f.send=send
        meta=f.home/'state/domain.meta'
        meta.write_text(meta.read_text().replace('fixture:fm-domain','fm-lab-discord:fm-domain'))
        for name in ('galagoa','unrelated'):
            (f.home/f'state/{name}.meta').write_text(meta.read_text().replace('fm-domain','fm-'+name).replace('endpoint_task_id=domain','endpoint_task_id='+name))
        cfgpath=f.home/'config/discord-integration.json'; cfg=json.loads(cfgpath.read_text())
        cfg['projects']['galagoa']=str(f.home/'projects/galagoa')
        cfg['routes'].insert(0,{'target':'galagoa','project':'galagoa'})
        cfgpath.write_text(canonical(cfg))
        # Integration intake uses no external traffic: FakeDiscord/FakeSSH are fixtures only.
        f.integration.environment=dict(f.env)
        ident=await f.capture(); text='Read-only synthetic request for isolated CLI verification.'
        corr=f.real_correlation(text)
        f.parent.prepare_dispatch(ident,binding=f.binding(ident,correlation=corr))
        token=Routing(f.pj).issue(project='pristine-valets',target='domain',operation='new',text=text,request=ident,generation='generation-1',endpoint_generation='endpoint-v1')
        r=send(text,token); assert r.returncode==0,r.stderr
        assert text in (f.home/'state/domain.inbox/001.msg').read_text()
        assert f.pj.state('route-permit',token)[1]['phase']=='confirmed'
        assert send(text,token).returncode!=0
        assert send('untyped mapped request').returncode!=0
        def issue(payload,generation='endpoint-v1'):
            return Routing(f.pj).issue(project='pristine-valets',target='domain',operation='instruction',text=payload,request=ident,generation='generation-1',endpoint_generation=generation,authority='private-existing')
        assert send('wrong endpoint generation',issue('wrong endpoint generation','endpoint-v0')).returncode!=0
        # All terminal aliases of the mapped window must be refused, even with a valid permit.
        wid=run(tm+['display-message','-p','-t','fm-lab-discord:fm-domain','#{window_id}'],capture_output=True,text=True,check=True).stdout.strip()
        idx=run(tm+['display-message','-p','-t','fm-lab-discord:fm-domain','#{window_index}'],capture_output=True,text=True,check=True).stdout.strip()
        aliases=['fm-lab-discord:fm-domain','fm-lab-discord:'+idx,'fm-lab-discord:'+wid,'fm-lab-discord:'+idx+'.0','=fm-lab-discord:=fm-domain']
        count=lambda:len(list((f.home/'state/domain.inbox').glob('*.msg')))
        before=count()
        for alias in aliases:
            r=send('alias bypass must not arrive',issue('alias bypass must not arrive'),alias)
            assert r.returncode!=0,(alias,r.stdout,r.stderr)
            assert count()==before
        # Disappeared unrelated mapped worker cannot poison later mapped or unmapped routes.
        run(tm+['kill-window','-t','fm-lab-discord:fm-galagoa'],check=True)
        r=send('Mapped instruction after unrelated disappearance',issue('Mapped instruction after unrelated disappearance'))
        assert r.returncode==0,r.stderr
        r=send('Ordinary unmapped instruction survives stale metadata',target='unrelated'); assert r.returncode==0,r.stderr
        # Dead session and dead window inventory are both conclusive absence.
        stale=f.home/'state/galagoa.meta'; stale.write_text(stale.read_text().replace('fm-lab-discord:fm-galagoa','fm-lab-missing:fm-galagoa'))
        r=send('Unmapped instruction survives absent session',target='unrelated'); assert r.returncode==0,r.stderr
        # A malformed recorded identity is indeterminate, not permission to bypass.
        stale.write_text(stale.read_text().replace('fm-lab-missing:fm-galagoa','bad:ambiguous:endpoint'))
        r=send('uncertain identity cannot bypass',target='fm-lab-discord:'+idx); assert r.returncode!=0
        assert count()==before+1
        stale.unlink()
        # Actual inbox readiness/outcome owners, with the real private journal.
        r=run(['/bin/bash',str(ROOT/'bin/fm-inbox.sh'),'drain'],env=f.env,cwd=ROOT,capture_output=True,text=True,timeout=20)
        assert r.returncode==0 and not r.stderr,r.stderr
        note=f.pj.state('request',ident)[1]['note_id']
        r=run(['/bin/bash',str(ROOT/'bin/fm-inbox.sh'),'reply','--json',note,'Synthetic terminal reply.'],env=f.env,cwd=ROOT,capture_output=True,text=True,timeout=20)
        assert r.returncode==0 and not r.stderr,r.stderr
        assert f.pj.record('pending-final',ident)['note_id']==note
        # Absent/disabled compatibility and invalid-config no-delivery guarantees.
        for mode in ('absent','disabled'):
            if mode=='absent': cfgpath.unlink()
            else: cfgpath.write_text('{"enabled":false}')
            r=send('Legacy delivery '+mode); assert r.returncode==0,r.stderr
        for invalid in ('{"enabled":true,"enabled":false}','{"enabled":"false"}','{"enabled":true,"schema":1}'):
            cfgpath.write_text(invalid); before_bad=count(); r=send('payload never echoed'); assert r.returncode!=0
            assert 'payload never echoed' not in r.stderr and count()==before_bad
        cfgpath.unlink(); linked=f.root/'linked.json'; linked.write_text('{"enabled":false}'); cfgpath.symlink_to(linked)
        r=send('symlink cannot bypass'); assert r.returncode!=0
        receipts={'steering_records':[p.read_text() for p in sorted((f.home/'state/domain.inbox').glob('*.msg'))],
                  'permit_state':f.pj.state('route-permit',token)[1], 'pending_final':f.pj.record('pending-final',ident), 'readiness':f.parent.readiness(),
                  'aliases_refused':aliases, 'media_calls':f.discord.media_calls,'model_calls':f.discord.model_calls}
        (E/'live-receipts.json').write_text(json.dumps(receipts,indent=2))
        print('Real CLI checks completed: permits, alias refusals, disappearance isolation, uncertain identity refusal, readiness/outcomes, inactive compatibility and malformed-config refusal.')
    finally:
        run(tm+['kill-server'],capture_output=True)
        f.tearDown()
        (E/'live-cli.json').write_text(json.dumps(records,indent=2))
asyncio.run(main())
