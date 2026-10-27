#!/usr/bin/env python3
"""Optional mapped-route parent lane guard, no Discord/SSH/model access.

Usage: fm-discord-hook.py send <raw-target> <resolved-target> <meta-or-empty> <backend>
       fm-discord-hook.py spawn <task-id> <canonical-project-directory>
       fm-discord-hook.py capacity-deferred <task-id> <canonical-project-directory>
       fm-discord-hook.py ready|outcome <note-id>|confirm-send local|remote <receipt>
The spawn owner calls capacity-deferred only after proving exit 75 before launch;
it records retryable no-launch evidence without consuming dispatch authority.
Exact pre-marker message (send) or brief SHA256 (spawn) arrives on stdin.
FM_HOME selects the invoking parent home, as in the owning lifecycle script.
Absent config/discord-integration.json preserves legacy behavior.
An enabled config binds schema=2, canonical home, private package root and hashes,
parent journal, routes [{target,project}], projects {canonical key:absolute root}.
FM_DISCORD_AUTH names a parent-issued one-use permit, never a transport claim.
No success is returned after consuming a permit until its transaction commits.
Consumed permits are deliberately not retryable without lifecycle reconciliation.
The local parent issues permits through the pinned integration release's admin API.
"""
import hashlib
import importlib
import json
import os
import sqlite3
import subprocess
from pathlib import Path
import sys


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate configuration field')
        result[key] = value
    return result


def load(home):
    path = home / 'config/discord-integration.json'
    if not path.exists():
        return None
    if path.is_symlink() or path.stat().st_size > 65536:
        raise ValueError('Invalid integration configuration file')
    config = json.loads(path.read_text(), object_pairs_hook=unique)
    if not isinstance(config, dict) or type(config.get('enabled')) is not bool:
        raise ValueError('Malformed integration enablement')
    if not config['enabled']:
        return None
    fields = {'schema', 'enabled', 'home', 'package_root', 'hashes', 'journal', 'routes', 'projects',
              'python_executable', 'source', 'source_commit', 'source_digest'}
    optional = {'mapping', 'ingress', 'egress', 'assets'}
    if not fields <= set(config) or set(config) - fields - optional or config['schema'] != 2 or config['home'] != str(home):
        raise ValueError('Integration schema/home mismatch')
    interpreter = Path(config['python_executable'])
    if not interpreter.is_absolute() or not interpreter.is_file():
        raise ValueError('Pinned existing parent interpreter required')
    if Path(sys.executable).resolve() != interpreter.resolve():
        os.execv(str(interpreter), [str(interpreter), '-I', str(Path(__file__).resolve()), *sys.argv[1:]])
    if sys.version_info[:2] != (3, 14):
        raise ValueError('Reviewed parent CPython 3.14 runtime required')
    sys.dont_write_bytecode = True
    package = Path(config['package_root'])
    if not package.is_absolute() or package.resolve() != package:
        raise ValueError('Integration package root must be pinned canonical absolute path')
    files = {str(item.relative_to(package)): hashlib.sha256(item.read_bytes()).hexdigest()
             for item in (package / 'personal_discord').glob('*.py') if not item.is_symlink()}
    if not files or files != config['hashes']:
        raise ValueError('Integration release hash mismatch')
    if (not Path(config['journal']).is_absolute() or not config['routes'] or not config['projects']
            or any(not isinstance(root, str) or not Path(root).is_absolute() for root in config['projects'].values())):
        raise ValueError('Integration journal/routes/projects missing')
    if (any(not isinstance(route, dict) for route in config['routes'])
            or len({route.get('target') for route in config['routes']}) != len(config['routes'])):
        raise ValueError('Ambiguous mapped route identity')
    for route in config['routes']:
        if set(route) != {'target', 'project'} or route['project'] not in config['projects']:
            raise ValueError('Invalid explicit integration mapping')
        if not route['target'] or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for c in route['target']):
            raise ValueError('Invalid mapped route identity')
    source = Path(__file__).resolve().parent.parent
    if str(source) != config['source']:
        raise ValueError('Invoked source differs from the approved parent release')
    sys.path.insert(0, str(package))
    identity = importlib.import_module('personal_discord.integration').Integration.identify_source(source)
    if identity != {key: config[key] for key in ('source_commit', 'source_digest')}:
        raise ValueError('Approved parent source commit/digest changed')
    return config


def meta_value(path, key):
    values = [line.split('=', 1)[1] for line in path.read_text().splitlines()
              if line.startswith(key + '=')]
    if len(values) > 1:
        raise ValueError('Conflicting runtime identity')
    return values[0] if values else ''


def guard(args):
    home = Path(os.environ['FM_HOME']).resolve(strict=True)
    config = load(home)
    if config is None:
        return
    if not args or args[0] not in ('send', 'spawn', 'capacity-deferred', 'outcome', 'ready', 'confirm-send'):
        raise ValueError('Unknown hook operation')
    if args[0] == 'confirm-send':
        if len(args) != 3 or args[1] not in ('local', 'remote'):
            raise ValueError('Exact owning delivery receipt required')
        journal_type = importlib.import_module('personal_discord.journal').Journal
        routing_type = importlib.import_module('personal_discord.routing').Routing
        journal = journal_type(config['journal'])
        try:
            permit = os.environ.get('FM_DISCORD_AUTH', '')
            body = journal.record('route-permit', permit)
            if args[1] == 'local':
                receipt = Path(args[2])
                expected = home / 'state' / (body['target'] + '.inbox')
                if receipt.parent.resolve() != expected.resolve() or not receipt.name.endswith('.msg') or not receipt.stem.isdigit():
                    raise ValueError('Receipt is not in the exact mapped task inbox')
                actual = receipt if receipt.is_file() else expected / 'handled' / receipt.name
                if not actual.is_file() or actual.is_symlink():
                    raise ValueError('Durable owning inbox receipt absent')
                evidence = {'local_inbox_record': receipt.name}
            else:
                if not args[2] or len(args[2]) > 96:
                    raise ValueError('Exact remote correlation/delivery identity required')
                evidence = {'remote_enqueue_confirmed': True, 'delivery_identity': args[2]}
            routing_type(journal).confirm(permit, evidence=evidence)
        finally:
            journal.close()
        return
    if args[0] == 'ready':
        if len(args) != 1 or 'mapping' not in config:
            raise ValueError('Pinned parent mapping required to renew readiness')
        journal_type = importlib.import_module('personal_discord.journal').Journal
        parent_type = importlib.import_module('personal_discord.parent').Parent
        journal = journal_type(config['journal'])
        try:
            parent_type(journal, config['mapping']).renew_readiness(primary_identity=parent_type.primary_identity(home))
        finally:
            journal.close()
        return
    if args[0] == 'outcome':
        if len(args) != 2:
            raise ValueError('Exact inbox note identity required')
        journal_type = importlib.import_module('personal_discord.journal').Journal
        journal = journal_type(config['journal'])
        try:
            reply_digest = sys.stdin.read(65)
            if len(reply_digest) != 64 or any(c not in '0123456789abcdef' for c in reply_digest):
                raise ValueError('Exact terminal reply digest required')
            for row in journal.db.execute("SELECT id FROM records WHERE family='request'"):
                _, state = journal.state('request', row['id'])
                if state.get('note_id') == args[1]:
                    with journal.transaction():
                        journal.put('pending-final', row['id'],
                                    {'note_id': args[1], 'reply_digest': reply_digest,
                                     'generation': state.get('note_generation', state.get('generation', 'preacceptance'))})
        finally:
            journal.close()
        return
    project = None
    target = None
    generation = ''
    if args[0] == 'send' and len(args) == 5:
        _, raw, resolved, metadata, candidate_backend = args
        for route in config['routes']:
            route_id = route['target']
            path = home / f'state/{route_id}.meta'
            direct = raw in (route_id, 'fm-' + route_id)
            matches = False
            if not direct and path.exists():
                backend = Path(__file__).resolve().parent / 'fm-backend.sh'
                result = subprocess.run(['/bin/bash', '-c', '. "$1"; fm_backend_target_matches_meta "$2" "$3" "$4"',
                                         '_', str(backend), candidate_backend, resolved, str(path)],
                                        text=True, capture_output=True, timeout=5)
                if result.returncode not in (0, 1):
                    raise ValueError('Mapped backend target could not be resolved')
                matches = result.returncode == 0
            if direct or matches:
                if not direct or not metadata or Path(metadata).resolve() != path.resolve():
                    raise ValueError('Explicit-terminal text cannot bypass the mapped parent route')
                project, target = route['project'], route_id
                generation = meta_value(path, 'spawn_gen')
                break
    elif args[0] in ('spawn', 'capacity-deferred') and len(args) == 3:
        _, target, project_path = args
        def common(path):
            result = subprocess.run(['/usr/bin/git', '-C', str(path), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                                    capture_output=True, text=True, timeout=5,
                                    env={'PATH': '/usr/bin:/bin', 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_SYSTEM': '/dev/null'})
            return result.stdout.strip() if result.returncode == 0 else None
        candidate_common = common(project_path)
        for key, root in config['projects'].items():
            root_common = common(root)
            if (Path(project_path).resolve() == Path(root).resolve()
                    or candidate_common and root_common and candidate_common == root_common):
                project = key
                break
    else:
        raise ValueError('Invalid hook arguments')
    if project is None:
        return
    if args[0] == 'send' and not generation:
        raise ValueError('Enabled mapped endpoint requires a recorded lifecycle generation')
    permit = os.environ.get('FM_DISCORD_AUTH', '')
    if len(permit) != 32 or any(c not in '0123456789abcdef' for c in permit):
        raise ValueError('Mapped routing requires a typed parent-issued lane permit')
    text = sys.stdin.buffer.read(24577)
    if len(text) > 24576:
        raise ValueError('Mapped route payload exceeds bounded authority envelope')
    journal_type = importlib.import_module('personal_discord.journal').Journal
    routing_type = importlib.import_module('personal_discord.routing').Routing
    journal = journal_type(config['journal'])
    try:
        body = journal.record('route-permit', permit)
        if args[0] == 'capacity-deferred':
            if body['project'] != project:
                raise ValueError('Deferred permit belongs to another mapped project')
            routing_type(journal).defer_capacity(permit, target=target, project_path=args[2])
            return
        # A parent can explicitly identify unrelated work on a shared route;
        # the non-exclusive runtime projects list is never consulted.
        declared = body['project']
        if args[0] == 'spawn' and (declared != project or body['operation'] not in ('new', 'instruction')):
            raise ValueError('Non-work/unmapped classification cannot spawn mapped work')
        correlation = ''
        if args[0] == 'send' and body['operation'] == 'new':
            binding = journal.work_binding(body['request'])
            correlation = binding['correlation']
            if len(correlation) != 16 or any(c not in '0123456789abcdef' for c in correlation):
                raise ValueError('Existing parent correlation required before new-work route')
            record = home / 'state/pending-replies' / correlation
            if (not record.is_file() or meta_value(record, 'task_id') != target
                    or meta_value(record, 'parent_home') != str(home)):
                raise ValueError('Correlation is not owned by this exact parent route')
        if args[0] == 'send' and (text.startswith(b'/') or
                                  text.startswith(b'$') and meta_value(Path(args[3]), 'harness') == 'codex'):
            raise ValueError('Mapped work must use ordinary inbox text, not a parser-native invocation')
        expected_generation = os.environ.get('FM_SEND_EXPECTED_SPAWN_GEN', '')
        if args[0] == 'send' and expected_generation and expected_generation != generation:
            raise ValueError('Existing caller generation fence conflicts with the typed permit')
        if '|' in generation or len(generation) > 96:
            raise ValueError('Malformed endpoint generation')
        routing_type(journal).consume(permit, project=declared, target=target,
                                     text=text.decode('utf-8'), endpoint_generation=generation,
                                     mapped=declared == project)
        if args[0] == 'send':
            print(correlation + '|' + generation, end='')
    finally:
        journal.close()


if __name__ == '__main__':
    if sys.argv[1:] == ['--help']:
        print(__doc__)
        sys.exit(0)
    try:
        guard(sys.argv[1:])
    except (ValueError, KeyError, TypeError, ImportError, OSError, RuntimeError, sqlite3.Error, subprocess.SubprocessError) as error:
        # Fixed categories only: never echo message, private paths or tokens.
        print('error: Discord parent routing guard refused: ' + type(error).__name__ +
              '; verify the configured mapping and current typed lane permit', file=sys.stderr)
        sys.exit(1)
