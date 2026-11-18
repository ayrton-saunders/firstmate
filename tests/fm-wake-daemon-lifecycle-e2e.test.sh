#!/usr/bin/env bash
# tests/fm-wake-daemon-lifecycle-e2e.test.sh - the watcher + supervise-daemon
# lifecycle, end to end, over one shared state root and a shimmed tmux:
#
#   routine status -> self-handled, queued
#   terminal status written while the watcher is DOWN -> caught on restart (catch-up)
#   drain queued records -> exactly ONE captain-relevant digest is buffered
#   housekeeping catch-all scan -> NO duplicate digest
#   buffered digest flushes to the supervisor pane as exactly ONE submission
#   stale working-pane: transient (self + marker) -> persistent (escalates once,
#     clears its marker) -> resumed/busy (clears without escalating)
#   finished worker -> one idle escalation, no repeat after decision handoff,
#     then a new blocker still escalates
#
# This proves the operator-visible routing/queueing/dedupe behavior through real
# fm-watch.sh runs plus the daemon's own functions. The captain-relevant
# status-phrase matrix and the lock-primitive races stay as focused units
# (fm-daemon.test.sh, fm-watcher-lock.test.sh) - an e2e cannot deterministically
# cover a race, and the phrase list is a product contract worth a dedicated test.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

# Source the daemon's pure functions (its main loop is guarded out under sourcing).
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=/dev/null
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-wake-daemon-e2e)

# Run the daemon-managed watcher once: under the supervise-daemon (away mode) the
# watcher is one-shot - it exits with a single reason line on EVERY wake and the
# daemon does the triage. This e2e exercises exactly that path, so it runs with
# state/.afk present (which the daemon owns) to keep the watcher one-shot; the
# always-on standalone triage is covered by fm-watch-triage.test.sh. fakebin
# shadows tmux. Echoes nothing; the caller reads $out.
run_watcher_once() {
  local state=$1 fakebin=$2 out=$3
  mkdir -p "$state"
  date '+%s' > "$state/.afk"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 100
}

ack_handled_wakes() {  # <state> <drain-stderr>
  local state=$1 drain_err=$2 sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$drain_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$drain_err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

# --- Phase 1: routine self-handled, queued; terminal caught after restart ---
test_routine_then_terminal_after_restart() {
  local dir state fakebin out drain_out drain_err status_file
  dir=$(make_supercase wd-lifecycle)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  drain_err="$dir/drain.err"
  status_file="$state/task-w1.status"

  # A routine status fires a signal; the watcher queues it and exits.
  printf 'working: building\n' > "$status_file"
  run_watcher_once "$state" "$fakebin" "$out" || fail "watcher did not exit for the routine signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not report the routine signal"

  # Drain it and route through the daemon: a routine status self-handles.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" \
    || fail "drain after routine signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "routine signal was not queued"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $status_file" "$state"
  ack_handled_wakes "$state" "$drain_err" || fail "routine wake acknowledgement failed"
  [ ! -s "$state/.subsuper-escalations" ] || fail "routine status was escalated by the daemon"

  # The watcher is now DOWN (one-shot exit). A terminal status lands while it is
  # down; the next watcher run must catch it up (losslessness across restart).
  printf 'done: PR https://example.test/pr/900\n' >> "$status_file"
  : > "$out"
  run_watcher_once "$state" "$fakebin" "$out" || fail "restarted watcher did not exit for the terminal signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "terminal signal written while watcher down was not caught on restart"

  # Drain and route the terminal: exactly ONE digest is buffered.
  : > "$drain_out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" \
    || fail "drain after terminal signal failed"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $status_file" "$state"
  ack_handled_wakes "$state" "$drain_err" || fail "terminal wake acknowledgement failed"
  [ -s "$state/.subsuper-escalations" ] || fail "captain-relevant terminal status was not buffered"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "expected exactly one buffered digest after the terminal signal"

  # The catch-all heartbeat scan must NOT re-escalate the same status (no dup).
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "catch-all scan duplicated the already-buffered digest"

  # With afk active, the buffered digest flushes to the supervisor pane as ONE
  # submission (one typed line + one Enter), then the buffer clears.
  local sent
  sent="$dir/sent.log"; : > "$sent"
  printf '❯\n' > "$dir/pane.txt"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed for the buffered digest"
  [ "$(grep -c '\[ENTER\]' "$sent")" -eq 1 ] || fail "buffered digest was not submitted exactly once"
  assert_not_contains "$(< "$sent")" '--idle-handoff' 'a terminal status escalation does not need idle handoff instructions'
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after a successful flush"
  pass "lifecycle: routine self-handles, terminal survives a watcher restart, buffers once, no dup, injects once"
}

# --- Phase 2: stale working-pane transient -> persistent -> resumed ----------
test_stale_pane_transient_persistent_resume() {
  local dir state fakebin win key resumed_gen
  dir=$(make_supercase wd-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:fm-stale-w2"
  key=$(printf '%s' "stale-w2" | tr ':/.' '___')
  printf 'working: compiling\n' > "$state/stale-w2.status"

  # Transient: first stale observation self-handles and records a marker.
  stale_marker_record "$win" "$state"
  case "$(FM_STATE_OVERRIDE="$state" classify_stale "$win" "$state")" in
    self\|*) : ;;
    *) fail "transient stale did not self-handle" ;;
  esac
  [ -e "$state/.subsuper-stale-$key" ] || fail "transient stale did not record a persistence marker"

  # Persistent: the marker ages past the threshold and the pane is still idle, so
  # housekeeping escalates exactly once and clears the marker.
  printf 'idle prompt $\n' > "$dir/pane.txt"
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  : > "$state/.subsuper-escalations" 2>/dev/null || true
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state" \
    2>"$dir/housekeeping.err"
  [ ! -s "$dir/housekeeping.err" ] \
    || fail "missing task metadata leaked a raw read error: $(cat "$dir/housekeeping.err")"
  [ -s "$state/.subsuper-escalations" ] || fail "persistent stale did not escalate"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "stale marker not cleared after escalation"

  # Resumed: a fresh transient marker but the crew is provably working again ->
  # housekeeping clears the marker without escalating. The proof is the crew's
  # own semantic busy-state record (bin/fm-busy-lib.sh), not rendered pane text.
  stale_marker_record "$win" "$state"
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  printf 'Working...\n' > "$dir/pane.txt"
  fm_write_meta "$state/stale-w2.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
  resumed_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" stale-w2)
  "$ROOT/bin/fm-busy-event.sh" apply "$state" stale-w2 busy --gen "$resumed_gen" \
    --source pi-ext --event agent-start
  : > "$state/.subsuper-escalations"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "resumed stale marker was not cleared"
  [ ! -s "$state/.subsuper-escalations" ] || fail "resumed (busy) stale was escalated"
  pass "lifecycle: stale pane transient self-handles, persistent escalates once and clears, resumed clears quietly"
}

test_finished_worker_decision_does_not_wake_away_daemon_twice() (
  local dir state fakebin win out pane sent buffer test_now delay blocker
  command -v tasks-axi >/dev/null 2>&1 || { echo 'skip: tasks-axi not found (finished worker decision)'; return 0; }
  dir=$(make_supercase wd-finished); state="$dir/state"; fakebin="$dir/fakebin"
  win=sess:fm-finished; out="$dir/watch.out"; pane="$dir/worker-pane"; sent="$dir/sent.log"
  buffer="$state/.subsuper-escalations"
  export FM_HOME="$dir" FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH"
  export FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" FM_FAKE_TMUX_SENT="$sent"
  export FM_SUPERVISOR_BACKEND=tmux FM_DAEMON_PRIMARY_HARNESS=grok
  export FM_ESCALATE_BATCH_SECS=999999 FM_STALE_ESCALATE_SECS=5 FM_MAX_DEFER_SECS=0
  mkdir -p "$dir/data"
  fm_test_tasks_toml "$dir/.tasks.toml" || fail 'could not configure fixture backlog'
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  "$ROOT/bin/fm-tasks-axi.sh" add finished 'Prepare the release' >/dev/null || fail 'could not add the release task'
  "$ROOT/bin/fm-tasks-axi.sh" start finished >/dev/null || fail 'could not start the release task'
  fm_write_meta "$state/finished.meta" "window=$win" kind=ship harness=grok backend=tmux
  printf 'working: preparing the release\n' > "$state/finished.status"
  prime_status_seen "$state" "$state/finished.status" || fail 'could not mark the past progress seen'
  FM_AFK_MODE=away "$ROOT/bin/fm-afk-contract.sh" enter --words 'Hold decisions for return' >/dev/null \
    || fail 'could not enter away mode'
  printf 'Release prepared; waiting for approval to proceed.\n' > "$pane"
  printf '❯\n' > "$dir/supervisor-pane"
  test_now=$(date +%s)
  # shellcheck disable=SC2329 # Invoked indirectly by the sourced daemon functions.
  _now() { printf '%s\n' "$test_now"; }

  run_watcher_once "$state" "$fakebin" "$out" || fail 'watcher did not report the first idle observation'
  assert_contains "$(< "$out")" "stale: $win" 'expected the first idle observation'
  handle_durable_wakes "$(< "$out")" "$state" 2> "$dir/drain.err" \
    || fail "daemon did not handle the idle wake: $(< "$dir/drain.err")"
  test_now=$((test_now + 6))
  housekeeping "$state"
  assert_contains "$(< "$buffer")" "stale persisted 6s (possible wedge): $win" 'expected the initial escalation'
  FM_FAKE_TMUX_CAPTURE="$dir/supervisor-pane" escalate_flush "$state" || fail 'initial escalation was not delivered'
  [ "$(grep -c '\[ENTER\]' "$sent")" -eq 1 ] || fail 'expected exactly one submission before the decision handoff'
  assert_contains "$(< "$sent")" '--idle-handoff' 'the delivered idle escalation does not tell the supervisor how to record the handoff'
  assert_contains "$(< "$sent")" 'if inspection confirms' 'the delivered handoff must be conditional on inspection'
  "$ROOT/bin/fm-captain-hold.sh" hold finished --reason 'Approve proceeding with the prepared release?' --open-ended --idle-handoff >/dev/null \
    || fail 'could not record the pending decision'

  # A harmless display refresh is a distinct hash, not a new development.
  printf '\nContext remaining: 65%%\n' >> "$pane"
  run_watcher_once "$state" "$fakebin" "$out" || fail 'watcher did not hand off the display refresh'
  assert_contains "$(< "$out")" "stale: $win" 'expected the daemon to classify the refreshed idle display'
  handle_durable_wakes "$(< "$out")" "$state" 2> "$dir/drain.err" \
    || fail "daemon did not classify the refreshed display: $(< "$dir/drain.err")"
  for delay in 10 7; do
    test_now=$((test_now + delay))
    housekeeping "$state"
    [ ! -s "$buffer" ] || fail "daemon escalated the same finished worker again: $(< "$buffer")"
  done

  # The actual task changes without an answer or another pane refresh.
  blocker='the prepared release artifact expired'
  printf 'blocked [key=artifact-expired]: %s\n' "$blocker" >> "$state/finished.status"
  run_watcher_once "$state" "$fakebin" "$out" || fail 'watcher did not report the new blocker'
  assert_contains "$(< "$out")" "signal: $state/finished.status" 'expected a status wake for the new blocker'
  handle_durable_wakes "$(< "$out")" "$state" 2> "$dir/drain.err" \
    || fail "daemon did not handle the blocker: $(< "$dir/drain.err")"
  assert_contains "$(< "$buffer")" "$blocker" 'the old decision hid the new blocker'
  "$ROOT/bin/fm-captain-hold.sh" open finished >/dev/null || fail 'the pending decision did not stay open'
  pass 'lifecycle: the away daemon stays quiet after a finished worker decision but surfaces a new blocker'
)

test_routine_then_terminal_after_restart
test_stale_pane_transient_persistent_resume
test_finished_worker_decision_does_not_wake_away_daemon_twice
