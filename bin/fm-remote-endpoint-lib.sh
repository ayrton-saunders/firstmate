#!/usr/bin/env bash
# Source-safe execution-boundary checks for route-owned remote operations.

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
  if [ ! -f "$home/.fm-secondmate-home" ] || [ -L "$home/.fm-secondmate-home" ]; then
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
