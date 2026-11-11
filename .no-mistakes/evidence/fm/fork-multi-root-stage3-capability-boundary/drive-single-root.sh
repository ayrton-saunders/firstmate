#!/usr/bin/env bash
set -eu
ROOT=$PWD
scratch=$(mktemp -d "$ROOT/.nm-single-root.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME='Local Validation' GIT_AUTHOR_EMAIL=validation@example.invalid
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export HOME="$scratch/account"
mkdir -p "$HOME"
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_REMOTE_JOB_STATE_OVERRIDE FM_REMOTE_JOB_STATE_ROOT
printf 'SCENARIO 4b: ordinary single-root fast-forward and queue with no enrollment\n'
git init -q "$scratch/source"
printf 'A\n' > "$scratch/source/payload"
git -C "$scratch/source" add payload
git -C "$scratch/source" commit -qm A
git clone -q --no-local "$scratch/source" "$scratch/destination"
printf 'B\n' > "$scratch/source/payload"
git -C "$scratch/source" commit -qam B
B=$(git -C "$scratch/source" rev-parse HEAD)
. "$ROOT/bin/fm-ff-lib.sh"
FF_IMPORT_FROM="$scratch/source"
ff_target "$scratch/destination" home "$B"
[ "$FF_STATUS" = updated ]
printf 'selected HEAD=%s; working file=' "$(git -C "$scratch/destination" rev-parse HEAD)"
head -n 1 "$scratch/destination/payload"
[ "$(git -C "$scratch/destination" rev-parse HEAD)" = "$B" ]
[ "$(head -n 1 "$scratch/destination/payload")" = B ]
ff_target "$scratch/destination" home "$B"
[ "$FF_STATUS" = current ]
[ -z "$(git -C "$scratch/destination" status --porcelain)" ]
. "$ROOT/bin/fm-remote-job-lib.sh"
fm_remote_job_prepare_state "$HOME"
fm_remote_job_launchagent_paths "$HOME"
printf 'state=%s\njobs=%s\nlabel=%s\nplist=%s\n' "${FM_REMOTE_JOB_STATE#"$HOME"}" "${FM_REMOTE_JOB_JOBS#"$HOME"}" "$FM_REMOTE_JOB_LABEL" "${FM_REMOTE_JOB_LAUNCH_AGENT_PLIST#"$HOME"}"
[ "$FM_REMOTE_JOB_STATE" = "$HOME/.firstmate/remote-job" ]
[ "$FM_REMOTE_JOB_LABEL" = dev.firstmate.remote-job ]
[ ! -e "$HOME/Library/LaunchAgents/dev.firstmate.remote-job.plist" ]
printf 'No enrollment created; no service rendered or installed. Disposable repositories cleaned on exit.\n'
