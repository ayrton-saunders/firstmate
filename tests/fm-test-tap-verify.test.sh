#!/usr/bin/env bash
# Behavior tests for bin/fm-test-tap-verify.sh: a TAP-planned suite that
# finishes cleanly passes; an early exit 0, a not-ok line, a nonzero status,
# or an ok-count that disagrees with the plan must fail. This is the
# completeness check that replaced hard-coded ok-counts in the stock macOS
# Bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY="$ROOT/bin/fm-test-tap-verify.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-tap-verify)
assert_present "$VERIFY" "bin/fm-test-tap-verify.sh is missing"

write_suite() {  # <path> <body>
  printf '%s\n' '#!/usr/bin/env bash' 'set -u' "$2" > "$1"
}

run_verify() {  # <suite> -> prints merged output; returns helper status
  "$BASH" "$VERIFY" "$1" 2>&1
}

test_correct_suite_passes() {
  local suite out rc=0
  suite="$TMP_ROOT/ok.sh"
  write_suite "$suite" '
printf "1..1\n"
printf "ok - good\n"
printf "FM_TEST_COMPLETE\n"
'
  out=$(run_verify "$suite" 0<&-) || rc=$?
  [ "$rc" -eq 0 ] || fail "a complete matching suite must pass, got exit $rc: $out"
  assert_contains "$out" "ok - good" "the helper hid the suite's ok line"
  assert_contains "$out" "1 planned, 1 ok, complete, exit 0" \
    "the helper did not confirm a matching plan"
  assert_not_contains "$out" "::error::" \
    "a passing suite must not print ::error::: $out"
  pass "a complete matching suite passes"
}

test_checkout_scratch_is_refused_before_running_suite() {
  local repo="$TMP_ROOT/repo" suite="$TMP_ROOT/unsafe.sh" out rc=0
  mkdir -p "$repo/.test-phase-tmp"
  git -C "$repo" init -q
  # shellcheck disable=SC2016 # Expand variables when the suite runs.
  write_suite "$suite" 'touch "$SUITE_CALLED"; printf "1..1\nok - good\nFM_TEST_COMPLETE\n"'
  out=$(TMPDIR="$repo/.test-phase-tmp" SUITE_CALLED="$TMP_ROOT/suite-called" run_verify "$suite") || rc=$?
  assert_equals 2 "$rc" "checkout TAP scratch exit status"
  assert_contains "$out" "unsafe scratch base" "checkout TAP scratch refusal"
  [ ! -e "$TMP_ROOT/suite-called" ] || fail "TAP suite ran before scratch refusal"
  pass "checkout scratch is refused before the TAP suite runs"
}

test_failed_suite_scratch_is_removed() {
  local suite="$TMP_ROOT/failing-scratch.sh" base="$TMP_ROOT/verifier-temp" out rc=0
  mkdir "$base"
  # shellcheck disable=SC2016 # Expand variables when the suite runs.
  write_suite "$suite" '
[ "$TMPDIR" = "$TMP" ] && [ "$TMPDIR" = "$TEMP" ] || exit 8
mkdir "$TMPDIR/read-only" || exit 8
touch "$TMPDIR/read-only/file" || exit 8
chmod 0500 "$TMPDIR/read-only" || exit 8
exit 7'
  out=$(TMPDIR="$base" run_verify "$suite") || rc=$?
  assert_equals 1 "$rc" 'a launched suite failure fails verification'
  assert_contains "$out" 'exited 7' 'the suite left scratch before it failed'
  assert_equals '' "$(ls -A "$base")" 'verifier removed output and suite scratch'
  pass 'verifier cleans read-only scratch from a failing suite'
}

test_retained_suite_scratch_survives_verifier_exit() {
  local base="$TMP_ROOT/retention" suite="$TMP_ROOT/retain.sh" status rc out
  for status in 0 7; do
    mkdir -p "$base/$status"
    # shellcheck disable=SC2016 # Expand variables when the suite runs.
    write_suite "$suite" '
mkdir "$TMPDIR/fixture" || exit 8
touch "$TMPDIR/fixture/sentinel" "$FM_TEST_RETAIN_MARKER.fixture" || exit 8
printf "1..1\nok - candidate\nFM_TEST_COMPLETE\n"
exit "$SUITE_STATUS"'
    rc=0
    out=$(TMPDIR="$base/$status" FM_TEST_RETAIN_MARKER="$base/$status/.retain-scratch" \
      SUITE_STATUS="$status" run_verify "$suite") || rc=$?
    assert_equals 1 "$rc" 'retained scratch fails verification'
    assert_contains "$out" 'retaining scratch:' 'retained scratch diagnostic'
    set -- "$base/$status"/fm-test-tap-verify.*/tmp/fixture/sentinel
    assert_present "$1" 'verifier did not delete retained suite scratch'
    set -- "$base/$status"/.retain-scratch.*.tap
    assert_present "$1" 'verifier publishes retention to the fixture marker'
  done
  pass 'verifier honors retention on both success and failure paths'
}

test_term_drains_stalled_suite() {
  local base="$TMP_ROOT/term" suite="$TMP_ROOT/stalled.sh"
  mkdir "$base"
  # shellcheck disable=SC2016 # Expand variables when the suite runs.
  write_suite "$suite" 'printf "%s\n" "$$" >"$READY"; exec sleep 60'
  TMPDIR="$base" READY="$TMP_ROOT/suite-ready" python3 - "$BASH" "$VERIFY" "$suite" <<'PY' || fail 'TERM did not drain the TAP suite and remove scratch'
import os, pathlib, signal, subprocess, sys, time

if os.name != 'posix':
    sys.exit(0)
ready = pathlib.Path(os.environ['READY'])
with ready.with_suffix('.log').open('w') as log:
    verifier = subprocess.Popen(sys.argv[1:], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    pid = None
    try:
        for _ in range(100):
            if ready.exists() and ready.read_text().strip():
                pid = int(ready.read_text())
                break
            assert verifier.poll() is None
            time.sleep(0.05)
        assert pid is not None, 'suite never started'
        verifier.send_signal(signal.SIGTERM)
        assert verifier.wait(timeout=8) == 143
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pid = None
        assert pid is None, 'stalled suite survived TERM'
        assert not list(pathlib.Path(os.environ['TMPDIR']).iterdir()), 'scratch survived TERM'
    finally:
        if pid is not None:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if verifier.poll() is None:
            verifier.kill()
            verifier.wait()
PY
  pass 'TERM drains a stalled TAP suite before removing scratch'
}

test_suite_reads_foreground_terminal() {
  local suite="$TMP_ROOT/interactive.sh"
  # shellcheck disable=SC2016 # Expand variables when the suite runs.
  write_suite "$suite" '
printf "input ready\n" > /dev/tty || exit 8
IFS= read -r reply && [ "$reply" = ready ] || exit 8
printf "1..1\nok - read terminal input\nFM_TEST_COMPLETE\n"'
  python3 - "$BASH" "$VERIFY" "$suite" <<'PY' || fail 'TAP suite could not read foreground terminal input'
import errno, os, pty, select, signal, sys, time

if os.name != 'posix':
    sys.exit(0)
pid, tty = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], sys.argv[1:])
try:
    transcript = b''
    deadline = time.monotonic() + 5
    while b'input ready' not in transcript:
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([tty], [], [], remaining)[0], transcript
        try:
            chunk = os.read(tty, 4096)
        except OSError as exc:
            if exc.errno != errno.EIO:
                raise
            chunk = b''
        assert chunk, transcript
        transcript += chunk
    os.write(tty, b'ready\n')
    eof = False
    for _ in range(100):
        child, status = os.waitpid(pid, os.WNOHANG)
        if child:
            pid = None
            assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0, (status, transcript)
            break
        if eof:
            time.sleep(0.05)
        elif select.select([tty], [], [], 0.05)[0]:
            try:
                chunk = os.read(tty, 4096)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                chunk = b''
            transcript += chunk
            eof = not chunk
    else:
        raise AssertionError('verifier blocked on a terminal read')
finally:
    os.close(tty)
    if pid is not None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
PY
  pass 'TAP verifier preserves foreground terminal input'
}

test_replay_starts_after_releasing_scratch() {
  local base="$TMP_ROOT/replay" suite="$TMP_ROOT/replay.sh" out
  mkdir -p "$base/tools"
  write_suite "$suite" 'printf "1..1\nok - replayed\nFM_TEST_COMPLETE\n"'
  # shellcheck disable=SC2016 # Expand variables when the stub runs.
  printf '%s\n' '#!/usr/bin/env bash' 'for entry in "$REPLAY_BASE"/.retain-scratch.* "$REPLAY_BASE"/fm-test-tap-verify.*; do' \
    '  [ ! -e "$entry" ] || exit 9' 'done' 'exec "$REAL_CAT" "$@"' > "$base/tools/cat"
  chmod +x "$base/tools/cat"
  out=$(TMPDIR="$base" FM_TEST_RETAIN_MARKER="$base/.retain-scratch" REPLAY_BASE="$base" \
    REAL_CAT="$(command -v cat)" PATH="$base/tools:$PATH" run_verify "$suite" </dev/null) \
    || fail "replay began before scratch and parent marker were removed: $out"
  assert_contains "$out" 'ok - replayed' 'replay still emits the TAP output'
  pass 'TAP verifier releases scratch before replay'
}

test_early_exit_zero_fails() {
  local suite out rc=0
  suite="$TMP_ROOT/early.sh"
  write_suite "$suite" '
printf "1..3\n"
printf "ok - one\n"
printf "ok - two\n"
exit 0
'
  out=$(run_verify "$suite") || rc=$?
  [ "$rc" -ne 0 ] || fail "an early exit 0 must fail the helper: $out"
  assert_contains "$out" "without a single FM_TEST_COMPLETE" \
    "an early exit 0 must name the missing completion marker: $out"
  pass "an early exit 0 fails even when some ok lines printed"
}

test_not_ok_fails_even_with_exit_zero() {
  local suite out rc=0
  suite="$TMP_ROOT/not-ok.sh"
  write_suite "$suite" '
printf "1..1\n"
printf "not ok - boom\n"
printf "ok - misleading\n"
printf "FM_TEST_COMPLETE\n"
exit 0
'
  out=$(run_verify "$suite") || rc=$?
  [ "$rc" -ne 0 ] || fail "a not-ok line with exit 0 must fail: $out"
  assert_contains "$out" "not-ok" "a not-ok line must be named: $out"
  pass "a not-ok line fails even when the suite exits 0"
}

test_nonzero_exit_fails() {
  local suite out rc=0
  suite="$TMP_ROOT/nonzero.sh"
  write_suite "$suite" '
printf "1..1\n"
printf "ok - good\n"
printf "FM_TEST_COMPLETE\n"
exit 7
'
  out=$(run_verify "$suite") || rc=$?
  [ "$rc" -ne 0 ] || fail "a nonzero suite status must fail the helper: $out"
  assert_contains "$out" "exited 7" "a nonzero status must be reported: $out"
  pass "a nonzero process status fails even with a matching TAP plan"
}

test_ok_count_mismatch_fails() {
  local suite out rc=0
  suite="$TMP_ROOT/mismatch.sh"
  write_suite "$suite" '
printf "1..2\n"
printf "ok - only-one\n"
printf "FM_TEST_COMPLETE\n"
'
  out=$(run_verify "$suite") || rc=$?
  [ "$rc" -ne 0 ] || fail "planned 2 / ok 1 must fail: $out"
  assert_contains "$out" "planned 2 ok lines, got 1" \
    "an ok-count mismatch must be reported: $out"
  pass "planned count must equal the number of ok lines"
}

test_fm_test_run_declares_plan_from_names() {
  local suite out rc=0
  suite="$TMP_ROOT/lib-run.sh"
  cat > "$suite" <<EOF
#!/usr/bin/env bash
set -u
# shellcheck disable=SC1091
. "$ROOT/tests/lib.sh"
test_alpha() { pass "alpha"; }
test_beta() { pass "beta"; }
fm_test_run test_alpha test_beta
EOF
  out=$(run_verify "$suite") || rc=$?
  [ "$rc" -eq 0 ] || fail "fm_test_run suite must pass the helper, got exit $rc: $out"
  assert_contains "$out" "1..2" "fm_test_run must print a plan derived from its names"
  assert_contains "$out" "ok - alpha" "fm_test_run lost the first test"
  assert_contains "$out" "ok - beta" "fm_test_run lost the second test"
  assert_contains "$out" "FM_TEST_COMPLETE" "fm_test_run must print the completion marker"
  assert_contains "$out" "2 planned, 2 ok, complete, exit 0" \
    "the helper must accept an fm_test_run plan"
  pass "fm_test_run derives N from the registered names"
}

test_fm_test_run_early_function_exit_fails() {
  local suite out rc=0
  suite="$TMP_ROOT/lib-early.sh"
  cat > "$suite" <<EOF
#!/usr/bin/env bash
set -u
# shellcheck disable=SC1091
. "$ROOT/tests/lib.sh"
test_alpha() { pass "alpha"; exit 0; }
test_beta() { pass "beta"; }
fm_test_run test_alpha test_beta
EOF
  out=$(run_verify "$suite") || rc=$?
  [ "$rc" -ne 0 ] || fail "a test function that exits 0 early must fail completeness: $out"
  assert_contains "$out" "without a single FM_TEST_COMPLETE" \
    "early function exit must name the missing completion marker: $out"
  pass "a test function that exits 0 before later tests fail completeness"
}

test_failure_prints_error_annotation() {
  local suite out rc=0
  suite="$TMP_ROOT/gha.sh"
  write_suite "$suite" 'exit 0'
  # Capture the helper's stdout and stderr so a passing self-test does not
  # leak ::error:: into the CI log.
  out=$(run_verify "$suite") || rc=$?
  [ "$rc" -ne 0 ] || fail "a suite with no plan must fail: $out"
  assert_contains "$out" "::error::" "a completeness failure must emit an error annotation: $out"
  pass "a completeness failure prints an error annotation"
}

test_correct_suite_passes
test_checkout_scratch_is_refused_before_running_suite
test_failed_suite_scratch_is_removed
test_retained_suite_scratch_survives_verifier_exit
test_term_drains_stalled_suite
test_suite_reads_foreground_terminal
test_replay_starts_after_releasing_scratch
test_early_exit_zero_fails
test_not_ok_fails_even_with_exit_zero
test_nonzero_exit_fails
test_ok_count_mismatch_fails
test_fm_test_run_declares_plan_from_names
test_fm_test_run_early_function_exit_fails
test_failure_prints_error_annotation
