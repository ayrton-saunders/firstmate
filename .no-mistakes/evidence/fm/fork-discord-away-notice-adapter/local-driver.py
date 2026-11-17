import contextlib, importlib.util, json, os, pathlib, shutil, sqlite3, sys, unittest
root=pathlib.Path.cwd()
world=root/'.notice-validation/live-world'
world.mkdir()
sys.argv=['fixture',str(root),str(world),str(root/'.notice-validation/slice1')]
with unittest.mock.patch('unittest.main') if False else contextlib.nullcontext():
    original=unittest.main
    unittest.main=lambda **kw: None
    spec=importlib.util.spec_from_file_location('fixture',root/'tests/fm-away-notice-fixture.py')
    fixture=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    unittest.main=original
# Retain actual CLI responses and product-owned persisted journal records, not only assertions.
old_call=fixture.Fixture.call
old_contract=fixture.Fixture.contract

def call(self,*args):
    result=old_call(self,*args)
    print('CLI',args,'stdout=',result.stdout.strip(),'stderr=',result.stderr.strip(),flush=True)
    return result

def contract(self,*args):
    result=old_contract(self,*args)
    print('AWAY',args,result.stdout.strip(),flush=True)
    return result
fixture.Fixture.call=call
fixture.Fixture.contract=contract

class RealHold(fixture.RealFacade):
    def setUp(self):
        super().setUp()
        shutil.copyfile(root/'bin/fm-captain-hold.sh',self.code/'bin/fm-captain-hold.sh')
        (self.home/'data').mkdir(exist_ok=True)
        (self.home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/archive.md"\ndone_keep = 10\n')
    def hold(self,task='task',lifecycle=None):
        result=__import__('subprocess').run(['bash',str(self.code/'bin/fm-captain-hold.sh'),'hold',task,'--reason','Routine choice pending','--title','Local synthetic decision'],env=self.env,text=True,capture_output=True)
        print('HOLD',task,result.returncode,result.stdout,result.stderr,flush=True)
        result.check_returncode()
        (self.home/f'state/{task}.meta').write_text('project='+str(self.code)+'\n')
    def assert_intake_recovers(self,path,host=False):
        self.hold()
        content=path.read_text()
        binding=self.contract('field','reach_binding').stdout.strip()
        path.write_text('{')
        self.report(host=host)
        self.assertEqual(len(self.rows()),1)
        self.assertEqual(self.rows()[0]['state'],'queued')
        self.assertEqual(json.loads(self.rows()[0]['target']),{'binding':binding})
        self.assertIsNotNone(self.rows()[0]['error'])
        self.assertFalse((self.home/'state/.branch-outcomes-processed').exists())
        self.unavailable()
        path.write_text(content)
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'],'owed')
        self.assertIsNone(self.rows()[0]['error'])
        check=__import__('subprocess').run(['bash',str(self.code/'bin/fm-captain-hold.sh'),'open','task','--identity'],env=self.env,capture_output=True,text=True,check=True)
        print('REAL HOLD REMAINS OPEN',check.stdout,flush=True)
        self.assertIn('1 retained failure(s)',self.call('return').stdout)
    def test_local_rate_queue_and_resolved_decision(self):
        self.hold('one')
        self.report(task='one')
        self.hold('two')
        self.report(task='two')
        self.assertEqual([r['state'] for r in self.rows()],['owed','queued'])
        self.assertEqual(len(self.events()),1)
        self.age()
        self.call('drain')
        self.assertEqual([r['state'] for r in self.rows()],['owed','owed'])
        self.assertEqual(len(self.events()),2)
        answer=self.world/'answer.txt'
        answer.write_text('Use the routine default.')
        result=__import__('subprocess').run(['bash',str(self.code/'bin/fm-captain-hold.sh'),'answer','two','--decision-file',str(answer)],env=self.env,text=True,capture_output=True,check=True)
        print('REAL HOLD ANSWER',result.stdout,flush=True)
        self.call('drain')
        self.assertEqual([r['state'] for r in self.rows()],['owed','withdrawn'])
    def test_local_selection_off_and_quiet(self):
        self.selection.unlink()
        self.contract('archive')
        self.contract('enter','--spend','1')
        self.assertEqual(self.contract('field','reach_channels').stdout.strip(),'none')
        self.hold()
        self.report()
        self.assertFalse((self.home/'state/away-notices.sqlite3').exists())
        self.contract('archive')
        self.selection.write_text(json.dumps({'reach':'discord-private','domain':'personal'}))
        self.env['FM_AFK_MODE']='quiet'
        self.contract('enter','--spend','1')
        self.report()
        self.assertFalse((self.home/'state/away-notices.sqlite3').exists())
        self.contract('readback')
    def tearDown(self):
        print('RESULT',self._testMethodName,flush=True)
        if (self.home/'state/away-notices.sqlite3').exists():
            print('ADAPTER ROWS',json.dumps(self.rows()),flush=True)
        for path in self.world.glob('domains/*/parent/state/journal'):
            with sqlite3.connect(path) as db:
                for table in ('events','obligations','records'):
                    db.row_factory=sqlite3.Row
                    print('PARENT',path.relative_to(world),table,json.dumps([dict(r) for r in db.execute('SELECT * FROM '+table)]),flush=True)
        outcomes=self.home/'state/branch-outcomes.jsonl'
        if outcomes.exists(): print('OUTCOMES',outcomes.read_text(),flush=True)

suite=unittest.defaultTestLoader.loadTestsFromTestCase(RealHold)
result=unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(not result.wasSuccessful())
