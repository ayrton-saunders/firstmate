#!/usr/bin/env bash

fm_test_declared_scratch=.test-phase-tmp
fm_test_scratch_exclusion=":(top,exclude,literal)$fm_test_declared_scratch"

fm_test_copy_primary_lab() (
  set -o pipefail
  local source=$1 dest=$2 entry
  local -a entries=()
  cd -- "$source" || return 1
  shopt -s dotglob nullglob
  for entry in ./*; do
    [ "$entry" = "./$fm_test_declared_scratch" ] || entries+=("$entry")
  done
  [ "${#entries[@]}" -gt 0 ] || return 0
  tar --exclude=.git --exclude=state --exclude=projects --exclude=node_modules -cf - "${entries[@]}" |
    tar -C "$dest" -xf -
)

# Remove a fixture tree even when it holds a read-only directory, such as the
# spawn-owned state/<id>.git-hooks strip directory.
fm_test_remove_tree() {
  local dir=$1
  if [ -d "$dir" ] && [ ! -L "$dir" ]; then
    find "$dir" -type d ! -perm -0700 -exec chmod u+rwx {} \; 2>/dev/null || true
  fi
  rm -rf -- "$dir"
}

fm_test_cleanup_scratch() {
  [ -n "$1" ] || return 0
  fm_test_remove_tree "$1" && return 0
  printf 'could not remove scratch: %s\n' "$1" >&2
  return 1
}

fm_test_allocate_scratch() {
  local allocated pending=0 rc=0
  FM_TEST_SCRATCH=
  trap 'status=$?; trap "" HUP INT QUIT TERM; fm_test_cleanup_scratch "$FM_TEST_SCRATCH" || { [ "$status" -ne 0 ] || status=1; }; exit "$status"' EXIT
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

fm_test_owner_start() (
  [ -r "$ROOT/bin/fm-wake-lib.sh" ] && [ -r "$ROOT/bin/fm-path-lib.sh" ] || return 1
  FM_STATE_OVERRIDE=$2
  unset FM_PROC_ROOT_OVERRIDE
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh" || return 1
  fm_pid_start_time "$1"
)

owned_group_live() {
  local pid=$1 start=$2 state=$3 current snapshot
  kill -0 -- "-$pid" 2>/dev/null || return 1
  current=$(fm_test_owner_start "$pid" "$state") || current=
  if [ -n "$current" ]; then
    [ "$start" != unknown ] || return 2
    [ "$current" = "$start" ] || return 1
  fi
  if snapshot=$(LC_ALL=C ps -e -o pid= -o pgid= -o stat= 2>/dev/null); then
    awk -v self="$$" -v pid="$pid" -v start="$start" -v checked="$current" '
      $1 == self && NF == 3 { readable = 1 }
      $2 == pid && $3 !~ /^Z/ { live = 1 }
      END {
        if (!readable) exit 2
        if (!live) exit 1
        exit (start == "unknown" || checked == "") ? 2 : 0
      }
    ' <<<"$snapshot"
  else
    [ -n "$current" ] || return 2
  fi
}

group_members() {
  LC_ALL=C ps -e -o pid= -o pgid= -o stat= 2>/dev/null |
    awk -v group="$1" '$2 == group && $1 ~ /^[1-9][0-9]*$/ && $3 !~ /^Z/ { print $1 }'
}

group_member_identities() {
  local pid identity
  for pid in $(group_members "$1"); do
    if identity=$(fm_test_owner_start "$pid" "$2"); then printf '%s|%s\n' "$pid" "$identity"; fi
  done
}

group_has_continuity() {
  local group=$1 identities=$2 state=$3 members pid identity current
  members=$'\n'$(group_members "$group")$'\n'
  while IFS='|' read -r pid identity; do
    [[ "$members" == *$'\n'"$pid"$'\n'* ]] || continue
    current=$(fm_test_owner_start "$pid" "$state") || continue
    [ "$identity" != "$current" ] || return 0
  done <<<"$identities"
  return 1
}

fm_test_drain_groups() {
  local state=$1 record owner pid group start extra rc i attempt members drained=0
  local -a groups=() starts=() witnesses=()
  shift
  for record in "$@"; do
    IFS='|' read -r owner pid group start extra <<<"$record"
    [ "$owner" = "$UID" ] && [ "$pid" = "$group" ] && [ -n "$start" ] && [ -z "$extra" ] || continue
    case "$group" in ''|0*|*[!0-9]*) continue ;; esac
    rc=0
    owned_group_live "$group" "$start" "$state" || rc=$?
    case "$rc" in
      0|2)
        groups+=("$group"); starts+=("$start")
        members=
        if [ "$rc" -eq 0 ]; then
          members=$(group_member_identities "$group" "$state")
          members=${members:-$group|$start}
          if ! owned_group_live "$group" "$start" "$state" || ! kill -TERM -- "-$group" 2>/dev/null; then members=; fi
        fi
        witnesses+=("$members")
        ;;
    esac
  done
  if [ "${#groups[@]}" -gt 0 ]; then
    sleep 0.2
    for i in "${!groups[@]}"; do
      if [ -n "${witnesses[$i]}" ] && { owned_group_live "${groups[$i]}" "${starts[$i]}" "$state" ||
          group_has_continuity "${groups[$i]}" "${witnesses[$i]}" "$state"; }; then
        kill -KILL -- "-${groups[$i]}" 2>/dev/null || true
      fi
    done
    for i in "${!groups[@]}"; do
      for ((attempt=0; attempt<20; ++attempt)); do
        rc=0
        owned_group_live "${groups[$i]}" "${starts[$i]}" "$state" || rc=$?
        [ "$rc" -ne 1 ] || break
        sleep 0.01
      done
      [ "$rc" -eq 1 ] || drained=1
    done
  fi
  [ "$drained" -eq 0 ]
}

fm_test_scratch_retained() (
  local marker prefix=.retain-scratch
  if [ -n "${2:-}" ]; then prefix+=".$2"; fi
  shopt -u failglob
  shopt -s nullglob
  for marker in "$1/$prefix".*; do return 0; done
  return 1
)

fm_test_check_scratch_placement() {
  local root=$1 base=$2 blocked ancestor effective_home=
  if [ -n "${FM_ROOT:-}" ]; then
    effective_home=$(
      . "${BASH_SOURCE[0]%/*}/fm-path-lib.sh" || exit 2
      fm_effective_home_to effective_home "$root"
      printf '%s\n' "$effective_home"
    ) || return 2
  fi
  ancestor=$base
  while :; do
    for blocked in "$root" "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" "$effective_home" \
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
  local lab=$1 base=$2 stage evidence entry
  local -a entries=()
  set -o pipefail
  shopt -s dotglob nullglob
  set -- "$lab"/*
  [ "$#" -gt 0 ] || return 1
  for entry in "$@"; do entries+=("./${entry##*/}"); done
  fm_test_allocate_scratch -d "${base%/}/.fm-hermes-evidence-staging.XXXXXX" || return 1
  stage=$FM_TEST_SCRATCH
  evidence="${base%/}/fm-hermes-evidence.${stage##*.}"
  tar -C "$lab" -cf - "${entries[@]}" | tar -C "$stage" -xf - || return 1
  set -- "$stage"/*
  [ "$#" -gt 0 ] || return 1

  python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$stage" "$evidence" || return 1
  FM_TEST_SCRATCH=
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
