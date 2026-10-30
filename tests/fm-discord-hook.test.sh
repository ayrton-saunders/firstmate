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

# Enabled mapped delivery uses a pinned, inert private-package fixture, never a
# live Discord package/config. A journal marker detects even an accidental open.
PY314=$(command -v python3.14 || true)
if [ -z "$PY314" ]; then
  printf 'SKIP: enabled Discord hook fixture requires CPython 3.14\n'
  exit 0
fi
MAPPED_HOME="$TMP_ROOT/mapped-home"
PACKAGE="$TMP_ROOT/package"
mkdir -p "$MAPPED_HOME/config" "$MAPPED_HOME/state" "$PACKAGE/personal_discord" "$TMP_ROOT/send-tools"
printf '' > "$PACKAGE/personal_discord/__init__.py"
cat > "$PACKAGE/personal_discord/integration.py" <<'PY'
class Integration:
    @staticmethod
    def identify_source(source):
        return {'source_commit': 'fixture', 'source_digest': 'fixture'}
PY
cat > "$PACKAGE/personal_discord/journal.py" <<'PY'
from pathlib import Path
class Journal:
    def __init__(self, path):
        self.path = Path(path)
        self.path.write_text('opened')
    def record(self, family, permit):
        raise ValueError('Unknown fixture permit')
    def close(self):
        pass
PY
cat > "$PACKAGE/personal_discord/routing.py" <<'PY'
class Routing:
    def __init__(self, journal):
        self.journal = journal
    def consume(self, *args, **kwargs):
        self.journal.path.with_suffix('.consumed').write_text('consumed')
        raise ValueError('Fixture must never consume')
    def confirm(self, *args, **kwargs):
        raise ValueError('Fixture must never confirm')
PY
"$PY314" - "$MAPPED_HOME" "$PACKAGE" "$ROOT" "$PY314" <<'PY'
import hashlib, json, sys
from pathlib import Path
home, package, source, interpreter = map(lambda p: Path(p).resolve(), sys.argv[1:])
config = dict(schema=2, enabled=True, home=str(home), package_root=str(package),
              hashes={str(p.relative_to(package)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in (package / 'personal_discord').glob('*.py')},
              journal=str(home / 'journal'), routes=[dict(target='mapped', project='fixture')],
              projects={'fixture': str(source)}, python_executable=str(interpreter),
              source=str(source), source_commit='fixture', source_digest='fixture')
(home / 'config/discord-integration.json').write_text(json.dumps(config))
PY
cat > "$TMP_ROOT/send-tools/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'ordinary prompt\n' ;;
  send-keys) : ;;
esac
SH
chmod +x "$TMP_ROOT/send-tools/tmux"
fm_write_meta "$MAPPED_HOME/state/mapped.meta" 'window=sess:fm-mapped' 'backend=tmux' 'harness=pi' 'kind=ship' 'spawn_gen=fixture-gen'
run_mapped_send() {
  env -u FM_DISCORD_AUTH PATH="$TMP_ROOT/send-tools:$PATH" FM_HOME="$MAPPED_HOME" \
    FM_ROOT_OVERRIDE="$MAPPED_HOME" FM_SEND_SETTLE=0 \
    bash "$ROOT/bin/fm-send.sh" mapped 'local supervisory text'
}
run_mapped_send >"$TMP_ROOT/mapped.out" 2>"$TMP_ROOT/mapped.err" \
  || fail "mapped local send must succeed: $(<"$TMP_ROOT/mapped.err")"
assert_contains "$(<"$MAPPED_HOME/state/mapped.inbox/001.msg")" 'local supervisory text' 'mapped local send must reach durable inbox'
assert_not_contains "$(<"$TMP_ROOT/mapped.err")" 'reconcile its receipt' 'mapped local send must not report confirmation failure'
[ ! -e "$MAPPED_HOME/journal" ] || fail 'local send must not open journal'
[ ! -e "$MAPPED_HOME/journal.consumed" ] || fail 'local send must not consume a permit'
pass 'Discord hook: mapped local supervisory send delivers without a journal or permit'

mapped_hook() {
  FM_HOME="$MAPPED_HOME" python3 -I "$HOOK" "$@"
}
receipt="$MAPPED_HOME/state/mapped.inbox/001.msg"
for delivery in local remote; do
  if printf 'private confirmation payload' | env -u FM_DISCORD_AUTH FM_HOME="$MAPPED_HOME" python3 -I "$HOOK" confirm-send "$delivery" "$receipt" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
    fail 'permit-free confirmation must refuse'
  fi
  [ ! -s "$TMP_ROOT/out" ] || fail 'refused confirmation must not emit output'
  [ "$(<"$TMP_ROOT/err")" = 'error: Discord parent routing guard refused: ValueError; verify the configured mapping and current typed lane permit' ] \
    || fail 'confirmation refusal must use a fixed category without payload or path'
  [ ! -e "$MAPPED_HOME/journal" ] || fail 'permit-free confirmation must not open journal'
done
pass 'Discord hook: permit-free confirmation refuses before journal access without disclosing payload or path'

# Presence identifies the Discord lane even when the supplied credential is
# empty (missing token) or malformed. It must never fall back to local authority.
for permit in '' invalid; do
  if printf 'private lane text' | FM_DISCORD_AUTH="$permit" mapped_hook send mapped sess:fm-mapped "$MAPPED_HOME/state/mapped.meta" tmux >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
    fail 'Discord lane with missing/invalid permit must refuse'
  fi
  assert_not_contains "$(<"$TMP_ROOT/err")" 'private lane text' 'refusal must not echo payload'
  [ ! -e "$MAPPED_HOME/journal" ] || fail 'malformed permit must refuse before journal access'
done
if printf 'private lane text' | FM_DISCORD_AUTH=00000000000000000000000000000000 mapped_hook send mapped sess:fm-mapped "$MAPPED_HOME/state/mapped.meta" tmux >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail 'unknown well-formed permit must refuse'
fi
[ -f "$MAPPED_HOME/journal" ] || fail 'well-formed permit must undergo journal lookup'
[ ! -e "$MAPPED_HOME/journal.consumed" ] || fail 'unknown permit must not be consumed'
rm "$MAPPED_HOME/journal"
pass 'Discord hook: Discord lane missing, malformed and unknown permits refuse before consume'

for payload in '/native' 'ordinary'; do
  metadata="$MAPPED_HOME/state/mapped.meta"
  [ "$payload" != ordinary ] || metadata=''
  if printf '%s' "$payload" | env -u FM_DISCORD_AUTH FM_HOME="$MAPPED_HOME" python3 -I "$HOOK" send mapped sess:fm-mapped "$metadata" tmux >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
    fail 'parser-native invocation and explicit-terminal metadata bypass must refuse'
  fi
done
if printf 'ordinary' | env -u FM_DISCORD_AUTH FM_HOME="$MAPPED_HOME" FM_SEND_EXPECTED_SPAWN_GEN=other python3 -I "$HOOK" send mapped sess:fm-mapped "$MAPPED_HOME/state/mapped.meta" tmux >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail 'local send must retain caller generation fence'
fi
[ ! -e "$MAPPED_HOME/journal" ] || fail 'local safety refusals must not open journal'
pass 'Discord hook: local sends retain parser, metadata and generation protections'

for generation in '' 'bad|generation'; do
  fm_write_meta "$MAPPED_HOME/state/mapped.meta" 'window=sess:fm-mapped' 'backend=tmux' 'harness=pi' "spawn_gen=$generation"
  if printf 'ordinary' | env -u FM_DISCORD_AUTH FM_HOME="$MAPPED_HOME" python3 -I "$HOOK" send mapped sess:fm-mapped "$MAPPED_HOME/state/mapped.meta" tmux >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
    fail 'missing or malformed local endpoint generation must refuse'
  fi
done
fm_write_meta "$MAPPED_HOME/state/mapped.meta" 'window=sess:fm-mapped' 'backend=tmux' 'harness=codex' 'spawn_gen=fixture-gen'
if printf '\044native' | env -u FM_DISCORD_AUTH FM_HOME="$MAPPED_HOME" python3 -I "$HOOK" send mapped sess:fm-mapped "$MAPPED_HOME/state/mapped.meta" tmux >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail 'Codex parser-native invocation must refuse'
fi
if python3 -c 'print("x" * 24577, end="")' | env -u FM_DISCORD_AUTH FM_HOME="$MAPPED_HOME" python3 -I "$HOOK" send mapped sess:fm-mapped "$MAPPED_HOME/state/mapped.meta" tmux >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail 'oversize local payload must refuse'
fi
if printf 'ordinary' | env -u FM_DISCORD_AUTH FM_HOME="$MAPPED_HOME" python3 -I "$HOOK" send mapped remote:mapped "$MAPPED_HOME/state/mapped.meta" remote >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail 'permit-free local authority must not extend to remote sends'
fi
mv "$MAPPED_HOME/state/mapped.inbox" "$MAPPED_HOME/state/saved-inbox"
printf 'not an inbox directory' > "$MAPPED_HOME/state/mapped.inbox"
if run_mapped_send >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail 'genuinely failed local inbox delivery must not report success'
fi
[ ! -e "$MAPPED_HOME/journal" ] || fail 'local safety checks must not access journal'
[ ! -e "$MAPPED_HOME/journal.consumed" ] || fail 'local safety checks must not consume permits'
pass 'Discord hook: bounded local authority retains lifecycle, payload and delivery failure checks'
