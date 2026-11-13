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
printf '%s\n' '{private-malformed-config' > "$HOME_FIXTURE/config/discord-integration.json"
for operation in send spawn capacity-deferred outcome ready confirm-send; do
  if FM_HOME="$HOME_FIXTURE" python3 -I "$HOOK" "$operation" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
    fail 'malformed JSON must refuse'
  fi
  assert_contains "$(<"$TMP_ROOT/err")" "Discord $operation configuration or authority validation check failed" \
    'fallback must name the operation and failed validation'
  assert_not_contains "$(<"$TMP_ROOT/err")" 'private-malformed-config' 'fallback must not expose exception text'
  assert_not_contains "$(<"$TMP_ROOT/err")" "$HOME_FIXTURE" 'fallback must not expose paths'
done

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
# Enrolled layout: <code>/current is a relative symlink the private self-updater
# switches between releases under <code>/releases.
CODE="$TMP_ROOT/code"
PACKAGE="$CODE/releases/r1"
mkdir -p "$MAPPED_HOME/config" "$MAPPED_HOME/state" "$PACKAGE/personal_discord" "$TMP_ROOT/send-tools"
printf '' > "$PACKAGE/personal_discord/__init__.py"
cat > "$PACKAGE/personal_discord/integration.py" <<'PY'
import os
from pathlib import Path
class Integration:
    @staticmethod
    def identify_source(source):
        marker = os.environ.get('FM_TEST_DISCORD_IDENTITY_MARKER')
        if marker:
            Path(marker).write_text('identified')
        return {'source_commit': 'a' * 40, 'source_digest': 'b' * 64}
PY
cat > "$PACKAGE/personal_discord/journal.py" <<'PY'
from pathlib import Path
class Journal:
    def __init__(self, path):
        self.path = Path(path)
        self.path.write_text('opened')
    def record(self, family, permit):
        if permit == '1' * 32:
            return dict(operation='instruction', project='fixture', target='mapped')
        raise ValueError('Unknown fixture permit')
    def close(self):
        pass
PY
cat > "$PACKAGE/personal_discord/routing.py" <<'PY'
from pathlib import Path
class Routing:
    def __init__(self, journal):
        self.journal = journal
    def consume(self, *args, **kwargs):
        self.journal.path.with_suffix('.consumed').write_text('consumed')
    def confirm(self, *args, **kwargs):
        # Records the directory this module was imported from, unresolved.
        self.journal.path.with_suffix('.confirmed').write_text(str(Path(__file__).parent.parent))
PY
ln -s releases/r1 "$CODE/current"
"$PY314" - "$MAPPED_HOME" "$CODE" "$ROOT" "$PY314" <<'PY'
import json, sys
from pathlib import Path
home, code, source, interpreter = map(lambda p: Path(p).resolve(), sys.argv[1:])
# The cutover keeps the retired per-module hashes map; it must be ignored, even stale.
config = dict(schema=2, enabled=True, home=str(home), package_root=str(code / 'current'),
              hashes={'personal_discord/retired.py': '0' * 64},
              journal=str(home / 'journal'), routes=[dict(target='mapped', project='fixture')],
              projects={'fixture': str(source)}, python_executable=str(interpreter),
              source=str(source), source_commit='a' * 40, source_digest='b' * 64)
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


cp "$MAPPED_HOME/config/discord-integration.json" "$TMP_ROOT/current-config.json"
"$PY314" - "$MAPPED_HOME/config/discord-integration.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
config = json.loads(path.read_text())
config.update(source_commit='stale-commit', source_digest='stale-digest')
path.write_text(json.dumps(config))
PY
fm_write_meta "$MAPPED_HOME/state/unmapped.meta" 'window=sess:fm-unmapped' 'backend=tmux' 'harness=pi' 'kind=ship' 'spawn_gen=fixture-gen'
for lane in ordinary typed; do
  lane_env=(-u FM_DISCORD_AUTH)
  [ "$lane" != typed ] || lane_env=(FM_DISCORD_AUTH=00000000000000000000000000000000)
  for target in unmapped mapped; do
    rm -f "$TMP_ROOT/identity-marker"
    rc=0
    env "${lane_env[@]}" PATH="$TMP_ROOT/send-tools:$PATH" FM_HOME="$MAPPED_HOME" \
      FM_ROOT_OVERRIDE="$MAPPED_HOME" FM_SEND_SETTLE=0 \
      FM_TEST_DISCORD_IDENTITY_MARKER="$TMP_ROOT/identity-marker" \
      bash "$ROOT/bin/fm-send.sh" "$target" 'stale pin steer' \
      >"$TMP_ROOT/stale.out" 2>"$TMP_ROOT/stale.err" || rc=$?
    if [ "$target" = unmapped ] || [ "$lane" = ordinary ]; then
      [ "$rc" -eq 0 ] || fail "stale parent pin must not fence $target $lane steer: $(<"$TMP_ROOT/stale.err")"
      [ ! -e "$TMP_ROOT/identity-marker" ] || fail 'ordinary steer must not identify the parent source'
      assert_not_contains "$(<"$TMP_ROOT/stale.err")" 'Discord lane fenced' 'ordinary steer must not report a Discord fence'
      assert_not_contains "$(<"$TMP_ROOT/stale.err")" 'Discord parent routing guard refused' 'ordinary steer must not report a Discord guard refusal'
    else
      [ "$rc" -ne 0 ] || fail 'unknown permit must still refuse mapped Discord steer'
      [ ! -e "$TMP_ROOT/identity-marker" ] || fail 'Discord steer must not identify parent source'
      [ -f "$MAPPED_HOME/journal" ] || fail 'stale source information must allow permit lookup'
      assert_not_contains "$(<"$TMP_ROOT/stale.err")" 'stale pin steer' 'refusal must not echo payload'
      rm "$MAPPED_HOME/journal"
    fi
  done
done
[ "$(find "$MAPPED_HOME/state/unmapped.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" -eq 2 ] || fail 'all unmapped steers must be durable'
assert_contains "$(<"$MAPPED_HOME/state/mapped.inbox/002.msg")" 'stale pin steer' 'mapped ordinary steer must be durable despite stale pins'
[ ! -e "$MAPPED_HOME/state/mapped.inbox/003.msg" ] || fail 'unknown permit sends must not deliver'
[ ! -e "$MAPPED_HOME/journal" ] || fail 'fixture journal must be closed and removed'
cp "$TMP_ROOT/current-config.json" "$MAPPED_HOME/config/discord-integration.json"
pass 'Discord hook: stale source information does not fence permit lookup or local supervision'

for form in present stale absent; do
  cp "$TMP_ROOT/current-config.json" "$MAPPED_HOME/config/discord-integration.json"
  "$PY314" - "$MAPPED_HOME/config/discord-integration.json" "$form" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
config = json.loads(path.read_text())
if sys.argv[2] == 'stale':
    config.update(source='/not/the/invoked/source', source_commit='old', source_digest='old')
elif sys.argv[2] == 'absent':
    config.pop('source_commit')
    config.pop('source_digest')
path.write_text(json.dumps(config))
PY
  env FM_DISCORD_AUTH=11111111111111111111111111111111 PATH="$TMP_ROOT/send-tools:$PATH" \
    FM_HOME="$MAPPED_HOME" FM_ROOT_OVERRIDE="$MAPPED_HOME" FM_SEND_SETTLE=0 \
    FM_TEST_DISCORD_IDENTITY_MARKER="$TMP_ROOT/identity-marker" \
    bash "$ROOT/bin/fm-send.sh" mapped "source information $form" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" \
    || fail "typed send with $form source information must deliver: $(<"$TMP_ROOT/err")"
  [ -f "$MAPPED_HOME/journal.consumed" ] || fail 'typed send must consume its permit'
  [ -f "$MAPPED_HOME/journal.confirmed" ] || fail 'typed send must confirm its durable delivery'
  [ ! -e "$TMP_ROOT/identity-marker" ] || fail 'source information must never be compared'
  grep -q "source information $form" "$MAPPED_HOME/state/mapped.inbox/"*.msg || fail 'typed steer must reach inbox'
  rm "$MAPPED_HOME/journal" "$MAPPED_HOME/journal.consumed" "$MAPPED_HOME/journal.confirmed"
done
cp "$TMP_ROOT/current-config.json" "$MAPPED_HOME/config/discord-integration.json"
pass 'Discord hook: actual typed delivery accepts present, stale and absent source status fields'

for check in home schema; do
  "$PY314" - "$MAPPED_HOME/config/discord-integration.json" "$check" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
config = json.loads(path.read_text())
config[sys.argv[2]] = {'home': '/another/home', 'schema': 1}[sys.argv[2]]
path.write_text(json.dumps(config))
PY
  if FM_HOME="$MAPPED_HOME" python3 -I "$HOOK" ready >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
    fail "$check protection must refuse"
  fi
  assert_contains "$(<"$TMP_ROOT/err")" 'Integration schema/home mismatch' 'refusal must name the concrete failed check'
  [ ! -e "$MAPPED_HOME/journal" ] || fail 'invalid home/schema must not open journal'
  cp "$TMP_ROOT/current-config.json" "$MAPPED_HOME/config/discord-integration.json"
done
pass 'Discord hook: home/schema binding still refuses by check name'

# package_root forms. Accepted forms must import the resolved release and deliver
# a typed send; refused forms must name the check and never open the journal.
mkdir -p "$CODE/releases/r2" "$TMP_ROOT/outside"
cp -R "$PACKAGE/personal_discord" "$CODE/releases/r2/"
cp -R "$PACKAGE" "$TMP_ROOT/outside/release"
ln -s ../outside/release "$CODE/escape"
ln -s releases/missing "$CODE/dangling"
ln -s "$CODE/releases/r1" "$TMP_ROOT/outside/hop"
ln -s ../outside/hop "$CODE/chain"
ln -s .. "$CODE/releases/up"
ln -s releases/up "$CODE/tree"
ln -s ../outside/via "$CODE/via"
ln -s "$CODE/releases" "$TMP_ROOT/outside/via"
ln -s via/r1 "$CODE/intermediate"
for form in plain switched escape dangling chain tree intermediate dotdot; do
  cp "$TMP_ROOT/current-config.json" "$MAPPED_HOME/config/discord-integration.json"
  [ "$form" != switched ] || ln -sfn releases/r2 "$CODE/current"
  "$PY314" - "$MAPPED_HOME/config/discord-integration.json" "$CODE" "$form" <<'PY'
import json, sys
from pathlib import Path
path, code, form = Path(sys.argv[1]), Path(sys.argv[2]).resolve(), sys.argv[3]
config = json.loads(path.read_text())
config['package_root'] = {'plain': str(code / 'releases/r1'), 'switched': str(code / 'current'),
                          'dotdot': str(code / 'releases/missing') + '/../r1'}.get(form, str(code / form))
path.write_text(json.dumps(config))
PY
  case "$form" in
    plain|switched)
      env FM_DISCORD_AUTH=11111111111111111111111111111111 PATH="$TMP_ROOT/send-tools:$PATH" \
        FM_HOME="$MAPPED_HOME" FM_ROOT_OVERRIDE="$MAPPED_HOME" FM_SEND_SETTLE=0 \
        bash "$ROOT/bin/fm-send.sh" mapped "package root $form" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" \
        || fail "typed send with $form package root must deliver: $(<"$TMP_ROOT/err")"
      expected=$(cd "$CODE/releases/r1" && pwd -P)
      [ "$form" != switched ] || expected=$(cd "$CODE/releases/r2" && pwd -P)
      [ "$(<"$MAPPED_HOME/journal.confirmed")" = "$expected" ] \
        || fail "$form package root must import from the resolved release, not the symlink"
      grep -q "package root $form" "$MAPPED_HOME/state/mapped.inbox/"*.msg || fail "$form steer must reach inbox"
      rm "$MAPPED_HOME/journal" "$MAPPED_HOME/journal.consumed" "$MAPPED_HOME/journal.confirmed"
      ;;
    *)
      if FM_HOME="$MAPPED_HOME" python3 -I "$HOOK" ready >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
        fail "$form package root must refuse"
      fi
      assert_contains "$(<"$TMP_ROOT/err")" 'canonical release inside the enrolled code tree' "$form refusal must name the check"
      [ ! -e "$MAPPED_HOME/journal" ] || fail "$form package root must not open journal"
      ;;
  esac
done
ln -sfn releases/r1 "$CODE/current"
cp "$TMP_ROOT/current-config.json" "$MAPPED_HOME/config/discord-integration.json"
pass 'Discord hook: package root accepts plain and switched enrolled releases, refuses escaping, dangling, tree-leaving and non-canonical roots'

mapped_hook() {
  FM_HOME="$MAPPED_HOME" python3 -I "$HOOK" "$@"
}
receipt="$MAPPED_HOME/state/mapped.inbox/001.msg"
for delivery in local remote; do
  if printf 'private confirmation payload' | env -u FM_DISCORD_AUTH FM_HOME="$MAPPED_HOME" python3 -I "$HOOK" confirm-send "$delivery" "$receipt" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
    fail 'permit-free confirmation must refuse'
  fi
  [ ! -s "$TMP_ROOT/out" ] || fail 'refused confirmation must not emit output'
  [ "$(<"$TMP_ROOT/err")" = 'error: Mapped routing requires a typed parent-issued lane permit' ] \
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
assert_contains "$(<"$TMP_ROOT/err")" 'Route permit lookup failed' 'unknown permit must name its failed check'
[ -f "$MAPPED_HOME/journal" ] || fail 'well-formed permit must undergo journal lookup'
[ ! -e "$MAPPED_HOME/journal.consumed" ] || fail 'unknown permit must not be consumed'
rm "$MAPPED_HOME/journal"
pass 'Discord hook: Discord lane missing, malformed and unknown permits refuse before consume'
for delivery in local remote; do
  if FM_DISCORD_AUTH=00000000000000000000000000000000 mapped_hook confirm-send "$delivery" "$receipt" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
    fail 'confirmation with unknown permit must refuse'
  fi
  [ "$(<"$TMP_ROOT/err")" = 'error: Route permit lookup failed' ] || fail 'confirmation must name lookup without private exception text'
  [ ! -e "$MAPPED_HOME/journal.confirmed" ] || fail 'unknown permit must not confirm delivery'
  rm "$MAPPED_HOME/journal"
done

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
