#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M7DF69148ETBXWS8FR0NJ1VZ
LAB="$PWD/.l"
[ ! -e "$LAB" ]
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/t" "$LAB/nm"
export FM_HOME="$LAB" TMUX_TMPDIR="$LAB/t" NM_HOME="$LAB/nm" FM_CREW_STATE_NO_FORGE=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
cleanup() {
  tmux -L fm-lab kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
# Private real tmux worker endpoint, not a mock harness or a fleet primary.
tmux -L fm-lab new-session -d -s worker -x 100 -y 30 -c "$ROOT" 'bash --noprofile --norc'
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),0,0"
mkdir -p "$LAB/projects/pr" "$LAB/projects/failed" "$LAB/projects/scout"
git init -q -b main "$LAB/projects/local"
git -C "$LAB/projects/local" -c user.name=Lab -c user.email=lab@example.invalid commit -q --allow-empty -m base
git -C "$LAB/projects/local" worktree add -q -b fm/lab "$LAB/projects/local-wt"
git -C "$LAB/projects/local-wt" -c user.name=Lab -c user.email=lab@example.invalid commit -q --allow-empty -m delivery
HEAD=$(git -C "$LAB/projects/local-wt" rev-parse HEAD)
meta() {
  local id=$1 path=$2 kind=$3 mode=$4; shift 4
  printf 'backend=tmux\nwindow=worker:0\nworktree=%s\nharness=claude\nkind=%s\nmode=%s\nspawn_gen=lab-%s\n' "$path" "$kind" "$mode" "$id" > "$LAB/state/$id.meta"
  for kv in "$@"; do printf '%s\n' "$kv" >> "$LAB/state/$id.meta"; done
  gen=$(bin/fm-busy-event.sh arm "$LAB/state" "$id")
  bin/fm-busy-event.sh apply "$LAB/state" "$id" idle --gen "$gen" --source claude-hook --event stop
}
meta pr "$LAB/projects/pr" ship no-mistakes 'pr=https://github.com/lab/example/pull/41'
meta failed "$LAB/projects/failed" ship direct-PR
meta local "$LAB/projects/local-wt" ship local-only "project=$LAB/projects/local" branch=fm/lab
printf 'done: implementation complete\n' > "$LAB/state/pr.status"
printf 'failed: delivery retained <https://gitlab.com/lab/example/-/merge_requests/42>\n' > "$LAB/state/failed.status"
printf 'done: ready branch fm/lab\n' > "$LAB/state/local.status"
printf '## In flight\n- [ ] pr - PR awaiting approval (kind: ship)\n- [ ] failed - Failed delivery still retained (kind: ship)\n- [ ] local - Branch awaiting landing (kind: ship)\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
cp "$LAB/data/backlog.md" "$LAB/backlog.before"
cp "$LAB/state/pr.meta" "$LAB/pr.before"
snapshot() { bin/fm-fleet-snapshot.sh --secondmate-home-summary > "$E/$1.json"; jq '{valid,invalidity,retained_unlanded,counts,omitted}' "$E/$1.json"; }
snapshot retained
jq -e '.valid and (.retained_unlanded|sort_by(.id)) == [{id:"failed",state:"failed",via:"pr"},{id:"local",state:"done",via:"local-only"},{id:"pr",state:"done",via:"pr"}]' "$E/retained.json"
grep -Fx "local_done_head=$HEAD" "$LAB/state/local.meta"
bin/fm-fleet-snapshot.sh --json > "$E/retained-fleet.json"
jq -e '.tasks[] | select(.id=="failed") | .pr.url=="https://gitlab.com/lab/example/-/merge_requests/42" and .pr.source=="status_event" and .delivery.landing=="unlanded"' "$E/retained-fleet.json"
cmp "$LAB/data/backlog.md" "$LAB/backlog.before"
cmp "$LAB/state/pr.meta" "$LAB/pr.before"
# A normal landing must remove the exemption, not silently repair the backlog.
(
  . "$ROOT/bin/fm-pr-lib.sh"
  fm_pr_url_parse https://github.com/lab/example/pull/41
  template="$ROOT/bin/fm-pr-poll.sh"
  fm_pr_poll_prepare "$LAB/state" pr "$FM_PR_PROVIDER" "$FM_PR_URL" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$template"
  fm_pr_poll_publish_prepared
  fm_pr_poll_snapshot_capture "$LAB/state" pr "$template"
  fm_pr_poll_retirement_publish "$LAB/state" pr "$template" merged
)
git -C "$LAB/projects/local" merge -q --ff-only fm/lab
snapshot landed
jq -e '.valid==false and .invalidity.kind=="terminal_in_flight" and (.invalidity.ids|sort)==["local","pr"] and .retained_unlanded==[{id:"failed",state:"failed",via:"pr"}]' "$E/landed.json"
cmp "$LAB/data/backlog.md" "$LAB/backlog.before"
# Adversarial: no delivery identity, no worker copy, and terminal scout.
rm "$LAB/state/pr.meta" "$LAB/state/local.meta"
meta missing "$LAB/projects/absent" ship no-mistakes 'pr=https://github.com/lab/example/pull/43'
meta identity "$LAB/projects/pr" ship direct-PR
meta scout "$LAB/projects/scout" scout scout
printf 'done: complete\n' > "$LAB/state/missing.status"
printf 'failed: stopped\n' > "$LAB/state/identity.status"
printf 'done: report ready\n' > "$LAB/state/scout.status"
printf '## In flight\n- [ ] failed - Retained delivery (kind: ship)\n- [ ] missing - Missing worker copy (kind: ship)\n- [ ] identity - No delivery identity (kind: ship)\n- [ ] scout - Terminal scout (kind: scout)\n' > "$LAB/data/backlog.md"
snapshot boundaries
jq -e '.valid==false and .invalidity.kind=="terminal_in_flight" and (.invalidity.ids|sort)==["identity","scout"] and .retained_unlanded==[{id:"failed",state:"failed",via:"pr"}] and any(.endpoints[]; .id=="missing" and .state=="unknown")' "$E/boundaries.json"
printf 'All three local product scenarios completed. Private tmux server and lab removed by EXIT trap.\n'
