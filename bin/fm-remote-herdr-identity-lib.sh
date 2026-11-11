#!/usr/bin/env bash
# Which Herdr session and launch-agent label one Firstmate code root's remote
# second mates use on this account.
#
# Source this file; it defines functions only. It owns default allocation and
# service-owner checks: doctor and remote control pass their persisted route
# assignment when present, so allocation never overrides that assignment.
# bin/fm-spawn.sh validates the reported session against the persisted route.
#
# The code root recorded in ~/.firstmate/remote-herdr-owner owns the primary
# fm-remote session and dev.firstmate.herdr.fm-remote label. Before owner
# records existed, the guard path in the primary darwin launch agent was the
# only durable evidence of its root, so it stands in for a missing record. Every
# other code root on the account gets fm-remote-<root-id> and
# dev.firstmate.herdr.fm-remote-<root-id>, recorded in
# ~/.firstmate/remote-herdr-owner-<root-id>, where <root-id> is the first 16
# hex digits of the SHA-256 of the root path.
#
# Functions:
#   fm_remote_herdr_identity <fm-root> [assigned-session]
#     A route assignment (including legacy fm-remote) wins over allocation.
#     Only unassigned roots use the root-derived default described above.
#     A chosen session owned by another root is a named collision, never a
#     request to redirect, rename, or adopt an existing route.
#     Sets FM_REMOTE_HERDR_SESSION, FM_REMOTE_HERDR_LABEL,
#     FM_REMOTE_HERDR_OWNER_DIR, FM_REMOTE_HERDR_OWNER_FILE, and
#     FM_REMOTE_HERDR_OWNER_ROOT (the root proven to own the resolved
#     session, empty when unproven). Returns 1 when <fm-root> needs a
#     root-derived identity and no SHA-256 tool resolves.
#   fm_remote_herdr_recorded_owner <owner-file>
#     Prints the root recorded in <owner-file>, nothing when it is absent or
#     not a plain file in a plain directory.
#   fm_remote_herdr_session_name_valid <session>
#     Succeeds for fm-remote and fm-remote-<root-id> only.

fm_remote_herdr_recorded_owner() { # <owner-file>
  local file=$1 dir owner=
  dir=${file%/*}
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$file" ] && [ ! -L "$file" ] || return 0
  IFS= read -r owner < "$file" || true
  printf '%s' "$owner"
}

fm_remote_herdr_root_id() { # <fm-root>
  local digest
  if command -v shasum >/dev/null 2>&1; then
    read -r digest _ < <(printf '%s' "$1" | shasum -a 256) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    read -r digest _ < <(printf '%s' "$1" | sha256sum) || return 1
  else
    return 1
  fi
  case "$digest" in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#digest}" -eq 64 ] || return 1
  printf '%s\n' "${digest:0:16}"
}

# Decode the first shell-quoted argument of the stored `exec` command without
# evaluating it. The renderer uses single quotes, with '\'' for apostrophes.
fm_remote_herdr_legacy_guard() { # <plist>
  local command rest part guard=
  command=$(sed -n 's/^[[:space:]]*<string>exec //p' "$1")
  rest=$command
  while [[ "$rest" == "'"* ]]; do
    rest=${rest#\'}
    [[ "$rest" == *"'"* ]] || return 1
    part=${rest%%\'*}
    guard=$guard$part
    rest=${rest#*\'}
    if [[ "$rest" == "\\'"* ]]; then
      guard="$guard'"
      rest=${rest#??}
    else
      [[ "$rest" == ' '* ]] || return 1
      case "$guard" in */bin/fm-remote-herdr-guard.sh) printf '%s' "$guard"; return 0 ;; esac
      return 1
    fi
  done
  return 1
}

# Consumed by the sourcing caller, so its assignments read as unused here.
# shellcheck disable=SC2034
fm_remote_herdr_identity() { # <fm-root>
  local root=$1 assigned=${2:-} owner plist guard id
  FM_REMOTE_HERDR_OWNER_DIR="${HOME:-}/.firstmate"
  FM_REMOTE_HERDR_SESSION=fm-remote
  FM_REMOTE_HERDR_LABEL=dev.firstmate.herdr.fm-remote
  FM_REMOTE_HERDR_OWNER_FILE="$FM_REMOTE_HERDR_OWNER_DIR/remote-herdr-owner"
  if [ -n "$assigned" ]; then
    # shellcheck source=bin/fm-herdr-session-lib.sh
    . "$(dirname "${BASH_SOURCE[0]}")/fm-herdr-session-lib.sh"
    fm_remote_herdr_session_validate "$assigned" || {
      printf 'error: invalid assigned Herdr session: %s\n' "$assigned" >&2
      return 1
    }
    FM_REMOTE_HERDR_SESSION=$assigned
    FM_REMOTE_HERDR_LABEL=$(fm_remote_herdr_session_label "$assigned")
    if [ "$assigned" != fm-remote ]; then
      if fm_remote_herdr_session_name_valid "$assigned"; then
        FM_REMOTE_HERDR_OWNER_FILE="$FM_REMOTE_HERDR_OWNER_DIR/remote-herdr-owner-${assigned#fm-remote-}"
      else
        FM_REMOTE_HERDR_OWNER_FILE="$FM_REMOTE_HERDR_OWNER_DIR/remote-herdr-owner-session-$assigned"
      fi
    fi
  fi
  owner=$(fm_remote_herdr_recorded_owner "$FM_REMOTE_HERDR_OWNER_FILE")
  plist="${HOME:-}/Library/LaunchAgents/$FM_REMOTE_HERDR_LABEL.plist"
  if [ -z "$owner" ] && [ -f "$plist" ] && [ ! -L "$plist" ]; then
    case "${FM_REMOTE_JOB_PLATFORM_OVERRIDE:-$(uname -s 2>/dev/null || true)}" in
      Darwin|darwin)
        guard=$(fm_remote_herdr_legacy_guard "$plist" 2>/dev/null || true)
        owner=${guard%/bin/fm-remote-herdr-guard.sh}
        ;;
    esac
  fi
  FM_REMOTE_HERDR_OWNER_ROOT=$owner
  if [ -n "$assigned" ]; then
    fm_remote_herdr_identity_owner_check "$root"
    return $?
  fi
  [ -n "$owner" ] && [ "$owner" != "$root" ] || return 0
  id=$(fm_remote_herdr_root_id "$root") || {
    printf 'error: no SHA-256 tool resolves to name the Herdr session for code root %s\n' "$root" >&2
    return 1
  }
  FM_REMOTE_HERDR_SESSION="fm-remote-$id"
  FM_REMOTE_HERDR_LABEL="dev.firstmate.herdr.fm-remote-$id"
  FM_REMOTE_HERDR_OWNER_FILE="$FM_REMOTE_HERDR_OWNER_DIR/remote-herdr-owner-$id"
  FM_REMOTE_HERDR_OWNER_ROOT=$(fm_remote_herdr_recorded_owner "$FM_REMOTE_HERDR_OWNER_FILE")
  fm_remote_herdr_identity_owner_check "$root"
}

fm_remote_herdr_identity_owner_check() { # <claiming-root>
  if [ -n "$FM_REMOTE_HERDR_OWNER_ROOT" ] && [ "$FM_REMOTE_HERDR_OWNER_ROOT" != "$1" ]; then
    printf 'error: Herdr session collision for %s: code root %s conflicts with owner %s\n' \
      "$FM_REMOTE_HERDR_SESSION" "$1" "$FM_REMOTE_HERDR_OWNER_ROOT" >&2
    return 1
  fi
}

fm_remote_herdr_session_name_valid() { # <session>
  local id
  [ "$1" != fm-remote ] || return 0
  case "$1" in fm-remote-*) ;; *) return 1 ;; esac
  id=${1#fm-remote-}
  [ "${#id}" -eq 16 ] || return 1
  case "$id" in *[!0-9a-f]*) return 1 ;; esac
}
