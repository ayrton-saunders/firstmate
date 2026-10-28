#!/usr/bin/env bash
set -eu
ROOT=$PWD
export FM_HERDR_LAB_STATE_DIR="$ROOT/.test-tmp/lab-state"
HELPER="$ROOT/bin/fm-herdr-lab.sh"
export HELPER ORIGINAL_PATH="$PATH"
SESSION=$("$HELPER" name fixture-compare)
export SESSION
mkdir -p "$ROOT/.test-tmp/probe-bin" "$ROOT/.test-tmp/probe-state"
cleanup() { env PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION"; }
"$HELPER" provision "$SESSION"
trap cleanup EXIT
cat > "$ROOT/.test-tmp/probe-bin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[n-2]}" = --session ] && [ "${args[n-1]}" = "$SESSION" ]; then
  unset 'args[n-1]' 'args[n-2]'
fi
exec env PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "${args[@]}"
SH
chmod +x "$ROOT/.test-tmp/probe-bin/herdr"
export PATH="$ROOT/.test-tmp/probe-bin:$PATH"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
. "$ROOT/bin/backends/herdr.sh"
lab() { env PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "$@"; }
token=$(fm_backend_herdr_projection_journal_create "$ROOT/.test-tmp/probe-state" duplicate1)
journal=$(fm_backend_herdr_projection_journal_path "$ROOT/.test-tmp/probe-state" duplicate1)
a=$(lab workspace create --cwd "$ROOT" --label "firstmate/duplicate1 · p:$token" --no-focus)
b=$(lab workspace create --cwd "$ROOT" --label "copy/duplicate1 · p:$token" --no-focus)
pane=$(printf '%s' "$a" | jq -r .result.root_pane.pane_id)
ws1=$(printf '%s' "$a" | jq -r .result.workspace.workspace_id)
ws2=$(printf '%s' "$b" | jq -r .result.workspace.workspace_id)
echo 'BASELINE: register test-agent over a bare shell (original fixture)'
lab pane report-agent "$pane" --source fm-projection-e2e --agent test-agent --state idle
if fm_backend_herdr_projection_recovery_allows_flat "$SESSION" "$journal" duplicate1; then
  echo 'BASELINE REPRODUCED: fallback allowed; original duplicate-agent refusal assertion would fail'
else
  echo 'BASELINE DID NOT REPRODUCE on this sample: fallback refused'
fi
lab agent get "$pane" || true
echo 'FIXED: start a real foreground sleep, then register the same test-agent'
fm_backend_herdr_send_text_line "$SESSION:$pane" 'sleep 900'
ready=0
for i in {1..50}; do
  state=$(fm_backend_herdr_pane_process_state "$SESSION" "$pane")
  if [ "$state" = other ]; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" -eq 1 ]
lab pane process-info --pane "$pane"
lab pane report-agent "$pane" --source fm-projection-e2e --agent test-agent --state idle
state=$(fm_backend_herdr_pane_agent_state "$SESSION" "$pane")
printf 'Classification with foreground process: %s\n' "$state"
[ "$state" = live ]
if fm_backend_herdr_projection_recovery_allows_flat "$SESSION" "$journal" duplicate1; then
  echo 'ERROR: duplicate live-agent launch allowed'; exit 1
fi
echo 'FIXED VERIFIED: duplicate launch refused'
lab workspace get "$ws1"
lab workspace get "$ws2"
echo 'Both quarantined workspaces remain present'
