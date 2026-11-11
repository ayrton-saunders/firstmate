#!/usr/bin/env bash
# Freeze the no-enrollment teardown -> orphan-cleanup integration using only
# a recorded reaper stub and fake backend, never a real sweep/backend/pool call.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset FM_PUBLIC_FOLLOWUP_PRIMARY_HOME
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SUBJECT=${FM_CHARACTERIZATION_ROOT:-$ROOT}
TMP_ROOT=$(fm_test_tmproot fm-remote-legacy-cleanup)
mkdir -p "$TMP_ROOT/code" "$TMP_ROOT/home/state" "$TMP_ROOT/home/data/legacy" \
  "$TMP_ROOT/home/config" "$TMP_ROOT/tools"
trap fm_test_cleanup EXIT
# Copy implementation bytes into a fixture directory, not another Git checkout.
# The fixture has no .git and never creates, adopts or removes a pool slot.
cp -R "$SUBJECT/bin" "$TMP_ROOT/code/bin"
cat > "$TMP_ROOT/code/bin/fm-remote-job-reap-orphans.sh" <<'SH'
#!/usr/bin/env bash
printf 'orphan-reap\n' >> "$CLEANUP_EFFECTS"
SH
chmod +x "$TMP_ROOT/code/bin/fm-remote-job-reap-orphans.sh"
# Catch every external lifecycle surface, including tools installed locally.
# A missing fixture worktree and recorded fake endpoint must touch no real tool.
for tool in tmux treehouse herdr rex orca launchctl no-mistakes gh gh-axi tasks-axi lsof; do
  cat > "$TMP_ROOT/tools/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${0##*/} $*" >> "$CLEANUP_EXTERNAL"
exit 1
SH
  chmod +x "$TMP_ROOT/tools/$tool"
done
cat > "$TMP_ROOT/tools/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "tmux $*" >> "$CLEANUP_EXTERNAL"
[ "$*" = 'kill-window -t =fixture:=fm-legacy' ]
SH
printf 'manual\n' > "$TMP_ROOT/home/config/backlog-backend"
printf 'fixture report\n' > "$TMP_ROOT/home/data/legacy/report.md"
printf '%s\n' 'kind=ship' 'mode=local-only' "worktree=$TMP_ROOT/already-absent" \
  "project=$TMP_ROOT/project" 'backend=tmux' 'window=fixture:fm-legacy' \
  'endpoint_task_id=legacy' 'spawn_gen=fixture-legacy' > "$TMP_ROOT/home/state/legacy.meta"
printf 'done: fixture report\n' > "$TMP_ROOT/home/state/legacy.status"
touch "$TMP_ROOT/home/state/.last-watcher-beat"
export CLEANUP_EFFECTS="$TMP_ROOT/effects" CLEANUP_EXTERNAL="$TMP_ROOT/external"
: > "$CLEANUP_EFFECTS"
: > "$CLEANUP_EXTERNAL"
if ! HOME="$TMP_ROOT/home" FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$TMP_ROOT/code" \
  FM_STATE_OVERRIDE="$TMP_ROOT/home/state" FM_DATA_OVERRIDE="$TMP_ROOT/home/data" \
  FM_CONFIG_OVERRIDE="$TMP_ROOT/home/config" PATH="$TMP_ROOT/tools:$PATH" \
  bash "$TMP_ROOT/code/bin/fm-teardown.sh" legacy > "$TMP_ROOT/out" 2>&1; then
  cat "$TMP_ROOT/out"
  fail "legacy fixture cleanup failed"
fi
printf 'orphan-reap\n' > "$TMP_ROOT/expected"
diff -u "$TMP_ROOT/expected" "$CLEANUP_EFFECTS" || fail "no-enrollment cleanup stopped invoking the orphan reaper"
printf 'tmux kill-window -t =fixture:=fm-legacy\n' > "$TMP_ROOT/external.expected"
diff -u "$TMP_ROOT/external.expected" "$CLEANUP_EXTERNAL" || fail "legacy cleanup external call footprint changed"
assert_absent "$TMP_ROOT/home/state/legacy.meta" "cleanup retained its fixture task record"
assert_present "$TMP_ROOT/home/data/legacy/report.md" "cleanup discarded retained task evidence"
pass "no-enrollment teardown still invokes orphan cleanup exactly once without a new installation"
