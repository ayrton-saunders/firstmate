#!/bin/bash
set -eu
ROOT="$PWD"
export PATH="$ROOT/.live-validation/tools/bin:$ROOT/.live-validation/tools:/usr/bin:/bin:/usr/sbin:/sbin"
export TMPDIR="$ROOT/.live-validation/tmp"
export FM_PROCEVENT_CLAIM_ROOT="$ROOT/.live-validation/claims"
export TREEHOUSE_ROOT="$ROOT/.live-validation/pool"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS HERDR_ENV HERDR_SESSION TMUX
CODE="$ROOT/.live-validation/code"
LAB="$ROOT/.live-validation/active"
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
export FM_HOME="$LAB"
printf 'manual\n' > "$LAB/config/backlog-backend"
SOCKET="$ROOT/.s"
cleanup() { tmux -S "$SOCKET" kill-server 2>/dev/null || true; rm -f "$SOCKET"; }
trap cleanup EXIT
create_case() {
  ID=$1
  SLOT=$(cd "$CODE" && treehouse get --lease --no-fetch --base main)
  printf '%s\n' "$ID" > "$SLOT/.fm-secondmate-home"
  mkdir -p "$SLOT/data/task" "$SLOT/state" "$SLOT/config" "$SLOT/projects/alpha" "$SLOT/.no-mistakes/repos"
  printf 'brief\n' > "$SLOT/data/task/brief.md"
  printf '999999\n' > "$SLOT/state/.lock"
  printf 'secret\n' > "$SLOT/config/private"
  printf 'clone\n' > "$SLOT/projects/alpha/private"
  printf 'scratch\n' > "$SLOT/.no-mistakes/repos/private"
  tmux -S "$SOCKET" -f /dev/null new-session -d -s "fm-lab-$ID" -n "fm-$ID" -c "$CODE" 'sleep 300'
  export TMUX="$SOCKET,0,0"
  printf 'window=fm-lab-%s:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nhome=%s\nkind=secondmate\nmode=local-only\nspawn_gen=s1700000000.1.live\n' "$ID" "$ID" "$ID" "$SLOT" "$CODE" "$SLOT" > "$LAB/state/$ID.meta"
}
create_case scrub-live
printf '\nSCENARIO retire pooled home\nslot=%s\n' "$SLOT"
"$CODE/bin/fm-teardown.sh" "$ID" --force
for dir in data state config projects .no-mistakes; do
  if [ -e "$SLOT/$dir" ]; then echo "LEAK: $dir"; exit 1; fi
  echo "retired $dir: absent"
done
[ -f "$SLOT/README.md" ]
echo 'tracked README.md: retained'
NEXT=$(cd "$CODE" && treehouse get --lease --no-fetch --base main)
[ "$NEXT" = "$SLOT" ]
for dir in data state config projects .no-mistakes; do [ ! -e "$NEXT/$dir" ]; done
echo 'next lease: same slot; all five retired private directories absent'
(cd "$CODE" && treehouse return --force "$NEXT")
create_case scrub-escape
rm -rf "$SLOT/.no-mistakes"
mkdir -p "$ROOT/.live-validation/external"
printf 'KEEP\n' > "$ROOT/.live-validation/external/sentinel"
ln -s "$ROOT/.live-validation/external" "$SLOT/.no-mistakes"
printf '\nSCENARIO escaping private symlink\n'
RC=0
"$CODE/bin/fm-teardown.sh" "$ID" --force || RC=$?
echo "teardown exit: $RC"
[ "$RC" = 1 ]
[ "$(< "$ROOT/.live-validation/external/sentinel")" = KEEP ]
[ -L "$SLOT/.no-mistakes" ]
[ -f "$LAB/state/$ID.meta" ]
echo 'outside sentinel: KEEP; unsafe symlink and retry route retained'
(cd "$CODE" && treehouse status)
rm "$SLOT/.no-mistakes"
rm -f "$LAB/state/$ID.meta"
(cd "$CODE" && treehouse return --force "$SLOT")
for SHAPE in broken file; do
  create_case "scrub-$SHAPE"
  rm -rf "$SLOT/.no-mistakes"
  if [ "$SHAPE" = broken ]; then ln -s "$ROOT/.live-validation/missing" "$SLOT/.no-mistakes"; else printf 'not a directory\n' > "$SLOT/.no-mistakes"; fi
  printf '\nSCENARIO invalid private path: %s\n' "$SHAPE"
  RC=0
  "$CODE/bin/fm-teardown.sh" "$ID" --force || RC=$?
  echo "teardown exit: $RC"
  [ "$RC" = 1 ]
  [ -e "$SLOT/.no-mistakes" ] || [ -L "$SLOT/.no-mistakes" ]
  [ -f "$LAB/state/$ID.meta" ]
  echo 'unsafe private entry and retry route: retained'
  (cd "$CODE" && treehouse status)
  rm "$SLOT/.no-mistakes"
  rm -f "$LAB/state/$ID.meta"
  (cd "$CODE" && treehouse return --force "$SLOT")
done
create_case scrub-unlanded
printf 'unique unlanded work\n' > "$SLOT/new-feature.txt"
git -C "$SLOT" add new-feature.txt
git -C "$SLOT" -c user.name=LiveTest -c user.email=live@example.invalid commit -qm unlanded
# A ship slot uses the ordinary landed-work guard before any private scrub.
printf 'window=fm-lab-%s:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=ship\nmode=local-only\nspawn_gen=s1700000000.1.live\n' "$ID" "$ID" "$ID" "$SLOT" "$CODE" > "$LAB/state/$ID.meta"
BEFORE=$(git -C "$SLOT" rev-parse HEAD)
printf '\nSCENARIO refuse unlanded work without force\n'
RC=0
"$CODE/bin/fm-teardown.sh" "$ID" || RC=$?
echo "teardown exit: $RC"
[ "$RC" = 1 ]
[ "$(git -C "$SLOT" rev-parse HEAD)" = "$BEFORE" ]
[ -f "$SLOT/new-feature.txt" ]
[ -f "$SLOT/state/.lock" ]
[ -f "$LAB/state/$ID.meta" ]
echo 'unlanded commit, file, stale private lock and task route: preserved'
(cd "$CODE" && treehouse status)
# Explicit fixture cleanup, not product teardown of real user work.
(cd "$CODE" && treehouse return --force "$SLOT")
