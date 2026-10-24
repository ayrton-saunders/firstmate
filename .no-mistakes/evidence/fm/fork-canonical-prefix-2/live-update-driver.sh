#!/usr/bin/env bash
set -eu
ROOT=$PWD
D="$ROOT/.validation-tmp/update-live"
mkdir -p "$D"
trap 'rm -rf "$D"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Validation GIT_COMMITTER_NAME=Validation GIT_AUTHOR_EMAIL=validation@example.invalid GIT_COMMITTER_EMAIL=validation@example.invalid
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
git init -q --bare "$D/origin.git"
git --git-dir="$D/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$D/origin.git" "$D/seed" 2>/dev/null
printf 'original\n' > "$D/seed/README.md"
git -C "$D/seed" add README.md; git -C "$D/seed" commit -qm original; git -C "$D/seed" push -q origin main
git clone -q "$D/origin.git" "$D/operator"
export FM_ROOT_OVERRIDE="$D/operator" FM_HOME="$D/home"
mkdir -p "$FM_HOME/state" "$FM_HOME/data"
old=$(git -C "$D/operator" rev-parse HEAD)
printf 'advanced\n' > "$D/seed/README.md"
git -C "$D/seed" commit -qam advance; git -C "$D/seed" push -q origin main
new=$(git -C "$D/seed" rev-parse HEAD)
printf '== Consume exact new default head from private local origin ==\n'
"$ROOT/bin/fm-update.sh" --consume-origin "$new"
[ "$(git -C "$D/operator" rev-parse HEAD)" = "$new" ]
git -C "$D/operator" merge-base --is-ancestor "$old" HEAD
printf 'Confirmed: HEAD advanced to exact origin tip, retaining its ancestor.\n'
printf '\n== Refuse stale expected head without moving current default ==\n'
set +e
"$ROOT/bin/fm-update.sh" --consume-origin "$old"
rc=$?
set -e
printf 'exit=%s\n' "$rc"
[ "$rc" -ne 0 ]; [ "$(git -C "$D/operator" rev-parse HEAD)" = "$new" ]
printf '\n== Refuse a task branch without moving it ==\n'
git -C "$D/operator" checkout -qb task
set +e
"$ROOT/bin/fm-update.sh" --consume-origin "$new"
rc=$?
set -e
printf 'exit=%s\n' "$rc"
[ "$rc" -ne 0 ]; [ "$(git -C "$D/operator" symbolic-ref --short HEAD)" = task ]
printf 'Confirmed: refused stale target and non-default branch; no secondmate actions.\n'
