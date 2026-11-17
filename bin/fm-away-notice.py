#!/usr/bin/env python3
"""Typed outbound-only away reach; no network or free-text publication surface.

Usage: FM_HOME=/absolute/home python3 -I bin/fm-away-notice.py reach [BINDING]
       ... report SEQUENCE TASK [decision|pr-ready]
       ... drain|return
Report runs after durable outcome append on Pi, host or legacy main.
No kind means drain only.
Existing supervision wakes drain this journal; this is not a scheduler or reasoning session.

Trusted config/away-reach.json selects {"reach":"discord-private","domain":"personal"}
or {"reach":"none"}; absent selection is off. Away prose selects nothing.
config/discord/<domain>/away-notices.json is separately reviewed enrollment:
{"schema":1,"enabled":true,"private_owner_only":true,"mapping":{...},
 "projects":{"key":{"alias":"Personal","repository":"owner/repo","sensitive":false}}}.
Mapping contains the six immutable integration origin fields. The integration's
matching mapping must additionally enroll private_notices owner_only, aliases and
HTTPS repositories. Aliases start with an ASCII letter, then letters/digits/spaces/
hyphens, at most 64 characters. Exact GitHub PR URLs have 1-10 decimal digits.
Sensitive defaults true; unassociated decisions use the generic template.
Selection and reviewed binding are recorded independently of delivery health.

The merged slice-1 personal_discord.private_notice facade exports
CAPABILITY='private-notice-v1'. available(config=...) checks configuration only.
approve(config=..., notice=...) accepts notice_id, mapping_id, template_id,
approved=True, and only fields used by that template. mapping_id comes from
personal_discord.mappings.mapping_id of the original trusted enrolled mapping.
Lifecycle identity stays fork-local; no origin, identity, body, error, transcript,
attachment or raw report crosses the facade. Templates are decision-waiting
(project_alias), sensitive-decision (no extra fields), and pr-ready (project_alias,
pr_url). Slice 1 owns fixed wording, mention/preview suppression and all transport.
state(config=..., notice_id=..., mapping_id=...) reconciles confirmed obligations
without approving again. withdraw takes those same arguments plus reason exactly
resolved, superseded, enrollment-revoked or away-ended. State and withdrawal remain
usable after capability disablement/retirement. All receipts are exactly
{notice_id: same ID, state: owed|delivered|stopped}; owed is never delivery proof.
Withdrawal returning owed is unresolved, not disposal. Confirmed delivery survives
withdrawal. These local facade calls never post to Discord; transport never approves.

state/away-notices.sqlite3 stores delivery bookkeeping independently of outcomes.
The lifecycle, recovery, rate limits and read-back health contract are owned by
../docs/away-notice/interface.md; this header owns invocation, enrollment and facade mechanics.
"""
from contextlib import closing
import csv
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import runpy
import signal
import sqlite3
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
HOOK = runpy.run_path(str(ROOT / 'fm-discord-hook.py'))
REPLY = runpy.run_path(str(ROOT / 'fm-discord-reply.py'))
FIELDS = {'bridge_id', 'owner_id', 'guild_id', 'parent_channel_id', 'mapping_revision', 'project_key'}
LIVE = "('queued','uncertain','owed','reconcile')"


class Unavailable(ValueError):
    pass


class Invalidated(ValueError):
    pass


def require(condition):
    if not condition:
        raise Unavailable('reach unavailable')


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def read_json(path):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 65536)
    return json.loads(path.read_text(), object_pairs_hook=HOOK['unique'])


def run(args):
    return subprocess.run(args, capture_output=True, text=True, timeout=20)


def selection(home):
    path = home / 'config/away-reach.json'
    try:
        path.lstat()
    except FileNotFoundError:
        return None
    value = read_json(path)
    if value == {'reach': 'none'}:
        return False
    require(set(value) == {'reach', 'domain'} and value['reach'] == 'discord-private'
            and isinstance(value['domain'], str)
            and re.fullmatch('[a-z][a-z0-9-]{0,47}', value['domain']))
    return value['domain']


def bind_domain(domain):
    require('FM_DISCORD_DOMAIN' not in os.environ or os.environ['FM_DISCORD_DOMAIN'] == domain)
    os.environ['FM_DISCORD_DOMAIN'] = domain


def target(home, domain):
    bind_domain(domain)
    config = HOOK['load'](home, routing_only=True)
    enrolled = read_json(home / 'config/discord' / domain / 'away-notices.json')
    require(set(enrolled) == {'schema', 'enabled', 'private_owner_only', 'mapping', 'projects'}
            and enrolled['schema'] == 1 and type(enrolled['enabled']) is bool
            and type(enrolled['private_owner_only']) is bool)
    if not enrolled['private_owner_only']:
        raise Invalidated('enrollment-revoked')
    mapping = enrolled['mapping']
    require(isinstance(mapping, dict) and set(mapping) == FIELDS)
    mappings = config['mapping'] if isinstance(config['mapping'], list) else [config['mapping']]
    matches = [item for item in mappings if all(item.get(key) == mapping[key] for key in FIELDS)]
    if not enrolled['enabled'] or not matches or matches[0].get('retired') is True:
        raise Invalidated('enrollment-revoked')
    require(len(matches) == 1)
    private = matches[0].get('private_notices')
    if private is None:
        raise Invalidated('enrollment-revoked')
    require(isinstance(private, dict) and set(private) == {'owner_only', 'aliases', 'repositories'}
            and type(private['owner_only']) is bool and isinstance(private['aliases'], list)
            and isinstance(private['repositories'], list))
    if not private['owner_only']:
        raise Invalidated('enrollment-revoked')
    require(isinstance(enrolled['projects'], dict))
    for key, project in enrolled['projects'].items():
        require(key in config['projects'] and set(project) <= {'alias', 'repository', 'sensitive'}
                and {'alias', 'repository'} <= set(project)
                and re.fullmatch('[A-Za-z][A-Za-z0-9 -]{0,63}', project['alias'])
                and re.fullmatch('[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+', project['repository'])
                and project['repository'].split('/')[1] not in ('.', '..')
                and type(project.get('sensitive', True)) is bool)
        if (project['alias'] not in private['aliases']
                or 'https://github.com/' + project['repository'] not in private['repositories']):
            raise Invalidated('enrollment-revoked')
    return {'domain': domain, 'enrollment': enrolled, 'mapping': matches[0],
            'roots': config['projects'], 'journal': config['journal']}


def parent(home, original):
    bind_domain(original['domain'])
    guard = run(['bash', '-c', '. "$1"; fm_refuse_if_gate_agent', '_', str(ROOT / 'fm-gate-refuse-lib.sh')])
    require(guard.returncode == 0)
    config = REPLY['configuration'](home, entrypoint=Path(__file__).resolve())
    require(config['journal'] == original['journal'])
    api = importlib.import_module('personal_discord.private_notice')
    mappings = importlib.import_module('personal_discord.mappings')
    require(api.CAPABILITY == 'private-notice-v1')
    return config, api, mappings.mapping_id(original['mapping'])


def away(home):
    result = run(['bash', str(ROOT / 'fm-afk-contract.sh'), 'mode'])
    return result.returncode == 0 and result.stdout.strip() == 'away'


def field(home, name):
    result = run(['bash', str(ROOT / 'fm-afk-contract.sh'), 'field', name])
    require(result.returncode == 0)
    return result.stdout.strip()


def meta(home, task):
    path = home / 'state' / (task + '.meta')
    if not path.exists():
        return {}
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 65536)
    fields = {}
    for line in path.read_text().splitlines():
        key, sep, value = line.partition('=')
        if sep:
            require(key not in fields)
            fields[key] = value
    return fields


def pr_identity(repository, number):
    result = run(['gh-axi', 'api', '/repos/' + repository + '/pulls/' + number,
                  '--jq', '[.html_url,.state,(.draft|tostring),.head.sha]|@tsv'])
    require(result.returncode == 0 and len(result.stdout.splitlines()) == 1)
    values = result.stdout.splitlines()[0].split('\t')
    require(len(values) == 4)
    pr = dict(zip(('url', 'state', 'isDraft', 'headRefOid'), values))
    require(re.fullmatch('[0-9a-f]{40,64}', pr['headRefOid'])
            and pr['state'] in ('open', 'closed') and pr['isDraft'] in ('true', 'false'))
    return pr


def expected_context(output, rollup):
    """EXPECTED is not ready even though gh-axi classifies it as skip."""
    count = int(rollup[1] or 0)
    if not count:
        return False
    rows = output[rollup.end():].splitlines()[1:]
    if rollup[2]:
        names = rollup[2].split(',')
        if 'state' not in names:
            return False
        require('__typename' in names and len(rows) >= count)
        for line in rows[:count]:
            require(line.startswith('    '))
            values = next(csv.reader([line[4:]], escapechar='\\'))
            require(len(values) == len(names))
            if values[names.index('__typename')] == 'StatusContext' and values[names.index('state')] == 'EXPECTED':
                return True
        return False
    items = [line for line in rows if line.startswith('    - ')]
    require(len(items) == count and all(line in ('    - __typename: CheckRun', '    - __typename: StatusContext') for line in items))
    context = False
    for line in rows:
        if line.startswith('    - '):
            context = line == '    - __typename: StatusContext'
        elif context and line == '      state: EXPECTED':
            return True
    return False


def evidence(home, row, original):
    fields = meta(home, row['task'])
    enrolled = original['enrollment']
    projects = [key for key, root in original['roots'].items() if fields.get('project') == root]
    project = enrolled['projects'].get(projects[0]) if len(projects) == 1 else None
    previous = json.loads(row['identity']) if row['identity'] else None
    if row['kind'] == 'decision':
        result = run(['bash', str(ROOT / 'fm-captain-hold.sh'), 'open', row['task'], '--identity'])
        if result.returncode == 1:
            raise Invalidated('resolved')
        require(result.returncode == 0 and re.fullmatch(r'[^\r\n]+#[0-9]+\n?', result.stdout))
        identity = {'task': row['task'], 'hold': result.stdout.strip()}
        if previous is not None and identity != previous:
            raise Invalidated('superseded')
        if project is None or project.get('sensitive', True):
            return identity, {'template_id': 'sensitive-decision'}
        return identity, {'template_id': 'decision-waiting', 'project_alias': project['alias']}
    require(project is not None)
    url = fields.get('pr', '')
    require(re.fullmatch('https://github\\.com/' + re.escape(project['repository']) + r'/pull/[1-9][0-9]{0,9}', url))
    require(re.fullmatch('[0-9a-f]{40,64}', fields.get('pr_head', '')))
    if previous is not None and (url != previous['pr_url'] or fields['pr_head'] != previous['head']):
        raise Invalidated('superseded')
    number, repository = url.rsplit('/', 1)[1], project['repository']
    pr = pr_identity(repository, number)
    require(pr['url'] == url)
    if pr['state'] != 'open' or pr['isDraft'] == 'true' or fields['pr_head'] != pr['headRefOid']:
        raise Invalidated('superseded')
    identity = {'pr_url': url, 'head': pr['headRefOid'], 'ready': True}
    if previous is not None and identity != previous:
        raise Invalidated('superseded')
    result = run(['gh-axi', 'pr', 'view', number, '-R', repository, '--fields', 'headRefOid,statusCheckRollup'])
    require(result.returncode == 0 and result.stdout.startswith('pull_request:\n'))
    # gh-axi uses inline [] for an empty rollup. Keep exactly one header and
    # retain raw EXPECTED evidence, which its normalized buckets call skip.
    heads = re.findall(r'^  headRefOid: ("?)([0-9a-f]{40,64})\1$', result.stdout, re.MULTILINE)
    rollups = list(re.finditer(r'^  statusCheckRollup(?:\[([0-9]+)\](?:\{([A-Za-z0-9_,]+)\})?:|: \[\])$', result.stdout, re.MULTILINE))
    require(len(heads) == len(rollups) == 1)
    if heads[0][1] != pr['headRefOid']:
        raise Invalidated('superseded')
    not_ready = expected_context(result.stdout, rollups[0])
    if int(rollups[0][1] or 0):
        result = run(['gh-axi', 'pr', 'checks', number, '-R', repository])
        require(result.returncode in (0, 1, 8))
        lines = result.stdout.splitlines()
        tables = [(index, re.fullmatch(r'checks\[([0-9]+)\]\{name,conclusion\}:', line))
                  for index, line in enumerate(lines) if line.startswith('checks[')]
        require(len(tables) == 1 and tables[0][1] is not None)
        index, table = tables[0]
        count = int(table[1])
        rows = lines[index + 1:index + 1 + count]
        require(count > 0 and len(rows) == count and all(line.startswith('  ') and ',' in line for line in rows))
        states = [line.rsplit(',', 1)[1] for line in rows]
        require(all(state in ('pass', 'fail', 'skip', 'cancel', 'pending') for state in states))
        not_ready = not_ready or any(state in ('fail', 'cancel', 'pending') for state in states)
        # gh-axi exits 0 for pass/skip/cancel; cancellation is still not ready
        # under the pre-F1 policy. Query errors without a table stay temporary.
        require(result.returncode == (1 if 'fail' in states else 8 if 'pending' in states else 0))
        confirmed = pr_identity(repository, number)
        require(confirmed['url'] == url and confirmed['headRefOid'] == pr['headRefOid'])
    if not_ready and row['state'] != 'queued':
        raise Invalidated('superseded')
    require(not not_ready)
    if project.get('sensitive', True):
        return identity, {'template_id': 'sensitive-decision'}
    return identity, {'template_id': 'pr-ready', 'project_alias': project['alias'], 'pr_url': url}


def database(home):
    path = home / 'state/away-notices.sqlite3'
    path.parent.mkdir(parents=True, exist_ok=True)
    require(not path.is_symlink())
    db = sqlite3.connect(path, timeout=5)
    db.row_factory = sqlite3.Row
    columns = {row['name'] for row in db.execute('PRAGMA table_info(notices)')}
    require(not columns or 'target' in columns)
    db.executescript('''
      CREATE TABLE IF NOT EXISTS notices(id TEXT PRIMARY KEY, seq TEXT, task TEXT, kind TEXT,
        target TEXT NOT NULL, identity TEXT, proposal TEXT, notice_id TEXT UNIQUE,
        state TEXT NOT NULL, error TEXT, reason TEXT);
      CREATE TABLE IF NOT EXISTS failures(epoch INTEGER, code TEXT);
      CREATE TABLE IF NOT EXISTS attempts(destination TEXT, epoch INTEGER);
    ''')
    os.chmod(path, 0o600)
    return db


def failure(db, row, code):
    db.execute('UPDATE notices SET error=? WHERE id=?', (code, row['id']))
    db.execute('INSERT INTO failures VALUES (?,?)', (int(time.time()), code))
    db.execute('DELETE FROM failures WHERE rowid NOT IN (SELECT rowid FROM failures ORDER BY rowid DESC LIMIT 20)')


def outcome(home, row):
    result = run(['bash', str(ROOT / 'fm-branch-outcome.sh'), 'lookup', '--seqs', row['seq']])
    require(result.returncode == 0)
    value = json.loads(result.stdout)
    require(value['task'] == row['task'] and value['verdict'] == 'captain' and not value.get('silent', False))


def boundary(api, operation, config, expected_id, **kwargs):
    def timed_out(_signum, _frame):
        raise TimeoutError('private notice boundary timeout')
    prior = signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(10)
    try:
        receipt = getattr(api, operation)(config=config, **kwargs)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, prior)
    require(isinstance(receipt, dict) and set(receipt) == {'notice_id', 'state'}
            and receipt['notice_id'] == expected_id and receipt['state'] in ('owed', 'delivered', 'stopped'))
    return receipt['state']


def settle(db, row, state):
    db.execute('UPDATE notices SET state=?,error=NULL WHERE id=?', (state, row['id']))


def withdraw(home, db, row, original, reason):
    if row['state'] == 'queued':
        settle(db, row, 'withdrawn')
        return
    db.execute("UPDATE notices SET state='reconcile',reason=? WHERE id=?", (reason, row['id']))
    db.commit()
    db.execute('BEGIN IMMEDIATE')
    try:
        config, api, mapping_id = parent(home, original)
        result = boundary(api, 'withdraw', config, row['notice_id'],
                          notice_id=row['notice_id'], mapping_id=mapping_id, reason=reason)
        require(result != 'owed')
        settle(db, row, 'delivered' if result == 'delivered' else 'withdrawn')
    except Exception:
        failure(db, row, 'withdrawal-reconciliation-required')


def drain_row(home, db, row, returning):
    original = json.loads(row['target'])
    reason = 'away-ended' if returning or not away(home) else row['reason']
    if reason:
        withdraw(home, db, row, original, reason)
        return
    try:
        domain = selection(home)
        if not domain or 'domain' in original and domain != original['domain']:
            raise Invalidated('enrollment-revoked')
        current = target(home, domain)
        binding = original.get('binding', digest(original))
        if digest(current) != binding:
            raise Invalidated('enrollment-revoked')
        if field(home, 'reach_channels') != 'discord-private' or field(home, 'reach_binding') != binding:
            raise Invalidated('enrollment-revoked')
        original = current
        db.execute('UPDATE notices SET target=? WHERE id=?', (canonical(original), row['id']))
        if row['state'] == 'queued':
            outcome(home, row)
        identity, template = evidence(home, row, original)
        config, api, mapping_id = parent(home, original)
        if row['state'] in ('owed', 'reconcile'):
            result = boundary(api, 'state', config, row['notice_id'], notice_id=row['notice_id'], mapping_id=mapping_id)
        else:
            require(api.available(config=config) is True)
            ident = digest({'mapping_id': mapping_id, 'identity': identity})
            proposal = {'notice_id': ident, 'mapping_id': mapping_id, 'approved': True, **template}
            if row['proposal']:
                require(json.loads(row['proposal']) == proposal)
            else:
                old = db.execute('SELECT id FROM notices WHERE notice_id=?', (ident,)).fetchone()
                if old and old['id'] != row['id']:
                    settle(db, row, 'withdrawn')
                    return
                db.execute('UPDATE notices SET identity=?,proposal=?,notice_id=?,error=NULL WHERE id=?',
                           (canonical(identity), canonical(proposal), ident, row['id']))
            now = int(time.time())
            destination = canonical({key: original['mapping'][key] for key in
                                     ('bridge_id', 'owner_id', 'guild_id', 'parent_channel_id')})
            stamps = [value[0] for value in db.execute('SELECT epoch FROM attempts WHERE destination=? AND epoch>?',
                                                     (destination, now - 600))]
            if stamps and (max(stamps) > now - 30 or len(stamps) >= 10):
                if row['state'] == 'queued':
                    db.execute('UPDATE notices SET error=NULL WHERE id=?', (row['id'],))
                return
            db.execute("UPDATE notices SET state='uncertain' WHERE id=?", (row['id'],))
            db.execute('INSERT INTO attempts VALUES (?,?)', (destination, now))
            db.execute('DELETE FROM attempts WHERE epoch<=?', (now - 600,))
            db.commit()
            db.execute('BEGIN IMMEDIATE')
            result = boundary(api, 'approve', config, ident, notice=proposal)
        if result == 'stopped':
            db.execute("UPDATE notices SET state='reconcile',reason=NULL WHERE id=?", (row['id'],))
            failure(db, row, 'transport-stopped')
        else:
            settle(db, row, result)
    except Invalidated as error:
        withdraw(home, db, row, original, str(error))
    except Exception:
        failure(db, row, 'evidence-or-parent-unavailable')


def drain(home, db, returning=False):
    db.commit()
    rows = db.execute('SELECT * FROM notices WHERE state IN ' + LIVE + ' ORDER BY rowid').fetchall()
    for row in rows:
        try:
            result = subprocess.run([sys.executable, '-I', str(Path(__file__).resolve()),
                                     '_row', row['id'], 'return' if returning else 'drain'],
                                    capture_output=True, text=True, timeout=90)
            require(result.returncode == 0)
        except Exception:
            db.execute('BEGIN IMMEDIATE')
            failure(db, row, 'row-runtime-unavailable')
            db.commit()


def reach(home, expected=None):
    domain = selection(home)
    if not domain:
        print('none\n-\nReach unavailable; hold-for-return only.\n-')
        return
    original = None
    healthy = False
    try:
        original = target(home, domain)
        require(expected is None or expected == digest(original))
        config, api, _mapping_id = parent(home, original)
        require(api.available(config=config) is True)
        if (home / 'state/away-notices.sqlite3').exists():
            with closing(database(home)) as db:
                require(db.execute("SELECT count(*) FROM notices WHERE state IN " + LIVE +
                                   " AND (error IS NOT NULL OR state IN ('uncertain','reconcile'))").fetchone()[0] == 0)
        healthy = True
    except Exception:
        pass
    print('discord-private')
    print(original['mapping']['mapping_revision'] if original else '-')
    print('Private Discord notifications configured, not proof of delivery; decisions still wait for return.'
          if healthy else 'Reach unavailable; hold-for-return only.')
    print(digest(original) if original else '-')


def main(args):
    if args == ['--help']:
        print(__doc__)
        return
    require('FM_HOME' in os.environ and Path(os.environ['FM_HOME']).is_absolute())
    home = Path(os.environ['FM_HOME']).resolve(strict=True)
    if args and args[0] == '_row':
        require(len(args) == 3 and re.fullmatch('[0-9a-f]{64}', args[1]) and args[2] in ('drain', 'return'))
        with closing(database(home)) as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT * FROM notices WHERE id=? AND state IN ' + LIVE, (args[1],)).fetchone()
            if row:
                drain_row(home, db, row, args[2] == 'return')
            db.commit()
        return
    require(args and args[0] in ('reach', 'report', 'drain', 'return'))
    if args[0] == 'reach':
        require(len(args) in (1, 2))
        reach(home, args[1] if len(args) == 2 else None)
        return
    require(args[0] == 'report' and len(args) in (3, 4) or args[0] != 'report' and len(args) == 1)
    path = home / 'state/away-notices.sqlite3'
    binding = None
    if args[0] == 'report' and len(args) == 4:
        seq, task, kind = args[1:]
        require(re.fullmatch('[1-9][0-9]*', seq) and re.fullmatch('[A-Za-z0-9._-]{1,96}', task)
                and task != 'fleet' and kind in ('decision', 'pr-ready'))
        if away(home) and field(home, 'reach_channels') == 'discord-private':
            binding = field(home, 'reach_binding')
    if not path.exists() and binding is None:
        return
    db = database(home)
    try:
        db.execute('BEGIN IMMEDIATE')
        if binding is not None:
            recorded = {'binding': binding}
            ident = digest({'seq': seq, 'task': task, 'kind': kind, 'target': recorded})
            db.execute('INSERT OR IGNORE INTO notices(id,seq,task,kind,target,state) VALUES (?,?,?,?,?,?)',
                       (ident, seq, task, kind, canonical(recorded), 'queued'))
            db.commit()
            db.execute('BEGIN IMMEDIATE')
        drain(home, db, returning=args[0] == 'return')
        if args[0] == 'return':
            count = db.execute('SELECT count(*) FROM failures').fetchone()[0]
            failed = db.execute('SELECT count(*) FROM notices WHERE state IN ' + LIVE +
                                ' AND error IS NOT NULL').fetchone()[0]
            pending = db.execute('SELECT count(*) FROM notices WHERE state IN ' + LIVE).fetchone()[0]
            reconciliation = db.execute("SELECT count(*) FROM notices WHERE state='reconcile'").fetchone()[0]
            withdrawn = db.execute("SELECT count(*) FROM notices WHERE state='withdrawn'").fetchone()[0]
            delivered = db.execute("SELECT count(*) FROM notices WHERE state='delivered'").fetchone()[0]
            print(f'Private reach: {count} retained failure(s), {failed} current failure(s), '
                  f'{reconciliation} withdrawal(s) needing reconciliation, {pending} pending notice(s), '
                  f'{withdrawn} withdrawn, {delivered} confirmed delivered; '
                  'decisions still await the usual conversation.')
    finally:
        db.close()


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except Exception:
        print('Private reach unavailable; durable outcomes and hold-for-return are unchanged.', file=sys.stderr)
        sys.exit(1)
