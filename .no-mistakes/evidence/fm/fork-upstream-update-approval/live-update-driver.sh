#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
W="$ROOT/.test-tmp/live-update"
mkdir -p "$W/home" "$W/private" "$W/home/data" "$W/home/state" "$W/home/config"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=Validation GIT_AUTHOR_EMAIL=validation@example.invalid GIT_COMMITTER_NAME=Validation GIT_COMMITTER_EMAIL=validation@example.invalid
export FM_HOME="$W/home" FM_STATE_OVERRIDE="$W/home/state" FM_DATA_OVERRIDE="$W/home/data" FM_CONFIG_OVERRIDE="$W/home/config" FM_PROJECTS_OVERRIDE="$W/home/projects"
unset FM_ROOT_OVERRIDE
call() { local root=$1; shift; printf '\n$ fm-update.sh %s\n' "$*"; FM_ROOT_OVERRIDE="$root" "$ROOT/bin/fm-update.sh" "$@"; }
refuse() { if "$@"; then echo 'ERROR: unsafe operation succeeded'; exit 1; else echo 'Observed expected refusal'; fi; }
commit() { git -C "$1" add -A; git -C "$1" commit -qm "$2"; }
git init -q --bare "$W/fork.git"
git -C "$W/fork.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/fork.git" "$W/seed"
printf 'baseline\n' > "$W/seed/runtime"
# Seed a structurally valid disposable product home, not operator memory.
printf 'Disposable validation home.\n' > "$W/seed/AGENTS.md"
mkdir "$W/seed/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/seed/bin/tool.sh"
printf 'private\n' > "$W/seed/.gitignore"
commit "$W/seed" baseline
git -C "$W/seed" push -q origin HEAD:main
git clone -q --bare "$W/fork.git" "$W/canonical.git"
git clone -q "$W/canonical.git" "$W/upstream"
printf '#!/usr/bin/env bash\nprintf "deliberate fork behavior\\n"\n' > "$W/seed/personal.sh"
commit "$W/seed" customization
git -C "$W/seed" push -q origin main
O=$(git -C "$W/seed" rev-parse HEAD)
git clone -q "$W/fork.git" "$W/primary"
git -C "$W/primary" worktree add -qb integrate "$W/candidate" main
git -C "$W/candidate" remote add canonical "$W/canonical.git"
printf 'upstream feature\n' > "$W/upstream/upstream-feature"
commit "$W/upstream" upstream
git -C "$W/upstream" push -q origin main
U=$(git -C "$W/upstream" rev-parse HEAD)
prepare() { call "$W/candidate" --prepare-upstream "$W/fork.git" main "$O" "$W/canonical.git" main "$U" "$W/private/attempt"; }
echo '=== Clean divergent integration retains both histories and actual personal behavior ==='
prepare
H=$(git -C "$W/candidate" rev-parse HEAD)
git -C "$W/candidate" merge-base --is-ancestor "$O" "$H"
git -C "$W/candidate" merge-base --is-ancestor "$U" "$H"
bash "$W/candidate/personal.sh"
[ "$(git -C "$W/primary" rev-parse HEAD)" = "$O" ]
[ "$(git -C "$W/fork.git" rev-parse main)" = "$O" ]
echo 'Active primary and published fork unchanged'
prepare
[ "$(git -C "$W/candidate" rev-parse HEAD)" = "$H" ]
echo 'Repeated preparation retained exact candidate'
echo '=== Unknown attempt and missing normal pipeline evidence refuse ==='
mkdir "$W/private/interrupted"
printf 'unknown\n' > "$W/private/interrupted/events"
refuse call "$W/candidate" --prepare-upstream "$W/fork.git" main "$O" "$W/canonical.git" main "$U" "$W/private/interrupted"
refuse call "$W/candidate" --qualify-upstream "$W/private/attempt" "$H" "$H" "$H" "$O" "$H" clean "$W/private/missing-pipeline-evidence"
[ ! -e "$W/private/attempt/qualifications" ]
echo 'No qualification or publication was fabricated'
echo '=== Origin consumption and independent/unsafe secondmate copies ==='
# Publish an ordinary local origin update, NOT a claimed checked integration landing.
printf 'independent origin update\n' > "$W/seed/origin-feature"
commit "$W/seed" origin-update
git -C "$W/seed" push -q origin main
M=$(git -C "$W/seed" rev-parse HEAD)
git clone -q --bare "$W/fork.git" "$W/independent.git"
git clone -q "$W/independent.git" "$W/own-seed"
git clone -q "$W/independent.git" "$W/independent"
printf 'independent\n' > "$W/independent/.fm-secondmate-home"
printf 'own remote only\n' > "$W/own-seed/own-feature"
commit "$W/own-seed" own-update
git -C "$W/own-seed" push -q origin main
OWN=$(git -C "$W/own-seed" rev-parse HEAD)
for id in dirty divergent; do
 git -C "$W/primary" worktree add -q --detach "$W/$id" "$O"
 printf '%s\n' "$id" > "$W/$id/.fm-secondmate-home"
done
printf 'unsaved local edit\n' > "$W/dirty/runtime"
printf 'unlanded commit\n' > "$W/divergent/local"
# The seed marker is ignored by the product, but keep it out of our commit.
git -C "$W/divergent" add local
git -C "$W/divergent" commit -qm unlanded
DIV=$(git -C "$W/divergent" rev-parse HEAD)
for id in independent dirty divergent; do printf -- '- %s - disposable domain (home: %s/%s; scope: validation; projects: p; added 2026-10-17)\n' "$id" "$W" "$id"; done > "$W/home/data/secondmates.md"
printf 'keep private journal\n' > "$W/home/data/journal"
refuse call "$W/primary" --consume-origin "$O"
[ "$(git -C "$W/primary" rev-parse HEAD)" = "$O" ]
[ "$(git -C "$W/independent" rev-parse HEAD)" = "$M" ]
echo 'Moved pin refused before all secondary copies'
printf 'unsaved primary\n' > "$W/primary/unsaved"
refuse call "$W/primary" --consume-origin "$M"
rm "$W/primary/unsaved"
call "$W/primary" --consume-origin "$M"
[ "$(git -C "$W/primary" rev-parse HEAD)" = "$M" ]
[ "$(git -C "$W/independent" rev-parse HEAD)" = "$OWN" ]
[ "$(git -C "$W/independent" remote get-url origin)" = "$W/independent.git" ]
[ "$(git -C "$W/divergent" rev-parse HEAD)" = "$DIV" ]
[ "$(< "$W/dirty/runtime")" = 'unsaved local edit' ]
[ "$(< "$W/home/data/journal")" = 'keep private journal' ]
echo "Primary on exact pin $M; independent copy on its own $OWN; unsafe work and private journal retained"
call "$W/primary" --consume-origin "$M"
echo '=== Conflicting integration preserves index and sticky provenance after resolution ==='
git -C "$W/primary" worktree add -qb conflict-task "$W/conflict" main
printf 'canonical conflict\n' > "$W/upstream/runtime"
commit "$W/upstream" conflict
git -C "$W/upstream" push -q origin main
U2=$(git -C "$W/upstream" rev-parse HEAD)
printf 'fork conflict\n' > "$W/seed/runtime"
commit "$W/seed" fork-conflict
git -C "$W/seed" push -q origin main
O2=$(git -C "$W/seed" rev-parse HEAD)
git -C "$W/conflict" fetch -q origin
git -C "$W/conflict" merge --ff-only "$O2"
conflict_prepare() { call "$W/conflict" --prepare-upstream "$W/fork.git" main "$O2" "$W/canonical.git" main "$U2" "$W/private/conflict-attempt"; }
refuse conflict_prepare
git -C "$W/conflict" ls-files -u
[ -n "$(git -C "$W/conflict" ls-files -u)" ]
printf 'resolved deliberately\n' > "$W/conflict/runtime"
git -C "$W/conflict" add runtime
git -C "$W/conflict" commit -qm resolution
conflict_prepare
[ "$(git -C "$W/primary" rev-parse HEAD)" = "$M" ]
echo 'Conflict resolution remains recorded as conflicted; active primary still unchanged'
echo '=== Live CLI checks complete; no checked publication or loaded activation claimed ==='
