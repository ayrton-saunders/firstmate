#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.hold-live.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
export HOME="$LAB/user" XDG_CONFIG_HOME="$LAB/user/.config"
export FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$ROOT"
export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" FM_CONFIG_OVERRIDE="$FM_HOME/config" FM_PROJECTS_OVERRIDE="$FM_HOME/projects"
mkdir -p "$HOME" "$FM_HOME"/{state,data,config,projects}
cp "$ROOT/.tasks.toml" "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
cli() { printf '\n$ fm-captain-hold.sh'; printf ' %q' "$@"; printf '\n'; bash "$ROOT/bin/fm-captain-hold.sh" "$@"; }
tasks() { (cd "$FM_HOME" && tasks-axi "$@"); }
refuse() {
  cp "$FM_HOME/data/backlog.md" "$LAB/before"
  set +e
  cli "$@" > "$LAB/output" 2>&1
  rc=$?
  set -e
  while IFS= read -r line; do printf '%s\n' "$line"; done < "$LAB/output"
  printf 'exit=%s\n' "$rc"
  test "$rc" -ne 0
  cmp "$LAB/before" "$FM_HOME/data/backlog.md"
  printf 'Backlog byte-for-byte unchanged.\n'
}
show() { printf '\n$ tasks-axi show %s --full\n' "$1"; tasks show "$1" --full; }
printf 'REAL CLI + tasks-axi %s; synthetic isolated markdown home\n' "$(tasks-axi --version)"
tasks add existing 'Existing decision' --repo sample >/dev/null
printf '\n=== 1. Invalid holds refuse without changing the backlog ===\n'
refuse hold new-call --title 'New decision' --reason 'Awaiting a choice'
grep -q -- '--until YYYY-MM-DD' "$LAB/output"
grep -q -- '--open-ended' "$LAB/output"
refuse hold existing --reason 'Awaiting a choice'
refuse hold existing --reason 'Awaiting a choice' --until ''
refuse hold existing --reason 'Awaiting a choice' --until
refuse hold existing --reason 'Awaiting a choice' --until tomorrow
refuse hold existing --reason 'Awaiting a choice' --until 2099-01-01 --open-ended
refuse hold existing --open-ended
refuse hold existing --open-ended --reason $' \t\n'
printf '\n=== 2. Explicit modes persist dates and reasons; unsafe re-hold refuses ===\n'
cli hold new-call --title 'New decision' --open-ended --reason 'Awaiting a choice with no known deadline'
show new-call | tee "$LAB/shown"
grep -q 'hold_kind: captain' "$LAB/shown"
grep -q 'hold_until: "-"' "$LAB/shown"
python3 - "$LAB/shown" <<'PY'
import base64, pathlib, re, sys
shown = pathlib.Path(sys.argv[1]).read_text()
encoded = re.search(r'hold_reason: "fm-hold-v1:([^"]+)"', shown).group(1)
assert base64.b64decode(encoded).decode() == 'Awaiting a choice with no known deadline'
print('Persisted reason independently base64-decoded: Awaiting a choice with no known deadline')
PY
cli hold existing --until 2099-01-01 --reason 'Revisit on the agreed date'
show existing | tee "$LAB/shown"
grep -q 'hold_until: 2099-01-01' "$LAB/shown"
refuse hold existing --reason 'Unintentional removal of the date'
cli hold existing --open-ended --reason 'External approval has no known deadline'
show existing | tee "$LAB/shown"
grep -q 'hold_until: "-"' "$LAB/shown"
printf '\n=== 3. Legacy wrapper enforces same guard and forwards explicit choice ===\n'
cp "$FM_HOME/data/backlog.md" "$LAB/before"
printf '\n$ fm-decision-hold.sh hold legacy-origin pick --title Legacy --reason Waiting\n'
set +e
bash "$ROOT/bin/fm-decision-hold.sh" hold legacy-origin pick --title Legacy --reason Waiting > "$LAB/output" 2>&1
rc=$?
set -e
while IFS= read -r line; do printf '%s\n' "$line"; done < "$LAB/output"
printf 'exit=%s\n' "$rc"
test "$rc" -ne 0
grep -q -- '--open-ended' "$LAB/output"
cmp "$LAB/before" "$FM_HOME/data/backlog.md"
printf 'Backlog byte-for-byte unchanged.\n'
printf '\n$ fm-decision-hold.sh hold legacy-origin pick --title Legacy --open-ended --reason "Approval has no deadline"\n'
bash "$ROOT/bin/fm-decision-hold.sh" hold legacy-origin pick --title Legacy --open-ended --reason 'Approval has no deadline'
show legacy-origin-decision-pick | tee "$LAB/shown"
grep -q 'hold_kind: captain' "$LAB/shown"
printf '\n=== 4. Historical undated row remains discoverable and answerable without migration ===\n'
tasks add legacy-call 'Historical undated decision' --repo sample >/dev/null
tasks hold legacy-call --kind captain --reason 'Awaiting a historical choice' >/dev/null
show legacy-call
printf '\n$ fm-tasks-axi.sh list --state held --fields held,hold_kind,hold_until\n'
bash "$ROOT/bin/fm-tasks-axi.sh" list --state held --fields held,hold_kind,hold_until
cli open legacy-call
printf 'Proceed with the rollout.\n' > "$LAB/answer.txt"
cli answer legacy-call --decision-file "$LAB/answer.txt"
show legacy-call | tee "$LAB/shown"
grep -q 'state: done' "$LAB/shown"
grep -q 'Proceed with the rollout.' "$LAB/shown"
printf '\nAll four live scenario groups completed successfully. Disposable home removed on exit.\n'
