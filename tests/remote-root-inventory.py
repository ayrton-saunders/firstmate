#!/usr/bin/env python3
"""Inactive Stage-1 closure index, never a runtime admission implementation.

Usage: python3 tests/remote-root-inventory.py [--root REPO] [--policy JSON]
       [--output JSON]

Enumerate tracked runtime entries and shell declaration sites without executing
or sourcing them. Declarations inside generated shell bodies are deliberately
included: this is a conservative syntactic index, not a shell call-graph proof.
Every unreviewed site remains explicitly unclassified and excluded. The policy
names behavioral evidence only for reviewed owners; the inventory test proves
index/exclusion mechanics, NOT those owners' effects or future safety.

No production code imports this test-side audit or its policy. It cannot
confer runtime authority. The executable regression separately verifies the
current ingress rejects protocol 2 before command dispatch or state creation.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys


DECLARATION = re.compile(
    r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z_0-9]*)\s*\(\s*\)\s*\{"
)
RUNTIME_SUFFIXES = {'.sh', '.py', '.js', '.mjs', '.ts', '.pl', '.lua', '.jq'}


def tracked_entries(root):
    output = subprocess.check_output(
        ['git', '-C', str(root), 'ls-files', '--stage', '-z']
    )
    for item in output.decode().split('\0'):
        if not item:
            continue
        header, name = item.split('\t', 1)
        mode = header.split()[0]
        path = pathlib.PurePosixPath(name)
        if 'tests' in path.parts or path.parts[0] == 'tests':
            continue
        if mode == '120000':
            continue
        if path.suffix in RUNTIME_SUFFIXES or mode == '100755':
            yield name, mode


def validate_policy(policy, root):
    if policy['schema'] != 1:
        raise ValueError('unsupported inventory schema')
    if policy['named_dispatch']:
        raise ValueError('Stage 1 cannot admit named dispatch')
    seen = set()
    for owner in policy['owners']:
        if not owner['effects'] or not owner['boundary']:
            raise ValueError('owner requires effects and boundary')
        if not (root / owner['test']).is_file():
            raise ValueError('missing behavioral test: ' + owner['test'])
        for symbol in owner['symbols']:
            key = (owner['file'], symbol)
            if key in seen:
                raise ValueError('duplicate owner: ' + repr(key))
            seen.add(key)
    default = policy['default']
    if not (root / default['test']).is_file():
        raise ValueError('missing exclusion test')
    return seen


def inventory(root, policy):
    expected = validate_policy(policy, root)
    owners = {(o['file'], s): o for o in policy['owners'] for s in o['symbols']}
    containers = {}
    for container in policy['containers']:
        for name in container['files']:
            if name in containers:
                raise ValueError('duplicate container: ' + name)
            containers[name] = {**policy['default'], **container}
    found = set()
    rows = []
    for name, mode in sorted(tracked_entries(root)):
        source = root / name
        sites = [('@entry', 1)]
        if source.suffix == '.sh':
            for line, text in enumerate(source.read_text().splitlines(), 1):
                match = DECLARATION.match(text)
                if match:
                    sites.append((match[1], line))
        for symbol, line in sites:
            key = (name, symbol)
            owner = owners.get(key)
            found.add(key)
            disposition = owner or containers.get(name, policy['default'])
            rows.append({
                'file': name, 'symbol': symbol, 'line': line, 'mode': mode,
                'classification': 'characterized-legacy' if owner else 'unclassified',
                'boundary': disposition['boundary'],
                'effects': disposition['effects'], 'test': disposition['test'],
                'evidence': 'legacy behavior only; no named authorization' if owner
                else disposition['evidence'],
                'closure_stage': disposition['closure_stage'],
                'named_dispatch': False,
            })
    missing = expected - found
    if missing:
        raise ValueError('reviewed owner not in declaration index: ' + repr(sorted(missing)))
    indexed_files = {row['file'] for row in rows}
    stale_containers = set(containers) - indexed_files
    if stale_containers:
        raise ValueError('container not in entry index: ' + repr(sorted(stale_containers)))
    for finding in policy['findings']:
        if finding['file'] not in indexed_files:
            raise ValueError('finding not in entry index: ' + finding['file'])
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument('--policy', type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parent /
                        'fixtures/remote-root-boundaries.json')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    policy = json.loads(args.policy.read_text())
    rows = inventory(args.root.resolve(), policy)
    report = {
        'schema': 1, 'baseline': policy['baseline'], 'named_dispatch': [],
        'source_head': subprocess.check_output(
            ['git', '-C', str(args.root.resolve()), 'rev-parse', 'HEAD'],
            text=True).strip(),
        'source_selection': 'tracked paths, current working-tree contents',
        'stage_map': policy['stage_map'],
        'scope': 'all tracked runtime modules/executables, all shell declaration sites',
        'limitations': [
            'Syntactic declaration sites are not a complete dynamic call graph.',
            'Unclassified includes imported code, generated bodies and transitive effects.',
            'File entry covers top-level effects and non-shell callback/module loading.',
            'Characterized legacy owners are not qualified named owners.',
            'No installed launcher, enrollment, gate, lease or named runtime exists here.',
        ],
        'entries': rows,
        'findings': [dict(finding, test=policy['default']['test'],
                          evidence='source-backed gap; exclusion only, not behavioral closure',
                          named_dispatch=False)
                     for finding in policy['findings']],
    }
    serialized = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.write_text(serialized)
    else:
        sys.stdout.write(serialized)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError) as error:
        sys.exit(str(error))
