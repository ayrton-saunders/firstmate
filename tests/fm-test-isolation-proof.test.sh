#!/usr/bin/env bash
# Behavioral tests for the isolation-proof and test-run public interfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROOF="$ROOT/bin/fm-test-isolation-proof.sh"
RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$PROOF" "bin/fm-test-isolation-proof.sh is missing"
[ -x "$PROOF" ] || fail "bin/fm-test-isolation-proof.sh must be executable"

test_unknown_pool_is_refused() {
  local tmp rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-isolation-proof-pool.XXXXXX")
  set +e
  "$PROOF" --pool unknown-family --list >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unknown --pool must be refused with exit 2, got $rc"
  [ ! -s "$tmp/out" ] || fail "unknown --pool unexpectedly listed candidates: $(cat "$tmp/out")"
  rm -rf "$tmp"
  pass "unknown candidate pools are refused"
}

test_family_pool_json_identifies_admission() {
  local tmp repo proof json admitted_json capped_json skipped_json rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-isolation-proof-json.XXXXXX")
  repo="$tmp/repo"
  proof="$repo/bin/fm-test-isolation-proof.sh"
  json="$tmp/proof.json"
  admitted_json="$tmp/admitted-proof.json"
  capped_json="$tmp/capped-proof.json"
  skipped_json="$tmp/skipped-proof.json"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$PROOF" "$ROOT/bin/fm-test-scratch-lib.sh" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-path-lib.sh" "$repo/bin/"
  cat >"$repo/bin/fm-test-run.sh" <<'SH'
#!/usr/bin/env bash
if { [ "$1" = --list ] || [ "$1" = --list-scheduled ]; } && [ "$2" = --family ]; then
  case "$3" in
    fixture-family)
      printf '%s\n' tests/fm-proof-fixture-a.test.sh tests/fm-proof-fixture-b.test.sh
      exit 0
      ;;
    admitted-family)
      if [ "${PROOF_UNDRAINED:-0}" = 1 ]; then
        printf '%s\n' tests/fm-proof-undrained.test.sh tests/fm-proof-slow.test.sh tests/fm-proof-replacement.test.sh
      else
        printf '%s\n' tests/fm-proof-slow.test.sh tests/fm-proof-fast.test.sh tests/fm-proof-replacement.test.sh
      fi
      exit 0
      ;;
    skipped-family)
      printf '%s\n' tests/fm-proof-skipped.test.sh
      exit 0
      ;;
    interrupt-family)
      printf '%s\n' tests/fm-proof-interrupt.test.sh tests/fm-proof-fixture-a.test.sh
      exit 0
      ;;
    retaining-family)
      printf '%s\n' tests/fm-proof-retaining.test.sh
      exit 0
      ;;
    failing-family)
      printf '%s\n' tests/fm-proof-readonly.test.sh
      exit 0
      ;;
  esac
fi
if [ "$1" = --list-concurrent-safe-families ]; then
  printf '%s\n' admitted-family skipped-family retaining-family
  exit 0
fi
if [ "$1" = --concurrent-safe-family-jobs-max ]; then
  case "$2" in
    admitted-family|skipped-family|retaining-family)
      printf '2\n'
      exit 0
      ;;
  esac
fi
exit 2
SH
  for fixture in fm-proof-fixture-a.test.sh fm-proof-fixture-b.test.sh; do
    cat >"$repo/tests/$fixture" <<'SH'
#!/usr/bin/env bash
[ -d "$TMPDIR" ] && [ "$TMP" = "$TMPDIR" ] && [ "$TEMP" = "$TMPDIR" ] || exit 1
if [ -n "${EXPECTED_PROOF_HOME:-}" ]; then
  [ "$FM_ROOT" -ef "$EXPECTED_PROOF_HOME" ] && [ "$STATE" -ef "$EXPECTED_PROOF_HOME/state" ] || exit 1
fi
echo "ok - proof fixture"
SH
    chmod +x "$repo/tests/$fixture"
  done
  cat >"$repo/tests/fm-proof-slow.test.sh" <<'SH'
#!/usr/bin/env bash
waited=0
while [ ! -e "$PROOF_SCHED_EVIDENCE/replacement-started" ] && [ "$waited" -lt 200 ]; do
  sleep 0.05
  waited=$((waited + 1))
done
touch "$PROOF_SCHED_EVIDENCE/slow-done"
echo "ok - slow proof fixture"
SH
  cat >"$repo/tests/fm-proof-fast.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - fast proof fixture"
SH
  cat >"$repo/tests/fm-proof-replacement.test.sh" <<'SH'
#!/usr/bin/env bash
if [ -e "$PROOF_SCHED_EVIDENCE/slow-done" ]; then
  echo "not ok - proof scheduler waited for oldest worker"
  exit 1
fi
touch "$PROOF_SCHED_EVIDENCE/replacement-started"
echo "ok - replacement proof fixture"
SH
  cat >"$repo/tests/fm-proof-skipped.test.sh" <<'SH'
#!/usr/bin/env bash
echo
echo "skip: herdr not found"
SH
  cat >"$repo/tests/fm-proof-readonly.test.sh" <<'SH'
#!/usr/bin/env bash
set -e
mkdir "$TMPDIR/readonly"
printf '%s\n' 'scratch' >"$TMPDIR/readonly/file"
chmod 0500 "$TMPDIR/readonly"
printf '%s\n' 'readonly fixture ready'
exit 7
SH
  cat >"$repo/tests/fm-proof-interrupt.test.sh" <<'SH'
#!/usr/bin/env bash
on_term() {
  [ -d "$TMPDIR" ] && printf 'scratch existed at TERM\n' >"$PROOF_SIGNAL_DIR/term"
  exit 0
}
trap on_term TERM
printf '%s\n' "$$" >"$PROOF_SIGNAL_DIR/ready"
while :; do sleep 0.1; done
SH
  cat >"$repo/tests/fm-proof-retaining.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
. bin/fm-test-scratch-lib.sh
fm_test_arm_private_tmux MARKER
printf '%s\n' 'retained scratch' >"$TMPDIR/sentinel"
SH
  cat >"$repo/tests/fm-proof-undrained.test.sh" <<'SH'
#!/usr/bin/env bash
sleep 20 &
printf '%s\n' "$!" >"$PROOF_SCHED_EVIDENCE/lingering-pid"
echo 'candidate left a background process'
SH
  chmod +x "$proof" "$repo/bin/fm-test-run.sh" "$repo/tests/fm-proof-"*.test.sh
  mkdir -p "$repo/.test-phase-tmp" "$tmp/tools"
  # shellcheck disable=SC2016 # Expand variables when the stub runs.
  printf '%s\n' '#!/usr/bin/env bash' 'touch "$MKTEMP_CALLED"; exit 1' >"$tmp/tools/mktemp"
  chmod +x "$tmp/tools/mktemp"
  rc=0
  PATH="$tmp/tools:$PATH" TMPDIR="$repo/.test-phase-tmp" MKTEMP_CALLED="$tmp/mktemp-called" \
    "$proof" --pool fixture-family --jobs 1 --json "$json" >"$tmp/out" 2>"$tmp/err" || rc=$?
  assert_equals 2 "$rc" "checkout proof scratch exit status"
  assert_contains "$(<"$tmp/err")" "unsafe scratch base" "checkout proof scratch refusal"
  [ ! -e "$tmp/mktemp-called" ] && [ ! -e "$json" ] || fail "proof allocated scratch before refusing it"
  mkdir "$tmp/proof-tmp"
  rc=0
  (cd "$tmp" && PATH="$tmp/tools:$PATH" TMPDIR=./proof-tmp FM_STATE_OVERRIDE=proof-tmp \
    MKTEMP_CALLED="$tmp/mktemp-called" "$proof" --pool fixture-family --jobs 1 --json "$json") \
    >"$tmp/out" 2>"$tmp/err" || rc=$?
  assert_equals 2 "$rc" 'relative operational proof scratch exit status'
  assert_contains "$(<"$tmp/err")" 'unsafe scratch base' 'relative operational proof scratch refusal'
  [ ! -e "$tmp/mktemp-called" ] && [ ! -e "$json" ] || fail 'proof allocated scratch before refusing it'
  rc=0
  TMPDIR="$tmp/proof-tmp" "$proof" --pool failing-family --jobs 1 >"$tmp/readonly.out" 2>"$tmp/readonly.err" || rc=$?
  assert_equals 1 "$rc" 'proof reports a failing candidate'
  assert_contains "$(<"$tmp/readonly.err")" 'readonly fixture ready' 'the failing candidate created read-only scratch'
  [ -z "$(ls -A "$tmp/proof-tmp")" ] || fail 'failing proof left read-only scratch behind'
  TMPDIR="$tmp/proof-tmp" PROOF_SIGNAL_DIR="$tmp" python3 - "$proof" <<'PY' || fail 'interrupted proof did not drain its candidate before cleanup'
import os, pathlib, signal, subprocess, sys, time

if os.name != 'posix':
    print('skip proof cancellation subcase: native Python cannot deliver catchable TERM')
    sys.exit(0)

base = pathlib.Path(os.environ['PROOF_SIGNAL_DIR'])
with (base / 'interrupted.log').open('w') as log:
    proof = subprocess.Popen([sys.argv[1], '--pool', 'interrupt-family', '--jobs', '2'],
                             stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if (base / 'ready').exists():
                break
            assert proof.poll() is None
            time.sleep(0.05)
        else:
            raise AssertionError('candidate never started')
        proof.send_signal(signal.SIGTERM)
        assert proof.wait(timeout=10) == 143
        assert (base / 'term').read_text() == 'scratch existed at TERM\n'
        assert not list((base / 'proof-tmp').iterdir())
    finally:
        if proof.poll() is None:
            proof.kill()
            proof.wait()
        ready = base / 'ready'
        if ready.exists() and not (base / 'term').exists():
            pid = ready.read_text().strip()
            if pid:
                try:
                    os.kill(int(pid), signal.SIGKILL)
                except ProcessLookupError:
                    pass
PY
  mkdir "$tmp/retained [SSD]"
  rc=0
  TMPDIR="$tmp/retained [SSD]" "$proof" --pool retaining-family --jobs 2 --json "$tmp/retained.json" >"$tmp/retained.out" 2>"$tmp/retained.err" || rc=$?
  assert_equals 1 "$rc" 'unverified private teardown fails the proof'
  assert_contains "$(<"$tmp/retained.out")" 'FM_ISOLATION_SUMMARY total=1 failed=1' 'retained worker fails the summary'
  python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); assert r["summary"]["failed"] == 1 and not r["fm_test_run_jobs_enabled"] and r["scripts"][0]["exit"] == 1' "$tmp/retained.json" || fail 'retained worker was admitted in JSON'
  set -- "$tmp/retained [SSD]"/fm-isolation-proof.*
  [ "$#" -eq 1 ] && [ -f "$1/w1/tmp/sentinel" ] || fail 'proof deleted explicitly retained scratch'
  assert_contains "$(<"$tmp/retained.err")" "retaining scratch: $(cd "$1" && pwd -P)" 'retained scratch diagnostic names its root'
  # shellcheck disable=SC2016 # Expand arguments when the stub runs.
  printf '%s\n' '#!/usr/bin/env bash' 'case "${!#}" in */fm-isolation-proof.??????) exit 1 ;; esac' 'exec "$REAL_RM" "$@"' >"$tmp/tools/rm"
  chmod +x "$tmp/tools/rm"
  rm "$tmp/tools/mktemp"
  mkdir "$tmp/cleanup-evidence"
  rc=0
  PROOF_SCHED_EVIDENCE="$tmp/cleanup-evidence" REAL_RM="$(command -v rm)" \
    PATH="$tmp/tools:$PATH" TMPDIR="$tmp/proof-tmp" \
    "$proof" --pool admitted-family --jobs 2 --json "$tmp/cleanup.json" >"$tmp/cleanup.out" 2>"$tmp/cleanup.err" || rc=$?
  assert_equals 1 "$rc" 'failed proof removal cannot produce success'
  assert_contains "$(<"$tmp/cleanup.err")" 'could not remove scratch' 'proof reports failed removal'
  assert_contains "$(<"$tmp/cleanup.out")" 'FM_ISOLATION_CLEANUP failed' 'cleanup failure has its own summary line'
  python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); assert r["cleanup_failed"] is True and r["summary"]["failed"] == 0 and all(s["exit"] == 0 for s in r["scripts"]) and not r["fm_test_run_jobs_enabled"]' "$tmp/cleanup.json" || fail 'failed removal was admitted in JSON'
  mkdir "$tmp/snapshot-tools"
  cat >"$tmp/snapshot-tools/git" <<'SH'
#!/usr/bin/env bash
if [ "$*" = 'config --global --list' ]; then
  if [ "$TMPDIR" = "$EXPECTED_PROOF_BASE" ] && [ "$TMP" = "$EXPECTED_PROOF_BASE" ] &&
     [ "$TEMP" = "$EXPECTED_PROOF_BASE" ]; then
    printf 'validated\n' >>"$PROOF_SNAPSHOT_LOG"
  else
    printf 'unvalidated: %s %s %s\n' "$TMPDIR" "$TMP" "$TEMP" >>"$PROOF_SNAPSHOT_LOG"
  fi
  exit 0
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$tmp/snapshot-tools/git"
  rc=0
  mkdir -p "$tmp/worker-home/state"
  (cd "$tmp" && TMPDIR=./proof-tmp TMP="$repo" TEMP="$repo" \
    FM_ROOT=./worker-home STATE=./worker-home/state EXPECTED_PROOF_HOME="$tmp/worker-home" \
    EXPECTED_PROOF_BASE="$(cd proof-tmp && pwd -P)" PROOF_SNAPSHOT_LOG="$tmp/snapshots" \
    REAL_GIT="$(command -v git)" PATH="$tmp/snapshot-tools:$PATH" \
    "$proof" --pool fixture-family --jobs 1 --json "$json") \
    >"$tmp/out" 2>"$tmp/err" || rc=$?
  [ "$rc" -eq 0 ] || fail "family pool proof fixture failed: $(cat "$tmp/out") $(cat "$tmp/err")"
  assert_present "$tmp/snapshots" 'proof ran both parent snapshots'
  assert_equals $'validated\nvalidated' "$(<"$tmp/snapshots")" 'parent snapshots use the canonical launch-directory base'
  python3 -c '
import json, sys
artifact = json.load(open(sys.argv[1], encoding="utf-8"))
assert artifact["kind"] == "isolation-proof"
assert artifact["pool"] == "fixture-family"
assert artifact["fm_test_run_jobs_enabled"] is False
assert artifact["production_sharding_enabled"] is False
assert artifact["summary"]["total"] == 2
assert artifact["summary"]["failed"] == 0
' "$json" || fail "serial family pool artifact metadata is incorrect"
  set +e
  PROOF_SCHED_EVIDENCE="$tmp" "$proof" --pool admitted-family --jobs 2 --json "$admitted_json" >"$tmp/admitted.out" 2>"$tmp/admitted.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "admitted family proof fixture failed: $(cat "$tmp/admitted.out") $(cat "$tmp/admitted.err")"
  python3 -c '
import json, sys
artifact = json.load(open(sys.argv[1], encoding="utf-8"))
assert artifact["pool"] == "admitted-family"
assert artifact["concurrency"] == 2
assert artifact["fm_test_run_jobs_enabled"] is True
assert artifact["summary"]["total"] == 3
assert artifact["summary"]["failed"] == 0
' "$admitted_json" || fail "admitted family pool artifact metadata is incorrect"
  mkdir "$tmp/undrained"
  cp "$admitted_json" "$tmp/undrained/proof.json"
  TMPDIR="$tmp/undrained" PROOF_SCHED_EVIDENCE="$tmp/undrained" PROOF_UNDRAINED=1 \
    python3 - "$proof" <<'PY' || fail 'undrained proof did not publish a failed artifact'
import json, os, pathlib, signal, subprocess, sys

if os.name != 'posix':
    print('skip leaderless process group subcase: requires POSIX signals')
    sys.exit(0)

base = pathlib.Path(os.environ['TMPDIR'])
artifact = base / 'proof.json'
try:
    result = subprocess.run([sys.argv[1], '--pool', 'admitted-family', '--jobs', '2', '--json', str(artifact)],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 1, result
    assert 'FM_ISOLATION_SUMMARY total=1 failed=1' in result.stdout, result
    assert 'candidate left a background process' in result.stderr, result
    assert 'could not confirm worker group exit; retaining scratch:' in result.stderr, result
    assert not (base / 'replacement-started').exists()
    assert len(list(base.glob('fm-isolation-proof.*'))) == 1
    report = json.loads(artifact.read_text())
    assert report['summary']['failed'] == 1 and not report['fm_test_run_jobs_enabled'], report
    assert [(s['path'], s['exit']) for s in report['scripts']] == [('tests/fm-proof-undrained.test.sh', 1)], report
finally:
    pid_file = base / 'lingering-pid'
    if pid_file.exists():
        try:
            os.kill(int(pid_file.read_text()), signal.SIGKILL)
        except ProcessLookupError:
            pass
PY
  mkdir "$tmp/capped-evidence"
  set +e
  PROOF_SCHED_EVIDENCE="$tmp/capped-evidence" "$proof" --pool admitted-family --jobs 3 --json "$capped_json" >"$tmp/capped.out" 2>"$tmp/capped.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "over-cap family proof fixture failed: $(cat "$tmp/capped.out") $(cat "$tmp/capped.err")"
  python3 -c '
import json, sys
artifact = json.load(open(sys.argv[1], encoding="utf-8"))
assert artifact["pool"] == "admitted-family"
assert artifact["concurrency"] == 3
assert artifact["fm_test_run_jobs_enabled"] is False
assert artifact["summary"]["failed"] == 0
' "$capped_json" || fail "over-cap family pool artifact metadata is incorrect"
  set +e
  "$proof" --pool skipped-family --jobs 2 --json "$skipped_json" >"$tmp/skipped.out" 2>"$tmp/skipped.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "gate-skipped family proof must fail, got $rc"
  grep -Fq 'pool skipped-family candidate gate-skipped' "$tmp/skipped.err" \
    || fail "gate-skipped proof did not name its pool: $(cat "$tmp/skipped.err")"
  grep -Fq 'tests/fm-proof-skipped.test.sh: skip: herdr not found' "$tmp/skipped.err" \
    || fail "gate-skipped proof did not name its candidate and prerequisite: $(cat "$tmp/skipped.err")"
  python3 -c '
import json, sys
artifact = json.load(open(sys.argv[1], encoding="utf-8"))
assert artifact["pool"] == "skipped-family"
assert artifact["fm_test_run_jobs_enabled"] is False
assert artifact["summary"]["total"] == 1
assert artifact["summary"]["failed"] == 1
assert artifact["scripts"][0]["exit"] == 1
' "$skipped_json" || fail "gate-skipped family artifact was admitted"
  rm -rf "$tmp"
  pass "family pool JSON scopes jobs admission to proven concurrency"
}

test_list_candidates_nonempty_and_stable() {
  local listed count sorted
  listed=$("$PROOF" --list)
  [ -n "$listed" ] || fail "--list printed nothing"
  count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$count" -ge 10 ] || fail "expected a bounded non-trivial candidate set, got $count"
  sorted=$(printf '%s\n' "$listed" | LC_ALL=C sort)
  [ "$listed" = "$sorted" ] || fail "--list must be sorted for a stable matrix"
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = "$count" ] \
    || fail "--list must not duplicate candidates"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) [ -f "$ROOT/$line" ] || fail "listed missing script: $line" ;;
      *) fail "non-test candidate path: $line" ;;
    esac
  done <<<"$listed"
  pass "candidate --list is non-empty, sorted, unique, and real"
}

test_candidates_exclude_serial_classes() {
  local listed
  listed=$("$PROOF" --list)
  for banned in \
    tests/fm-test-isolation-proof.test.sh \
    tests/fm-backend-tmux-smoke.test.sh \
    tests/fm-watcher-lock.test.sh \
    tests/fm-wake-queue.test.sh \
    tests/fm-backend-herdr-smoke.test.sh \
    tests/fm-afk-inject-e2e.test.sh \
    tests/fm-pi-primary-live-e2e.test.sh \
    tests/fm-pr-check-security.test.sh \
    tests/fm-backend-cmux-smoke.test.sh; do
    printf '%s\n' "$listed" | grep -Fxq "$banned" \
      && fail "serial-class script must not be a parallel candidate: $banned"
  done
  pass "serial classes remain excluded from the parallel candidate set"
}

test_extra_hermetic_candidates_present() {
  local listed
  listed=$("$PROOF" --list)
  for want in \
    tests/fm-backend-herdr.test.sh \
    tests/fm-send-strict.test.sh \
    tests/fm-spawn-batch.test.sh \
    tests/fm-pr-merge.test.sh \
    tests/fm-review-diff.test.sh \
    tests/fm-x-mode.test.sh; do
    printf '%s\n' "$listed" | grep -Fxq "$want" \
      || fail "extra hermetic candidate missing: $want"
  done
  pass "audited fake-backend and stub-network extras are candidates"
}

test_list_exclusions_documents_reasons() {
  local out
  out=$("$PROOF" --list-exclusions)
  [ -n "$out" ] || fail "--list-exclusions printed nothing"
  printf '%s\n' "$out" | grep -Fq 'fm-watcher-lock.test.sh' \
    || fail "exclusions must document watcher-lock serial reason"
  printf '%s\n' "$out" | grep -Fq 'fm-backend-herdr-smoke.test.sh' \
    || fail "exclusions must document real-herdr serial reason"
  pass "exclusion list documents serial reasons"
}

test_family_map_labels_this_contract() {
  local fam safe safe_max scheduled_first
  fam=$("$RUNNER" --list --family pure-contract-unit)
  printf '%s\n' "$fam" | grep -Fq 'tests/fm-test-isolation-proof.test.sh' \
    || fail "fm-test-isolation-proof.test.sh must map to pure-contract-unit"
  safe=$("$RUNNER" --list-concurrent-safe-families)
  printf '%s\n' "$safe" | grep -Fxq watcher-wake-lock \
    || fail "runner must expose the admitted watcher concurrent-safe family"
  printf '%s\n' "$safe" | grep -Fxq pure-contract-unit \
    || fail "runner must expose the admitted contract-unit concurrent-safe family"
  safe_max=$("$RUNNER" --concurrent-safe-family-jobs-max watcher-wake-lock)
  [ "$safe_max" -eq 4 ] || fail "runner exposed the wrong watcher family worker cap: $safe_max"
  safe_max=$("$RUNNER" --concurrent-safe-family-jobs-max pure-contract-unit)
  [ "$safe_max" -eq 4 ] || fail "runner exposed the wrong contract-unit family worker cap: $safe_max"
  scheduled_first=$("$RUNNER" --list-scheduled --family watcher-wake-lock | head -n 1)
  [ "$scheduled_first" = tests/fm-watch-triage.test.sh ] \
    || fail "runner scheduled the watcher family out of longest-hint order: $scheduled_first"
  pass "isolation-proof contract test is family-mapped"
}

test_parallel_shards_consume_the_proven_set() {
  local proven shards
  proven=$("$PROOF" --list | LC_ALL=C sort -u)
  shards=$(
    {
      "$RUNNER" --list --lane portable-parallel-1
      "$RUNNER" --list --lane portable-parallel-2
    } | LC_ALL=C sort -u
  )
  [ "$proven" = "$shards" ] \
    || fail "portable parallel shards must equal isolation-proof --list exactly"
  pass "parallel shards consume the proven-isolated set only"
}

# A fixture repository names its branch, so a suite that resolves `main` gets
# the same answer wherever it runs. Without the pinned initial branch this
# fails on any host whose init.defaultBranch is still master.
test_fixture_repo_branch_is_pinned() {
  local root dir config branch
  root=$(fm_test_tmproot fm-fixture-branch-pin) || fail "could not create a fixture root"
  dir="$root/repo"
  config="$root/gitconfig"
  printf '[init]\n\tdefaultBranch = master\n' > "$config"
  GIT_CONFIG_GLOBAL="$config" fm_git_init_commit "$dir"
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
  [ "$branch" = main ] \
    || fail "fixture repo branch follows init.defaultBranch instead of main: $branch"
  git -C "$dir" rev-parse main >/dev/null 2>&1 \
    || fail "fixture repo cannot resolve main"
  pass "fixture repositories pin their initial branch to main"
}

test_unknown_pool_is_refused
test_family_pool_json_identifies_admission
test_list_candidates_nonempty_and_stable
test_candidates_exclude_serial_classes
test_extra_hermetic_candidates_present
test_list_exclusions_documents_reasons
test_family_map_labels_this_contract
test_parallel_shards_consume_the_proven_set
test_fixture_repo_branch_is_pinned
