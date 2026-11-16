"""Strict gh-axi 0.1.47 double with captured successful wire output.

Captured read-only on 2026-11-16 from the green reviewed PR:
https://github.com/ayrton-saunders/firstmate/pull/54 at
388558d8a93350c079c1691f845b4d43078ee547.
Only the fixture repository, PR number and head are substituted; failure/pending,
empty-rollup and StatusContext variants deliberately mutate that captured contract.
"""
import json
import os
from pathlib import Path
import sys

root = Path(__file__).parent
home = Path(os.environ['FM_HOME']) / 'state'
args = sys.argv[1:]
with (home / 'forge-calls').open('a') as stream:
    stream.write(json.dumps(args) + '\n')


def reject():
    print('error: "unsupported gh-axi fixture invocation"\ncode: VALIDATION_ERROR')
    sys.exit(2)


api_args = ['api', '/repos/owner/repo/pulls/1', '--jq']
tsv = '[.html_url,.state,(.draft|tostring),.head.sha]|@tsv'
old_json = '{url:.html_url,state:.state,isDraft:.draft,headRefOid:.head.sha}|tojson'
view_args = ['pr', 'view', '1', '-R', 'owner/repo', '--fields', 'headRefOid,statusCheckRollup']
checks_args = ['pr', 'checks', '1', '-R', 'owner/repo']
if not (args == view_args or args == checks_args
        or len(args) == 4 and args[:3] == api_args and args[3] in (tsv, old_json)):
    reject()
if (home / 'forge-error').exists():
    print('error: "forge unavailable"\ncode: UNKNOWN')
    sys.exit(2)
head = (home / 'head').read_text().strip()
mode = (home / 'checks-mode').read_text().strip() if (home / 'checks-mode').exists() else 'success'


def captured(name, current=head):
    return (root / name).read_text().replace(
        'https://github.com/ayrton-saunders/firstmate/pull/54', 'https://github.com/owner/repo/pull/1'
    ).replace('388558d8a93350c079c1691f845b4d43078ee547', current)


if args[:1] == ['api']:
    sys.stdout.write(captured('identity.tsv' if args[-1] == tsv else 'identity.toon'))
elif args == view_args:
    if mode == 'view-error':
        print('error: "forge unavailable"\ncode: UNKNOWN')
        sys.exit(1)
    current = (home / 'checks-head').read_text().strip() if (home / 'checks-head').exists() else head
    output = captured('view.toon', current)
    if current.isdecimal():
        output = output.replace('headRefOid: ' + current, 'headRefOid: ' + json.dumps(current))
    if mode == 'none':
        output = output.split('  statusCheckRollup')[0] + '  statusCheckRollup[0]:\n'
    elif mode.startswith('context-'):
        state = {'context-failing': 'FAILURE', 'context-pending': 'PENDING',
                 'context-error': 'ERROR', 'context-expected': 'EXPECTED'}[mode]
        output = output.split('  statusCheckRollup')[0] + '  statusCheckRollup[1]{__typename,context,state}:\n    StatusContext,ci,' + state + '\n'
    elif mode in ('failing', 'pending'):
        output = output.replace(',SUCCESS,', ',FAILURE,' if mode == 'failing' else ',null,', 1)
        if mode == 'pending':
            output = output.replace(',COMPLETED,', ',IN_PROGRESS,', 1)
    sys.stdout.write(output)
else:
    if mode == 'checks-error':
        print('error: "forge unavailable"\ncode: UNKNOWN')
        sys.exit(1)
    if mode == 'none':
        print('summary: "0 passed, 0 failed, 0 total"\nchecks[0]:')
        sys.exit(1)
    output = captured('checks.toon')
    code = 0
    if mode == 'mixed':
        lines = output.splitlines()
        lines[0] = 'summary: "25 passed, 1 failed, 1 pending, 27 total"'
        lines[2] = lines[2].rsplit(',', 1)[0] + ',fail'
        lines[3] = lines[3].rsplit(',', 1)[0] + ',pending'
        output = '\n'.join(lines) + '\n'
        code = 1
    elif mode in ('failing', 'pending', 'context-failing', 'context-pending', 'context-error', 'context-expected'):
        pending = mode in ('pending', 'context-pending', 'context-expected')
        conclusion = 'pending' if pending else 'fail'
        lines = output.splitlines()
        lines[0] = 'summary: "26 passed, 0 failed, 1 pending, 27 total"' if pending else 'summary: "26 passed, 1 failed, 27 total"'
        lines[2] = lines[2].rsplit(',', 1)[0] + ',' + conclusion
        output = '\n'.join(lines) + '\n'
        code = 8 if pending else 1
    sys.stdout.write(output)
    sys.exit(code)
