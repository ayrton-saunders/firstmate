#!/bin/bash
set -eu
ROOT=$PWD
E=~/.no-mistakes/evidence/01M7NFZSW3SBAKS5E5WA6D4ECB
D="$ROOT/.test-live/account"
H="$ROOT/.test-live/route"
mkdir -p "$D/.local/bin" "$H" "$ROOT/.test-live/bootstrap" "$ROOT/.test-live/basebin"
for tool in tasks-axi treehouse claude; do
  resolved=$(command -v "$tool")
  ln -sf "$resolved" "$D/.local/bin/$tool"
done
ln -sf "$(command -v jq)" "$ROOT/.test-live/bootstrap/jq"
# Parent models the minimal SSH bootstrap PATH. Worker uses the real product's
# filesystem-composed PATH and discovers the installed Herdr CLI itself.
export HOME="$D" FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT"
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_REMOTE_JOB_ACTIVE FM_REMOTE_JOB_STATE_ROOT HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID TASKS_AXI_FILE TASKS_AXI_BACKEND
. "$ROOT/bin/fm-remote-job-lib.sh"
worker=
cleanup() { if [ -n "$worker" ]; then kill -TERM "$worker" 2>/dev/null || true; wait "$worker" || true; fi; }
trap cleanup EXIT
"$ROOT/bin/fm-remote-job-worker.sh" --serve > "$E/live-worker.stdout" 2> "$E/live-worker.stderr" &
worker=$!
for ((i=0;i<100;i++)); do
  if fm_remote_job_probe "$D" && fm_remote_job_worker_identity_matches "$ROOT" "$D"; then break; fi
  sleep .1
done
fm_remote_job_probe "$D"
fm_remote_job_worker_identity_matches "$ROOT" "$D"
run_doctor() {
  local name=$1 cli=$2 rc
  shift 2
  set +e
  PATH="$ROOT/bin:$ROOT/.test-live/bootstrap:/usr/bin:/bin:/usr/sbin:/sbin" "$cli" "$@" > "$E/$name.log" 2>&1
  rc=$?
  set -e
  printf '\nprocess_exit=%s\n' "$rc" >> "$E/$name.log"
  LAST_RC=$rc
}
assert_output() { grep -F -- "$2" "$E/$1.log" >/dev/null || { printf 'missing expectation %s in %s\n' "$2" "$1"; exit 1; }; }
run_doctor seed "$ROOT/bin/fm-remote-doctor.sh" --herdr-session fm-lab-probe-personal --route-id fpl
assert_output seed 'check remote-job-probe=ok: the remote job worker completed the required-tool probe'
[ ! -e "$H/.fm-secondmate-home" ]
printf 'PASS seed: unmarked home probed without being provisioned\n'
printf 'fpl\n' > "$H/.fm-secondmate-home"
mkdir -p "$H/state/parent-route"
printf '%s\n' kind=secondmate "home=$H" "worktree=$H" "project=$ROOT" backend=herdr endpoint_task_id=fpl window=fm-lab-probe-personal:pane-1 herdr_session=fm-lab-probe-personal herdr_workspace_id=workspace-1 herdr_tab_id=tab-1 herdr_pane_id=pane-1 > "$H/state/parent-route/fpl.meta"
# Execute the previous parent doctor with current dependencies and current real
# worker. The old missing-session staging must still reproduce the incident.
for f in "$ROOT"/bin/*; do ln -sf "$f" "$ROOT/.test-live/basebin/${f##*/}"; done
rm "$ROOT/.test-live/basebin/fm-remote-doctor.sh"
git show 0644e6e17cbbc6580b666c80c7dd6487416da040:bin/fm-remote-doctor.sh > "$ROOT/.test-live/basebin/fm-remote-doctor.sh"
chmod +x "$ROOT/.test-live/basebin/fm-remote-doctor.sh"
run_doctor before-fix "$ROOT/.test-live/basebin/fm-remote-doctor.sh" --herdr-session fm-lab-probe-personal --route-id fpl
assert_output before-fix 'check remote-job-probe=fixable: the remote job worker returned an invalid required-tool probe result'
printf 'REPRODUCED previous parent: invalid required-tool probe\n'
run_doctor assigned "$ROOT/bin/fm-remote-doctor.sh" --herdr-session fm-lab-probe-personal --route-id fpl
assert_output assigned 'check remote-job-probe=ok: the remote job worker completed the required-tool probe'
assert_output assigned 'required herdr='
run_doctor inferred "$ROOT/bin/fm-remote-doctor.sh" --herdr-session fm-lab-probe-personal
assert_output inferred 'check remote-job-probe=ok: the remote job worker completed the required-tool probe'
printf 'PASS assigned and inferred custom route: real child returned valid Herdr tool facts\n'
run_doctor wrong-session "$ROOT/bin/fm-remote-doctor.sh" --herdr-session fm-lab-probe-wrong --route-id fpl
[ "$LAST_RC" = 1 ]
assert_output wrong-session "expected 'fm-lab-probe-wrong'; refusing access"
# Probe mode is driven through the actual queue, not by fabricating its active marker.
job=$(fm_remote_job_stage "$D" "$ROOT" "$H" fm-remote-doctor.sh --herdr-session fm-lab-probe-wrong --route-id fpl --worker-tool-probe --backend herdr </dev/null)
fm_remote_job_wait "$D" "$job"
cp "$FM_REMOTE_JOB_STDOUT" "$E/wrong-worker-probe.stdout"
cp "$FM_REMOTE_JOB_STDERR" "$E/wrong-worker-probe.stderr"
printf 'process_exit=%s\n' "$FM_REMOTE_JOB_EXIT" > "$E/wrong-worker-probe.log"
[ "$FM_REMOTE_JOB_EXIT" = 1 ]
[ ! -s "$FM_REMOTE_JOB_STDOUT" ]
grep -F "expected 'fm-lab-probe-wrong'; refusing access" "$FM_REMOTE_JOB_STDERR"
fm_remote_job_reap "$D" "$job"
printf 'PASS wrong session: both readiness and queued worker probe refused\n'
run_doctor migration-source "$ROOT/bin/fm-remote-doctor.sh" --herdr-session fm-lab-probe-personal --birth-for-migration fm-lab-probe-next op.test
[ "$LAST_RC" = 1 ]
assert_output migration-source 'migration intent is missing or disagrees'
run_doctor migration-wrong-source "$ROOT/bin/fm-remote-doctor.sh" --herdr-session fm-lab-probe-wrong --birth-for-migration fm-lab-probe-next op.test
[ "$LAST_RC" = 1 ]
assert_output migration-wrong-source "expected 'fm-lab-probe-wrong'; refusing access"
printf 'PASS migration source: inferred ownership admitted only correct source to intent guard; no lifecycle called\n'
cleanup
worker=
printf 'Worker stopped and waited; disposable homes remain only for removal by test runner.\n'
