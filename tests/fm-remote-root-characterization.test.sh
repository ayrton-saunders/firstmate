#!/usr/bin/env bash
# Stage-1 no-enrollment golden effects and candidate runner command-shape probe.
# Only fixture processes are enumerated; the signal builtin is replaced in the
# reaper subprocess. Never run an account-wide process sweep in this suite.
# FM_CHARACTERIZATION_ROOT selects an extracted baseline bin/ for differential
# runs. It is not a production override or an enrollment interface.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SUBJECT=${FM_CHARACTERIZATION_ROOT:-$ROOT}
TMP_ROOT=$(fm_test_tmproot fm-remote-root-characterization)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
launcher=
cleanup() {
  touch "$TMP_ROOT/finish"
  if [ -n "$launcher" ]; then wait "$launcher" || true; fi
  fm_test_cleanup
}
trap cleanup EXIT
mkdir -p "$TMP_ROOT/tools" "$TMP_ROOT/pruned/bin" "$TMP_ROOT/installed"
printf 'fixture root\n' > "$TMP_ROOT/pruned/AGENTS.md"
# All candidate processes stay alive until the test has inspected their real
# command lines. The Python launcher owns and joins only its own children.
cat > "$TMP_ROOT/installed/runner" <<'SH'
#!/usr/bin/env bash
"$1" --serve --binding candidate-binding &
child=$!
wait "$child"
SH
cat > "$TMP_ROOT/pruned/bin/fm-remote-job-worker.sh" <<'SH'
#!/usr/bin/env bash
: > "$FIXTURE_READY_DIR/ready.$$"
if [ "${1:-}" = --serve ] && [ "${2:-}" = --binding ]; then
  "$BASH" "$0" --lane candidate-job --binding candidate-binding &
  lane=$!
  printf '%s\n' "$lane" > "$FIXTURE_READY_DIR/lane-pid"
  while [ ! -e "$FIXTURE_FINISH" ]; do sleep 0.1; done
  wait "$lane"
else
  while [ ! -e "$FIXTURE_FINISH" ]; do sleep 0.1; done
fi
SH
chmod +x "$TMP_ROOT/installed/runner" "$TMP_ROOT/pruned/bin/fm-remote-job-worker.sh"
cat > "$TMP_ROOT/launch.py" <<'PY'
import os
import pathlib
import shutil
import subprocess
import sys
import time

base = pathlib.Path(sys.argv[1])
worker = str(base / 'pruned/bin/fm-remote-job-worker.sh')
env = dict(os.environ, FIXTURE_FINISH=str(base / 'finish'), FIXTURE_READY_DIR=str(base))
shell = shutil.which('bash')
commands = [
    [shell, str(base / 'installed/runner'), worker, '--worker', 'candidate-binding'],
    [shell, worker, '--serve'],  # positive legacy parser control
]
children = []
try:
    for command in commands:
        children.append(subprocess.Popen(command, env=env, start_new_session=True))
    (base / 'pids').write_text('\n'.join(str(p.pid) for p in children) + '\n')
    while not (base / 'finish').exists():
        if any(p.poll() is not None for p in children):
            raise RuntimeError('fixture process exited before observation')
        time.sleep(0.1)
finally:
    (base / 'finish').touch()
    for child in children:
        child.wait(timeout=15)
PY
python3 "$TMP_ROOT/launch.py" "$TMP_ROOT" > "$TMP_ROOT/launch.out" 2>&1 &
launcher=$!
for ((i=0; i<200; i++)); do
  [ ! -f "$TMP_ROOT/pids" ] || break
  sleep 0.1
done
[ -f "$TMP_ROOT/pids" ] || fail "candidate processes did not start"
runner=$(head -n 1 "$TMP_ROOT/pids")
legacy=$(tail -n 1 "$TMP_ROOT/pids")
serve=
for ((i=0; i<200; i++)); do
  serve=$(pgrep -P "$runner" | head -n 1 || true)
  [ -z "$serve" ] || break
  sleep 0.1
done
[ -n "$serve" ] || fail "candidate runner did not start its serving descendant"
for ((i=0; i<200; i++)); do
  [ ! -f "$TMP_ROOT/lane-pid" ] || break
  sleep 0.1
done
[ -f "$TMP_ROOT/lane-pid" ] || fail "serving descendant did not start its lane"
lane=$(cat "$TMP_ROOT/lane-pid")
[ "$(ps -p "$lane" -o ppid= | tr -d '[:space:]')" = "$serve" ] || fail "lane is not a serving-child descendant"
# Popen/ps can see argv before Bash has opened its script. Do not prune until
# every fixture script has positively entered; otherwise the positive control
# sometimes exits before the reaper's independent live-command read-back.
for pid in "$serve" "$lane" "$legacy"; do
  for ((i=0; i<200; i++)); do
    [ ! -f "$TMP_ROOT/ready.$pid" ] || break
    sleep 0.1
  done
  [ -f "$TMP_ROOT/ready.$pid" ] || fail "fixture script did not acknowledge entry"
done
# Observe actual OS command strings, not a hand-authored process-list example.
: > "$TMP_ROOT/scan"
for pid in "$runner" "$serve" "$lane" "$legacy"; do
  command=$(ps -p "$pid" -o command=)
  printf '%s %s\n' "$pid" "$command" >> "$TMP_ROOT/scan"
done
# Include the actual auxiliary descendant commands (for example sleep), not
# only the selected worker invocations. A child that exits during observation
# is ignored; all long-lived runner/serve/lane processes were acknowledged above.
record_descendants() {
  local parent=$1 child observed
  for child in $(pgrep -P "$parent" || true); do
    observed=$(ps -p "$child" -o command= 2>/dev/null) || continue
    case "$child" in "$serve"|"$lane") ;; *) printf '%s %s\n' "$child" "$observed" >> "$TMP_ROOT/scan" ;; esac
    record_descendants "$child"
  done
}
record_descendants "$runner"
record_descendants "$legacy"
# Pin that all interesting shapes really existed before exercising the parser.
assert_grep '--serve --binding candidate-binding' "$TMP_ROOT/scan" "serving shape absent"
assert_grep '--lane candidate-job --binding candidate-binding' "$TMP_ROOT/scan" "lane shape absent"
cat > "$TMP_ROOT/tools/ps" <<'SH'
#!/usr/bin/env bash
case "$1" in
  -u) exec "$FIXTURE_CAT" "$FIXTURE_SCAN" ;;
  *) exit 1 ;; # ancestor lookup is bounded to this fixture, never the account
esac
SH
chmod +x "$TMP_ROOT/tools/ps"
cat > "$TMP_ROOT/no-signals" <<'SH'
kill() {
  if [ "${1:-}" = -0 ]; then return 1; fi
  printf '%s\n' "$*" >> "$FIXTURE_SIGNALS"
  return 0
}
SH
export FIXTURE_SCAN="$TMP_ROOT/scan" FIXTURE_CAT
FIXTURE_CAT=$(command -v cat)
export FIXTURE_SIGNALS="$TMP_ROOT/signals"
: > "$FIXTURE_SIGNALS"
reaper() {
  PATH="$TMP_ROOT/tools:$PATH" BASH_ENV="$TMP_ROOT/no-signals" \
    bash "$SUBJECT/bin/fm-remote-job-reap-orphans.sh" "$@"
}
reaper > "$TMP_ROOT/healthy"
[ ! -s "$TMP_ROOT/healthy" ] || fail "legacy cleanup selected a healthy root"
[ ! -s "$FIXTURE_SIGNALS" ] || fail "legacy cleanup signalled a healthy root"
rm -rf "$TMP_ROOT/pruned"
reaper --dry-run > "$TMP_ROOT/dry"
printf 'would reap abandoned remote job worker %s (pruned code root %s)\n' \
  "$legacy" "$TMP_ROOT/pruned" > "$TMP_ROOT/expected-dry"
if ! diff -u "$TMP_ROOT/expected-dry" "$TMP_ROOT/dry"; then
  printf 'Observed fixture processes:\n'
  cat "$TMP_ROOT/scan"
  PATH="$TMP_ROOT/tools:$PATH" BASH_ENV="$TMP_ROOT/no-signals" \
    bash -x "$SUBJECT/bin/fm-remote-job-reap-orphans.sh" --dry-run >&2
  fail "legacy dry-run golden changed or candidate was selected"
fi
[ ! -s "$FIXTURE_SIGNALS" ] || fail "dry run signalled a process"
reaper > "$TMP_ROOT/reap"
printf 'reaped abandoned remote job worker %s (pruned code root %s)\n' \
  "$legacy" "$TMP_ROOT/pruned" > "$TMP_ROOT/expected-reap"
diff -u "$TMP_ROOT/expected-reap" "$TMP_ROOT/reap" || fail "legacy reap golden changed or candidate was selected"
printf -- '-TERM -- -%s\n' "$legacy" > "$TMP_ROOT/expected-signals"
diff -u "$TMP_ROOT/expected-signals" "$FIXTURE_SIGNALS" || fail "legacy signal footprint changed"
for pid in "$runner" "$serve" "$lane" "$legacy"; do
  kill -0 "$pid" || fail "the signal sandbox touched a real process"
done
pass "no-enrollment reaper output and TERM footprint remain unchanged"
pass "baseline reaper excludes the live candidate runner, serving child and lane command shapes"
# No production named runner exists yet. This is a candidate ABI constraint,
# not qualification of a future implementation or proof of admission.
