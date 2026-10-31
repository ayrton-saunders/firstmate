#!/usr/bin/env python3
"""Publish one parent-approved Discord final from an authoritative correlated return.

Usage: FM_HOME=/absolute/parent-home python3 -I bin/fm-discord-reply.py REQUEST ROUTE 'Approved answer.'

Only the trusted parent invokes this command after reviewing the actual return.
REQUEST is the captured request identifier; ROUTE is a configured mapped target.
The words are an explicitly approved, single-line customer answer, not raw worker
output. Generation, correlation, scope and the stable final event identifier are
derived from existing custody and work records, never supplied by the caller.
No readiness renewal, dispatch, synthetic return, credential read or network call
is performed. Publication uses the pinned private release's approval API and its
local egress projection; transport delivery is separate and is not claimed here.
Successful publication is silent. An identical repeat repairs the same event;
changed words cannot replace an already approved final. After any error, inspect
the existing approval before retrying; never invent another event identifier.
The shared gate-agent guard runs before configuration or journal access; its
existing disposable-lab exception remains owned by fm-gate-refuse-lib.sh.
The enabled home configuration, source pins, package hashes and CPython 3.14
runtime must then pass the existing parent guard before any journal is opened.
Pre-flight: bin/fm-discord-verify-pins.py --help
Pin transition and snapshot limits: docs/discord-owner-reply-pins.md
"""
import importlib
import json
import os
from pathlib import Path
import re
import runpy
import sqlite3
import subprocess
import sys


class Refusal(ValueError):
    """Public-safe diagnostic selected locally, never private exception text."""


def require(condition, message):
    if not condition:
        raise Refusal(message)


def configuration(home):
    # Reuse the owning guard, without changing its lifecycle hash or executing
    # its main. Select the pinned interpreter here so its re-exec cannot switch
    # this command into the hook's CLI with unrelated arguments.
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
    require(config is not None and {'mapping', 'ingress', 'egress'} <= set(config),
            'pinned parent publication mapping required')
    return config


def resolved_return(home, binding):
    correlation = binding['correlation']
    require(isinstance(correlation, str) and re.fullmatch('[0-9a-f]{16}', correlation),
            'existing parent correlation required')
    record = home / 'state/pending-replies' / correlation
    require(record.is_file() and not record.is_symlink() and record.stat().st_size <= 65536,
            'authoritative correlated return absent')
    fields = {}
    for line in record.read_text().splitlines():
        key, sep, value = line.partition('=')
        if sep:
            require(key not in fields, 'ambiguous correlated return')
            fields[key] = value
    require(fields.get('corr_id') == correlation and fields.get('task_id') == binding['work_id']
            and fields.get('parent_home') == str(home), 'return belongs to another route or home')
    require(fields.get('phase') == 'resolved', 'authoritative correlated return is not resolved')


def reply(args):
    require(len(args) == 3, 'supply only the request, mapped route and approved answer')
    ident, target, words = args
    require(all(re.fullmatch('[A-Za-z0-9._-]{1,96}', value) for value in (ident, target)),
            'invalid request or mapped route identifier')
    require(words.strip() and len(words.encode('utf-8')) <= 400
            and not any(ord(char) < 32 or ord(char) == 127 or char in '\u2028\u2029' for char in words),
            'approved answer must be one nonempty line of at most 400 UTF-8 bytes')
    require('FM_HOME' in os.environ and Path(os.environ['FM_HOME']).is_absolute(),
            'explicit absolute parent home required')
    home = Path(os.environ['FM_HOME']).resolve(strict=True)
    source = Path(__file__).resolve().parent.parent
    guard = subprocess.run(['/bin/bash', '-c', '. "$1"; fm_refuse_if_gate_agent', '_',
                            str(source / 'bin/fm-gate-refuse-lib.sh')],
                           capture_output=True, timeout=10)
    require(guard.returncode == 0, 'parent lifecycle authority required')
    config = configuration(home)
    routes = [route for route in config['routes'] if route['target'] == target]
    require(len(routes) == 1, 'exact mapped route required')
    journal_type = importlib.import_module('personal_discord.journal').Journal
    digest = importlib.import_module('personal_discord.journal').digest
    parent_type = importlib.import_module('personal_discord.parent').Parent
    integration_type = importlib.import_module('personal_discord.integration').Integration
    journal = journal_type(config['journal'])
    try:
        require(not journal.fenced and not journal.delivery_fenced, 'parent intake or delivery remains fenced')
        request = journal.record('request', ident)
        revision, state = journal.state('request', ident)
        binding = journal.work_binding(ident)
        require(request['origin']['project_key'] == routes[0]['project'] and binding['work_id'] == target,
                'request is not bound to this mapped route')
        require(state.get('generation') == binding['generation'], 'current work generation mismatch')
        scope = state.get('current_scope_digest', request['scope_digest'])
        require(binding['scope_digest'] == scope, 'accepted scope binding mismatch')
        lane = journal.db.execute('SELECT project,phase FROM lanes WHERE request=?', (ident,)).fetchone()
        require(lane and lane['project'] == routes[0]['project']
                and lane['phase'] in ('active', 'finished'), 'request lane is not active or finished')
        resolved_return(home, binding)
        event_id = 'final.' + digest({'request': ident, 'generation': binding['generation'],
                                      'correlation': binding['correlation']})
        environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin',
                       'HOME': str(home), 'FM_HOME': str(home), 'FM_ROOT_OVERRIDE': str(home),
                       'FM_STATE_OVERRIDE': str(home / 'state'), 'FM_DATA_OVERRIDE': str(home / 'data'),
                       'FM_CONFIG_OVERRIDE': str(home / 'config'), 'FM_PROJECTS_OVERRIDE': str(home / 'projects'),
                       'TMPDIR': str(home / 'state'), 'GIT_TERMINAL_PROMPT': '0',
                       'PYTHONDONTWRITEBYTECODE': '1', 'LC_ALL': 'C'}
        for key in ('NO_MISTAKES_GATE', 'FM_SUPERVISION_ACTOR', 'PI_CODING_AGENT'):
            if key in os.environ:
                environment[key] = os.environ[key]
        egress = journal_type(config['egress'])
        try:
            integration = integration_type(parent_type(journal, config['mapping']), config['ingress'], egress,
                                           source=config['source'], home=home, environment=environment)
            result = integration.approve_update(ident, event_id=event_id, generation=binding['generation'],
                                                correlation=binding['correlation'], revision=revision,
                                                safe_text=words, kind='final', terminal=True, approved=True)
            require(result.get('published') is True, 'approved final is not yet published; reconcile before retry')
        finally:
            egress.close()
    finally:
        journal.close()


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    if sys.argv[1:] == ['--help']:
        print(__doc__)
        sys.exit(0)
    try:
        reply(sys.argv[1:])
    except Refusal as error:
        print('error: Discord reply refused: ' + str(error), file=sys.stderr)
        sys.exit(1)
    except (ValueError, KeyError, TypeError, ImportError, OSError, RuntimeError, sqlite3.Error,
            subprocess.SubprocessError):
        print('error: Discord reply refused: verify pinned configuration and existing approval; '
              'reconcile before retry', file=sys.stderr)
        sys.exit(1)
