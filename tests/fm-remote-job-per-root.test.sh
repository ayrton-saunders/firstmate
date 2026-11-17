#!/usr/bin/env bash
# Two code roots, one account, real workers and a private launchctl simulator.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SUBJECT=${FM_CHARACTERIZATION_ROOT:-$ROOT}
TMP_ROOT=$(fm_test_tmproot fm-remote-job-per-root)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
mkdir -p "$TMP_ROOT/account" "$TMP_ROOT/stub-bin" "$TMP_ROOT/launchd"
cleanup() {
  local file pid
  for file in "$TMP_ROOT/launchd/"*.pid; do
    [ -f "$file" ] || continue
    pid=$(cat "$file")
    kill -TERM -- "-$pid" 2>/dev/null || true
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
while [ ! -f "$2" ]; do sleep 0.1; done
SH
  cat > "$TMP_ROOT/$name/bin/fm-after.sh" <<'SH'
#!/usr/bin/env bash
if [ ! -f "$1" ]; then : > "$2"; fi
: > "$3"
SH
  cat > "$TMP_ROOT/$name/bin/fm-hold.sh" <<'SH'
#!/usr/bin/env bash
: > "$1"
while [ ! -f "$2" ]; do sleep 0.05; done
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
export REAL_DATE
cat > "$TMP_ROOT/stub-bin/date" <<'SH'
#!/usr/bin/env bash
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
  . "$1/bin/fm-remote-job-lib.sh"
  fm_remote_job_ensure_worker "$1" "$TMP_ROOT/account" || { printf '%s\n' "$FM_REMOTE_JOB_ERROR" >&2; exit 1; }
  printf '%s\n' "$FM_REMOTE_JOB_LABEL" > "$TMP_ROOT/${1##*/}.label"
  printf '%s\n' "$FM_REMOTE_JOB_STATE" > "$TMP_ROOT/${1##*/}.state"
)
# Seed a legacy agent pointing to root one. No migration may rewrite, restart,
# or boot it out, whether it belongs to this root or to its neighbour.
(
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
  export FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/account/.firstmate/remote-job"
  . "$TMP_ROOT/one/bin/fm-remote-job-lib.sh"
  fm_remote_job_stage "$TMP_ROOT/account" "$TMP_ROOT/one" "$TMP_ROOT/account/mate" fm-hold.sh "$TMP_ROOT/legacy-started" "$TMP_ROOT/release-legacy" < /dev/null > /dev/null
  fm_remote_job_stage "$TMP_ROOT/account" "$TMP_ROOT/one" "$TMP_ROOT/account/mate" fm-touch.sh "$TMP_ROOT/legacy-drained" < /dev/null > /dev/null
)
ensure "$TMP_ROOT/one"
ensure "$TMP_ROOT/two"
(
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
# Inject an interrupted date only after staging, while the serving child is
# stopped. Its next queue pass must defer work, never compare an empty number.
state=$(cat "$TMP_ROOT/one.state")
serving=$(cat "$state/worker.pid")
kill -STOP "$serving"
(
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
  . "$TMP_ROOT/alias/bin/fm-remote-job-lib.sh"
  [ "$FM_REMOTE_JOB_LABEL" = "$(cat "$TMP_ROOT/one.label")" ]
  fm_remote_job_prepare_state "$TMP_ROOT/account"
  [ "$FM_REMOTE_JOB_STATE" = "$(cat "$TMP_ROOT/one.state")" ]
) || fail 'symlink changed root identity'
pass 'two roots keep separate runners and queues, preserve legacy, and converge through symlinks'
