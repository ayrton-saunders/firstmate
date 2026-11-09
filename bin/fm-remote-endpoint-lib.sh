#!/usr/bin/env bash
# Source-safe execution-boundary checks for route-owned remote operations.

fm_remote_endpoint_command_options() {
  . "$(dirname "${BASH_SOURCE[0]}")/fm-herdr-session-lib.sh"
  FM_REMOTE_COMMAND_SESSION=$FM_REMOTE_HERDR_LEGACY_SESSION
  FM_REMOTE_COMMAND_OPTION_COUNT=0
  if [ "${1:-}" = --herdr-session ]; then
    [ "$#" -ge 2 ] || return 1
    fm_remote_herdr_session_validate "$2" || return 1
    FM_REMOTE_COMMAND_SESSION=$2
    FM_REMOTE_COMMAND_OPTION_COUNT=2
    shift 2
  fi
  fm_remote_endpoint_options "$@" || return 1
  FM_REMOTE_COMMAND_OPTION_COUNT=$((FM_REMOTE_COMMAND_OPTION_COUNT + FM_REMOTE_ENDPOINT_OPTION_COUNT))
}

fm_remote_endpoint_command_guard() {
  if [ "${FM_REMOTE_JOB_ACTIVE:-0}" = 1 ] || [ "$FM_REMOTE_COMMAND_OPTION_COUNT" -gt 0 ]; then
    fm_remote_endpoint_guard "$FM_REMOTE_COMMAND_SESSION"
  fi
}

fm_remote_endpoint_guard() {
  local session=${1:?session is required} id=${FM_REMOTE_ROUTE_ID:-} marker home=${FM_HOME:?FM_HOME is required}
  if [ -z "$id" ] && [ "$session" != "$FM_REMOTE_HERDR_LEGACY_SESSION" ]; then
    printf 'error: requested remote route identity is unavailable\n' >&2
    return 1
  fi
  [ -e "$home/.fm-secondmate-home" ] || [ -L "$home/.fm-secondmate-home" ] || {
    [ "${FM_REMOTE_JOB_ACTIVE:-0}" != 1 ] && return 0
    printf 'error: remote home ownership is unavailable\n' >&2
    return 1
  }
  [ -d "$home" ] && [ ! -L "$home" ] && [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] || return 1
  marker=$(<"$home/.fm-secondmate-home")
  if [ -n "$id" ] && [ "$marker" != "$id" ]; then
    printf 'error: remote home belongs to %s, not %s\n' "$marker" "$id" >&2
    return 1
  fi
  [ -n "$id" ] || id=$marker
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  if [ "${2:-}" = provision ] && [ ! -e "$home/state/parent-route/$id.meta" ] && [ ! -L "$home/state/parent-route/$id.meta" ] \
    && [ -z "${FM_REMOTE_EXPECTED_BACKEND:-}${FM_REMOTE_EXPECTED_TARGET:-}" ]; then
    return 0
  fi
  . "$(dirname "${BASH_SOURCE[0]}")/fm-backend.sh"
  fm_remote_endpoint_validate "$home" "$id" "$session" || {
    printf 'error: %s\n' "$REMOTE_ENDPOINT_ERROR" >&2
    return 1
  }
}

fm_remote_endpoint_options() {
  FM_REMOTE_ENDPOINT_OPTION_COUNT=0
  FM_REMOTE_EXPECTED_BACKEND=
  FM_REMOTE_EXPECTED_TARGET=
  FM_REMOTE_ROUTE_ID=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expected-backend)
        [ "$#" -ge 2 ] && [ -z "$FM_REMOTE_EXPECTED_BACKEND" ] || return 1
        case "$2" in herdr|rex) ;; *) return 1 ;; esac
        FM_REMOTE_EXPECTED_BACKEND=$2 ;;
      --expected-target)
        [ "$#" -ge 2 ] && [ -z "$FM_REMOTE_EXPECTED_TARGET" ] && [ -n "$2" ] || return 1
        FM_REMOTE_EXPECTED_TARGET=$2 ;;
      --route-id)
        [ "$#" -ge 2 ] && [ -z "$FM_REMOTE_ROUTE_ID" ] || return 1
        case "$2" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
        FM_REMOTE_ROUTE_ID=$2 ;;
      *) break ;;
    esac
    FM_REMOTE_ENDPOINT_OPTION_COUNT=$((FM_REMOTE_ENDPOINT_OPTION_COUNT + 2))
    shift 2
  done
  [ -z "$FM_REMOTE_EXPECTED_TARGET" ] || [ -n "$FM_REMOTE_EXPECTED_BACKEND" ]
}

fm_remote_endpoint_validate() {
  local home=$1 id=$2 session=$3 meta marker recorded_session server
  REMOTE_ENDPOINT_ERROR=
  REMOTE_ENDPOINT_BACKEND=
  REMOTE_ENDPOINT_TARGET=
  meta="$home/state/parent-route/$id.meta"
  REMOTE_ENDPOINT_META=$meta
  if [ ! -d "$home" ] || [ -L "$home" ] || [ ! -f "$home/.fm-secondmate-home" ] || [ -L "$home/.fm-secondmate-home" ]; then
    REMOTE_ENDPOINT_ERROR="remote home marker is unavailable or unsafe"
    return 1
  fi
  marker=$(<"$home/.fm-secondmate-home")
  if [ "$marker" != "$id" ]; then
    REMOTE_ENDPOINT_ERROR="remote home belongs to $marker, not $id"
    return 1
  fi
  if ! fm_backend_validate_task_endpoint "$meta" "$id" 2>/dev/null; then
    REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint metadata is invalid; refusing access until it is explicitly migrated"
    return 1
  fi
  local field expected value
  for field in kind home worktree; do
    case "$field" in kind) expected=secondmate ;; *) expected=$home ;; esac
    value=$(fm_backend_meta_exact_value "$meta" "$field" 2>/dev/null) || value=
    if [ "$value" != "$expected" ]; then
      REMOTE_ENDPOINT_ERROR="remote endpoint $field does not match the selected secondmate home"
      return 1
    fi
  done
  REMOTE_ENDPOINT_BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  REMOTE_ENDPOINT_TARGET=$FM_BACKEND_VALIDATED_TARGET
  if [ -n "${FM_REMOTE_EXPECTED_BACKEND:-}" ] && [ "$REMOTE_ENDPOINT_BACKEND" != "$FM_REMOTE_EXPECTED_BACKEND" ]; then
    REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint is recorded on backend '$REMOTE_ENDPOINT_BACKEND', expected '$FM_REMOTE_EXPECTED_BACKEND'; refusing access until it is explicitly migrated"
    return 1
  fi
  if [ -n "${FM_REMOTE_EXPECTED_TARGET:-}" ] && [ "$REMOTE_ENDPOINT_TARGET" != "$FM_REMOTE_EXPECTED_TARGET" ]; then
    REMOTE_ENDPOINT_ERROR="remote endpoint disagrees with requested target"
    return 1
  fi
  case "$REMOTE_ENDPOINT_BACKEND" in
    herdr)
      recorded_session=$(fm_backend_meta_exact_value "$meta" herdr_session 2>/dev/null || true)
      if [ "$recorded_session" != "$session" ]; then
        REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint is recorded in Herdr session '${recorded_session:-missing}', expected '$session'; refusing access until it is explicitly migrated"
        return 1
      fi
      case "$REMOTE_ENDPOINT_TARGET" in
        "$session":?*) ;;
        *) REMOTE_ENDPOINT_ERROR="remote endpoint target is outside Herdr session '$session'"; return 1 ;;
      esac
      ;;
    rex)
      server=$(fm_backend_meta_exact_value "$meta" rex_server 2>/dev/null || true)
      case "$server" in
        unix://?*) ;;
        *) REMOTE_ENDPOINT_ERROR="remote endpoint is not a host-local Rex server"; return 1 ;;
      esac
      ;;
    *) REMOTE_ENDPOINT_ERROR="remote endpoint is not recorded on herdr or rex"; return 1 ;;
  esac
}
