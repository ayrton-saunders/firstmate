#!/bin/bash
set -eu
ROOT=$PWD
LAB="$PWD/.gate-remote-lab"
mkdir -p "$LAB/account"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
unset FM_REMOTE_JOB_STATE_ROOT FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
. "${SUBJECT:-$ROOT}/bin/fm-remote-job-lib.sh"
cleanup() {
  local state pid
  for state in "$LAB/account/.firstmate/"remote-job*; do
    [ -f "$state/worker.pid" ] || continue
    read -r pid < "$state/worker.pid"
    fm_remote_job_stop_worker_tree "$pid" || true
  done
}
trap cleanup EXIT
for name in one two; do
  mkdir -p "$LAB/$name/bin" "$LAB/account/mate"
  cp "${SUBJECT:-$ROOT}/bin/fm-remote-job-lib.sh" "${SUBJECT:-$ROOT}/bin/fm-remote-job-worker.sh" "$LAB/$name/bin/"
  printf 'fixture\n' > "$LAB/$name/AGENTS.md"
  cat > "$LAB/$name/bin/fm-probe.sh" <<'SH'
#!/bin/bash
printf 'root=%s\nhome=%s\nactive=%s\n' "$FM_ROOT_OVERRIDE" "$FM_HOME" "$FM_REMOTE_JOB_ACTIVE"
printf 'arg=<%s>\n' "$@"
cat
printf 'probe stderr\n' >&2
exit 23
SH
  cat > "$LAB/$name/bin/fm-hold.sh" <<'SH'
#!/bin/bash
trap '' HUP INT TERM
printf '%s\n' "$$" > "$1"
sleep 60
printf 'survived shutdown\n' > "$2"
SH
  chmod +x "$LAB/$name/bin/"*.sh
  git -C "$LAB/$name" init -q -b main
  git -C "$LAB/$name" add .
  git -C "$LAB/$name" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
  fm_remote_job_ensure_worker "$LAB/$name" "$LAB/account" || { printf '%s\n' "$FM_REMOTE_JOB_ERROR"; exit 1; }
  fm_remote_job_prepare_state "$LAB/account"
  printf '%s\n' "$FM_REMOTE_JOB_STATE" > "$LAB/$name.state"
  printf '%s\n' "$FM_REMOTE_JOB_LABEL" > "$LAB/$name.label"
done
read -r state1 < "$LAB/one.state"
read -r state2 < "$LAB/two.state"
read -r pid1 < "$state1/worker.pid"
read -r pid2 < "$state2/worker.pid"
printf 'Initial observed queue paths: root one=%s root two=%s\n' "$state1" "$state2"
if [ "$state1" = "$state2" ]; then
  printf 'REGRESSION: two roots share the same queue\n'
  exit 1
fi
[ "$pid1" != "$pid2" ]
for iteration in 1 2 3; do
  for name in one two; do
    fm_remote_job_ensure_worker "$LAB/$name" "$LAB/account" || { printf '%s\n' "$FM_REMOTE_JOB_ERROR"; exit 1; }
  done
done
ln -s "$LAB/one" "$LAB/alias"
fm_remote_job_ensure_worker "$LAB/alias" "$LAB/account"
[ "$FM_REMOTE_JOB_LABEL" = "$(< "$LAB/one.label")" ]
[ "$(< "$state1/worker.pid")" = "$pid1" ]
[ "$(< "$state2/worker.pid")" = "$pid2" ]
printf 'Isolated direct workers after alternating readiness and symlink alias:\nroot one: label=%s state=%s serving_pid=%s\nroot two: label=%s state=%s serving_pid=%s\n' "$(< "$LAB/one.label")" "$state1" "$pid1" "$(< "$LAB/two.label")" "$state2" "$pid2"
for name in one two; do
  fm_remote_job_stage "$LAB/account" "$LAB/$name" "$LAB/account/mate" fm-probe.sh 'two words' '' '$literal' <<< 'live synthetic stdin'
  fm_remote_job_wait "$LAB/account" "$FM_REMOTE_JOB_ID"
  [ "$FM_REMOTE_JOB_EXIT" = 23 ]
  printf '\nRoot %s real command output (exit %s):\n' "$name" "$FM_REMOTE_JOB_EXIT"
  /bin/cat "$FM_REMOTE_JOB_STDOUT"
  /bin/cat "$FM_REMOTE_JOB_STDERR" >&2
  grep -Fx "root=$LAB/$name" "$FM_REMOTE_JOB_STDOUT" > /dev/null
  grep -Fx 'active=1' "$FM_REMOTE_JOB_STDOUT" > /dev/null
  grep -Fx 'live synthetic stdin' "$FM_REMOTE_JOB_STDOUT" > /dev/null
  fm_remote_job_reap "$LAB/account" "$FM_REMOTE_JOB_ID"
done
fm_remote_job_stage "$LAB/account" "$LAB/one" "$LAB/account/mate" fm-hold.sh "$LAB/active.pid" "$LAB/unsafe-survivor" < /dev/null
for i in $(seq 1 200); do [ ! -f "$LAB/active.pid" ] || break; sleep 0.05; done
[ -f "$LAB/active.pid" ]
read -r active < "$LAB/active.pid"
printf '\nStopping root one with TERM-resistant active command pid=%s; root two stays serving_pid=%s\n' "$active" "$pid2"
fm_remote_job_stop_worker_tree "$pid1"
! kill -0 "$active" 2>/dev/null
! kill -0 "$pid1" 2>/dev/null
[ ! -f "$LAB/unsafe-survivor" ]
kill -0 "$pid2"
[ "$(< "$state2/worker.pid")" = "$pid2" ]
fm_remote_job_stage "$LAB/account" "$LAB/two" "$LAB/account/mate" fm-probe.sh after-neighbor-shutdown < /dev/null
fm_remote_job_wait "$LAB/account" "$FM_REMOTE_JOB_ID"
[ "$FM_REMOTE_JOB_EXIT" = 23 ]
/bin/cat "$FM_REMOTE_JOB_STDOUT"
/bin/cat "$FM_REMOTE_JOB_STDERR" >&2
fm_remote_job_reap "$LAB/account" "$FM_REMOTE_JOB_ID"
printf '\nActive command and root one worker stopped; neighbouring worker served its next real command without replacement.\n'
cleanup
trap - EXIT
for state in "$state1" "$state2"; do
  if [ -f "$state/worker.pid" ]; then
    read -r pid < "$state/worker.pid"
    ! kill -0 "$pid" 2>/dev/null
  fi
done
printf 'All disposable workers stopped.\n'
