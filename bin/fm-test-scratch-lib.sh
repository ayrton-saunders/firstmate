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

fm_test_allocate_scratch() {
  local allocated pending=0 rc=0
  FM_TEST_SCRATCH=
  trap '[ -z "$FM_TEST_SCRATCH" ] || fm_test_remove_tree "$FM_TEST_SCRATCH"' EXIT
  trap 'pending=129' HUP
  trap 'pending=130' INT
  trap 'pending=131' QUIT
  trap 'pending=143' TERM
  if allocated=$(trap '' HUP INT QUIT TERM; mktemp "$@"); then
    FM_TEST_SCRATCH=$allocated
  else
    rc=$?
  fi
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 131' QUIT
  trap 'exit 143' TERM
  [ "$pending" -eq 0 ] || exit "$pending"
  return "$rc"
}

fm_test_check_scratch_placement() {
  local root=$1 base=$2 blocked ancestor
  ancestor=$base
  while :; do
    for blocked in "$root" "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" \
      "$HOME/.firstmate-preserved" "$HOME/.treehouse" "${TREEHOUSE_ROOT:-}"; do
      [ -n "$blocked" ] || continue
      if [ "$ancestor" = "${blocked%/}" ] || [ "$ancestor" -ef "$blocked" ]; then
        printf 'unsafe scratch base %s resolves inside %s\n' "$base" "$blocked" >&2
        return 2
      fi
    done
    if [ -e "$ancestor/.git" ]; then
      printf 'unsafe scratch base %s resolves inside checkout %s\n' "$base" "$ancestor" >&2
      return 2
    fi
    [ "$ancestor" != / ] || break
    ancestor=${ancestor%/*}
    ancestor=${ancestor:-/}
  done
}

fm_test_validate_scratch_base() {
  local root=$1 requested=$2 base
  base=$(CDPATH='' cd -P -- "$requested" && pwd -P) || {
    printf 'cannot resolve scratch base: %s\n' "$requested" >&2
    return 2
  }
  fm_test_check_scratch_placement "$root" "$base" || return "$?"
  printf '%s\n' "$base"
}

# An interrupt just after publication can leave complete opt-in evidence without a printed path.
fm_test_copy_hermes_evidence() (
  local lab=$1 base=$2 stage= evidence entry
  local -a entries=()
  set -o pipefail
  trap '[ -z "$stage" ] || fm_test_remove_tree "$stage"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 131' QUIT
  trap 'exit 143' TERM
  shopt -s dotglob nullglob
  set -- "$lab"/*
  [ "$#" -gt 0 ] || return 1
  for entry in "$@"; do entries+=("./${entry##*/}"); done
  stage=$(mktemp -d "${lab%/}/fm-hermes-evidence.XXXXXX") || return 1
  evidence="${base%/}/${stage##*/}"
  tar -C "$lab" -cf - "${entries[@]}" | tar -C "$stage" -xf - || return 1
  set -- "$stage"/*
  [ "$#" -gt 0 ] || return 1

  python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$stage" "$evidence" || return 1
  stage=
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
