"""Public CLI tests: approved lifecycle design and merged slice-1 contract are the oracles.

These reject lost intents, duplicate approvals, premature disposal, false delivery,
selection latches and raw-content disclosure through observable custody and output.
Optional REAL_SOURCE qualifies the actual facade and its isolated journals offline.
"""
from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import time
import unittest

SOURCE, TEMP = map(Path, sys.argv[1:3])
REAL_SOURCE = Path(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else None

MAPPINGS = '''import hashlib,json
def mapping_id(mapping):
    fields=('bridge_id','owner_id','guild_id','parent_channel_id','mapping_revision','project_key')
    return hashlib.sha256(json.dumps({k:mapping[k] for k in fields},sort_keys=True,separators=(',',':')).encode()).hexdigest()
'''
API = '''import json,os
from pathlib import Path
CAPABILITY='private-notice-v1'
def available(*,config):
    return config.get('enabled') is True and all(config.get(k,{}).get('private_notices') is True for k in ('capabilities','peer_capabilities')) and any(not m.get('retired') and m.get('private_notices',{}).get('owner_only') is True for m in [config['mapping']])
def record(config,op,body):
    assert config['domain']==Path(__file__).parents[4].name
    assert os.environ.get('FM_DISCORD_DOMAIN')==config['domain']
    with Path(config['journal']+'.calls').open('a') as stream:
        stream.write(json.dumps({'op':op,'body':body,'actor':os.environ.get('FM_SUPERVISION_ACTOR')})+'\\n')
def custody(config,notice_id):
    return Path(config['journal']+'.'+notice_id)
def approve(*,config,notice):
    assert available(config=config)
    template=notice['template_id']
    fields={'notice_id','mapping_id','template_id','approved'}
    if template in ('pr-ready','decision-waiting'): fields.add('project_alias')
    if template=='pr-ready': fields.add('pr_url')
    assert set(notice)==fields and notice['approved'] is True
    record(config,'approve',notice)
    if Path(config['journal']+'.fail').exists(): raise ValueError('private error')
    path=custody(config,notice['notice_id'])
    if not path.exists(): path.write_text('owed')
    if Path(config['journal']+'.lost').exists(): raise ValueError('lost approval receipt')
    return {'notice_id':notice['notice_id'],'state':path.read_text()}
def state(*,config,notice_id,mapping_id):
    record(config,'state',{'notice_id':notice_id,'mapping_id':mapping_id})
    if Path(config['journal']+'.state-fail').exists(): raise ValueError('private error')
    return {'notice_id':notice_id,'state':custody(config,notice_id).read_text()}
def withdraw(*,config,notice_id,mapping_id,reason):
    assert reason in ('resolved','superseded','enrollment-revoked','away-ended')
    record(config,'withdraw',{'notice_id':notice_id,'mapping_id':mapping_id,'reason':reason})
    if Path(config['journal']+'.withdraw-fail').exists(): raise ValueError('private error')
    if Path(config['journal']+'.withdraw-owed').exists(): return {'notice_id':notice_id,'state':'owed'}
    path=custody(config,notice_id)
    if not path.exists(): raise KeyError('unknown approval')
    if path.read_text()!='delivered': path.write_text('stopped')
    return {'notice_id':notice_id,'state':path.read_text()}
'''


class Fixture(unittest.TestCase):
    real = False

    def setUp(self):
        self.world = TEMP / (type(self).__name__ + self._testMethodName)
        self.world.mkdir()
        self.home = self.world / 'home'
        (self.home / 'config/discord/personal').mkdir(parents=True)
        (self.home / 'state').mkdir()
        self.code = self.world / 'source'
        shutil.copytree(SOURCE / 'bin', self.code / 'bin')
        self.cli = self.code / 'bin/fm-away-notice.py'
        (self.code / 'bin/fm-captain-hold.sh').write_text('''#!/bin/bash
[ ! -f "$FM_HOME/state/hold-error" ] || exit 2
file="$FM_HOME/state/$2.hold"
[ -f "$file" ] || exit 1
head -n 1 "$file"
''')
        self.instance = self.world / 'domains/personal/parent'
        self.runtime = self.instance / 'code/current'
        (self.runtime / 'venv/bin').mkdir(parents=True)
        (self.runtime / 'venv/bin/python').symlink_to(Path(sys.executable).resolve())
        package = self.runtime / 'personal_discord'
        if self.real:
            shutil.copytree(REAL_SOURCE / 'personal_discord', package)
        else:
            package.mkdir()
            (package / '__init__.py').write_text('')
            (package / 'private_notice.py').write_text(API)
            (package / 'mappings.py').write_text(MAPPINGS)
        (self.instance / 'state').mkdir()
        self.mapping = dict(bridge_id='personal', owner_id='1', guild_id='2', parent_channel_id='3',
                            mapping_revision='r1', project_key='project')
        self.config = dict(schema=2, enabled=True, home=str(self.home), source=str(self.code),
                           python_executable=str(self.runtime / 'venv/bin/python'), package_root=str(self.runtime),
                           journal=str(self.instance / 'state/journal'), ingress=str(self.instance / 'state/ingress'),
                           egress=str(self.instance / 'state/egress'), domain='personal', instance_root=str(self.instance),
                           mapping={**self.mapping, 'private_notices': dict(owner_only=True, aliases=['Personal'],
                                     repositories=['https://github.com/owner/repo'])},
                           capabilities={'private_notices': True}, peer_capabilities={'private_notices': True},
                           projects={'project': str(self.code)}, routes=[dict(target='personal-mate', project='project')])
        self.enrollment = dict(schema=1, enabled=True, private_owner_only=True, mapping=self.mapping,
                               projects={'project': dict(alias='Personal', repository='owner/repo', sensitive=False)})
        self.selection = self.home / 'config/away-reach.json'
        self.selection.write_text(json.dumps(dict(reach='discord-private', domain='personal')))
        self.enroll()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
        self.env.update(FM_HOME=str(self.home), FM_SUPERVISION_ACTOR='branch', FM_GATE_REFUSE_BYPASS='1')
        tools = self.world / 'tools'
        tools.mkdir()
        forge = tools / 'gh-axi'
        forge.write_text('''#!/bin/bash
[ ! -f "$FM_HOME/state/forge-error" ] || exit 2
head=$(head -n 1 "$FM_HOME/state/head")
mode=success
[ ! -f "$FM_HOME/state/checks-mode" ] || mode=$(head -n 1 "$FM_HOME/state/checks-mode")
if [ "$1" = api ]; then
  printf '{"url":"https://github.com/owner/repo/pull/1","state":"open","isDraft":false,"headRefOid":"%s"}\n' "$head"
elif [ "$2" = view ]; then
  [ "$mode" != view-error ] || { printf 'forge unavailable\n' >&2; exit 1; }
  [ ! -f "$FM_HOME/state/checks-head" ] || head=$(head -n 1 "$FM_HOME/state/checks-head")
  checks='[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]'
  case "$mode" in
    none) checks='[]' ;;
    failing) checks='[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]' ;;
    pending) checks='[{"name":"ci","status":"IN_PROGRESS","conclusion":""}]' ;;
    context-failing) checks='[{"context":"ci","state":"FAILURE"}]' ;;
    context-pending) checks='[{"context":"ci","state":"PENDING"}]' ;;
    context-error) checks='[{"context":"ci","state":"ERROR"}]' ;;
    context-expected) checks='[{"context":"ci","state":"EXPECTED"}]' ;;
  esac
  printf '{"headRefOid":"%s","statusCheckRollup":%s}\n' "$head" "$checks"
else
  case "$mode" in
    none) printf 'no checks reported\n' >&2; exit 1 ;;
    failing|context-failing|context-error) exit 1 ;;
    pending|context-pending|context-expected) exit 8 ;;
    checks-error) printf 'forge unavailable\n' >&2; exit 1 ;;
  esac
fi
''')
        forge.chmod(0o755)
        self.env['PATH'] = str(tools) + os.pathsep + self.env['PATH']
        if self.real:
            self.runtime_call('from personal_discord.journal import Journal\nfor key in ("journal","ingress","egress"):\n j=Journal(config[key],create=True); j.close()')
        self.contract('enter', '--spend', '1')

    def enroll(self):
        base = self.home / 'config/discord/personal'
        (base / 'integration.json').write_text(json.dumps(self.config))
        (base / 'away-notices.json').write_text(json.dumps(self.enrollment))

    def call(self, *args):
        return subprocess.run([sys.executable, '-I', str(self.cli), *args], env=self.env,
                              text=True, capture_output=True, check=True)

    def contract(self, *args):
        return subprocess.run(['bash', str(self.code / 'bin/fm-afk-contract.sh'), *args], env=self.env,
                              text=True, capture_output=True, check=True)

    def runtime_call(self, program, config=None):
        config = self.config if config is None else config
        bootstrap = 'import sys,json\nsys.dont_write_bytecode=True\nsys.path.insert(0,sys.argv[1])\nconfig=json.loads(sys.argv[2])\n'
        return subprocess.run([sys.executable, '-I', '-c', bootstrap + program, config['package_root'], json.dumps(config)],
                              env=self.env, capture_output=True, text=True, check=True)

    def hold(self, task='task', lifecycle='2026-11-15T01:00:00Z#0'):
        (self.home / f'state/{task}.hold').write_text(lifecycle + '\n')
        (self.home / f'state/{task}.meta').write_text('project=' + str(self.code) + '\n')

    def ready(self, head='a' * 40, url='https://github.com/owner/repo/pull/1'):
        (self.home / 'state/task.meta').write_text(f'project={self.code}\npr={url}\npr_head={head}\n')
        (self.home / 'state/head').write_text(head)

    def report(self, kind='decision', task='task', host=False):
        if host:
            (self.home / 'state/.supervision-host-turn').write_text('turn=test\nunscoped=1\nposture=away\nwake=heartbeat: test\n')
            return subprocess.run(['bash', str(self.code / 'bin/fm-branch-report.sh'), '--task', task,
                                   '--verdict', 'captain', '--summary', 'secret raw report @everyone', '--notice', kind],
                                  env={**self.env, 'FM_BRANCH_REPORT_TURN': 'test'}, capture_output=True, text=True, check=True)
        result = subprocess.run(['bash', str(self.code / 'bin/fm-branch-outcome.sh'), 'append', '--task', task,
                                 '--verdict', 'captain', '--summary', 'secret raw report @everyone'], env=self.env,
                                text=True, capture_output=True, check=True)
        return self.call('report', result.stdout.strip(), task, kind)

    def rows(self):
        with closing(sqlite3.connect(self.home / 'state/away-notices.sqlite3')) as db, db:
            db.row_factory = sqlite3.Row
            return [dict(row) for row in db.execute('SELECT * FROM notices ORDER BY rowid')]

    def age(self, seconds=31):
        with closing(sqlite3.connect(self.home / 'state/away-notices.sqlite3')) as db, db:
            db.execute('UPDATE attempts SET epoch=?', (int(time.time()) - seconds,))

    def calls(self, operation=None, config=None):
        config = self.config if config is None else config
        path = Path(config['journal'] + '.calls')
        values = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [row for row in values if operation is None or row['op'] == operation]

    def flag(self, suffix):
        path = Path(self.config['journal'] + '.' + suffix)
        path.touch()
        return path

    def install_domain(self, domain):
        instance = self.world / 'domains' / domain / 'parent'
        runtime = instance / 'code/current'
        (runtime / 'venv/bin').mkdir(parents=True)
        (runtime / 'venv/bin/python').symlink_to(Path(sys.executable).resolve())
        if self.real:
            shutil.copytree(REAL_SOURCE / 'personal_discord', runtime / 'personal_discord')
        else:
            package = runtime / 'personal_discord'
            package.mkdir()
            (package / '__init__.py').write_text('')
            (package / 'private_notice.py').write_text(API)
            (package / 'mappings.py').write_text(MAPPINGS)
        (instance / 'state').mkdir()
        config = json.loads(json.dumps(self.config))
        config.update(domain=domain, instance_root=str(instance), package_root=str(runtime),
                      python_executable=str(runtime / 'venv/bin/python'))
        for key in ('journal', 'ingress', 'egress'):
            config[key] = str(instance / 'state' / key)
        config['mapping'].update(bridge_id=domain, parent_channel_id='4')
        config['routes'][0]['target'] = domain + '-mate'
        enrollment = json.loads(json.dumps(self.enrollment))
        enrollment['mapping'].update(bridge_id=domain, parent_channel_id='4')
        base = self.home / 'config/discord' / domain
        base.mkdir()
        (base / 'integration.json').write_text(json.dumps(config))
        (base / 'away-notices.json').write_text(json.dumps(enrollment))
        if self.real:
            self.runtime_call('from personal_discord.journal import Journal\nfor key in ("journal","ingress","egress"):\n j=Journal(config[key],create=True); j.close()', config=config)
        return config

    def switch_domain(self, domain):
        self.selection.write_text(json.dumps(dict(reach='discord-private', domain=domain)))
        (self.home / 'state/.afk-contract').unlink()
        self.contract('enter', '--spend', '1')

    def assert_intake_recovers(self, path, host=False):
        self.hold()
        content = path.read_text()
        binding = self.contract('field', 'reach_binding').stdout.strip()
        path.write_text('{')
        self.report(host=host)
        self.assertEqual(len(self.rows()), 1)
        self.assertEqual(self.rows()[0]['state'], 'queued')
        self.assertEqual(json.loads(self.rows()[0]['target']), {'binding': binding})
        self.assertIsNotNone(self.rows()[0]['error'])
        self.assertFalse((self.home / 'state/.branch-outcomes-processed').exists())
        path.write_text(content)
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'owed')
        self.assertIsNone(self.rows()[0]['error'])
        self.assertTrue((self.home / 'state/task.hold').exists())
        self.assertIn('1 retained failure(s)', self.call('return').stdout)

    def unavailable(self):
        self.assertIn('Reach unavailable', self.call('reach').stdout)
        self.assertIn('current reach: Reach unavailable', self.contract('readback').stdout)


class Notices(Fixture):
    def assert_readiness_withdrawn(self, mode, uncertain=False):
        """Choice A: positively lost readiness disposes the unsent obligation."""
        self.hold()
        self.ready()
        if uncertain:
            self.flag('lost')
        self.report('pr-ready')
        self.assertEqual(self.rows()[0]['state'], 'uncertain' if uncertain else 'owed')
        notice_id = self.rows()[0]['notice_id']
        (self.home / 'state/checks-mode').write_text(mode)
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'withdrawn')
        self.assertEqual(Path(self.config['journal'] + '.' + notice_id).read_text(), 'stopped')
        self.assertEqual(self.calls('withdraw')[0]['body']['reason'], 'superseded')
        self.assertEqual(len(self.calls('approve')), 1)
        self.assertTrue((self.home / 'state/task.hold').exists())
        self.assertFalse((self.home / 'state/.branch-outcomes-processed').exists())

    def test_red_ci_withdraws_owed_notice_at_same_head(self):
        self.assert_readiness_withdrawn('failing')

    def test_pending_ci_withdraws_owed_notice_at_same_head(self):
        self.assert_readiness_withdrawn('pending')

    def test_failed_status_context_withdraws_owed_notice(self):
        self.assert_readiness_withdrawn('context-failing')

    def test_pending_status_context_withdraws_owed_notice(self):
        self.assert_readiness_withdrawn('context-pending')

    def test_error_status_context_withdraws_owed_notice(self):
        self.assert_readiness_withdrawn('context-error')

    def test_expected_status_context_withdraws_owed_notice(self):
        self.assert_readiness_withdrawn('context-expected')

    def test_lost_readiness_withdraws_uncertain_approval(self):
        self.assert_readiness_withdrawn('pending', uncertain=True)

    def test_head_changed_between_queries_withdraws_notice(self):
        self.ready()
        self.report('pr-ready')
        (self.home / 'state/checks-head').write_text('b' * 40)
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'withdrawn')
        self.assertEqual(self.calls('withdraw')[0]['body']['reason'], 'superseded')

    def test_forge_errors_preserve_owed_notice_and_recover(self):
        self.ready()
        self.report('pr-ready')
        mode = self.home / 'state/checks-mode'
        for error in ('view-error', 'checks-error'):
            mode.write_text(error)
            self.call('drain')
            self.assertEqual(self.rows()[0]['state'], 'owed')
            self.assertIsNotNone(self.rows()[0]['error'])
            self.assertEqual(self.calls('withdraw'), [])
        self.unavailable()
        mode.write_text('none')
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'owed')
        self.assertIsNone(self.rows()[0]['error'])
        self.assertEqual(len(self.calls('approve')), 1)

    def test_no_ci_pr_is_ready_at_recorded_head(self):
        """Repository readiness contract: no CI is not a failed check."""
        self.ready()
        (self.home / 'state/checks-mode').write_text('none')
        self.report('pr-ready', host=True)
        self.assertEqual(self.rows()[0]['state'], 'owed')
        self.assertIsNone(self.rows()[0]['error'])
        self.assertEqual(len(self.calls('approve')), 1)
        self.assertEqual(self.calls('approve')[0]['body']['template_id'], 'pr-ready')

    def test_failing_and_pending_checks_do_not_qualify(self):
        self.ready()
        mode = self.home / 'state/checks-mode'
        mode.write_text('failing')
        self.report('pr-ready')
        self.assertEqual(self.rows()[0]['state'], 'queued')
        mode.write_text('pending')
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'queued')
        self.assertEqual(self.calls('approve'), [])
        mode.write_text('success')
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'owed')
        self.assertEqual(len(self.calls('approve')), 1)

    def test_forge_errors_cannot_be_mistaken_for_no_ci(self):
        """A successful empty rollup, not exit 1, is the no-CI oracle."""
        self.ready()
        mode = self.home / 'state/checks-mode'
        mode.write_text('view-error')
        self.report('pr-ready')
        self.assertEqual(self.rows()[0]['state'], 'queued')
        self.assertIsNotNone(self.rows()[0]['error'])
        mode.write_text('checks-error')
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'queued')
        self.assertIsNotNone(self.rows()[0]['error'])
        self.assertEqual(self.calls('approve'), [])
        self.unavailable()
        mode.write_text('none')
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'owed')
        self.assertIsNone(self.rows()[0]['error'])
        self.assertFalse((self.home / 'state/.branch-outcomes-processed').exists())

    def test_intake_survives_enrollment_lookup_failure(self):
        self.assert_intake_recovers(self.home / 'config/discord/personal/away-notices.json', host=True)
        self.assertEqual(len(self.calls('approve')), 1)

    def test_intake_survives_selection_lookup_failure(self):
        self.assert_intake_recovers(self.selection)
        self.assertEqual(len(self.calls('approve')), 1)

    def test_deferred_intent_cannot_adopt_replacement_binding(self):
        self.hold()
        path = self.home / 'config/discord/personal/away-notices.json'
        path.write_text('{')
        self.report()
        self.mapping['parent_channel_id'] = '99'
        self.config['mapping']['parent_channel_id'] = '99'
        self.enroll()
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'withdrawn')
        self.assertIsNone(self.rows()[0]['proposal'])
        self.assertEqual(self.calls(), [])
        self.assertIn('1 retained failure(s)', self.call('return').stdout)

    def test_domain_replacement_withdraws_using_original_runtime(self):
        self.hold()
        self.report()
        replacement = self.install_domain('private')
        self.switch_domain('private')
        self.hold('other')
        self.report(task='other')
        self.assertEqual([row['state'] for row in self.rows()], ['withdrawn', 'owed'])
        self.assertEqual(self.calls('withdraw')[0]['body']['reason'], 'enrollment-revoked')
        self.assertEqual(len(self.calls('approve', config=replacement)), 1)
        self.assertEqual(self.calls('approve', config=replacement)[0]['actor'], 'branch')

    def test_mixed_domain_return_visits_every_original_runtime(self):
        self.hold()
        self.report()
        flag = self.flag('withdraw-fail')
        replacement = self.install_domain('private')
        self.switch_domain('private')
        self.hold('other')
        self.report(task='other')
        self.assertEqual([row['state'] for row in self.rows()], ['reconcile', 'owed'])
        flag.unlink()
        self.assertIn('0 withdrawal(s) needing reconciliation', self.call('return').stdout)
        self.assertEqual([row['state'] for row in self.rows()], ['withdrawn', 'withdrawn'])
        self.assertEqual(self.calls('withdraw')[-1]['body']['reason'], 'away-ended')
        self.assertEqual(self.calls('withdraw', config=replacement)[0]['body']['reason'], 'away-ended')
        self.assertEqual(len(self.calls('approve')), 1)
        self.assertEqual(len(self.calls('approve', config=replacement)), 1)

    def test_explicit_caller_domain_remains_a_constraint(self):
        self.hold()
        self.report()
        replacement = self.install_domain('private')
        self.switch_domain('private')
        self.env['FM_DISCORD_DOMAIN'] = 'personal'
        self.hold('other')
        self.report(task='other')
        self.assertEqual(self.rows()[1]['state'], 'queued')
        self.assertIsNotNone(self.rows()[1]['error'])
        self.assertEqual(self.calls(config=replacement), [])
        self.env.pop('FM_DISCORD_DOMAIN')
        self.call('drain')
        self.assertEqual(self.rows()[1]['state'], 'owed')

    def test_off_and_quiet(self):
        self.selection.unlink()
        self.contract('archive')
        self.contract('enter', '--spend', '1')
        self.hold()
        self.report()
        self.assertTrue(self.call('reach').stdout.startswith('none\n'))
        self.assertFalse((self.home / 'state/away-notices.sqlite3').exists())
        self.assertEqual(self.calls(), [])
        self.contract('archive')
        self.selection.write_text(json.dumps(dict(reach='discord-private', domain='personal')))
        self.env['FM_AFK_MODE'] = 'quiet'
        self.contract('enter', '--spend', '1')
        self.report()
        self.assertEqual(self.contract('mode').stdout.strip(), 'quiet')
        self.assertEqual(self.calls(), [])

    def test_replay_state_receipt_and_independent_bookkeeping(self):
        self.hold()
        self.report()
        self.report()
        self.call('drain')
        self.assertEqual(len(self.calls('approve')), 1)
        self.assertGreaterEqual(len(self.calls('state')), 2)
        self.assertEqual(self.rows()[0]['state'], 'owed')
        notice_id = self.rows()[0]['notice_id']
        Path(self.config['journal'] + '.' + notice_id).write_text('delivered')
        self.call('drain')
        self.call('return')
        self.assertEqual(self.rows()[0]['state'], 'delivered')
        self.assertEqual(self.calls('withdraw'), [])
        self.assertTrue(all(call['actor'] == 'branch' for call in self.calls()))
        self.assertNotIn('secret', json.dumps(self.calls()))
        self.assertFalse((self.home / 'state/.branch-outcomes-processed').exists())
        self.assertTrue((self.home / 'state/task.hold').exists())

    def test_host_failure_retains_outcome_and_recovers(self):
        self.hold()
        flag = self.flag('fail')
        result = self.report(host=True)
        self.assertIn('recorded seq', result.stdout)
        self.assertEqual(self.rows()[0]['state'], 'uncertain')
        self.unavailable()
        flag.unlink()
        self.age()
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'owed')
        self.assertIn('notifications configured', self.call('reach').stdout)
        self.assertEqual(len((self.home / 'state/branch-outcomes.jsonl').read_text().splitlines()), 1)
        self.assertTrue((self.home / 'state/.supervision-host-receipts').exists())

    def test_failed_report_and_unrelated_drain(self):
        self.ready()
        flag = self.home / 'state/forge-error'
        flag.touch()
        self.report('pr-ready')
        self.assertEqual(self.rows()[0]['state'], 'queued')
        self.assertIsNone(self.rows()[0]['proposal'])
        self.call('drain')
        self.hold('other')
        self.report(task='other')
        self.unavailable()
        self.assertIsNotNone(self.rows()[0]['error'])
        flag.unlink()
        self.age()
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'owed')
        self.assertIsNone(self.rows()[0]['error'])
        self.assertIn('notifications configured', self.call('reach').stdout)

    def test_temporary_hold_error_preserves_queued_and_owed(self):
        self.hold()
        self.report()
        self.hold('other')
        self.report(task='other')
        flag = self.home / 'state/hold-error'
        flag.touch()
        self.age()
        self.call('drain')
        self.assertEqual([row['state'] for row in self.rows()], ['owed', 'queued'])
        self.assertEqual(self.calls('withdraw'), [])
        self.unavailable()
        flag.unlink()
        self.call('drain')
        self.assertEqual([row['state'] for row in self.rows()], ['owed', 'owed'])
        self.assertIn('notifications configured', self.call('reach').stdout)

    def test_uncertain_recovery_reserves_spacing_and_ten_minute_budget(self):
        self.hold()
        flag = self.flag('fail')
        self.report()
        self.age()
        flag.unlink()
        self.hold('other')
        self.report(task='other')
        self.assertEqual(len(self.calls('approve')), 2)
        self.assertEqual(self.calls('approve')[0]['body'], self.calls('approve')[1]['body'])
        self.assertEqual(self.rows()[1]['state'], 'queued')
        for index in range(8):
            self.age()
            self.hold(f'next{index}')
            self.report(task=f'next{index}')
        self.assertEqual(len(self.calls('approve')), 10)
        self.age()
        self.call('drain')
        self.assertEqual(len(self.calls('approve')), 10)
        self.age(601)
        self.call('drain')
        self.assertEqual(len(self.calls('approve')), 11)

    def test_crash_reservation_recovery(self):
        self.hold()
        self.report()
        with closing(sqlite3.connect(self.home / 'state/away-notices.sqlite3')) as db, db:
            db.execute("UPDATE notices SET state='uncertain'")
        Path(self.config['journal'] + '.' + self.rows()[0]['notice_id']).unlink()
        self.age()
        self.hold('other')
        self.report(task='other')
        self.assertEqual(len(self.calls('approve')), 2)
        self.assertEqual(self.rows()[1]['state'], 'queued')

    def test_positive_resolution_and_superseded_lifecycle(self):
        self.hold()
        self.report()
        self.hold('other')
        self.report(task='other')
        self.age()
        self.call('drain')
        (self.home / 'state/task.hold').unlink()
        self.hold('other', '2026-11-15T02:00:00Z#1')
        self.call('drain')
        self.assertEqual([row['state'] for row in self.rows()], ['withdrawn', 'withdrawn'])
        self.assertEqual([call['body']['reason'] for call in self.calls('withdraw')], ['resolved', 'superseded'])

    def test_pr_head_change_and_temporary_forge_error(self):
        self.ready()
        self.report('pr-ready')
        flag = self.home / 'state/forge-error'
        flag.touch()
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'owed')
        self.assertEqual(self.calls('withdraw'), [])
        flag.unlink()
        (self.home / 'state/head').write_text('b' * 40)
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'withdrawn')
        self.assertEqual(self.calls('withdraw')[0]['body']['reason'], 'superseded')

    def test_revocation_return_reentry_has_no_health_latch(self):
        self.hold()
        self.report()
        self.enrollment['enabled'] = False
        self.enroll()
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'withdrawn')
        self.contract('archive')
        self.enrollment['enabled'] = True
        self.enroll()
        self.contract('enter', '--spend', '1')
        self.assertIn('reach_channels: discord-private', (self.home / 'state/.afk-contract').read_text())
        self.hold('other')
        self.age()
        self.report(task='other')
        self.assertEqual(self.rows()[-1]['state'], 'owed')
        self.assertIn('notifications configured', self.call('reach').stdout)

    def test_capability_disabled_entry_recovers_selection(self):
        self.config['peer_capabilities']['private_notices'] = False
        self.enroll()
        self.contract('archive')
        self.contract('enter', '--spend', '1')
        record = (self.home / 'state/.afk-contract').read_text()
        self.assertIn('reach_channels: discord-private', record)
        self.assertNotIn('reach_binding: -', record)
        self.hold()
        self.report()
        self.assertEqual(self.rows()[0]['state'], 'queued')
        self.unavailable()
        self.config['peer_capabilities']['private_notices'] = True
        self.enroll()
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'owed')
        self.assertIn('notifications configured', self.call('reach').stdout)

    def test_return_retries_every_obligation_after_archive(self):
        self.hold()
        self.report()
        self.hold('other')
        flag = self.flag('fail')
        self.age()
        self.report(task='other')
        flag.unlink()
        self.assertEqual([row['state'] for row in self.rows()], ['owed', 'uncertain'])
        withdraw_flag = self.flag('withdraw-fail')
        self.contract('archive')
        result = self.call('return')
        self.assertIn('2 withdrawal(s) needing reconciliation', result.stdout)
        self.assertEqual([row['state'] for row in self.rows()], ['reconcile', 'reconcile'])
        self.assertTrue(all(call['body']['reason'] == 'away-ended' for call in self.calls('withdraw')))
        self.assertNotIn('private error', result.stdout)
        withdraw_flag.unlink()
        result = self.call('return')
        self.assertIn('1 withdrawal(s) needing reconciliation', result.stdout)
        self.assertEqual(self.rows()[0]['state'], 'withdrawn')
        self.assertEqual(self.rows()[1]['state'], 'reconcile')

    def test_uncertain_withdrawal_never_reports_disposed(self):
        self.hold()
        self.report()
        flag = self.flag('withdraw-owed')
        (self.home / 'state/task.hold').unlink()
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'reconcile')
        self.unavailable()
        flag.unlink()
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'withdrawn')
        self.assertEqual(len(self.calls('approve')), 1)

    def test_changed_binding_never_retargets(self):
        self.hold()
        self.report()
        old = self.rows()[0]['proposal']
        self.mapping['parent_channel_id'] = '99'
        self.config['mapping']['parent_channel_id'] = '99'
        self.enroll()
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'withdrawn')
        self.assertEqual(self.rows()[0]['proposal'], old)
        self.assertEqual(self.calls('withdraw')[0]['body']['mapping_id'], json.loads(old)['mapping_id'])

    def test_fixed_disclosure_and_url_bounds(self):
        self.hold()
        self.enrollment['projects']['project']['sensitive'] = True
        self.enroll()
        self.contract('archive')
        self.contract('enter', '--spend', '1')
        self.report()
        self.assertEqual(set(self.calls('approve')[0]['body']), {'notice_id', 'mapping_id', 'template_id', 'approved'})
        for url in ('https://github.com/owner/repo/pull/10000000000', 'https://github.com/owner/repo/pull/1?secret=x',
                    'https://github.com/owner/repo/pull/1#x', 'https://user@github.com/owner/repo/pull/1',
                    'https://evil.example/owner/repo/pull/1'):
            self.ready(url=url)
            self.report('pr-ready')
        self.assertEqual(len(self.calls('approve')), 1)
        self.assertNotIn('secret', json.dumps(self.calls()))

    def test_legacy_main_provenance_is_not_fabricated(self):
        self.env.pop('FM_SUPERVISION_ACTOR')
        self.hold()
        self.report()
        self.assertIsNone(self.calls('approve')[0]['actor'])
        self.assertEqual(self.rows()[0]['state'], 'owed')

    def test_mixed_release_stays_queued_without_fallback(self):
        module = self.runtime / 'personal_discord/private_notice.py'
        module.write_text("CAPABILITY='unsupported'\n")
        self.contract('archive')
        self.contract('enter', '--spend', '1')
        self.hold()
        self.report()
        self.assertEqual(self.rows()[0]['state'], 'queued')
        self.assertEqual(self.calls(), [])
        self.unavailable()
        module.write_text(API)
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'owed')

    def test_temporary_configuration_read_error_preserves_obligation(self):
        self.hold()
        self.report()
        path = self.home / 'config/discord/personal/away-notices.json'
        path.write_text('{')
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'owed')
        self.assertEqual(self.calls('withdraw'), [])
        self.unavailable()
        self.enroll()
        self.call('drain')
        self.assertIsNone(self.rows()[0]['error'])
        self.assertIn('notifications configured', self.call('reach').stdout)

    def test_denial_requires_reconciliation_not_invented_revocation(self):
        self.hold()
        self.report()
        Path(self.config['journal'] + '.' + self.rows()[0]['notice_id']).write_text('stopped')
        self.call('drain')
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'reconcile')
        self.assertEqual(self.calls('withdraw'), [])
        self.unavailable()
        self.call('return')
        self.assertEqual(self.rows()[0]['state'], 'withdrawn')
        self.assertEqual(self.calls('withdraw')[0]['body']['reason'], 'away-ended')

    def test_lost_approval_receipt_replays_same_payload(self):
        self.hold()
        flag = self.flag('lost')
        self.report()
        self.assertEqual(self.rows()[0]['state'], 'uncertain')
        flag.unlink()
        self.age()
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'owed')
        self.assertEqual(self.calls('approve')[0]['body'], self.calls('approve')[1]['body'])

    def test_parallel_drains_serialize_new_approvals(self):
        flag = self.home / 'state/hold-error'
        flag.touch()
        self.hold()
        self.report()
        self.hold('other')
        self.report(task='other')
        flag.unlink()
        processes = [subprocess.Popen([sys.executable, '-I', str(self.cli), 'drain'], env=self.env,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
        for process in processes:
            output = process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0, output)
        self.assertEqual(len(self.calls('approve')), 1)
        self.assertEqual([row['state'] for row in self.rows()], ['owed', 'queued'])

    def test_failure_history_is_bounded_not_health(self):
        self.hold()
        flag = self.home / 'state/hold-error'
        flag.touch()
        self.report()
        for _ in range(22):
            self.call('drain')
        flag.unlink()
        self.call('drain')
        self.assertIn('notifications configured', self.call('reach').stdout)
        self.assertIn('20 retained failure(s), 0 current failure(s)', self.call('return').stdout)


@unittest.skipUnless(REAL_SOURCE, 'set FM_NOTICE_REAL_SOURCE to the reviewed slice-1 checkout')
class RealFacade(Fixture):
    real = True

    def test_real_readiness_loss_withdraws_parent_obligation(self):
        self.ready()
        self.report('pr-ready')
        (self.home / 'state/checks-mode').write_text('pending')
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'withdrawn')
        with closing(sqlite3.connect(self.config['journal'])) as db, db:
            self.assertEqual(db.execute('SELECT phase FROM obligations').fetchone()[0], 'owner-disposed')
            withdrawal = json.loads(db.execute("SELECT body FROM records WHERE family='notice-withdrawal'").fetchone()[0])
            self.assertEqual(withdrawal['reason'], 'superseded')
        self.assertEqual(len(self.events()), 1)

    def test_real_no_ci_pr_creates_one_notice(self):
        self.ready()
        (self.home / 'state/checks-mode').write_text('none')
        self.report('pr-ready')
        self.call('drain')
        self.assertEqual(self.rows()[0]['state'], 'owed')
        self.assertEqual(len(self.events()), 1)
        self.assertEqual(self.events()[0]['template_id'], 'pr-ready')

    def test_real_intake_recovers_from_configuration_failure(self):
        self.assert_intake_recovers(self.home / 'config/discord/personal/away-notices.json', host=True)
        self.assertEqual(len(self.events()), 1)

    def test_real_mixed_domain_withdrawal_and_return(self):
        self.hold()
        self.report()
        replacement = self.install_domain('private')
        self.config['enabled'] = False
        self.enroll()
        self.switch_domain('private')
        self.hold('other')
        self.report(task='other')
        self.assertEqual([row['state'] for row in self.rows()], ['reconcile', 'owed'])
        self.config['enabled'] = True
        self.enroll()
        self.assertIn('0 withdrawal(s) needing reconciliation', self.call('return').stdout)
        self.assertEqual([row['state'] for row in self.rows()], ['withdrawn', 'withdrawn'])
        for config, domain in ((self.config, 'personal'), (replacement, 'private')):
            with closing(sqlite3.connect(config['journal'])) as db, db:
                event = json.loads(db.execute('SELECT body FROM events').fetchone()[0])
                self.assertEqual(event['origin']['bridge_id'], domain)
                self.assertEqual(db.execute('SELECT count(*) FROM events').fetchone()[0], 1)
                withdrawal = json.loads(db.execute("SELECT body FROM records WHERE family='notice-withdrawal'").fetchone()[0])
                self.assertEqual(withdrawal['reason'], 'away-ended')

    def events(self):
        with closing(sqlite3.connect(self.config['journal'])) as db, db:
            return [json.loads(row[0]) for row in db.execute('SELECT body FROM events ORDER BY sequence')]

    def test_real_templates_dedupe_and_receipt_only_reconciliation(self):
        self.hold()
        self.report()
        self.report()
        self.call('drain')
        events = self.events()
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]['template_id'], 'decision-waiting')
        self.assertEqual(events[0]['text'], 'A decision is waiting for the Personal work. Please review it in our usual conversation.')
        self.assertEqual(self.rows()[0]['state'], 'owed')
        self.age()
        self.ready()
        self.report('pr-ready')
        self.assertEqual(self.events()[1]['text'], 'The Personal work is ready for review: <https://github.com/owner/repo/pull/1>. Review it in our usual conversation. Discord replies do not approve it.')
        self.age()
        self.hold('unassociated')
        (self.home / 'state/unassociated.meta').unlink()
        self.report(task='unassociated')
        self.assertEqual(self.events()[2]['text'], 'A decision is waiting. Please review it in our usual conversation.')
        with closing(sqlite3.connect(self.config['journal'])) as db, db:
            self.assertEqual(db.execute("SELECT count(*) FROM records WHERE family='request'").fetchone()[0], 0)
        self.assertNotIn('secret', json.dumps(self.events()))
        self.assertFalse((self.home / 'state/.branch-outcomes-processed').exists())

    def test_real_withdrawal_after_retirement_and_delivery_evidence(self):
        self.hold()
        self.report()
        self.hold('other')
        self.age()
        self.report(task='other')
        delivered = self.events()[0]['id']
        self.runtime_call('from personal_discord.journal import Journal\nj=Journal(config["journal"])\nwith j.transaction():\n j.put("notice-delivery",' + repr(delivered) + ',{"message_ids":["123"]})\n j.db.execute("UPDATE obligations SET phase=\'delivered\' WHERE event=?",(' + repr(delivered) + ',))\nj.close()')
        self.config['mapping']['retired'] = True
        self.config['capabilities']['private_notices'] = False
        self.enroll()
        result = self.call('return')
        self.assertIn('0 withdrawal(s) needing reconciliation', result.stdout)
        self.assertEqual([row['state'] for row in self.rows()], ['delivered', 'withdrawn'])
        with closing(sqlite3.connect(self.config['journal'])) as db, db:
            self.assertEqual(db.execute("SELECT count(*) FROM records WHERE family='notice-delivery'").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT count(*) FROM records WHERE family='notice-withdrawal'").fetchone()[0], 1)
        self.assertEqual(len(self.events()), 2)


unittest.main(argv=['away-notice'])
