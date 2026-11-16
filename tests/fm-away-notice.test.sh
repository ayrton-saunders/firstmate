#!/usr/bin/env bash
# Typed notice CLI through a pinned fake parent release, real away records and reports.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-away-notice)
PY314=$(command -v python3.14 || true)
if [ -z "$PY314" ]; then
  printf 'SKIP: private notice fixture requires CPython 3.14\n'
  exit 0
fi
"$PY314" -I - "$ROOT" "$TMP_ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import time
import unittest

source, tmp = map(Path, sys.argv[1:])

API = '''import json, os
from pathlib import Path
CAPABILITY='private-notice-v1'
def available(*, config):
    return not Path(config['journal']+'.unsupported').exists()
def approve(*, config, notice):
    assert set(notice)=={'notice_id','identity','origin','template','project_alias','pr_url'}
    path=Path(config['journal']+'.calls')
    with path.open('a') as f:
        f.write(json.dumps({'notice':notice,'actor':os.environ.get('FM_SUPERVISION_ACTOR')})+'\\n')
    if Path(config['journal']+'.fail').exists():
        raise ValueError('private error must never appear')
    state='owed' if Path(config['journal']+'.owed').exists() else 'delivered'
    Path(config['journal']+'.'+notice['notice_id']).write_text(state)
    return {'notice_id':notice['notice_id'],'state':state}
def withdraw(*, config, notice):
    if Path(config['journal']+'.withdraw-fail').exists():
        raise ValueError('withdraw refused')
    path=Path(config['journal']+'.withdrawals')
    with path.open('a') as f:
        f.write(json.dumps({'notice':notice,'actor':os.environ.get('FM_SUPERVISION_ACTOR')})+'\\n')
    custody=Path(config['journal']+'.'+notice['notice_id'])
    state='delivered' if custody.exists() and custody.read_text()=='delivered' else 'stopped'
    custody.write_text(state)
    return {'notice_id':notice['notice_id'],'state':state}
'''

def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))

class Notices(unittest.TestCase):
    def setUp(self):
        self.world = tmp / self._testMethodName
        self.world.mkdir()
        self.home = self.world/'home'
        (self.home/'config/discord/personal').mkdir(parents=True)
        (self.home/'state').mkdir()
        self.code = self.world/'source'
        shutil.copytree(source/'bin', self.code/'bin')
        self.cli = self.code/'bin/fm-away-notice.py'
        # The real hold owner has its own regression suite. This boundary fixture
        # provides mutable authoritative hold identities, not arbitrary notice text.
        (self.code/'bin/fm-captain-hold.sh').write_text('''#!/bin/bash
file="$FM_HOME/state/$2.hold"
[ -f "$file" ] || exit 1
head -n 1 "$file"
''')
        self.instance = self.world/'domains/personal/parent'
        runtime = self.instance/'code/current'
        (runtime/'venv/bin').mkdir(parents=True)
        (runtime/'venv/bin/python').symlink_to(Path(sys.executable).resolve())
        package = runtime/'personal_discord'
        package.mkdir()
        (package/'__init__.py').write_text('')
        (package/'private_notice.py').write_text(API)
        (self.instance/'state').mkdir()
        self.mapping = dict(bridge_id='personal',owner_id='1',guild_id='2',parent_channel_id='3',mapping_revision='r1',project_key='project')
        self.config = dict(schema=2, enabled=True, home=str(self.home), source=str(self.code),
            python_executable=str(runtime/'venv/bin/python'), package_root=str(runtime),
            journal=str(self.instance/'state/journal'), ingress=str(self.instance/'state/ingress'),
            egress=str(self.instance/'state/egress'), mapping=self.mapping,
            domain='personal', instance_root=str(self.instance),
            projects={'project':str(self.code)},routes=[dict(target='personal-mate',project='project')])
        self.enrollment = dict(schema=1,enabled=True,private_owner_only=True,mapping=self.mapping,
            projects={'project':dict(alias='Personal',repository='owner/repo',sensitive=False)})
        self.selection = self.home/'config/away-reach.json'
        self.selection.write_text(json.dumps(dict(reach='discord-private',domain='personal')))
        self.enroll()
        self.env = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
        self.env.update(FM_HOME=str(self.home),FM_SUPERVISION_ACTOR='branch',FM_GATE_REFUSE_BYPASS='1')
        tools = self.world/'tools'
        tools.mkdir()
        forge = tools/'gh-axi'
        forge.write_text('#!/bin/bash\nhead=$(head -n 1 "$FM_HOME/state/head")\nprintf \'{"url":"https://github.com/owner/repo/pull/1","state":"open","isDraft":false,"headRefOid":"%s"}\\n\' "$head"\n')
        forge.chmod(0o755)
        self.env['PATH'] = str(tools)+os.pathsep+self.env['PATH']
        self.enter()

    def enroll(self):
        base = self.home/'config/discord/personal'
        (base/'integration.json').write_text(json.dumps(self.config))
        (base/'away-notices.json').write_text(json.dumps(self.enrollment))

    def call(self, *args):
        return subprocess.run([sys.executable,'-I',str(self.cli),*args],env=self.env,text=True,capture_output=True,check=True)

    def enter(self):
        # Exercise real entry and record validation, without launching supervision.
        result = subprocess.run(['bash',str(self.code/'bin/fm-afk-contract.sh'),'enter','--spend','1'],env=self.env,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('reach_channels:',(self.home/'state/.afk-contract').read_text())

    def hold(self, task='task', lifecycle='2026-11-15T01:00:00Z#0'):
        (self.home/f'state/{task}.hold').write_text(lifecycle+'\n')
        (self.home/f'state/{task}.meta').write_text('project='+str(self.code)+'\n')

    def report(self, kind='decision', task='task', host=False):
        result = subprocess.run(['bash',str(self.code/'bin/fm-branch-outcome.sh'),'append','--task',task,'--verdict','captain','--summary','secret raw report @everyone'],env=self.env,text=True,capture_output=True,check=True)
        if not host:
            return self.call('report',result.stdout.strip(),task,kind)
        turn = self.home/'state/.supervision-host-turn'
        turn.write_text('turn=test\nunscoped=1\nposture=away\nwake=heartbeat: test\n')
        return subprocess.run(['bash',str(self.code/'bin/fm-branch-report.sh'),'--task',task,'--verdict','captain','--summary','secret raw report @everyone','--notice',kind],env={**self.env,'FM_BRANCH_REPORT_TURN':'test'},capture_output=True,text=True,check=True)

    def calls(self):
        path=Path(self.config['journal']+'.calls')
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def age(self):
        with sqlite3.connect(self.home/'state/away-notices.sqlite3') as db:
            db.execute('UPDATE notices SET attempted=? WHERE attempted IS NOT NULL',(int(time.time())-31,))
            db.execute('UPDATE attempts SET epoch=?',(int(time.time())-31,))

    def test_off_and_unconfigured(self):
        self.selection.unlink()
        (self.home/'state/.afk-contract').unlink()
        self.enter()
        self.assertTrue(self.call('reach').stdout.startswith('none\n'))
        self.hold()
        self.report()
        self.assertEqual(self.calls(),[])
        self.assertFalse((self.home/'state/away-notices.sqlite3').exists())

    def test_unsupported_capability_and_old_record(self):
        Path(self.config['journal']+'.unsupported').touch()
        self.assertTrue(self.call('reach').stdout.startswith('none\n'))
        self.hold()
        self.report()
        self.assertEqual(self.calls(),[])
        self.assertIn('1 retained failure',self.call('return').stdout)
        Path(self.config['journal']+'.unsupported').unlink()
        record=self.home/'state/.afk-contract'
        record.write_text(record.read_text().replace('reach_channels: discord-private','reach_channels: none').replace('reach_binding:', 'old_binding:'))
        self.report()
        self.assertEqual(self.calls(),[])

    def test_replay_restart_and_independent_outcomes(self):
        self.hold()
        self.report()
        self.report()
        self.call('drain')
        self.assertEqual(len(self.calls()),1)
        self.assertEqual(self.calls()[0]['actor'],'branch')
        self.assertNotIn('secret',encoded(self.calls()))
        self.assertFalse((self.home/'state/.branch-outcomes-processed').exists())
        self.assertTrue((self.home/'state/task.hold').exists())
        self.assertEqual(len((self.home/'state/branch-outcomes.jsonl').read_text().splitlines()),2)

    def test_host_shape_and_notice_failure_preserves_outcome(self):
        self.hold()
        Path(self.config['journal']+'.fail').touch()
        result=self.report(host=True)
        self.assertIn('recorded seq',result.stdout)
        self.assertEqual(self.calls()[0]['actor'],'branch')
        self.assertIn('retained failure',self.call('return').stdout)
        self.assertNotIn('private error',self.call('return').stdout)
        self.assertTrue((self.home/'state/.supervision-host-receipts').exists())
        self.assertFalse((self.home/'state/.branch-outcomes-processed').exists())

    def test_sensitive_decision_generic(self):
        self.enrollment['projects']['project']['sensitive']=True
        self.enroll()
        # Replace the away record to pick up the separately reviewed binding.
        (self.home/'state/.afk-contract').unlink()
        self.enter()
        self.hold()
        self.report()
        notice=self.calls()[0]['notice']
        self.assertEqual(notice['template'],'sensitive-decision')
        self.assertEqual(notice['project_alias'],'')
        self.assertEqual(notice['pr_url'],'')

    def test_rate_limits_recheck_and_new_lifecycle(self):
        self.hold()
        self.report()
        self.hold('other')
        self.report(task='other')
        self.assertEqual(len(self.calls()),1)
        (self.home/'state/other.hold').unlink()
        self.age()
        self.call('drain')
        self.assertEqual(len(self.calls()),1)
        for index in range(9):
            self.age()
            self.hold(lifecycle=f'2026-11-15T02:00:00Z#{index+1}')
            self.report()
        self.assertEqual(len(self.calls()),10)
        self.age()
        self.hold(lifecycle='2026-11-15T03:00:00Z#11')
        self.report()
        self.assertEqual(len(self.calls()),10)
        with sqlite3.connect(self.home/'state/away-notices.sqlite3') as db:
            self.assertEqual(db.execute("SELECT count(*) FROM notices WHERE state='queued'").fetchone()[0],1)
            db.execute('UPDATE notices SET attempted=? WHERE attempted IS NOT NULL',(int(time.time())-601,))
            db.execute('UPDATE attempts SET epoch=?',(int(time.time())-601,))
        self.call('drain')
        self.assertEqual(len(self.calls()),11)

    def test_pr_heads_and_disallowed_urls(self):
        self.hold()
        url='https://github.com/owner/repo/pull/1'
        def ready(url,head):
            (self.home/'state/task.meta').write_text(f'project={self.code}\npr={url}\npr_head={head}\n')
            (self.home/'state/head').write_text(head)
        ready(url,'a'*40)
        self.report('pr-ready')
        self.report('pr-ready')
        self.assertEqual(len(self.calls()),1)
        self.age()
        ready(url,'b'*40)
        self.report('pr-ready')
        self.assertEqual(len(self.calls()),2)
        for bad in [url+'?token=secret',url+'#fragment',url.replace('https://','http://'),url.replace('github.com','evil.example'),url.replace('owner/repo','other/repo'),url.replace('github.com','owner@github.com')]:
            ready(bad,'c'*40)
            self.report('pr-ready')
        self.assertEqual(len(self.calls()),2)

    def test_revoked_binding_never_retargets(self):
        self.hold()
        self.report()
        self.hold('other')
        self.report(task='other')
        self.mapping['parent_channel_id']='99'
        self.enroll()
        self.call('drain')
        self.assertEqual(len(self.calls()),1)
        readback=subprocess.run(['bash',str(self.code/'bin/fm-afk-contract.sh'),'readback'],env=self.env,text=True,capture_output=True,check=True)
        self.assertIn('current reach: Reach unavailable',readback.stdout)

    def test_failure_replay_is_same_identity_and_bounded(self):
        self.hold()
        flag=Path(self.config['journal']+'.fail')
        flag.touch()
        self.report()
        for _ in range(22):
            with sqlite3.connect(self.home/'state/away-notices.sqlite3') as db:
                db.execute('UPDATE attempts SET epoch=?',(int(time.time())-601,))
            self.call('drain')
        self.assertEqual(len({row['notice']['notice_id'] for row in self.calls()}),1)
        self.assertIn('20 retained failure(s)', self.call('return').stdout)
        flag.unlink()
        self.age()
        self.call('drain')
        self.call('drain')
        self.assertEqual(len(self.calls()),24)
        self.assertTrue((self.home/'state/task.hold').exists())
        self.assertFalse((self.home/'state/.branch-outcomes-processed').exists())

    def pending(self):
        Path(self.config['journal']+'.owed').touch()
        self.hold()
        self.report()
        self.assertEqual(len(self.calls()),1)
        return self.calls()[0]['notice']['notice_id']

    def assert_withdrawn(self, ident):
        self.call('drain')
        self.assertEqual(Path(self.config['journal']+'.'+ident).read_text(),'stopped')
        self.assertEqual(len(self.calls()),1)
        withdrawals=[json.loads(line) for line in Path(self.config['journal']+'.withdrawals').read_text().splitlines()]
        self.assertEqual(withdrawals[0]['notice']['notice_id'],ident)
        self.assertEqual(withdrawals[0]['actor'],'branch')
        self.assertEqual(withdrawals[0]['notice']['origin']['parent_channel_id'],'3')
        self.assertTrue((self.home/'state/branch-outcomes.jsonl').exists())

    def test_owed_resolved_hold_is_withdrawn(self):
        ident=self.pending()
        (self.home/'state/task.hold').unlink()
        self.assert_withdrawn(ident)

    def test_owed_new_lifecycle_is_withdrawn(self):
        ident=self.pending()
        self.hold(lifecycle='2026-11-15T02:00:00Z#1')
        self.assert_withdrawn(ident)

    def test_owed_changed_head_is_withdrawn(self):
        Path(self.config['journal']+'.owed').touch()
        self.hold()
        (self.home/'state/task.meta').write_text(f'project={self.code}\npr=https://github.com/owner/repo/pull/1\npr_head={"a"*40}\n')
        (self.home/'state/head').write_text('a'*40)
        self.report('pr-ready')
        ident=self.calls()[0]['notice']['notice_id']
        (self.home/'state/head').write_text('b'*40)
        self.assert_withdrawn(ident)

    def test_owed_revoked_enrollment_is_withdrawn(self):
        ident=self.pending()
        self.enrollment['enabled']=False
        self.enroll()
        self.assert_withdrawn(ident)

    def test_owed_changed_binding_is_withdrawn(self):
        ident=self.pending()
        self.mapping['parent_channel_id']='99'
        self.enroll()
        self.assert_withdrawn(ident)

    def test_owed_return_is_withdrawn(self):
        ident=self.pending()
        subprocess.run(['bash',str(self.code/'bin/fm-afk-contract.sh'),'archive'],env=self.env,check=True,capture_output=True)
        self.assertEqual(Path(self.config['journal']+'.'+ident).read_text(),'stopped')
        self.assert_withdrawn(ident)

    def test_withdraw_failure_stays_due_after_reenrollment(self):
        ident=self.pending()
        flag=Path(self.config['journal']+'.withdraw-fail')
        flag.touch()
        (self.home/'state/task.hold').unlink()
        self.call('drain')
        self.assertTrue(self.call('reach').stdout.startswith('none\n'))
        self.assertIn('1 current failure',self.call('return').stdout)
        with sqlite3.connect(self.home/'state/away-notices.sqlite3') as db:
            self.assertEqual(db.execute('SELECT state FROM notices').fetchone()[0],'reconcile')
        self.hold()
        flag.unlink()
        self.assert_withdrawn(ident)
        self.assertTrue(self.call('reach').stdout.startswith('discord-private\n'))

    def test_uncertain_approval_recovery_reserves_spacing(self):
        self.hold()
        flag=Path(self.config['journal']+'.fail')
        flag.touch()
        self.report()
        self.age()
        flag.unlink()
        self.hold('other')
        self.report(task='other')
        self.assertEqual(len(self.calls()),2)
        self.assertEqual(self.calls()[0]['notice']['notice_id'],self.calls()[1]['notice']['notice_id'])
        self.call('drain')
        self.assertEqual(len(self.calls()),2)
        self.age()
        self.call('drain')
        self.assertEqual(len(self.calls()),3)
        self.assertNotEqual(self.calls()[1]['notice']['notice_id'],self.calls()[2]['notice']['notice_id'])

    def test_crash_before_approval_reserves_recovery_spacing(self):
        self.pending()
        ident=self.calls()[0]['notice']['notice_id']
        Path(self.config['journal']+'.calls').unlink()
        Path(self.config['journal']+'.'+ident).unlink()
        with sqlite3.connect(self.home/'state/away-notices.sqlite3') as db:
            db.execute('UPDATE notices SET confirmed=0')
        self.age()
        self.hold('other')
        self.report(task='other')
        self.assertEqual(len(self.calls()),1)
        self.assertEqual(self.calls()[0]['notice']['notice_id'],ident)
        self.age()
        self.call('drain')
        self.assertEqual(len({row['notice']['notice_id'] for row in self.calls()}),2)

    def test_current_failure_readback_and_recovered_history(self):
        self.hold()
        flag=Path(self.config['journal']+'.fail')
        flag.touch()
        self.report(host=True)
        self.assertTrue(self.call('reach').stdout.startswith('none\n'))
        result=subprocess.run(['bash',str(self.code/'bin/fm-afk-contract.sh'),'readback'],env=self.env,check=True,capture_output=True,text=True)
        self.assertIn('current reach: Reach unavailable',result.stdout)
        flag.unlink()
        self.age()
        self.call('drain')
        self.assertTrue(self.call('reach').stdout.startswith('discord-private\n'))
        self.assertIn('1 retained failure(s), 0 current failure(s)',self.call('return').stdout)

    def test_alias_and_foreign_domain_refused(self):
        self.enrollment['projects']['project']['alias']='@everyone secret\n'
        self.enroll()
        self.assertTrue(self.call('reach').stdout.startswith('none\n'))
        self.env['FM_DISCORD_DOMAIN']='galagoa'
        self.assertTrue(self.call('reach').stdout.startswith('none\n'))
        self.assertEqual(self.calls(),[])

unittest.main(argv=['notices'])
PY
