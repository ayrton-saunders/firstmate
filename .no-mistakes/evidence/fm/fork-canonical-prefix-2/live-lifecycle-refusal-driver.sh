#!/usr/bin/env bash
set -eu
ROOT=/Users/ayrton/.no-mistakes/worktrees/5611073f0314/01M5Q4KBXA4FE87Y7CZV7AG0QH
cd "$ROOT"
for v in ${!FM_@}; do unset "$v"; done
unset TMUX HERDR_SESSION HERDR_PRIMARY_WORKSPACE HERDR_PRIMARY_PANE RELAY_PRIMARY_WORKSPACE RELAY_PRIMARY_PANE || true
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
FM_HOME="$ROOT/.validation-tmp/lifecycle-home"
export FM_HOME
LAB_TMUX_DIR=
cleanup() {
  rc=$?
  trap - EXIT
  if [ -n "$LAB_TMUX_DIR" ]; then
    TMUX_TMPDIR="$LAB_TMUX_DIR" tmux -L fm-prefix2-refusal kill-server 2>/dev/null || true
    sleep 1
    "$LAB_HOME_HELPER" teardown "$FM_HOME" || rc=1
    if [ -e "$LAB_TMUX_DIR" ]; then echo 'FAIL private socket directory remains'; rc=1; else echo 'cleanup: exact private tmux server and socket directory removed'; fi
  fi
  rm -rf "$FM_HOME"
  echo "finished exit=$rc"
  exit "$rc"
}
trap cleanup EXIT
printf 'tested_head='; git rev-parse HEAD
"$LAB_HOME_HELPER" create "$FM_HOME"
LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$FM_HOME")
export TMUX_TMPDIR="$LAB_TMUX_DIR"
echo "private_socket_directory=$LAB_TMUX_DIR"
printf 'tmux\n' > "$FM_HOME/config/runtime-backend"
mkdir -p "$FM_HOME/agent" "$FM_HOME/pi-sessions"
PI_BIN=$(command -v pi)
# No discovered project code, tools, MCP, or plugins execute in this probe.
# Authentication and model selection remain the existing permitted profile.
printf '#!/usr/bin/env bash\nexec env -i HOME=%q USER=%q PATH=%q TERM=xterm-256color PI_OFFLINE=1 %q --no-approve --no-extensions --no-mcp --no-skills --no-prompt-templates --no-themes --no-context-files --no-tools --session-dir %q --model openai-codex/gpt-6.1-sol --thinking medium %q\n' "$HOME" "${USER:-ayrton}" "$PATH" "$PI_BIN" "$FM_HOME/pi-sessions" 'Reply only PREFIX2_REFUSAL_READY_71c9 then wait. Do not use tools.' > "$FM_HOME/launch.sh"
chmod 700 "$FM_HOME/launch.sh"
tmux -L fm-prefix2-refusal -f /dev/null new-session -d -s prefix2-refusal -n fm-prefix2mate -x 120 -y 40 -c "$FM_HOME/agent" "$FM_HOME/launch.sh"
ready=0
for ((i=0;i<90;i++)); do
  if rg -q '"role":"assistant".*PREFIX2_REFUSAL_READY_71c9' "$FM_HOME/pi-sessions"; then ready=1; break; fi
  sleep 1
done
if [ "$ready" != 1 ]; then
  echo 'BLOCKED: permitted Pi profile did not complete the nonce turn within 90 seconds'
  tmux -L fm-prefix2-refusal capture-pane -p -t prefix2-refusal:fm-prefix2mate || true
  exit 1
fi
echo 'PASS: real Pi agent completed nonce turn on permitted model and effort'
cat > "$FM_HOME/state/prefix2mate.meta" <<META
task=prefix2mate
kind=secondmate
harness=pi
model=openai-codex/gpt-6.1-sol
effort=medium
backend=tmux
window=prefix2-refusal:fm-prefix2mate
worktree=$FM_HOME/agent
project=$FM_HOME/agent
META
cp "$FM_HOME/state/prefix2mate.meta" "$FM_HOME/meta.before"
pid_before=$(tmux -L fm-prefix2-refusal display-message -p -t prefix2-refusal:fm-prefix2mate '#{pane_pid}')
kill -0 "$pid_before"
# Genuine unreadability, followed by malformed duplicate override: both must refuse.
for scenario in unreadable malformed; do
  printf 'mate prefix2mate: pi openai-codex/gpt-6.1-sol medium\n' > "$FM_HOME/config/secondmate-harness"
  if [ "$scenario" = unreadable ]; then chmod 000 "$FM_HOME/config/secondmate-harness"; else printf 'mate prefix2mate: pi\n' >> "$FM_HOME/config/secondmate-harness"; fi
  set +e
  "$ROOT/bin/fm-control.sh" prefix2mate relaunch > "$FM_HOME/control.out" 2>&1
  status=$?
  set -e
  chmod 600 "$FM_HOME/config/secondmate-harness"
  printf 'scenario=%s exit=%s\n' "$scenario" "$status"
  cat "$FM_HOME/control.out"
  [ "$status" != 0 ]
  grep -q 'configured secondmate runtime pin.*cannot be read' "$FM_HOME/control.out"
  cmp "$FM_HOME/meta.before" "$FM_HOME/state/prefix2mate.meta"
  [ ! -e "$FM_HOME/state/prefix2mate.control-relaunch" ]
  pid_after=$(tmux -L fm-prefix2-refusal display-message -p -t prefix2-refusal:fm-prefix2mate '#{pane_pid}')
  [ "$pid_before" = "$pid_after" ]; kill -0 "$pid_after"
  echo "PASS $scenario: refusal preceded stop; same live agent PID; metadata unchanged; no relaunch journal"
done
# A second real turn proves the surviving agent still accepts input.
tmux -L fm-prefix2-refusal send-keys -t prefix2-refusal:fm-prefix2mate -l 'Reply only PREFIX2_SURVIVED_823a'
tmux -L fm-prefix2-refusal send-keys -t prefix2-refusal:fm-prefix2mate Enter
for ((i=0;i<90;i++)); do
  if rg -q '"role":"assistant".*PREFIX2_SURVIVED_823a' "$FM_HOME/pi-sessions"; then echo 'PASS: same real agent answered after both refusals'; exit 0; fi
  sleep 1
done
echo 'FAIL: surviving agent did not complete follow-up turn'
exit 1
