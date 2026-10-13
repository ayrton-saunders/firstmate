#!/usr/bin/env bash
# Shared extraction of secondmate registry summary and scope from a charter.
# Source only. FM_SECONDMATE_CHARTER and FM_SECONDMATE_SCOPE remain explicit
# caller overrides; otherwise the named sections in the filled brief are used.

fm_secondmate_charter_for_route() {
  local brief=$1 route=$2 id=$3 root=$4 state=$5 config=$6 remote_home=${7:-}
  local status inbox line section= old_status= old_inbox= append
  . "${BASH_SOURCE[0]%/*}/fm-parent-channel-lib.sh"
  if [ "$route" = remote ]; then
    root=$remote_home
    state="$remote_home/state"
    config="$remote_home/config"
    inbox="$state/parent-route/$id.inbox"
  else
    case "$root" in /*) ;; *) root="$PWD/$root" ;; esac
    case "$state" in /*) ;; *) state="$PWD/$state" ;; esac
    case "$config" in /*) ;; *) config="$PWD/$config" ;; esac
    inbox="$state/$id.inbox"
  fi
  status=$(fm_parent_channel_path_for_route "$route" "$state" "$state" "$id") || return
  status=$(fm_secondmate_charter_quote "$status")
  inbox=$(fm_secondmate_charter_quote "$inbox")
  append="echo \"{state} [at=<epoch>]: {one short line}\" >> $status && { [ ! -e $(fm_secondmate_charter_quote "$config/fleet-ledger") ] || $(fm_secondmate_charter_quote "$root/bin/fm-fleet-ledger.sh") appended $(fm_secondmate_charter_quote "$config") $status >/dev/null 2>&1 || true; }"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '# '*) section=$line ;; esac
    case "$section:$line" in
      '# The captain and the parent channel:Nobody reads this chat: '*)
        old_status=${line#*'see only what is appended to '}
        old_status=${old_status%%', and a captain-facing sentence'*}
        line=${line//"$old_status"/"$status"}
        ;;
      '# Firstmate instruction inbox:Firstmate steers you through durable message files in '*)
        old_inbox=${line#'Firstmate steers you through durable message files in '}
        old_inbox=${old_inbox%.}
        line=${line//"$old_inbox"/"$inbox"}
        ;;
      '# Firstmate instruction inbox:When a terminal message says an instruction is waiting there '*)
        [ -z "$old_inbox" ] || line=${line//"$old_inbox"/"$inbox"}
        ;;
      '# Escalation to main firstmate:   `echo "{state} [at=<epoch>]: {one short line}" >> '*)
        line='   `'$append'`'
        ;;
    esac
    printf '%s\n' "$line"
  done < "$brief"
}

fm_secondmate_charter_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

normalize_registry_text() {
  awk '
    {
      gsub(/[;()]/, " ")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if ($0 != "") out = out (out == "" ? "" : " ") $0
    }
    END { print out }
  '
}

brief_section_text() {
  local brief=$1 heading=$2
  awk -v heading="# $heading" '
    $0 == heading { in_section=1; next }
    in_section && /^# / { exit }
    in_section { print }
  ' "$brief"
}

registry_summary_for_brief() {
  local brief=$1
  if [ -n "${FM_SECONDMATE_CHARTER:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_CHARTER" | normalize_registry_text
  else
    brief_section_text "$brief" "Charter" | normalize_registry_text
  fi
}

registry_scope_for_brief() {
  local brief=$1
  if [ -n "${FM_SECONDMATE_SCOPE:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_SCOPE" | normalize_registry_text
  else
    brief_section_text "$brief" "Routing scope" | normalize_registry_text
  fi
}
