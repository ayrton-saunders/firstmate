#!/usr/bin/env bash

# Remove a fixture tree even when it holds a read-only directory, such as the
# spawn-owned state/<id>.git-hooks strip directory.
fm_test_remove_tree() {
  local dir=$1
  if [ -d "$dir" ] && [ ! -L "$dir" ]; then
    find "$dir" -type d ! -perm -0700 -exec chmod u+rwx {} \; 2>/dev/null || true
  fi
  rm -rf -- "$dir"
}

fm_test_copy_hermes_evidence() (
  local lab=$1 base=$2 evidence
  set -o pipefail
  evidence=$(mktemp -d "${base%/}/fm-hermes-evidence.XXXXXX") || return 1
  if ! tar -C "$lab" -cf - . | tar -C "$evidence" -xf -; then
    fm_test_remove_tree "$evidence"
    return 1
  fi
  shopt -s dotglob nullglob
  set -- "$evidence"/*
  if [ "$#" -eq 0 ]; then
    fm_test_remove_tree "$evidence"
    return 1
  fi
  printf 'Hermes guard evidence: %s\n' "$evidence"
)

fm_test_arm_private_tmux() {
  local marker_var=$1
  if [ -n "${FM_TEST_RETAIN_MARKER:-}" ]; then
    # An unresolved teardown marker excludes this root from automatic reaping, even after its owners exit.
    printf -v "$marker_var" '%s' "$FM_TEST_RETAIN_MARKER.$$.$marker_var"
    : >"${!marker_var}"
  fi
}

fm_test_stop_private_tmux() (
  local socket=$1 tmux_bin=$2 marker=${3:-} diagnostics output status=0
  if [ ! -S "$socket" ]; then
    [ -z "$marker" ] || rm -f -- "$marker"
    return
  fi
  # shellcheck source=bin/fm-timeout-lib.sh
  . "${BASH_SOURCE[0]%/*}/fm-timeout-lib.sh" || return 1
  diagnostics=$(mktemp "${socket%/*}/.tmux-stop.XXXXXX") || return 1
  LC_ALL=C fm_run_timed 2 "$tmux_bin" -S "$socket" kill-server >"$diagnostics" 2>&1 || status=$?
  output=$(<"$diagnostics")
  rm -f -- "$diagnostics"
  if [ "$status" -eq 0 ] || [ ! -S "$socket" ] ||
    { [ "$status" -eq 1 ] && [[ "$output" == "no server running on $socket" ]]; }; then
    [ -z "$marker" ] || rm -f -- "$marker"
    return
  fi
  printf 'not ok - tmux teardown unverified; retained socket: %s\n' "$socket" >&2
  return 1
)
