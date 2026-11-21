#!/usr/bin/env bash
# Explicit remote Herdr session migration, replay, and reversal over fake SSH.
set -u

# shellcheck source=tests/remote-secondmate-lifecycle-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-secondmate-lifecycle-fixture.sh"

printf '1..1\n'
set -e
ORIGINAL_PARENT=$PARENT
# Existing fake SSH/job-worker/Herdr path, extended for explicit relocation.
PARENT="$TMP_ROOT/migration-primary"
NAMING_PARENTS+=("$PARENT")
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$REMOTE_ROOT/state"
printf 'claude\n' > "$PARENT/config/secondmate-harness"
moving_home="$TMP_ROOT/migration-home"
FM_SECONDMATE_CHARTER='Own the moving fixture route.' remote_env "$ROOT/bin/fm-remote-home-seed.sh" moving remote-mac "$REMOTE_ROOT" "$moving_home" --no-projects >/dev/null || fail 'migration seed failed'
printf '%s\n' "$$" > "$PARENT/state/.lock"
: > "$PARENT/config/trace-context"
FM_TRACE_CONTEXT=on bash -c '. "$1/bin/fm-trace-context-lib.sh"; fm_trace_context_session_start "$2/config" "$2/state/.trace-context-effective"' _ "$ROOT" "$PARENT"
remote_env "$ROOT/bin/fm-spawn.sh" moving --secondmate >/dev/null || fail 'migration source launch failed'
endpoint="$moving_home/state/parent-route/moving.meta"
migration_traceparent=$(awk -F= '$1=="traceparent" {print $2}' "$PARENT/state/moving.meta")
[ -n "$migration_traceparent" ] || fail 'trace-enabled source has no carrier'
migration_trace_preserved() {
  local staged
  grep -Fx "traceparent=$migration_traceparent" "$PARENT/state/moving.meta" >/dev/null || fail 'migration changed parent trace identity'
  grep -Fx "traceparent=$migration_traceparent" "$endpoint" >/dev/null || fail 'migration changed remote trace identity'
  [ "$(sed -n 's/.*export TRACEPARENT=\([0-9a-f-]*\).*/\1/p' "$HERDR_LOG" | tail -1)" = "$migration_traceparent" ] || fail 'migration did not inject saved trace identity'
  staged=$(sed -n "s/^pane send-text [^ ]* \\. '\([^']*\)' --session [^ ]*\$/\1/p" "$HERDR_LOG" | tail -1)
  [ -f "$staged" ] || fail 'migration launch payload unavailable'
  assert_grep 'FM_TRACE_CONTEXT=on' "$staged" 'migration disabled launched tracing'
}
migration_trace_preserved
printf 'preserved history\n' > "$moving_home/data/migration-history"
printf 'preserved config\n' > "$moving_home/config/migration-preserve"
cp "$moving_home/data/charter.md" "$TMP_ROOT/migration-charter.before"
cp "$endpoint" "$TMP_ROOT/migration-source.before"
awk -F= '$1=="herdr_session" {print "herdr_session=fm-disagree"; next} {print}' "$endpoint" > "$TMP_ROOT/migration-disagreement"
cp "$TMP_ROOT/migration-disagreement" "$endpoint"
if remote_env "$ROOT/bin/fm-remote-session-migrate.sh" moving fm-migrated > "$TMP_ROOT/migration-disagree.out" 2>&1; then fail 'disagreeing endpoint accepted'; fi
assert_grep 'endpoint metadata is invalid' "$TMP_ROOT/migration-disagree.out" "disagreement omitted its reason: $(cat "$TMP_ROOT/migration-disagree.out")"
cmp -s "$endpoint" "$TMP_ROOT/migration-disagreement" || fail 'disagreeing endpoint was rewritten'
cp "$TMP_ROOT/migration-source.before" "$endpoint"
source_target=$(awk -F= '$1=="remote_target" {print substr($0,15)}' "$PARENT/state/moving.meta")
source_pane=${source_target#fm-remote:}
touch "$REMOTE_ROOT/state/.migration-test"
for invalid in '' default bad/name -bad; do
  calls_before=$(cat "$SSH_COUNT")
  if remote_env "$ROOT/bin/fm-remote-session-migrate.sh" moving "$invalid" > "$TMP_ROOT/migration-invalid.out" 2>&1; then fail 'invalid target accepted'; fi
  assert_grep '1-64 ASCII bytes' "$TMP_ROOT/migration-invalid.out" 'invalid target omitted grammar'
  [ "$(cat "$SSH_COUNT")" = "$calls_before" ] || fail 'invalid target reached SSH'
done
for missing in absent moving; do
  cp "$PARENT/data/secondmates.md" "$TMP_ROOT/migration-registry.clean"
  [ "$missing" != moving ] || grep '^- moving ' "$TMP_ROOT/migration-registry.clean" >> "$PARENT/data/secondmates.md"
  if remote_env "$ROOT/bin/fm-remote-session-migrate.sh" "$missing" fm-migrated > "$TMP_ROOT/migration-missing.out" 2>&1; then fail 'unregistered or duplicate route accepted'; fi
  assert_grep 'unregistered or duplicated route' "$TMP_ROOT/migration-missing.out" 'missing route refusal omitted reason'
  cp "$TMP_ROOT/migration-registry.clean" "$PARENT/data/secondmates.md"
done
printf -- '- staying - Sibling (host: remote-mac; root: %s; home: %s; session: fm-already; scope: sibling; projects: ; added 2026-10-31)\n' "$REMOTE_ROOT" "$TMP_ROOT/sibling-home" >> "$PARENT/data/secondmates.md"
if remote_env "$ROOT/bin/fm-remote-session-migrate.sh" moving fm-already > "$TMP_ROOT/migration-duplicate.out" 2>&1; then fail 'registered target collision accepted'; fi
assert_grep 'registered-route collision' "$TMP_ROOT/migration-duplicate.out" 'collision omitted reason'
reset_remote_herdr_fixture "$HERDR_STATE.fm-taken"
if remote_env "$ROOT/bin/fm-remote-session-migrate.sh" moving fm-taken > "$TMP_ROOT/migration-taken.out" 2>&1; then fail 'existing session accepted'; fi
assert_grep 'name already used' "$TMP_ROOT/migration-taken.out" 'used name omitted reason'
assert_absent "$PARENT/state/.remote-session-migration-moving" 'refusal recorded a partial relocation'
sed 's/session: fm-already;/session: fm-remote;/' "$PARENT/data/secondmates.md" > "$TMP_ROOT/migration-registry.before"
cp "$TMP_ROOT/migration-registry.before" "$PARENT/data/secondmates.md"
cp "$PARENT/state/moving.meta" "$TMP_ROOT/migration-parent.before"
jq -S --arg p "$source_pane" '.tabs | map(select(.pane_id != $p))' "$HERDR_STATE" > "$TMP_ROOT/migration-siblings.before"
for activity in busy unknown; do
  if [ "$activity" = busy ]; then
    gen=$("$ROOT/bin/fm-busy-event.sh" arm "$moving_home/state/parent-route" moving --state busy --source fm-spawn --event seed)
    printf 'busy_gen=%s\n' "$gen" >> "$endpoint"
  else
    "$ROOT/bin/fm-busy-event.sh" retire "$moving_home/state/parent-route" moving --gen "$gen" >/dev/null
  fi
  if remote_env "$ROOT/bin/fm-remote-session-migrate.sh" moving fm-migrated > "$TMP_ROOT/migration-$activity.out" 2>&1; then fail "$activity source accepted"; fi
  assert_grep 'quiesce it and re-run' "$TMP_ROOT/migration-$activity.out" 'source refusal omitted recovery'
  cmp -s "$PARENT/data/secondmates.md" "$TMP_ROOT/migration-registry.before" || fail "$activity source changed route"
done
migration_fail_before_refresh() {
  local destination=$1 label=$2 real_cp intent
  real_cp=$(command -v cp)
  cp "$PARENT/data/secondmates.md" "$TMP_ROOT/$label-registry.before"
  cp "$PARENT/state/moving.meta" "$TMP_ROOT/$label-parent.before"
  cat > "$REMOTE_ROOT/bin/cp" <<SH
#!/usr/bin/env bash
destination=\${!#}
case "\$destination" in
  '$moving_home/state/parent-route/.session-migration-moving/'op.*/before|'$moving_home/state/parent-route/.session-migration-moving/'op.*/.before.*)
    '$real_cp' "\${destination%/*}/before" '$TMP_ROOT/$label-snapshot.before' || exit 1
    printf 'partial copy\n' > "\$destination"
    touch '$TMP_ROOT/$label-copy-failed'
    exit 1 ;;
esac
exec '$real_cp' "\$@"
SH
  chmod +x "$REMOTE_ROOT/bin/cp"
  if remote_env "$ROOT/bin/fm-remote-session-migrate.sh" moving "$destination" > "$TMP_ROOT/$label-copy.out" 2>&1; then fail 'partial source snapshot copy reported success'; fi
  rm "$REMOTE_ROOT/bin/cp"
  assert_present "$TMP_ROOT/$label-copy-failed" 'source snapshot refresh was not reached'
  intent=$(cat "$moving_home/state/parent-route/.session-migration-moving/active")
  cmp -s "$TMP_ROOT/$label-snapshot.before" "$moving_home/state/parent-route/.session-migration-moving/$intent/before" || fail 'failed refresh corrupted published source snapshot'
  assert_absent "$moving_home/state/parent-route/.session-migration-moving/$intent/after" 'failed refresh published destination preparation'
  cmp -s "$PARENT/data/secondmates.md" "$TMP_ROOT/$label-registry.before" || fail 'failed refresh changed route'
  cmp -s "$PARENT/state/moving.meta" "$TMP_ROOT/$label-parent.before" || fail 'failed refresh changed parent endpoint'
}
migration_idle() {
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$moving_home/state/parent-route" moving --state idle --source fm-spawn --event seed)
  grep -v '^busy_gen=' "$endpoint" > "$TMP_ROOT/migration-meta.clean"
  { cat "$TMP_ROOT/migration-meta.clean"; printf 'busy_gen=%s\n' "$gen"; } > "$endpoint"
}
migration_idle
touch "$REMOTE_ROOT/state/.migration-test.birth-fail"
if remote_env "$ROOT/bin/fm-remote-session-migrate.sh" moving fm-migrated > "$TMP_ROOT/migration-birth.out" 2>&1; then fail 'failed birth accepted'; fi
assert_grep 'target session could not be created' "$TMP_ROOT/migration-birth.out" 'birth failure omitted reason'
rm "$REMOTE_ROOT/state/.migration-test.birth-fail"
migration_fail_before_refresh fm-migrated forward
if FM_FAKE_SSH_MODE=migration-lost-prepare remote_env "$ROOT/bin/fm-remote-session-migrate.sh" moving fm-migrated > "$TMP_ROOT/migration-lost.out" 2>&1; then fail 'lost preparation reported success'; fi
assert_grep 'route remains on session fm-remote' "$TMP_ROOT/migration-lost.out" 'pre-publication failure omitted old binding'
if [ ! -f "$HERDR_STATE.fm-migrated" ] && [ -n "${FM_TEST_RELOCATION_EVIDENCE_DIR:-}" ]; then
  cp "$HERDR_LOG" "$FM_TEST_RELOCATION_EVIDENCE_DIR/herdr-birth-failure.log"
  cp "$TMP_ROOT/migration-lost.out" "$FM_TEST_RELOCATION_EVIDENCE_DIR/prepare-birth-failure.log"
fi
assert_present "$HERDR_STATE.fm-migrated" "failure did not reach session creation: $(cat "$TMP_ROOT/migration-lost.out")"
cmp -s "$PARENT/data/secondmates.md" "$TMP_ROOT/migration-registry.before" || fail 'lost preparation changed session or root'
cmp -s "$PARENT/state/moving.meta" "$TMP_ROOT/migration-parent.before" || fail 'lost preparation changed parent endpoint'
grep -Fx 'herdr_session=fm-remote' "$endpoint" >/dev/null || fail 'lost preparation changed remote binding'
if remote_env "$ROOT/bin/fm-on.sh" moving fm-remote-secondmate-control.sh state moving > "$TMP_ROOT/migration-barrier.out" 2>&1; then fail 'partial relocation allowed ordinary recovery'; fi
assert_grep 'incomplete relocation' "$TMP_ROOT/migration-barrier.out" 'partial relocation omitted recovery barrier'
printf '# unrelated registry note preserved across retry\n' >> "$PARENT/data/secondmates.md"
# Interrupt between the two local atomic replacements. No ordinary route may
# observe that uncommitted binding, and replay must finish the same snapshots.
migration_fakebin=$(fm_fakebin "$TMP_ROOT/migration-fake")
real_mv=$(command -v mv)
cat > "$migration_fakebin/mv" <<SH
#!/usr/bin/env bash
destination=\${!#}
if [ "\$destination" = '$PARENT/data/secondmates.md' ] && [ ! -f '$TMP_ROOT/migration-interrupted' ]; then
  touch '$TMP_ROOT/migration-interrupted'
  kill -TERM "\$PPID"
  exit 1
fi
exec '$real_mv' "\$@"
SH
chmod +x "$migration_fakebin/mv"
if remote_env env PATH="$migration_fakebin:$PATH" "$ROOT/bin/fm-remote-session-migrate.sh" moving fm-migrated > "$TMP_ROOT/migration-interrupt.out" 2>&1; then fail 'injected interruption reported success'; fi
assert_present "$TMP_ROOT/migration-interrupted" 'interruption did not reach binding publication'
if remote_env "$ROOT/bin/fm-on.sh" moving fm-remote-secondmate-control.sh state moving >/dev/null 2>&1; then fail 'interrupted publication exposed an ordinary route'; fi
if FM_FAKE_SSH_MODE=migration-no-answer remote_env "$ROOT/bin/fm-remote-session-migrate.sh" moving fm-migrated > "$TMP_ROOT/migration-no-answer.out" 2>&1; then fail 'unanswering normal route reported success'; fi
assert_grep 'normal remote route did not answer' "$TMP_ROOT/migration-no-answer.out" 'unanswering mate omitted the reason'
migration_trace_preserved
migration_pane=$(awk -F= '$1=="herdr_pane_id" {print $2}' "$endpoint")
jq --arg p "$migration_pane" '.typed[$p] = false | .working[$p] = false' "$HERDR_STATE.fm-migrated" > "$TMP_ROOT/migration-stopped"
mv "$TMP_ROOT/migration-stopped" "$HERDR_STATE.fm-migrated"
remote_env "$ROOT/bin/fm-remote-session-migrate.sh" moving fm-migrated > "$TMP_ROOT/migration-complete.out" 2>&1 || fail "relocation re-run failed: $(cat "$TMP_ROOT/migration-complete.out")"
assert_grep 'normal route answers' "$TMP_ROOT/migration-complete.out" 'normal route was not verified'
migration_trace_preserved
assert_grep '# unrelated registry note preserved across retry' "$PARENT/data/secondmates.md" 'migration replay overwrote unrelated registry changes'
grep -Fx 'remote_herdr_session=fm-migrated' "$PARENT/state/moving.meta" >/dev/null || fail 'parent session did not move'
grep -Fx 'herdr_session=fm-migrated' "$endpoint" >/dev/null || fail 'remote session did not move'
[ "$(remote_env "$ROOT/bin/fm-on.sh" moving fm-remote-secondmate-control.sh state moving)" = alive ] || fail 'migrated route did not answer'
jq -e --arg p "$source_pane" '.tabs | any(.pane_id == $p)' "$HERDR_STATE" >/dev/null || fail 'source terminal removed'
jq -S --arg p "$source_pane" '.tabs | map(select(.pane_id != $p))' "$HERDR_STATE" > "$TMP_ROOT/migration-siblings.after"
cmp -s "$TMP_ROOT/migration-siblings.before" "$TMP_ROOT/migration-siblings.after" || fail 'sibling terminal changed'
grep -F -- '- staying -' "$PARENT/data/secondmates.md" | grep -F 'session: fm-remote;' >/dev/null || fail 'sibling route changed'
assert_absent "$moving_home/state/parent-route/moving.control-relaunch" 'relocation wrote a journal'
[ "$(cat "$moving_home/data/migration-history")" = 'preserved history' ] || fail 'migration changed mate history'
[ "$(cat "$moving_home/config/migration-preserve")" = 'preserved config' ] || fail 'migration changed mate config'
cmp -s "$moving_home/data/charter.md" "$TMP_ROOT/migration-charter.before" || fail 'migration changed mate instructions'
migration_original_traceparent=$migration_traceparent
for tracing in off on; do
  migration_pane=$(awk -F= '$1=="herdr_pane_id" {print $2}' "$endpoint")
  jq --arg p "$migration_pane" '.typed[$p] = false | .working[$p] = false' "$HERDR_STATE.fm-migrated" > "$TMP_ROOT/migration-stopped"
  mv "$TMP_ROOT/migration-stopped" "$HERDR_STATE.fm-migrated"
  FM_TRACE_CONTEXT=$tracing bash -c '. "$1/bin/fm-trace-context-lib.sh"; fm_trace_context_session_start "$2/config" "$2/state/.trace-context-effective"' _ "$ROOT" "$PARENT"
  remote_env "$ROOT/bin/fm-spawn.sh" moving --secondmate --effort high >/dev/null || fail 'migration trace reconfiguration launch failed'
done
migration_traceparent=$(awk -F= '$1=="traceparent" {print $2}' "$PARENT/state/moving.meta")
[ -n "$migration_traceparent" ] && [ "$migration_traceparent" != "$migration_original_traceparent" ] || fail 'reconfiguration did not create a new trace identity'
migration_trace_preserved
migration_idle
cp "$PARENT/data/secondmates.md" "$TMP_ROOT/reversal-registry.before"
cp "$PARENT/state/moving.meta" "$TMP_ROOT/reversal-parent.before"
real_mv=$(command -v mv)
cat > "$REMOTE_ROOT/bin/mv" <<SH
#!/usr/bin/env bash
destination=\${!#}
case "\$destination" in
  '$moving_home/state/parent-route/.session-migration-moving/'op.*/after)
    if [ ! -f '$TMP_ROOT/reversal-interrupted' ]; then
      touch '$TMP_ROOT/reversal-interrupted'
      exit 1
    fi ;;
esac
exec '$real_mv' "\$@"
SH
chmod +x "$REMOTE_ROOT/bin/mv"
migration_fail_before_refresh --reverse reversal
if remote_env "$ROOT/bin/fm-remote-session-migrate.sh" moving --reverse > "$TMP_ROOT/migration-reverse-interrupted.out" 2>&1; then fail 'interrupted reversal preparation reported success'; fi
assert_present "$TMP_ROOT/reversal-interrupted" 'reversal did not reach preparation publication'
remote_intent=$(cat "$moving_home/state/parent-route/.session-migration-moving/active")
assert_absent "$moving_home/state/parent-route/.session-migration-moving/$remote_intent/after" 'interrupted preparation published a destination snapshot'
cmp -s "$PARENT/data/secondmates.md" "$TMP_ROOT/reversal-registry.before" || fail 'interrupted reversal changed route'
cmp -s "$PARENT/state/moving.meta" "$TMP_ROOT/reversal-parent.before" || fail 'interrupted reversal changed parent endpoint'
grep -Fx 'herdr_session=fm-migrated' "$endpoint" >/dev/null || fail 'interrupted reversal changed remote endpoint'
remote_env "$ROOT/bin/fm-remote-session-migrate.sh" moving --reverse > "$TMP_ROOT/migration-reverse.out" 2>&1 || fail "session reversal failed: $(cat "$TMP_ROOT/migration-reverse.out")"
rm "$REMOTE_ROOT/bin/mv"
grep -Fx 'effort=high' "$endpoint" >/dev/null || fail 'reversal restored stale launch profile'
grep -Fx 'effort=high' "$PARENT/state/moving.meta" >/dev/null || fail 'reversal changed parent launch profile'
[ "$(remote_env "$ROOT/bin/fm-on.sh" moving fm-remote-secondmate-control.sh state moving)" = alive ] || fail 'reversed route did not answer'
migration_trace_preserved
assert_grep "root: $REMOTE_ROOT; home: $moving_home; session: fm-remote;" "$PARENT/data/secondmates.md" 'reversal did not restore original session and preserve root'
grep -Fx "remote_root=$REMOTE_ROOT" "$PARENT/state/moving.meta" >/dev/null || fail 'session migration changed execution root'
assert_no_regex '(session (stop|delete|rename)|server stop).*--session fm-remote( |$)' "$HERDR_LOG" 'relocation touched legacy session lifecycle'
PARENT=$ORIGINAL_PARENT
pass 'explicit session migration handles refusals, re-runs and reversal without changing the source session or siblings'

printf 'FM_TEST_COMPLETE\n'
