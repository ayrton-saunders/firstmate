#!/usr/bin/env bash
# Two code roots, one account, real workers and a private launchctl simulator.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SUBJECT=${FM_CHARACTERIZATION_ROOT:-$ROOT}
TMP_ROOT=$(fm_test_tmproot fm-remote-job-per-root)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
mkdir -p "$TMP_ROOT/account" "$TMP_ROOT/stub-bin" "$TMP_ROOT/launchd"
stager_pid=
cleanup() {
  local file pid attempt
  exec 7>&-
  if [ -n "$stager_pid" ]; then
    kill -TERM "$stager_pid" 2>/dev/null || true
    wait "$stager_pid" 2>/dev/null || true
  fi
  for file in "$TMP_ROOT/launchd/"*.pid; do
    [ -f "$file" ] || continue
    pid=$(cat "$file")
    kill -TERM -- "-$pid" 2>/dev/null || true
  done
  for file in "$TMP_ROOT/launchd/"*.pid; do
    [ -f "$file" ] || continue
    pid=$(cat "$file")
    for attempt in $(seq 1 400); do
      kill -0 -- "-$pid" 2>/dev/null || break
      sleep 0.05
    done
  done
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT
for name in one two; do
  mkdir -p "$TMP_ROOT/$name/bin"
  cp "$SUBJECT/bin/fm-remote-job-lib.sh" "$SUBJECT/bin/fm-remote-job-worker.sh" "$TMP_ROOT/$name/bin/"
  # shellcheck disable=SC2016 # The fixture command receives its own argument.
  printf '#!/usr/bin/env bash\n: > "$1"\n' > "$TMP_ROOT/$name/bin/fm-touch.sh"
  cat > "$TMP_ROOT/$name/bin/fm-hold.sh" <<'SH'
#!/usr/bin/env bash
: > "$1"
while [ ! -f "$2" ]; do sleep 0.05; done
if [ -n "${3:-}" ]; then : > "$3"; fi
SH
  cat > "$TMP_ROOT/$name/bin/fm-after.sh" <<'SH'
#!/usr/bin/env bash
[ -f "$1" ] || : > "$2"
: > "$3"
SH
  chmod +x "$TMP_ROOT/$name/bin/"*.sh
  printf 'fixture\n' > "$TMP_ROOT/$name/AGENTS.md"
  git -C "$TMP_ROOT/$name" init -q -b main
  git -C "$TMP_ROOT/$name" add .
  git -C "$TMP_ROOT/$name" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
done
REAL_DATE=$(command -v date)
REAL_PS=$(command -v ps)
export REAL_DATE REAL_PS
cat > "$TMP_ROOT/stub-bin/date" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = +%s ] && [ "${FM_TEST_LOCK_CLOCK:-}" = 1 ] && [ -f "$LAB/lock-clock" ]; then
  rm -f "$LAB/lock-clock"
  : > "$LAB/lock-clock-interrupted"
  printf 'invalid-clock\n'
  exit 0
fi
if [ "${1:-}" = +%s ] && [ -f "$LAB/lane-clock-target" ]; then
  parent=$("$REAL_PS" -p "$PPID" -o command=)
  case "$parent" in
    *fm-remote-job-worker.sh*--lane*)
      count=0
      [ ! -f "$LAB/clock-count.$PPID" ] || read -r count < "$LAB/clock-count.$PPID"
      count=$((count + 1))
      printf '%s\n' "$count" > "$LAB/clock-count.$PPID"
      read -r target < "$LAB/lane-clock-target"
      if [ "$count" -eq "$target" ]; then
        rm -f "$LAB/lane-clock-target"
        : > "$LAB/lane-clock-interrupted-$target"
        case "$target" in
          3) printf 'invalid-clock\n'; exit 0 ;;
          4) exit 1 ;;
          *) exit 0 ;;
        esac
      fi
      ;;
  esac
fi
if [ "${1:-}" = +%s ] && [ -f "$LAB/empty-clock" ]; then
  rm -f "$LAB/empty-clock"
  : > "$LAB/clock-interrupted"
  exit 0
fi
exec "$REAL_DATE" "$@"
SH
chmod +x "$TMP_ROOT/stub-bin/date"
cat > "$TMP_ROOT/stub-bin/launchctl" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$LAB/launchctl.log"
label=${!#}; label=${label##*/}; label=${label%.plist}
record="$LAB/launchd/$label"
case "$1" in
  print)
    case "$2" in gui/[0-9]*)
      case "$2" in gui/*/*) ;; *) exit 0 ;; esac
    esac
    [ -f "$record.plist" ] || exit 113
    worker=$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["ProgramArguments"][0])' "$record.plist")
    printf 'label = %s\npath = %s\nprogram = %s\npid = %s\n' "$label" "$(cat "$record.path")" "$worker" "$(cat "$record.pid")"
    ;;
  bootout)
    [ -f "$record.pid" ] || exit 113
    kill -TERM -- "-$(cat "$record.pid")" 2>/dev/null || true
    rm -f "$record.plist" "$record.pid" "$record.path"
    ;;
  bootstrap)
    cp "$3" "$record.plist"
    printf '%s\n' "$3" > "$record.path"
    worker=$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["ProgramArguments"][0])' "$3")
    set -m
    HOME="$LAB/account" XPC_SERVICE_NAME="$label" FM_ROOT_OVERRIDE="${worker%/bin/*}" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Darwin \
      "$worker" >> "$LAB/$label.log" 2>&1 < /dev/null &
    printf '%s\n' "$!" > "$record.pid"
    ;;
  kickstart) exit 0 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$TMP_ROOT/stub-bin/launchctl"
export LAB="$TMP_ROOT" PATH="$TMP_ROOT/stub-bin:$PATH"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Darwin
unset FM_REMOTE_JOB_STATE_ROOT
ensure() (
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$1/bin/fm-remote-job-lib.sh"
  fm_remote_job_ensure_worker "$1" "$TMP_ROOT/account" || { printf '%s\n' "$FM_REMOTE_JOB_ERROR" >&2; exit 1; }
  printf '%s\n' "$FM_REMOTE_JOB_LABEL" > "$TMP_ROOT/${1##*/}.label"
  printf '%s\n' "$FM_REMOTE_JOB_STATE" > "$TMP_ROOT/${1##*/}.state"
)
# Seed a legacy agent pointing to root one. No migration may rewrite, restart,
# or boot it out, whether it belongs to this root or to its neighbour.
(
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$TMP_ROOT/one/bin/fm-remote-job-lib.sh"
  fm_remote_job_render_launchagent "$TMP_ROOT/one" "$TMP_ROOT/account"
) > "$TMP_ROOT/legacy.original"
python3 - "$TMP_ROOT/legacy.original" "$TMP_ROOT/account" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
agent = plistlib.loads(path.read_bytes())
agent['Label'] = 'dev.firstmate.remote-job'
for key in ('StandardOutPath', 'StandardErrorPath'):
    agent[key] = sys.argv[2] + '/Library/Logs/dev.firstmate.remote-job.log'
path.write_bytes(plistlib.dumps(agent))
PY
mkdir -p "$TMP_ROOT/account/Library/LaunchAgents" "$TMP_ROOT/account/.firstmate/remote-job"
cp "$TMP_ROOT/legacy.original" "$TMP_ROOT/account/Library/LaunchAgents/dev.firstmate.remote-job.plist"
launchctl bootstrap "gui/$(id -u)" "$TMP_ROOT/account/Library/LaunchAgents/dev.firstmate.remote-job.plist"
legacy_pid=$(cat "$TMP_ROOT/launchd/dev.firstmate.remote-job.pid")
for _ in $(seq 1 400); do
  [ -f "$TMP_ROOT/account/.firstmate/remote-job/worker.ready" ] && break
  sleep 0.05
done
[ -f "$TMP_ROOT/account/.firstmate/remote-job/worker.ready" ] || fail 'legacy agent did not retain its legacy queue'
legacy_serving=$(cat "$TMP_ROOT/account/.firstmate/remote-job/worker.pid")
kill -STOP "$legacy_serving"
(
  # shellcheck disable=SC2030 # Only this subshell submits into the legacy queue.
  export FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/account/.firstmate/remote-job"
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$TMP_ROOT/one/bin/fm-remote-job-lib.sh"
  fm_remote_job_stage "$TMP_ROOT/account" "$TMP_ROOT/one" "$TMP_ROOT/account/mate" fm-hold.sh "$TMP_ROOT/legacy-started" "$TMP_ROOT/release-legacy" < /dev/null > /dev/null
  fm_remote_job_stage "$TMP_ROOT/account" "$TMP_ROOT/one" "$TMP_ROOT/account/mate" fm-touch.sh "$TMP_ROOT/legacy-drained" < /dev/null > /dev/null
)
ensure "$TMP_ROOT/one"
ensure "$TMP_ROOT/two"
(
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$TMP_ROOT/one/bin/fm-remote-job-lib.sh"
  fm_remote_job_stage "$TMP_ROOT/account" "$TMP_ROOT/one" "$TMP_ROOT/account/mate" fm-after.sh "$TMP_ROOT/legacy-drained" "$TMP_ROOT/overlap" "$TMP_ROOT/migrated" < /dev/null > /dev/null
  fm_remote_job_stage "$TMP_ROOT/account" "$TMP_ROOT/one" "$TMP_ROOT/account/other-mate" fm-touch.sh "$TMP_ROOT/other-home" < /dev/null > /dev/null
  fm_remote_job_stage "$TMP_ROOT/account" "$TMP_ROOT/two" "$TMP_ROOT/account/mate" fm-touch.sh "$TMP_ROOT/other-root" < /dev/null > /dev/null
)
for _ in $(seq 1 400); do
  [ -f "$TMP_ROOT/other-home" ] && [ -f "$TMP_ROOT/other-root" ] && break
  sleep 0.05
done
[ -f "$TMP_ROOT/other-home" ] || fail 'legacy queue blocked an unrelated home'
[ -f "$TMP_ROOT/other-root" ] || fail 'legacy queue blocked the neighbouring root'
[ ! -f "$TMP_ROOT/migrated" ] || fail 'new runner bypassed queued legacy work'
kill -CONT "$legacy_serving"
for _ in $(seq 1 400); do
  [ -f "$TMP_ROOT/legacy-started" ] && break
  sleep 0.05
done
[ -f "$TMP_ROOT/legacy-started" ] || fail 'legacy command did not start'
sleep 2
[ ! -f "$TMP_ROOT/migrated" ] || fail 'new runner overlapped running legacy work'
: > "$TMP_ROOT/release-legacy"
for _ in $(seq 1 400); do
  [ -f "$TMP_ROOT/migrated" ] && break
  sleep 0.05
done
[ -f "$TMP_ROOT/migrated" ] || fail 'new queue did not resume after legacy drained'
[ ! -f "$TMP_ROOT/overlap" ] || fail 'new command ran before the legacy FIFO drained'
pass 'migration waits for same-root/home legacy work without blocking unrelated lanes'
mkfifo "$TMP_ROOT/legacy-input"
exec 7<> "$TMP_ROOT/legacy-input"
FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/account/.firstmate/remote-job" bash -c '
  . "$LAB/one/bin/fm-remote-job-lib.sh"
  fm_remote_job_stage "$LAB/account" "$LAB/one" "$LAB/account/staging-mate" fm-hold.sh "$LAB/stage-started" "$LAB/release-stage" "$LAB/stage-finished"
' 7>&- < "$TMP_ROOT/legacy-input" > "$TMP_ROOT/staged-job" &
# shellcheck disable=SC2031 # Capture this shell's stager, not a sourced fixture's background job.
stager_pid=$!
stage_ready=0
for _ in $(seq 1 400); do
  for stage in "$TMP_ROOT/account/.firstmate/remote-job/jobs/".stage.*; do
    if [ -f "$stage/stdin" ]; then stage_ready=1; break; fi
  done
  [ "$stage_ready" -eq 0 ] || break
  sleep 0.05
done
[ "$stage_ready" -eq 1 ] || fail 'legacy submission did not block capturing stdin'
kill -0 "$stager_pid" || fail 'legacy staging owner exited before input closed'
(
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$TMP_ROOT/one/bin/fm-remote-job-lib.sh"
  fm_remote_job_stage "$TMP_ROOT/account" "$TMP_ROOT/one" "$TMP_ROOT/account/staging-mate" fm-after.sh "$TMP_ROOT/stage-finished" "$TMP_ROOT/stage-overlap" "$TMP_ROOT/stage-migrated" < /dev/null > /dev/null
  fm_remote_job_stage "$TMP_ROOT/account" "$TMP_ROOT/one" "$TMP_ROOT/account/other-mate" fm-touch.sh "$TMP_ROOT/stage-other-home" < /dev/null > /dev/null
  fm_remote_job_stage "$TMP_ROOT/account" "$TMP_ROOT/two" "$TMP_ROOT/account/staging-mate" fm-touch.sh "$TMP_ROOT/stage-other-root" < /dev/null > /dev/null
)
for _ in $(seq 1 400); do
  [ -f "$TMP_ROOT/stage-other-home" ] && [ -f "$TMP_ROOT/stage-other-root" ] && break
  sleep 0.05
done
[ -f "$TMP_ROOT/stage-other-home" ] || fail 'legacy staging blocked another home'
[ -f "$TMP_ROOT/stage-other-root" ] || fail 'legacy staging blocked another root'
sleep 2
[ ! -f "$TMP_ROOT/stage-migrated" ] || fail 'new command bypassed live legacy staging'
exec 7>&-
wait "$stager_pid"
stager_pid=
for _ in $(seq 1 400); do
  [ -f "$TMP_ROOT/stage-started" ] && break
  sleep 0.05
done
[ -f "$TMP_ROOT/stage-started" ] || fail 'legacy stage did not publish and execute'
sleep 2
[ ! -f "$TMP_ROOT/stage-migrated" ] || fail 'publication lost the legacy reservation'
: > "$TMP_ROOT/release-stage"
for _ in $(seq 1 400); do
  [ -f "$TMP_ROOT/stage-migrated" ] && break
  sleep 0.05
done
[ -f "$TMP_ROOT/stage-migrated" ] || fail 'new command did not resume after legacy staging completed'
[ ! -f "$TMP_ROOT/stage-overlap" ] || fail 'new command overtook the legacy stage'
pass 'live legacy staging reserves its lane through publication and execution'
# Inject an interrupted date only after staging, while the serving child is
# stopped. Its next queue pass must defer work, never compare an empty number.
state=$(cat "$TMP_ROOT/one.state")
serving=$(cat "$state/worker.pid")
kill -STOP "$serving"
(
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$TMP_ROOT/one/bin/fm-remote-job-lib.sh"
  fm_remote_job_stage "$TMP_ROOT/account" "$TMP_ROOT/one" "$TMP_ROOT/account/mate" fm-touch.sh "$TMP_ROOT/touched" < /dev/null > /dev/null
)
: > "$TMP_ROOT/empty-clock"
kill -CONT "$serving"
for _ in $(seq 1 400); do
  [ -f "$TMP_ROOT/touched" ] && break
  sleep 0.05
done
[ -f "$TMP_ROOT/clock-interrupted" ] || fail 'clock fault was not exercised'
[ -f "$TMP_ROOT/touched" ] || fail 'queue did not recover after the interrupted clock'
if grep -q 'integer expression expected' "$TMP_ROOT/"*.log; then fail 'empty clock reached a numeric comparison'; fi
pass 'an interrupted queue clock is deferred and work resumes without numeric diagnostics'
ensure "$TMP_ROOT/two"
cp "$TMP_ROOT/launchctl.log" "$TMP_ROOT/initial.calls"
ensure "$TMP_ROOT/one"
ensure "$TMP_ROOT/two"
# shellcheck disable=SC2031 # Sourced helpers run in the subshell; the outer loop owns name.
for name in one two; do
  (
    # shellcheck source=bin/fm-remote-job-lib.sh
    . "$TMP_ROOT/$name/bin/fm-remote-job-lib.sh"
    fm_remote_job_launchagent_contract_matches "$TMP_ROOT/$name" "$TMP_ROOT/account"
    fm_remote_job_probe "$TMP_ROOT/account"
  ) || fail "root $name lost its runner after the other root's readiness repair"
done
[ "$(cat "$TMP_ROOT/one.label")" != "$(cat "$TMP_ROOT/two.label")" ] || fail 'roots share a label'
[ "$(cat "$TMP_ROOT/one.state")" != "$(cat "$TMP_ROOT/two.state")" ] || fail 'roots share a queue'
[ "$(grep -c '^bootstrap ' "$TMP_ROOT/launchctl.log")" = 3 ] || fail 'repeat readiness reinstalled a runner'
[ "$(grep -c '^kickstart ' "$TMP_ROOT/launchctl.log")" = "$(grep -c '^kickstart ' "$TMP_ROOT/initial.calls")" ] || fail 'repeat readiness restarted a runner'
if grep -E '^(bootout|kickstart).*gui/[0-9]+/dev.firstmate.remote-job$' "$TMP_ROOT/launchctl.log"; then
  fail 'migration touched the legacy runner'
fi
kill -0 "$legacy_pid" || fail 'migration killed the legacy worker'
cmp "$TMP_ROOT/legacy.original" "$TMP_ROOT/account/Library/LaunchAgents/dev.firstmate.remote-job.plist" || fail 'migration rewrote legacy plist'
ln -s "$TMP_ROOT/one" "$TMP_ROOT/alias"
ensure "$TMP_ROOT/alias"
(
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$TMP_ROOT/alias/bin/fm-remote-job-lib.sh"
  [ "$FM_REMOTE_JOB_LABEL" = "$(cat "$TMP_ROOT/one.label")" ]
  fm_remote_job_prepare_state "$TMP_ROOT/account"
  [ "$FM_REMOTE_JOB_STATE" = "$(cat "$TMP_ROOT/one.state")" ]
) || fail 'symlink changed root identity'
pass 'two roots keep separate runners and queues, preserve legacy, and converge through symlinks'

# A failed clock cannot reclaim a stale lock or abort startup arithmetic.
mkdir -p "$TMP_ROOT/clock-account" "$TMP_ROOT/clock-state/worker.lock"
touch -t 200001010000 "$TMP_ROOT/clock-state/worker.lock"
: > "$TMP_ROOT/lock-clock"
set -m
HOME="$TMP_ROOT/clock-account" FM_ROOT_OVERRIDE="$TMP_ROOT/one" \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/clock-state" FM_TEST_LOCK_CLOCK=1 \
  "$TMP_ROOT/one/bin/fm-remote-job-worker.sh" --serve > "$TMP_ROOT/lock-clock.log" 2>&1 &
# shellcheck disable=SC2031 # Capture this shell's worker, not a sourced fixture's background job.
lock_clock_pid=$!
set +m
printf '%s\n' "$lock_clock_pid" > "$TMP_ROOT/launchd/clock-lock.pid"
for _ in $(seq 1 400); do
  [ -f "$TMP_ROOT/clock-state/worker.ready" ] && break
  kill -0 "$lock_clock_pid" 2>/dev/null || break
  sleep 0.05
done
[ -f "$TMP_ROOT/lock-clock-interrupted" ] || fail 'lock clock fault was not exercised'
[ -f "$TMP_ROOT/clock-state/worker.ready" ] || fail 'an invalid lock clock aborted worker startup'
pass 'an invalid lock clock defers stale-lock reclamation without arithmetic failure'

# These are the three execution-budget clock reads after the lane's initial
# deadline check. Exercise empty, malformed, and failed date output separately.
for clock_read in 2 3 4; do
  printf '%s\n' "$clock_read" > "$TMP_ROOT/lane-clock-target"
  (
    # shellcheck source=bin/fm-remote-job-lib.sh
    . "$TMP_ROOT/one/bin/fm-remote-job-lib.sh"
    export FM_REMOTE_JOB_TIMEOUT=4 FM_REMOTE_JOB_QUEUE_TIMEOUT=8 FM_REMOTE_JOB_WAIT_GRACE=2
    fm_remote_job_stage "$TMP_ROOT/account" "$TMP_ROOT/one" "$TMP_ROOT/account/clock-mate" fm-touch.sh "$TMP_ROOT/clock-$clock_read-ran" < /dev/null > /dev/null
    fm_remote_job_wait "$TMP_ROOT/account" "$FM_REMOTE_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
    [ "$FM_REMOTE_JOB_EXIT" = 125 ] || fail "invalid execution clock $clock_read did not return an internal error"
    [ ! -e "$FM_REMOTE_JOB_JOBS/$FM_REMOTE_JOB_ID/.stdout.pipe" ] || fail 'clock failure left an output pipe'
    [ ! -e "$FM_REMOTE_JOB_JOBS/$FM_REMOTE_JOB_ID/.stderr.pipe" ] || fail 'clock failure left an error pipe'
  )
  [ -f "$TMP_ROOT/lane-clock-interrupted-$clock_read" ] || fail "execution clock $clock_read fault was not exercised"
  [ ! -f "$TMP_ROOT/clock-$clock_read-ran" ] || fail 'an invalid clock allowed command execution'
done
if grep -Eq 'integer expression expected|syntax error|unbound variable' "$TMP_ROOT/"*.log; then
  fail 'an invalid worker clock reached arithmetic'
fi
pass 'all execution-budget clock failures return bounded errors without running commands'

# Lab C: a retired or crashed legacy worker cannot finish these records.
# Their own persisted deadlines must eventually release migration reservations.
kill -TERM -- "-$legacy_pid"
for _ in $(seq 1 400); do
  kill -0 -- "-$legacy_pid" 2>/dev/null || break
  sleep 0.05
done
! kill -0 -- "-$legacy_pid" 2>/dev/null || fail 'fixture legacy worker did not stop'
(
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$TMP_ROOT/one/bin/fm-remote-job-lib.sh"
  # shellcheck disable=SC2030,SC2031 # Only these leftovers belong to this subshell's legacy queue.
  export FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/account/.firstmate/remote-job"
  expired=$(( $(date +%s) - 1 ))
  fm_remote_job_stage "$TMP_ROOT/account" "$TMP_ROOT/one" "$TMP_ROOT/account/expired-queued" fm-touch.sh "$TMP_ROOT/legacy-must-not-run" < /dev/null > /dev/null
  fm_remote_job_write_number "$FM_REMOTE_JOB_JOBS/$FM_REMOTE_JOB_ID" queue_deadline "$expired"
  fm_remote_job_stage "$TMP_ROOT/account" "$TMP_ROOT/one" "$TMP_ROOT/account/expired-running" fm-touch.sh "$TMP_ROOT/legacy-must-not-run" < /dev/null > /dev/null
  fm_remote_job_write_number "$FM_REMOTE_JOB_JOBS/$FM_REMOTE_JOB_ID" deadline "$expired"
  fm_remote_job_write_state "$FM_REMOTE_JOB_JOBS/$FM_REMOTE_JOB_ID" running
)
(
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$TMP_ROOT/one/bin/fm-remote-job-lib.sh"
  for home in expired-queued expired-running; do
    fm_remote_job_stage "$TMP_ROOT/account" "$TMP_ROOT/one" "$TMP_ROOT/account/$home" fm-touch.sh "$TMP_ROOT/$home-ran" < /dev/null > /dev/null
  done
)
for _ in $(seq 1 200); do
  [ -f "$TMP_ROOT/expired-queued-ran" ] && [ -f "$TMP_ROOT/expired-running-ran" ] && break
  sleep 0.05
done
[ -f "$TMP_ROOT/expired-queued-ran" ] || fail 'expired orphaned queued legacy record still reserves its home'
[ -f "$TMP_ROOT/expired-running-ran" ] || fail 'expired orphaned running legacy record still reserves its home'
[ ! -f "$TMP_ROOT/legacy-must-not-run" ] || fail 'migration executed a legacy leftover'
pass 'expired orphaned legacy queued and running records release their homes'
