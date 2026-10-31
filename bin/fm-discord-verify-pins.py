#!/usr/bin/env python3
"""Read-only comparison of the private Discord parent and transport identity pins.

Usage: fm-discord-verify-pins.py --parent-config /absolute/discord-integration.json
                               --transport-manifest /absolute/transport.json
                               [--parent-journal-snapshot /absolute/parent.sqlite
                                --transport-journal-snapshot /absolute/transport.sqlite]

Run the installed command from the approved parent source, with an explicit local
copy of the transport manifest. No default home, SSH, private package import,
credential access or service operation is performed.
Without snapshots, exit 0 means only the source/config/manifest pins agree.
Supply BOTH standalone offline SQLite backups to additionally compare the
transport's remembered parent identity/epoch and check both journals' intake and
delivery fences. Use the private release's coherent backup procedure, never a
copy of a live main database without its WAL. Snapshots with sidecars and paths
configured as live journals are refused. Snapshot reads are immutable/read-only,
never open the private Journal owner, and cannot prove current live readiness.
Remote-epoch reconciliation and unfencing remain separate owner actions.
The v2 source identity matches Integration.identify_source in the pinned private
release: Git HEAD plus the canonical SHA256 map of the four lifecycle files.
See docs/discord-owner-reply-pins.md for pin ownership and the recovery sequence.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys


class Refusal(ValueError):
    """A fixed, public-safe diagnostic, never raw configuration or command output."""


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refusal('duplicate JSON field')
        result[key] = value
    return result


def read_object(path):
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise Refusal('explicit absolute regular JSON files required')
    with path.open('rb') as stream:
        raw = stream.read(65537)
    if len(raw) > 65536:
        raise Refusal('JSON file exceeds the configuration size limit')
    try:
        value = json.loads(raw, object_pairs_hook=unique)
    except (UnicodeError, json.JSONDecodeError, RecursionError):
        raise Refusal('malformed JSON configuration') from None
    if not isinstance(value, dict):
        raise Refusal('JSON configuration must be an object')
    return value


def canonical_path(value):
    if not isinstance(value, str) or not value or '\x00' in value:
        raise Refusal('canonical absolute source and home paths required')
    path = Path(value)
    if not path.is_absolute() or str(path.resolve()) != value:
        raise Refusal('canonical absolute source and home paths required')
    return path


def hex_value(value, lengths):
    return (isinstance(value, str) and len(value) in lengths
            and all(char in '0123456789abcdef' for char in value))


def source_identity(source):
    # Keep this wire-format calculation compatible with the private v2 release;
    # importing its Integration would execute private code during a read-only check.
    result = subprocess.run(
        ['/usr/bin/git', '--no-optional-locks', '-C', str(source), 'rev-parse', 'HEAD'],
        capture_output=True, text=True, timeout=5,
        env={'PATH': '/usr/bin:/bin', 'GIT_CONFIG_GLOBAL': os.devnull,
             'GIT_CONFIG_SYSTEM': os.devnull, 'GIT_OPTIONAL_LOCKS': '0'})
    commit = result.stdout.strip()
    if result.returncode or not hex_value(commit, (40, 64)):
        raise Refusal('parent source Git commit unavailable')
    files = {}
    for name in ('bin/fm-inbox.sh', 'bin/fm-send.sh', 'bin/fm-spawn.sh', 'bin/fm-discord-hook.py'):
        path = source / name
        if path.is_symlink() or not path.is_file():
            raise Refusal('parent source lifecycle file absent or symlinked')
        files[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    encoded = json.dumps(files, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)
    return {'source_commit': commit, 'source_digest': hashlib.sha256(encoded.encode()).hexdigest()}


def verify(config, manifest):
    if type(config.get('schema')) is not int or config['schema'] != 2 or config.get('enabled') is not True:
        raise Refusal('enabled schema 2 parent configuration required')
    if type(manifest.get('schema')) is not int or manifest['schema'] != 2 or manifest.get('enabled') is not True:
        raise Refusal('enabled schema 2 transport manifest required')
    source = canonical_path(config.get('source'))
    home = canonical_path(config.get('home'))
    if source != Path(__file__).resolve().parent.parent:
        raise Refusal('invoked command is not from the configured parent source')
    if not hex_value(config.get('source_commit'), (40, 64)) or not hex_value(config.get('source_digest'), (64,)):
        raise Refusal('parent source pins absent or malformed')
    actual = source_identity(source)
    if config['source_commit'] != actual['source_commit']:
        raise Refusal('parent source commit mismatch; re-pin both sides before reconciliation')
    if config['source_digest'] != actual['source_digest']:
        raise Refusal('parent source digest mismatch; re-pin both sides before reconciliation')
    expected = {**actual, 'home_identity': hashlib.sha256(str(home).encode()).hexdigest()}
    identity = manifest.get('parent_identity')
    if not isinstance(identity, dict) or set(identity) != set(expected):
        raise Refusal('transport parent_identity absent or malformed')
    for key in ('source_commit', 'source_digest', 'home_identity'):
        if identity[key] != expected[key]:
            raise Refusal('transport parent_identity ' + key + ' mismatch; re-pin both sides before reconciliation')
    return expected


def snapshot_identity(db, role):
    rows = db.execute('SELECT singleton,schema_version,epoch,fenced,delivery_fenced FROM identity LIMIT 2').fetchall()
    if (len(rows) != 1 or type(rows[0][0]) is not int or rows[0][0] != 1
            or type(rows[0][1]) is not int or rows[0][1] != 2
            or not hex_value(rows[0][2], (32,))
            or any(type(flag) is not int or flag not in (0, 1) for flag in rows[0][3:])):
        raise Refusal(role + ' snapshot identity absent or malformed')
    if any(rows[0][3:]):
        raise Refusal(role + ' intake or delivery remains fenced; reconcile before explicit unfencing')
    return rows[0][2]


def remembered_parent(db):
    rows = db.execute("SELECT revision,body FROM state WHERE family='remote-epoch' AND id='parent' LIMIT 2").fetchall()
    try:
        if (len(rows) != 1 or type(rows[0][0]) is not int or rows[0][0] < 1
                or not isinstance(rows[0][1], str) or len(rows[0][1].encode()) > 65536):
            raise ValueError
        body = json.loads(rows[0][1], object_pairs_hook=unique)
        if (not isinstance(body, dict) or set(body) != {'epoch', 'identity'}
                or not hex_value(body['epoch'], (32,)) or not isinstance(body['identity'], dict)):
            raise ValueError
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise Refusal('remembered parent observation absent or malformed') from None
    return body


def verify_snapshots(parent_path, transport_path, config, manifest, expected):
    if parent_path is None or transport_path is None:
        raise Refusal('both journal snapshot arguments are required')
    paths = (parent_path, transport_path)
    for path in paths:
        if not path.is_absolute() or path.is_symlink() or not path.is_file():
            raise Refusal('explicit absolute regular snapshot files required')
        if any(Path(str(path) + suffix).exists() or Path(str(path) + suffix).is_symlink()
               for suffix in ('-wal', '-shm', '-journal')):
            raise Refusal('standalone offline journal snapshots required; use coherent backups without sidecars')
        for live in (config.get('journal'), manifest.get('journal')):
            if isinstance(live, str) and path.resolve() == Path(live).resolve():
                raise Refusal('configured live journal paths are not snapshots')
    if parent_path.samefile(transport_path):
        raise Refusal('distinct parent and transport snapshots required')
    epochs = []
    observed = None
    for role, path in zip(('parent', 'transport'), paths):
        db = None
        try:
            # immutable avoids WAL/SHM creation even in a read-only directory.
            # This deliberately requires coherent offline backups, not live DBs.
            db = sqlite3.connect(path.resolve().as_uri() + '?mode=ro&immutable=1', uri=True)
            db.execute('PRAGMA query_only=ON')
            db.execute('PRAGMA trusted_schema=OFF')
            epochs.append(snapshot_identity(db, role))
            if role == 'transport':
                observed = remembered_parent(db)
        except sqlite3.Error:
            raise Refusal('journal snapshot could not be read; standalone schema 2 backups required') from None
        finally:
            if db is not None:
                db.close()
    if observed['identity'] != expected:
        raise Refusal('remembered parent identity mismatch; reconcile remote-epoch before unfencing')
    if observed['epoch'] != epochs[0]:
        raise Refusal('remembered parent epoch mismatch; reconcile remote-epoch before unfencing')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--parent-config', required=True, type=Path)
    parser.add_argument('--transport-manifest', required=True, type=Path)
    parser.add_argument('--parent-journal-snapshot', type=Path)
    parser.add_argument('--transport-journal-snapshot', type=Path)
    args = parser.parse_args()
    snapshots = args.parent_journal_snapshot is not None or args.transport_journal_snapshot is not None
    try:
        config = read_object(args.parent_config)
        manifest = read_object(args.transport_manifest)
        expected = verify(config, manifest)
        if snapshots:
            verify_snapshots(args.parent_journal_snapshot, args.transport_journal_snapshot, config, manifest, expected)
    except Refusal as error:
        print('error: Discord pin verification refused: ' + str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError, subprocess.SubprocessError):
        print('error: Discord pin verification refused: configuration, source or snapshot could not be read', file=sys.stderr)
        return 1
    if snapshots:
        print('Discord source/config/manifest/remote-epoch pins agree; parent and transport '
              'intake/delivery fences are clear (offline snapshots only).')
    else:
        print('Discord source/config/manifest pins agree; journal epoch and fences not checked.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
