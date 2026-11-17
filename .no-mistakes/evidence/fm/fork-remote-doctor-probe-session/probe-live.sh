#!/bin/bash
set -eu
ROOT=$PWD
EVID=~/.no-mistakes/evidence/01M7N9T9YGJCMJ5CAW7SV320E4
FIXTURE="$ROOT/.probe-live"
mkdir -p "$FIXTURE/account/.local/bin" "$FIXTURE/mate/state/parent-route"
PID=
cleanup() {
  if [ -n "$PID" ]; then
    kill -TERM "$PID" 2>/dev/null || true
    set +e
    wait "$PID"
    status=$?
    set -e
    printf 'worker shutdown exit=%s\n' "$status"
    PID=
  fi
  rm -rf "$FIXTURE"
}
trap cleanup EXIT
# Expose installed real tools inside the isolated account. No CLI is mocked.
for tool in tasks-axi treehouse claude; do
  resolved=$(command -v "$tool")
  ln -s "$resolved" "$FIXTURE/account/.local/bin/$tool"
done
export HOME="$FIXTURE/account" FM_HOME="$FIXTURE/mate" FM_ROOT_OVERRIDE="$ROOT"
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_REMOTE_JOB_ACTIVE FM_REMOTE_JOB_STATE_ROOT HERDR_SOCKET_PATH HERDR_SESSION HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID
. "$ROOT/bin/fm-remote-job-lib.sh"
write_route() {
  session=$1
  printf 'fpl\n' > "$FM_HOME/.fm-secondmate-home"
  printf '%s\n' 'kind=secondmate' "home=$FM_HOME" "worktree=$FM_HOME" "project=$ROOT" 'backend=herdr' 'endpoint_task_id=fpl' "window=$session:pane-1" "herdr_session=$session" 'herdr_workspace_id=workspace-1' 'herdr_tab_id=tab-1' 'herdr_pane_id=pane-1' > "$FM_HOME/state/parent-route/fpl.meta"
}
write_route fm-lab-personal
# Direct serving process, never launchd and never a Herdr server. Its own
# children run via the production env-i executor and isolated account HOME.
env -i HOME="$HOME" PATH="$PATH" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-remote-job-worker.sh" --serve > "$EVID/worker.log" 2>&1 &
PID=$!
for i in $(seq 1 100); do
  [ ! -f "$HOME/.firstmate/remote-job-$FM_REMOTE_JOB_ROOT_KEY/worker.ready" ] || break
  kill -0 "$PID"
  sleep .1
done
fm_remote_job_worker_identity_matches "$ROOT" "$HOME"
printf 'Real per-root worker ready, PID=%s\n' "$PID"
run_doctor() {
  name=$1; shift
  printf '\n=== %s: fm-remote-doctor.sh' "$name"
  printf ' %q' "$@"; printf ' ===\n'
  set +e
  env -i HOME="$HOME" FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$ROOT" PATH="$ROOT/bin:$HOME/.local/bin:$PATH" "$ROOT/bin/fm-remote-doctor.sh" "$@" > "$EVID/$name.log" 2>&1
  RC=$?
  set -e
  printf 'exit=%s\n' "$RC"
  /bin/cat "$EVID/$name.log"
}
queued_probe() {
  name=$1; shift
  job=$(fm_remote_job_stage "$HOME" "$ROOT" "$FM_HOME" fm-remote-doctor.sh "$@" </dev/null)
  fm_remote_job_wait "$HOME" "$job"
  printf '\n=== %s: real worker job %s, exit=%s ===\n' "$name" "$job" "$FM_REMOTE_JOB_EXIT"
  /bin/cat "$FM_REMOTE_JOB_STDOUT" "$FM_REMOTE_JOB_STDERR" | tee "$EVID/$name.log"
  QUEUED_RC=$FM_REMOTE_JOB_EXIT
  fm_remote_job_reap "$HOME" "$job"
}
# Independent oracle: reported incident says omission defaults to fm-remote
# and must be refused, whereas the assigned custom session must yield six facts.
queued_probe omitted-session --worker-tool-probe --backend herdr
[ "$QUEUED_RC" -eq 1 ]
grep -F "expected 'fm-remote'; refusing access" "$EVID/omitted-session.log"
run_doctor custom-explicit --herdr-session fm-lab-personal --route-id fpl --backend herdr
grep -Fx 'check remote-job-probe=ok: the remote job worker completed the required-tool probe' "$EVID/custom-explicit.log"
run_doctor custom-inferred --herdr-session fm-lab-personal --backend herdr
grep -Fx 'check remote-job-probe=ok: the remote job worker completed the required-tool probe' "$EVID/custom-inferred.log"
run_doctor wrong-session --herdr-session fm-lab-wrong --route-id fpl --backend herdr
[ "$RC" -eq 1 ]
grep -F "expected 'fm-lab-wrong'; refusing access" "$EVID/wrong-session.log"
queued_probe wrong-probe --herdr-session fm-lab-wrong --route-id fpl --worker-tool-probe --backend herdr
[ "$QUEUED_RC" -eq 1 ]
grep -F "expected 'fm-lab-wrong'; refusing access" "$EVID/wrong-probe.log"
run_doctor migration-inferred --herdr-session fm-lab-personal --birth-for-migration fm-lab-next op.live
[ "$RC" -eq 1 ]
grep -F 'migration intent is missing or disagrees' "$EVID/migration-inferred.log"
run_doctor migration-wrong --herdr-session fm-lab-wrong --birth-for-migration fm-lab-next op.live
[ "$RC" -eq 1 ]
grep -F "expected 'fm-lab-wrong'; refusing access" "$EVID/migration-wrong.log"
write_route fm-remote
run_doctor legacy --route-id fpl --backend herdr
grep -Fx 'check remote-job-probe=ok: the remote job worker completed the required-tool probe' "$EVID/legacy.log"
printf '\nAll bounded local product scenarios satisfied; unrelated readiness gaps in this disposable account are expected. No Herdr lifecycle operations were run.\n'
cleanup
trap - EXIT
