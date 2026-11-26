#!/usr/bin/env bash
# Remote secondmate updates, liveness, and recovery over fake SSH.
set -u

# shellcheck source=tests/remote-secondmate-lifecycle-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-secondmate-lifecycle-fixture.sh"
# shellcheck source=tests/herdr-client-pair-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-client-pair-fixture.sh"

printf '1..8\n'
set -e
launch_ios_route
add_local_route

# Structured fleet state comes from each home's published ledger. The remote
# host is explicit, and the local route remains alongside it.
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LOCAL_HOME" \
  "$ROOT/bin/fm-home-summary-refresh.sh" >/dev/null \
  || fail "local fixture did not publish its home ledger"
remote_env "$ROOT/bin/fm-on.sh" ios fm-home-summary-refresh.sh >/dev/null \
  || fail "remote fixture did not publish its home ledger"
SNAPSHOT=$(remote_env "$ROOT/bin/fm-fleet-snapshot.sh" --json)
if ! printf '%s' "$SNAPSHOT" | jq -e '.secondmate_current.records | any(.id == "ios" and .remote == true and .host == "remote-mac" and .provenance.selected == "structured-home")' >/dev/null; then
  printf 'secondmate projection:\n%s\n' "$(printf '%s' "$SNAPSHOT" | jq '.secondmate_current')" >&2
  fail "fleet snapshot did not select the remote structured-home projection"
fi
printf '%s' "$SNAPSHOT" | jq -e '.tasks[] | select(.id == "ios") | .paths.home.present == null and .endpoint.agent_alive == "unknown"' >/dev/null \
  || fail "the fleet snapshot performed or invented a remote endpoint-liveness probe"
printf '%s' "$SNAPSHOT" | jq -e '.secondmate_current.records | any(.id == "local" and .remote == false)' >/dev/null \
  || fail "fleet snapshot lost the existing local secondmate route"
pass "fleet snapshot projects mixed local and remote structured state"
rm -f "$PARENT/state/.wake-queue"

# The remote code root updates independently, then the persistent home imports
# and fast-forwards to that host-local commit without touching project clones.
REMOTE_SEED="$TMP_ROOT/firstmate-seed"
git clone -q "file://$REMOTE_ORIGIN" "$REMOTE_SEED"
git -C "$REMOTE_SEED" config user.email test@example.com
git -C "$REMOTE_SEED" config user.name Test
printf 'remote update probe\n' > "$REMOTE_SEED/REMOTE_UPDATE_PROBE"
git -C "$REMOTE_SEED" add REMOTE_UPDATE_PROBE
git -C "$REMOTE_SEED" commit -qm 'advance remote code root'
git -C "$REMOTE_SEED" push -q origin main
UPDATE_OUT=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh update ios)
assert_contains "$UPDATE_OUT" 'synced:' "remote update did not report a host-local fast-forward"
[ "$(git -C "$REMOTE_HOME" rev-parse HEAD)" = "$(git -C "$REMOTE_ROOT" rev-parse HEAD)" ] \
  || fail "remote persistent home did not fast-forward to its code-root commit"
assert_present "$REMOTE_HOME/REMOTE_UPDATE_PROBE" "remote update did not materialize the code-root commit"
pass "remote update imports and fast-forwards the persistent home on its configured host"

# Remote restart must reject an unverified harness or contradictory endpoint
# ownership before stopping the live agent or rewriting the endpoint record.
RELAUNCH_UNVERIFIED=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh \
  relaunch ios notaharness - - 2>&1) && fail "an unverified runtime should refuse a remote restart"
assert_contains "$RELAUNCH_UNVERIFIED" 'unverified remote secondmate harness' \
  "the remote restart verb did not refuse an unverified runtime"
RELAUNCH_ROUTE_META="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$RELAUNCH_ROUTE_META" "$TMP_ROOT/ios-before-relaunch.meta"
mkdir -p "$TMP_ROOT/not-a-checkout"
sed "s|^worktree=.*|worktree=$TMP_ROOT/not-a-checkout|" \
  "$TMP_ROOT/ios-before-relaunch.meta" > "$RELAUNCH_ROUTE_META"
cp "$RELAUNCH_ROUTE_META" "$TMP_ROOT/ios-mismatched-relaunch.meta"
RELAUNCH_CHECKPOINT=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh \
  relaunch ios codex - - 2>&1) && fail "a restart with contradictory endpoint ownership should refuse"
assert_contains "$RELAUNCH_CHECKPOINT" 'remote endpoint worktree does not match the selected secondmate home' \
  "remote restart did not reject contradictory endpoint ownership"
cmp -s "$TMP_ROOT/ios-mismatched-relaunch.meta" "$RELAUNCH_ROUTE_META" \
  || fail "a refused remote restart changed the contradictory endpoint record"
cp "$TMP_ROOT/ios-before-relaunch.meta" "$RELAUNCH_ROUTE_META"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "a refused remote restart must leave the running agent untouched"
pass "remote restart rejects unverified harnesses and contradictory ownership before mutation"


rm -f "$TMP_ROOT/doctor.repaired"
: > "$DOCTOR_LOG"
[ "$(FM_FAKE_SSH_MODE=doctor-fixable remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = unreadable ] \
  || fail "the stopped-server fixture did not make the pre-repair endpoint probe unreadable"
launches_before_repair=$(grep -c '^tab create' "$HERDR_LOG" || true)
BOOT_REPAIRED=$(FM_FAKE_SSH_MODE=doctor-fixable remote_env "$ROOT/bin/fm-bootstrap.sh")
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fixable --backend
doctor-fixable --fix
doctor-fixable --backend' ] || fail "liveness did not check, repair, and re-check readiness before probing"$'\n'"$(cat "$DOCTOR_LOG")"
assert_not_contains "$BOOT_REPAIRED" 'SECONDMATE_LIVENESS: secondmate ios:' \
  "successful pre-probe readiness repair produced a liveness failure"
launches_after_repair=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before_repair" -eq "$launches_after_repair" ] \
  || fail "readiness repair introduced a new remote relaunch point"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "the endpoint was not probed successfully after readiness repair"
pass "startup repairs remote readiness before probing without relaunching"

# --- ordinary-supervision recovery of a dead remote endpoint -----------------
# The watcher's cadence-gated liveness tick (bin/fm-watch.sh
# secondmate_liveness_tick) drives the same shared probe+relaunch library the
# startup sweep used above: a positively dead remote endpoint relaunches
# through the guarded remote spawn and emits exactly one check wake, while an
# unreachable host is preserved untouched. The tick runs against a dedicated
# state dir holding only this mate's endpoint meta so no other supervision
# source can fire first.

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
WATCH_STATE="$TMP_ROOT/watch-liveness-state"
mkdir -p "$WATCH_STATE"
cp "$PARENT/state/ios.meta" "$WATCH_STATE/ios.meta"
# The remote spawn path mints its inheritance generation from a counter that
# lives beside the task record, so the dedicated watch state needs the real
# one; otherwise the pushed payload reads as superseded on the remote home.
cp "$PARENT/state/.remote-inherit-ios.generation" "$WATCH_STATE/" 2>/dev/null || true
touch "$WATCH_STATE/home-summary.json"

# A graceful agent exit leaves the pane with no registered agent - the exact
# incident this tick exists for.
ios_pane=$(sed -n 's/^herdr_pane_id=//p' "$remote_route_meta")
[ -n "$ios_pane" ] || fail "the remote route meta did not record its Herdr pane"
jq --arg p "$ios_pane" \
  '.typed |= with_entries(select(.key != $p)) | .working |= with_entries(select(.key != $p))' \
  "$HERDR_STATE" > "$TMP_ROOT/herdr-dead.json" && mv "$TMP_ROOT/herdr-dead.json" "$HERDR_STATE"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = dead ] \
  || fail "the agent-free remote pane did not classify dead"

tabs_before=$(grep -c '^tab create' "$HERDR_LOG" || true)
# exec keeps $! the watcher itself rather than the function's subshell, so a
# kill reaches the process that probes and writes into the fixture root.
# Recovery permits one timeout for lock acquisition and another for spawn.
# The outer deadline must cover both, plus watcher startup and EXIT cleanup;
# a 30-second wait races successful recovery on a loaded runner.
watch_relaunch_timeout=120
FM_SECONDMATE_LIVENESS_TIMEOUT="$watch_relaunch_timeout" \
  FM_STATE_OVERRIDE="$WATCH_STATE" FM_SECONDMATE_LIVENESS_SECS=1 FM_POLL=1 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  remote_env exec "$ROOT/bin/fm-watch.sh" \
  > "$TMP_ROOT/watch-liveness.out" 2> "$TMP_ROOT/watch-liveness.err" &
watch_pid=$!
watch_deadline=$((SECONDS + 2 * watch_relaunch_timeout + 30))
while kill -0 "$watch_pid" 2>/dev/null && [ "$SECONDS" -lt "$watch_deadline" ]; do
  sleep 0.1
done
if kill -0 "$watch_pid" 2>/dev/null; then
  kill "$watch_pid" 2>/dev/null || true
  fail "the watcher did not exit on its auto-relaunch wake within its ${watch_relaunch_timeout}s relaunch bound: $(cat "$TMP_ROOT/watch-liveness.out" "$TMP_ROOT/watch-liveness.err" 2>/dev/null)"
fi
wait "$watch_pid" \
  || fail "the liveness watcher leg exited non-zero: $(cat "$TMP_ROOT/watch-liveness.err")"
watch_pid=''
grep -F 'check: secondmate ios auto-relaunched after remote endpoint dead on its configured host (host=remote-mac)' \
  "$TMP_ROOT/watch-liveness.out" >/dev/null \
  || fail "the dead remote secondmate was not auto-relaunched: $(cat "$TMP_ROOT/watch-liveness.out")"
[ "$(grep -c 'check: secondmate ios auto-relaunched' "$TMP_ROOT/watch-liveness.out")" -eq 1 ] \
  || fail "the remote auto-relaunch did not produce exactly one captain-facing line"
grep -F $'\tcheck\tsecondmate-relaunch-ios-' "$WATCH_STATE/.wake-queue" >/dev/null \
  || fail "the durable auto-relaunch wake row was not queued: $(cat "$WATCH_STATE/.wake-queue" 2>/dev/null)"
grep -F 'relaunched' "$WATCH_STATE/.secondmate-relaunch-ios" >/dev/null \
  || fail "the durable per-mate ledger did not record the relaunch"
tabs_after=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$tabs_after" -gt "$tabs_before" ] \
  || fail "the remote relaunch did not create a fresh remote endpoint ($tabs_before -> $tabs_after)"
assert_grep 'remote_host=remote-mac' "$WATCH_STATE/ios.meta" \
  "the watcher relaunch dropped the remote host route"
assert_grep 'herdr_session=fm-remote' "$remote_route_meta" \
  "the watcher relaunch did not re-record the pinned remote Herdr session"
assert_grep '- ios ' "$PARENT/data/secondmates.md" \
  "the watcher relaunch changed the registry route"
[ "$(FM_STATE_OVERRIDE="$WATCH_STATE" remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "the auto-relaunched remote endpoint did not read alive"
# Production relaunch updates the parent route meta and inheritance generation
# in place; the dedicated watch state above kept the rest of this suite's
# parent state out of scope, so fold both records back now.
cp "$WATCH_STATE/ios.meta" "$PARENT/state/ios.meta"
cp "$WATCH_STATE/.remote-inherit-ios.generation" "$PARENT/state/" 2>/dev/null || true
pass "watch liveness: a dead remote secondmate is auto-relaunched on its own host with one wake"

# Host loss mid-supervision is never evidence of death: the same tick on an
# unreachable route probes, preserves, and stays silent.
WATCH_STATE_UNREACHABLE="$TMP_ROOT/watch-liveness-unreachable"
mkdir -p "$WATCH_STATE_UNREACHABLE"
cp "$WATCH_STATE/ios.meta" "$WATCH_STATE_UNREACHABLE/ios.meta"
touch "$WATCH_STATE_UNREACHABLE/home-summary.json"
ssh_before=$(cat "$SSH_COUNT" 2>/dev/null || printf '0')
FM_FAKE_SSH_MODE=unreachable FM_STATE_OVERRIDE="$WATCH_STATE_UNREACHABLE" \
  FM_SECONDMATE_LIVENESS_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  remote_env exec "$ROOT/bin/fm-watch.sh" \
  > "$TMP_ROOT/watch-unreachable.out" 2> "$TMP_ROOT/watch-unreachable.err" &
watch_pid=$!
i=0
processed=0
while [ "$i" -lt 80 ]; do
  kill -0 "$watch_pid" 2>/dev/null \
    || fail "the watcher exited against an unreachable remote secondmate: $(cat "$TMP_ROOT/watch-unreachable.out" "$TMP_ROOT/watch-unreachable.err")"
  if [ "$processed" -eq 0 ] \
    && grep -Fq 'secondmate ios liveness:' "$WATCH_STATE_UNREACHABLE/.watch-triage.log" 2>/dev/null; then
    processed=1
    touch "$TMP_ROOT/watch-unreachable.processed"
  fi
  if [ "$processed" -eq 1 ] \
    && [ "$WATCH_STATE_UNREACHABLE/.last-watcher-beat" -nt "$TMP_ROOT/watch-unreachable.processed" ]; then
    break
  fi
  sleep 0.1
  i=$((i + 1))
done
kill -0 "$watch_pid" 2>/dev/null \
  || fail "the watcher exited against an unreachable remote secondmate: $(cat "$TMP_ROOT/watch-unreachable.out" "$TMP_ROOT/watch-unreachable.err")"
kill "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
watch_pid=''
sleep 1
ssh_after=$(cat "$SSH_COUNT" 2>/dev/null || printf '0')
[ "$ssh_after" -gt "$ssh_before" ] || fail "the unreachable remote endpoint was never probed"
# A watcher that survives this stop keeps probing into the fixture root until
# the EXIT trap races its removal, so prove nothing polls past a few cycles.
touch "$TMP_ROOT/watch-unreachable.stopped"
sleep 3
[ "$(cat "$SSH_COUNT" 2>/dev/null || printf '0')" = "$ssh_after" ] \
  || fail "the stopped unreachable watcher kept probing the remote endpoint"
[ -z "$(find "$WATCH_STATE_UNREACHABLE" -newer "$TMP_ROOT/watch-unreachable.stopped" -print)" ] \
  || fail "the stopped unreachable watcher kept writing its state"
[ ! -s "$WATCH_STATE_UNREACHABLE/.wake-queue" ] \
  || fail "an unreachable remote probe queued a wake: $(cat "$WATCH_STATE_UNREACHABLE/.wake-queue")"
assert_absent "$WATCH_STATE_UNREACHABLE/.secondmate-relaunch-ios" \
  "an unreachable remote probe ledgered a relaunch attempt"
assert_grep 'remote_host=remote-mac' "$WATCH_STATE_UNREACHABLE/ios.meta" \
  "an unreachable remote probe changed the route metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" \
  "an unreachable remote probe changed the registry route"
pass "watch liveness: an unreachable remote secondmate is probed, preserved, and never failed over"

# --- a stale herdr client shadowing the one the server accepts --------------
# The remote host's job PATH can resolve an older self-updated herdr ahead of
# the one its running server accepts; the server then refuses every command
# from it with protocol_mismatch. The host-local state read must still reach
# the live endpoint through the accepted client.
make_herdr_client_pair "$TMP_ROOT/client-pair" 0.7.1 14 0.7.5 16
export FM_HERDR_PAIR_DIR="$TMP_ROOT/client-pair"
SHADOWED_STATE=$(FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  PATH="$TMP_ROOT/client-pair/stale:$REMOTE_ROOT/bin:$TMP_ROOT/client-pair/tools:/usr/bin:/bin" \
  "$REMOTE_ROOT/bin/fm-remote-secondmate-control.sh" state ios 2>"$TMP_ROOT/shadowed-state.err")
[ "$SHADOWED_STATE" = alive ] \
  || fail "a live endpoint behind a stale shadowing client must still read alive, got: $SHADOWED_STATE ($(cat "$TMP_ROOT/shadowed-state.err"))"
assert_contains "$(cat "$TMP_ROOT/client-pair/stale.log")" 'pane get' "the stale client was not the one the job PATH resolved first"
unset FM_HERDR_PAIR_DIR
pass "the host-local state read steps around a stale shadowing herdr client"

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-liveness-legacy.meta"
cp "$PARENT/state/ios.meta" "$TMP_ROOT/parent-ios-before-liveness-legacy.meta"
cp "$PARENT/data/secondmates.md" "$TMP_ROOT/registry-before-liveness-legacy.md"
cat > "$remote_route_meta" <<EOF
window=firstmate:fm-ios
worktree=$REMOTE_HOME
home=$REMOTE_HOME
project=$REMOTE_ROOT
harness=codex
kind=secondmate
backend=tmux
EOF
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-liveness-legacy.meta"
printf 'fm-ios|%s\n' "$REMOTE_HOME" > "$TMUX_STATE"
tmux_state_before=$(cat "$TMUX_STATE")
launches_before_legacy=$(grep -c '^tab create' "$HERDR_LOG" || true)
BOOT_LEGACY=$(remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_contains "$BOOT_LEGACY" "SECONDMATE_LIVENESS: secondmate ios: skipped: remote endpoint state is unverified on remote-mac" \
  "liveness accepted an alive legacy remote backend"
cmp -s "$TMP_ROOT/remote-ios-liveness-legacy.meta" "$remote_route_meta" \
  || fail "liveness rewrote the alive legacy endpoint metadata"
cmp -s "$TMP_ROOT/parent-ios-before-liveness-legacy.meta" "$PARENT/state/ios.meta" \
  || fail "liveness rewrote the parent route metadata for an alive legacy endpoint"
cmp -s "$TMP_ROOT/registry-before-liveness-legacy.md" "$PARENT/data/secondmates.md" \
  || fail "liveness changed the registry route for an alive legacy endpoint"
[ "$(cat "$TMUX_STATE")" = "$tmux_state_before" ] \
  || fail "liveness changed or killed the alive legacy endpoint"
launches_after_legacy=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before_legacy" -eq "$launches_after_legacy" ] \
  || fail "liveness relaunched an alive legacy endpoint"
mv -f "$TMP_ROOT/remote-ios-before-liveness-legacy.meta" "$remote_route_meta"
rm -f "$TMUX_STATE"
pass "startup reports alive legacy backends without changing their routes"

printf 'FM_TEST_COMPLETE\n'
