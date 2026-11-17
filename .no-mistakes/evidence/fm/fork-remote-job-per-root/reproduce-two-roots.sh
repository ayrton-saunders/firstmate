#!/usr/bin/env bash
# Drive the real Linux-start worker API with two disposable roots on one account.
set -eu
subject=$1
lab=$(mktemp -d "$PWD/.test-tmp/two-roots.XXXXXX")
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
unset FM_REMOTE_JOB_STATE_ROOT
cleanup() {
  local f pid
  for f in "$lab"/account/.firstmate/remote-job*/worker.pid; do
    [ -f "$f" ] || continue
    pid=$(<"$f")
    fm_remote_job_stop_worker_tree "$pid" || true
  done
  rm -rf "$lab"
}
trap cleanup EXIT
mkdir -p "$lab/account"
for name in one two; do
  mkdir -p "$lab/$name/bin"
  cp "$subject/bin/fm-remote-job-lib.sh" "$subject/bin/fm-remote-job-worker.sh" "$lab/$name/bin/"
  chmod +x "$lab/$name/bin/"*.sh
  printf 'fixture\n' > "$lab/$name/AGENTS.md"
done
. "$lab/one/bin/fm-remote-job-lib.sh"
iteration=0
for name in one two one two; do
  iteration=$((iteration + 1))
  if fm_remote_job_ensure_worker "$lab/$name" "$lab/account"; then
    printf 'ensure root=%s label=%s queue=%s repaired=%s\n' "$name" "$FM_REMOTE_JOB_LABEL" "$FM_REMOTE_JOB_STATE" "$FM_REMOTE_JOB_REPAIRED"
    if [ "$iteration" -gt 2 ] && [ "$FM_REMOTE_JOB_REPAIRED" -ne 0 ]; then
      printf 'FAIL: alternating readiness restarted an already installed root\n'
      exit 1
    fi
  else
    printf 'ensure root=%s FAILED: %s\n' "$name" "$FM_REMOTE_JOB_ERROR"
    exit 1
  fi
done
for name in one two; do
  (
    . "$lab/$name/bin/fm-remote-job-lib.sh"
    fm_remote_job_prepare_state "$lab/account"
    fm_remote_job_probe "$lab/account"
    printf 'root=%s independently ready\n' "$name"
  ) || exit 1
done
