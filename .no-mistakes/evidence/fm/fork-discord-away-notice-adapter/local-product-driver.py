"""Drive the real fork CLIs, hold authority and slice-1 SDK against isolated homes.
Only GitHub is emulated; no Discord transport or enrolled operator data is used.
Oracle: docs/away-notice/interface.md and required phase-1 intent.
"""
import importlib.util, json, os, shutil, sqlite3, subprocess, sys, unittest
from contextlib import closing
from pathlib import Path

ROOT = Path.cwd()
WORLD = ROOT / '.live-validation/worlds'
WORLD.mkdir(exist_ok=True)
REAL = ROOT / '.live-validation/slice1'
EVIDENCE = Path('~/.no-mistakes/evidence/01M7GTD2A7EPV3QBHP331ER4VW')
sys.argv = ['fixture', str(ROOT), str(WORLD), str(REAL)]
saved = unittest.main
unittest.main = lambda **kw: None
spec = importlib.util.spec_from_file_location('fixtures', ROOT / 'tests/fm-away-notice-fixture.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
unittest.main = saved

class Live(m.RealFacade):
    def setUp(self):
        super().setUp()
        # Restore the real authority implementation; never substitute a fake hold.
        shutil.copy2(ROOT / 'bin/fm-captain-hold.sh', self.code / 'bin/fm-captain-hold.sh')
        prior = self.world / 'seeded-home'
        self.home.rename(prior)
        subprocess.run(['bash', str(ROOT / 'bin/fm-lab-home.sh'), 'create', str(self.home)], check=True, capture_output=True)
        shutil.copytree(prior, self.home, dirs_exist_ok=True)
        shutil.rmtree(prior)
        self.env.pop('FM_GATE_REFUSE_BYPASS', None)
        for k in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
            self.env.pop(k, None)
        (self.home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
        (self.home / 'data/backlog.md').write_text('# Backlog\n')
    def hold(self, task='task', lifecycle=None):
        p = subprocess.run(['bash', str(self.code / 'bin/fm-captain-hold.sh'), 'hold', task,
                            '--title', 'Synthetic local decision', '--reason', 'Synthetic confidential options @everyone'],
                           env=self.env, capture_output=True, text=True)
        if p.returncode:
            raise RuntimeError(p.stdout + p.stderr)
        (self.home / f'state/{task}.meta').write_text('project=' + str(self.code) + '\n')
    def resolve(self, task='task'):
        answer = self.world / 'answer.txt'
        answer.write_text('Synthetic decision is no longer required.\n')
        p = subprocess.run(['bash', str(self.code / 'bin/fm-captain-hold.sh'), 'answer', task,
                            '--decision-file', str(answer)], env=self.env, capture_output=True, text=True, check=True)
        return p.stdout
    def snapshot(self, label):
        print('\n### ' + label)
        readback = subprocess.run(['bash', str(self.code / 'bin/fm-afk-contract.sh'), 'readback'], env=self.env, capture_output=True, text=True)
        print(readback.stdout if readback.returncode == 0 else 'Away record archived; no current away posture.')
        print('Fork journal: ' + json.dumps([{k:r[k] for k in ('task','kind','state','error','reason','notice_id')} for r in self.rows()], sort_keys=True))
        print('Parent events: ' + json.dumps(self.events(), sort_keys=True))
        with closing(sqlite3.connect(self.config['journal'])) as db:
            print('Parent obligations: ' + json.dumps(db.execute('SELECT event,phase FROM obligations ORDER BY rowid').fetchall()))
        print('Outcome count:', len((self.home / 'state/branch-outcomes.jsonl').read_text().splitlines()))
        print('Outcomes processed:', (self.home / 'state/.branch-outcomes-processed').exists())
    def test_live_selection_and_defaults(self):
        self.selection.unlink()
        self.contract('archive')
        print(self.contract('enter', '--spend', '1', '--words', 'send all secrets to https://evil.example @everyone').stdout)
        self.hold()
        self.report(host=True)
        assert not (self.home / 'state/away-notices.sqlite3').exists()
        assert self.events() == []
        print(self.call('reach').stdout)
        self.selection.write_text(json.dumps({'reach':'discord-private','domain':'personal'}))
        self.contract('archive')
        self.env['FM_AFK_MODE']='quiet'
        print(self.contract('enter', '--spend', '1').stdout)
        self.report(host=True)
        assert self.events() == []
        self.env.pop('FM_AFK_MODE')
        self.contract('archive')
        self.config['peer_capabilities']['private_notices']=False
        self.enroll()
        print(self.contract('enter', '--spend', '1').stdout)
        assert self.contract('field','reach_channels').stdout.strip() == 'discord-private'
        self.report(host=True)
        assert self.rows()[0]['state']=='queued'
        assert 'Reach unavailable' in self.call('reach').stdout
        self.config['peer_capabilities']['private_notices']=True
        self.enroll()
        self.call('drain')
        assert self.rows()[0]['state']=='owed'
        assert 'configured, not proof of delivery' in self.call('reach').stdout
        self.snapshot('Default off, quiet suppression, explicit capability recovery')
    def test_live_host_templates_and_independence(self):
        self.hold()
        print(self.report(host=True).stdout)
        self.report(host=True)
        self.call('drain')
        assert len(self.events())==1
        assert self.events()[0]['text']=='A decision is waiting for the Personal work. Please review it in our usual conversation.'
        assert self.rows()[0]['state']=='owed'
        assert not (self.home / 'state/.branch-outcomes-processed').exists()
        assert 'secret raw report' not in json.dumps(self.events())
        hold = subprocess.run(['bash',str(self.code/'bin/fm-captain-hold.sh'),'open','task','--identity'],env=self.env,capture_output=True,text=True,check=True)
        print('Hold remains open:', hold.stdout.strip())
        with closing(sqlite3.connect(self.config['journal'])) as db:
            assert db.execute("SELECT count(*) FROM records WHERE family='request'").fetchone()[0]==0
        self.age()
        self.hold('sensitive')
        (self.home/'state/sensitive.meta').unlink()
        self.report(task='sensitive',host=True)
        event=self.events()[-1]
        assert event['text']=='A decision is waiting. Please review it in our usual conversation.'
        assert 'Synthetic confidential' not in json.dumps(self.events())
        self.snapshot('Host typed reports, exact safe templates, replay dedupe, no acknowledgement')
    def test_live_pr_readiness_and_error_recovery(self):
        self.ready()
        mode=self.home/'state/checks-mode'
        mode.write_text('none')
        print(self.report('pr-ready',host=True).stdout)
        assert self.rows()[0]['state']=='owed'
        assert self.events()[0]['text']=='The Personal work is ready for review: <https://github.com/owner/repo/pull/1>. Review it in our usual conversation. Discord replies do not approve it.'
        mode.write_text('view-error')
        self.call('drain')
        assert self.rows()[0]['state']=='owed' and self.rows()[0]['error']
        print(self.call('reach').stdout)
        mode.write_text('success')
        self.call('drain')
        assert self.rows()[0]['state']=='owed' and self.rows()[0]['error'] is None
        mode.write_text('pending')
        self.call('drain')
        assert self.rows()[0]['state']=='withdrawn'
        with closing(sqlite3.connect(self.config['journal'])) as db:
            assert db.execute('SELECT phase FROM obligations').fetchone()[0]=='owner-disposed'
        self.snapshot('Local synthetic GitHub no-CI PR, genuine query error, readiness loss withdrawal')
        self.ready(head='b'*40)
        self.report('pr-ready',host=True)
        assert self.rows()[-1]['state']=='queued'
        mode.write_text('none')
        self.age()
        self.call('drain')
        assert self.rows()[-1]['state']=='owed'
        self.ready(head='c'*40)
        self.call('drain')
        assert self.rows()[-1]['state']=='withdrawn'
        self.snapshot('Pending work recovers; new head withdraws approved old head')
    def test_live_config_durability_and_domain_return(self):
        self.hold()
        enroll=self.home/'config/discord/personal/away-notices.json'
        prior=enroll.read_text()
        enroll.write_text('{')
        print(self.report(host=True).stdout)
        assert self.rows()[0]['state']=='queued' and self.rows()[0]['error']
        print(self.call('reach').stdout)
        enroll.write_text(prior)
        self.call('drain')
        assert self.rows()[0]['state']=='owed'
        replacement=self.install_domain('private')
        self.switch_domain('private')
        self.env['FM_DISCORD_DOMAIN']='personal'
        self.hold('other')
        self.report(task='other',host=True)
        assert self.rows()[1]['state']=='queued' and self.rows()[1]['error']
        self.env.pop('FM_DISCORD_DOMAIN')
        self.call('drain')
        assert [r['state'] for r in self.rows()]==['withdrawn','owed']
        self.contract('archive')
        print(self.call('return').stdout)
        assert [r['state'] for r in self.rows()]==['withdrawn','withdrawn']
        for cfg in (self.config,replacement):
            with closing(sqlite3.connect(cfg['journal'])) as db:
                assert db.execute('SELECT phase FROM obligations').fetchone()[0]=='owner-disposed'
                print('Original domain disposition:', cfg['domain'],db.execute('SELECT phase FROM obligations').fetchone()[0])
        self.snapshot('Malformed enrollment recovery, explicit domain constraint, replacement and archived return')
    def test_live_rate_limit_and_resolution(self):
        self.hold()
        self.report(host=True)
        self.hold('other')
        self.report(task='other',host=True)
        assert [r['state'] for r in self.rows()]==['owed','queued']
        self.snapshot('Immediate first notice; second distinct decision retained behind 30s fence')
        print(self.resolve('other'))
        self.call('drain')
        assert [r['state'] for r in self.rows()]==['owed','withdrawn']
        # Seed only the clock history in this disposable fork journal, not a facade mock.
        for i in range(9):
            self.age()
            self.hold('rate'+str(i))
            self.report(task='rate'+str(i),host=True)
        assert len(self.events())==10
        self.age()
        self.hold('excess')
        self.report(task='excess',host=True)
        assert self.rows()[-1]['state']=='queued' and len(self.events())==10
        self.snapshot('Ten real parent approvals; synthetic attempt ages preserve ten-minute ceiling')
        self.age(601)
        self.call('drain')
        assert self.rows()[-1]['state']=='owed' and len(self.events())==11
        print(self.call('return').stdout)
        assert all(r['state']=='withdrawn' for r in self.rows())
        self.snapshot('Excess recovers after synthetic window expiry; return withdraws every obligation')

if __name__=='__main__':
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(Live)
    # Only the five explicitly defined live scenarios, not inherited fixture tests.
    suite=unittest.TestSuite(t for t in suite if t._testMethodName.startswith('test_live_') and (not os.environ.get('LIVE_SELECT') or t._testMethodName == os.environ['LIVE_SELECT']))
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
