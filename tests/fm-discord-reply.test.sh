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
cp "$ROOT/bin/fm-discord-reply.py" "$ROOT/bin/fm-discord-hook.py" \
  "$ROOT/bin/fm-discord-verify-pins.py" "$ROOT/bin/fm-gate-refuse-lib.sh" "$TMP_ROOT/source/bin/"
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
import sqlite3
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
        assert parent.mapping == {'fixture':True}
        assert environment['FM_HOME'] == environment['FM_ROOT_OVERRIDE'] == str(home)
        assert environment['FM_STATE_OVERRIDE'] == str(home/'state')
        assert environment['FM_DATA_OVERRIDE'] == str(home/'data')
        assert environment['FM_CONFIG_OVERRIDE'] == str(home/'config')
        assert environment['FM_PROJECTS_OVERRIDE'] == str(home/'projects')
        assert environment['HOME'] == str(home)
        for key in ('NO_MISTAKES_GATE', 'FM_SUPERVISION_ACTOR', 'PI_CODING_AGENT'):
            assert environment.get(key) == os.environ.get(key)
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
        (package / 'journal.py').write_text(JOURNAL)
        (package / 'integration.py').write_text(INTEGRATION)
        (package / 'parent.py').write_text('class Parent:\n    def __init__(self,journal,mapping):\n        self.j,self.mapping=journal,mapping\n')
        files = {name: hashlib.sha256((self.source/name).read_bytes()).hexdigest() for name in
                 ('bin/fm-inbox.sh', 'bin/fm-send.sh', 'bin/fm-spawn.sh', 'bin/fm-discord-hook.py')}
        self.config = dict(schema=2, enabled=True, home=str(self.home), source=str(self.source),
                           source_commit=subprocess.check_output(['git','-C',str(self.source),'rev-parse','HEAD'],text=True).strip(),
                           source_digest=digest(files), python_executable=str(Path(sys.executable).resolve()),
                           package_root=str(self.package),
                           hashes={str(p.relative_to(self.package)):hashlib.sha256(p.read_bytes()).hexdigest()
                                   for p in package.glob('*.py')},
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
        self.refuse('reconcile before retry',ident='missing-request')
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

    def test_mismatched_pin_refuses_before_journal_open(self):
        self.config['source_commit'] = '0'*40
        self.config_path.write_text(json.dumps(self.config))
        self.refuse('reconcile before retry')
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())
        self.assertFalse(Path(self.config['egress']).with_suffix('.opened').exists())

    def test_changed_package_refuses_before_journal_open(self):
        (self.package/'personal_discord/journal.py').write_text('raise AssertionError("must not import")')
        self.refuse('reconcile before retry')
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

    def test_preflight_verifier_agrees_on_offline_fixtures(self):
        manifest = self.world/'transport.json'
        manifest.write_text(json.dumps(dict(schema=2,enabled=True,parent_identity={
            **{key:self.config[key] for key in ('source_commit','source_digest')},
            'home_identity':hashlib.sha256(str(self.home).encode()).hexdigest()})))
        result = subprocess.run([sys.executable,'-I',str(self.source/'bin/fm-discord-verify-pins.py'),
                                 '--parent-config',str(self.config_path),'--transport-manifest',str(manifest)],
                                capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'Discord source/config/manifest pins agree; journal epoch and fences not checked.\n')
        self.assertEqual(self.approvals(),[])
        print(result.stdout.strip())


unittest.main(argv=['discord-reply'],verbosity=2)
PY
pass 'Discord reply: approved final, authoritative return, isolation, replay and refusal paths'
