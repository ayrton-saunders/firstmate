#!/usr/bin/env bash
# Negative controls: deliberately broken fixture code must fail the frozen
# legacy observations. Mutants live only under the test temporary directory.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-legacy-mutation)
mkdir -p "$TMP_ROOT/subject"
trap fm_test_cleanup EXIT
SUBJECT=${FM_CHARACTERIZATION_ROOT:-$ROOT}
cp -R "$SUBJECT/bin" "$TMP_ROOT/subject/bin"
# Run the actual suites once against the unmodified extracted fixture subject.
FM_CHARACTERIZATION_ROOT="$TMP_ROOT/subject" bash "$ROOT/tests/fm-remote-legacy-golden.test.sh" > "$TMP_ROOT/positive" 2>&1 \
  || { cat "$TMP_ROOT/positive"; fail "unmodified legacy golden control failed"; }
FM_CHARACTERIZATION_ROOT="$TMP_ROOT/subject" bash "$ROOT/tests/fm-remote-root-characterization.test.sh" >> "$TMP_ROOT/positive" 2>&1 \
  || { cat "$TMP_ROOT/positive"; fail "unmodified reaper golden control failed"; }
FM_CHARACTERIZATION_ROOT="$TMP_ROOT/subject" bash "$ROOT/tests/fm-remote-legacy-cleanup.test.sh" >> "$TMP_ROOT/positive" 2>&1 \
  || { cat "$TMP_ROOT/positive"; fail "unmodified cleanup golden control failed"; }
mutant() { # <file> <old> <new> <suite> <expected failure>
  local file=$1 old=$2 new=$3 suite=$4 reason=$5
  cp "$SUBJECT/bin/$file" "$TMP_ROOT/subject/bin/$file"
  python3 - "$TMP_ROOT/subject/bin/$file" "$old" "$new" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
if text.count(sys.argv[2]) != 1:
    raise SystemExit('mutation site changed: refresh negative control explicitly')
path.write_text(text.replace(sys.argv[2], sys.argv[3]))
PY
  if FM_CHARACTERIZATION_ROOT="$TMP_ROOT/subject" bash "$ROOT/tests/$suite" > "$TMP_ROOT/mutant.out" 2>&1; then
    fail "broken $file passed its legacy golden"
  fi
  assert_grep "$reason" "$TMP_ROOT/mutant.out" "mutant failed for an unrelated reason"
  cp "$SUBJECT/bin/$file" "$TMP_ROOT/subject/bin/$file"
  pass "deliberately broken $file fails: $reason"
}
mutant fm-herdr-session-lib.sh 'FM_REMOTE_HERDR_LEGACY_SESSION=fm-remote' \
  'FM_REMOTE_HERDR_LEGACY_SESSION=changed-default' fm-remote-legacy-golden.test.sh 'legacy route defaults changed'
mutant fm-remote-readiness-lib.sh $'  [ "$rc" -ne 0 ] || return 0\n  [ "$rc" -ne 255 ] || return 255' \
  $'  [ "$rc" -ne 0 ] || return 0\n  [ "$rc" -ne 255 ] || return 0' fm-remote-legacy-golden.test.sh 'ambiguous transport failure lost exit 255'
# shellcheck disable=SC2016 # Mutate literal script text, not this shell's label.
mutant fm-ff-lib.sh 'echo "$label: already current"' \
  'echo "$label: changed output"' fm-remote-legacy-golden.test.sh 'exact-current output changed'
mutant fm-remote-job-reap-orphans.sh 'would reap abandoned remote job worker' \
  'changed reap abandoned remote job worker' fm-remote-root-characterization.test.sh 'legacy dry-run golden changed'
mutant fm-remote-job-lib.sh 'FM_REMOTE_JOB_LABEL=dev.firstmate.remote-job' \
  'FM_REMOTE_JOB_LABEL=dev.firstmate.changed' fm-remote-legacy-golden.test.sh 'legacy queue default projection changed'
# shellcheck disable=SC2016 # Deliberately remove the literal fixture code call.
mutant fm-teardown.sh '"$SCRIPT_DIR/fm-remote-job-reap-orphans.sh" >&2 || true' \
  ':' fm-remote-legacy-cleanup.test.sh 'no-enrollment cleanup stopped invoking the orphan reaper'
