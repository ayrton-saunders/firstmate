#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EV=~/.no-mistakes/evidence/01M7Q3PE8FPNF5WEDSVFKVQK3V
LAB="$ROOT/.idle-live-home"
SOCK=''
PID=''
cleanup() {
  if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  if [ -n "$SOCK" ]; then TMUX_TMPDIR="$SOCK" tmux -L fm-lab kill-server 2>/dev/null || true; fi
  if [ -d "$LAB" ]; then "$ROOT/bin/fm-lab-home.sh" teardown "$LAB"; rm -rf "$LAB"; fi
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
SOCK=$(bin/fm-lab-home.sh tmux-dir "$LAB")
export TMUX_TMPDIR="$SOCK"
tmux -L fm-lab new-session -d -s primary -n finished -x 100 -y 30 -c "$ROOT" 'env PS1="release prepared> " bash --noprofile --norc -i'
export TMUX="$SOCK/tmux-$(id -u)/fm-lab,$(tmux -L fm-lab display-message -p '#{pid}'),0"
export FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_STALE_ESCALATE_SECS=2 FM_PAUSE_RESURFACE_SECS=2
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE FM_CREW_STATE_BIN
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
bin/fm-tasks-axi.sh add finished 'Prepare release' >/dev/null
bin/fm-tasks-axi.sh start finished >/dev/null
printf 'window=primary:finished\nkind=ship\nharness=claude\nbackend=tmux\n' > "$LAB/state/finished.meta"
printf 'working: preparing release\n' > "$LAB/state/finished.status"
. bin/fm-wake-lib.sh
fm_wake_status_mark_current "$LAB/state" "$LAB/state/finished.status"
start_watch() { bin/fm-watch.sh > "$EV/$1.out" 2> "$EV/$1.err" & PID=$!; }
wait_wake() {
  local i rc=0
  for ((i=0;i<90;i++)); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
  if kill -0 "$PID" 2>/dev/null; then echo "FAIL watcher did not complete"; return 1; fi
  wait "$PID" || rc=$?; PID=''; echo "watcher exit=$rc"; [ "$rc" -eq 0 ]
}
ack() {
  bin/fm-wake-drain.sh > "$EV/$1.drain" 2> "$EV/$1.drain.err"
  local seq gen
  seq=$(awk '/^WAKE_ACK_REQUIRED:/ {for(i=1;i<=NF;i++) if($i=="--ack-through") print $(i+1)}' "$EV/$1.drain.err")
  gen=$(awk '/^WAKE_ACK_REQUIRED:/ {for(i=1;i<=NF;i++) if($i=="--recovery-generation") print $(i+1)}' "$EV/$1.drain.err")
  bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen"
}
quiet() {
  start_watch "$1"
  sleep 15
  kill -0 "$PID" || { echo 'FAIL watcher exited during quiet probe'; wait "$PID"; PID=''; return 1; }
  [ ! -s "$EV/$1.out" ] || { echo 'FAIL unexpected wake'; return 1; }
  kill "$PID"; wait "$PID" || true; PID=''
  echo "$1: watcher remained running with no wake over 15s (>7 idle thresholds)"
}
echo 'SCENARIO first idle alert from real tmux shell with synthetic working status'
start_watch first-idle
wait_wake
cat "$EV/first-idle.out"
grep -F 'stale: primary:finished' "$EV/first-idle.out"
ack first-idle
grep -F -- '--idle-handoff' "$EV/first-idle.drain"
echo 'SCENARIO conflicting decision and dated deferral refuse without mutation'
bin/fm-captain-hold.sh hold finished --reason 'Approve prepared release?' --until 2099-01-01
bin/fm-tasks-axi.sh show finished --full > "$EV/deferral-before.txt"
if bin/fm-captain-hold.sh hold finished --reason 'Approve prepared release?' --idle-handoff; then exit 11; fi
bin/fm-tasks-axi.sh show finished --full > "$EV/deferral-after.txt"
cmp "$EV/deferral-before.txt" "$EV/deferral-after.txt"
bin/fm-captain-hold.sh hold finished --reason 'Approve prepared release?'
bin/fm-tasks-axi.sh show finished --full > "$EV/hold-before.txt"
if bin/fm-captain-hold.sh hold finished --reason 'Use preview instead?' --idle-handoff; then exit 12; fi
bin/fm-tasks-axi.sh show finished --full > "$EV/hold-after.txt"
cmp "$EV/hold-before.txt" "$EV/hold-after.txt"
echo 'SCENARIO recorded handoff stays quiet through unchanged pane and display-only resize'
bin/fm-captain-hold.sh hold finished --reason 'Approve prepared release?' --idle-handoff
[ "$(bin/fm-captain-hold.sh open finished --idle-state)" = handed-off ]
quiet unchanged
ack unchanged
tmux -L fm-lab resize-window -t primary:finished -x 110 -y 32
quiet display-refresh
ack display-refresh
echo 'SCENARIO new blocker surfaces while decision stays open'
printf 'blocked [key=expired]: prepared release artifact expired\n' >> "$LAB/state/finished.status"
start_watch blocker
wait_wake
cat "$EV/blocker.out"
grep -F 'signal:' "$EV/blocker.out"
ack blocker
grep -F 'prepared release artifact expired' "$EV/blocker.drain"
[ "$(bin/fm-captain-hold.sh open finished --idle-state)" = held ]
echo 'SCENARIO answer invalidates handoff and restores idle monitoring'
bin/fm-captain-hold.sh hold finished --reason 'Approve prepared release?' --idle-handoff
printf 'Proceed after replacing artifact.\n' > "$LAB/answer.txt"
bin/fm-captain-hold.sh answer finished --decision-file "$LAB/answer.txt" --release
start_watch answered
wait_wake
cat "$EV/answered.out"
grep -F 'stale: primary:finished' "$EV/answered.out"
echo 'ALL LOCAL PRODUCT SCENARIOS PASSED'
