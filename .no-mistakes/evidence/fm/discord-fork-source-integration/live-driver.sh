#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB="$ROOT/.l"
EVIDENCE=/Users/ayrton/.no-mistakes/evidence/01M5Z6S3D1YEKGGHKF6B2RZ6HH
bash bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
cleanup() { tmux -L fm-lab kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
# A real terminal endpoint receives the product's doorbell; no worker model or bot is activated.
tmux -L fm-lab new-session -d -s primary -x 100 -y 30 -c "$ROOT" 'cat'
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),$(tmux -L fm-lab display-message -p '#{pid}'),0"
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
printf 'window=primary:0\nbackend=tmux\nkind=ship\nharness=claude\nspawn_gen=lab-generation\n' > "$LAB/state/worker.meta"
for mode in absent disabled malformed duplicate nonboolean symlink; do
  rm -f "$LAB/config/discord-integration.json"
  case "$mode" in
    absent) ;;
    disabled) printf '{"enabled":false}\n' > "$LAB/config/discord-integration.json" ;;
    malformed) printf '{"enabled":true,"schema":1}\n' > "$LAB/config/discord-integration.json" ;;
    duplicate) printf '{"enabled":true,"enabled":false}\n' > "$LAB/config/discord-integration.json" ;;
    nonboolean) printf '{"enabled":"false"}\n' > "$LAB/config/discord-integration.json" ;;
    symlink) printf '{"enabled":false}\n' > "$LAB/linked.json"; ln -s "$LAB/linked.json" "$LAB/config/discord-integration.json" ;;
  esac
  echo "=== Real fm-send: $mode configuration ==="
  before=$(find "$LAB/state/worker.inbox" -name '*.msg' 2>/dev/null | wc -l | tr -d ' ' || true)
  rc=0
  bash bin/fm-send.sh worker "isolated $mode delivery" || rc=$?
  after=$(find "$LAB/state/worker.inbox" -name '*.msg' 2>/dev/null | wc -l | tr -d ' ' || true)
  echo "exit=$rc durable-records-before=$before after=$after"
  case "$mode" in
    absent|disabled) [ "$rc" -eq 0 ]; [ "$after" -eq "$((before+1))" ]; ;;
    *) [ "$rc" -ne 0 ]; [ "$after" -eq "$before" ]; ;;
  esac
  if [ "$mode" = absent ] || [ "$mode" = disabled ] || [ "$mode" = malformed ]; then
    echo "=== Real fm-inbox: $mode capture/drain/reply/receipt ==="
    note=$(bash bin/fm-inbox.sh note --request-id "live-$mode" --json "isolated $mode request")
    echo "$note"
    id=$(printf '%s' "$note" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
    bash bin/fm-inbox.sh drain
    bash bin/fm-inbox.sh reply --json "$id" "isolated $mode reply"
    bash bin/fm-inbox.sh receipts --all-replies
  fi
done
echo '=== Persisted steering records ==='
python3 - "$LAB/state/worker.inbox" <<'PY'
from pathlib import Path
import sys
records=sorted(Path(sys.argv[1]).glob('*.msg'))
assert len(records)==2
for path in records:
    print(path.name, path.read_text())
assert 'isolated absent delivery' in records[0].read_text()
assert 'isolated disabled delivery' in records[1].read_text()
PY
echo '=== Terminal capture (no agent launched; durable enqueue is delivery) ==='
tmux -L fm-lab capture-pane -p -t primary
# Default-home executable without exported FM_HOME; code-local home is disposable.
cp -R bin "$LAB/bin"
rm -f "$LAB/config/discord-integration.json"
printf '{"enabled":false}\n' > "$LAB/config/discord-integration.json"
echo '=== Default-home inbox with FM_HOME unset ==='
id=$(env -u FM_HOME bash "$LAB/bin/fm-inbox.sh" note --json 'unset-home request' | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
env -u FM_HOME bash "$LAB/bin/fm-inbox.sh" drain
env -u FM_HOME bash "$LAB/bin/fm-inbox.sh" reply --json "$id" 'unset-home durable reply'
env -u FM_HOME bash "$LAB/bin/fm-inbox.sh" receipts --all-replies
echo 'All live CLI checks completed; disposable terminal and home removed on exit.'
