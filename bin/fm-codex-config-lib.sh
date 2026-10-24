#!/usr/bin/env bash

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-config-inherit-lib.sh"

fm_codex_resolve_modes() {
  local config=$1 present
  present=$(fm_config_source_present "$config/codex-approval-mode") || return 1
  CODEX_APPROVAL_MODE=bypass
  if [ "$present" = 1 ]; then
    if [ ! -f "$config/codex-approval-mode" ] || [ ! -r "$config/codex-approval-mode" ]; then
      echo "error: config/codex-approval-mode must be a readable regular file holding one of: bypass, approve-for-me" >&2
      return 1
    fi
    if ! CODEX_APPROVAL_MODE=$(perl -0777 -pe 's/\A\s+|\s+\z//g' <"$config/codex-approval-mode"); then
      echo 'error: could not read config/codex-approval-mode' >&2
      return 1
    fi
    case "$CODEX_APPROVAL_MODE" in
      bypass | approve-for-me) ;;
      *)
        echo "error: config/codex-approval-mode holds '$CODEX_APPROVAL_MODE'; accepted values are: bypass (the default), approve-for-me" >&2
        return 1
        ;;
    esac
  fi
  case "$CODEX_APPROVAL_MODE" in
    approve-for-me) CODEX_APPROVAL_FLAG='--approve-for-me' ;;
    *) CODEX_APPROVAL_FLAG='--dangerously-bypass-approvals-and-sandbox' ;;
  esac
  CODEX_PERMISSION_MODE=bypass
  present=$(fm_config_source_present "$config/codex-permission-mode") || return 1
  if [ "$present" = 1 ]; then
    if [ ! -f "$config/codex-permission-mode" ] || [ ! -r "$config/codex-permission-mode" ]; then
      echo "error: config/codex-permission-mode must be a readable regular file holding bypass or restricted" >&2
      return 1
    fi
    CODEX_PERMISSION_MODE=$(cat "$config/codex-permission-mode") || return 1
    case "$CODEX_PERMISSION_MODE" in
      bypass | restricted) ;;
      *)
        echo "error: config/codex-permission-mode must contain bypass or restricted" >&2
        return 1
        ;;
    esac
  fi
  if [ "$CODEX_PERMISSION_MODE" = restricted ]; then
    CODEX_APPROVAL_MODE=restricted
    CODEX_APPROVAL_FLAG='--sandbox workspace-write --ask-for-approval on-request'
  fi
}
