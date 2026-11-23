#!/usr/bin/env bash
# Behavior tests for the supervision host loop (stub engine, both postures, wakes, closes, mirror, return)
# (bin/fm-supervision-host.sh, docs/supervision-host.md). Shared fixtures live
# in tests/supervision-host-helpers.sh.
#
# The loop cases run the real host, arm, watcher, wake grant, drain, outcome
# store, and lease scripts in a fixture home. The host runs as a child of a fake
# harness (a bash symlink named "claude") whose pid is the home's session lock,
# and its engine is a stub named by FM_SUPERVISION_ENGINE_CLAUDE_BIN that does
# what a branch turn does through the same scripts, so the real argument
# construction, bounding, and reaping are exercised without a model. A real
# status append drives each wake through the real watcher.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

test_park_exit_probe_uses_half_second_child_sleeps() {
  local home host_pid
  home=$(make_home park-cadence attended)
  cat > "$home/fakebin/sleep" <<'SH'
#!/bin/bash
pid=''
if [ -f "$FM_HOME/probe-host" ]; then
  IFS= read -r pid < "$FM_HOME/probe-host" || true
  if [ "$PPID" = "$pid" ]; then
    printf '%s\n' "$1" >> "$FM_HOME/park-sleeps"
  fi
fi
exec /bin/sleep "$@"
SH
  chmod +x "$home/fakebin/sleep"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "park-cadence: no watcher started"
  host_pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
  [ -n "$host_pid" ] || fail "park-cadence: no recorded host"
  printf '%s\n' "$host_pid" > "$home/probe-host"
  wait_until 100 test -s "$home/park-sleeps" || fail "park-cadence: no child sleep observed"
  [ "$(sort -u "$home/park-sleeps")" = 0.5 ] || fail "park-cadence: exit probing did not use half-second sleeps"
  stop_home_processes "$home"
  pass "host: parked child-exit sampling uses ordinary half-second sleeps"
}

test_attended_routine_wake_is_handled_on_the_engine_and_stays_off_main() {
  local home first drained
  home=$(make_home attended-routine attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "attended: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "attended: the wake was not handled on the engine: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re '^actor=branch$' "$first" "the attended engine must run as the branch actor"
  assert_no_re '^POSTURE: AWAY' "$first" "an attended wake must carry no away tail"
  assert_re '^(arg=)?FIRSTMATE SUPERVISION WAKE: signal: ' "$first" "the attended wake must carry the close"
  assert_re '	handled	turn=[^	]*	posture=attended	' "$home/state/.supervision-host.log" "the ledger must record the attended turn"
  assert_grep '"verdict":"routine"' "$home/state/branch-outcomes.jsonl" "the engine's routine report did not reach the store"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the engine's acknowledgement did not consume the wake"
  assert_no_grep 'supervision-host-return' "$home/state/.wake-queue" "an attended report must queue no return wake for main"
  assert_grep 'it waits in the outcome store for MAIN' "$home/engine-report.log" "an attended routine report must say it stays in the store"
  [ ! -s "$home/host.rc" ] || fail "a routine attended outcome reached main: $(cat "$home/host.out")"
  [ "$(grep -cv '^watcher: started pid=' "$home/host.out")" -eq 0 ] \
    || fail "a routine attended outcome printed more than the first cycle's status to main: $(cat "$home/host.out")"
  watcher_live "$home" || fail "the host is not parked on a live successor after an attended wake"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES, ROUTINE (handled by the supervision session since your last drain" \
    "main's next drain must list the routine outcome for awareness"
  assert_contains "$drained" "[seq 1] demo: stub handled demo" "the routine listing must carry the outcome"
  assert_not_contains "$drained" "mark-processed" "a routine outcome must ask for no acknowledgement"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "[seq 1]" "a routine outcome must be listed only once"
  pass "host: an attended wake the branch may take is handled on the engine, and its routine outcome never wakes main"
}


# A TERM that lands just after a handled wake, while the host settles its
# successor handoff under the queue and marker locks, must not leave the host
# waiting in its own exit cleanup on the queue lock it still holds: that wedged
# the host (and every later queue append) instead of exiting.

test_host_stopped_right_after_a_handled_wake_exits_and_frees_the_queue() {
  local home pid
  home=$(make_home handled-then-term attended)
  echo hold-marker > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "handled then TERM: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "handled then TERM: the wake was not handled on the engine: $(cat "$home/state/.supervision-host.log")"
  pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
  [ -n "$pid" ] || fail "fixture: no host record after the handled wake"
  kill -TERM "$pid" 2>/dev/null || true
  wait_until 100 bash -c '! kill -0 "$1" 2>/dev/null' _ "$pid" \
    || fail "handled then TERM: the host did not exit within 10s of TERM after a handled wake"
  FM_HOME="$home" timeout 10 bash -c '. "$1"; fm_wake_append check probe "check: probe"' _ "$ROOT/bin/fm-wake-lib.sh" \
    || fail "handled then TERM: the stopped host left the wake queue lock held"
  stop_home_processes "$home"
  pass "host: a host stopped right after a handled wake exits and leaves the wake queue usable"
}


# A wrapper may launch the engine in another time zone than the host's (one
# observed wrapper exports a TZ the main session's hooks never see). The
# process-table identity that ties the branch grant to the host must read the
# same from both, or the engine's drain discards the grant as stale, refuses,
# and leaves every granted row for main. The proc root is hidden so Linux takes
# the same process-table path as macOS.

test_engine_in_another_time_zone_handles_its_granted_rows() {
  local home no_proc
  home=$(make_home engine-tz attended)
  no_proc="$TMP_ROOT/engine-tz-no-proc"
  [ "$(TZ=UTC0 LC_ALL=C ps -p $$ -o lstart=)" != "$(TZ=ENG-9 LC_ALL=C ps -p $$ -o lstart=)" ] \
    || fail "fixture: ps renders the same start time in both time zones, so the case would prove nothing"
  printf 'ENG-9\n' > "$home/stub-tz"
  TZ=UTC0 FM_PROC_ROOT_OVERRIDE="$no_proc" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "engine tz: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "engine tz: the turn did not end handled: $(cat "$home/state/.supervision-host.log"; cat "$home"/engine-drain.* 2>/dev/null)"
  assert_no_re '	failed	' "$home/state/.supervision-host.log" "engine tz: a turn that reported for its granted rows must not fail"
  assert_no_grep 'no branch-eligible row snapshot' "$home/engine-drain.1" "engine tz: the engine's drain discarded the host's grant"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "engine tz: the engine's acknowledgement did not consume the wake"
  [ ! -s "$home/host.rc" ] || fail "engine tz: the handled wake reached main: $(cat "$home/host.out")"
  pass "host: an engine in another time zone than the host drains, reports, and acknowledges its granted rows"
}

test_attended_captain_outcome_reaches_main_through_branch_outcomes() {
  local home drained
  home=$(make_home attended-captain attended)
  echo captain > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "captain: the host never started a watcher cycle"
  append_status "$home" 'ready for review'
  wait_until_deadline 60 host_exited "$home" || fail "captain: the captain outcome did not wake main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a captain-outcome exit must exit 0 for the owner to deliver"
  assert_re '^supervision-host: branch-outcome: .*\(store rows 1\); run bin/fm-wake-drain.sh' "$home/host.out" \
    "the exit must name the captain outcome's store row and send main to its drain"
  assert_no_re '^signal:' "$home/host.out" "the close the engine handled must not reach main as a wake"
  assert_grep 'MAIN processes it from its next drain' "$home/engine-report.log" "an attended captain report must say main processes it"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the handled wake must stay acknowledged"
  assert_no_grep 'supervision-host-return' "$home/state/.wake-queue" "an attended captain report must queue no return wake"
  watcher_live "$home" && fail "the host left its successor cycle running when it woke main"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES (captain outcomes the supervision session recorded for you" "main's drain must present the captain outcome"
  assert_contains "$drained" "[seq 1, recorded " "the section must carry the outcome's row and when it was recorded"
  assert_contains "$drained" " ago] demo: stub escalated: " "the section must carry the outcome's task and summary"
  assert_contains "$drained" "run bin/fm-branch-outcome.sh mark-processed --through 1" "the section must print its exact acknowledgement"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" " ago] demo: stub escalated: " "an unacknowledged captain outcome must be presented again"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 1 >/dev/null \
    || fail "main's acknowledgement of the presented outcome was refused"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "an acknowledged captain outcome must not be presented again"
  pass "host: an attended captain outcome wakes main once and stays in its drain until main acknowledges it"
}

test_captain_leaving_mid_turn_keeps_its_captain_outcome_for_the_return() {
  local home drained
  home=$(make_home attended-go-away attended)
  echo go-away > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "go-away: the host never started a watcher cycle"
  append_status "$home" 'finished while the captain left'
  wait_until 250 handled_at_least "$home" 1 || fail "go-away: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  [ -f "$home/state/.afk-contract" ] || fail "fixture: the stub did not record the away posture"
  [ ! -s "$home/host.rc" ] || fail "a captain outcome recorded after the captain left woke main: $(cat "$home/host.out")"
  assert_grep '"verdict":"captain"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report a captain outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "captain outcomes must wait for the return while the away record exists"
  FM_HOME="$home" "$CONTRACT" archive >/dev/null 2>&1 || fail "fixture: could not archive the away posture"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" " ago] demo: stub handled demo" "after the return the drain must present the away window's captain outcome"
  pass "host: a captain outcome recorded after the captain left waits for the return, then reaches main's drain"
}


# A quiet record left without its daemon (no state/.afk) is a present captain,
# not an away one: the host runs attended beside it, so a captain outcome wakes
# main and reaches its drain instead of waiting for a return that never comes,
# and a decision close reaches main as the plain arm delivers it.

test_quiet_record_without_its_daemon_is_a_present_captain() {
  local home drained
  home=$(make_home quiet-captain quiet)
  echo captain > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "quiet: the host never started a watcher cycle"
  append_status "$home" 'ready for review'
  wait_until_deadline 60 host_exited "$home" || fail "quiet: the captain outcome did not wake the present captain's main: $(cat "$home/state/.supervision-host.log")"
  assert_re '	handled	turn=[^	]*	posture=attended	' "$home/state/.supervision-host.log" "a quiet record must leave the host's turn attended"
  assert_no_re '^POSTURE: AWAY' "$home/engine-call.1" "a turn beside a quiet record must carry no away tail"
  assert_re 'MAIN DIALOG MIRROR' "$home/engine-call.1" "a turn beside a quiet record must carry the captain's dialog"
  assert_grep 'MAIN processes it from its next drain' "$home/engine-report.log" "a captain report beside a quiet record must say main processes it"
  assert_re '^supervision-host: branch-outcome: .*\(store rows 1\); run bin/fm-wake-drain.sh' "$home/host.out" \
    "the exit must name the captain outcome's store row for the present captain"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES (captain outcomes the supervision session recorded for you" "main's drain must present the captain outcome beside a quiet record"
  assert_contains "$drained" " ago] demo: stub escalated: " "the section must carry the outcome"
  [ -f "$home/state/.afk-contract" ] || fail "the host must leave quiet mode's record in place"

  home=$(make_home quiet-main-only quiet)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "quiet main-only: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  wait_until_deadline 60 host_exited "$home" || fail "quiet main-only: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_re '^signal: .*demo.status' "$home/host.out" "the decision close must reach main as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "quiet main-only: the engine took a decision close from a present captain"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record the attended main-only pass-through"
  pass "host: a quiet record without its daemon is a present captain, so outcomes and decisions reach main"
}

assert_attended_main_only_status() {  # <verb>
  local home
  home=$(make_home "attended-main-only-$1" attended)
  printf 'kind=secondmate\n' >> "$home/state/demo.meta"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "main-only: the host never started a watcher cycle"
  append_status "$home" 'which export format?' "$1"
  wait_until_deadline 60 host_exited "$home" || fail "main-only: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a main-only close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "a main-only close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "main-only: the engine ran for a decision close"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the decision wake must stay queued for main"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  stop_home_processes "$home"
  pass "host: an attended $1 close stays main's exactly as the plain arm delivers it"
}

test_attended_main_only_close_passes_straight_to_main() { assert_attended_main_only_status needs-decision; }
test_attended_blocked_close_passes_straight_to_main() { assert_attended_main_only_status blocked; }

test_attended_failed_status_reaches_main() {
  local home drain
  home=$(make_home attended-failed-status attended)
  printf 'captain\n' > "$home/stub-mode"
  printf '0\n' > "$home/park-clock"
  install_first_offer_action "$home" 'printf "121\n" > "$FM_HOME/park-clock"'
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=120 \
    FM_SUPERVISION_HOST_PARK_LIMIT=240 FM_SUPERVISION_HOST_TURN_TIMEOUT=30 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "failed status: watcher never started"
  append_status "$home" 'build could not complete' failed
  wait_until_deadline 60 host_exited "$home" || fail "failed status: failure did not reach main"
  assert_re '^supervision-host: branch-outcome:' "$home/host.out" "failed status did not come back as a captain outcome"
  assert_grep 'build could not complete' "$home/engine-drain.1" "the failure was absent from the branch's drain"
  drain=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drain" 'BRANCH OUTCOMES (captain outcomes' "main's drain lost the failure outcome"
  stop_home_processes "$home"
  pass "host: an attended failed status can surface as a captain outcome"
}

routine_wake_lib() {  # <home> <wake-lib function> [args...]
  local home=$1
  shift
  FM_HOME="$home" bash -c '. "$1"; shift; "$@"' _ "$ROOT/bin/fm-wake-lib.sh" "$@"
}

assert_routine_close_acknowledged() {  # <home> <reason pattern>
  local home=$1 log="$1/state/.supervision-host.log"
  wait_until_deadline 60 grep -Eq 'routine-ack|pass-through|to-main' "$log" \
    || fail "the host did not classify the routine close"
  assert_re "routine-ack[[:space:]]+$2" "$log" "the host did not acknowledge the routine close"
  [ ! -s "$home/state/.wake-queue" ] || fail "the routine close was not removed from the queue"
  [ "$(engine_calls "$home")" = 0 ] || fail "a deterministic acknowledgement ran an engine turn"
  [ ! -s "$home/host.rc" ] || fail "a routine close exited to main"
  assert_no_re '^(signal:|stale:|check:|supervision-host:)' "$home/host.out" "a routine close reached main"
  watcher_live "$home" || fail "the host did not retain its successor watcher"
}

# Delay only the release of evidence until the watcher has already closed.
# The real offer and host still classify at their normal boundaries.
install_first_offer_action() {  # <home> <shell command> [second offer action]
  local real_node
  real_node=$(command -v node)
  cat > "$1/fakebin/node" <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = offer ] && [ ! -e "\$FM_HOME/offer-action-ran" ]; then
  : > "\$FM_HOME/offer-action-ran"
  $2 || exit 1
elif [ "\${2:-}" = offer ] && [ ! -e "\$FM_HOME/second-offer-action-ran" ]; then
  : > "\$FM_HOME/second-offer-action-ran"
  ${3:-:} || exit 1
fi
exec "$real_node" "\$@"
SH
  chmod +x "$1/fakebin/node"
}

test_answer_receipt_is_serialized_with_classification() {
  local home f writer reader
  home=$(make_home answer-receipt-race attended)
  f="$home/state/demo.status"
  printf 'needs-decision [key=answer-test]: choose\n' > "$f"
  routine_wake_lib "$home" fm_wake_append signal demo.status "needs-decision: $f"
  main_drain_and_ack "$home"
  FM_HOME="$home" bash -c '
    . "$1"
    mv() {
      if [ "${3:-}" = "$FM_HOME/state/.demo.home-appends" ]; then
        : > "$FM_HOME/publishing"
        for ((i=0; i<200; i++)); do
          [ ! -f "$FM_HOME/release-receipt" ] || break
          command sleep 0.05
        done
      fi
      command mv "$@"
    }
    fm_wake_status_append_self_announced "${2%/*}" "$2" "resolved [key=answer-test]: answered: go ahead"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$f" &
  writer=$!
  wait_until_deadline 5 test -f "$home/publishing" || fail "receipt publication did not reach the test seam"
  FM_HOME="$home" bash -c '
    . "$1"
    _fm_wake_require_classify
    sleep() { : > "$FM_HOME/reader-waiting"; command sleep "$@"; }
    status_unread_only_home_answers "$2"
    printf "%s\n" "$?" > "$FM_HOME/reader-result"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$f" &
  reader=$!
  wait_until_deadline 5 test -f "$home/reader-waiting" || fail "classification did not wait for the in-flight receipt"
  [ ! -e "$home/reader-result" ] || fail "classification completed before the receipt was published"
  : > "$home/release-receipt"
  wait "$writer" || true
  wait "$reader"
  expect_code 0 "$(<"$home/reader-result")" "classification must recognize the answer after publication"
  pass "host: answer classification waits for an in-flight owned append receipt"
}

seed_open_captain_hold() {  # <home> <key>
  local home=$1 key=$2
  fm_test_tasks_toml "$home/.tasks.toml"
  mkdir -p "$home/data"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  (cd "$home" && FM_HOME="$home" tasks-axi add demo 'Inspect routing' --kind scout --repo demo --start) >/dev/null \
    || fail "fixture: could not create the origin task"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" hold "$key" --open-ended \
    --title 'Choose the route' --reason 'A routing decision is pending' --repo demo --origin demo >/dev/null \
    || fail "fixture: could not register the captain call"
}

test_attended_answer_close() {  # <owned|external|mixed|capped|divergence>
  local mode=$1 home state f baseline action real_mv i note initial prior_size other other_size other_sig second_action
  local key=answer-test answer='answered: go ahead' opening=choose
  home=$(make_home "attended-answer-$mode" quiet)
  state="$home/state"
  f="$state/demo.status"
  case "$mode" in
    divergence|unreadable-hold) seed_open_captain_hold "$home" answer-test ;;
    handback-lock) seed_open_captain_hold "$home" unrelated-call ;;
  esac
  case "$mode" in
    operator|other-reply)
      key=pending-reply-00005e7700000000
      opening='pending-reply-unanswered: choose'
      answer="pending-reply-resolved: task=demo pending-reply-id=${key#pending-reply-} via=operator-resolve-key go ahead"
      [ "$mode" != other-reply ] || answer=${answer/operator-resolve-key/parent-reply}
      ;;
  esac
  printf 'kind=secondmate\n' >> "$state/demo.meta"
  printf 'needs-decision [key=%s]: %s\n' "$key" "$opening" > "$f"
  routine_wake_lib "$home" fm_wake_status_mark_current "$state" "$f" || fail "fixture: could not baseline the decision"
  if [ "$mode" = capped ]; then
    printf -v note '%0200d' 0
    for ((i=1; i<=25; i++)); do
      printf 'needs-decision [key=sibling-%s]: %s\n' "$i" "$note"
    done >> "$f"
    printf 'note: status summary\n' >> "$f"
    initial=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
    assert_contains "$initial" '[key=answer-test] needs-decision:' "fixture: the answered key was not displayed"
    assert_contains "$initial" 'more omitted (byte cap)' "fixture: the drain did not cap the decisions"
    assert_not_contains "$initial" '[key=sibling-24]' "fixture: an omitted sibling was displayed"
  else
    routine_wake_lib "$home" fm_wake_append signal demo.status "needs-decision: $f" || fail "fixture: could not queue the decision"
  fi
  if [[ "$mode" = coalesced-* ]]; then
    other="$state/zed.status"
    printf 'project=zed\nwindow=fm-zed\nkind=secondmate\n' > "$state/zed.meta"
    printf 'needs-decision [key=zed-answer]: choose\n' > "$other"
    routine_wake_lib "$home" fm_wake_append signal zed.status "needs-decision: $other"
  fi
  main_drain_and_ack "$home"
  [ ! -s "$state/.wake-queue" ] || fail "fixture: prior decision is still queued"
  if [[ "$mode" = coalesced-* ]]; then
    other_size=$(wc -c < "$other" | tr -d ' ')
    other_sig=$(routine_wake_lib "$home" fm_wake_signal_sig "$other")
    routine_wake_lib "$home" fm_wake_status_append_self_announced "$state" "$other" 'resolved [key=zed-answer]: answered: proceed'
    routine_wake_lib "$home" fm_wake_status_seen_commit "$state" "$other" "$other_size" "$other_size"
    routine_wake_lib "$home" fm_wake_status_reported_commit "$state" "$other" "$other_sig"
  fi
  prior_size=$(wc -c < "$f" | tr -d ' ')
  baseline=$(routine_wake_lib "$home" fm_wake_signal_sig "$f")
  routine_wake_lib "$home" fm_wake_status_reported_commit "$state" "$f" "$baseline" || fail "fixture: prior decision could still wake"
  action=:
  if [ "$mode" != external ]; then
    real_mv=$(command -v mv)
    cat > "$home/fakebin/mv" <<SH
#!/usr/bin/env bash
if [ "\${3:-}" = "\$FM_HOME/state/.demo.home-appends" ]; then
  exec "$real_mv" "\$2" "\$FM_HOME/delayed-home-appends"
fi
exec "$real_mv" "\$@"
SH
    chmod +x "$home/fakebin/mv"
    FM_HOME="$home" PATH="$home/fakebin:$PATH" bash -c '
      . "$1"
      fm_wake_status_append_self_announced "$2" "$3" "$4"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$f" "resolved [key=$key]: $answer"
    [ -s "$home/delayed-home-appends" ] || fail "fixture: no append receipt was delayed"
    rm "$home/fakebin/mv"
    # The watcher was already looking at the prior signature when the writer
    # appended. Restore its pre-answer classified position, not presentation.
    routine_wake_lib "$home" fm_wake_status_seen_commit "$state" "$f" \
      "$prior_size" "$(awk -F '\t' '$1 == "demo" { print $2 }' "$state/.status-presentation-cursor")" \
      || fail "fixture: could not replay the watcher snapshot"
    routine_wake_lib "$home" fm_wake_status_reported_commit "$state" "$f" "$baseline" || fail "fixture: could not restore the old signature"
    action='mv "$FM_HOME/delayed-home-appends" "$FM_HOME/state/.demo.home-appends"'
  else
    printf 'resolved [key=answer-test]: answered: go ahead\n' >> "$f"
  fi
  if [ "$mode" = mixed ]; then
    action+=$'\n''  printf "needs-decision [key=new-choice]: choose again\n" >> "$FM_HOME/state/demo.status"'
  fi
  if [ "$mode" = divergence ]; then
    action+=$'\n''lock="$FM_HOME/state/.watcher-down.lock"
      mkdir "$lock" || exit 1
      ( sleep 5; rm -f "$lock/pid"; rmdir "$lock" ) </dev/null >/dev/null 2>&1 &
      printf "%s\n" "$!" > "$lock/pid"'
  fi
  if [[ "$mode" = coalesced-* ]]; then
    printf '0\n' > "$home/park-clock"
    printf -v second_action '%q "$@" || exit 1\nprintf "110\\n" > "$FM_HOME/park-clock"\n' "$(command -v node)"
    if [ "$mode" = coalesced-locked ]; then
      second_action+='lock="$FM_HOME/state/.demo.home-appends.lock"
      mkdir "$lock" && cp "$FM_HOME/state/.lock" "$lock/pid" || exit 1
'
    else
      second_action+='printf "working: continuing\n" >> "$FM_HOME/state/demo.status"
'
    fi
    second_action+='printf "needs-decision [key=late-zed]: choose again\n" >> "$FM_HOME/state/zed.status"
    exit'
    install_first_offer_action "$home" "$action" "$second_action"
  elif [ "$mode" = late-rejection ]; then
    : > "$home/config/supervision-handoff-ack"
    install_first_offer_action "$home" "$action" '
      printf "needs-decision [key=late]: choose again\n" >> "$FM_HOME/state/demo.status"
      lock="$FM_HOME/state/.wake-queue.lock"
      mkdir "$lock" || exit 1
      ( sleep 6; rm -f "$lock/pid"; rmdir "$lock" ) </dev/null >/dev/null 2>&1 &
      printf "%s\n" "$!" > "$lock/pid"'
  else
    install_first_offer_action "$home" "$action"
  fi
  case "$mode" in
    unreadable-hold)
      printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/tasks-axi"
      chmod +x "$home/fakebin/tasks-axi"
      ;;
    handback-lock)
      : > "$home/config/supervision-handoff-ack"
      {
        printf '#!/usr/bin/env bash\n'
        printf 'if [ "$1" = list ] && [ -e "$FM_HOME/second-offer-action-ran" ]; then for lock in .wake-queue.lock .fm-lease-command.lock; do mkdir "$FM_HOME/state/$lock" && printf "%%s\\n" %s > "$FM_HOME/state/$lock/pid"; done; fi\n' "$$"
        printf 'exec %q "$@"\n' "$(command -v tasks-axi)"
      } > "$home/fakebin/tasks-axi"
      chmod +x "$home/fakebin/tasks-axi"
      ;;
  esac
  if [ "$mode" = handback-lock ]; then
    FM_STATUS_PRESENTATION_LOCK_TIMEOUT=2 start_host "$home"
    wait_until_deadline 35 host_exited "$home" || fail "routine hand-back waited on the stalled queue lock"
    assert_re '^signal: .*demo.status' "$home/host.out" "hand-back failure must preserve the original close"
    assert_grep 'the acknowledged hand-back could not be recorded' "$home/host.out" "contended hand-back must report failure"
    [ -s "$state/.wake-queue" ] || fail "contended hand-back lost the queued wake"
    rm -f "$state/.wake-queue.lock/pid"
    rmdir "$state/.wake-queue.lock"
    rm -f "$state/.fm-lease-command.lock/pid"
    rmdir "$state/.fm-lease-command.lock"
  elif [[ "$mode" = coalesced-* ]]; then
    FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=120 \
      FM_SUPERVISION_HOST_TURN_TIMEOUT=20 start_host "$home"
  elif [ "$mode" = late-rejection ] || [ "$mode" = divergence ]; then
    FM_STATUS_PRESENTATION_LOCK_TIMEOUT=2 start_host "$home"
  else
    start_host "$home"
  fi
  if [ "$mode" = owned ] || [ "$mode" = operator ]; then
    assert_routine_close_acknowledged "$home" 'signal: .*demo.status'
  elif [ "$mode" = other-reply ]; then
    wait_until_deadline 60 grep -Eq 'routine-ack|pass-through|to-main|handled' "$state/.supervision-host.log" \
      || fail "the nonoperator reply did not route"
    assert_no_re 'routine-ack' "$state/.supervision-host.log" "a nonoperator reply must not bypass ordinary routing"
  elif [ "$mode" != handback-lock ]; then
    wait_until_deadline 60 host_exited "$home" || fail "$mode: did not hand the signal back to main"
    assert_re '^signal: .*demo.status' "$home/host.out" "$mode: the signal did not reach main"
    [ -s "$state/.wake-queue" ] || fail "$mode: the host consumed consequential work"
    if [[ "$mode" = coalesced-* ]]; then
      if [ "$mode" = coalesced-locked ]; then
        [ -s "$state/.demo.home-appends.lock/pid" ] || fail "fixture: no answer receipt lock was held"
        rm "$state/.demo.home-appends.lock/pid"
        rmdir "$state/.demo.home-appends.lock"
      fi
      [ -e "$home/second-offer-action-ran" ] || fail "fixture: no final offer"
      assert_re '^signal: .*demo.status .*zed.status' "$home/host.out" "the coalesced close must reach main"
      assert_no_re '^supervision-host: cycle boundary' "$home/host.out" "the older offer must not force a deadline hand-back"
      [ "$(engine_calls "$home")" -eq 0 ] || fail "the older offer took the coalesced wake"
      watcher_live "$home" || fail "the late decision hand-back left no successor"
    elif [ "$mode" = late-rejection ]; then
      expect_code 0 "$(<"$home/host.rc")" "a late rejection must not time out its ordinary hand-back"
      assert_grep 'check: supervision-handoff' "$state/.wake-queue" "ordinary hand-back must publish its check"
    elif [ "$mode" = divergence ]; then
      expect_code 0 "$(<"$home/host.rc")" "a known hold must use ordinary hand-back despite marker contention"
      assert_no_re '^supervision-host:|^watcher: FAILED' "$home/host.out" "known divergence should pass through unchanged"
      initial=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
      assert_contains "$initial" 'answer-test [key=answer-test] reads resolved' "the open structured hold must reach main"
    fi
  fi
  stop_home_processes "$home"
  pass "host: attended answer signal with $mode provenance/content routes correctly"
}

test_attended_busy_inbox_close() {  # <mode> [kind]
  local mode=$1 kind=${2:-secondmate} home rec
  home=$(make_home "attended-busy-$mode-$kind" quiet)
  [ "$mode" != missing ] || kind=ship
  printf 'project=demo\nwindow=sess:fm-demo\nkind=%s\nharness=grok\n' "$kind" > "$home/state/demo.meta"
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  capture-pane) echo BUSYTOKEN ;;
  display-message) echo fakepane ;;
  list-windows)
    if [ -e "$FM_HOME/missing-endpoint" ] && [ "$*" = 'list-windows -t sess -F #{window_name}' ]; then
      echo other
    else
      echo fm-demo
    fi ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/tmux"
  rec=$(FM_HOME="$home" bash -c '. "$1"; fm_task_inbox_write "$2" demo steer' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state") \
    || fail "fixture: could not write an inbox record"
  if [ "$mode" = handled ]; then
    install_first_offer_action "$home" 'mv "$FM_HOME/state/demo.inbox/001.msg" "$FM_HOME/state/demo.inbox/handled/"'
  elif [ "$mode" = decision ]; then
    install_first_offer_action "$home" 'mv "$FM_HOME/state/demo.inbox/001.msg" "$FM_HOME/state/demo.inbox/handled/"
    printf "needs-decision [key=inbox-choice]: choose an approach\n" >> "$FM_HOME/state/demo.status"'
  elif [ "$mode" = stuck-late ]; then
    printf '0\n' > "$home/park-clock"
    install_first_offer_action "$home" 'printf "121\n" > "$FM_HOME/park-clock"'
  elif [[ "$mode" = final-* ]]; then
    local first_action=: second_action=''
    if [ "$mode" != final-decision ]; then
      first_action='mv "$FM_HOME/state/demo.inbox/001.msg" "$FM_HOME/state/demo.inbox/handled/"'
    fi
    if [ "$mode" = final-after-offer ]; then
      printf -v second_action '%q "$@" || exit 1\nprintf "110\\n" > "$FM_HOME/park-clock"\n' "$(command -v node)"
    else
      second_action='printf "120\n" > "$FM_HOME/park-clock"'
    fi
    second_action+=$'\n''printf "needs-decision [key=inbox-choice]: choose an approach\n" >> "$FM_HOME/state/demo.status"'
    if [ "$mode" = final-after-offer ]; then second_action+=$'\n''exit'; fi
    printf '0\n' > "$home/park-clock"
    install_first_offer_action "$home" "$first_action" "$second_action"
  elif [ "$mode" = missing ] || [ "$mode" = unhandled-decision ]; then
    if [ "$mode" = missing ]; then : > "$home/missing-endpoint"; fi
    printf '117\n' > "$home/park-clock"
    install_first_offer_action "$home" 'sleep 4
    printf "needs-decision [key=inbox-choice]: choose an approach\n" >> "$FM_HOME/state/demo.status"'
  fi
  local park_limit=120
  [ "$mode" != stuck-late ] || park_limit=240
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=120 \
    FM_SUPERVISION_HOST_PARK_LIMIT="$park_limit" FM_SUPERVISION_HOST_TURN_TIMEOUT=20 \
    FM_BUSY_REGEX=BUSYTOKEN FM_TASK_INBOX_GRACE_SECS=0 start_host "$home"
  if [ "$mode" = missing ] || [ "$mode" = unhandled-decision ]; then
    wait_until_deadline 30 host_exited "$home" || fail "ordinary stale did not reach main"
    if [ "$mode" = missing ]; then
      assert_re '^stale: .*endpoint is missing' "$home/host.out" "the missing endpoint reason must reach main"
    else
      assert_re '^stale: .*stuck-busy' "$home/host.out" "the unhandled decision-owned stale must reach main"
      [ "$(engine_calls "$home")" -eq 0 ] || fail "the branch took a decision-owned stale row"
    fi
    assert_no_re '^supervision-host: cycle boundary' "$home/host.out" "the ordinary stale offer must not use the routine timeout"
    [ -f "$rec" ] || fail "missing endpoint work was lost"
  elif [[ "$mode" = final-* ]]; then
    wait_until_deadline 60 host_exited "$home" || fail "the final decision-owned stale did not reach main"
    assert_re '^stale: .*stuck-busy' "$home/host.out" "the final main-only close was lost"
    assert_no_re '^supervision-host: cycle boundary' "$home/host.out" "the final hand-back must preserve the successor"
    watcher_live "$home" || fail "the final hand-back left no live successor"
    if [ "$mode" != final-decision ]; then
      [ -f "${rec%/*}/handled/${rec##*/}" ] || fail "the handled steer receipt was lost"
      assert_grep 'stuck-busy' "$home/state/.wake-queue" "the decision-owned stale must remain queued"
    else
      [ -f "$rec" ] || fail "the unhandled steer was lost"
    fi
    [ "$(engine_calls "$home")" -eq 0 ] || fail "the branch took a decision-owned stale row"
  elif [ "$mode" = handled ]; then
    if [ "$kind" = secondmate ]; then
      assert_routine_close_acknowledged "$home" 'stale: .*stuck-busy'
    else
      wait_until_deadline 60 grep -q 'stuck-busy' "$home/engine-drain.1" 2>/dev/null \
        || fail "a handled $kind stale bypassed ordinary branch routing"
    fi
    [ -f "$home/state/demo.inbox/handled/${rec##*/}" ] || fail "fixture: the worker did not handle the named record"
  elif [ "$mode" = decision ]; then
    wait_until_deadline 60 host_exited "$home" || fail "a handled stale hid a decision-owned wake"
    assert_re '^stale: .*stuck-busy' "$home/host.out" "the decision-owned stale must reach main"
    assert_grep 'stuck-busy' "$home/state/.wake-queue" "the decision-owned row must remain queued"
    [ "$(engine_calls "$home")" = 0 ] || fail "the branch took a decision-owned stale row"
  else
    wait_until_deadline 60 grep -q 'stuck-busy' "$home/engine-drain.1" 2>/dev/null \
      || fail "a branch-eligible stuck inbox did not reach the branch engine"
    [ -f "$rec" ] || fail "the stuck record was lost"
  fi
  stop_home_processes "$home"
  pass "host: a $mode $kind inbox stale closes in the correct destination"
}

test_attended_resurface() {  # <empty|routine|credential|captain-outcome|read-captain-outcome>
  local mode=$1 kind=${2:-secondmate} home rec reason seq f i note initial lock_timeout=10 via
  home=$(make_home "attended-resurface-$mode-$kind" quiet)
  : > "$home/state/.wake-queue"
  case "$mode" in
    divergence)
      seed_open_captain_hold "$home" routing-call
      f="$home/state/demo.status"
      printf 'needs-decision [key=routing-call]: north or south\nresolved [key=routing-call]: answered: north\n' > "$f"
      routine_wake_lib "$home" fm_wake_status_mark_current "$home/state" "$f" || fail "fixture: status would wake independently"
      ;;
    unread-reply|operator-reply)
      f="$home/state/demo.status"
      printf 'blocked [key=pending-reply-00005e7700000000]: pending-reply-missed: waiting for a secondmate report\n' > "$f"
      routine_wake_lib "$home" fm_wake_append signal demo.status "needs-decision: $f" || fail "fixture: no escalation row"
      main_drain_and_ack "$home"
      [ ! -s "$home/state/.wake-queue" ] || fail "fixture: escalation was not drained"
      routine_wake_lib "$home" fm_wake_status_mark_current "$home/state" "$f" || fail "fixture: could not mark escalation surfaced"
      via=status
      [ "$mode" != operator-reply ] || via=operator-resolve-key
      routine_wake_lib "$home" fm_wake_status_append_self_announced "$home/state" "$f" \
        "resolved [key=pending-reply-00005e7700000000]: pending-reply-resolved: task=demo pending-reply-id=00005e7700000000 via=$via" \
        || fail "fixture: reply closure was not self-announced"
      ;;
    new-decision|presented-decision|reopened-decision)
      f="$home/state/demo.status"
      printf 'blocked [key=recovery-choice]: choose an approach\n' > "$f"
      if [ "$mode" != new-decision ]; then
        main_drain_and_ack "$home"
      fi
      if [ "$mode" = reopened-decision ]; then
        printf 'resolved [key=recovery-choice]: answered\nblocked [key=recovery-choice]: choose an approach\n' >> "$f"
      fi
      routine_wake_lib "$home" fm_wake_status_mark_current "$home/state" "$f" || fail "fixture: decision would wake independently"
      ;;
    capped-decisions)
      f="$home/state/demo.status"
      printf -v note '%0200d' 0
      for ((i=1; i<=25; i++)); do
        printf 'blocked [key=choice-%s]: %s\n' "$i" "$note"
      done > "$f"
      initial=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
      assert_contains "$initial" 'more omitted (byte cap)' "fixture: drain did not cap open decisions"
      assert_not_contains "$initial" '[key=choice-25]' "fixture: the last open decision was already displayed"
      routine_wake_lib "$home" fm_wake_status_mark_current "$home/state" "$f" || fail "fixture: decisions would wake independently"
      ;;
    credential) routine_wake_lib "$home" fm_wake_append check needs-gh-auth 'check: GitHub login required' || fail "fixture: no credential check" ;;
    backstop|routine-backstop|routine|cooldown|away-cooldown)
      if [ "$mode" != backstop ]; then
        printf 'project=demo\nwindow=sess:fm-demo\nkind=%s\nharness=claude\n' "$kind" > "$home/state/demo.meta"
        rec=$(FM_HOME="$home" bash -c '. "$1"; fm_task_inbox_write "$2" demo steer' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state") || fail "fixture: no inbox record"
        mv "$rec" "${rec%/*}/handled/"
        reason="stale: sess:fm-demo (unread firstmate instruction: stuck-busy after 2 consecutive busy-deferred due doorbells; $rec stays unhandled and no doorbell was typed; inspect the worker)"
        printf 'needs-decision [key=answer-test]: choose\n' > "$home/state/demo.status"
        routine_wake_lib "$home" fm_wake_append signal demo.status "needs-decision: $home/state/demo.status"
        main_drain_and_ack "$home"
        routine_wake_lib "$home" fm_wake_status_mark_current "$home/state" "$home/state/demo.status"
        routine_wake_lib "$home" fm_wake_status_append_self_announced "$home/state" "$home/state/demo.status" \
          'resolved [key=answer-test]: answered: go ahead' || fail "fixture: answer was not self-announced"
        routine_wake_lib "$home" fm_wake_append signal demo.status "signal: $home/state/demo.status" || fail "fixture: no recovered answer row"
        routine_wake_lib "$home" fm_wake_append stale sess:fm-demo "$reason" || fail "fixture: no recovered stale row"
      fi
      if [ "$mode" = backstop ] || [ "$mode" = routine-backstop ]; then
        f="$home/state/review.status"
        printf 'failed: review build failed without a branch outcome\n' > "$f"
        routine_wake_lib "$home" fm_wake_status_mark_current "$home/state" "$f" || fail "fixture: failure would wake independently"
      fi
      ;;
    captain-outcome|read-captain-outcome|locked-captain-outcome)
      seq=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict captain \
        --summary 'a review requires attention') || fail "fixture: no captain outcome"
      if [ "$mode" = read-captain-outcome ]; then
        FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through "$seq" || fail "fixture: outcome was not marked read"
      fi
      ;;
  esac
  routine_wake_lib "$home" fm_recovery_marker_publish "$home/state/.watcher-down" downtime || fail "fixture: no recovery episode"
  printf '0\n' > "$home/park-clock"
  case "$mode" in
    empty|divergence) install_first_offer_action "$home" ': > "$FM_HOME/unexpected-empty-offer"; exit 1' ;;
    routine) install_first_offer_action "$home" 'printf "105\n" > "$FM_HOME/park-clock"' ;;
    locked-captain-outcome)
      lock_timeout=2
      {
        printf '#!/usr/bin/env bash\n'
        printf '%s\n' 'if [ "${1:-}" = -rs ] && [ "${2:-}" = '\''any(.verdict == "captain")'\'' ]; then
          lock="$FM_HOME/state/.watcher-down.lock"
          mkdir "$lock" || exit 1
          ( sleep 5; rm -f "$lock/pid"; rmdir "$lock" ) </dev/null >/dev/null 2>&1 &
          printf "%s\n" "$!" > "$lock/pid"
          : > "$FM_HOME/outcome-lock-held"
        fi'
        printf 'exec %q "$@"\n' "$(command -v jq)"
      } > "$home/fakebin/jq"
      chmod +x "$home/fakebin/jq"
      ;;
    cooldown|away-cooldown)
      local action
      action='key=$(bash -c '\''. "$1/fm-wake-lib.sh"; . "$1/fm-supervision-engine-lib.sh"; fm_supervision_host_config "$FM_HOME/config" claude; fm_supervision_host_health_key "$FM_HOME/state"'\'' _ "${1%/*}") || exit 1
      printf "key=%s\nerrors=2\ncooldown=300\nretry_after=%s\n" "$key" "$(( $(date +%s) + 300 ))" > "$FM_HOME/state/.supervision-host-health"'
      if [ "$mode" = away-cooldown ]; then
        action+=$'\n''FM_AFK_MODE=away "${1%/*}/fm-afk-contract.sh" enter --words "watch the fleet" >/dev/null'
      fi
      install_first_offer_action "$home" "$action"
      ;;
  esac
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=120 \
    FM_STATUS_PRESENTATION_LOCK_TIMEOUT="$lock_timeout" FM_SUPERVISION_HOST_TURN_TIMEOUT=20 FM_SUPERVISION_ENGINE_GRACE=1 start_host "$home"
  if [ "$mode" = empty ] || { [ "$mode" = routine ] && [ "$kind" = secondmate ]; } || [ "$mode" = cooldown ] || [ "$mode" = operator-reply ]; then
    assert_routine_close_acknowledged "$home" 'check: rearm-resurface$'
    assert_re '^acked:' "$home/state/.watcher-down" "resurfacing did not acknowledge recovery"
    [ ! -e "$home/unexpected-empty-offer" ] || fail "empty routine recovery invoked the offer"
  elif [ "$mode" = away-cooldown ]; then
    wait_until_deadline 30 host_exited "$home" || fail "cooldown did not hand the away wake back"
    assert_re '^check: rearm-resurface$' "$home/host.out" "the away wake must reach main during cooldown"
    assert_grep 'paused after repeated engine errors' "$home/host.out" "cooldown must explain the hand-back"
    [ "$(engine_calls "$home")" -eq 0 ] || fail "a cooling engine took the away wake"
    assert_grep 'stuck-busy' "$home/state/.wake-queue" "cooldown must leave the wake queued"
  else
    wait_until_deadline 60 host_exited "$home" || fail "$mode: recovery did not reach main"
    assert_re '^check: rearm-resurface$' "$home/host.out" "$mode: recovery was suppressed"
    local drain
    drain=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
    case "$mode" in
      routine) assert_contains "$drain" 'stuck-busy' "recovery lost the handled $kind stale" ;;
      credential) assert_contains "$drain" 'GitHub login required' "the credentials request was lost" ;;
      divergence)
        [ ! -e "$home/unexpected-empty-offer" ] || fail "rejected empty recovery invoked the offer"
        watcher_live "$home" || fail "rejected empty recovery left no successor watcher"
        assert_contains "$drain" 'RECORD DIVERGENCE' "recovery lost the captain hold divergence"
        assert_contains "$drain" 'routing-call [key=routing-call] reads resolved' "the unresolved captain call was lost"
        ;;
      new-decision|reopened-decision|presented-decision) assert_contains "$drain" '[key=recovery-choice] blocked: choose an approach' "the open decision was lost" ;;
      capped-decisions) assert_contains "$drain" 'more omitted (byte cap)' "recovery lost the open-decision overflow" ;;
      unread-reply)
        assert_contains "$drain" 'UNREAD STATUS' "recovery skipped unread status presentation"
        assert_contains "$drain" 'pending-reply-id=00005e7700000000 via=status' "recovery hid the secondmate closure"
        ;;
      backstop|routine-backstop)
        assert_contains "$drain" 'STATUS OUTCOME BACKSTOP (' "recovery did not preserve the backstop surface"
        assert_contains "$drain" 'review build failed without a branch outcome' "recovery lost the uncovered failure"
        ;;
      captain-outcome|read-captain-outcome|locked-captain-outcome)
        if [ "$mode" = locked-captain-outcome ]; then
          [ -f "$home/outcome-lock-held" ] || fail "fixture: no recovery marker contention"
          watcher_live "$home" || fail "captain outcome hand-back left no successor watcher"
        fi
        assert_contains "$drain" 'a review requires attention' "the captain outcome was lost"
        ;;
    esac
  fi
  stop_home_processes "$home"
  pass "host: attended recovery with $mode ($kind) routes correctly"
}

# The file is read at every wake (docs/configuration.md "Supervision host"), so
# an off written while the host is parked sends the next attended close to main
# exactly as the arm printed it, with the ledger naming the opt-out.

test_off_written_while_parked_passes_the_next_attended_close_to_main() {
  local home
  home=$(make_home attended-off-while-parked attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "off while parked: the host never started a watcher cycle"
  : > "$home/config/supervision-host-off"
  append_status "$home" 'step one'
  wait_until_deadline 60 host_exited "$home" || fail "off while parked: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a close on a home that opted out must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "off while parked: the engine ran after the home opted out"
  assert_re '	pass-through	attended	the home does not run the supervision host	signal:' "$home/state/.supervision-host.log" \
    "the ledger must name the opt-out as why the close went to main"
  stop_home_processes "$home"
  pass "host: an off written while the host is parked sends the next attended close to main, naming the opt-out"
}


# The live failure this guards: a main-only pass-through used to exit without
# a watcher, so nothing restarted short-lived listeners until the session
# armed again. The close still reaches main unchanged, and the successor
# cycle stays up for the session's next arm to attach to.

test_main_only_pass_through_leaves_the_successor_watcher_running() {
  local home pid
  home=$(make_home main-only-successor attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "successor: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  wait_until_deadline 60 host_exited "$home" || fail "successor: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a main-only close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "a main-only close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "successor: the engine ran for a decision close"
  watcher_live "$home" || fail "successor: the pass-through left no live watcher: $(cat "$home/state/.supervision-host.log")"
  [ "$(marker_kind "$home")" = downtime ] \
    || fail "successor: the pass-through claimed the close was being handled, so main's re-arm owner would not deliver it: $(cat "$home/state/.watcher-down")"
  pid=$(cat "$home/state/.watch.lock/pid")
  sleep 2
  kill -0 "$pid" 2>/dev/null || fail "successor: the watcher exited after the pass-through (pid $pid)"
  [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null)" = "$pid" ] || fail "successor: the watcher lock moved after the pass-through"
  pass "host: a main-only pass-through leaves the successor watcher running and the close undelivered for main"
}


# The session-lock holder's process identity cannot be read (its proc entry
# is truncated), so no main-session key exists: the close reaches main exactly
# as the arm printed it, before any mirror feed or engine turn.

test_attended_close_with_unidentified_main_session_passes_to_main() {
  local home
  home=$(make_home attended-unidentified attended)
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      mkdir -p "$FM_HOME/proc/$$"
      printf "%s (claude) S\n" "$$" > "$FM_HOME/proc/$$/stat"
      printf "claude\0" > "$FM_HOME/proc/$$/cmdline"
      export FM_PROC_ROOT_OVERRIDE="$FM_HOME/proc"
      "$0" park > "$FM_HOME/host.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/host.rc"
    ' "$HOST" 2>> "$home/claude.err" &
  wait_until 150 watcher_live "$home" || fail "unidentified: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until_deadline 60 host_exited "$home" || fail "unidentified: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a close for an unidentified main session must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "unidentified: the engine ran without a main-session key"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the wake must stay queued for main"
  assert_re '	pass-through	attended	the main session could not be identified	signal:' "$home/state/.supervision-host.log" \
    "the ledger must record why the close went to main"
  pass "host: an attended close whose main session cannot be identified reaches main and runs no engine turn"
}


# The captain returns after the loop accepted a decision close away but before
# its turn starts: the turn meets the attended rule, so the close still reaches
# main exactly as the arm printed it instead of being scoped to nothing.

test_close_accepted_away_that_turns_attended_passes_to_main() {
  local home real_mktemp
  home=$(make_home away-then-attended away)
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p0","prompt":"watch the fleet for me"}' > "$home/mirror-seed.0"
  real_mktemp=$(command -v mktemp)
  # Starting the successor arm is the first step after the loop's away check;
  # once the decision line is queued, the captain returns there.
  cat > "$home/fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in
  *.supervision-host-arm.*)
    ! grep -q 'which export format?' "\$FM_HOME/state/demo.status" 2>/dev/null \
      || "\$FM_REPO/bin/fm-afk-contract.sh" archive >> "\$FM_HOME/engine-return.log" 2>&1 ;;
esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$home/fakebin/mktemp"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away-then-attended: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  wait_until_deadline 60 host_exited "$home" || fail "away-then-attended: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_absent "$home/state/.afk-contract" "fixture: the captain did not return before the turn"
  expect_code 0 "$(cat "$home/host.rc")" "the close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "away-then-attended: the engine ran for a decision close"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the decision wake must stay queued for main"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  assert_no_re '	no-op	' "$home/state/.supervision-host.log" "the close must not be treated as handled"
  watcher_live "$home" || fail "the pass-through left no successor watcher"
  pass "host: a decision close accepted away whose turn starts attended still reaches main unchanged"
}

test_attended_close_that_turns_main_only_before_its_turn_passes_to_main() {
  local home
  home=$(make_home attended-turns-main-only attended)
  turn_main_only_at_second_offer "$home" snapshot
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "turns-main-only: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until_deadline 60 host_exited "$home" || fail "turns-main-only: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_grep 'which export format?' "$home/state/demo.status" "fixture: the decision was not recorded before the turn"
  expect_code 0 "$(cat "$home/host.rc")" "the close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "turns-main-only: the engine ran on a stale offer"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the wake must stay queued for main"
  assert_grep 'which export format?' "$home/pi-offer-state/demo.status" "fixture: the Pi snapshot must contain the new decision"
  assert_no_re 'needs-decision:' "$home/pi-offer-state/.wake-queue" "fixture: the Pi snapshot must contain only the accepted wake"
  local pi_offer
  pi_offer=$(node --input-type=module -e '
    const dispatch = await import(process.argv[1]);
    console.log(dispatch.branchOfferForWake(process.argv[2], process.argv[3], false).eligible);
  ' "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$home/pi-offer-state" "signal: $home/state/demo.status")
  [ "$pi_offer" = true ] || fail "the host-only transition veto changed Pi's existing offer rule"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  watcher_live "$home" || fail "the pass-through left no successor watcher"
  pass "host: an attended close whose task turns main-only before its turn still reaches main unchanged"
}


# Grok and OpenCode have no mirror writer, because they cannot record a
# session's first captain prompt, and neither Codex nor omp has a proven one,
# so none of them has a verified dialog mirror: every attended close reaches
# main as without the host, while the away posture, which needs no mirror,
# still runs on the engine.

test_primary_without_a_verified_mirror_runs_away_only() {
  local home harness
  for harness in grok opencode omp codex; do
    home=$(make_home "attended-$harness" attended claude)
    FM_SUPERVISION_HOST_PRIMARY=$harness start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$harness: the host never started a watcher cycle"
    append_status "$home" 'fixture finished' 'done'
    wait_until_deadline 60 host_exited "$home" || fail "$harness: the host did not hand the attended close to main"
    assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
    assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
    [ "$(engine_calls "$home")" -eq 0 ] || fail "$harness: the engine ran an attended wake without a verified dialog mirror"
    assert_re "	pass-through	attended	no verified dialog mirror for $harness	" "$home/state/.supervision-host.log" \
      "the ledger must record that no verified mirror kept the close on main"
  done
  home=$(make_home away-grok away claude)
  FM_SUPERVISION_HOST_PRIMARY=grok start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away grok: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "away grok: the wake was not handled on the engine: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  assert_re '^primary=grok$' "$home/engine-call.1" "the away engine must carry the grok primary pin"
  assert_re '^POSTURE: AWAY\.' "$home/engine-call.1" "the away wake must carry the away tail"
  [ ! -s "$home/host.rc" ] || fail "a handled away wake on grok reached main: $(cat "$home/host.out")"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until_deadline 60 host_exited "$home" || fail "away grok: the host did not stop on TERM"
  pass "host: a primary with no verified dialog mirror keeps every attended close on main, and its away posture still runs"
}

test_attended_wake_carries_the_dialog_mirror() {
  local home first second
  home=$(make_home attended-mirror attended)
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  printf '{"hook_event_name":"Stop","prompt_id":"p1","last_assistant_message":"Understood, low effort it is."}' > "$home/mirror-seed.2"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p2","prompt":"\342\201\243FIRSTMATE_OP: v1 watcher: signal: demo.status"}' > "$home/mirror-seed.3"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "mirror: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "mirror: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re '^arg=MAIN DIALOG MIRROR \(read-only context' "$first" "the wake must open with the dialog mirror"
  assert_re '^\[captain\] keep the export worker on low effort$' "$first" "the mirror must carry the captain's words"
  assert_re '^\[main\] Understood, low effort it is\.$' "$first" "the mirror must carry main's reply"
  assert_no_re 'FIRSTMATE_OP' "$first" "operational input must never be mirrored as dialog"
  append_status "$home" 'step two'
  wait_until 250 handled_at_least "$home" 2 || fail "mirror: the second wake was not handled"
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "fixture: the second turn did not resume the conversation"
  assert_no_re 'MAIN DIALOG MIRROR' "$second" "a resumed conversation must not be fed dialog it already has"
  pass "host: each wake carries the captain's dialog since the last wake, without operational input"
}


# Every file carrying the captain's dialog is owner-only, even under an open
# umask and when a readable copy was already there. The feed is removed before
# the engine starts, so a node wrapper records its mode as the wake renders.

test_dialog_bearing_files_are_owner_only() {
  local home old
  home=$(make_home attended-private attended)
  {
    printf '#!/usr/bin/env bash\nREAL_NODE=%q\n' "$(command -v node)"
    cat <<'SH'
prev=
for a in "$@"; do
  [ "$prev" != --mirror-file ] || { stat -c %a "$a" 2>/dev/null || stat -f %Lp "$a"; } >> "$FM_HOME/feed-modes"
  prev=$a
done
exec "$REAL_NODE" "$@"
SH
  } > "$home/fakebin/node"
  chmod +x "$home/fakebin/node"
  old=$(umask)
  umask 022
  for f in .host-mirror.jsonl .supervision-host-mirror .supervision-host-wake; do
    : > "$home/state/$f"
    chmod 644 "$home/state/$f"
  done
  start_host "$home"
  umask "$old"
  wait_until 150 watcher_live "$home" || fail "private: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "private: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  assert_re '^\[captain\] watch the fleet for me$' "$home/engine-call.1" "fixture: the wake must carry the captain's words"
  [ "$(mode_of "$home/state/.host-mirror.jsonl")" = 600 ] || fail "the dialog mirror must be owner-only, got $(mode_of "$home/state/.host-mirror.jsonl")"
  [ "$(mode_of "$home/state/.supervision-host-wake")" = 600 ] || fail "the wake file must be owner-only, got $(mode_of "$home/state/.supervision-host-wake")"
  [ "$(cat "$home/feed-modes" 2>/dev/null)" = 600 ] || fail "the mirror feed must be owner-only, got $(cat "$home/feed-modes" 2>/dev/null)"
  pass "host: the dialog mirror, its feed, and the wake file are owner-only"
}


# Dialog counts as delivered only once the turn that carried it is accepted
# with its report. A host that reaches its park boundary after feeding the
# mirror but before the turn, or is stopped mid-turn, leaves the conversation
# resumable without it, so the next turn must still carry it; a turn with no
# report starts a new conversation, which must carry it too.

# Opt-in scalar evidence for this fixture only. Never copy dialog, prompts,
# config, environment, command lines, or raw logs into the hosted artifact.
# At most four restarts plus cleanup; no sampler or additional wait is needed.
dialog_restart_diagnostic_snapshot() {  # <private home> <stage>
  local home=$1 stage=$2 root=${FM_TEST_HOST_DIALOG_DIAGNOSTIC_DIR:-} file pid
  [ -n "$root" ] || return 0
  [ "$root" = "${RUNNER_TEMP:-/absent}/fm-test/host-dialog-restart" ] \
    || fail "dialog-restart diagnostic destination is not the runner's private artifact directory"
  [ "$home" = "$TMP_ROOT/mirror-boundary" ] \
    || fail "dialog-restart diagnostic home is not this case's private fixture"
  mkdir -p "$root" || return 1
  {
    printf 'epoch=%s restart=%s stage=%s\n' "$(date +%s)" "${DIALOG_RESTART_DIAGNOSTIC_STEP:-0}" "$stage"
    for file in park.go host.rc host.out state/.watcher-down state/.watcher-down.lock \
      state/.watch.lock state/.wake-queue state/.wake-queue.lock state/.supervision-host state/.supervision-host-left \
      state/.supervision-host-turn state/.supervision-host.engine-pid; do
      if [ -e "$home/$file" ]; then printf '%s present=1\n' "$file"; else printf '%s present=0\n' "$file"; fi
    done
    for file in host.rc park-clock; do
      [ ! -f "$home/$file" ] || awk -v key="$file" '/^[0-9]+$/ { print key "=" $0 }' "$home/$file"
    done
    [ ! -f "$home/state/.watcher-down" ] || awk -F : '
      ($1 == "pending" || $1 == "announced" || $1 == "acked") && ($2 == "handling" || $2 == "downtime") {
        print "downtime_state=" $1; print "downtime_kind=" $2
      }
    ' "$home/state/.watcher-down"
    [ ! -f "$home/state/.wake-queue" ] || awk 'END { print "queue_rows=" NR }' "$home/state/.wake-queue"
    printf 'engine_calls=%s\n' "$(engine_calls "$home")"
    if grep -q '^check: rearm-resurface' "$home/host.out" 2>/dev/null; then
      printf 'resurface_result=1\n'
    else
      printf 'resurface_result=0\n'
    fi
    [ ! -f "$home/state/.supervision-host" ] || awk -F '\t' '
      ($1 == "host" || $1 == "arm") && $2 ~ /^[0-9]+$/ { print $1 "_pid=" $2 }
    ' "$home/state/.supervision-host"
    for file in state/.watch.lock/pid state/.supervision-host.engine-pid state/.supervision-host-left; do
      [ ! -f "$home/$file" ] || awk -F '\t' -v key="$file" '$1 ~ /^[0-9]+$/ { print key "=" $1 }' "$home/$file"
    done
    # Only exact PIDs recorded by this synthetic home, never a fleet scan.
    {
      [ ! -f "$home/claude-pids" ] || awk '/^[0-9]+$/ { print }' "$home/claude-pids"
      [ ! -f "$home/state/.supervision-host" ] || awk -F '\t' '
        ($1 == "host" || $1 == "arm") && $2 ~ /^[0-9]+$/ { print $2 }
      ' "$home/state/.supervision-host"
      for file in state/.watch.lock/pid state/.supervision-host.engine-pid state/.supervision-host-left \
        state/.watcher-down.lock/pid state/.wake-queue.lock/pid; do
        [ ! -f "$home/$file" ] || awk -F '\t' '$1 ~ /^[0-9]+$/ { print $1 }' "$home/$file"
      done
    } | sort -u | while IFS= read -r pid; do
      printf 'owned_pid=%s\n' "$pid"
      ps -p "$pid" -o pid=,ppid=,pgid=,etime=,state= 2>/dev/null || true
    done
  } > "$root/restart-${DIALOG_RESTART_DIAGNOSTIC_STEP:-0}-$stage.txt"
}

park_after_stop() {  # <home>
  DIALOG_RESTART_DIAGNOSTIC_STEP=$(( ${DIALOG_RESTART_DIAGNOSTIC_STEP:-0} + 1 ))
  dialog_restart_diagnostic_snapshot "$1" before-restart
  # Provide intentional main work so even an otherwise empty recovery still
  # hands back for this fixture's explicit drain and next park.
  routine_wake_lib "$1" fm_wake_append check fixture-restart 'check: fixture restart' || fail "could not queue the restart check"
  rm -f "$1/host.rc"
  : > "$1/park.go"
  wait_until 150 host_exited "$1" || {
    dialog_restart_diagnostic_snapshot "$1" wait-failed
    fail "the watcher's downtime resurface did not reach main: $(cat "$1/host.out")"
  }
  dialog_restart_diagnostic_snapshot "$1" wait-completed
  assert_re '^check: rearm-resurface' "$1/host.out" "fixture: the first close after the watcher stopped was not its resurface"
  main_drain_and_ack "$1"
  quiet_pass_through_successor "$1"
  park_again "$1"
  dialog_restart_diagnostic_snapshot "$1" next-park-ready
}

test_undelivered_dialog_is_fed_again_on_the_next_turn() {
  local home real_node second third fourth
  home=$(make_home mirror-boundary attended)
  DIALOG_RESTART_DIAGNOSTIC_HOME=$home
  real_node=$(command -v node)
  cat > "$home/fakebin/node" <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = wake-prompt ] && [ -e "\$FM_HOME/slow-render" ]; then echo 120 > "\$FM_HOME/park-clock"; fi
exec "$real_node" "\$@"
SH
  chmod +x "$home/fakebin/node"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"first ask"}' > "$home/mirror-seed.1"
  echo 0 > "$home/park-clock"
  # The park bound sits past every wall-clock check below, so a host that
  # ignored the test clock could never reach a boundary inside this case.
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=120 FM_SUPERVISION_HOST_TURN_TIMEOUT=20 FM_SUPERVISION_ENGINE_GRACE=1 start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  wait_until 250 handled_at_least "$home" 1 || fail "mirror boundary: the first wake was not handled: $(cat "$home/state/.supervision-host.log")"
  assert_re '^\[captain\] first ask$' "$home/engine-call.1" "fixture: the first turn did not carry the first dialog"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until_deadline 60 host_exited "$home" || fail "mirror boundary: the first host did not stop on TERM"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p2","prompt":"second ask, never handed over"}' > "$home/mirror-seed.2"
  : > "$home/slow-render"
  echo 0 > "$home/park-clock"
  park_after_stop "$home"
  append_status "$home" 'reaches the boundary'
  wait_until 400 host_exited "$home" || fail "mirror boundary: the host did not end its park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "fixture: the second host did not exit at its boundary"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "fixture: an engine turn ran at the boundary"
  main_drain_and_ack "$home"

  rm -f "$home/slow-render"
  echo 0 > "$home/park-clock"
  park_again "$home"
  append_status "$home" 'handled after the boundary'
  wait_until 250 handled_at_least "$home" 2 || fail "mirror boundary: the next wake was not handled: $(cat "$home/state/.supervision-host.log")"
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "fixture: the next turn did not resume the conversation"
  assert_re '^\[captain\] second ask, never handed over$' "$second" \
    "dialog fed to a wake that never reached the engine must reach the next turn"
  assert_no_re '^\[captain\] first ask$' "$second" "a resumed conversation must not be fed dialog it already has"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p3","prompt":"third ask, turn stopped"}' > "$home/mirror-seed.3"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until_deadline 60 host_exited "$home" || fail "mirror boundary: the second handling host did not stop on TERM"
  echo hang > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'stopped mid-turn'
  wait_until 250 test -e "$home/engine-call.3" || fail "mirror boundary: the stopped turn never started"
  assert_re '^\[captain\] third ask, turn stopped$' "$home/engine-call.3" "fixture: the stopped turn did not carry the third dialog"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until_deadline 60 host_exited "$home" || fail "mirror boundary: the host did not stop mid-turn on TERM"
  echo handle > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'handled after the stop'
  wait_until 250 handled_at_least "$home" 3 || fail "mirror boundary: the wake after the stop was not handled: $(cat "$home/state/.supervision-host.log")"
  third="$home/engine-call.4"
  assert_re '^arg=--resume$' "$third" "fixture: the turn after the stop did not resume the conversation"
  assert_re '^\[captain\] third ask, turn stopped$' "$third" "dialog of a turn stopped before its report must reach the next turn"
  assert_no_re '^\[captain\] second ask' "$third" "a resumed conversation must not be fed dialog a handled turn delivered"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p4","prompt":"fourth ask, turn unreported"}' > "$home/mirror-seed.4"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until_deadline 60 host_exited "$home" || fail "mirror boundary: the third handling host did not stop on TERM"
  echo noreport > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'no report'
  wait_until_deadline 60 host_exited "$home" || fail "mirror boundary: the unreported turn did not hand its wake back"
  assert_re '^\[captain\] fourth ask, turn unreported$' "$home/engine-call.5" "fixture: the unreported turn did not carry the fourth dialog"
  main_drain_and_ack "$home"
  echo handle > "$home/stub-mode"
  park_again "$home"
  append_status "$home" 'handled after no report'
  wait_until 250 handled_at_least "$home" 4 || fail "mirror boundary: the wake after the unreported turn was not handled: $(cat "$home/state/.supervision-host.log")"
  fourth="$home/engine-call.6"
  assert_re '^\[captain\] fourth ask, turn unreported$' "$fourth" "dialog of a turn that recorded no report must reach the next turn"
  pass "host: dialog a turn never completed with its report (a park boundary, a stopped turn, no report) reaches the next turn"
}


# The attended engine never judges without the captain's words: a mirror that
# is missing, cannot be read, or holds an entry that does not parse hands the
# wake to main before any engine turn and leaves the mirror cursor where it was.

test_attended_wake_with_an_unreadable_mirror_reaches_main() {
  local home mirror cursor
  home=$(make_home attended-bad-mirror attended)
  mirror="$home/state/.host-mirror.jsonl"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  wait_until 250 handled_at_least "$home" 1 || fail "bad mirror: the first wake was not handled: $(cat "$home/state/.supervision-host.log")"
  cursor=$(cat "$home/state/.host-mirror-cursor") || fail "fixture: the handled turn committed no mirror cursor"

  rm -f "$mirror"
  append_status "$home" 'missing mirror'
  wait_until_deadline 60 host_exited "$home" || fail "bad mirror: a missing mirror did not hand the wake to main"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the watcher's reason line"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a missing mirror must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without a mirror"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a missing mirror moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "a missing mirror staged a cursor"
  main_drain_and_ack "$home"

  park_again "$home"
  [ -f "$mirror" ] || fail "fixture: the next park did not write the mirror again"
  chmod 000 "$mirror"
  append_status "$home" 'unreadable mirror'
  wait_until_deadline 60 host_exited "$home" || fail "bad mirror: an unreadable mirror did not hand the wake to main"
  chmod 644 "$mirror"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the watcher's reason line"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "an unreadable mirror must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without a readable mirror"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "an unreadable mirror moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "an unreadable mirror staged a cursor"
  main_drain_and_ack "$home"

  printf '#!/usr/bin/env bash\nprev=\nfor a in "$@"; do [ "$prev" != --mirror-file ] || chmod 000 "$a"; prev=$a; done\nexec %q "$@"\n' \
    "$(command -v node)" > "$home/fakebin/node"
  chmod +x "$home/fakebin/node"
  park_again "$home"
  append_status "$home" 'mirror lost before the prompt'
  wait_until_deadline 60 host_exited "$home" || fail "bad mirror: a feed lost before the prompt did not hand the wake to main"
  rm -f "$home/fakebin/node"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a feed lost before the prompt must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without the feed it was promised"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a feed lost before the prompt moved the cursor"
  main_drain_and_ack "$home"

  printf '{"seq":' >> "$mirror"
  printf '\n' >> "$mirror"
  park_again "$home"
  append_status "$home" 'malformed mirror'
  wait_until_deadline 60 host_exited "$home" || fail "bad mirror: a malformed mirror entry did not hand the wake to main"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a malformed mirror entry must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran past a malformed mirror entry"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a malformed mirror entry moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "a malformed mirror entry staged a cursor past it"
  pass "host: an attended wake whose mirror is missing, cannot be read (at the feed or at the prompt), or holds a malformed entry reaches main before any engine turn, and the cursor stays put"
}

test_away_wake_is_handled_on_the_engine_and_never_reaches_main() {
  local home lock_pid session first second pid watcher
  home=$(make_home away-handled away)
  echo hold-lease > "$home/stub-mode"
  # Dialog in the mirror that an away wake must neither carry nor mark read.
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "away: the wake was not handled: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  lock_pid=$(cat "$home/state/.lock")

  first="$home/engine-call.1"
  assert_re '^actor=branch$' "$first" "the engine must run as the branch actor"
  assert_re "^holder=$lock_pid\$" "$first" "the engine's lease holder must be the session-lock holder"
  assert_re '^primary=claude$' "$first" "the engine must carry the primary-harness pin"
  assert_re '^turn=host-' "$first" "the engine must carry its report turn"
  assert_re '^arg=--safe-mode$' "$first" "the engine must load none of the home's hooks"
  assert_re '^arg=dontAsk$' "$first" "the engine must never prompt"
  assert_re '^arg=sonnet$' "$first" "the engine must default to its default model"
  assert_re '^arg=--session-id$' "$first" "the first turn must open a new conversation"
  assert_re '^POSTURE: AWAY\.' "$first" "the wake must carry the away tail"
  assert_grep 'keep the export worker on low effort' "$home/state/.host-mirror.jsonl" "fixture: the captain's dialog was not mirrored"
  assert_no_re 'MAIN DIALOG MIRROR|low effort' "$first" "an away wake must carry no dialog mirror"
  assert_absent "$home/state/.host-mirror-cursor" "a handled away wake must leave the mirror cursor where it was"
  assert_absent "$home/state/.host-mirror-cursor.next" "an away wake must stage no mirror cursor"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "the engine's report did not reach the outcome store"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the engine's acknowledgement did not consume the wake"
  if FM_HOME="$home" "$LEASE" check demo >/dev/null 2>&1; then
    fail "the host did not release the lease the engine left held: $(FM_HOME="$home" "$LEASE" check demo)"
  fi
  [ ! -s "$home/host.rc" ] || fail "a handled away wake reached main: $(cat "$home/host.out")"
  [ "$(grep -cv '^watcher: started pid=' "$home/host.out")" -eq 0 ] \
    || fail "a handled away wake printed more than the first cycle's status to main: $(cat "$home/host.out")"
  watcher_live "$home" || fail "the host is not parked on a live successor cycle"

  echo handle > "$home/stub-mode"
  append_status "$home" 'step two'
  wait_until 250 handled_at_least "$home" 2 || fail "away: the second wake was not handled"
  session=$(sed -n '/^arg=--session-id$/{n;s/^arg=//p;}' "$first")
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "a later turn must resume the conversation"
  assert_re "^arg=$session\$" "$second" "a later turn must resume the same conversation"
  [ "$(grep -c '"task":"demo"' "$home/state/branch-outcomes.jsonl")" -eq 2 ] || fail "the second outcome was not recorded"
  assert_re '	handled	turn=[^	]*\.2	.* cost=0\.25 conversation_cost=0\.5 ' "$home/state/.supervision-host.log" \
    "a resumed turn must log its own cost, not the conversation's running total"

  pid=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -TERM "$pid"
  wait_until_deadline 60 host_exited "$home" || fail "the host did not stop on TERM"
  expect_code 143 "$(cat "$home/host.rc")" "a TERMed host must exit 143"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" || fail "a stopped host left its watcher running"
  assert_absent "$home/state/.supervision-host" "a stopped host left its record"
  pass "host: an away wake is handled on the engine through the branch contract and never reaches main"
}

test_away_turn_without_a_report_hands_the_wake_to_main() {
  local home token
  home=$(make_home away-noreport away)
  echo noreport > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "noreport: the host never started a watcher cycle"
  append_status "$home" 'needs a look'
  wait_until_deadline 60 host_exited "$home" || fail "noreport: the host did not hand the wake to main"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*recorded no outcome for its wake; this wake is yours$' "$home/host.out" "the handback must say why"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unhandled wake must stay durable for main"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the wake to main"
  token=$(cat "$home/state/.watcher-down")
  case "$token" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "a handback must leave the recovery marker in downtime for the owner's rewake, got: $token" ;;
  esac
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  pass "host: an engine turn that records no outcome hands its durable wake to main"
}

test_return_during_an_engine_turn_hands_its_outcomes_to_main() {
  local home
  home=$(make_home away-return away)
  echo return > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return: the host never started a watcher cycle"
  append_status "$home" 'mid-task'
  wait_until_deadline 60 host_exited "$home" || fail "return: the host did not hand the late outcome to main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a late-outcome handoff must exit 0 for the owner to deliver"
  assert_absent "$home/state/.afk-contract" "fixture: the stub's return did not archive the record"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handoff must carry the close"
  assert_re '^supervision-host: the captain returned while the away session was handling this wake.*store rows 1[,)]' "$home/host.out" \
    "the handoff must say the captain returned mid-turn and name the store rows"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "the handoff must carry the turn's outcome for main to relay"
  assert_re '	handled	turn=' "$home/state/.supervision-host.log" "the turn itself was handled"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the handled wake must stay acknowledged"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the outcome to main"
  pass "host: a captain return during an engine turn hands that turn's outcomes to main"
}


# Silent outcomes stay stored, but neither captain-return path names or relays
# them when the host decides whether to hand the wake to main.

test_silent_outcomes_are_not_relayed_when_the_captain_returns() {
  local mode home host
  for mode in return-silent return-fail-silent; do
    home=$(make_home "away-$mode" away)
    echo "$mode" > "$home/stub-mode"
    start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$mode: the host never started a watcher cycle"
    append_status "$home" 'no-change result during a captain return'

    if [ "$mode" = return-silent ]; then
      wait_until 250 handled_at_least "$home" 1 || fail "$mode: the wake was not handled: host=$(cat "$home/host.out" 2>/dev/null) log=$(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null) report=$(cat "$home/engine-report.log" 2>/dev/null)"
      [ ! -s "$home/host.rc" ] || fail "$mode: a silent-only outcome forced a captain handoff: $(cat "$home/host.out")"
      watcher_live "$home" || fail "$mode: the host did not park on its successor"
      host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
      kill -TERM "$host"
      wait_until_deadline 60 host_exited "$home" || fail "$mode: the host did not stop on TERM"
    else
      wait_until_deadline 60 host_exited "$home" || fail "$mode: the failed turn did not hand the wake to main: $(cat "$home/host.out" 2>/dev/null) $(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null)"
      assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
        "$home/host.out" "$mode: the failed turn must still hand its wake to main"
    fi
    assert_no_re 'captain returned|store rows|^supervision-host: outcome ' "$home/host.out" \
      "$mode: a silent outcome was referenced in the captain-return handoff"
    assert_grep '"silent":true' "$home/state/branch-outcomes.jsonl" "$mode: the silent outcome was not retained in the store"
    assert_absent "$home/state/.afk-contract" "$mode: the captain return was not archived"
  done
  pass "host: silent outcomes are excluded from both captain-return handoff paths"
}

test_large_turn_relays_an_early_visible_outcome() {
  local home count
  home=$(make_home away-many-receipts away)
  echo return-many > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "many receipts: the host never started a watcher cycle"
  append_status "$home" 'large turn with a visible first outcome'
  wait_until_deadline 60 host_exited "$home" || fail "many receipts: the captain-return handoff did not finish: host=$(cat "$home/host.out" 2>/dev/null) log=$(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null) report=$(tail -n 5 "$home/engine-report.log" 2>/dev/null) rows=$(wc -l < "$home/state/branch-outcomes.jsonl" 2>/dev/null)"
  count=$(grep -c '^supervision-host: outcome ' "$home/host.out")
  [ "$count" -eq 1 ] || fail "many receipts: expected one visible outcome, got $count: $(tail -n 5 "$home/host.out")"
  [ "$(wc -l < "$home/state/branch-outcomes.jsonl" | tr -d ' ')" -eq 1001 ] \
    || fail "many receipts: the fixture did not exceed the old 1,000-row window: rows=$(wc -l < "$home/state/branch-outcomes.jsonl") host=$(cat "$home/host.out") report=$(cat "$home/engine-report.log") tail=$(tail -c 300 "$home/state/branch-outcomes.jsonl")"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "many receipts: the early visible outcome was lost behind later silent rows"
  assert_no_grep 'bulk silent fixture' "$home/host.out" "many receipts: silent outcomes were relayed"
  pass "host: an early visible outcome survives more than 1,000 same-turn receipts"
}

test_outcome_lookup_failure_is_not_treated_as_silence() {
  local home
  home=$(make_home away-lookup-failure away)
  echo return-lookup-fail > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "lookup failure: the host never started a watcher cycle"
  append_status "$home" 'outcome lookup failure after a captain return'
  wait_until_deadline 60 host_exited "$home" || fail "lookup failure: the host treated an unreadable store as a silent outcome"
  assert_re '^supervision-host: the captain returned while the away session was handling this wake, but the recorded outcomes could not be verified; main must review them$' \
    "$home/host.out" "lookup failure: the main handoff did not explain the lookup failure"
  assert_re '^supervision-host: outcome lookup failed for turn receipt rows 1; visible outcomes may require manual review$' \
    "$home/host.out" "lookup failure: the missing outcome warning was not emitted"
  pass "host: an outcome lookup failure forces a visible main handoff"
}


# The live failure this guards: a Cursor park superseded by the captain's
# return kills its host as the engine turn ends, so the host's own handoff is
# never printed. The outcome still reaches main: the next host's first cycle
# resurfaces the durable queue and main's drain presents it.

test_outcome_after_the_return_survives_a_host_killed_at_the_turn_end() {
  local home host rc drained
  home=$(make_home away-return-first away)
  echo return-first > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return-first: the host never started a watcher cycle"
  append_status "$home" 'finishing while the captain comes back'
  wait_until 250 grep -qs 'supervision-host-return:1' "$home/state/.wake-queue" \
    || fail "return-first: the late outcome was never queued: $(cat "$home/engine-report.log" 2>/dev/null)"
  host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  kill -TERM "$host"
  wait_until_deadline 60 host_exited "$home" || fail "return-first: the stopped host did not exit"
  rc=$(cat "$home/host.rc")
  [ "$rc" -gt 128 ] || fail "fixture: the host was not stopped mid-turn (rc=$rc): $(cat "$home/host.out")"
  assert_no_re '^supervision-host: ' "$home/host.out" "fixture: the stopped host printed a handoff, so this case proves nothing"
  for f in "$home"/state/.supervision-host-result.* "$home"/state/.supervision-host-errors.*; do
    [ -e "$f" ] && fail "a host stopped mid-turn left its turn file behind: $f"
  done
  assert_grep 'supervision-host-return:1' "$home/state/.wake-queue" "the late outcome must stay queued after its host died"

  rm -f "$home/host.rc"
  start_host "$home"
  wait_until_deadline 60 host_exited "$home" || fail "return-first: the next host did not resurface the queued outcome"
  assert_re '^check: rearm-resurface$' "$home/host.out" "the next host's first cycle must resurface the queue"
  assert_re '	pass-through	attended	main-only	check: rearm-resurface' "$home/state/.supervision-host.log" "the attended resurface must reach main"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  assert_contains "$drained" "supervision-host outcome 1 for demo [routine] was recorded after the captain returned" \
    "main's drain must present the outcome the killed host never handed off"
  pass "host: an outcome recorded after the return reaches main even when its host dies at the turn's end"
}


# A host killed outright mid-turn leaves turn files, but the bounded engine's
# watchdog stops the engine when its owner dies. The next host clears the files.

test_next_host_clears_a_turn_its_killed_predecessor_left() {
  local home host engine
  home=$(make_home away-killed-mid-turn away)
  echo return-first > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "killed: the host never started a watcher cycle"
  append_status "$home" 'mid-turn when its host is killed'
  wait_until 250 grep -qs 'supervision-host-return:1' "$home/state/.wake-queue" || fail "killed: the turn never reported"
  host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  engine=$(cut -f1 "$home/state/.supervision-host.engine-pid")
  kill -KILL "$host"
  wait_until 100 host_exited "$home" || fail "killed: the host did not die"
  ls "$home"/state/.supervision-host-result.* >/dev/null 2>&1 || fail "fixture: the killed turn left no result file, so this case proves nothing"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$engine" || fail "the bounded engine survived its killed host"

  rm -f "$home/host.rc"
  start_host "$home"
  wait_until_deadline 60 host_exited "$home" || fail "killed: the next host did not resurface the queued outcome"
  ! kill -0 "$engine" 2>/dev/null || fail "the next host revived its killed predecessor's engine"
  for f in "$home"/state/.supervision-host-result.* "$home"/state/.supervision-host-errors.* \
    "$home"/state/.supervision-host-descendants.* "$home/state/.supervision-host-turn"; do
    [ -e "$f" ] && fail "the next host left its killed predecessor's turn file behind: $f"
  done
  assert_re '^check: rearm-resurface$' "$home/host.out" "the next host's first cycle must resurface the queue"
  pass "host: a killed predecessor's engine is reaped and the next host removes its turn files"
}

test_report_without_acknowledgement_hands_the_wake_to_main() {
  local home
  home=$(make_home away-noack away)
  echo noack > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "noack: the host never started a watcher cycle"
  append_status "$home" 'reported, never acknowledged'
  wait_until_deadline 60 host_exited "$home" || fail "noack: the host counted an unacknowledged wake handled: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*the engine turn left its granted wake rows [0-9]+( [0-9]+)* unacknowledged; this wake is yours$' "$home/host.out" \
    "the handback must name the rows the turn left unacknowledged"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unacknowledged wake must stay durable for main"
  assert_re '	failed	turn=.*	unacked=[0-9]' "$home/state/.supervision-host.log" "the ledger must record the turn as failed"
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the wake to main"
  pass "host: a turn that reports but leaves its granted rows queued hands the wake to main"
}

return_fail_diagnostic_snapshot() {  # <private home> <stage>
  local home=$1 stage=$2 root=${FM_TEST_HOST_RETURN_DIAGNOSTIC_DIR:-} out file pid
  [ -n "$root" ] || return 0
  [ "$root" = "${RUNNER_TEMP:-/absent}/fm-test/host-return-fail" ] \
    || fail "return-fail diagnostic destination is not the runner's private artifact directory"
  case "$home" in "$TMP_ROOT"/away-return-fail) ;; *) fail "return-fail diagnostic home is not this case's private fixture" ;; esac
  out="$root/$stage"
  mkdir -p "$out/state" || return 1
  printf 'epoch=%s suite_pid=%s stage=%s\n' "$(date +%s)" "$$" "$stage" > "$out/observation.txt"
  for file in host.out host.rc claude.err claude-pids engine-return.log engine-report.log engine-ack.log engine-lease.log \
    state/.supervision-host state/.supervision-host.log state/.supervision-host.engine-pid \
    state/.supervision-host-turn state/.wake-queue state/.watcher-down state/.watch.lock/pid; do
    if [ -f "$home/$file" ]; then
      mkdir -p "$out/$(dirname "$file")"
      cp "$home/$file" "$out/$file" 2>/dev/null || true
    else
      printf 'absent %s\n' "$file" >> "$out/observation.txt"
    fi
  done
  {
    [ ! -f "$home/claude-pids" ] || awk '/^[0-9]+$/ { print }' "$home/claude-pids"
    [ ! -f "$home/state/.supervision-host" ] \
      || awk -F '\t' '$1 == "host" || $1 == "arm" { if ($2 ~ /^[0-9]+$/) print $2 }' "$home/state/.supervision-host"
    [ ! -f "$home/state/.supervision-host.engine-pid" ] \
      || awk -F '\t' '$1 ~ /^[0-9]+$/ { print $1 }' "$home/state/.supervision-host.engine-pid"
    [ ! -f "$home/state/.watch.lock/pid" ] || awk '/^[0-9]+$/ { print }' "$home/state/.watch.lock/pid"
  } | sort -u > "$out/owned-pids.txt"
  while IFS= read -r pid; do
    ps -p "$pid" -o pid=,ppid=,pgid=,etime=,state=,args= >> "$out/owned-processes.txt" 2>/dev/null || true
  done < "$out/owned-pids.txt"
}

return_fail_diagnostic_stop() {
  local current
  [ -n "${RETURN_FAIL_DIAGNOSTIC_PID:-}" ] || return 0
  current=$(fm_test_pid_identity "$RETURN_FAIL_DIAGNOSTIC_PID" 2>/dev/null || true)
  if [ -n "${RETURN_FAIL_DIAGNOSTIC_IDENTITY:-}" ] && [ "$current" = "$RETURN_FAIL_DIAGNOSTIC_IDENTITY" ]; then
    kill -TERM "$RETURN_FAIL_DIAGNOSTIC_PID" 2>/dev/null || true
  fi
  wait "$RETURN_FAIL_DIAGNOSTIC_PID" 2>/dev/null || true
  RETURN_FAIL_DIAGNOSTIC_PID=
}

return_fail_diagnostic_start() {  # <private home>
  [ -n "${FM_TEST_HOST_RETURN_DIAGNOSTIC_DIR:-}" ] || return 0
  RETURN_FAIL_DIAGNOSTIC_HOME=$1
  return_fail_diagnostic_snapshot "$1" watcher-ready || return 1
  (
    local sample=0
    while [ "$sample" -lt 40 ] && kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null; do
      return_fail_diagnostic_snapshot "$1" "sample-$sample" || exit 1
      sample=$((sample + 1))
      sleep 1
    done
  ) &
  RETURN_FAIL_DIAGNOSTIC_PID=$!
  RETURN_FAIL_DIAGNOSTIC_IDENTITY=$(fm_test_pid_identity "$RETURN_FAIL_DIAGNOSTIC_PID") || return 1
}

test_return_during_a_failed_turn_still_hands_its_outcomes_to_main() {
  local home
  home=$(make_home away-return-fail away)
  echo return-fail > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return-fail: the host never started a watcher cycle"
  return_fail_diagnostic_start "$home" || fail "return-fail: could not start private diagnostic capture"
  append_status "$home" 'mid-task, then a crash'
  wait_until_deadline 60 host_exited "$home" || {
    return_fail_diagnostic_snapshot "$home" wait-failed
    fail "return-fail: the host did not hand the wake to main"
  }
  return_fail_diagnostic_stop
  return_fail_diagnostic_snapshot "$home" wait-completed
  expect_code 0 "$(cat "$home/host.rc")" "a failed turn's handback must exit 0 for the owner to deliver"
  assert_absent "$home/state/.afk-contract" "fixture: the stub's return did not archive the record"
  assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); .*captain returned during its turn.*store rows 1[,)]' "$home/host.out" \
    "the handback must say the turn failed, that the captain returned, and name the store rows"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "the handback must carry the failed turn's outcome for main to relay"
  assert_re '	failed	turn=' "$home/state/.supervision-host.log" "the turn itself failed"
  pass "host: a captain return during a failed engine turn still hands that turn's outcomes to main"
}

test_incomplete_engine_result_hands_the_wake_to_main() {
  local home
  home=$(make_home away-emptyresult away)
  echo emptyresult > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "emptyresult: the host never started a watcher cycle"
  append_status "$home" 'handled, but the result is empty'
  wait_until_deadline 60 host_exited "$home" || fail "emptyresult: the host counted an empty result handled: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*the engine turn ended with an error or an incomplete result; this wake is yours$' "$home/host.out" \
    "the handback must say the engine's result was incomplete"
  assert_re '	failed	turn=.*	error=1 ' "$home/state/.supervision-host.log" "the ledger must record the turn as failed"
  assert_no_re '	handled	turn=' "$home/state/.supervision-host.log" "an incomplete result must never count as handled"
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  pass "host: an engine turn whose result is incomplete hands its wake to main"
}

diagnostic_suite_cleanup() {
  if [ -n "${RETURN_FAIL_DIAGNOSTIC_PID:-}" ]; then
    return_fail_diagnostic_stop
  fi
  if [ -n "${RETURN_FAIL_DIAGNOSTIC_HOME:-}" ]; then
    return_fail_diagnostic_snapshot "$RETURN_FAIL_DIAGNOSTIC_HOME" before-cleanup
  fi
  if [ -n "${DIALOG_RESTART_DIAGNOSTIC_HOME:-}" ]; then
    dialog_restart_diagnostic_snapshot "$DIALOG_RESTART_DIAGNOSTIC_HOME" before-cleanup
  fi
  suite_cleanup
}
trap diagnostic_suite_cleanup EXIT

test_owned_answer_close() { test_attended_answer_close owned; }
test_external_answer_close() { test_attended_answer_close external; }
test_mixed_answer_close() { test_attended_answer_close mixed; }
test_coalesced_late_answer_decision() { test_attended_answer_close coalesced-late; }
test_coalesced_decision_precedes_receipt_wait() { test_attended_answer_close coalesced-locked; }
test_capped_answer_close() { test_attended_answer_close capped; }
test_direct_answer_preserves_hold_divergence() { test_attended_answer_close divergence; }
test_unreadable_hold_does_not_acknowledge_answer() { test_attended_answer_close unreadable-hold; }
test_acknowledged_handback_bounds_queue_lock() { test_attended_answer_close handback-lock; }
test_late_routine_rejection_waits_for_queue_lock() { test_attended_answer_close late-rejection; }
test_operator_pending_reply_answer() { test_attended_answer_close operator; }
test_other_pending_reply_answer() { test_attended_answer_close other-reply; }
test_handled_busy_inbox_close() { test_attended_busy_inbox_close handled; }
test_handled_ship_busy_inbox_close() { test_attended_busy_inbox_close handled ship; }
test_stuck_busy_inbox_close() { test_attended_busy_inbox_close stuck; }
test_ordinary_attended_offer_can_cross_park_boundary() { test_attended_busy_inbox_close stuck-late; }
test_routine_resurface() { test_attended_resurface routine; }

test_unsafe_offer_preserves_handled_stales() {
  local home task rec reason real_node
  home=$(make_home unsafe-offer quiet)
  seed_open_captain_hold "$home" routing-call
  printf 'captain-held [key=routing-call]: tracked by routing-call\n' > "$home/state/demo.status"
  printf 'working: processing steer\n' > "$home/state/other.status"
  for task in demo other; do
    printf 'project=%s\nwindow=sess:fm-%s\nkind=secondmate\nharness=claude\n' "$task" "$task" > "$home/state/$task.meta"
    routine_wake_lib "$home" fm_wake_status_mark_current "$home/state" "$home/state/$task.status"
    rec=$(FM_HOME="$home" bash -c '. "$1"; fm_task_inbox_write "$2" "$3" steer' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state" "$task")
    mv "$rec" "${rec%/*}/handled/"
    reason="stale: sess:fm-$task (unread firstmate instruction: stuck-busy after 2 consecutive busy-deferred due doorbells; $rec stays unhandled and no doorbell was typed; inspect the worker)"
    routine_wake_lib "$home" fm_wake_append stale "sess:fm-$task" "$reason"
  done
  routine_wake_lib "$home" fm_recovery_marker_publish "$home/state/.watcher-down" downtime
  real_node=$(command -v node)
  cat > "$home/change-status.cjs" <<'JS'
const fs = require('node:fs');
const read = fs.readFileSync;
fs.readFileSync = function (path, ...args) {
  const contents = read.call(this, path, ...args);
  if (path === `${process.env.FM_HOME}/state/other.status`) {
    fs.appendFileSync(path, 'working: progressed during dispatch\n');
  }
  return contents;
};
require('node:module').syncBuiltinESMExports();
JS
  cat > "$home/fakebin/node" <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = offer ]; then
  set -o pipefail
  "$real_node" --require "\$FM_HOME/change-status.cjs" "\$@" | tee "\$FM_HOME/dispatch-offer"
  exit \$?
fi
exec "$real_node" "\$@"
SH
  chmod +x "$home/fakebin/node"
  start_host "$home"
  wait_until_deadline 60 host_exited "$home" || fail "an unsafe offer suppressed the rearm close"
  assert_re '^corrupted=1$' "$home/dispatch-offer" "fixture: the dispatch scan must detect the status change"
  assert_re '^check: rearm-resurface$' "$home/host.out" "an unsafe offer must reach main"
  for task in demo other; do
    assert_grep "stale: sess:fm-$task " "$home/state/.wake-queue" "the unsafe offer must not consume either handled stale"
  done
  stop_home_processes "$home"
  pass "host: unsafe dispatch preserves handled stales for main"
}
test_handled_scout_stale_resurface() { test_attended_resurface routine scout; }
test_handled_decision_stale() { test_attended_busy_inbox_close decision; }
test_missing_endpoint_stale_uses_ordinary_offer() { test_attended_busy_inbox_close missing; }
test_unhandled_decision_stale_uses_ordinary_offer() { test_attended_busy_inbox_close unhandled-decision; }
test_final_main_only_stale_keeps_successor() { test_attended_busy_inbox_close final-decision; }
test_final_handled_decision_keeps_successor() { test_attended_busy_inbox_close final-handled-decision; }
test_decision_after_final_offer_keeps_successor() { test_attended_busy_inbox_close final-after-offer; }
test_captain_hold_divergence_resurface() { test_attended_resurface divergence; }
test_new_decision_resurface() { test_attended_resurface new-decision; }
test_reopened_decision_resurface() { test_attended_resurface reopened-decision; }
test_presented_decision_resurface() { test_attended_resurface presented-decision; }
test_capped_decisions_resurface() { test_attended_resurface capped-decisions; }
test_status_backstop_resurface() { test_attended_resurface backstop; }
test_unread_reply_resurface() { test_attended_resurface unread-reply; }
test_operator_reply_resurface() { test_attended_resurface operator-reply; }
test_status_backstop_with_routine_rows_resurface() { test_attended_resurface routine-backstop; }
test_cooldown_resurface() { test_attended_resurface cooldown; }
test_away_transition_honors_cooldown() { test_attended_resurface away-cooldown; }

assert_routine_resurface_lock_wait() {  # <park|command>
  local home lock mode=$1 limit=10
  home=$(make_home "resurface-deadline-$mode" quiet)
  lock="$home/state/.branch-outcomes.lock"
  mkdir "$lock" || fail "fixture: could not hold the outcome lock"
  printf '%s\n' "$$" > "$lock/pid"
  routine_wake_lib "$home" fm_recovery_marker_publish "$home/state/.watcher-down" downtime || fail "fixture: no recovery episode"
  printf '0\n' > "$home/park-clock"
  if [ "$mode" = park ]; then
    printf '117\n' > "$home/park-clock"
  else
    limit=2
    install_first_offer_action "$home" ': > "$FM_HOME/unexpected-timeout-offer"'
  fi
  FM_STATUS_PRESENTATION_LOCK_TIMEOUT="$limit" FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" \
    FM_SUPERVISION_HOST_PARK_SECONDS=120 start_host "$home"
  wait_until_deadline 20 host_exited "$home" || fail "routine proof waited past the park bound for a live lock"
  if [ "$mode" = park ]; then
    assert_re '^supervision-host: cycle boundary' "$home/host.out" "the park deadline must use the normal boundary hand-back"
  else
    assert_no_re '^supervision-host: cycle boundary' "$home/host.out" "a proof timeout is not the park deadline"
    [ ! -e "$home/unexpected-timeout-offer" ] || fail "timed-out empty recovery invoked an offer"
    [ "$(engine_calls "$home")" -eq 0 ] || fail "proof timeout launched an engine turn"
  fi
  assert_re '^check: rearm-resurface$' "$home/host.out" "recovery must remain visible on hand-back"
  assert_no_re '^acked:' "$home/state/.watcher-down" "a timed-out proof must not acknowledge recovery"
  stop_home_processes "$home"
  pass "host: lock contention cannot extend the routine recovery proof past its $mode budget"
}
test_routine_resurface_respects_park_deadline() { assert_routine_resurface_lock_wait park; }
test_routine_resurface_respects_command_deadline() { assert_routine_resurface_lock_wait command; }
test_read_captain_outcome_resurface() { test_attended_resurface read-captain-outcome; }
test_empty_resurface() { test_attended_resurface empty; }
test_credential_resurface() { test_attended_resurface credential; }

test_credential_handback_waits_for_queue_lock() {
  local home lock
  home=$(make_home credential-handback quiet)
  lock="$home/state/.wake-queue.lock"
  : > "$home/config/supervision-handoff-ack"
  install_first_offer_action "$home" 'lock="$FM_HOME/state/.wake-queue.lock"
    mkdir "$lock" || exit 1
    proof="$FM_HOME/state/.branch-outcomes.lock"
    mkdir "$proof" || exit 1
    ( sleep 10; rm -f "$lock/pid" "$proof/pid"; rmdir "$lock" "$proof" ) </dev/null >/dev/null 2>&1 &
    printf "%s\n" "$!" | tee "$lock/pid" > "$proof/pid"
    sleep 6
    printf "120\n" > "$FM_HOME/park-clock"
    : > "$FM_HOME/credential-offer-complete"'
  routine_wake_lib "$home" fm_wake_append check needs-gh-auth 'check: GitHub login required' || fail "fixture: no credential row"
  routine_wake_lib "$home" fm_recovery_marker_publish "$home/state/.watcher-down" downtime || fail "fixture: no recovery episode"
  printf '116\n' > "$home/park-clock"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=120 \
    FM_STATUS_PRESENTATION_LOCK_TIMEOUT=2 start_host "$home"
  wait_until_deadline 45 host_exited "$home" || fail "credential hand-back did not finish"
  [ -f "$home/credential-offer-complete" ] || fail "the credential offer was cut short by the routine deadline"
  assert_re '^check: rearm-resurface$' "$home/host.out" "the credential recovery close was lost"
  assert_no_re 'hand-back could not be recorded' "$home/host.out" "ordinary hand-back should wait for a briefly held lock"
  assert_grep 'GitHub login required' "$home/state/.wake-queue" "the credential row must remain queued"
  assert_no_re '^supervision-host: cycle boundary' "$home/host.out" "the credential hand-back must preserve the successor"
  watcher_live "$home" || fail "the credential hand-back left no live successor"
  stop_home_processes "$home"
  pass "host: credential recovery does not lose its close under brief contention"
}
test_captain_outcome_resurface() { test_attended_resurface captain-outcome; }
test_locked_captain_outcome_resurface() { test_attended_resurface locked-captain-outcome; }

fm_test_run \
  test_park_exit_probe_uses_half_second_child_sleeps \
  test_attended_routine_wake_is_handled_on_the_engine_and_stays_off_main \
  test_ordinary_attended_offer_can_cross_park_boundary \
  test_host_stopped_right_after_a_handled_wake_exits_and_frees_the_queue \
  test_engine_in_another_time_zone_handles_its_granted_rows \
  test_attended_captain_outcome_reaches_main_through_branch_outcomes \
  test_captain_leaving_mid_turn_keeps_its_captain_outcome_for_the_return \
  test_quiet_record_without_its_daemon_is_a_present_captain \
  test_attended_main_only_close_passes_straight_to_main \
  test_attended_blocked_close_passes_straight_to_main \
  test_attended_failed_status_reaches_main \
  test_answer_receipt_is_serialized_with_classification \
  test_owned_answer_close \
  test_external_answer_close \
  test_mixed_answer_close \
  test_coalesced_late_answer_decision \
  test_coalesced_decision_precedes_receipt_wait \
  test_capped_answer_close \
  test_direct_answer_preserves_hold_divergence \
  test_unreadable_hold_does_not_acknowledge_answer \
  test_acknowledged_handback_bounds_queue_lock \
  test_late_routine_rejection_waits_for_queue_lock \
  test_operator_pending_reply_answer \
  test_other_pending_reply_answer \
  test_handled_busy_inbox_close \
  test_handled_ship_busy_inbox_close \
  test_stuck_busy_inbox_close \
  test_routine_resurface \
  test_unsafe_offer_preserves_handled_stales \
  test_handled_scout_stale_resurface \
  test_handled_decision_stale \
  test_missing_endpoint_stale_uses_ordinary_offer \
  test_unhandled_decision_stale_uses_ordinary_offer \
  test_final_main_only_stale_keeps_successor \
  test_final_handled_decision_keeps_successor \
  test_decision_after_final_offer_keeps_successor \
  test_captain_hold_divergence_resurface \
  test_new_decision_resurface \
  test_reopened_decision_resurface \
  test_presented_decision_resurface \
  test_capped_decisions_resurface \
  test_status_backstop_resurface \
  test_unread_reply_resurface \
  test_operator_reply_resurface \
  test_status_backstop_with_routine_rows_resurface \
  test_cooldown_resurface \
  test_away_transition_honors_cooldown \
  test_routine_resurface_respects_park_deadline \
  test_routine_resurface_respects_command_deadline \
  test_empty_resurface \
  test_credential_resurface \
  test_credential_handback_waits_for_queue_lock \
  test_captain_outcome_resurface \
  test_locked_captain_outcome_resurface \
  test_read_captain_outcome_resurface \
  test_off_written_while_parked_passes_the_next_attended_close_to_main \
  test_main_only_pass_through_leaves_the_successor_watcher_running \
  test_attended_close_with_unidentified_main_session_passes_to_main \
  test_close_accepted_away_that_turns_attended_passes_to_main \
  test_attended_close_that_turns_main_only_before_its_turn_passes_to_main \
  test_primary_without_a_verified_mirror_runs_away_only \
  test_attended_wake_carries_the_dialog_mirror \
  test_dialog_bearing_files_are_owner_only \
  test_undelivered_dialog_is_fed_again_on_the_next_turn \
  test_attended_wake_with_an_unreadable_mirror_reaches_main \
  test_away_wake_is_handled_on_the_engine_and_never_reaches_main \
  test_away_turn_without_a_report_hands_the_wake_to_main \
  test_return_during_an_engine_turn_hands_its_outcomes_to_main \
  test_silent_outcomes_are_not_relayed_when_the_captain_returns \
  test_large_turn_relays_an_early_visible_outcome \
  test_outcome_lookup_failure_is_not_treated_as_silence \
  test_outcome_after_the_return_survives_a_host_killed_at_the_turn_end \
  test_next_host_clears_a_turn_its_killed_predecessor_left \
  test_report_without_acknowledgement_hands_the_wake_to_main \
  test_return_during_a_failed_turn_still_hands_its_outcomes_to_main \
  test_incomplete_engine_result_hands_the_wake_to_main
