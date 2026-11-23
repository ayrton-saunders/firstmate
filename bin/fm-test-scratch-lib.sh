#!/usr/bin/env bash
# Shared scratch placement for test runners, standalone probes, and fixtures.
# For direct suite runs and the isolation proof, TAP verifier, and Linux
# helpers, point TMPDIR at an existing OS temp directory to keep scratch out of
# backups. These entry points validate ${TMPDIR:-/tmp} and refuse an unsafe
# path instead of falling back. The standalone helpers' outer scratch roots
# are not enrolled in orphan recovery after SIGKILL; tests/lib.sh owns the
# separate recovery rules for registered fixtures.

# Exclude only the declared top-level scratch entry at copy time, not dirty
# or untracked work with similar names. See tests/fm-test-fixture-cleanup.test.sh.
fm_test_declared_scratch=.test-phase-tmp

fm_test_is_declared_scratch() {
  local top=${2%%/*} candidate declared identities entry found_candidate=0 found_declared=0
  [ "$top" != "$fm_test_declared_scratch" ] || return 0
  candidate="$1/$top"
  declared="$1/$fm_test_declared_scratch"
  if [ -L "$declared" ]; then
    [ -L "$candidate" ] || return 1
    (shopt -s nocasematch; [[ "$top" == "$fm_test_declared_scratch" ]]) || return 1
    identities=$(stat -c '%d:%i' -- "$candidate" "$declared" 2>/dev/null) ||
      identities=$(stat -f '%d:%i' "$candidate" "$declared") || return 1
    [ "${identities%%$'\n'*}" = "${identities#*$'\n'}" ] || return 1
    for entry in "$1"/.*; do
      [ "$entry" != "$candidate" ] || found_candidate=1
      [ "$entry" != "$declared" ] || found_declared=1
    done
    [ "$found_candidate$found_declared" != 11 ]
  else
    [ -d "$candidate" ] && [ ! -L "$candidate" ] && [ "$candidate" -ef "$declared" ]
  fi
}

# Primary labs need working-tree changes and untracked setup files, unlike
# the tracked-only remote source fixture. Keep the primary lab's existing
# Git, runtime-state and dependency exclusions as well as declared scratch.
fm_test_copy_primary_lab() (
  set -o pipefail
  local source=$1 dest=$2 entry
  local -a entries=()
  cd -- "$source" || return 1
  shopt -s dotglob nullglob
  for entry in ./*; do
    fm_test_is_declared_scratch . "${entry#./}" || entries+=("$entry")
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
  [ "$#" -eq 1 ] || return 2
  local allocated pending=0 rc=0
  FM_TEST_SCRATCH=
  trap 'status=$?; trap "" HUP INT QUIT TERM; fm_test_cleanup_scratch "$FM_TEST_SCRATCH" || { [ "$status" -ne 0 ] || status=1; }; exit "$status"' EXIT
  trap 'pending=129' HUP
  trap 'pending=130' INT
  trap 'pending=131' QUIT
  trap 'pending=143' TERM
  if allocated=$(trap '' HUP INT QUIT TERM; mktemp -d -- "$1"); then
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
  local lookup_root=${ROOT:-}
  [ -r "$lookup_root/bin/fm-wake-lib.sh" ] && [ -r "$lookup_root/bin/fm-path-lib.sh" ] || return 1
  unset FM_PROC_ROOT_OVERRIDE
  # shellcheck disable=SC2016 # Initialize wake state only in the lookup shell.
  FM_STATE_OVERRIDE=$2 exec "$BASH" -c '. "$1" || exit 1; fm_pid_start_time "$2"' _ "$lookup_root/bin/fm-wake-lib.sh" "$1"
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

fm_test_probe_interrupt() {
  if [ "$probe_launching" -ne 0 ]; then probe_pending=$1; else exit "$1"; fi
}

fm_test_stdin_is_open() {
  (: <&0) 2>/dev/null
}

fm_test_probe_run() {
  local probe_launching=1 probe_pending=0 start rc=0
  trap 'fm_test_probe_interrupt 129' HUP
  trap 'fm_test_probe_interrupt 130' INT
  trap 'fm_test_probe_interrupt 131' QUIT
  trap 'fm_test_probe_interrupt 143' TERM
  set -m
  if fm_test_stdin_is_open; then
    "$@" <&0 &
  else
    "$@" </dev/null &
  fi
  probe_pid=$!
  set +m
  start=$(fm_test_owner_start "$probe_pid" "$FM_TEST_SCRATCH") || start=unknown
  probe_owner="$UID|$probe_pid|$probe_pid|$start"
  probe_launching=0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 131' QUIT
  trap 'exit 143' TERM
  [ "$probe_pending" -eq 0 ] || exit "$probe_pending"
  wait "$probe_pid" || rc=$?
  fm_test_probe_drain || return 1
  return "$rc"
}

fm_test_probe_drain() {
  [ -n "$probe_owner" ] || return 0
  fm_test_drain_groups "$FM_TEST_SCRATCH" "$probe_owner" || return 1
  wait "$probe_pid" 2>/dev/null || true
  probe_owner=
}

fm_test_scratch_retained() (
  local marker prefix=.retain-scratch
  if [ -n "${2:-}" ]; then prefix+=".$2"; fi
  shopt -u failglob
  shopt -s nullglob
  for marker in "$1/$prefix".*; do return 0; done
  return 1
)

fm_test_resolve_boundary() (
  local path=$1 links_left=${2:-40} parent leaf link_target
  if CDPATH='' cd -P -- "$path" 2>/dev/null; then
    pwd -P
    return
  fi
  path=${path%"${path##*[!/]}"}
  [ -n "$path" ] || return 1
  leaf=${path##*/}
  if [ -L "$path" ]; then
    [ "$links_left" -gt 0 ] || return 1
    link_target=$(readlink -- "$path") || return 1
    case "$OSTYPE" in msys*|cygwin*) link_target=${link_target//\\//} ;; esac
    case "$link_target" in
      /*|[a-zA-Z]:/*) ;;
      *) link_target=${path%"$leaf"}$link_target ;;
    esac
    fm_test_resolve_boundary "$link_target" "$((links_left - 1))"
    return
  fi
  case "$path" in
    */*) parent=$(fm_test_resolve_boundary "${path%/*}/" "$links_left") || return 1 ;;
    *) parent=$(pwd -P) || return 1 ;;
  esac
  case "$leaf" in
    .) printf '%s\n' "$parent" ;;
    ..) parent=${parent%/*}; printf '%s\n' "${parent:-/}" ;;
    *) printf '%s/%s\n' "${parent%/}" "$leaf" ;;
  esac
)

fm_test_missing_boundary_matches() (
  local candidate=$1 boundary=$2 LC_ALL=C
  [ "$candidate" != "$boundary" ] || return 0
  [ ! -e "$boundary" ] || return 1
  shopt -s nocasematch
  [[ "${candidate##*/}" == "${boundary##*/}" ]] &&
    [ "${candidate%/*}/" -ef "${boundary%/*}/" ]
)

fm_test_anchor_inherited_paths() {
  local origin=$1 name value
  for name in FM_HOME FM_ROOT_OVERRIDE FM_ROOT FM_STATE_OVERRIDE STATE FM_DATA_OVERRIDE \
    FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TREEHOUSE_ROOT HOME; do
    value=${!name-}
    case "$value" in
      ''|/*|[a-zA-Z]:/*|[a-zA-Z]:\\*) continue ;;
    esac
    value=$(CDPATH='' cd -P -- "$origin" && fm_test_resolve_boundary "$value") || {
      printf 'cannot resolve inherited scratch boundary: %s\n' "$name" >&2
      return 2
    }
    export "$name=$value"
  done
}

# Snapshot physical paths for validation in child shells, not as operational overrides.
# The newline-delimited handoff accepts spaces but not control characters.
fm_test_snapshot_boundaries() {
  local boundary resolved
  local -a protected_paths
  fm_test_protected_paths "$1"
  for boundary in "${protected_paths[@]}" "${FM_ROOT:-}" "${STATE:-}"; do
    [ -n "$boundary" ] || continue
    resolved=$(fm_test_resolve_boundary "$boundary" && printf '.') || return 2
    resolved=${resolved%$'\n.'}
    case "$resolved" in *[[:cntrl:]]*) printf 'unsupported character in scratch boundary\n' >&2; return 2 ;; esac
    printf '%s\n' "$resolved"
  done
}

fm_test_export_boundaries() {
  local snapshot
  snapshot=$(fm_test_snapshot_boundaries "$1") || return "$?"
  FM_TEST_PARENT_BOUNDARIES=${FM_TEST_PARENT_BOUNDARIES:+$FM_TEST_PARENT_BOUNDARIES$'\n'}$snapshot
  export FM_TEST_PARENT_BOUNDARIES
}

# Populate the caller's protected_paths array before a fixture clears its environment.
fm_test_protected_paths() {
  local repo_root=$1 home wake_home
  home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$repo_root}}
  # bin/fm-wake-lib.sh owns the wake home and state fallback; keep these rules in sync.
  wake_home=${FM_HOME:-${FM_ROOT_OVERRIDE:-${FM_ROOT:-$repo_root}}}
  protected_paths=("$repo_root" "$home" "${FM_ROOT_OVERRIDE:-}" "$wake_home"
    "${FM_STATE_OVERRIDE:-$home/state}" "${FM_STATE_OVERRIDE:-${STATE:-$wake_home/state}}"
    "${FM_DATA_OVERRIDE:-$home/data}" "${FM_CONFIG_OVERRIDE:-$home/config}" "${FM_PROJECTS_OVERRIDE:-$home/projects}"
    "$HOME/.firstmate-preserved" "$HOME/.treehouse" "${TREEHOUSE_ROOT:-}")
}

fm_test_check_scratch_placement() (
  local repo_root=$1 base=$2 blocked ancestor resolved rc
  local -a protected_paths
  if [ "$#" -ge 3 ]; then
    CDPATH='' cd -P -- "$3" || return 2
  fi
  fm_test_protected_paths "$repo_root"
  while IFS= read -r blocked; do
    case "$blocked" in
      /*|[a-zA-Z]:/*) protected_paths+=("$blocked") ;;
      '') ;;
      *) printf 'invalid inherited scratch boundary\n' >&2; return 2 ;;
    esac
    case "$blocked" in *[[:cntrl:]]*) return 2 ;; esac
  done <<< "${FM_TEST_PARENT_BOUNDARIES:-}"
  ancestor=$base
  while :; do
    for blocked in "${protected_paths[@]}"; do
      [ -n "$blocked" ] || continue
      rc=1
      if [ "$ancestor" = "${blocked%/}" ] || [ "$ancestor" -ef "$blocked" ]; then
        rc=0
      elif [ ! -e "$ancestor" ] && resolved=$(fm_test_resolve_boundary "$blocked"); then
        rc=0
        fm_test_missing_boundary_matches "$ancestor" "$resolved" || rc=$?
      fi
      if [ "$rc" -ne 1 ]; then
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
)

fm_test_validate_scratch_base() (
  local repo_root=$1 requested=$2 base
  if [ "$#" -ge 3 ]; then
    CDPATH='' cd -P -- "$3" || return 2
  fi
  case "$requested" in *[[:cntrl:]]*) printf 'unsupported character in scratch base\n' >&2; return 2 ;; esac
  base=$(CDPATH='' cd -P -- "$requested" && pwd -P && printf '.') || {
    printf 'cannot resolve scratch base: %s\n' "$requested" >&2
    return 2
  }
  base=${base%$'\n.'}
  case "$base" in *[[:cntrl:]]*) printf 'unsupported character in resolved scratch base\n' >&2; return 2 ;; esac
  fm_test_check_scratch_placement "$repo_root" "$base" || return "$?"
  printf '%s\n' "$base"
)

fm_test_os_scratch_base() {
  local base
  base=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || base=/tmp
  case "$base" in
    /*) ;;
    *) printf 'scratch base must be absolute: %s\n' "$base" >&2; return 2 ;;
  esac
  fm_test_validate_scratch_base "$1" "$base" "${@:2}"
}

# An interrupt just after publication can leave complete opt-in evidence without a printed path.
# During an opt-in copy, runner interruption that escalates to KILL can leave staging in OS temp.
fm_test_copy_hermes_evidence() (
  local lab=$1 base=$2 stage evidence entry
  local -a entries=()
  set -o pipefail
  shopt -s dotglob nullglob
  set -- "$lab"/*
  [ -d "$lab" ] || return 1
  for entry in "$@"; do entries+=("./${entry##*/}"); done
  fm_test_allocate_scratch "${base%/}/.fm-hermes-evidence-staging.XXXXXX" || return 1
  stage=$FM_TEST_SCRATCH
  evidence="${base%/}/fm-hermes-evidence.${stage##*.}"
  tar -C "$lab" -cf - -T /dev/null ${entries[@]+"${entries[@]}"} | tar -C "$stage" -xf - || return 1

  python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$stage" "$evidence" || return 1
  trap - EXIT
  printf 'Hermes guard evidence: %s\n' "$evidence"
)

fm_test_arm_private_tmux() {
  local marker_var=$1 root=${2:-} prefix=${FM_TEST_RETAIN_MARKER:-}
  if [ -z "$prefix" ] && [ -n "$root" ]; then
    fm_test_owns_registered_root "$root" || return 1
    prefix="$root/.retain-scratch.tmux"
  fi
  if [ -n "$prefix" ]; then
    printf -v "$marker_var" '%s' "$prefix.$$.$marker_var"
    : >"${!marker_var}"
  fi
}

# Before tmux binds its socket, an interrupted launch can look stopped to
# teardown. This helper does not prove that such a pending launch is gone.
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
