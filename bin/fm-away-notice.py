#!/usr/bin/env python3
"""Typed outbound-only away reach, with no network or free-text publication API.

Usage: FM_HOME=/absolute/home python3 -I bin/fm-away-notice.py reach|drain|return
       ... report SEQUENCE TASK [decision|pr-ready]
`reach` optionally accepts the recorded enrollment hash for truthful read-back.
`report` runs AFTER durable outcome append on Pi, host, or legacy main; it checks
that exact captain outcome before deriving evidence, then drains eligible notices.
No kind means drain only. Call drain on subsequent handled wakes, not a new service.
Legacy daemon main may call report with an appended outcome reference; the daemon
itself never approves egress. No report summary is read into a notice.

Trusted config/away-reach.json: {"reach":"discord-private","domain":"personal"}.
Absent configuration or reach=none is off. Never derive selectors from away words.
config/discord/<domain>/away-notices.json is separately approved local enrollment:
{"schema":1,"enabled":true,"private_owner_only":true,"mapping":{...},
 "projects":{"key":{"alias":"Personal","repository":"owner/repo",
                     "sensitive":false}}}.
Mapping must exactly match one integration mapping; all projects must be enrolled
integration projects. Alias permits ASCII letters/digits/spaces/hyphens, 1-48 chars.
Sensitive defaults true; an unassociated decision always gets the generic template.
No enrollment or private-ACL claim is created by this command.

Small slice-1 boundary: enrolled personal_discord.private_notice exports
CAPABILITY='private-notice-v1', available(config=...) -> True only after full-path
capability negotiation, approve(config=..., notice=...) -> exactly
{notice_id: same ID, state: owed|delivered|stopped}. Approval is immutable/idempotent
and reprojects existing custody/egress; only receipt closure means delivered.
Notice fields are exactly notice_id, identity, origin, template, project_alias,
pr_url. Identity is mapping_revision+task+hold lifecycle, or mapping_revision+
pr_url+head+ready state. No raw content field is accepted. Slice 1 renders:
pr-ready: 'The {alias} work is ready for review: {pr_url} . Review it in our usual conversation.'
decision: 'A decision is waiting for the {alias} work. Please review it in our usual conversation.'
sensitive-decision: 'A decision is waiting. Please review it in our usual conversation.'
All mentions and previews are disabled by slice 1. Never solicit Discord approval.

state/away-notices.sqlite3 owns independent immutable approvals, bounded failures
(last 20, fixed codes only), and per-destination attempts. SQLite serializes drains.
First approval immediately; one new approval/30s, ten/600s. Excess stays queued;
current local hold/forge evidence is rechecked before approval. Existing approval
reconciliation is not new traffic: transport owns retry-after/ambiguous POSTs.
Changed/revoked enrollment stops unsent notices, never retargets; explicit disposal
is operator work. Terminal rows retain dedupe across restarts. Nothing here changes
outcome cursors, captain holds, work release, inbox notes or away posture.
"""
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


class Unavailable(ValueError):
    pass


def require(condition):
    if not condition:
        raise Unavailable('reach unavailable')


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))


def read_json(path):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 65536)
    return json.loads(path.read_text(), object_pairs_hook=HOOK['unique'])


def run(args):
    return subprocess.run(args, capture_output=True, text=True, timeout=20)


def local_config(home):
    path = home / 'config/away-reach.json'
    if not path.exists():
        raise Unavailable('reach unavailable')
    selection = read_json(path)
    require(selection.get('reach') == 'discord-private' and set(selection) == {'reach', 'domain'})
    domain = selection['domain']
    require(isinstance(domain, str) and re.fullmatch('[a-z][a-z0-9-]{0,47}', domain))
    require('FM_DISCORD_DOMAIN' not in os.environ or os.environ['FM_DISCORD_DOMAIN'] == domain)
    os.environ['FM_DISCORD_DOMAIN'] = domain
    config = HOOK['load'](home, routing_only=True)
    enrollment = read_json(home / 'config/discord' / domain / 'away-notices.json')
    require(set(enrollment) == {'schema', 'enabled', 'private_owner_only', 'mapping', 'projects'}
            and enrollment['schema'] == 1 and enrollment['enabled'] is True
            and enrollment['private_owner_only'] is True)
    mapping = enrollment['mapping']
    require(isinstance(mapping, dict) and set(mapping) == FIELDS
            and re.fullmatch('[A-Za-z0-9._-]{1,96}', mapping['mapping_revision']))
    mappings = config['mapping'] if isinstance(config['mapping'], list) else [config['mapping']]
    require(sum(mapping == item for item in mappings) == 1)
    require(isinstance(enrollment['projects'], dict))
    for key, project in enrollment['projects'].items():
        require(key in config['projects'] and set(project) <= {'alias', 'repository', 'sensitive'}
                and {'alias', 'repository'} <= set(project)
                and re.fullmatch('[A-Za-z0-9][A-Za-z0-9 -]{0,47}', project['alias'])
                and re.fullmatch('[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', project['repository'])
                and type(project.get('sensitive', True)) is bool)
    return config, enrollment


def transport(home):
    guard = run(['bash', '-c', '. "$1"; fm_refuse_if_gate_agent', '_', str(ROOT / 'fm-gate-refuse-lib.sh')])
    require(guard.returncode == 0)
    config, enrollment = local_config(home)
    # configuration re-execs THIS entrypoint into the pinned interpreter and
    # imports only the enrolled release. Actor provenance stays in the environment.
    config = REPLY['configuration'](home, entrypoint=Path(__file__).resolve())
    api = importlib.import_module('personal_discord.private_notice')
    require(api.CAPABILITY == 'private-notice-v1' and api.available(config=config) is True)
    return config, enrollment, api


def away(home):
    result = run(['bash', str(ROOT / 'fm-afk-contract.sh'), 'mode'])
    return result.returncode == 0 and result.stdout.strip() == 'away'


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


def evidence(home, task, kind, config, enrollment):
    require(re.fullmatch('[A-Za-z0-9._-]{1,96}', task) and task != 'fleet')
    fields = meta(home, task)
    projects = [key for key, root in config['projects'].items() if fields.get('project') == root]
    project = enrollment['projects'].get(projects[0]) if len(projects) == 1 else None
    revision = enrollment['mapping']['mapping_revision']
    if kind == 'decision':
        result = run(['bash', str(ROOT / 'fm-captain-hold.sh'), 'open', task, '--identity'])
        if result.returncode == 1:
            return None
        require(result.returncode == 0 and re.fullmatch(r'[^\r\n]+#[0-9]+\n?', result.stdout))
        identity = {'mapping_revision': revision, 'task': task, 'hold': result.stdout.strip()}
        sensitive = project is None or project.get('sensitive', True)
        return identity, 'sensitive-decision' if sensitive else 'decision', '' if sensitive else project['alias'], ''
    require(kind == 'pr-ready' and project is not None)
    url = fields.get('pr', '')
    require(re.fullmatch('https://github\\.com/' + re.escape(project['repository']) + r'/pull/[1-9][0-9]*', url))
    # The recorded URL is never constructed from model text. Query current head
    # and ready state on every send, including delayed sends after a restart.
    result = run(['gh-axi', 'api', '/repos/' + project['repository'] + '/pulls/' + url.rsplit('/', 1)[1],
                  '--jq', '{url:.html_url,state:.state,isDraft:.draft,headRefOid:.head.sha}|tojson'])
    require(result.returncode == 0)
    pr = json.loads(result.stdout)
    require(pr['url'] == url and re.fullmatch('[0-9a-f]{40,64}', pr['headRefOid']))
    if pr['state'] != 'open' or pr['isDraft'] is not False:
        return None
    require(fields.get('pr_head') == pr['headRefOid'])
    if run(['gh-axi', 'pr', 'checks', url]).returncode != 0:
        return None
    identity = {'mapping_revision': revision, 'pr_url': url, 'head': pr['headRefOid'], 'ready': True}
    if project.get('sensitive', True):
        return identity, 'sensitive-decision', '', ''
    return identity, 'pr-ready', project['alias'], url


def database(home):
    path = home / 'state/away-notices.sqlite3'
    path.parent.mkdir(parents=True, exist_ok=True)
    require(not path.is_symlink())
    db = sqlite3.connect(path, timeout=5)
    db.executescript('''
      CREATE TABLE IF NOT EXISTS notices(id TEXT PRIMARY KEY, task TEXT, kind TEXT,
        payload TEXT, destination TEXT, state TEXT, attempted INTEGER);
      CREATE TABLE IF NOT EXISTS failures(epoch INTEGER, code TEXT);
    ''')
    os.chmod(path, 0o600)
    return db


def failure(db, code):
    db.execute('INSERT INTO failures VALUES (?,?)', (int(time.time()), code))
    db.execute('DELETE FROM failures WHERE rowid NOT IN (SELECT rowid FROM failures ORDER BY rowid DESC LIMIT 20)')


def payload_for(current, enrollment):
    identity, template, alias, url = current
    ident = hashlib.sha256(canonical(identity).encode()).hexdigest()
    return {'notice_id': ident, 'identity': identity, 'origin': enrollment['mapping'],
            'template': template, 'project_alias': alias, 'pr_url': url}


def outcome(home, seq, task):
    require(re.fullmatch('[1-9][0-9]*', seq))
    result = run(['bash', str(ROOT / 'fm-branch-outcome.sh'), 'lookup', '--seqs', seq])
    require(result.returncode == 0)
    row = json.loads(result.stdout)
    require(row['task'] == task and row['verdict'] == 'captain' and not row.get('silent', False))


def drain(home, config, enrollment, api, db):
    now = int(time.time())
    deadline = time.monotonic() + 40
    # Enrollment snapshots include disclosure policy as well as destination.
    binding = canonical(enrollment)
    for ident, task, kind, encoded, dest, state, attempted in db.execute(
            "SELECT * FROM notices WHERE state IN ('queued','owed') ORDER BY rowid").fetchall():
        if time.monotonic() >= deadline:
            break
        payload = json.loads(encoded)
        if dest != binding or not away(home):
            db.execute("UPDATE notices SET state='stopped' WHERE id=?", (ident,))
            failure(db, 'enrollment-or-posture-changed')
            continue
        if state == 'queued':
            try:
                current = evidence(home, task, kind, config, enrollment)
            except Exception:
                failure(db, 'current-evidence-unavailable')
                continue
            if current is None or payload_for(current, enrollment) != payload:
                db.execute("UPDATE notices SET state='suppressed' WHERE id=?", (ident,))
                continue
            destination_fields = ('bridge_id', 'owner_id', 'guild_id', 'parent_channel_id')
            attempts = [stamp for previous, stamp in db.execute(
                'SELECT payload,attempted FROM notices WHERE attempted IS NOT NULL AND attempted>?', (now - 600,))
                if all(json.loads(previous)['origin'][key] == enrollment['mapping'][key] for key in destination_fields)]
            if attempts and (max(attempts) > now - 30 or len(attempts) >= 10):
                continue
            # Persist the immutable intent BEFORE the external boundary. A crash
            # replays the same approval, never allocates a new transport identity.
            db.execute("UPDATE notices SET state='owed', attempted=? WHERE id=?", (now, ident))
            db.commit()
            db.execute('BEGIN IMMEDIATE')
        # This is a local journal boundary, not a network delivery call.
        # Bound a malfunctioning mixed release without copying its diagnostics.
        def timed_out(_signum, _frame):
            raise TimeoutError('private notice boundary timeout')
        prior = signal.signal(signal.SIGALRM, timed_out)
        signal.alarm(10)
        try:
            receipt = api.approve(config=config, notice=payload)
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, prior)
        require(isinstance(receipt, dict) and set(receipt) == {'notice_id', 'state'}
                and receipt['notice_id'] == ident and receipt['state'] in ('owed', 'delivered', 'stopped'))
        db.execute('UPDATE notices SET state=? WHERE id=?', (receipt['state'], ident))
        if receipt['state'] == 'stopped':
            failure(db, 'transport-stopped')


def main(args):
    if args == ['--help']:
        print(__doc__)
        return
    require('FM_HOME' in os.environ and Path(os.environ['FM_HOME']).is_absolute())
    home = Path(os.environ['FM_HOME']).resolve(strict=True)
    require(args and args[0] in ('reach', 'report', 'drain', 'return'))
    if args[0] == 'return':
        path = home / 'state/away-notices.sqlite3'
        if path.exists():
            db = database(home)
            count = db.execute('SELECT count(*) FROM failures').fetchone()[0]
            pending = db.execute("SELECT count(*) FROM notices WHERE state != 'delivered'").fetchone()[0]
            print(f'Private reach: {count} retained failure(s), {pending} notice(s) not confirmed delivered; decisions still await the usual conversation.')
        return
    if args[0] == 'reach':
        try:
            config, enrollment, api = transport(home)
            require(len(args) == 1 or len(args) == 2 and args[1]
                    == hashlib.sha256(canonical(enrollment).encode()).hexdigest())
            print('discord-private')
            print(enrollment['mapping']['mapping_revision'])
            print('Private Discord notifications configured, not proof of delivery; decisions still wait for return.')
            print(hashlib.sha256(canonical(enrollment).encode()).hexdigest())
        except Exception:
            print('none\n-\nReach unavailable; hold-for-return only.')
        return
    if not away(home):
        return
    # Off means no journal, no package and no publication, even on an old record.
    try:
        local_config(home)
    except Exception:
        selected = run(['bash', str(ROOT / 'fm-afk-contract.sh'), 'field', 'reach_channels'])
        if selected.stdout.strip() == 'discord-private':
            with database(home) as db:
                db.execute("UPDATE notices SET state='stopped' WHERE state='queued'")
                failure(db, 'reach-configuration-unavailable')
        return
    db = database(home)
    try:
        config, enrollment, api = transport(home)
        recorded = run(['bash', str(ROOT / 'fm-afk-contract.sh'), 'field', 'reach_binding'])
        selected = run(['bash', str(ROOT / 'fm-afk-contract.sh'), 'field', 'reach_channels'])
        if selected.stdout.strip() != 'discord-private' or recorded.stdout.strip() != hashlib.sha256(canonical(enrollment).encode()).hexdigest():
            db.execute("UPDATE notices SET state='stopped' WHERE state='queued'")
            failure(db, 'recorded-reach-binding-unavailable')
            db.commit()
            return
        db.execute('BEGIN IMMEDIATE')
        if args[0] == 'report':
            require(len(args) in (3, 4))
            seq, task = args[1:3]
            if len(args) == 4:
                outcome(home, seq, task)
                current = evidence(home, task, args[3], config, enrollment)
                if current is not None:
                    payload = payload_for(current, enrollment)
                    db.execute('INSERT OR IGNORE INTO notices VALUES (?,?,?,?,?,?,NULL)',
                               (payload['notice_id'], task, args[3], canonical(payload), canonical(enrollment), 'queued'))
        else:
            require(len(args) == 1)
        drain(home, config, enrollment, api, db)
        db.commit()
    except Exception:
        # Never copy exception messages, subprocess stderr or private payloads.
        failure(db, 'approval-or-evidence-unavailable')
        db.commit()
    finally:
        db.close()


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except Exception:
        print('Private reach unavailable; durable outcomes and hold-for-return are unchanged.', file=sys.stderr)
        sys.exit(1)
