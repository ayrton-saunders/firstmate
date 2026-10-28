#!/usr/bin/env bash
# Optional private Discord lane hook: legacy compatibility and safe rejection.
# Full pinned-private-release integration is tested in that release's test suite.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-discord-hook)
HOME_FIXTURE="$TMP_ROOT/home"
mkdir -p "$HOME_FIXTURE/config" "$HOME_FIXTURE/state"
HOOK="$ROOT/bin/fm-discord-hook.py"
printf 'legacy text' | FM_HOME="$HOME_FIXTURE" python3 "$HOOK" send legacy fixture:legacy '' \
  || fail 'absent integration must preserve legacy routes'
pass 'Discord hook: absent integration preserves legacy delivery'
printf '%s\n' '{"enabled":false}' > "$HOME_FIXTURE/config/discord-integration.json"
printf 'legacy text' | FM_HOME="$HOME_FIXTURE" python3 "$HOOK" send legacy fixture:legacy '' \
  || fail 'disabled integration must preserve legacy routes'
pass 'Discord hook: disabled integration preserves legacy delivery'
printf '%s\n' '{"enabled":true,"enabled":false}' > "$HOME_FIXTURE/config/discord-integration.json"
if printf 'private text' | FM_HOME="$HOME_FIXTURE" python3 "$HOOK" send mapped fixture:mapped '' >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail 'duplicate configuration keys must refuse'
fi
assert_not_contains "$(<"$TMP_ROOT/err")" 'private text' 'refusal must not echo payload'
pass 'Discord hook: malformed configuration refuses without echoing private payload'
printf '%s\n' '{"enabled":true,"schema":1}' > "$HOME_FIXTURE/config/discord-integration.json"
if printf 'private text' | FM_HOME="$HOME_FIXTURE" python3 "$HOOK" send mapped fixture:mapped '' >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail 'incomplete enabled configuration must refuse rather than bypass routing'
fi
pass 'Discord hook: incomplete enabled configuration refuses'

# These negative cases require no private package, credentials or runtime setup.
for invalid in '[]' '{"enabled":"false"}' '{"enabled":null}'; do
  printf '%s\n' "$invalid" > "$HOME_FIXTURE/config/discord-integration.json"
  if printf 'private text' | FM_HOME="$HOME_FIXTURE" python3 -I "$HOOK" send mapped fixture:mapped '' >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
    fail 'invalid enablement must not bypass the optional guard'
  fi
  assert_not_contains "$(<"$TMP_ROOT/err")" 'private text' 'invalid enablement must not echo payload'
done
pass 'Discord hook: non-object and non-boolean enablement refuse'
rm "$HOME_FIXTURE/config/discord-integration.json"
printf '%s\n' '{"enabled":false}' > "$TMP_ROOT/linked-config.json"
ln -s "$TMP_ROOT/linked-config.json" "$HOME_FIXTURE/config/discord-integration.json"
if FM_HOME="$HOME_FIXTURE" python3 -I "$HOOK" ready >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail 'symlink configuration must refuse even when disabled'
fi
rm "$HOME_FIXTURE/config/discord-integration.json"
pass 'Discord hook: symlink configuration refuses'

# Drive the actual inbox executable, not an imitation of the optional calls.
# Disabled integration needs neither the private core nor the pinned interpreter.
run_inbox() {
  FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$HOME_FIXTURE/state" \
    FM_DATA_OVERRIDE="$HOME_FIXTURE/data" FM_CONFIG_OVERRIDE="$HOME_FIXTURE/config" \
    bash "$ROOT/bin/fm-inbox.sh" "$@"
}
for mode in absent disabled malformed; do
  case "$mode" in
    absent) rm -f "$HOME_FIXTURE/config/discord-integration.json" ;;
    disabled) printf '%s\n' '{"enabled":false}' > "$HOME_FIXTURE/config/discord-integration.json" ;;
    malformed) printf '%s\n' '{"enabled":true,"schema":1}' > "$HOME_FIXTURE/config/discord-integration.json" ;;
  esac
  note=$(run_inbox note --request-id "discord-hook-$mode" --json 'synthetic private request') \
    || fail 'inbox capture must preserve normal behavior'
  id=$(printf '%s' "$note" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  run_inbox drain >"$TMP_ROOT/drain" 2>"$TMP_ROOT/drain.err" \
    || fail 'optional readiness must not prevent inbox drain'
  assert_contains "$(<"$TMP_ROOT/drain")" 'synthetic private request' 'drain must retain captured input'
  run_inbox reply --json "$id" 'synthetic private reply' >"$TMP_ROOT/reply" 2>"$TMP_ROOT/reply.err" \
    || fail 'optional outcome failure must not make a durable reply retryable'
  receipts=$(run_inbox receipts --all-replies) || fail 'reply receipts must remain readable'
  assert_contains "$receipts" 'synthetic private reply' 'reply must remain readable'
  if [ "$mode" = malformed ]; then
    assert_contains "$(<"$TMP_ROOT/drain.err")" 'readiness not renewed' 'invalid integration must disclose readiness failure'
    assert_contains "$(<"$TMP_ROOT/reply.err")" 'do not resend' 'durable reply must warn against duplication'
  else
    [ ! -s "$TMP_ROOT/drain.err" ] || fail 'absent/disabled readiness must not warn'
    [ ! -s "$TMP_ROOT/reply.err" ] || fail 'absent/disabled reply must not warn'
  fi
done
pass 'Discord hook: actual inbox preserves absent/disabled behavior and reconciles optional failures'

DEFAULT_HOME="$TMP_ROOT/default-home"
fm_test_spawn_home "$DEFAULT_HOME" codex
cp -R "$ROOT/bin" "$DEFAULT_HOME/bin"
printf '%s\n' '{"enabled":false}' > "$DEFAULT_HOME/config/discord-integration.json"
mkdir -p "$DEFAULT_HOME/user-home"
run_default_inbox() {
  env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE HOME="$DEFAULT_HOME/user-home" \
    bash "$DEFAULT_HOME/bin/fm-inbox.sh" "$@"
}
note=$(run_default_inbox note --request-id discord-default-home --json 'default-home request') \
  || fail 'default-home inbox capture must succeed'
id=$(printf '%s' "$note" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
run_default_inbox drain >"$TMP_ROOT/default-drain" 2>"$TMP_ROOT/default-drain.err" \
  || fail 'default-home inbox drain must succeed'
assert_contains "$(<"$TMP_ROOT/default-drain")" 'default-home request' 'default-home request must be drained'
[ ! -s "$TMP_ROOT/default-drain.err" ] || fail 'disabled default-home readiness must not warn'
run_default_inbox reply --json "$id" 'default-home reply' >"$TMP_ROOT/default-reply" 2>"$TMP_ROOT/default-reply.err" \
  || fail 'default-home inbox reply must succeed'
[ ! -s "$TMP_ROOT/default-reply.err" ] || fail 'disabled default-home outcome must not warn'
receipts=$(run_default_inbox receipts --all-replies) || fail 'default-home receipts must be readable'
assert_contains "$receipts" 'default-home reply' 'default-home reply must be durable'
pass 'Discord hook: unset FM_HOME preserves disabled default-home inbox behavior'

FAKEBIN=$(fm_test_make_spawn_fakebin "$TMP_ROOT/spawn-tools" codex gh gh-axi)
PROJECT="$TMP_ROOT/project"
WORKTREE="$TMP_ROOT/worker"
fm_git_worktree "$PROJECT" "$WORKTREE" discord-default-home
fm_test_spawn_brief "$DEFAULT_HOME" default-worker
run_default_spawn() {
  env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_CONFIG_OVERRIDE \
    HOME="$DEFAULT_HOME/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WORKTREE" TMUX=fake,1,0 \
    PATH="$FAKEBIN:$PATH" bash "$DEFAULT_HOME/bin/fm-spawn.sh" "$@"
}
run_default_spawn default-worker "$PROJECT" --scout --backend tmux \
  >"$TMP_ROOT/default-spawn" 2>"$TMP_ROOT/default-spawn.err" \
  || fail "disabled default-home spawn must succeed: $(<"$TMP_ROOT/default-spawn.err")"
[ -f "$DEFAULT_HOME/state/default-worker.meta" ] || fail 'default-home spawn must register its worker'
printf '%s 1\n' "${PROJECT##*/}" > "$DEFAULT_HOME/config/project-capacity"
fm_test_spawn_brief "$DEFAULT_HOME" deferred-worker
rc=0
run_default_spawn deferred-worker "$PROJECT" --scout --backend tmux \
  >"$TMP_ROOT/default-defer" 2>"$TMP_ROOT/default-defer.err" || rc=$?
[ "$rc" -eq 75 ] || fail "default-home capacity deferral must exit 75: $(<"$TMP_ROOT/default-defer.err")"
assert_not_contains "$(<"$TMP_ROOT/default-defer.err")" 'Discord admission receipt needs reconciliation' \
  'disabled default-home capacity hook must not warn'
assert_not_contains "$(<"$TMP_ROOT/default-defer.err")" 'Traceback' 'default-home capacity hook must not crash'
[ ! -e "$DEFAULT_HOME/state/deferred-worker.meta" ] || fail 'deferred worker must not launch'
pass 'Discord hook: unset FM_HOME preserves disabled default-home spawn and deferral'
