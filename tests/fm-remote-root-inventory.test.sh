#!/usr/bin/env bash
# Exercise the inactive closure audit's metadata/exclusion interface.
# This is NOT a source-string behavioral test of a production implementation.
# Owner behavior is exercised by each separately named executable suite.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-root-inventory)
mkdir -p "$TMP_ROOT"
trap fm_test_cleanup EXIT
python3 "$ROOT/tests/remote-root-inventory.py" --output "$TMP_ROOT/index.json"
python3 - "$TMP_ROOT/index.json" "$ROOT" <<'PY'
import json
import pathlib
import sys

report = json.load(open(sys.argv[1]))
root = pathlib.Path(sys.argv[2])
assert report['entries'], 'empty audit cannot pass'
assert not report['named_dispatch']
assert any(e['classification'] == 'unclassified' for e in report['entries'])
assert any(e['classification'] == 'characterized-legacy' for e in report['entries'])
for entry in report['entries']:
    assert entry['named_dispatch'] is False
    assert entry['file'] and entry['symbol'] and entry['line'] > 0
    assert entry['boundary'] and entry['effects'] and entry['test']
    assert entry['closure_stage'] in range(2, 7)
    assert (root / entry['test']).is_file()
for finding in report['findings']:
    assert finding['file'] and finding['symbol'] and finding['line'] > 0
    assert finding['boundary'] and finding['effects'] and finding['test']
    assert finding['named_dispatch'] is False
    assert (root / finding['test']).is_file()
stages = {stage['stage']: stage for stage in report['stage_map']}
assert set(stages) == {'1', '2', '2-adapter-slice', '3', '4', '5', '6'}
for target in stages['1']['targets']:
    assert (root / target).is_file()
assert {r for stage in stages.values() for r in stage['corrections']} == {
    'R1', 'R2', 'R3', 'R4', 'R5', 'R6'}
print('ok - every indexed entry has an explicit exclusion, boundary and evidence level')
PY
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
fixture = pathlib.Path(sys.argv[2]) / 'runtime-fixture'
fixture.mkdir()
subprocess.run(['git', 'init', '-q', str(fixture)], check=True)
expected = {
    'bin/entry.sh', 'bin/module.py', 'bin/module.js', 'bin/module.mjs',
    'bin/module.ts', 'bin/capture.pl', 'bin/reader.lua', 'bin/filter.jq',
}
for name in expected:
    path = fixture / name
    path.parent.mkdir(exist_ok=True)
    path.write_text('')
    path.chmod(0o644)
subprocess.run(['git', '-C', str(fixture), 'add', 'bin'], check=True)
policy = json.loads((root / 'tests/fixtures/remote-root-boundaries.json').read_text())
policy.update(owners=[], containers=[], findings=[])
test = fixture / policy['default']['test']
test.parent.mkdir(parents=True, exist_ok=True)
test.write_text('')
policy_path = fixture / 'policy.json'
policy_path.write_text(json.dumps(policy))
subprocess.run(['git', '-C', str(fixture), '-c', 'user.name=Fixture',
                '-c', 'user.email=fixture@example.invalid',
                '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Runtime fixture'],
               check=True)
report = json.loads(subprocess.check_output([
    'python3', str(root / 'tests/remote-root-inventory.py'),
    '--root', str(fixture), '--policy', str(policy_path)], text=True))
assert {entry['file'] for entry in report['entries']} == expected
for entry in report['entries']:
    assert entry['symbol'] == '@entry' and entry['mode'] == '100644'
    assert entry['classification'] == 'unclassified'
    assert entry['named_dispatch'] is False
    for field in ('boundary', 'effects', 'test', 'closure_stage'):
        assert entry[field] == policy['default'][field]
print('ok - tracked non-executable interpreted modules retain exclusion mappings')
PY
# Exercise the real ingress, not just the audit policy: protocol 2 is not a
# production dispatch surface in Stage 1. Both a known and an unclassified
# command-shaped payload must be rejected before decoding or queue creation.
mkdir -p "$TMP_ROOT/account" "$TMP_ROOT/staging"
for command in fm-on.sh fm-unclassified-audit.sh; do
  payload=$(printf '%s\0' "$command" "$TMP_ROOT/must-not-run" | base64 | tr -d '\n')
  if HOME="$TMP_ROOT/account" TMPDIR="$TMP_ROOT/staging" \
    bash "$ROOT/bin/fm-remote-entrypoint.sh" 2 unused-root unused-home "$payload" \
    > "$TMP_ROOT/ingress.out" 2> "$TMP_ROOT/ingress.err"; then
    fail "Stage-1 ingress unexpectedly admitted protocol 2"
  else
    rc=$?
  fi
  [ "$rc" = 64 ] || fail "protocol 2 refusal changed exit status"
  assert_grep 'incompatible remote protocol: local=2 remote=1' "$TMP_ROOT/ingress.err" "ingress did not reject the protocol before interpreting its payload"
  [ ! -s "$TMP_ROOT/ingress.out" ] || fail "refused ingress produced command output"
  [ -z "$(find "$TMP_ROOT/account" "$TMP_ROOT/staging" -mindepth 1 -print)" ] || fail "refused named-shaped request created account or queue state"
  assert_absent "$TMP_ROOT/must-not-run" "refused payload ran"
done
pass "real legacy ingress excludes known and unclassified command payloads from protocol 2 before state creation"
# A deliberately invalid audit policy must fail, not turn a helper-test pass
# into permission to enable enrollment. Only test data is modified here.
python3 - "$ROOT/tests/fixtures/remote-root-boundaries.json" "$TMP_ROOT/broken.json" <<'PY'
import json
import sys
policy = json.load(open(sys.argv[1]))
policy['named_dispatch'] = ['launch']
with open(sys.argv[2], 'w') as output:
    json.dump(policy, output)
PY
if python3 "$ROOT/tests/remote-root-inventory.py" --policy "$TMP_ROOT/broken.json" \
  --output "$TMP_ROOT/must-not-exist" > "$TMP_ROOT/refusal" 2>&1; then
  fail "a broken policy enabled named dispatch"
fi
assert_grep 'Stage 1 cannot admit named dispatch' "$TMP_ROOT/refusal" "broken policy did not fail for admission"
pass "deliberately enabled policy fails the Stage-1 exclusion audit"
