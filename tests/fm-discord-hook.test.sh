#!/usr/bin/env bash
# Optional private Discord lane hook: legacy compatibility and safe rejection.
# Full pinned-private-release integration is tested in that release's test suite.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-discord-hook)
trap 'rm -r "$TMP_ROOT"' EXIT
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
