#!/usr/bin/env bash
set -euo pipefail
BASE="$PWD/.validation"
CODE="$BASE/code"
export TREEHOUSE_ROOT="$BASE/pool"
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
bash bin/fm-lab-home.sh create "$BASE/parent"
export FM_HOME="$BASE/parent" TMUX="$BASE/s,0,0"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
touch "$FM_HOME/state/.last-watcher-beat"
git -C "$CODE" init -q -b main
printf 'tracked public content\n' > "$CODE/public.txt"
git -C "$CODE" add bin .gitignore public.txt
git -C "$CODE" -c user.name=Validation -c user.email=validation@example.invalid commit -qm baseline
home=$(cd "$CODE" && treehouse get --lease --no-fetch --base main)
printf '%s\n' "$home" > "$BASE/slot-path"
seed_private() {
  local name
  printf '%s\n' "$1" > "$home/.fm-secondmate-home"
  for name in data state config projects .no-mistakes; do mkdir -p "$home/$name"; printf 'private %s\n' "$name" > "$home/$name/secret"; done
  printf '999999\n' > "$home/state/.lock"
}
meta() {
  printf 'kind=%s\nmode=local-only\nhome=%s\nproject=%s\nworktree=%s\nwindow=fm-lab-validation:fm-%s\nendpoint_task_id=%s\nspawn_gen=disposable-validation-%s\n' "$2" "$home" "$CODE" "$home" "$1" "$1" "$1" > "$FM_HOME/state/$1.meta"
}
seed_private mate-one
meta mate-one secondmate
printf '\n=== Retire leased home: before ===\n'
(cd "$CODE" && treehouse status)
find "$home/data" "$home/state" "$home/config" "$home/projects" "$home/.no-mistakes" -type f
printf '\n=== Real teardown ===\n'
bash "$CODE/bin/fm-teardown.sh" mate-one
printf '\n=== After retirement ===\n'
for name in data state config projects .no-mistakes; do test ! -e "$home/$name"; printf '%s absent\n' "$name"; done
test "$(< "$home/public.txt")" = 'tracked public content'
printf 'public.txt preserved: %s\n' "$(< "$home/public.txt")"
(cd "$CODE" && treehouse status)
next=$(cd "$CODE" && treehouse get --lease --no-fetch --base main)
test "$next" = "$home"
for name in data state config projects .no-mistakes; do test ! -e "$next/$name"; done
printf 'Next lease reused same slot, with no private directories: %s\n' "$next"

printf '\n=== Unsafe escaping private directory refuses retirement ===\n'
seed_private unsafe-home
meta unsafe-home secondmate
mkdir -p "$BASE/outside"
printf 'outside sentinel\n' > "$BASE/outside/sentinel"
rm -rf "$home/projects"
ln -s "$BASE/outside" "$home/projects"
rc=0
bash "$CODE/bin/fm-teardown.sh" unsafe-home || rc=$?
test "$rc" -ne 0
test "$(< "$BASE/outside/sentinel")" = 'outside sentinel'
test -f "$FM_HOME/state/unsafe-home.meta"
test -f "$home/data/secret"
printf 'Unsafe retirement exit=%s; external sentinel, home data, and task record preserved\n' "$rc"
rm "$home/projects"
# Validating the same record after correcting the disposable setup also releases its lease.
bash "$CODE/bin/fm-teardown.sh" unsafe-home

printf '\n=== Unlanded pooled ship refuses and preserves work ===\n'
home=$(cd "$CODE" && treehouse get --lease --no-fetch --base main -b fm/unlanded)
printf 'not landed\n' > "$home/feature.txt"
git -C "$home" add feature.txt
git -C "$home" -c user.name=Validation -c user.email=validation@example.invalid commit -qm 'unlanded feature'
mkdir -p "$home/data"
printf 'private pending work\n' > "$home/data/secret"
meta unlanded ship
head_before=$(git -C "$home" rev-parse HEAD)
rc=0
bash "$CODE/bin/fm-teardown.sh" unlanded || rc=$?
test "$rc" -ne 0
test "$(git -C "$home" rev-parse HEAD)" = "$head_before"
test -f "$home/feature.txt"
test -f "$home/data/secret"
test -f "$FM_HOME/state/unlanded.meta"
printf 'Unlanded retirement exit=%s; commit=%s, feature, private data, and task record preserved\n' "$rc" "$head_before"

printf '\n=== Landed ordinary ship does not scrub home-owned ignored data ===\n'
git -C "$CODE" merge --ff-only fm/unlanded
bash "$CODE/bin/fm-teardown.sh" unlanded
test -f "$home/data/secret"
test "$(< "$home/data/secret")" = 'private pending work'
printf 'Ordinary landed ship returned successfully; ignored data/secret preserved\n'
(cd "$CODE" && treehouse status)
printf '\nALL FOUR LIVE SCENARIOS PASSED\n'
