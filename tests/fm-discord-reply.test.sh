#!/usr/bin/env bash
# Parent reply CLI with pinned inert package, fake journal and lifecycle owner.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-discord-reply)
PY314=$(command -v python3.14 || true)
if [ -z "$PY314" ]; then
  printf 'SKIP: enabled Discord reply fixture requires CPython 3.14\n'
  exit 0
fi
fm_git_init_commit "$TMP_ROOT/source"
mkdir -p "$TMP_ROOT/source/bin"
cp "$ROOT/bin/fm-discord-reply.py" "$ROOT/bin/fm-discord-acknowledge.py" "$ROOT/bin/fm-discord-hook.py" \
  "$ROOT/bin/fm-gate-refuse-lib.sh" "$TMP_ROOT/source/bin/"
for name in fm-inbox.sh fm-send.sh fm-spawn.sh; do
  printf 'inert fixture for %s\n' "$name" > "$TMP_ROOT/source/bin/$name"
done
"$PY314" -I - "$TMP_ROOT" <<'PY'
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import time
import subprocess
import sys
import unittest

root = Path(sys.argv[1]).resolve()


@contextmanager
def database(path):
    db = sqlite3.connect(path)
    try:
        with db:
            yield db
    finally:
        db.close()


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()


JOURNAL = '''import hashlib, json, sqlite3
from pathlib import Path

def digest(value):
    return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',', ':'),ensure_ascii=False).encode()).hexdigest()

class Conflict(ValueError):
    pass

class Journal:
    def __init__(self, path):
        Path(path).with_suffix('.opened').touch()
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
    def fixture(self):
        return json.loads(self.db.execute('SELECT body FROM fixture').fetchone()[0])
    @property
    def fenced(self):
        return self.fixture().get('fenced',False)
    @property
    def delivery_fenced(self):
        return self.fixture().get('delivery_fenced',False)
    def record(self, family, ident):
        body = self.fixture()
        if family != 'request' or ident != body['id']:
            raise KeyError('absent request')
        return body['request']
    def state(self, family, ident):
        self.record(family,ident)
        return 7, self.fixture()['state']
    def work_binding(self, ident):
        self.record('request',ident)
        return self.fixture()['binding']
    def close(self):
        self.db.close()
'''

INTEGRATION = '''import hashlib, json, os, subprocess
from .journal import digest

class Integration:
    @staticmethod
    def identify_source(source):
        files = {name:hashlib.sha256((source/name).read_bytes()).hexdigest() for name in
                 ('bin/fm-inbox.sh','bin/fm-send.sh','bin/fm-spawn.sh','bin/fm-discord-hook.py')}
        return dict(source_commit=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip(),
                    source_digest=digest(files))
    def __init__(self, parent, ingress, egress, *, source, home, environment):
        self.j = parent.j
        self.home = home
        assert parent.mapping == self.j.fixture().get('mapping',{'fixture':True})
        assert environment.get('FM_DISCORD_DOMAIN') == os.environ.get('FM_DISCORD_DOMAIN')
        self.egress = egress
        assert environment['FM_HOME'] == environment['FM_ROOT_OVERRIDE'] == str(home)
        assert environment['FM_STATE_OVERRIDE'] == str(home/'state')
        assert environment['FM_DATA_OVERRIDE'] == str(home/'data')
        assert environment['FM_CONFIG_OVERRIDE'] == str(home/'config')
        assert environment['FM_PROJECTS_OVERRIDE'] == str(home/'projects')
        assert environment['HOME'] == str(home)
        for key in ('NO_MISTAKES_GATE', 'FM_SUPERVISION_ACTOR', 'PI_CODING_AGENT'):
            assert environment.get(key) == os.environ.get(key)
    def approve_acknowledgement(self, ident, **body):
        from .journal import Conflict
        fixture = self.j.fixture()
        assert ident == fixture['id']
        assert body['origin'] == fixture['request']['origin']
        assert body['revision'] == 7 and type(body['revision']) is int
        assert body['generation'] == fixture['binding']['generation']
        assert body['correlation'] == fixture['binding']['correlation']
        assert body['approved'] is True
        # Model the live public-caption guard: no approval side effects on refusal.
        if 'secret' in body['safe_text']:
            from .checks import Refusal
            raise Refusal('unsafe private caption fixture')
        fields = dict(line.split('=',1) for line in
                      (self.home/'state/pending-replies'/body['correlation']).read_text().splitlines())
        if not fields.get('delivered_epoch') and fields.get('phase') != 'resolved':
            raise Conflict('Milestone needs authoritative routed delivery evidence')
        self.j.db.execute('INSERT INTO approvals VALUES(?,?)',('attempt',json.dumps(body)))
        self.j.db.commit()
        if fixture.get('conflict'):
            raise Conflict('private exception must never escape')
        if fixture.get('unpublished'):
            return {'event':'ack','published':False}
        self.j.db.execute('INSERT INTO approvals VALUES(?,?)',('ack',json.dumps(body)))
        self.j.db.commit()
        return {'event':'ack','published':True}
    def approve_update(self, ident, **body):
        fixture = self.j.fixture()
        binding = fixture['binding']
        assert ident == fixture['id']
        assert body['revision'] == 7
        assert body['generation'] == binding['generation']
        assert body['correlation'] == binding['correlation']
        assert body['kind'] == 'final' and body['terminal'] is True and body['approved'] is True
        event_id = 'final.' + digest(dict(request=ident,generation=binding['generation'],correlation=binding['correlation']))
        assert body['event_id'] == event_id
        row = self.j.db.execute('SELECT body FROM approvals WHERE id=?',(event_id,)).fetchone()
        encoded = json.dumps(body,sort_keys=True)
        if row and row[0] != encoded:
            raise ValueError('immutable approved final')
        self.j.db.execute('INSERT OR IGNORE INTO approvals VALUES(?,?)',(event_id,encoded))
        self.j.db.commit()
        if 'mapping' in fixture:
            self.egress.db.execute('CREATE TABLE IF NOT EXISTS sent(bot,text)')
            self.egress.db.execute('INSERT INTO sent VALUES(?,?)', (fixture['mapping']['bridge_id'],body['safe_text']))
            self.egress.db.commit()
        return {'event':event_id,'published':not fixture.get('unpublished',False)}
'''


class Reply(unittest.TestCase):
    def setUp(self):
        self.world = root / 'world'
        shutil.rmtree(self.world, ignore_errors=True)
        self.source = self.world / 'source'
        shutil.copytree(root / 'source', self.source)
        self.home = self.world / 'home'
        self.home.mkdir()
        if self._testMethodName.startswith('test_gate_lab_'):
            subprocess.run(['/bin/bash', '-c', '. "$1"; fm_gate_lab_mark "$2"', '_',
                            str(self.source/'bin/fm-gate-refuse-lib.sh'), str(self.home)], check=True)
        (self.home / 'config').mkdir()
        (self.home / 'state/pending-replies').mkdir(parents=True)
        self.package = self.world / 'package'
        package = self.package / 'personal_discord'
        package.mkdir(parents=True)
        (package / '__init__.py').write_text('')
        (package / 'checks.py').write_text('class Refusal(ValueError):\n    pass\n')
        (package / 'journal.py').write_text(JOURNAL)
        (package / 'integration.py').write_text(INTEGRATION)
        (package / 'parent.py').write_text('class Parent:\n    def __init__(self,journal,mapping):\n        self.j,self.mapping=journal,mapping\n')
        files = {name: hashlib.sha256((self.source/name).read_bytes()).hexdigest() for name in
                 ('bin/fm-inbox.sh', 'bin/fm-send.sh', 'bin/fm-spawn.sh', 'bin/fm-discord-hook.py')}
        self.config = dict(schema=2, enabled=True, home=str(self.home), source=str(self.source),
                           source_commit=subprocess.check_output(['git','-C',str(self.source),'rev-parse','HEAD'],text=True).strip(),
                           source_digest=digest(files), python_executable=str(Path(sys.executable).resolve()),
                           package_root=str(self.package),
                           journal=str(self.world/'parent.sqlite'), egress=str(self.world/'egress.sqlite'),
                           ingress=str(self.world/'must-not-open-ingress'), mapping={'fixture':True},
                           projects={'project':str(self.source)}, routes=[dict(target='domain',project='project')])
        self.config_path = self.home / 'config/discord-integration.json'
        self.config_path.write_text(json.dumps(self.config))
        self.ident = 'captured-request'
        self.binding = dict(generation='accepted-generation', work_id='domain', correlation='0123456789abcdef',
                            scope_digest='a'*64, kind='read-only')
        self.fixture = dict(id=self.ident, request=dict(origin=dict(project_key='project'),scope_digest='a'*64),
                            state=dict(generation='accepted-generation',phase='accepted'), binding=self.binding)
        with database(self.config['journal']) as db:
            db.executescript('CREATE TABLE fixture(body); CREATE TABLE lanes(project,request,phase); CREATE TABLE approvals(id PRIMARY KEY,body);')
            db.execute('INSERT INTO fixture VALUES(?)',(json.dumps(self.fixture),))
            db.execute('INSERT INTO lanes VALUES(?,?,?)',('project',self.ident,'active'))
        sqlite3.connect(self.config['egress']).close()
        self.return_path = self.home / 'state/pending-replies' / self.binding['correlation']
        self.lifecycle_return()

    def domain_configs(self):
        import copy
        configs = {}
        for index, domain in enumerate(('pristine-valets', 'galagoa-new')):
            instance = self.world/'domains'/domain/'parent'
            (instance/'code/current/venv/bin').mkdir(parents=True)
            (instance/'code/current/venv/bin/python').symlink_to(Path(sys.executable).resolve())
            shutil.copytree(self.package/'personal_discord', instance/'code/current/personal_discord')
            (instance/'state').mkdir()
            config = dict(self.config, domain=domain, instance_root=str(instance),
                          package_root=str(instance/'code/current'),
                          python_executable=str(instance/'code/current/venv/bin/python'),
                          **{key:str(instance/'state'/(key+'.sqlite')) for key in ('journal','ingress','egress')})
            config['mapping'] = dict(bridge_id=domain, owner_id='owner', guild_id=str(index+1),
                                     parent_channel_id=str(index+10), mapping_revision='pilot-v1', project_key='project')
            target = domain+'-mate'
            config['routes'] = [dict(target=target, project='project')]
            path = self.home/'config/discord'/domain/'integration.json'
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(config))
            shutil.copyfile(self.config['journal'], config['journal'])
            shutil.copyfile(self.config['egress'], config['egress'])
            fixture = copy.deepcopy(self.fixture)
            fixture['mapping'] = config['mapping']
            fixture['request']['origin'] = dict(config['mapping'], thread_id=str(index+10), source_message_id='100')
            fixture['binding'].update(work_id=target, correlation=str(index+1)*16)
            with database(config['journal']) as db:
                db.execute('UPDATE fixture SET body=?', (json.dumps(fixture),))
            record = self.home/'state/pending-replies'/fixture['binding']['correlation']
            record.write_text('corr_id='+fixture['binding']['correlation']+'\ntask_id='+target+
                              '\nparent_home='+str(self.home)+'\nphase=resolved\n')
            configs[domain] = config
        return configs

    def domain_call(self, domain, config):
        return subprocess.run([sys.executable, '-I', str(self.source/'bin/fm-discord-reply.py'),
                               self.ident, config['routes'][0]['target'], 'Only '+domain+' approved answer'],
                              env={**os.environ, 'FM_HOME':str(self.home), 'FM_DISCORD_DOMAIN':domain},
                              capture_output=True, text=True, timeout=15)

    def test_two_domains_reply_concurrently_to_only_their_own_bot(self):
        from concurrent.futures import ThreadPoolExecutor
        configs = self.domain_configs()
        before = self.config_path.read_bytes()
        with ThreadPoolExecutor() as executor:
            jobs = [executor.submit(self.domain_call, domain, config) for domain, config in configs.items()]
            for job in jobs:
                result = job.result()
                self.assertEqual(result.returncode, 0, result.stderr)
        for domain, config in configs.items():
            with database(config['egress']) as db:
                self.assertEqual(db.execute('SELECT bot,text FROM sent').fetchall(),
                                 [(domain, 'Only '+domain+' approved answer')])
        self.assertEqual(self.config_path.read_bytes(), before)
        self.assertEqual(self.approvals(), [])
        self.invoke()  # Legacy reply still uses only the unchanged global configuration.

    def test_foreign_origin_and_return_refuse_before_egress_in_both_directions(self):
        import copy
        configs = self.domain_configs()
        for domain, config in configs.items():
            other = next(value for key, value in configs.items() if key != domain)
            with database(config['journal']) as db:
                original = json.loads(db.execute('SELECT body FROM fixture').fetchone()[0])
            for kind in ('origin', 'return'):
                fixture = copy.deepcopy(original)
                if kind == 'origin':
                    fixture['request']['origin'] = other['mapping']
                else:
                    fixture['binding']['correlation'] = '2'*16 if domain == 'pristine-valets' else '1'*16
                with database(config['journal']) as db:
                    db.execute('UPDATE fixture SET body=?', (json.dumps(fixture),))
                result = self.domain_call(domain, config)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('another bound domain' if kind == 'origin' else 'another route or home', result.stderr)
                self.assertFalse(Path(config['egress']).with_suffix('.opened').exists())
                with database(config['journal']) as db:
                    self.assertEqual(db.execute('SELECT * FROM approvals').fetchall(), [])

    def lifecycle_return(self, **changes):
        # Fake lifecycle owner, not the command under test, records the return.
        fields = dict(corr_id=self.binding['correlation'], task_id='domain', parent_home=str(self.home),
                      phase='resolved', resolved_via='marked_status', resolved_epoch='1234567890')
        fields.update(changes)
        self.return_path.write_text(''.join(f'{key}={value}\n' for key,value in fields.items()))

    def update(self):
        with database(self.config['journal']) as db:
            db.execute('UPDATE fixture SET body=?',(json.dumps(self.fixture),))

    def approvals(self):
        with database(self.config['journal']) as db:
            return db.execute('SELECT id,body FROM approvals').fetchall()

    def invoke(self, reason=None, words='The answer is ready.', route='domain', ident=None, env=None, command=None):
        result = subprocess.run([str(command or sys.executable), '-I', str(self.source/'bin/fm-discord-reply.py'),
                                 ident or self.ident, route, words], capture_output=True, text=True, timeout=10,
                                env={**os.environ, 'FM_HOME':str(self.home), **(env or {})})
        self.assertEqual(result.stdout,'')
        if reason is None:
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stderr,'')
        else:
            self.assertEqual(result.returncode,1)
            self.assertIn(reason,result.stderr)
            self.assertNotIn(str(self.world),result.stderr)
            self.assertNotIn(words,result.stderr)
        self.assertFalse(Path(self.config['ingress']).exists())
        self.assertFalse(list(self.package.rglob('__pycache__')))
        return result

    def refuse(self, reason, **kwargs):
        self.invoke(reason,**kwargs)
        self.assertEqual(self.approvals(),[])

    def gate_environment(self, marker='review'):
        environment = {key:'' for key in os.environ if key.startswith('FM_') and key.endswith('_OVERRIDE')}
        environment.update(NO_MISTAKES_GATE=marker, FM_GATE_REFUSE_BYPASS='',
                           FM_SUPERVISION_ACTOR='main', PI_CODING_AGENT='1')
        return environment

    def test_gate_refuses_before_configuration_and_journals(self):
        before = {path:Path(path).read_bytes() for path in
                  (self.config['journal'], self.config['egress'], self.return_path)}
        original_config = self.config_path.read_text()
        for marker in ('review', ''):
            for config in (original_config, '{invalid configuration'):
                with self.subTest(marker=marker, config=config):
                    self.config_path.write_text(config)
                    self.refuse('parent lifecycle authority required', env=self.gate_environment(marker))
                    for path, content in before.items():
                        self.assertEqual(Path(path).read_bytes(), content)
                    for key in ('journal', 'egress'):
                        self.assertFalse(Path(self.config[key]).with_suffix('.opened').exists())

    def test_gate_lab_permits_approved_final_and_preserves_authority_signals(self):
        for directory in ('data', 'projects'):
            (self.home/directory).mkdir()
        environment = self.gate_environment()
        environment.update(FM_ROOT_OVERRIDE=str(self.source), FM_STATE_OVERRIDE=str(self.home/'state'),
                           FM_CONFIG_OVERRIDE=str(self.home/'config'))
        self.invoke(env=environment)
        self.assertEqual(len(self.approvals()), 1)

    def test_gate_lab_rejects_nonstock_override(self):
        for directory in ('data', 'projects'):
            (self.home/directory).mkdir()
        environment = self.gate_environment()
        environment['FM_STATE_OVERRIDE'] = str(self.world/'other-state')
        self.refuse('parent lifecycle authority required', env=environment)
        for key in ('journal', 'egress'):
            self.assertFalse(Path(self.config[key]).with_suffix('.opened').exists())

    def test_final_uses_existing_binding_and_exact_approved_words(self):
        words = 'Your preferred option is available.'
        self.invoke(words=words)
        self.assertEqual(len(self.approvals()),1)
        body = json.loads(self.approvals()[0][1])
        self.assertEqual(body['safe_text'],words)
        self.assertEqual(body['generation'],'accepted-generation')
        self.assertEqual(body['correlation'],'0123456789abcdef')
        self.assertTrue(body['terminal'])
        self.assertEqual(body['kind'],'final')

    def test_identical_repeat_uses_same_final_even_after_lane_finishes(self):
        self.invoke()
        before = self.approvals()
        self.fixture['state']['phase'] = 'completed'
        self.update()
        with database(self.config['journal']) as db:
            db.execute("UPDATE lanes SET phase='finished'")
        self.invoke()
        self.assertEqual(self.approvals(),before)

    def test_changed_words_cannot_replace_approval(self):
        self.invoke()
        before = self.approvals()
        self.invoke('reconcile before retry',words='A different answer.')
        self.assertEqual(self.approvals(),before)

    def test_unresolved_return_refuses_without_manufacturing_resolution(self):
        self.lifecycle_return(phase='awaiting_report')
        before = self.return_path.read_bytes()
        self.refuse('return is not resolved')
        self.assertEqual(self.return_path.read_bytes(),before)

    def test_missing_return_refuses(self):
        self.return_path.unlink()
        self.refuse('return absent')
        self.assertFalse(self.return_path.exists())

    def test_wrong_return_home_task_or_correlation_refuses(self):
        for key,value in (('parent_home','/other-home'),('task_id','other-task'),('corr_id','fedcba9876543210')):
            with self.subTest(key=key):
                self.lifecycle_return(**{key:value})
                self.refuse('another route or home')

    def test_symlink_and_duplicate_return_refuse(self):
        other = self.world/'other-return'
        self.return_path.rename(other)
        self.return_path.symlink_to(other)
        self.refuse('return absent')
        self.return_path.unlink()
        self.lifecycle_return()
        with self.return_path.open('a') as stream:
            stream.write('phase=resolved\n')
        self.refuse('ambiguous correlated return')

    def test_unknown_request_or_route_refuses(self):
        self.refuse('Captured request lookup failed',ident='missing-request')
        self.refuse('exact mapped route required',route='missing-route')

    def test_wrong_project_or_task_binding_refuses(self):
        self.fixture['request']['origin']['project_key'] = 'other-project'
        self.update()
        self.refuse('not bound to this mapped route')
        self.fixture['request']['origin']['project_key'] = 'project'
        self.binding['work_id'] = 'other-task'
        self.update()
        self.refuse('not bound to this mapped route')

    def test_stale_generation_or_scope_refuses(self):
        self.binding['generation'] = 'stale-generation'
        self.update()
        self.refuse('generation mismatch')
        self.binding['generation'] = 'accepted-generation'
        self.fixture['state']['current_scope_digest'] = 'b'*64
        self.update()
        self.refuse('scope binding mismatch')

    def test_non_active_lane_refuses(self):
        for phase in ('queued','withdrawn','deferred'):
            with self.subTest(phase=phase), database(self.config['journal']) as db:
                db.execute('UPDATE lanes SET phase=?',(phase,))
                db.commit()
                self.refuse('lane is not active or finished')

    def test_fences_refuse(self):
        for flag in ('fenced','delivery_fenced'):
            with self.subTest(flag=flag):
                self.fixture[flag] = True
                self.update()
                self.refuse('remains fenced')
                self.fixture[flag] = False

    def test_source_status_fields_are_optional_and_do_not_fence(self):
        self.config['source_commit'] = 'old'
        self.config.pop('source_digest')
        self.config_path.write_text(json.dumps(self.config))
        self.invoke()
        self.assertEqual(len(self.approvals()),1)

    def test_escaping_package_root_refuses_before_import_or_journal(self):
        (self.package/'personal_discord/journal.py').write_text('raise AssertionError("must not import")')
        (self.world/'code').mkdir()
        (self.world/'code/current').symlink_to(self.package)
        self.config['package_root']=str(self.world/'code/current')
        self.config_path.write_text(json.dumps(self.config))
        self.refuse('canonical release inside the enrolled code tree')
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())

    def test_home_binding_refuses_by_check_name_before_journal(self):
        self.config['home']='/private/wrong-home'
        self.config_path.write_text(json.dumps(self.config))
        self.refuse('Integration schema/home mismatch')
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())

    def test_duplicate_configuration_refuses_by_check_name(self):
        self.config_path.write_text('{"enabled":true,"enabled":false}')
        self.refuse('Duplicate configuration field')
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())

    def test_unsafe_or_oversized_words_refuse_before_journal_open(self):
        for words in ('', '  ', 'Two\nlines', 'Two\rlines', 'Null\x01byte', 'x'*401, '\u00e9'*201, 'Two\u2028lines'):
            with self.subTest(words=repr(words)):
                # Short fragments can occur in diagnostics; do not use invoke's
                # payload non-disclosure check for empty/whitespace strings.
                result = subprocess.run([sys.executable,'-I',str(self.source/'bin/fm-discord-reply.py'),
                                         self.ident,'domain',words],capture_output=True,text=True,timeout=10,
                                        env={**os.environ,'FM_HOME':str(self.home)})
                self.assertEqual(result.returncode,1)
                self.assertIn('one nonempty line',result.stderr)
                self.assertEqual(result.stdout,'')
        self.assertEqual(self.approvals(),[])
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())

    def test_no_false_success_when_publication_is_incomplete(self):
        self.fixture['unpublished'] = True
        self.update()
        self.invoke('not yet published; reconcile before retry')
        self.assertEqual(len(self.approvals()),1,'committed approval is retained for repair')

    def test_pinned_interpreter_reexec_preserves_reply_entrypoint(self):
        python = next((path for path in (shutil.which('python3.12'), '/usr/bin/python3', shutil.which('python3'))
                       if path and Path(path).is_file() and Path(path).resolve() != Path(sys.executable).resolve()), None)
        if python is None:
            self.skipTest('no alternate Python interpreter installed')
        self.invoke(command=python)
        self.assertEqual(len(self.approvals()),1)

    def test_disabled_absent_and_symlink_configuration_refuse_before_open(self):
        original = self.config_path.read_text()
        self.config_path.unlink()
        self.refuse('regular parent configuration required')
        self.config_path.write_text('{"enabled":false}')
        self.refuse('enabled parent configuration required')
        other = self.world/'config.json'
        other.write_text(original)
        self.config_path.unlink()
        self.config_path.symlink_to(other)
        self.refuse('regular parent configuration required')
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())

    def test_reply_does_not_renew_or_require_intake_readiness(self):
        # Already owed finals survive an expired intake lease. The private
        # publication API, unlike dispatch preparation, does not renew it.
        self.fixture['readiness'] = {'expires':0}
        self.update()
        self.invoke()
        with database(self.config['journal']) as db:
            self.assertEqual(json.loads(db.execute('SELECT body FROM fixture').fetchone()[0])['readiness'],{'expires':0})


class AcknowledgementTests(unittest.TestCase):
    setUp = Reply.setUp
    lifecycle_return = Reply.lifecycle_return
    update = Reply.update
    approvals = Reply.approvals

    def configure(self, *, enabled=True, words='I am checking the invoice totals.'):
        command = self.world/'cheap-wording.py'
        command.write_text('import json, os, pwd, sys\nfrom pathlib import Path\n'
                           'assert not any(key.startswith("FM_") for key in os.environ)\n'
                           'assert "ANTHROPIC_API_KEY" not in os.environ\n'
                           'assert os.environ["HOME"] == pwd.getpwuid(os.getuid()).pw_dir\n'
                           'assert os.environ["USER"] == os.environ["LOGNAME"] == pwd.getpwuid(os.getuid()).pw_name\n'
                           'assert not list(Path.cwd().iterdir())\n'
                           f'assert not Path.cwd().is_relative_to(Path({str(self.home)!r}))\n'
                           'data=json.load(sys.stdin)\n'
                           'assert data["verified_public_context"] == "Checking invoice totals against receipts."\n'
                           'assert "Maximum 400 UTF-8 bytes" in data["instruction"]\n'
                           'assert "one sentence" in data["instruction"] and "No private paths" in data["instruction"]\n'
                           'assert "links or mentions" in data["instruction"]\n'
                           f'Path({str(self.world/"wording-called")!r}).touch()\n'
                           f'print({words!r})\n')
        (self.home/'config/discord-acknowledgement.json').write_text(json.dumps(
            dict(enabled=enabled, wording_command=[sys.executable, '-I', str(command)])))

    def invoke_ack(self, *, delay='well-over-30s', success=True, command=None, env=None, timeout=15):
        result = subprocess.run([command or sys.executable, '-I', str(self.source/'bin/fm-discord-acknowledge.py'),
                                 self.ident, 'domain', delay, 'Checking invoice totals against receipts.'],
                                capture_output=True, text=True, timeout=timeout,
                                env={**os.environ, 'FM_HOME':str(self.home), **(env or {})})
        self.assertEqual(result.returncode, 0 if success else 1, result.stderr)
        self.assertEqual(result.stdout, '')
        if success:
            self.assertEqual(result.stderr, '')
        else:
            self.assertNotIn(str(self.world), result.stderr)
            self.assertNotIn('unsafe private caption fixture', result.stderr)
            self.assertNotIn('Traceback', result.stderr)
        return result

    def test_slow_sends_one_contextual_line_with_original_binding(self):
        self.fixture['request']['origin'].update(thread_id='123', message_id='456', extra={'preserve':True})
        self.update()
        self.configure()
        self.invoke_ack(env={'TMPDIR':str(self.home/'state'), 'HOME':str(self.home),
                             'FM_TEST_UNTRUSTED':'must-not-inherit', 'ANTHROPIC_API_KEY':'fixture-only'})
        rows = self.approvals()
        self.assertEqual([row[0] for row in rows], ['attempt', 'ack'])
        body = json.loads(rows[1][1])
        self.assertEqual(body['safe_text'], 'I am checking the invoice totals.')
        self.assertEqual(body['origin'], self.fixture['request']['origin'])
        self.assertEqual(body['generation'], self.binding['generation'])
        self.assertEqual(body['correlation'], self.binding['correlation'])
        self.assertEqual(body['revision'], 7)
        self.assertTrue((self.world/'wording-called').exists())

    def test_imminent_never_opens_configuration_journal_or_model(self):
        self.configure()
        self.config_path.write_text('invalid')
        self.invoke_ack(delay='imminent')
        self.assertEqual(self.approvals(), [])
        self.assertFalse((self.world/'wording-called').exists())
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())

    def test_absent_and_inactive_switch_send_nothing(self):
        self.invoke_ack()
        self.configure(enabled=False)
        self.invoke_ack()
        self.assertEqual(self.approvals(), [])
        self.assertFalse((self.world/'wording-called').exists())
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())

    def test_closed_window_and_conflict_are_silent_single_attempts(self):
        for flag in ('unpublished', 'conflict'):
            with self.subTest(flag=flag):
                self.setUp()
                self.fixture[flag] = True
                self.update()
                self.configure()
                before = list((self.home/'state').rglob('*'))
                self.invoke_ack()
                self.assertEqual([row[0] for row in self.approvals()], ['attempt'])
                self.assertEqual(list((self.home/'state').rglob('*')), before)

    def test_overlong_and_multiline_wording_never_reach_approval(self):
        for words in ('x'*401, '\u00e9'*201, '', 'Two\nlines', 'Two\u2028lines', 'Two\x01lines',
                      'Two\x85lines', 'Two\u202elines', 'Two\u2067lines', '\u200b', '\u200b \u200b'):
            with self.subTest(words=repr(words)):
                self.setUp()
                self.configure(words=words)
                self.invoke_ack(success=False)
                self.assertEqual(self.approvals(), [])

    def test_unsafe_copy_uses_live_guard_without_approval_side_effect(self):
        self.configure(words='The secret invoice total is available.')
        result = self.invoke_ack(success=False)
        self.assertIn('public caption guard refused', result.stderr)
        self.assertEqual(self.approvals(), [])

    def test_missing_transport_api_is_safe_before_wording(self):
        self.configure()
        with (self.package/'personal_discord/integration.py').open('a') as stream:
            stream.write('\ndel Integration.approve_acknowledgement\n')
        result = subprocess.run([sys.executable, '-I', str(self.source/'bin/fm-discord-acknowledge.py'),
                                 self.ident, 'domain', 'well-over-30s', 'Checking invoice totals against receipts.'],
                                capture_output=True, text=True, timeout=15,
                                env={**os.environ, 'FM_HOME':str(self.home)})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, 'Discord acknowledgement unavailable: enrolled release lacks contextual acknowledgement; keep the switch off.\n')
        self.assertFalse((self.world/'wording-called').exists())
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())
        self.assertEqual(self.approvals(), [])

    def test_pinned_reexec_keeps_acknowledgement_entrypoint(self):
        self.configure()
        python = next((path for path in (shutil.which('python3.12'), '/usr/bin/python3', shutil.which('python3'))
                       if path and Path(path).is_file() and Path(path).resolve() != Path(sys.executable).resolve()), None)
        if python is None:
            self.skipTest('no alternate Python interpreter installed')
        self.invoke_ack(command=python)
        self.assertEqual([row[0] for row in self.approvals()], ['attempt', 'ack'])

    def test_gate_refuses_before_wording_and_journal(self):
        self.configure()
        self.invoke_ack(success=False, env={'NO_MISTAKES_GATE':'review', 'FM_GATE_REFUSE_BYPASS':''})
        self.assertFalse((self.world/'wording-called').exists())
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())
        self.assertEqual(self.approvals(), [])

    def test_wording_failure_is_not_retried_or_published(self):
        self.configure()
        command = self.world/'cheap-wording.py'
        command.write_text('from pathlib import Path\nimport sys\n'
                           f'p=Path({str(self.world/"attempts")!r})\n'
                           'p.write_text(p.read_text()+"x" if p.exists() else "x")\n'
                           'sys.exit(1)\n')
        self.invoke_ack(success=False)
        self.assertEqual((self.world/'attempts').read_text(), 'x')
        self.assertEqual(self.approvals(), [])

    def test_wording_timeout_kills_the_whole_process_group(self):
        self.configure()
        marker = self.world/'wording-child'
        command = self.world/'cheap-wording.py'
        command.write_text('from pathlib import Path\nimport subprocess, sys, time\n'
                           'child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(120)"])\n'
                           f'Path({str(marker)!r}).write_text(str(child.pid))\n'
                           'time.sleep(120)\n')
        child = None
        try:
            result = self.invoke_ack(success=False, timeout=35)
            self.assertIn('timed out; no line sent, do not retry', result.stderr)
            child = int(marker.read_text())
            # A killed orphan can briefly remain a zombie until init reaps it.
            for _ in range(30):
                state = subprocess.run(['ps', '-o', 'stat=', '-p', str(child)],
                                       capture_output=True, text=True, timeout=5).stdout.strip()
                if not state or state.startswith('Z'):
                    break
                time.sleep(0.1)
            self.assertTrue(not state or state.startswith('Z'), 'wording child still running')
            self.assertEqual(self.approvals(), [])
        finally:
            if child is None and marker.exists():
                child = int(marker.read_text())
            if child is not None:
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_wrong_binding_refuses_before_wording(self):
        self.configure()
        self.binding['generation'] = 'old'
        self.update()
        self.invoke_ack(success=False)
        self.assertFalse((self.world/'wording-called').exists())
        self.assertEqual(self.approvals(), [])

    def test_does_not_require_a_finished_return_to_acknowledge(self):
        self.configure()
        self.lifecycle_return(phase='awaiting_report', delivered_epoch='1234567880')
        before = self.return_path.read_bytes()
        self.invoke_ack()
        self.assertEqual(self.return_path.read_bytes(), before)
        self.assertEqual(len(self.approvals()), 2)

    def test_missing_delivery_evidence_skips_before_wording(self):
        self.configure()
        self.lifecycle_return(phase='delivery_unknown')
        before = self.return_path.read_bytes()
        self.invoke_ack()
        self.assertEqual(self.return_path.read_bytes(), before)
        self.assertFalse((self.world/'wording-called').exists())
        self.assertEqual(self.approvals(), [])


unittest.main(argv=['discord-reply'],verbosity=2)
PY
pass 'Discord reply: approved final, authoritative return, isolation, replay and refusal paths'
