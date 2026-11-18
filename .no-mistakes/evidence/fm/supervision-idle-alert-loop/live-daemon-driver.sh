#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EV=~/.no-mistakes/evidence/01M7Q3PE8FPNF5WEDSVFKVQK3V
LAB="$ROOT/.idle-daemon-home"
SOCK='' DPID=''
cleanup_lab() {
  if [ -n "$DPID" ]; then
    # Retain the observable buffer, then suppress sending it into the lab shell at shutdown.
    cp "$LAB/state/.subsuper-escalations" "$EV/daemon-final-buffer.txt" 2>/dev/null || true
    rm -f "$LAB/state/.afk" "$LAB/state/.subsuper-escalations"
    kill "$DPID" 2>/dev/null || true; wait "$DPID" 2>/dev/null || true
  fi
  if [ -n "$SOCK" ]; then TMUX_TMPDIR="$SOCK" tmux -L fm-lab kill-server 2>/dev/null || true; fi
  if [ -d "$LAB" ]; then bin/fm-lab-home.sh teardown "$LAB"; rm -rf "$LAB"; fi
}
trap cleanup_lab EXIT
bin/fm-lab-home.sh create "$LAB"
SOCK=$(bin/fm-lab-home.sh tmux-dir "$LAB")
export TMUX_TMPDIR="$SOCK"
tmux -L fm-lab new-session -d -s primary -n finished -x 100 -y 30 -c "$ROOT" 'env PS1="release prepared> " bash --noprofile --norc -i'
export TMUX="$SOCK/tmux-$(id -u)/fm-lab,$(tmux -L fm-lab display-message -p '#{pid}'),0"
export FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_STALE_ESCALATE_SECS=2 FM_PAUSE_RESURFACE_SECS=2
export FM_SUPERVISOR_TARGET=primary:finished FM_SUPERVISOR_BACKEND=tmux FM_ESCALATE_BATCH_SECS=999999 FM_MAX_DEFER_SECS=0 FM_HEARTBEAT_SCAN_SECS=999999 FM_HOUSEKEEPING_TICK=1 FM_WEDGE_ALARM_CHANNEL=off
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE FM_CREW_STATE_BIN
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
bin/fm-tasks-axi.sh add finished 'Prepare release' >/dev/null
bin/fm-tasks-axi.sh start finished >/dev/null
printf 'window=primary:finished\nkind=ship\nharness=claude\nbackend=tmux\n' > "$LAB/state/finished.meta"
printf 'working: preparing release\n' > "$LAB/state/finished.status"
. bin/fm-wake-lib.sh
fm_wake_status_mark_current "$LAB/state" "$LAB/state/finished.status"
echo 'SCENARIO task and backlog lease contention cannot record handoff'
printf '%s\n' "$$" > "$LAB/state/.lock"
for resource in finished backlog; do
  FM_SUPERVISION_ACTOR=main bin/fm-lease.sh claim "$resource"
  rc=0
  FM_SUPERVISION_ACTOR=branch bin/fm-captain-hold.sh hold finished --reason 'Approve release?' --idle-handoff || rc=$?
  echo "resource=$resource refusal=$rc"; [ "$rc" -eq 6 ]
  [ ! -e "$LAB/state/finished.idle-decision-handoff" ]
  FM_SUPERVISION_ACTOR=main bin/fm-lease.sh release "$resource"
  FM_SUPERVISION_ACTOR=branch bin/fm-lease.sh claim "$resource"
done
for resource in finished backlog; do FM_SUPERVISION_ACTOR=branch bin/fm-lease.sh release "$resource"; done
rm "$LAB/state/.lock"
echo 'SCENARIO actual away daemon escalates initial idle once, suppresses repeat after handoff, then reports new blocker'
FM_AFK_MODE=away bin/fm-afk-contract.sh enter --words 'Hold decisions for return' >/dev/null
date +%s > "$LAB/state/.afk"
bin/fm-supervise-daemon.sh > "$EV/daemon.stdout" 2> "$EV/daemon.stderr" & DPID=$!
for ((i=0;i<100;i++)); do
  grep -q 'stale persisted' "$LAB/state/.subsuper-escalations" 2>/dev/null && break
  kill -0 "$DPID" || { echo 'FAIL daemon exited'; exit 1; }; sleep 1
done
cat "$LAB/state/.subsuper-escalations"
grep -q 'stale persisted' "$LAB/state/.subsuper-escalations"
cp "$LAB/state/.subsuper-escalations" "$EV/daemon-initial-buffer.txt"
[ "$(grep -c 'stale persisted' "$LAB/state/.subsuper-escalations")" -eq 1 ]
bin/fm-captain-hold.sh hold finished --reason 'Approve release?' --idle-handoff
# Display churn creates a new stale hash without changing the task.
tmux -L fm-lab resize-window -t primary:finished -x 110 -y 32
sleep 25
kill -0 "$DPID"
[ "$(grep -c 'stale persisted' "$LAB/state/.subsuper-escalations")" -eq 1 ]
echo 'daemon remained running: initial stale escalation count=1 after 25s (>12 stale thresholds)'
printf 'blocked [key=expired]: prepared release artifact expired\n' >> "$LAB/state/finished.status"
for ((i=0;i<100;i++)); do
  grep -q 'prepared release artifact expired' "$LAB/state/.subsuper-escalations" 2>/dev/null && break
  kill -0 "$DPID" || exit 1; sleep 1
done
grep 'prepared release artifact expired' "$LAB/state/.subsuper-escalations"
[ "$(bin/fm-captain-hold.sh open finished --idle-state)" = held ]
cp "$LAB/state/.supervise-daemon.log" "$EV/daemon-product.log"
echo 'ALL AWAY DAEMON AND LEASE SCENARIOS PASSED'
