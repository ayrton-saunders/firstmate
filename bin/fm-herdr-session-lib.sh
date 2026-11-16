#!/usr/bin/env bash
# Source-safe remote Herdr session naming. No environment, filesystem or server
# changes occur on source. Only the registry parser supplies the legacy default.
# fm_remote_herdr_session_validate <name>; fm_remote_herdr_session_label <name>
# Names: 1-64 ASCII bytes, alphanumeric first, then letters/digits/./_/-;
# exact reserved name default is refused. Names are never normalized.

# shellcheck disable=SC2034 # exported sourcing interface, not a process env default.
FM_REMOTE_HERDR_LEGACY_SESSION=fm-remote

fm_remote_herdr_session_validate() {
  local LC_ALL=C name=${1-}
  case "$name" in ''|default|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#name}" -le 64 ]
}

fm_remote_herdr_session_label() {
  fm_remote_herdr_session_validate "${1-}" || return 1
  printf 'dev.firstmate.herdr.%s\n' "$1"
}
