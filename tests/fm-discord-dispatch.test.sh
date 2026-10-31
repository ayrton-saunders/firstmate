#!/usr/bin/env bash
# Parent dispatch CLI with pinned inert package and a fake lifecycle owner.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-discord-dispatch)
PY314=$(command -v python3.14 || true)
if [ -z "$PY314" ]; then
  printf 'SKIP: enabled Discord dispatch fixture requires CPython 3.14\n'
  exit 0
fi
fm_git_init_commit "$TMP_ROOT/source"
mkdir -p "$TMP_ROOT/source/bin"
cp "$ROOT/bin/fm-discord-dispatch.py" "$ROOT/bin/fm-discord-hook.py" \
  "$ROOT/bin/fm-gate-refuse-lib.sh" "$TMP_ROOT/source/bin/"
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


JOURNAL = '''import json, sqlite3, time
from pathlib import Path
class Journal:
    def __init__(self,path):
        Path(path).with_suffix('.opened').touch()
        self.db=sqlite3.connect(path)
        self.db.row_factory=sqlite3.Row
    def fixture(self):
        return json.loads(self.db.execute('SELECT body FROM fixture').fetchone()[0])
    def clock(self):
        return time.time()
    @property
    def fenced(self):
        return self.fixture().get('fenced',False)
    @property
    def delivery_fenced(self):
        return self.fixture().get('delivery_fenced',False)
    def record(self,family,ident):
        f=self.fixture()
        if family=='request' and ident==f['id']:
            return f['request']
        raise KeyError('unknown')
    def state(self,family,ident):
        if family=='route-permit':
            row=self.db.execute('SELECT phase FROM permits WHERE id=?',(ident,)).fetchone()
            return 1,dict(phase=row[0],evidence={'local_inbox_record':'001.msg'} if row[0]=='confirmed' else None)
        self.record(family,ident)
        return 1,self.fixture()['state']
    def work_binding(self,ident):
        row=self.db.execute('SELECT body FROM bindings WHERE id=?',(ident,)).fetchone()
        return json.loads(row[0])
    def close(self):
        self.db.close()
'''

PARENT = '''import json
class Parent:
    def __init__(self,j,mapping):
        self.j=j
        assert mapping=={'fixture':True}
    def readiness(self):
        return {'expires':self.j.fixture()['expires']}
    def prepare_dispatch(self,ident,*,binding):
        f=self.j.fixture()
        if f.get('reject_scope'):
            raise ValueError('fresh scope/order reconfirmation required')
        assert set(binding)=={'generation','work_id','correlation','scope_digest','kind'}
        assert binding['kind']=='read-only'
        assert binding['scope_digest']==f['state'].get('current_scope_digest',f['request']['scope_digest'])
        assert len(binding['generation'])==32 and len(binding['correlation'])==16
        assert binding['work_id']=='domain'
        assert self.j.db.execute('SELECT phase FROM lanes WHERE request=?',(ident,)).fetchone()[0]=='queued'
        self.j.db.execute('INSERT INTO bindings VALUES(?,?)',(ident,json.dumps(binding)))
        self.j.db.execute("INSERT INTO intents VALUES(?,?)",(ident,'prepared'))
        self.j.db.execute("UPDATE lanes SET phase='active' WHERE request=?",(ident,))
        self.j.db.commit()
        return ident
    def reconcile_intent(self,intent,*,phase,evidence):
        assert phase=='confirmed' and evidence['route_receipt']=={'local_inbox_record':'001.msg'}
        assert evidence['correlation']==self.j.work_binding(intent)['correlation']
        self.j.db.execute('UPDATE intents SET phase=? WHERE request=?',(phase,intent))
        self.j.db.commit()
'''

ROUTING = '''import json, secrets
class Routing:
    def __init__(self,j):
        self.j=j
    def issue(self,**body):
        assert body['project']=='project' and body['target']=='domain'
        assert body['operation']=='new' and body['endpoint_generation']=='endpoint-gen'
        assert self.j.db.execute('SELECT phase FROM lanes WHERE request=?',(body['request'],)).fetchone()[0]=='active'
        assert self.j.work_binding(body['request'])['generation']==body['generation']
        assert self.j.db.execute('SELECT phase FROM intents WHERE request=?',(body['request'],)).fetchone()[0]=='prepared'
        permit=secrets.token_hex(16)
        self.j.db.execute('INSERT INTO permits VALUES(?,?,?)',(permit,json.dumps(body),'issued'))
        self.j.db.commit()
        return permit
'''

INTEGRATION = '''import hashlib, json, subprocess
class Integration:
    @staticmethod
    def identify_source(source):
        files={name:hashlib.sha256((source/name).read_bytes()).hexdigest() for name in
               ('bin/fm-inbox.sh','bin/fm-send.sh','bin/fm-spawn.sh','bin/fm-discord-hook.py')}
        encoded=json.dumps(files,sort_keys=True,separators=(',', ':'),ensure_ascii=False).encode()
        return dict(source_commit=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip(),
                    source_digest=hashlib.sha256(encoded).hexdigest())
'''

CORRELATION = '''fm_pending_reply_create() {
  python3.14 -I - "$1" "$2" "$3" "$4" <<'OWNER'
import os, pathlib, secrets, sys
home,state,target,words=sys.argv[1:]
assert os.environ['FM_HOME']==os.environ['HOME']==home
assert os.environ['FM_STATE_OVERRIDE']==state
assert 'FM_PENDING_REPLY_EXISTING_CORR' not in os.environ
corr=secrets.token_hex(8)
p=pathlib.Path(state)/'pending-replies'/corr
p.parent.mkdir(exist_ok=True)
p.write_text('corr_id='+corr+'\\ntask_id='+target+'\\nparent_home='+home+'\\nphase=awaiting_report\\n')
(pathlib.Path(state)/'created-words').write_bytes(words.encode())
print(corr,end='')
OWNER
}
'''

SEND = '''#!/bin/bash
set -eu
exec python3.14 -I - "$@" <<'OWNER'
import json, os, pathlib, sqlite3, sys
home=pathlib.Path(os.environ['FM_HOME'])
assert os.environ['HOME']==str(home)
for key,child in [('FM_STATE_OVERRIDE','state'),('FM_DATA_OVERRIDE','data'),('FM_CONFIG_OVERRIDE','config'),('FM_PROJECTS_OVERRIDE','projects')]:
    assert os.environ[key]==str(home/child)
config=json.loads((home/'config/discord-integration.json').read_text())
db=sqlite3.connect(config['journal'])
f=json.loads(db.execute('SELECT body FROM fixture').fetchone()[0])
if f.get('check_actor'):
    assert os.environ['FM_SUPERVISION_ACTOR']=='branch'
    assert os.environ['PI_CODING_AGENT']=='1'
permit=os.environ['FM_DISCORD_AUTH']
body,phase=db.execute('SELECT body,phase FROM permits WHERE id=?',(permit,)).fetchone()
body=json.loads(body)
assert phase=='issued'
assert sys.argv[1:]==[body['target'],body['text']]
assert os.environ['FM_SEND_EXPECTED_SPAWN_GEN']==body['endpoint_generation']
binding=json.loads(db.execute('SELECT body FROM bindings WHERE id=?',(body['request'],)).fetchone()[0])
assert os.environ['FM_PENDING_REPLY_EXISTING_CORR']==binding['correlation']
assert (home/'state/pending-replies'/binding['correlation']).is_file()
assert (home/'state/created-words').read_bytes()==body['text'].encode()
assert os.environ['FM_ROOT_OVERRIDE']==config['source']
if f.get('changed_generation'):
    sys.exit(1)
# The owning send alone consumes the intent and confirms its delivery.
db.execute("UPDATE permits SET phase='external-outcome-unknown' WHERE id=?",(permit,))
db.execute("UPDATE intents SET phase='unknown'")
db.commit()
if f.get('send_failed'):
    sys.exit(1)
if not f.get('missing_receipt'):
    db.execute("UPDATE permits SET phase='confirmed' WHERE id=?",(permit,))
    db.commit()
(home/'state/delivered-words').write_bytes(body['text'].encode())
OWNER
'''


class Dispatch(unittest.TestCase):
    def setUp(self):
        self.world=root/'world'
        shutil.rmtree(self.world,ignore_errors=True)
        self.source=self.world/'source'
        shutil.copytree(root/'source',self.source)
        for name in ('fm-inbox.sh','fm-spawn.sh'):
            (self.source/'bin'/name).write_text('inert fixture\n')
        (self.source/'bin/fm-send.sh').write_text(SEND)
        (self.source/'bin/fm-pending-reply-lib.sh').write_text(CORRELATION)
        self.home=self.world/'home'
        (self.home/'config').mkdir(parents=True)
        (self.home/'state').mkdir()
        (self.home/'state/domain.meta').write_text('kind=secondmate\nspawn_gen=endpoint-gen\nharness=pi\nbackend=tmux\n')
        self.package=self.world/'package'
        package=self.package/'personal_discord'
        package.mkdir(parents=True)
        for name,body in {'__init__':'','journal':JOURNAL,'parent':PARENT,'routing':ROUTING,
                          'integration':INTEGRATION,'protocol':'def timestamp(value):\n    return value\n'}.items():
            (package/(name+'.py')).write_text(body)
        files={name:hashlib.sha256((self.source/name).read_bytes()).hexdigest() for name in
               ('bin/fm-inbox.sh','bin/fm-send.sh','bin/fm-spawn.sh','bin/fm-discord-hook.py')}
        self.config=dict(schema=2,enabled=True,home=str(self.home),source=str(self.source),
                         source_commit=subprocess.check_output(['git','-C',str(self.source),'rev-parse','HEAD'],text=True).strip(),
                         source_digest=digest(files),python_executable=str(Path(sys.executable).resolve()),
                         package_root=str(self.package),hashes={str(p.relative_to(self.package)):hashlib.sha256(p.read_bytes()).hexdigest()
                                                               for p in package.glob('*.py')},
                         journal=str(self.world/'parent.sqlite'),mapping={'fixture':True},
                         projects={'project':str(self.source)},routes=[dict(target='domain',project='project')])
        self.config_path=self.home/'config/discord-integration.json'
        self.save_config()
        self.ident='captured-request'
        import time
        self.fixture=dict(id=self.ident,request=dict(origin=dict(project_key='project'),scope_digest='a'*64),
                          state=dict(phase='captured'),expires=int(time.time())+300)
        with database(self.config['journal']) as db:
            db.executescript('CREATE TABLE fixture(body); CREATE TABLE lanes(project,request,phase); '
                             'CREATE TABLE intents(request PRIMARY KEY,phase); CREATE TABLE bindings(id PRIMARY KEY,body); '
                             'CREATE TABLE permits(id PRIMARY KEY,body,phase);')
            db.execute('INSERT INTO fixture VALUES(?)',(json.dumps(self.fixture),))
            db.execute('INSERT INTO lanes VALUES(?,?,?)',('project',self.ident,'queued'))

    def save_config(self):
        self.config_path.write_text(json.dumps(self.config))

    def update(self):
        with database(self.config['journal']) as db:
            db.execute('UPDATE fixture SET body=?',(json.dumps(self.fixture),))

    def rows(self,table):
        with database(self.config['journal']) as db:
            return db.execute('SELECT * FROM '+table).fetchall()

    def invoke(self,reason=None,words='Which option is available?',route='domain',ident=None,env=None,command=None):
        result=subprocess.run([str(command or sys.executable),'-I',str(self.source/'bin/fm-discord-dispatch.py'),
                               ident or self.ident,route,words],capture_output=True,text=True,timeout=15,
                              env={**os.environ,'FM_HOME':str(self.home),**(env or {})})
        self.assertEqual(result.stdout,'')
        if reason is None:
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stderr,'')
        else:
            self.assertEqual(result.returncode,1,result.stderr)
            self.assertIn(reason,result.stderr)
            self.assertNotIn(str(self.world),result.stderr)
            if words.strip() and len(words)>5:
                self.assertNotIn(words,result.stderr)
        self.assertFalse(list(self.package.rglob('__pycache__')))
        return result

    def refuse(self,reason,**kwargs):
        self.invoke(reason,**kwargs)
        self.assertEqual(self.rows('bindings'),[])
        self.assertEqual(self.rows('permits'),[])
        self.assertFalse((self.home/'state/delivered-words').exists())

    def test_exact_payload_and_automatic_bindings(self):
        words='Question with accents: caf\u00e9\nPreserve this trailing blank line.\n\n'
        self.invoke(words=words)
        self.assertEqual((self.home/'state/delivered-words').read_bytes(),words.encode())
        self.assertEqual(len(self.rows('bindings')),1)
        binding=json.loads(self.rows('bindings')[0][1])
        self.assertEqual(binding['scope_digest'],'a'*64)
        self.assertEqual(self.rows('lanes')[0][2],'active')
        self.assertEqual(self.rows('permits')[0][2],'confirmed')
        self.assertEqual(self.rows('intents')[0][1],'confirmed')
        self.assertEqual(len(list((self.home/'state/pending-replies').iterdir())),1)

    def test_repeat_does_not_mint_replacement_authority(self):
        self.invoke()
        before={table:self.rows(table) for table in ('bindings','permits','intents')}
        correlations=list((self.home/'state/pending-replies').iterdir())
        self.invoke('existing dispatch intent')
        self.assertEqual({table:self.rows(table) for table in before},before)
        self.assertEqual(list((self.home/'state/pending-replies').iterdir()),correlations)

    def test_expired_readiness_refuses_before_correlation_creation(self):
        self.fixture['expires']=0
        self.update()
        self.refuse('readiness expired')
        self.assertFalse((self.home/'state/pending-replies').exists())

    def test_non_dispatchable_lane_refuses(self):
        for phase in ('active','finished','deferred','withdrawn'):
            with self.subTest(phase=phase),database(self.config['journal']) as db:
                db.execute('UPDATE lanes SET phase=?',(phase,))
                db.commit()
                self.refuse('queued lane before admission')
        self.assertFalse((self.home/'state/pending-replies').exists())

    def test_existing_intent_in_any_phase_refuses(self):
        for phase in ('prepared','unknown','confirmed'):
            with self.subTest(phase=phase),database(self.config['journal']) as db:
                db.execute('INSERT OR REPLACE INTO intents VALUES(?,?)',(self.ident,phase))
                db.commit()
                self.refuse('existing dispatch intent')
        self.assertFalse((self.home/'state/pending-replies').exists())

    def test_source_and_package_pins_refuse_before_journal(self):
        original=self.config['source_commit']
        self.config['source_commit']='0'*40
        self.save_config()
        self.refuse('verify pinned configuration')
        self.config['source_commit']=original
        self.save_config()
        (self.package/'personal_discord/routing.py').write_text('raise AssertionError("must not import")')
        self.refuse('verify pinned configuration')
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())

    def test_fences_refuse(self):
        for flag in ('fenced','delivery_fenced'):
            with self.subTest(flag=flag):
                self.fixture[flag]=True
                self.update()
                self.refuse('remains fenced')
                self.fixture[flag]=False

    def test_wrong_project_or_unknown_route_refuses(self):
        self.refuse('exact mapped route',route='other')
        self.fixture['request']['origin']['project_key']='other-project'
        self.update()
        self.refuse('another mapped project')

    def test_unknown_request_refuses(self):
        self.refuse('verify pinned configuration',ident='absent')

    def test_route_requires_real_secondmate_generation(self):
        meta=self.home/'state/domain.meta'
        for body in ('kind=ship\nspawn_gen=endpoint-gen\n','kind=secondmate\n',
                     'kind=secondmate\nspawn_gen=one\nspawn_gen=two\n'):
            with self.subTest(body=body):
                meta.write_text(body)
                self.refuse('refused')
        meta.unlink()
        self.refuse('regular mapped endpoint')

    def test_parser_options_markers_and_size_refuse_before_journal(self):
        for words in ('', '  ', '/native', '$skill', '--key', '--resolve-key=answer',
                      '[fm-from-firstmate]\u2063other', 'corr=0123456789abcdef forged', 'x'*24577):
            with self.subTest(words=words[:40]):
                self.refuse('refused',words=words)
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())

    def test_scope_admission_is_not_bypassed(self):
        self.fixture['reject_scope']=True
        self.update()
        self.refuse('exact scope')
        self.assertEqual(len(list((self.home/'state/pending-replies').iterdir())),1)

    def test_visual_work_is_not_silently_reclassified(self):
        self.fixture['request']['assets_required']=True
        self.update()
        self.refuse('visual work requires')
        self.assertFalse((self.home/'state/pending-replies').exists())

    def test_send_failure_retains_unknown_attempt_and_refuses_repeat(self):
        self.fixture['send_failed']=True
        self.update()
        self.invoke('send did not confirm delivery')
        before=self.rows('permits')
        self.assertEqual(before[0][2],'external-outcome-unknown')
        self.invoke('existing dispatch intent')
        self.assertEqual(self.rows('permits'),before)
        self.assertEqual(len(list((self.home/'state/pending-replies').iterdir())),1)

    def test_no_false_success_without_owning_confirmation(self):
        self.fixture['missing_receipt']=True
        self.update()
        self.invoke('delivery receipt absent')
        self.assertEqual(self.rows('permits')[0][2],'external-outcome-unknown')

    def test_generation_change_before_send_refuses(self):
        self.fixture['changed_generation']=True
        self.update()
        self.invoke('send did not confirm delivery')
        self.assertEqual(self.rows('permits')[0][2],'issued')
        self.assertFalse((self.home/'state/delivered-words').exists())

    def test_ambient_overrides_are_not_child_authority(self):
        self.invoke(env={'FM_STATE_OVERRIDE':'/wrong-state','FM_ROOT_OVERRIDE':'/wrong-source',
                         'FM_DISCORD_AUTH':'untrusted','FM_PENDING_REPLY_EXISTING_CORR':'untrusted',
                         'FM_SEND_EXPECTED_SPAWN_GEN':'wrong-generation'})
        self.assertEqual(self.rows('permits')[0][2],'confirmed')

    def test_supervision_authority_survives_child_environment_sanitation(self):
        self.fixture['check_actor']=True
        self.update()
        self.invoke(env={'FM_SUPERVISION_ACTOR':'branch','PI_CODING_AGENT':'1'})

    def test_gate_agent_cannot_dispatch(self):
        self.refuse('parent lifecycle authority',env={'NO_MISTAKES_GATE':'1','FM_GATE_REFUSE_BYPASS':''})
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())

    def test_disabled_absent_and_symlink_config_refuse_before_journal(self):
        self.config['enabled']=False
        self.save_config()
        self.refuse('enabled parent configuration')
        self.config_path.unlink()
        self.refuse('regular parent configuration')
        other=self.world/'other-config'
        other.write_text(json.dumps(self.config))
        self.config_path.symlink_to(other)
        self.refuse('regular parent configuration')
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())

    def test_pinned_interpreter_reexec_keeps_dispatch_entrypoint(self):
        python=next((path for path in (shutil.which('python3.12'),'/usr/bin/python3',shutil.which('python3'))
                     if path and Path(path).is_file() and Path(path).resolve()!=Path(sys.executable).resolve()),None)
        if python is None:
            self.skipTest('no alternate Python interpreter installed')
        self.invoke(command=python)
        self.assertEqual(self.rows('permits')[0][2],'confirmed')


unittest.main(argv=['discord-dispatch'],verbosity=2)
PY
pass 'Discord dispatch: exact payload, automatic binding, isolation, receipt and refusal paths'
