#!/usr/bin/env bash
# Token-free vendor-rendering guard: the installed Claude Code receives a
# synthetic refusal from loopback for 'say hi'. No login or model call occurs.
# Other harnesses have no verified safeguard banner and are not classified.
# The CLI runs in print mode and an interactive private tmux server, never a
# shared server. Its own rendered error prefix must survive pane classification.
# FM_CLAUDE_SAFEGUARD_LIVE=1 (or FM_LIVE=1) requires Claude, python3, and tmux;
# =0 skips. A changed Claude renderer fails with its version, never silently.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CLAUDE_SAFEGUARD_LIVE claude python3 tmux
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-s) || fail 'cannot allocate fixture scratch'
version=$(claude --version 2>/dev/null | head -n 1)
server_pid=''
tmux_socket=''
TMUX_RETAIN=
stop_server() {
  local teardown=0
  fm_test_stop_private_tmux "$tmux_socket" tmux "$TMUX_RETAIN" || teardown=1
  tmux_socket=''
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
  server_pid=''
  return "$teardown"
}
trap 'status=$?; if stop_server; then fm_test_cleanup; elif [ "$status" -eq 0 ]; then status=1; fi; exit "$status"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT
for category in cyber none; do
  python3 "$ROOT/tests/fixtures/fm-claude-refusal.py" "$TMP_ROOT/$category.port" "$category" &
  server_pid=$!
  for ((i=0; i<100; i++)); do
    [ ! -s "$TMP_ROOT/$category.port" ] || break
    sleep 0.1
  done
  [ -s "$TMP_ROOT/$category.port" ] || fail "Claude $version: loopback refusal server did not start"
  port=$(cat "$TMP_ROOT/$category.port")
  rc=0
  (
    cd "$TMP_ROOT" || exit 1
    fm_run_timed 40 env -i PATH="$PATH" HOME="$TMP_ROOT/home-$category" TERM=dumb \
      CLAUDE_CONFIG_DIR="$TMP_ROOT/config-$category" \
      ANTHROPIC_API_KEY=sk-ant-synthetic-loopback-only \
      ANTHROPIC_BASE_URL="http://127.0.0.1:$port" \
      DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      claude -p 'say hi' --model claude-sonnet-4-6 --max-turns 1 \
        --setting-sources '' --strict-mcp-config
  ) > "$TMP_ROOT/$category.out" 2> "$TMP_ROOT/$category.err" || rc=$?
  [ "$rc" = 1 ] || fail "Claude $version: expected terminal refusal exit 1, got $rc ($category)"
  rendered=$(cat "$TMP_ROOT/$category.out")
  fm_busy_safeguard_pause claude "$rendered" \
    || fail "Claude $version: unrecognized $category refusal rendering: $rendered"
  # Each independent vendor recovery form must work without the other one.
  printf '%s\n' "$rendered" | grep -q '^API Error:' \
    || fail "Claude $version: refusal was not emitted as an API error"
  pass "Claude Code $version: $category refusal renders a recognized terminal safeguard stop"
  # Pre-approve only this disposable test directory and the synthetic key, so
  # onboarding cannot mask the vendor refusal. Nothing reads a real account.
  python3 -I - "$TMP_ROOT" "$category" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
config = root / ("config-" + sys.argv[2])
config.mkdir(parents=True, exist_ok=True)
(config / ".claude.json").write_text(json.dumps({
    "hasCompletedOnboarding": True,
    "theme": "dark",
    "customApiKeyResponses": {"approved": ["sk-ant-synthetic-loopback-only"[-20:]], "rejected": []},
    "projects": {str(root): {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True}},
}))
PY
  for width in 180 64 40; do
    tmux_socket="$TMP_ROOT/${category:0:1}$width"
    fm_test_arm_private_tmux TMUX_RETAIN || fail 'could not protect Claude probe scratch'
    env -i PATH="$PATH" HOME="$TMP_ROOT/home-$category" TERM=xterm-256color \
      CLAUDE_CONFIG_DIR="$TMP_ROOT/config-$category" \
      ANTHROPIC_API_KEY=sk-ant-synthetic-loopback-only \
      ANTHROPIC_BASE_URL="http://127.0.0.1:$port" \
      DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      tmux -S "$tmux_socket" -f /dev/null new-session -d -s refusal -x "$width" -y 40 -c "$TMP_ROOT" \
        "claude 'say hi' --model claude-sonnet-4-6 --setting-sources '' --strict-mcp-config --tools ''" \
      || fail "Claude $version: private interactive session did not start"
    pane=''
    for ((i=0; i<300; i++)); do
      pane=$(tmux -S "$tmux_socket" capture-pane -p -t refusal -S -40 2>/dev/null || true)
      if fm_busy_safeguard_pause claude "$pane"; then break; fi
      sleep 0.1
    done
    fm_busy_safeguard_pause claude "$pane" \
      || fail "Claude $version: unrecognized interactive $category refusal at $width columns: $pane"
    fm_test_stop_private_tmux "$tmux_socket" tmux "$TMUX_RETAIN" || exit 1
    TMUX_RETAIN=
    tmux_socket=''
    pass "Claude Code $version: interactive $category refusal is recognized at $width columns"
  done
  stop_server
done
