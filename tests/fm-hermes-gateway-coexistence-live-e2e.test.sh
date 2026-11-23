#!/usr/bin/env bash
# Credentialed Hermes idle-gateway coexistence guard. Opt in with
# FM_HERMES_GATEWAY_LIVE=1, FM_HERMES_LIVE_HOME=<throwaway-root>
# and FM_HERMES_LIVE_PROFILE=<name> (default worker). Starts a real native gateway for the
# throwaway profile with an isolated HOME, state and host-lock directory, so it
# cannot attach to any other gateway. The profile must configure no messaging
# platform; the guard refuses one. It then runs the TUI worker guard beside the
# idle gateway and checks the session store, memory and gateway afterward.
# The profile's config is restored after it temporarily sets gateway.standalone.
# After SIGKILL, a .fm-gateway-config.* backup may remain beside config.yaml for recovery.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_HERMES_GATEWAY_LIVE hermes tmux jq python3
: "${FM_HERMES_LIVE_HOME:?provide a configured throwaway Hermes root}"
PROFILE=${FM_HERMES_LIVE_PROFILE:-worker}
HERMES_BIN=$(command -v hermes)
FM_HERMES_LIVE_HOME=$(cd -- "$FM_HERMES_LIVE_HOME" && pwd -P) || fail 'could not resolve throwaway root'
case "$PROFILE" in ''|.|..|*/*|*\\*) fail 'invalid throwaway profile name' ;; esac
PROFILE_HOME=$(cd -- "$FM_HERMES_LIVE_HOME/profiles/$PROFILE" && pwd -P) || fail 'could not resolve throwaway profile'
case "$PROFILE_HOME" in "$FM_HERMES_LIVE_HOME"/profiles/*) ;; *) fail 'profile resolves outside the throwaway root' ;; esac
CONFIG_TARGET=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$PROFILE_HOME/config.yaml") \
  && [ -f "$CONFIG_TARGET" ] || fail 'could not resolve profile config'
case "$CONFIG_TARGET" in "$PROFILE_HOME"/*) ;; *) fail 'config resolves outside the throwaway profile' ;; esac
LAB=
SOCKET=
BACKUP=
publication_pending=0
mutation_attempted=0
probe_signal=0
TUI_PID=
TUI_RETAIN=
GATEWAY_RETAIN=
cleanup() {
  local status=$? attempt teardown_failed=0 child_lab tui_lab_retained=0
  trap '' HUP INT QUIT TERM
  if [ -n "$TUI_PID" ]; then kill -TERM "$TUI_PID" 2>/dev/null || true; fi
  if [ -n "$BACKUP" ]; then
    if [ "$mutation_attempted" -eq 0 ]; then
      rm -f "$BACKUP" || { [ "$status" -ne 0 ] || status=1; }
    elif ! restore_config; then
      printf 'not ok - config restore failed; backup retained at %s\n' "$BACKUP" >&2
      [ "$status" -ne 0 ] || status=1
    fi
  fi
  if [ -n "$TUI_PID" ]; then
    for ((attempt=0; attempt<60; ++attempt)); do
      kill -0 "$TUI_PID" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$TUI_PID" 2>/dev/null; then
      teardown_failed=1
    else
      wait "$TUI_PID" || true
      TUI_PID=
    fi
  fi
  if [ -n "$LAB" ]; then
    for child_lab in "$LAB"/hm.??????; do
      if [ -e "$child_lab" ] || [ -L "$child_lab" ]; then tui_lab_retained=1; break; fi
    done
  fi
  if [ -z "$TUI_PID" ] && [ "$tui_lab_retained" -eq 0 ]; then
    if [ -n "$TUI_RETAIN" ]; then rm -f -- "$TUI_RETAIN"; fi
  else
    printf 'not ok - TUI teardown unverified; retaining %s; delete it by hand once nothing is using it\n' "$LAB" >&2
    teardown_failed=1
  fi
  fm_test_stop_private_tmux "$SOCKET" tmux "$GATEWAY_RETAIN" || teardown_failed=1
  fm_test_cleanup
  if [ "$teardown_failed" -eq 0 ]; then
    [ -z "$LAB" ] || fm_test_remove_tree "$LAB" || { [ "$status" -ne 0 ] || status=1; }
  else
    [ "$status" -ne 0 ] || status=1
  fi
  exit "$status"
}
trap cleanup EXIT
interrupt_probe() {
  probe_signal=$1
  [ "$publication_pending" -ne 0 ] || exit "$probe_signal"
}
trap 'interrupt_probe 129' HUP
trap 'interrupt_probe 130' INT
trap 'interrupt_probe 131' QUIT
trap 'interrupt_probe 143' TERM
publication_pending=1
LAB=$(trap '' HUP INT QUIT TERM; mktemp -d "${FM_TEST_TMPDIR%/}/h.XXXXXX") || fail 'could not allocate gateway scratch'
publication_pending=0
[ "$probe_signal" -eq 0 ] || exit "$probe_signal"
lab_path=$(cd "$LAB" && pwd -P) || fail 'could not resolve gateway scratch'
LAB=$lab_path
SOCKET="$LAB/s"
mkdir -p "$LAB/home" "$LAB/state" "$LAB/locks" || fail 'could not prepare gateway scratch'
for file in "$FM_HERMES_LIVE_HOME/.env" "$PROFILE_HOME/.env"; do
  [ ! -s "$file" ] || fail "$file may configure a messaging platform; use a profile without one"
done
HERMES_HOME="$FM_HERMES_LIVE_HOME" "$HERMES_BIN" -p "$PROFILE" config get platforms --json > "$LAB/platforms.json" 2>/dev/null || echo null > "$LAB/platforms.json"
jq -e '. == null or . == {} or ([.[]? | objects | select(.enabled == true)] | length == 0)' "$LAB/platforms.json" >/dev/null \
  || fail 'throwaway profile configures a messaging platform'
snapshot() {
  python3 -I - "$PROFILE_HOME" "$1" <<'PY'
import hashlib, json, sqlite3, sys
from pathlib import Path
home, out = Path(sys.argv[1]), Path(sys.argv[2])
conn = sqlite3.connect(f"file:{home / 'state.db'}?mode=ro", uri=True)
ok = conn.execute('pragma integrity_check').fetchone()[0]
sessions = {sid: count for sid, count in conn.execute(
    'select s.id, count(m.id) from sessions s left join messages m on m.session_id = s.id group by s.id')}
conn.close()
memory = home / 'memories' / 'MEMORY.md'
digest = hashlib.sha256(memory.read_bytes()).hexdigest() if memory.exists() else None
out.write_text(json.dumps({'integrity': ok, 'sessions': sessions, 'memory': digest}))
PY
}
snapshot "$LAB/before.json" || fail 'could not snapshot the throwaway session store'
CONFIG_LINK=
if [ -L "$PROFILE_HOME/config.yaml" ]; then
  CONFIG_LINK=$(readlink "$PROFILE_HOME/config.yaml") || fail 'could not read profile config link'
fi
# Native Hermes runs a profile-owned gateway only in its standalone mode, the
# shape of an operator profile whose own gateway serves only itself.
restore_config() {
  [ ! -d "$CONFIG_TARGET" ] && [ ! -L "$CONFIG_TARGET" ] && cp -p "$BACKUP" "$CONFIG_TARGET" || return 1
  if [ -n "$CONFIG_LINK" ] && [ "$(readlink "$PROFILE_HOME/config.yaml" 2>/dev/null)" != "$CONFIG_LINK" ]; then
    [ ! -d "$PROFILE_HOME/config.yaml" ] || return 1
    ln -sfn -- "$CONFIG_LINK" "$PROFILE_HOME/config.yaml" || return 1
  fi
  rm -f -- "$BACKUP"
}
publication_pending=1
BACKUP=$(
  trap '' HUP INT QUIT TERM
  backup=$(mktemp "$PROFILE_HOME/.fm-gateway-config.XXXXXX") || exit 1
  if ! cp -p "$CONFIG_TARGET" "$backup"; then
    rm -f "$backup"
    exit 1
  fi
  printf '%s\n' "$backup"
) || fail 'could not back up profile config'
publication_pending=0
[ "$probe_signal" -eq 0 ] || exit "$probe_signal"
mutation_attempted=1
HERMES_HOME="$FM_HERMES_LIVE_HOME" "$HERMES_BIN" -p "$PROFILE" config set gateway.standalone true >/dev/null \
  || fail 'could not mark the throwaway profile gateway standalone'
gateway_state() { jq -c '{pid, gateway_state, active_agents, active_work, updated_at, session_store}' "$PROFILE_HOME/gateway_state.json"; }
# The gateway's environment, HOME and state are private, so no inherited
# platform credential, operator Hermes root, or per-user host rendezvous is
# visible to it.
printf 'exec env -i PATH=%q TERM=xterm-256color HOME=%q XDG_STATE_HOME=%q HERMES_GATEWAY_LOCK_DIR=%q HERMES_HOME=%q %q -p %q gateway run\n' \
  "$PATH" "$LAB/home" "$LAB/state" "$LAB/locks" "$FM_HERMES_LIVE_HOME" "$HERMES_BIN" "$PROFILE" > "$LAB/gateway.sh"
fm_test_arm_private_tmux GATEWAY_RETAIN || fail 'could not protect gateway scratch'
tmux -S "$SOCKET" new-session -d -s gateway -x 160 -y 50 "bash '$LAB/gateway.sh'; sleep 600" || fail 'gateway launch failed'
for _ in $(seq 1 240); do
  # A previous run leaves its state file behind; wait for a live writer.
  [ -f "$PROFILE_HOME/gateway_state.json" ] && [ "$(jq -r '.gateway_state + ":" + (.active_agents|tostring)' "$PROFILE_HOME/gateway_state.json" 2>/dev/null)" = running:0 ] \
    && kill -0 "$(jq -r .pid "$PROFILE_HOME/gateway_state.json" 2>/dev/null)" 2>/dev/null && break
  sleep 0.5
done
GATEWAY_PID=$(jq -r .pid "$PROFILE_HOME/gateway_state.json" 2>/dev/null)
if [ "$(jq -r .gateway_state "$PROFILE_HOME/gateway_state.json" 2>/dev/null)" != running ] || ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
  fail "native gateway did not reach running: $(tmux -S "$SOCKET" capture-pane -p -t gateway | tail -20)"
fi
printf 'idle gateway before: %s\n' "$(gateway_state)"
# shellcheck source=bin/fm-hermes-lib.sh
. "$ROOT/bin/fm-hermes-lib.sh"
HERMES_GATEWAY_LOCK_DIR="$LAB/locks" fm_hermes_gateway_check "$PROFILE_HOME" "$PROFILE" || fail 'idle own gateway refused'
pass 'real idle profile gateway accepted by the read-only preflight'
fm_test_arm_private_tmux TUI_RETAIN || fail 'could not protect pending TUI teardown'
publication_pending=1
TMPDIR="$LAB" TMP="$LAB" TEMP="$LAB" FM_HERMES_SIGNALS_LIVE=1 HERMES_GATEWAY_LOCK_DIR="$LAB/locks" \
  bash "$ROOT/tests/fm-hermes-signals-live-e2e.test.sh" &
TUI_PID=$!
publication_pending=0
[ "$probe_signal" -eq 0 ] || exit "$probe_signal"
tui_status=0
wait "$TUI_PID" || tui_status=$?
TUI_PID=
[ "$tui_status" -eq 0 ] || fail 'TUI worker guard failed beside the idle gateway'
before_stamp=$(jq -r .updated_at "$PROFILE_HOME/gateway_state.json")
for _ in $(seq 1 150); do
  [ "$(jq -r .updated_at "$PROFILE_HOME/gateway_state.json")" != "$before_stamp" ] && break
  sleep 1
done
printf 'idle gateway after: %s\n' "$(gateway_state)"
kill -0 "$GATEWAY_PID" 2>/dev/null || fail 'gateway exited during the worker task'
[ "$(jq -r .pid "$PROFILE_HOME/gateway_state.json")" = "$GATEWAY_PID" ] || fail 'gateway was replaced during the worker task'
jq -e '.gateway_state == "running" and .active_agents == 0 and .session_store.status == "ok"' "$PROFILE_HOME/gateway_state.json" >/dev/null \
  || fail 'gateway is no longer idle-serving with a healthy session store'
[ "$(jq -r .updated_at "$PROFILE_HOME/gateway_state.json")" != "$before_stamp" ] || fail 'gateway heartbeat stopped after the worker task'
HOME="$LAB/home" XDG_STATE_HOME="$LAB/state" HERMES_GATEWAY_LOCK_DIR="$LAB/locks" HERMES_HOME="$FM_HERMES_LIVE_HOME" \
  "$HERMES_BIN" -p "$PROFILE" gateway status > "$LAB/status.txt" 2>&1 || true
printf 'native gateway status: %s\n' "$(grep -iE 'running|stopped' "$LAB/status.txt" | head -1)"
grep -qi 'running' "$LAB/status.txt" || fail "native gateway status did not report running: $(cat "$LAB/status.txt")"
snapshot "$LAB/after.json" || fail 'could not snapshot the session store afterward'
jq -e --slurpfile b "$LAB/before.json" '. as $a | .integrity == "ok" and .memory == $b[0].memory and ([$b[0].sessions | to_entries[] | select(.value != $a.sessions[.key])] | length == 0) and (.sessions | length > ($b[0].sessions | length))' \
  "$LAB/after.json" >/dev/null || fail "session store or memory changed unexpectedly: before $(cat "$LAB/before.json") after $(cat "$LAB/after.json")"
printf 'session store: integrity ok, %s prior sessions and their messages retained, %s new worker sessions; memory unchanged\n' \
  "$(jq '.sessions | length' "$LAB/before.json")" "$(jq --slurpfile b "$LAB/before.json" '(.sessions | length) - ($b[0].sessions | length)' "$LAB/after.json")"
pass "$("$HERMES_BIN" --version 2>/dev/null | head -1): TUI worker completed beside a real idle gateway; gateway, session store and memory intact"
