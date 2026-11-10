"""Drive the real selection CLI and workflow verdict shell; never invoke a linter."""
import collections
import glob
import json
import os
from pathlib import Path
import subprocess

out = Path('~/.no-mistakes/evidence/01M73GH4CBMA43FH7DAGTP2YPP')
env = dict(os.environ, CI='false', GITHUB_ACTIONS='false')
records = []
def call(args, expected=0, call_env=env):
    p = subprocess.run(args, env=call_env, text=True, capture_output=True, timeout=60)
    records.append({'argv': args, 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr})
    assert p.returncode == expected, records[-1]
    return p.stdout

# Independent public inventory contract: all direct shell children in these three directories.
expected = sorted(p for pattern in ('bin/*.sh', 'bin/backends/*.sh', 'tests/*.sh') for p in glob.glob(pattern))
full = call(['bin/fm-lint.sh', '--list-files'], call_env=dict(env, CI='true')).splitlines()
assert sorted(full) == expected
partitions = {}
for total in (2, 4):
    union = []
    for index in range(1, total + 1):
        part = f'{index}of{total}'
        args = ['bin/fm-lint.sh', '--partition', part, '--list-files']
        roots = call(args).splitlines()
        assert roots and roots == call(args).splitlines()
        assert roots == call(args, call_env=dict(env, CI='true', GITHUB_ACTIONS='true')).splitlines()
        union.extend(roots)
        partitions[part] = {'count': len(roots), 'roots': roots}
    assert collections.Counter(union) == collections.Counter(expected)
    assert len(union) == len(set(union))

invalid = ['0of2', '3of2', '1of3', '0of4', '5of4', '1of0', '01of4', '1of04', '', '1of4;exit 0']
for value in invalid:
    call(['bin/fm-lint.sh', '--partition', value, '--list-files'], 2)
call(['bin/fm-lint.sh', '--partition'], 2)
for total in (2, 4):
    call(['bin/fm-lint.sh', '--partition', f'1of{total}', '--fast', '--list-files'], 2)
    call(['bin/fm-lint.sh', '--partition', f'1of{total}', 'bin/fm-lint.sh'], 2)

# Parse the machine-consumed workflow, then execute its actual verdict payload
# with synthetic dependency outcomes. This proves the local shell, NOT hosted scheduling.
payload = subprocess.run(['ruby', '-ryaml', '-rjson', '-e',
    'puts JSON.generate(YAML.load_file(ARGV[0]).fetch("jobs").fetch("lint"))',
    '.github/workflows/ci.yml'], text=True, capture_output=True, check=True)
job = json.loads(payload.stdout)
assert job['needs'] == ['lint-partitions']
assert job['strategy']['matrix']['partition'] == [1, 2]
verdicts = []
for result in ('success', 'failure', 'cancelled', 'skipped', '', 'unknown'):
    for step in job['steps']:
        assert step['env'] == {'FM_LINT_RESULT': '${{ needs.lint-partitions.result }}'}
        p = subprocess.run(['bash', '-c', step['run']], env=dict(env, FM_LINT_RESULT=result),
                           text=True, capture_output=True, timeout=10)
        verdicts.append({'dependency_result': result, 'exit': p.returncode,
                         'stdout': p.stdout, 'stderr': p.stderr})
        assert (p.returncode == 0) == (result == 'success'), verdicts[-1]

(out / 'local-contract-transcript.json').write_text(json.dumps({
    'inventory_count': len(expected), 'partitions': partitions,
    'commands': records, 'verdicts': verdicts}, indent=2) + '\n')
summary = {'inventory_count': len(expected),
           'partition_counts': {k: v['count'] for k, v in partitions.items()},
           'inventory_result': 'Both unions equal the independent canonical inventory with no duplicates; repeated local and CI selections agree.',
           'guard_result': 'Malformed selectors, missing values, fast mode and explicit subsets exit 2 before analysis.',
           'local_shell_verdicts': verdicts,
           'scope': 'Actual CLI list/refusal interface and actual workflow verdict bash payload; no ShellCheck/actionlint, no hosted Actions scheduler, no timing study.'}
(out / 'local-contract-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
