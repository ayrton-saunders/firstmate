#!/usr/bin/env bash
# Credentialed Hermes idle-gateway coexistence guard. Opt in with
# FM_HERMES_GATEWAY_LIVE=1, FM_HERMES_LIVE_HOME=<throwaway-root>
# and FM_HERMES_LIVE_PROFILE=<name> (default worker). Starts a real native gateway for the
# throwaway profile with an isolated HOME, state and host-lock directory, so it
# cannot attach to any other gateway. The profile must configure no messaging
# platform; the guard refuses one. It then runs the TUI worker guard beside the
# idle gateway and checks the session store, memory and gateway afterward.
# The probe restores config bytes only when the recorded entries still match and no relink is needed.
# If Hermes replaced a config symlink, inspect the retained backup and repair the link by hand.
# After SIGKILL, a .fm-gateway-config.* backup may remain beside config.yaml for recovery.
# A write interrupted before rollback confirmation may require restoring the retained backup by hand.
# If teardown is unverified, do not run another probe on this profile until both the gateway and TUI are gone.
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
LAB=
SOCKET=
BACKUP=
BACKUP_RECORD=
PROFILE_LOCK=
WRITTEN_RECORD=
WRITTEN_LINK=
publication_pending=0
mutation_attempted=0
probe_signal=0
TUI_PID=
TUI_RETAIN=
GATEWAY_RETAIN=
FINGERPRINT_CODE='import hashlib, stat

def fingerprint(info):
    return ":".join(map(str, (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns)))

def read_record(file):
    before = os.fstat(file.fileno())
    if not stat.S_ISREG(before.st_mode):
        sys.exit("config recovery requires regular files")
    data = file.read()
    record = fingerprint(before)
    after = os.fstat(file.fileno())
    if record != fingerprint(after) or before.st_ctime_ns != after.st_ctime_ns:
        sys.exit("file changed while reading config recovery data")
    return record + ":" + hashlib.sha256(data).hexdigest(), data, after.st_ctime_ns

def file_record(path, parent=None):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent), "rb") as file:
        return read_record(file)[0]'
RESTORE_TARGET_CODE='import os, sys
from contextlib import ExitStack

profile, target, expected_link, *restore = sys.argv[1:]
flags = os.O_NOFOLLOW | os.O_NONBLOCK
'"$FINGERPRINT_CODE"'

def entry(parent, name):
    return os.stat(name, dir_fd=parent, follow_symlinks=False)

with ExitStack() as stack:
    def directory(path, parent=None):
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        stack.callback(os.close, fd)
        return fd

    if os.path.commonpath((profile, target)) != profile or profile == target:
        sys.exit("config target is outside the profile")
    profile_fd = directory("/")
    for part in profile.strip("/").split("/"):
        profile_fd = directory(part, profile_fd)
    target_fd = profile_fd
    parts = os.path.relpath(target, profile).split("/")
    for part in parts[:-1]:
        target_fd = directory(part, target_fd)
    name = parts[-1]
    config = "config.yaml"
    config_path = os.path.join(profile, config)
    target_info = entry(target_fd, name)
    config_info = entry(profile_fd, config)
    if not stat.S_ISREG(target_info.st_mode) or not (
        stat.S_ISLNK(config_info.st_mode) and os.readlink(config, dir_fd=profile_fd) == expected_link
        and os.path.realpath(config_path) == target
        if expected_link else target == config_path and stat.S_ISREG(config_info.st_mode)
    ):
        sys.exit("config restore found an unexpected file or link")
    target_record = file_record(name, target_fd)
    record = target_record
    if expected_link:
        record += "/" + fingerprint(config_info)
    if not restore:
        print(record)
        sys.exit(0)
    backup, backup_record, mode, expected, *verify_only = restore
    if record != expected:
        sys.exit("config entries changed before restore")
    if verify_only:
        if file_record(backup) != backup_record:
            sys.exit("config backup changed")
        sys.exit(0)

    with os.fdopen(os.open(os.path.basename(backup), os.O_RDONLY | flags, dir_fd=profile_fd), "rb") as src, \
         os.fdopen(os.open(name, os.O_RDWR | flags, dir_fd=target_fd), "r+b") as dst:
        before = os.fstat(dst.fileno())
        actual_backup, data, _ = read_record(src)
        if actual_backup != backup_record or file_record(backup) != backup_record:
            sys.exit("config backup changed")
        actual_target, _, verified_ctime = read_record(dst)
        if actual_target != target_record or fingerprint(before) != fingerprint(target_info):
            sys.exit("config target changed before restore opened it")
        if fingerprint(os.lstat(target)) != fingerprint(target_info) or (expected_link and (
            fingerprint(os.lstat(config_path)) != fingerprint(config_info) or os.path.realpath(config_path) != target
        )):
            sys.exit("config entries changed before restore")
        dst.seek(0)
        if os.fstat(dst.fileno()).st_ctime_ns != verified_ctime:
            sys.exit("config target changed after verification")
        dst.write(data)
        dst.truncate()
        dst.flush()
        os.fchmod(dst.fileno(), int(mode, 8))
        if not os.path.samestat(before, os.lstat(target)):
            sys.exit("config target was replaced during restore")
        if expected_link and (fingerprint(os.lstat(config_path)) != fingerprint(config_info) or
                              os.path.realpath(config_path) != target):
            sys.exit("config entry was replaced during restore")
        if file_record(backup) != backup_record:
            sys.exit("config backup was replaced during restore")'
restore_args() {
  [ -n "$WRITTEN_RECORD" ] && [ "$CONFIG_LINK" = "$WRITTEN_LINK" ] || return 1
  RESTORE_ARGS=(-I -c "$RESTORE_TARGET_CODE" "$PROFILE_HOME" "$CONFIG_TARGET" "$WRITTEN_LINK"
    "$BACKUP" "$BACKUP_RECORD" "$CONFIG_MODE" "$WRITTEN_RECORD")
}
print_restore_command() {
  local -a RESTORE_ARGS
  if restore_args && python3 "${RESTORE_ARGS[@]}" verify 2>/dev/null; then
    printf 'To restore manually: python3'
    printf ' %q' "${RESTORE_ARGS[@]}"
    printf '\n'
  else
    printf 'No safe restore command: inspect %q and %q without changing them before using the backup.\n' \
      "$PROFILE_HOME/config.yaml" "$BACKUP"
  fi
}
backup_fingerprint() {
  python3 -I -c 'import os, sys
'"$FINGERPRINT_CODE"'
print(file_record(sys.argv[1]))' "$1"
}
discard_backup() {
  [ -n "$BACKUP_RECORD" ] && [ "$(backup_fingerprint "$BACKUP")" = "$BACKUP_RECORD" ] || return 1
  rm -f -- "$BACKUP"
}
cleanup() {
  local status=$? attempt teardown_failed=0 child_lab tui_lab_retained=0
  trap '' HUP INT QUIT TERM
  if [ -n "$TUI_PID" ]; then kill -TERM "$TUI_PID" 2>/dev/null || true; fi
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
  if [ "$teardown_failed" -ne 0 ]; then
    printf 'A gateway or TUI may still be using %s; do not run another gateway probe on this profile until you confirm both are gone.\n' "$PROFILE_HOME" >&2
  fi
  if [ -n "$BACKUP" ]; then
    if ! { if [ "$mutation_attempted" -eq 0 ]; then discard_backup; else restore_config; fi; }; then
      printf 'not ok - config changed or restore failed; backup retained at %s\n' "$BACKUP" >&2
      print_restore_command >&2
      [ "$status" -ne 0 ] || status=1
    fi
  fi
  if [ -n "$PROFILE_LOCK" ]; then
    fm_lock_release "$PROFILE_LOCK" || { [ "$status" -ne 0 ] || status=1; }
  fi
  fm_test_cleanup || { [ "$status" -ne 0 ] || status=1; }
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
# shellcheck source=bin/fm-wake-lib.sh
FM_STATE_OVERRIDE="$LAB/state" . "$ROOT/bin/fm-wake-lib.sh"
publication_pending=1
PROFILE_LOCK="$PROFILE_HOME/.fm-gateway-config-lock"
fm_lock_try_acquire "$PROFILE_LOCK" || fail 'throwaway profile is locked by another gateway probe (or a previous interrupted probe)'
publication_pending=0
[ "$probe_signal" -eq 0 ] || exit "$probe_signal"
CONFIG_TARGET=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$PROFILE_HOME/config.yaml") \
  && [ -f "$CONFIG_TARGET" ] || fail 'could not resolve profile config'
case "$CONFIG_TARGET" in "$PROFILE_HOME"/*) ;; *) fail 'config resolves outside the throwaway profile' ;; esac
for file in "$FM_HERMES_LIVE_HOME/.env" "$PROFILE_HOME/.env"; do
  [ ! -s "$file" ] || fail "$file may configure a messaging platform; use a profile without one"
done
CONFIG_LINK=
if [ -L "$PROFILE_HOME/config.yaml" ]; then
  CONFIG_LINK=$(readlink "$PROFILE_HOME/config.yaml") || fail 'could not read profile config link'
fi
original_record=$(python3 -I -c "$RESTORE_TARGET_CODE" "$PROFILE_HOME" "$CONFIG_TARGET" "$CONFIG_LINK") \
  || fail 'config target changed before platform check'
HERMES_HOME="$FM_HERMES_LIVE_HOME" "$HERMES_BIN" -p "$PROFILE" config get platforms --json > "$LAB/platforms.json" 2>/dev/null || echo null > "$LAB/platforms.json"
jq -e '. == null or . == {} or ([.[]? | objects | select(.enabled == true)] | length == 0)' "$LAB/platforms.json" >/dev/null \
  || fail 'throwaway profile configures a messaging platform'
[ "$(python3 -I -c "$RESTORE_TARGET_CODE" "$PROFILE_HOME" "$CONFIG_TARGET" "$CONFIG_LINK")" = "$original_record" ] \
  || fail 'config target changed during platform check'
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
# Native Hermes runs a profile-owned gateway only in its standalone mode, the
# shape of an operator profile whose own gateway serves only itself.
restore_config() {
  local -a RESTORE_ARGS
  restore_args || return 1
  python3 "${RESTORE_ARGS[@]}" || return 1
  discard_backup
}
[ "$(python3 -I -c "$RESTORE_TARGET_CODE" "$PROFILE_HOME" "$CONFIG_TARGET" "$CONFIG_LINK")" = "$original_record" ] \
  || fail 'config target changed after platform approval'
original_target=${original_record%%/*}
IFS=: read -r _ _ original_mode _ _ original_digest <<< "$original_target"
printf -v CONFIG_MODE '%o' "$((original_mode & 07777))"
publication_pending=1
BACKUP=$(
  trap '' HUP INT QUIT TERM
  backup=$(mktemp "$PROFILE_HOME/.fm-gateway-config.XXXXXX") || exit 1
  if ! chmod 0600 "$backup" || ! command cat "$CONFIG_TARGET" > "$backup"; then
    rm -f "$backup"
    exit 1
  fi
  printf '%s\n' "$backup"
) || fail 'could not back up profile config'
BACKUP_RECORD=$(backup_fingerprint "$BACKUP") || fail 'could not record config backup'
publication_pending=0
[ "$probe_signal" -eq 0 ] || exit "$probe_signal"
[ "${BACKUP_RECORD##*:}" = "$original_digest" ] &&
  [ "$(backup_fingerprint "$BACKUP")" = "$BACKUP_RECORD" ] &&
  [ "$(python3 -I -c "$RESTORE_TARGET_CODE" "$PROFILE_HOME" "$CONFIG_TARGET" "$CONFIG_LINK")" = "$original_record" ] \
  || fail 'config target or backup changed before mutation'
mutation_attempted=1
HERMES_HOME="$FM_HERMES_LIVE_HOME" "$HERMES_BIN" -p "$PROFILE" config set gateway.standalone true >/dev/null \
  || fail 'could not mark the throwaway profile gateway standalone'
WRITTEN_LINK=$(readlink "$PROFILE_HOME/config.yaml" 2>/dev/null) || WRITTEN_LINK=
written_record=$(python3 -I -c "$RESTORE_TARGET_CODE" "$PROFILE_HOME" "$CONFIG_TARGET" "$WRITTEN_LINK") \
  || fail 'could not record config identities after the gateway probe write'
WRITTEN_RECORD=$written_record
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
