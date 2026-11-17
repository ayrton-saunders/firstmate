"""Strict gh-axi 0.1.47 double with captured wire output.

Read-only captures:
https://github.com/ayrton-saunders/firstmate/pull/54 at 388558d8 (2026-11-16),
https://github.com/octocat/Hello-World/pull/11747 (empty rollup), and
https://github.com/astral-sh/ruff/pull/30483 (green with skips), 2026-11-17.
Only fixture identity fields are substituted.
EXPECTED table/list captures use the real gh-axi encoder on explicitly synthetic
StatusContext data through read-only api --jq. Other controlled variants follow
pr.js classifyCheck/checksExitCode: skip/cancel exit 0, fail 1, pending 8.
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
    output = (root / name).read_text()
    for url in ('https://github.com/ayrton-saunders/firstmate/pull/54',
                'https://github.com/octocat/Hello-World/pull/11747',
                'https://github.com/astral-sh/ruff/pull/30483'):
        output = output.replace(url, 'https://github.com/owner/repo/pull/1')
    for sha in ('388558d8a93350c079c1691f845b4d43078ee547',
                '68c0f62566bc731d9b9473b5391a5b1ad6fa6dc5',
                '0ebc06b76a62c5044d612b2a44785227a9e26202',
                '28464c3824c02b26860c420e6d1a0a4de6c8dcda'):
        output = output.replace(sha, current)
    return output


if args[:1] == ['api']:
    sys.stdout.write(captured('identity.tsv' if args[-1] == tsv else 'identity.toon'))
elif args == view_args:
    if mode == 'view-error':
        print('error: "forge unavailable"\ncode: UNKNOWN')
        sys.exit(1)
    current = (home / 'checks-head').read_text().strip() if (home / 'checks-head').exists() else head
    name = {'none': 'view-empty.toon', 'skips': 'view-skips.toon',
            'context-expected': 'view-expected.toon', 'mixed-expected': 'view-expected-mixed.toon'}.get(mode, 'view.toon')
    output = captured(name, current)
    if current.isdecimal():
        output = output.replace('headRefOid: ' + current, 'headRefOid: ' + json.dumps(current))
    if mode == 'duplicate-empty':
        output += '  statusCheckRollup: []\n'
    elif mode in ('context-failing', 'context-pending', 'context-error', 'context-neutral'):
        state = {'context-failing': 'FAILURE', 'context-pending': 'PENDING',
                 'context-error': 'ERROR', 'context-neutral': 'NEUTRAL'}[mode]
        output = output.split('  statusCheckRollup')[0] + '  statusCheckRollup[1]{__typename,context,state}:\n    StatusContext,ci,' + state + '\n'
    elif mode in ('failing', 'pending', 'cancel'):
        conclusion = {'failing': 'FAILURE', 'pending': 'null', 'cancel': 'CANCELLED'}[mode]
        output = output.replace(',SUCCESS,', ',' + conclusion + ',', 1)
        if mode == 'pending':
            output = output.replace(',COMPLETED,', ',IN_PROGRESS,', 1)
    sys.stdout.write(output)
else:
    if mode == 'checks-error':
        print('error: "forge unavailable"\ncode: UNKNOWN')
        sys.exit(1)
    if mode == 'none':
        sys.stdout.write(captured('checks-empty.toon'))
        sys.exit(1)
    output = captured('checks-skips.toon' if mode == 'skips' else 'checks.toon')
    code = 0
    buckets = {'failing': 'fail', 'pending': 'pending', 'cancel': 'cancel',
               'context-failing': 'fail', 'context-pending': 'pending',
               'context-error': 'fail', 'context-expected': 'skip',
               'mixed-expected': 'skip', 'context-neutral': 'skip'}
    if mode == 'mixed':
        lines = output.splitlines()
        lines[0] = 'summary: "25 passed, 1 failed, 1 pending, 27 total"'
        lines[2] = lines[2].rsplit(',', 1)[0] + ',fail'
        lines[3] = lines[3].rsplit(',', 1)[0] + ',pending'
        output = '\n'.join(lines) + '\n'
        code = 1
    elif mode in buckets:
        bucket = buckets[mode]
        count = {'fail': '1 failed', 'pending': '1 pending',
                 'cancel': '1 cancelled', 'skip': '1 skipped'}[bucket]
        if mode.startswith('context-') or mode == 'mixed-expected':
            mixed = mode == 'mixed-expected'
            name = '"required, context"' if mode == 'context-expected' else 'required' if mixed else 'ci'
            summary = ('1 passed, ' if mixed else '0 passed, ') + (count if bucket == 'fail' else '0 failed, ' + count)
            output = 'summary: "' + summary + (', 2 total"\nchecks[2]{name,conclusion}:\n  ci,pass\n' if mixed else ', 1 total"\nchecks[1]{name,conclusion}:\n')
            output += '  ' + name + ',' + bucket + '\n'
        else:
            lines = output.splitlines()
            lines[0] = 'summary: "26 passed, ' + (count if bucket == 'fail' else '0 failed, ' + count) + ', 27 total"'
            lines[2] = lines[2].rsplit(',', 1)[0] + ',' + bucket
            output = '\n'.join(lines) + '\n'
        code = 1 if bucket == 'fail' else 8 if bucket == 'pending' else 0
    if (home / 'after-checks-head').exists():
        (home / 'head').write_text((home / 'after-checks-head').read_text())
    sys.stdout.write(output)
    sys.exit(code)
