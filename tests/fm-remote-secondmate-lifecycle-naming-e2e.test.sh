#!/usr/bin/env bash
# Independent primaries with distinct remote Herdr sessions over fake SSH.
set -u

# shellcheck source=tests/remote-secondmate-lifecycle-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-secondmate-lifecycle-fixture.sh"

printf '1..1\n'
set -e
# Independent primaries reuse one route id on the same fake account.
ORIGINAL_PARENT=$PARENT
for lane in a b; do
  PARENT="$TMP_ROOT/naming-primary-$lane"
  NAMING_PARENTS+=("$PARENT")
  mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config"
  printf 'codex\n' > "$PARENT/config/secondmate-harness"
  session="fm-fleet-$lane"
  lane_home="$TMP_ROOT/naming-home-$lane"
  reset_remote_herdr_fixture "$HERDR_STATE.$session"
  FM_SECONDMATE_CHARTER='Own the isolated naming fixture.' \
    remote_env "$ROOT/bin/fm-remote-home-seed.sh" --herdr-session "$session" naming remote-mac "$REMOTE_ROOT" "$lane_home" --no-projects >/dev/null \
    || fail "custom seed failed for $lane"
  assert_grep "home: $lane_home; session: $session;" "$PARENT/data/secondmates.md" "seed lost session"
  if [ "$lane" = a ]; then
    cp "$PARENT/data/secondmates.md" "$TMP_ROOT/naming-route.before"
    export FM_FAKE_SESSION_CHANGE_REG="$PARENT/data/secondmates.md"
    if FM_FAKE_SSH_MODE=doctor-route-change remote_env "$ROOT/bin/fm-spawn.sh" naming --secondmate >/dev/null 2>&1; then fail "route change during readiness accepted"; fi
    assert_absent "$lane_home/state/parent-route/naming.meta" "changed route reached endpoint launch"
    assert_absent "$PARENT/state/naming.meta" "changed route published parent metadata"
    cp "$TMP_ROOT/naming-route.before" "$PARENT/data/secondmates.md"
    unset FM_FAKE_SESSION_CHANGE_REG
  fi
  remote_env "$ROOT/bin/fm-spawn.sh" naming --secondmate >/dev/null || fail "custom launch failed for $lane"
  assert_grep "remote_herdr_session=$session" "$PARENT/state/naming.meta" "parent publication lost custom session"
  assert_grep "herdr_session=$session" "$lane_home/state/parent-route/naming.meta" "remote publication lost custom session"
done
for lane in a b; do
  PARENT="$TMP_ROOT/naming-primary-$lane"
  session="fm-fleet-$lane"
  lane_home="$TMP_ROOT/naming-home-$lane"
  other=a; [ "$lane" != a ] || other=b
  other_home="$TMP_ROOT/naming-home-$other"
  cp "$HERDR_STATE.fm-fleet-$other" "$TMP_ROOT/naming-sibling.state"
  cp "$other_home/state/parent-route/naming.meta" "$TMP_ROOT/naming-sibling.meta"
  [ "$(remote_env "$ROOT/bin/fm-on.sh" naming fm-remote-secondmate-control.sh state naming)" = alive ] || fail "custom state failed"
  route=$(remote_env "$ROOT/bin/fm-on.sh" naming fm-remote-secondmate-control.sh route naming)
  assert_contains "$route" "herdr_session=$session" "route returned another session"
  remote_env "$ROOT/bin/fm-on.sh" naming fm-remote-secondmate-control.sh send naming 'isolated steer' fire-and-forget >/dev/null || fail "custom send failed"
  remote_env "$ROOT/bin/fm-on.sh" naming fm-remote-secondmate-control.sh key naming Enter >/dev/null || fail "custom key failed"
  for verb in capture observe sync update; do
    remote_env "$ROOT/bin/fm-on.sh" naming fm-remote-secondmate-control.sh "$verb" naming >/dev/null || fail "custom $verb failed"
  done
  endpoint="$lane_home/state/parent-route/naming.meta"
  cp "$endpoint" "$TMP_ROOT/naming-endpoint.before"
  for key in herdr_session window; do
    replacement="fm-fleet-$other"; [ "$key" != window ] || replacement="fm-fleet-$other:alien"
    awk -F= -v key="$key" -v replacement="$replacement" '$1==key {print key "=" replacement;next} {print}' "$TMP_ROOT/naming-endpoint.before" > "$endpoint"
    cp "$endpoint" "$TMP_ROOT/naming-contradiction"
    before_calls=$(wc -l < "$HERDR_LOG" | tr -d ' ')
    for verb in route capture observe sync update retire; do
      if remote_env "$ROOT/bin/fm-on.sh" naming fm-remote-secondmate-control.sh "$verb" naming >/dev/null 2>&1; then fail "custom $verb accepted contradictory $key"; fi
    done
    [ "$(wc -l < "$HERDR_LOG" | tr -d ' ')" = "$before_calls" ] || fail "contradictory endpoint accessed a session"
    cmp -s "$endpoint" "$TMP_ROOT/naming-contradiction" || fail "contradictory evidence changed"
    cp "$TMP_ROOT/naming-endpoint.before" "$endpoint"
  done
  cp "$PARENT/state/naming.meta" "$TMP_ROOT/naming-parent.before"
  sed "s/remote_herdr_session=$session/remote_herdr_session=fm-fleet-$other/" "$TMP_ROOT/naming-parent.before" > "$PARENT/state/naming.meta"
  calls_before=$(cat "$SSH_COUNT")
  if remote_env "$ROOT/bin/fm-on.sh" naming fm-remote-secondmate-control.sh send naming forbidden >/dev/null 2>&1; then fail "parent mismatch accepted"; fi
  [ "$(cat "$SSH_COUNT")" = "$calls_before" ] || fail "parent mismatch reached SSH"
  cp "$TMP_ROOT/naming-parent.before" "$PARENT/state/naming.meta"
  reset_remote_herdr_fixture "$HERDR_STATE.$session"
  remote_env "$ROOT/bin/fm-spawn.sh" naming --secondmate >/dev/null || fail "custom recovery failed"
  assert_grep "remote_target=$session:" "$PARENT/state/naming.meta" "recovery moved sessions"
  cmp -s "$HERDR_STATE.fm-fleet-$other" "$TMP_ROOT/naming-sibling.state" || fail "custom operations mutated sibling session"
  cmp -s "$other_home/state/parent-route/naming.meta" "$TMP_ROOT/naming-sibling.meta" || fail "custom operations mutated sibling endpoint"
done
for lane in a b; do
  PARENT="$TMP_ROOT/naming-primary-$lane"
  remote_env "$ROOT/bin/fm-teardown.sh" naming >/dev/null || fail "custom retirement failed for $lane"
  assert_absent "$TMP_ROOT/naming-home-$lane" "custom retirement retained its home"
done
PARENT=$ORIGINAL_PARENT
pass "two primary homes preserve distinct sessions through seed, launch, access, refusal, sync, update, recovery and retirement"

printf 'FM_TEST_COMPLETE\n'
