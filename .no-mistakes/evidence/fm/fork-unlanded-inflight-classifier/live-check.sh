#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$ROOT/.v
E=~/.no-mistakes/evidence/01M7DBBYVHWJ3DXDAS4J5GGN65
export TMUX_TMPDIR=$LAB/tmux
# A real tmux endpoint for the snapshot; no agent is impersonated or prompted.
tmux -L fm-lab new-session -d -s fixture -x 100 -y 30 -n fm-delivery 'sleep 600'
trap 'tmux -L fm-lab kill-server 2>/dev/null || true' EXIT
export TMUX=$(tmux -L fm-lab display-message -p '#{socket_path}'),0,0
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH FM_BACKEND TASKS_AXI_FILE TASKS_AXI_BACKEND
export FM_HOME=$LAB NM_HOME=$LAB/nm
mkdir -p "$NM_HOME"
meta() {
  printf '%s\n' 'backend=tmux' 'window=fixture:fm-delivery' "worktree=$LAB/projects/worker" 'harness=claude' 'kind=ship' 'mode=no-mistakes' "$@" > "$LAB/state/delivery.meta"
}
idle() {
  gen=$(bin/fm-busy-event.sh arm "$LAB/state" delivery)
  bin/fm-busy-event.sh apply "$LAB/state" delivery idle --gen "$gen" --source claude-hook --event stop
}
summary() {
  bin/fm-fleet-snapshot.sh --secondmate-home-summary > "$E/$1.json"
  jq '{valid,invalidity,retained_unlanded,counts}' "$E/$1.json"
}
if [ -d "$LAB/projects/worker-away" ]; then mv "$LAB/projects/worker-away" "$LAB/projects/worker"; fi
mkdir -p "$LAB/projects/worker"
printf '## In flight\n- [ ] delivery - Awaiting landing (kind: ship)\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
cp "$LAB/data/backlog.md" "$LAB/backlog.before"
urls=('https://github.com/example/demo/pull/41' 'https://gitlab.com/example/demo/-/merge_requests/41' 'https://review.example.com/c/example/demo/+/41' 'https://codeberg.org/example/demo/pulls/41')
i=0
for url in "${urls[@]}"; do
  i=$((i+1)); meta; idle
  printf 'failed: delivery retained <%s>\n' "$url" > "$LAB/state/delivery.status"
  summary "live-status-forge-$i"
  jq -e '.valid == true and .retained_unlanded == [{id:"delivery",state:"failed",via:"pr"}]' "$E/live-status-forge-$i.json" >/dev/null
  bin/fm-fleet-snapshot.sh --json > "$E/live-status-identity-$i.json"
  jq -e --arg url "$url" '.tasks[0].pr == {url:$url,source:"status_event",head:null}' "$E/live-status-identity-$i.json" >/dev/null
done
meta 'pr=https://github.com/example/demo/pull/41' 'pr_head=0123456789abcdef0123456789abcdef01234567'
printf 'done: PR https://github.com/example/demo/pull/41 checks green\n' > "$LAB/state/delivery.status"
summary live-pr-open
jq -e '.valid and .counts.retained_unlanded == 1' "$E/live-pr-open.json" >/dev/null
mv "$LAB/projects/worker" "$LAB/projects/worker-away"
summary live-missing-worker
jq -e '.valid == false and .invalidity.ids == ["delivery"] and .retained_unlanded == []' "$E/live-missing-worker.json" >/dev/null
mv "$LAB/projects/worker-away" "$LAB/projects/worker"
meta
printf 'done: no recorded delivery\n' > "$LAB/state/delivery.status"
summary live-no-delivery
jq -e '.valid == false and .invalidity.kind == "terminal_in_flight"' "$E/live-no-delivery.json" >/dev/null
# Real isolated git commits, first-observation pinning, and subsequent landing.
git init -q -b main "$LAB/projects/local"
git -C "$LAB/projects/local" -c user.name=Lab -c user.email=lab@example.invalid commit -q --allow-empty -m base
git -C "$LAB/projects/local" worktree add -q -b fm/delivery "$LAB/projects/local-wt"
git -C "$LAB/projects/local-wt" -c user.name=Lab -c user.email=lab@example.invalid commit -q --allow-empty -m delivery
head=$(git -C "$LAB/projects/local-wt" rev-parse HEAD)
for generation in legacy generated; do
  printf '%s\n' 'backend=tmux' 'window=fixture:fm-delivery' "worktree=$LAB/projects/local-wt" "project=$LAB/projects/local" 'branch=fm/delivery' 'harness=claude' 'kind=ship' 'mode=local-only' > "$LAB/state/delivery.meta"
  if [ "$generation" = generated ]; then printf 'spawn_gen=disposable-generation\n' >> "$LAB/state/delivery.meta"; fi
  idle
  printf 'done: ready branch fm/delivery\n' > "$LAB/state/delivery.status"
  summary "live-local-first-$generation"
  jq -e '.valid and .retained_unlanded == [{id:"delivery",state:"done",via:"local-only"}]' "$E/live-local-first-$generation.json" >/dev/null
  grep -Fx "local_done_head=$head" "$LAB/state/delivery.meta"
done
git -C "$LAB/projects/local" merge -q --ff-only fm/delivery
summary live-local-landed
jq -e '.valid == false and .invalidity == {kind:"terminal_in_flight",ids:["delivery"]} and .retained_unlanded == []' "$E/live-local-landed.json" >/dev/null
cmp "$LAB/backlog.before" "$LAB/data/backlog.md"
test -f "$LAB/state/delivery.meta"
echo 'Backlog unchanged; metadata and worker copies retained. All live CLI assertions passed.'
