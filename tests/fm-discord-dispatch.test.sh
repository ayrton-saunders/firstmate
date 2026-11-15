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
import shlex
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
        if family=='route-permit':
            row=self.db.execute('SELECT body FROM permits WHERE id=?',(ident,)).fetchone()
            if row:
                return json.loads(row[0])
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
        assert mapping==self.j.fixture().get('mapping',{'fixture':True})
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
        assert binding['work_id']==f.get('target','domain')
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
        assert body['project']==self.j.fixture()['request']['origin']['project_key']
        assert body['target']==self.j.fixture().get('target','domain')
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
prefix=target+'-' if 'FM_DISCORD_DOMAIN' in os.environ else ''
(pathlib.Path(state)/(prefix+'created-words')).write_bytes(words.encode())
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
path=home/'config/discord'/os.environ['FM_DISCORD_DOMAIN']/'integration.json' if 'FM_DISCORD_DOMAIN' in os.environ else home/'config/discord-integration.json'
config=json.loads(path.read_text())
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
prefix=body['target']+'-' if 'FM_DISCORD_DOMAIN' in os.environ else ''
assert (home/'state'/(prefix+'created-words')).read_bytes()==body['text'].encode()
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
(home/'state'/(prefix+'delivered-words')).write_bytes(body['text'].encode())
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
        # Production deliberately sanitizes PATH; fixture owners use the discovered
        # interpreter, including installations outside the production PATH.
        (self.source/'bin/fm-send.sh').write_text(SEND.replace('python3.14', shlex.quote(sys.executable)))
        (self.source/'bin/fm-pending-reply-lib.sh').write_text(CORRELATION.replace('python3.14', shlex.quote(sys.executable)))
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
                         package_root=str(self.package),
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

    def test_missing_bound_domain_never_falls_back_to_legacy(self):
        self.invoke('Bound domain configuration required', env={'FM_DISCORD_DOMAIN':'pristine-valets'})
        self.assertEqual(self.rows('intents'), [])

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
            (self.home/'state'/(target+'.meta')).write_text('kind=secondmate\nspawn_gen=endpoint-gen\n')
            shutil.copyfile(self.config['journal'], config['journal'])
            fixture = copy.deepcopy(self.fixture)
            fixture.update(mapping=config['mapping'], target=target)
            fixture['request']['origin'] = dict(config['mapping'], thread_id=str(index+10), source_message_id='100')
            with database(config['journal']) as db:
                db.execute('UPDATE fixture SET body=?', (json.dumps(fixture),))
            configs[domain] = config
        return configs

    def domain_call(self, domain, config, words):
        return subprocess.run([sys.executable, '-I', str(self.source/'bin/fm-discord-dispatch.py'),
                               self.ident, config['routes'][0]['target'], words],
                              env={**os.environ, 'FM_HOME':str(self.home), 'FM_DISCORD_DOMAIN':domain},
                              capture_output=True, text=True, timeout=15)

    def test_two_bound_domains_concurrent_and_legacy_route_unchanged(self):
        from concurrent.futures import ThreadPoolExecutor
        configs = self.domain_configs()
        before = self.config_path.read_bytes()
        with ThreadPoolExecutor() as executor:
            jobs = [executor.submit(self.domain_call, domain, config, 'Only '+domain+' reviewed question')
                    for domain, config in configs.items()]
            for job in jobs:
                result = job.result()
                self.assertEqual(result.returncode, 0, result.stderr)
        correlations = set()
        for domain, config in configs.items():
            with database(config['journal']) as db:
                body = json.loads(db.execute('SELECT body FROM permits').fetchone()[0])
                binding = json.loads(db.execute('SELECT body FROM bindings').fetchone()[0])
                self.assertEqual(body['text'], 'Only '+domain+' reviewed question')
                self.assertEqual(body['target'], domain+'-mate')
                record = self.home/'state/pending-replies'/binding['correlation']
                self.assertIn('task_id='+domain+'-mate', record.read_text())
                correlations.add(binding['correlation'])
        self.assertEqual(len(correlations), 2)
        self.assertEqual(self.rows('intents'), [])
        self.assertEqual(self.config_path.read_bytes(), before)
        self.invoke()  # The still-global personal/Galagoa route is unchanged.

    def test_existing_personal_galagoa_mapping_remains_global_without_selector(self):
        configs = self.domain_configs()
        mapping = dict(bridge_id='personal-discord-galagoa', project_key='galagoa', mapping_revision='pilot-v1',
                       owner_id='owner', guild_id='existing-guild', parent_channel_id='existing-channel')
        self.config.update(mapping=mapping, projects={'galagoa':str(self.source)},
                           routes=[dict(target='domain', project='galagoa')])
        self.fixture['mapping'] = mapping
        self.fixture['request']['origin'] = mapping
        self.save_config()
        self.update()
        with database(self.config['journal']) as db:
            db.execute("UPDATE lanes SET project='galagoa'")
        before = self.config_path.read_bytes()
        self.invoke()
        self.assertEqual(self.config_path.read_bytes(), before)
        permit = json.loads(self.rows('permits')[0][1])
        self.assertEqual((permit['project'], permit['target']), ('galagoa', 'domain'))
        for config in configs.values():
            self.assertFalse(Path(config['journal']).with_suffix('.opened').exists())

    def test_bound_dispatch_refuses_foreign_origins_in_both_directions(self):
        configs = self.domain_configs()
        for domain, config in configs.items():
            other = next(value for key, value in configs.items() if key != domain)
            with database(config['journal']) as db:
                fixture = json.loads(db.execute('SELECT body FROM fixture').fetchone()[0])
                fixture['request']['origin'] = other['mapping']
                db.execute('UPDATE fixture SET body=?', (json.dumps(fixture),))
            result = self.domain_call(domain, config, 'Not authorized')
            self.assertEqual(result.returncode, 1)
            self.assertIn('Request origin belongs to another bound domain', result.stderr)
            with database(config['journal']) as db:
                self.assertEqual(db.execute('SELECT * FROM intents').fetchall(), [])
        self.assertFalse((self.home/'state/pending-replies').exists())

    def test_bound_domain_refuses_shared_mate_and_foreign_state(self):
        configs = self.domain_configs()
        domain, config = next(iter(configs.items()))
        path = self.home/'config/discord'/domain/'integration.json'
        original = json.loads(path.read_text())
        for key, value, message in (
                ('routes', self.config['routes'], 'separate mapped mates'),
                ('egress', self.config['journal'], 'writable path belongs to another domain'),
                ('domain', 'foreign', 'domain/root mismatch')):
            path.write_text(json.dumps(dict(original, **{key:value})))
            result = self.domain_call(domain, config, 'Not authorized')
            self.assertEqual(result.returncode, 1)
            self.assertIn(message, result.stderr)
            self.assertFalse(Path(config['journal']).with_suffix('.opened').exists())
        path.write_text(json.dumps(original))

    def test_hook_cannot_consume_or_confirm_another_domains_permit(self):
        configs = self.domain_configs()
        permits = {}
        for domain, config in configs.items():
            result = self.domain_call(domain, config, 'Only '+domain+' question')
            self.assertEqual(result.returncode, 0, result.stderr)
            with database(config['journal']) as db:
                permits[domain] = db.execute('SELECT id,body,phase FROM permits').fetchone()
        for domain, config in configs.items():
            foreign = next(value for key, value in permits.items() if key != domain)
            target = config['routes'][0]['target']
            for copied in (False, True):
                if copied:
                    with database(config['journal']) as db:
                        db.execute('INSERT INTO permits VALUES(?,?,?)', foreign)
                for operation in (['send', target, target, str(self.home/'state'/(target+'.meta')), 'tmux'],
                                  ['confirm-send', 'local', '001.msg']):
                    result = subprocess.run([sys.executable, '-I', str(self.source/'bin/fm-discord-hook.py'), *operation],
                                            input='Only reviewed words', text=True, capture_output=True,
                                            env={**os.environ, 'FM_HOME':str(self.home), 'FM_DISCORD_DOMAIN':domain,
                                                 'FM_DISCORD_AUTH':foreign[0]})
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn('another bound route' if copied else 'Route permit lookup failed', result.stderr)
            with database(config['journal']) as db:
                self.assertEqual(db.execute('SELECT id,body,phase FROM permits WHERE id=?',
                                            (permits[domain][0],)).fetchone(), permits[domain])

    def test_domain_hook_refuses_cross_route_and_invalid_local_bindings(self):
        configs = self.domain_configs()
        (self.source/'bin/fm-backend.sh').write_text('fm_backend_target_matches_meta() { return 1; }\n')
        for domain, config in configs.items():
            other = next(value for key, value in configs.items() if key != domain)
            target = config['routes'][0]['target']
            foreign = other['routes'][0]['target']
            for route, authority, message in ((target, {}, None),
                    (foreign, {'FM_DISCORD_AUTH':'a'*32}, 'unmapped route')):
                result = subprocess.run([sys.executable, '-I', str(self.source/'bin/fm-discord-hook.py'),
                                         'send', route, route, str(self.home/'state'/(route+'.meta')), 'tmux'],
                                        input='Only reviewed local words', text=True, capture_output=True,
                                        env={**os.environ, 'FM_HOME':str(self.home), 'FM_DISCORD_DOMAIN':domain, **authority})
                self.assertEqual(result.returncode, int(message is not None), result.stderr)
                if message:
                    self.assertIn(message, result.stderr)
            self.assertFalse(Path(config['journal']).with_suffix('.opened').exists())
        for domain in ('', '../galagoa-new', '/galagoa-new', 'Galagoa', 'x'*49):
            self.invoke('Invalid trusted domain binding', env={'FM_DISCORD_DOMAIN':domain})
        domain, config = next(iter(configs.items()))
        path = self.home/'config/discord'/domain/'integration.json'
        path.write_text(json.dumps(dict(config, enabled=False)))
        self.invoke('enabled parent configuration required', env={'FM_DISCORD_DOMAIN':domain})
        path.unlink()
        path.symlink_to(self.config_path)
        self.invoke('Bound domain configuration required', env={'FM_DISCORD_DOMAIN':domain})

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

    def test_source_status_fields_are_optional_and_do_not_fence(self):
        self.config['source_commit']='old'
        self.config.pop('source_digest')
        self.save_config()
        self.invoke()

    def test_escaping_package_root_refuses_before_import_or_journal(self):
        (self.package/'personal_discord/routing.py').write_text('raise AssertionError("must not import")')
        (self.world/'code').mkdir()
        (self.world/'code/current').symlink_to(self.package)
        self.config['package_root']=str(self.world/'code/current')
        self.save_config()
        self.refuse('canonical release inside the enrolled code tree')
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())

    def test_home_binding_refuses_by_check_name_before_journal(self):
        self.config['home']='/private/wrong-home'
        self.save_config()
        self.refuse('Integration schema/home mismatch')
        self.assertFalse(Path(self.config['journal']).with_suffix('.opened').exists())

    def test_duplicate_configuration_refuses_by_check_name(self):
        self.config_path.write_text('{"enabled":true,"enabled":false}')
        self.refuse('Duplicate configuration field')
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
        self.refuse('Captured request lookup failed',ident='absent')

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
