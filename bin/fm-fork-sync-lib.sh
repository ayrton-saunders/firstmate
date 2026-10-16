#!/usr/bin/env bash
# Primary-only upstream candidate preparation for fm-update.sh --prepare-integration.
# fm_fork_sync_prepare <root> <home> returns 0 prepared/already included,
# 2 absent/consumer, or 1 error. FM_FORK_STATUS, FM_FORK_ORIGIN, FM_FORK_UPSTREAM,
# FM_FORK_PRIMARY, FM_FORK_CANDIDATE and FM_FORK_ATTEMPT are outputs.
# No upstream means no staging or network calls. Linked secondmate homes are
# consumers even though their common Git config contains upstream.
# Only the retained isolated clone merges. Preparation never validates, pushes,
# advances a running home or authorizes landing. Legacy config/fork-publication
# and config/fork-validation files are ignored, not changed.
# An upstream already included in origin returns status settled and no candidate;
# otherwise status prepared reports integration-repo, integration-candidate,
# integration-origin and integration-upstream lines for the separate ship task.
# The update skill owns the separate ship task's no-mistakes PR/CI path,
# explicit merge approval and ancestry-preserving landing.
# Attempts live in <home>/data/fork-sync/attempt.XXXXXXXX and are never deleted.
# origin and upstream defaults come from fresh remote HEAD advertisements.
# All errors retain evidence; failure diagnostics include O/U0/P and attempt
# location without remote URLs. Private operational paths are rejected in both
# the candidate tree and outgoing history, even if later removed.

fm_fork_sync_error() {
  FM_FORK_STATUS=error
  printf 'firstmate: skipped: fork integration %s (O=%s U0=%s P=%s attempt=%s)\n' \
    "$1" "${FM_FORK_ORIGIN:-unknown}" "${FM_FORK_UPSTREAM:-unknown}" \
    "${FM_FORK_PRIMARY:-unknown}" "${FM_FORK_ATTEMPT:-none}" >&2
  return 1
}

fm_fork_remote_default() { # <clone> <remote>; no guesses or cached refs
  local output branch tip
  output=$(git -C "$1" ls-remote --symref "$2" HEAD 2>/dev/null) || return 1
  branch=$(printf '%s\n' "$output" | awk '$1 == "ref:" && $3 == "HEAD" {print $2}')
  tip=$(printf '%s\n' "$output" | awk '$2 == "HEAD" && $1 != "ref:" {print $1}')
  case "$branch" in refs/heads/*) ;; *) return 1 ;; esac
  [ "$(printf '%s\n' "$branch" | wc -l | tr -d ' ')" = 1 ] || return 1
  git check-ref-format "$branch" >/dev/null 2>&1 || return 1
  [ "$(git -C "$1" rev-parse --verify "refs/remotes/$2/${branch#refs/heads/}^{commit}" 2>/dev/null)" = "$tip" ] || return 1
  printf '%s\n' "${branch#refs/heads/}"
}

fm_fork_sync_prepare() {
  local root=$1 home=$2 upstream_config origin upstream pushes branch upstream_branch
  local candidate common primary_branch operation primary_status
  # Public result consumed by callers sourcing this library.
  # shellcheck disable=SC2034
  FM_FORK_STATUS=absent
  FM_FORK_UPSTREAM='' FM_FORK_ORIGIN='' FM_FORK_PRIMARY='' FM_FORK_ATTEMPT='' FM_FORK_CANDIDATE=''
  upstream_config=$(git -C "$root" config --get-regexp '^remote\.upstream\.' 2>/dev/null) || {
    [ "$?" -eq 1 ] || { fm_fork_sync_error 'cannot read upstream configuration'; return 1; }
  }
  [ -n "$upstream_config" ] || return 2
  # A linked home shares the publisher's remote configuration, not its authority.
  if [ -f "$home/.fm-secondmate-home" ] || [ -f "$root/.fm-secondmate-home" ]; then
    common=$(git -C "$root" rev-parse --git-common-dir) || return 1
    if [ "$common" != "$(git -C "$root" rev-parse --git-dir)" ]; then return 2; fi
    fm_fork_sync_error 'standalone secondmate must not configure upstream'; return 1
  fi
  [ -n "$(git -C "$root" config --get remote.upstream.url 2>/dev/null)" ] || { fm_fork_sync_error 'invalid upstream'; return 1; }
  [ -n "$(git -C "$root" config --get remote.origin.url 2>/dev/null)" ] || { fm_fork_sync_error 'invalid origin'; return 1; }
  origin=$(git -C "$root" remote get-url --all origin 2>/dev/null) || { fm_fork_sync_error 'invalid origin'; return 1; }
  upstream=$(git -C "$root" remote get-url --all upstream 2>/dev/null) || { fm_fork_sync_error 'invalid upstream'; return 1; }
  pushes=$(git -C "$root" remote get-url --push --all origin 2>/dev/null) || { fm_fork_sync_error 'invalid publication destination'; return 1; }
  if [ -z "$origin" ] || [ -z "$upstream" ] || [[ "$origin$upstream" == *$'\n'* ]] || [ "$pushes" != "$origin" ] ||
    git -C "$root" config --get-all remote.origin.push >/dev/null 2>&1 ||
    [ "$(git -C "$root" config --bool remote.origin.mirror 2>/dev/null || true)" = true ]; then
    fm_fork_sync_error 'ambiguous or unexpected remote destinations'; return 1
  fi
  case "$origin" in /*|*://*|*:*) ;; *) fm_fork_sync_error 'origin local path must be absolute'; return 1 ;; esac
  case "$upstream" in /*|*://*|*:*) ;; *) fm_fork_sync_error 'upstream local path must be absolute'; return 1 ;; esac
  # Never carry embedded HTTP credentials or URL parameters into attempt config.
  case "$origin $upstream" in *://*@*|*\?*|*\#*) fm_fork_sync_error 'unsafe remote URL'; return 1 ;; esac
  FM_FORK_PRIMARY=$(git -C "$root" rev-parse --verify HEAD) || { fm_fork_sync_error 'missing primary HEAD'; return 1; }
  primary_branch=$(git -C "$root" symbolic-ref --quiet --short HEAD) || { fm_fork_sync_error 'detached primary'; return 1; }
  primary_status=$(git -C "$root" status --porcelain --untracked-files=all) || { fm_fork_sync_error 'primary status unreadable'; return 1; }
  [ -z "$primary_status" ] || { fm_fork_sync_error 'dirty primary'; return 1; }
  for operation in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer; do
    [ ! -e "$(git -C "$root" rev-parse --path-format=absolute --git-path "$operation")" ] || { fm_fork_sync_error 'primary operation in progress'; return 1; }
  done
  [ "$(git -C "$root" rev-parse --is-shallow-repository)" = false ] || { fm_fork_sync_error 'shallow primary'; return 1; }
  mkdir -p "$home/data/fork-sync" || { fm_fork_sync_error 'cannot create attempt directory'; return 1; }
  FM_FORK_ATTEMPT=$(mktemp -d "$home/data/fork-sync/attempt.XXXXXXXX") || { fm_fork_sync_error 'cannot create attempt'; return 1; }
  if ! git clone --quiet --no-checkout --no-local -- "$origin" "$FM_FORK_ATTEMPT/repo" 2>"$FM_FORK_ATTEMPT/transport.log"; then
    fm_fork_sync_error 'origin clone failed'; return 1
  fi
  local repo="$FM_FORK_ATTEMPT/repo"
  [ "$(git -C "$repo" rev-parse --is-shallow-repository)" = false ] || { fm_fork_sync_error 'shallow integration clone'; return 1; }
  git -C "$repo" remote add upstream "$upstream" || { fm_fork_sync_error 'upstream configuration failed'; return 1; }
  if ! git -C "$repo" fetch --quiet origin 2>"$FM_FORK_ATTEMPT/transport.log" ||
    ! git -C "$repo" fetch --quiet upstream 2>>"$FM_FORK_ATTEMPT/transport.log"; then
    fm_fork_sync_error 'remote fetch failed'; return 1
  fi
  branch=$(fm_fork_remote_default "$repo" origin) || { fm_fork_sync_error 'origin default missing or changed during fetch'; return 1; }
  upstream_branch=$(fm_fork_remote_default "$repo" upstream) || { fm_fork_sync_error 'upstream default missing or changed during fetch'; return 1; }
  FM_FORK_ORIGIN=$(git -C "$repo" rev-parse "refs/remotes/origin/$branch")
  FM_FORK_UPSTREAM=$(git -C "$repo" rev-parse "refs/remotes/upstream/$upstream_branch")
  if [ "$primary_branch" != "$branch" ] ||
    [ "$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" != "refs/remotes/origin/$branch" ]; then
    fm_fork_sync_error 'primary/default branch mismatch'; return 1
  fi
  # Import the primary HEAD for proof without fetching/mutating the primary.
  git -C "$repo" fetch --quiet "$root" "$FM_FORK_PRIMARY" 2>>"$FM_FORK_ATTEMPT/transport.log" || { fm_fork_sync_error 'primary ancestry import failed'; return 1; }
  git -C "$repo" merge-base --is-ancestor "$FM_FORK_PRIMARY" "$FM_FORK_ORIGIN" || { fm_fork_sync_error 'primary has unpublished or diverged work'; return 1; }
  git -C "$repo" merge-base "$FM_FORK_ORIGIN" "$FM_FORK_UPSTREAM" >/dev/null || { fm_fork_sync_error 'unrelated histories'; return 1; }
  if git -C "$repo" merge-base --is-ancestor "$FM_FORK_UPSTREAM" "$FM_FORK_ORIGIN"; then
    FM_FORK_STATUS=settled
    printf 'fork upstream included: %s\n' "$FM_FORK_UPSTREAM"
    return 0
  fi
  git -C "$repo" checkout --quiet -b fork-integration "$FM_FORK_ORIGIN" || { fm_fork_sync_error 'integration checkout failed'; return 1; }
  if ! git -C "$repo" -c core.hooksPath=/dev/null merge --ff --no-edit "$FM_FORK_UPSTREAM" >"$FM_FORK_ATTEMPT/merge.log" 2>&1; then
    git -C "$repo" diff --name-only --diff-filter=U >"$FM_FORK_ATTEMPT/conflicts"
    fm_fork_sync_error 'merge failed; unresolved paths in attempt/conflicts'; return 1
  fi
  candidate=$(git -C "$repo" rev-parse HEAD)
  # Ignore rules are not evidence that confidential operational material was
  # never committed. Reject both the candidate tree and the outgoing history.
  if [ -n "$(git -C "$repo" ls-tree -r --name-only "$candidate" -- data state config projects .env .no-mistakes)" ] ||
    [ -n "$(git -C "$repo" log --full-history --format=%H "$FM_FORK_ORIGIN..$candidate" -- data state config projects .env .no-mistakes)" ]; then
    fm_fork_sync_error 'private operational paths in candidate/history'; return 1
  fi
  if [ -n "$(git -C "$repo" status --porcelain --untracked-files=all)" ] ||
    ! git -C "$repo" merge-base --is-ancestor "$FM_FORK_ORIGIN" "$candidate" ||
    ! git -C "$repo" merge-base --is-ancestor "$FM_FORK_UPSTREAM" "$candidate"; then
    fm_fork_sync_error 'candidate cleanliness or ancestry proof failed'; return 1
  fi
  # shellcheck disable=SC2034 # Public results for sourcing callers.
  FM_FORK_STATUS=prepared FM_FORK_CANDIDATE=$candidate
  printf 'integration-repo: %s\n' "$repo"
  printf 'integration-candidate: %s\n' "$candidate"
  printf 'integration-origin: %s\n' "$FM_FORK_ORIGIN"
  printf 'integration-upstream: %s\n' "$FM_FORK_UPSTREAM"
}
