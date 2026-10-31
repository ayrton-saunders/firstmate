#!/usr/bin/env python3
"""Assign a captured Discord question to a mapped second mate and send exact words.

Usage: FM_HOME=/absolute/parent-home python3 -I bin/fm-discord-dispatch.py REQUEST ROUTE 'Question'

Only the trusted parent invokes this after reviewing the captured request and
its exact scope. This surface reserves read-only question/decision work, not
coding approval, continuation, maintenance or public follow-up authority.
The route must be an existing mapped second mate with a recorded generation.
The private release owns lane admission, readiness and scope checks. The real
pending-reply owner creates the correlation; the command derives the remaining
binding and mints a one-use, payload-bound permit before invoking fm-send once.
No readiness renewal, launch, credential read or direct network call is made.
Successful dispatch is silent and requires the owning send's confirmed receipt.
Every repeat refuses: after any error reconcile the existing intent, permit and
correlation privately, never rerun blindly or mint replacement authority.
Leading parser/option prefixes, control markers and oversized words are refused
rather than reinterpreted. Payload bytes, including trailing newlines, are kept.
The configured private release and CPython 3.14 runtime must pass the existing
parent guard before journal access. No new source pin scheme is introduced.
Pre-flight: bin/fm-discord-verify-pins.py --help
Pin transition and snapshot limits: docs/discord-owner-reply-pins.md
"""
import importlib
import json
import os
from pathlib import Path
import re
import runpy
import secrets
import sqlite3
import subprocess
import sys


class Refusal(ValueError):
    """Public-safe local diagnostic, never private exception text."""


def require(condition, message):
    if not condition:
        raise Refusal(message)


def configuration(home):
    hook = runpy.run_path(str(Path(__file__).resolve().with_name('fm-discord-hook.py')))
    path = home / 'config/discord-integration.json'
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 65536,
            'enabled regular parent configuration required')
    config = json.loads(path.read_text(), object_pairs_hook=hook['unique'])
    require(isinstance(config, dict) and config.get('enabled') is True,
            'enabled parent configuration required')
    interpreter = Path(config['python_executable'])
    require(interpreter.is_absolute() and interpreter.is_file(), 'pinned parent interpreter required')
    if Path(sys.executable).resolve() != interpreter.resolve():
        os.execv(str(interpreter), [str(interpreter), '-I', str(Path(__file__).resolve()), *sys.argv[1:]])
    config = hook['load'](home)
    require(config is not None and 'mapping' in config, 'pinned parent mapping required')
    return config, hook['meta_value']


def dispatch(args):
    require(len(args) == 3, 'supply only the request, mapped route and exact words')
    ident, target, words = args
    require(all(re.fullmatch('[A-Za-z0-9._-]{1,96}', value) and not value.startswith('-')
                for value in (ident, target)), 'invalid request or mapped route identifier')
    require(words.strip() and len(words.encode('utf-8')) <= 24576 and '\x00' not in words,
            'nonempty words within the 24576-byte envelope required')
    require(not words.startswith(('/', '$', '-')) and '[fm-from-firstmate]' not in words
            and '\u2063' not in words and not re.search(r'corr=[A-Fa-f0-9]{16}', words),
            'ordinary words without parser prefixes or correlation markers required')
    require('FM_HOME' in os.environ and Path(os.environ['FM_HOME']).is_absolute(),
            'explicit absolute parent home required')
    home = Path(os.environ['FM_HOME']).resolve(strict=True)
    source = Path(__file__).resolve().parent.parent
    # Keep the owning gate-context guard, including its original environment,
    # before stripping ambient overrides for the lifecycle calls below.
    guard = subprocess.run(['/bin/bash', '-c', '. "$1"; fm_refuse_if_gate_agent', '_',
                            str(source / 'bin/fm-gate-refuse-lib.sh')],
                           capture_output=True, timeout=10)
    require(guard.returncode == 0, 'parent lifecycle authority required')
    config, meta_value = configuration(home)
    routes = [route for route in config['routes'] if route['target'] == target]
    require(len(routes) == 1, 'exact mapped route required')
    project = routes[0]['project']
    metadata = home / 'state' / (target + '.meta')
    require(metadata.is_file() and not metadata.is_symlink() and metadata.stat().st_size <= 65536,
            'existing regular mapped endpoint required')
    require(meta_value(metadata, 'kind') == 'secondmate', 'mapped second mate required for a correlated return')
    endpoint_generation = meta_value(metadata, 'spawn_gen')
    require(re.fullmatch('[A-Za-z0-9._-]{1,96}', endpoint_generation), 'recorded endpoint generation required')
    environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin',
                   'HOME': str(home), 'FM_HOME': str(home), 'FM_ROOT_OVERRIDE': str(source),
                   'FM_STATE_OVERRIDE': str(home / 'state'), 'FM_DATA_OVERRIDE': str(home / 'data'),
                   'FM_CONFIG_OVERRIDE': str(home / 'config'), 'FM_PROJECTS_OVERRIDE': str(home / 'projects'),
                   'TMPDIR': str(home / 'state'), 'GIT_TERMINAL_PROMPT': '0',
                   'PYTHONDONTWRITEBYTECODE': '1', 'LC_ALL': 'C'}
    # Keep gate and supervision authority signals, not routing/path overrides.
    # In particular a supervision branch must not become main after sanitation.
    for key in ('NO_MISTAKES_GATE', 'FM_SUPERVISION_ACTOR', 'PI_CODING_AGENT'):
        if key in os.environ:
            environment[key] = os.environ[key]
    journal_type = importlib.import_module('personal_discord.journal').Journal
    parent_type = importlib.import_module('personal_discord.parent').Parent
    routing_type = importlib.import_module('personal_discord.routing').Routing
    timestamp = importlib.import_module('personal_discord.protocol').timestamp
    journal = journal_type(config['journal'])
    try:
        require(not journal.fenced and not journal.delivery_fenced, 'parent intake or delivery remains fenced')
        parent = parent_type(journal, config['mapping'])
        request = journal.record('request', ident)
        _, state = journal.state('request', ident)
        require(request['origin']['project_key'] == project, 'request belongs to another mapped project')
        require(not journal.db.execute('SELECT 1 FROM intents WHERE request=?', (ident,)).fetchone(),
                'existing dispatch intent requires reconciliation')
        lane = journal.db.execute('SELECT project,phase FROM lanes WHERE request=?', (ident,)).fetchone()
        require(lane and lane['project'] == project and lane['phase'] == 'queued',
                'captured request must have its queued lane before admission')
        require(timestamp(parent.readiness()['expires']) > journal.clock(), 'parent readiness expired')
        require(not request.get('assets_required'), 'visual work requires its existing supported input procedure')
        # This is the lifecycle owner's API, not a fabricated custody file.
        result = subprocess.run(['/bin/bash', '-c', '. "$1"; fm_pending_reply_create "$2" "$3" "$4" "$5"',
                                 '_', str(source / 'bin/fm-pending-reply-lib.sh'), str(home),
                                 str(home / 'state'), target, words], env=environment, cwd=home,
                                capture_output=True, text=True, timeout=15)
        correlation = result.stdout
        require(result.returncode == 0 and re.fullmatch('[0-9a-f]{16}', correlation),
                'owning correlation creation failed; reconcile before retry')
        binding = {'generation': secrets.token_hex(16), 'work_id': target, 'correlation': correlation,
                   'scope_digest': state.get('current_scope_digest', request['scope_digest']), 'kind': 'read-only'}
        intent = parent.prepare_dispatch(ident, binding=binding)
        permit = routing_type(journal).issue(project=project, target=target, operation='new', text=words,
                                             request=ident, generation=binding['generation'],
                                             endpoint_generation=endpoint_generation)
        environment.update(FM_DISCORD_AUTH=permit, FM_SEND_EXPECTED_SPAWN_GEN=endpoint_generation,
                           FM_PENDING_REPLY_EXISTING_CORR=correlation)
        result = subprocess.run(['/bin/bash', str(source / 'bin/fm-send.sh'), target, words],
                                env=environment, cwd=home, capture_output=True, timeout=60)
        require(result.returncode == 0, 'owning send did not confirm delivery; reconcile before retry')
        receipt = journal.state('route-permit', permit)[1]
        require(receipt.get('phase') == 'confirmed' and receipt.get('evidence'),
                'owning delivery receipt absent; reconcile before retry')
        parent.reconcile_intent(intent, phase='confirmed',
                                evidence={'route_receipt': receipt['evidence'], 'correlation': correlation})
    finally:
        journal.close()


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    if sys.argv[1:] == ['--help']:
        print(__doc__)
        sys.exit(0)
    try:
        dispatch(sys.argv[1:])
    except Refusal as error:
        print('error: Discord dispatch refused: ' + str(error), file=sys.stderr)
        sys.exit(1)
    except (ValueError, KeyError, TypeError, ImportError, OSError, RuntimeError, sqlite3.Error,
            subprocess.SubprocessError):
        print('error: Discord dispatch refused: verify pinned configuration, readiness and exact scope; '
              'reconcile existing intent and correlation before retry', file=sys.stderr)
        sys.exit(1)
