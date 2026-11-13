#!/usr/bin/env python3
"""Optional mapped-route parent lane guard, no Discord/SSH/model access.

Usage: fm-discord-hook.py send <raw-target> <resolved-target> <meta-or-empty> <backend>
       fm-discord-hook.py spawn <task-id> <canonical-project-directory>
       fm-discord-hook.py capacity-deferred <task-id> <canonical-project-directory>
       fm-discord-hook.py ready
       fm-discord-hook.py outcome <note-id>
       fm-discord-hook.py confirm-send local|remote <receipt>
The spawn owner calls capacity-deferred only after proving exit 75 before launch;
it records retryable no-launch evidence without consuming dispatch authority.
Exact pre-marker message (send) or brief SHA256 (spawn) arrives on stdin.
FM_HOME selects the invoking parent home, as in the owning lifecycle script.
Absent config/discord-integration.json preserves legacy behavior.
Unmapped sends and ordinary local supervisory sends resolve routing configuration
only, never the pinned parent interpreter or package.
An enabled config binds schema=2, canonical home, private package root,
parent journal, routes [{target,project}], projects {canonical key:absolute root}.
package_root is absolute and may be a symlink such as <code>/current, which the
private self-updater switches between releases; every hop must stay inside the
enrolled code tree (its parent, resolved) and end at a canonical release
directory, which alone is imported. A legacy per-module hashes map is ignored.
Optional source_commit and source_digest are status information only, never
identity claims; source is descriptive and is not compared with this installation.
FM_DISCORD_AUTH names a parent-issued one-use permit, never a transport claim.
Its presence selects Discord-lane authority even when empty or malformed.
Only send to a local mapped task with FM_DISCORD_AUTH absent may use ordinary
supervisory inbox text without opening the journal or consuming a permit.
Configuration, endpoint identity, generation fences, payload bounds and native
invocation restrictions still apply; remote sends and mapped project spawns
still require permits.
Permit-free sends emit no route information and need no confirm-send call;
confirm-send without FM_DISCORD_AUTH is refused before journal access.
No success is returned after consuming a permit until its transaction commits.
Consumed permits are deliberately not retryable without lifecycle reconciliation.
The local parent issues permits through the pinned integration release's admin API.
"""
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
            raise HookCheck('Duplicate configuration field')
        result[key] = value
    return result


class HookCheck(ValueError):
    """A concrete local check failure containing no payload, paths or tokens."""


def failure_check(error):
    checks = {ValueError: 'configuration or authority validation', KeyError: 'required field',
              TypeError: 'field type', ImportError: 'integration module availability',
              OSError: 'local resource access', RuntimeError: 'parent authority state',
              sqlite3.Error: 'journal integrity', subprocess.SubprocessError: 'lifecycle subprocess'}
    return next(label for kind, label in checks.items() if isinstance(error, kind))


def checked_record(journal, family, ident):
    try:
        return journal.record(family, ident)
    except (ValueError, KeyError, TypeError, RuntimeError, sqlite3.Error) as error:
        check = 'Route permit lookup failed' if family == 'route-permit' else 'Captured request lookup failed'
        raise HookCheck(check) from error


def load(home, *, routing_only=False):
    path = home / 'config/discord-integration.json'
    if not path.exists():
        return None
    if path.is_symlink() or path.stat().st_size > 65536:
        raise HookCheck('Invalid integration configuration file')
    config = json.loads(path.read_text(), object_pairs_hook=unique)
    if not isinstance(config, dict) or type(config.get('enabled')) is not bool:
        raise HookCheck('Malformed integration enablement')
    if not config['enabled']:
        return None
    fields = {'schema', 'enabled', 'home', 'package_root', 'journal', 'routes', 'projects',
              'python_executable', 'source'}
    # hashes is a retired per-module pin that enrolled configs may still carry; it is ignored.
    optional = {'mapping', 'ingress', 'egress', 'assets', 'source_commit', 'source_digest', 'hashes'}
    if not fields <= set(config) or set(config) - fields - optional or config['schema'] != 2 or config['home'] != str(home):
        raise HookCheck('Integration schema/home mismatch')
    if (not Path(config['journal']).is_absolute() or not config['routes'] or not config['projects']
            or any(not isinstance(root, str) or not Path(root).is_absolute() for root in config['projects'].values())):
        raise HookCheck('Integration journal/routes/projects missing')
    if (any(not isinstance(route, dict) for route in config['routes'])
            or len({route.get('target') for route in config['routes']}) != len(config['routes'])):
        raise HookCheck('Ambiguous mapped route identity')
    for route in config['routes']:
        if set(route) != {'target', 'project'} or route['project'] not in config['projects']:
            raise HookCheck('Invalid explicit integration mapping')
        if not route['target'] or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for c in route['target']):
            raise HookCheck('Invalid mapped route identity')
    # Imported callers (dispatch/reply) retain full verification by default.
    if not routing_only:
        verify_parent(config)
    return config


def verify_parent(config):
    interpreter = Path(config['python_executable'])
    if not interpreter.is_absolute() or not interpreter.is_file():
        raise HookCheck('Pinned existing parent interpreter required')
    if Path(sys.executable).resolve() != interpreter.resolve():
        os.execv(str(interpreter), [str(interpreter), '-I', str(Path(__file__).resolve()), *sys.argv[1:]])
    if sys.version_info[:2] != (3, 14):
        raise HookCheck('Reviewed parent CPython 3.14 runtime required')
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(enrolled_release(config['package_root'])))


def enrolled_release(package_root):
    """Resolve package_root to one canonical release directory inside its code tree.

    The enrolled code tree is package_root's parent, resolved. package_root may be a
    symlink (the self-updater switches <code>/current between releases); every hop of
    its chain must stay inside that tree and end at an existing directory. Callers
    import from the returned directory, so a later switch cannot mix releases.
    """
    refusal = 'Integration package root must resolve to a canonical release inside the enrolled code tree'
    if not isinstance(package_root, str) or not Path(package_root).is_absolute():
        raise HookCheck(refusal)
    node = Path(package_root)
    tree = node.parent.resolve()
    for _ in range(40):
        if node.name in ('', '..'):
            raise HookCheck(refusal)
        node = node.parent.resolve() / node.name
        if node == tree or not node.is_relative_to(tree):
            raise HookCheck(refusal)
        if not node.is_symlink():
            break
        node = node.parent / os.readlink(node)
    else:
        raise HookCheck(refusal)
    if not node.is_dir() or node.resolve() != node:
        raise HookCheck(refusal)
    return node


def meta_value(path, key):
    values = [line.split('=', 1)[1] for line in path.read_text().splitlines()
              if line.startswith(key + '=')]
    if len(values) > 1:
        raise HookCheck('Conflicting runtime identity')
    return values[0] if values else ''


def guard(args):
    home = Path(os.environ['FM_HOME']).resolve(strict=True)
    config = load(home, routing_only=bool(args and args[0] == 'send'))
    if config is None:
        return
    if not args or args[0] not in ('send', 'spawn', 'capacity-deferred', 'outcome', 'ready', 'confirm-send'):
        raise HookCheck('Unknown hook operation')
    # Lane origin is explicit: a present FM_DISCORD_AUTH selects Discord permit
    # authority (even if empty/invalid); absence selects local supervisory text.
    # Never infer origin from a mapped target, route, or caller identity.
    discord_lane = 'FM_DISCORD_AUTH' in os.environ
    if args[0] == 'confirm-send':
        if len(args) != 3 or args[1] not in ('local', 'remote'):
            raise HookCheck('Exact owning delivery receipt required')
        if not discord_lane:
            raise HookCheck('Mapped routing requires a typed parent-issued lane permit')
        journal_type = importlib.import_module('personal_discord.journal').Journal
        routing_type = importlib.import_module('personal_discord.routing').Routing
        journal = journal_type(config['journal'])
        try:
            permit = os.environ.get('FM_DISCORD_AUTH', '')
            body = checked_record(journal, 'route-permit', permit)
            if args[1] == 'local':
                receipt = Path(args[2])
                expected = home / 'state' / (body['target'] + '.inbox')
                if receipt.parent.resolve() != expected.resolve() or not receipt.name.endswith('.msg') or not receipt.stem.isdigit():
                    raise HookCheck('Receipt is not in the exact mapped task inbox')
                actual = receipt if receipt.is_file() else expected / 'handled' / receipt.name
                if not actual.is_file() or actual.is_symlink():
                    raise HookCheck('Durable owning inbox receipt absent')
                evidence = {'local_inbox_record': receipt.name}
            else:
                if not args[2] or len(args[2]) > 96:
                    raise HookCheck('Exact remote correlation/delivery identity required')
                evidence = {'remote_enqueue_confirmed': True, 'delivery_identity': args[2]}
            routing_type(journal).confirm(permit, evidence=evidence)
        finally:
            journal.close()
        return
    if args[0] == 'ready':
        if len(args) != 1 or 'mapping' not in config:
            raise HookCheck('Pinned parent mapping required to renew readiness')
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
            raise HookCheck('Exact inbox note identity required')
        journal_type = importlib.import_module('personal_discord.journal').Journal
        journal = journal_type(config['journal'])
        try:
            reply_digest = sys.stdin.read(65)
            if len(reply_digest) != 64 or any(c not in '0123456789abcdef' for c in reply_digest):
                raise HookCheck('Exact terminal reply digest required')
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
                    raise HookCheck('Mapped backend target could not be resolved')
                matches = result.returncode == 0
            if direct or matches:
                if not direct or not metadata or Path(metadata).resolve() != path.resolve():
                    raise HookCheck('Explicit-terminal text cannot bypass the mapped parent route')
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
        raise HookCheck('Invalid hook arguments')
    if project is None:
        return
    local_send = args[0] == 'send' and candidate_backend != 'remote' and not discord_lane
    if args[0] == 'send' and not local_send:
        verify_parent(config)
    if args[0] == 'send' and not generation:
        raise HookCheck('Enabled mapped endpoint requires a recorded lifecycle generation')
    permit = os.environ.get('FM_DISCORD_AUTH', '')
    if not local_send and (len(permit) != 32 or any(c not in '0123456789abcdef' for c in permit)):
        raise HookCheck('Mapped routing requires a typed parent-issued lane permit')
    text = sys.stdin.buffer.read(24577)
    if len(text) > 24576:
        raise HookCheck('Mapped route payload exceeds bounded authority envelope')
    if local_send:
        if text.startswith(b'/') or text.startswith(b'$') and meta_value(Path(args[3]), 'harness') == 'codex':
            raise HookCheck('Mapped work must use ordinary inbox text, not a parser-native invocation')
        expected_generation = os.environ.get('FM_SEND_EXPECTED_SPAWN_GEN', '')
        if expected_generation and expected_generation != generation:
            raise HookCheck('Existing caller generation fence conflicts with the typed permit')
        if '|' in generation or len(generation) > 96:
            raise HookCheck('Malformed endpoint generation')
        return
    journal_type = importlib.import_module('personal_discord.journal').Journal
    routing_type = importlib.import_module('personal_discord.routing').Routing
    journal = journal_type(config['journal'])
    try:
        body = checked_record(journal, 'route-permit', permit)
        if args[0] == 'capacity-deferred':
            if body['project'] != project:
                raise HookCheck('Deferred permit belongs to another mapped project')
            routing_type(journal).defer_capacity(permit, target=target, project_path=args[2])
            return
        # A parent can explicitly identify unrelated work on a shared route;
        # the non-exclusive runtime projects list is never consulted.
        declared = body['project']
        if args[0] == 'spawn' and (declared != project or body['operation'] not in ('new', 'instruction')):
            raise HookCheck('Non-work/unmapped classification cannot spawn mapped work')
        correlation = ''
        if args[0] == 'send' and body['operation'] == 'new':
            binding = journal.work_binding(body['request'])
            correlation = binding['correlation']
            if len(correlation) != 16 or any(c not in '0123456789abcdef' for c in correlation):
                raise HookCheck('Existing parent correlation required before new-work route')
            record = home / 'state/pending-replies' / correlation
            if (not record.is_file() or meta_value(record, 'task_id') != target
                    or meta_value(record, 'parent_home') != str(home)):
                raise HookCheck('Correlation is not owned by this exact parent route')
        if args[0] == 'send' and (text.startswith(b'/') or
                                  text.startswith(b'$') and meta_value(Path(args[3]), 'harness') == 'codex'):
            raise HookCheck('Mapped work must use ordinary inbox text, not a parser-native invocation')
        expected_generation = os.environ.get('FM_SEND_EXPECTED_SPAWN_GEN', '')
        if args[0] == 'send' and expected_generation and expected_generation != generation:
            raise HookCheck('Existing caller generation fence conflicts with the typed permit')
        if '|' in generation or len(generation) > 96:
            raise HookCheck('Malformed endpoint generation')
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
    except HookCheck as error:
        print('error: ' + str(error), file=sys.stderr)
        sys.exit(1)
    except (ValueError, KeyError, TypeError, ImportError, OSError, RuntimeError, sqlite3.Error, subprocess.SubprocessError) as error:
        # Fixed categories only: never echo message, private paths or tokens.
        operation = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] in (
            'send', 'spawn', 'capacity-deferred', 'outcome', 'ready', 'confirm-send') else 'operation'
        check = failure_check(error)
        print('error: Discord ' + operation + ' ' + check + ' check failed', file=sys.stderr)
        sys.exit(1)
