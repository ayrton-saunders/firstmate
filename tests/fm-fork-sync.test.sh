#!/usr/bin/env bash
# Candidate preparation is tested against real disposable Git remotes.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-fork-sync-lib.sh
. "$ROOT/bin/fm-fork-sync-lib.sh"
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-fork-sync-tests)

world() {
  w="$TMP_ROOT/$1"
  mkdir -p "$w/home/config"
  git init -q --bare "$w/upstream"
  git -C "$w/upstream" symbolic-ref HEAD refs/heads/trunk
  git clone -q "$w/upstream" "$w/u" 2>/dev/null
  printf 'base\n' > "$w/u/shared"
  git -C "$w/u" add shared
  git -C "$w/u" commit -qm base
  git -C "$w/u" push -q origin trunk
  git clone -q --bare "$w/upstream" "$w/fork"
  git clone -q "$w/fork" "$w/p"
  git -C "$w/p" branch -m main
  printf 'personal\n' > "$w/p/personal"
  git -C "$w/p" add personal
  git -C "$w/p" commit -qm personal
  git -C "$w/p" push -q origin main
  git -C "$w/fork" symbolic-ref HEAD refs/heads/main
  git -C "$w/p" remote set-head origin main
  git -C "$w/p" remote add upstream "$w/upstream"
  printf 'upstream\n' > "$w/u/new"
  git -C "$w/u" add new
  git -C "$w/u" commit -qm upstream
  git -C "$w/u" push -q origin trunk
  O=$(git -C "$w/fork" rev-parse main)
  U=$(git -C "$w/upstream" rev-parse trunk)
}
refused() {
  if fm_fork_sync_prepare "$w/p" "$w/home" >"$w/result" 2>&1; then fail "$1 accepted"; fi
  assert_equals "$O" "$(git -C "$w/fork" rev-parse main)" "$1 changed fork"
  assert_equals "$O" "$(git -C "$w/p" rev-parse HEAD)" "$1 changed primary"
  assert_grep "$2" "$w/result" "$1 diagnostic"
}

world merge
# Old private approvals must never turn preparation into validation/publication.
printf 'enabled\n' > "$w/home/config/fork-publication"
printf '#!/usr/bin/env bash\ntouch "%s/validator-called"\nexit 1\n' "$w" > "$w/validate"
chmod +x "$w/validate"
printf '%s\n' "$w/validate" > "$w/home/config/fork-validation"
fm_fork_sync_prepare "$w/p" "$w/home" >"$w/result" || fail 'merge preparation failed'
repo="$FM_FORK_ATTEMPT/repo"
C=$(git -C "$repo" rev-parse HEAD)
assert_equals prepared "$FM_FORK_STATUS" 'preparation status'
assert_equals "$C" "$FM_FORK_CANDIDATE" 'candidate output'
assert_equals 2 "$(git -C "$repo" rev-list --parents -n1 "$C" | awk '{print NF-1}')" 'merge must retain both parents'
git -C "$repo" merge-base --is-ancestor "$O" "$C" || fail 'personal history lost'
git -C "$repo" merge-base --is-ancestor "$U" "$C" || fail 'upstream history lost'
assert_grep "integration-candidate: $C" "$w/result" 'candidate identity not reported'
assert_grep "integration-origin: $O" "$w/result" 'origin identity not reported'
assert_grep "integration-upstream: $U" "$w/result" 'upstream identity not reported'
assert_grep "integration-repo: $repo" "$w/result" 'retained repository not reported'
assert_equals "$O" "$(git -C "$w/fork" rev-parse main)" 'preparation published'
assert_equals "$O" "$(git -C "$w/p" rev-parse HEAD)" 'preparation moved primary'
assert_absent "$w/validator-called" 'preparation ran the private validator'
assert_absent "$FM_FORK_ATTEMPT/push.log" 'preparation attempted publication'
assert_absent "$FM_FORK_ATTEMPT/validation.log" 'preparation attempted local CI'
pass 'preparation preserves and identifies both histories without validating, publishing, or landing'

# Simulate the separate, approved ancestry-preserving PR landing in this fixture.
git -C "$repo" push -q origin HEAD:refs/heads/main
fm_fork_sync_prepare "$w/p" "$w/home" >"$w/result" || fail 'already integrated retry failed'
assert_equals settled "$FM_FORK_STATUS" 'already integrated status'
assert_equals '' "$FM_FORK_CANDIDATE" 'settled retry reported stale candidate'
assert_grep 'fork upstream included:' "$w/result" 'already integrated outcome'
assert_equals "$C" "$(git -C "$w/fork" rev-parse main)" 'settled retry moved origin'
pass 'an ancestry-preserving landing makes later preparation a no-op'

world absent
git -C "$w/p" remote remove upstream
rc=0
fm_fork_sync_prepare "$w/p" "$w/home" || rc=$?
assert_equals 2 "$rc" 'absent return'
assert_absent "$w/home/data/fork-sync" 'absent upstream created staging'
pass 'absent upstream does not stage'

world malformed
git -C "$w/p" remote remove upstream
git -C "$w/p" config remote.upstream.fetch '+refs/heads/*:refs/remotes/upstream/*'
refused malformed 'invalid upstream'
world dirty
printf 'dirty\n' > "$w/p/untracked"
refused dirty 'dirty primary'
assert_absent "$w/home/data/fork-sync" 'dirty primary staged'
world wrong
git -C "$w/p" checkout -qb topic
refused wrong 'primary/default branch mismatch'
world changed_default
git -C "$w/fork" symbolic-ref HEAD refs/heads/trunk
refused changed_default 'primary/default branch mismatch'
world pushurl
git -C "$w/p" config remote.origin.pushurl "$w/upstream"
refused pushurl 'unexpected remote destinations'
world extra_pushurl
git -C "$w/p" config --add remote.origin.pushurl "$w/fork"
git -C "$w/p" config --add remote.origin.pushurl "$w/upstream"
refused extra_pushurl 'unexpected remote destinations'
world shallow
printf '%s\n' "$O" > "$w/p/.git/shallow"
refused shallow 'shallow primary'
pass 'unsafe primary and ambiguous remote destinations remain refused'

world ahead
printf 'ahead\n' > "$w/p/ahead"
git -C "$w/p" add ahead
git -C "$w/p" commit -qm ahead
P=$(git -C "$w/p" rev-parse HEAD)
if fm_fork_sync_prepare "$w/p" "$w/home" >"$w/result" 2>&1; then fail 'ahead accepted'; fi
assert_equals "$P" "$(git -C "$w/p" rev-parse HEAD)" 'ahead work moved'
assert_equals "$O" "$(git -C "$w/fork" rev-parse main)" 'ahead work published'
assert_grep 'unpublished or diverged' "$w/result" 'ahead diagnostic'
pass 'unpublished primary work stays intact'

world conflict
printf 'personal shared\n' > "$w/p/shared"
git -C "$w/p" commit -qam personal-shared
git -C "$w/p" push -q origin main
O=$(git -C "$w/p" rev-parse HEAD)
printf 'upstream shared\n' > "$w/u/shared"
git -C "$w/u" commit -qam upstream-shared
git -C "$w/u" push -q origin trunk
refused conflict 'unresolved paths'
assert_grep shared "$FM_FORK_ATTEMPT/conflicts" 'conflict paths retained'
assert_present "$FM_FORK_ATTEMPT/repo/.git/MERGE_HEAD" 'conflict was aborted'
assert_absent "$w/p/.git/MERGE_HEAD" 'primary conflict created'
pass 'conflicts remain unresolved only in the retained integration clone'

world fast_forward
# With no fork contribution the exact upstream tip is the candidate, not a merge.
git init -q --bare "$w/ff-fork"
git -C "$w/ff-fork" symbolic-ref HEAD refs/heads/main
git -C "$w/u" push -q "$w/ff-fork" 'HEAD^:refs/heads/main'
git clone -q "$w/ff-fork" "$w/consumer"
git -C "$w/consumer" remote add upstream "$w/upstream"
fm_fork_sync_prepare "$w/consumer" "$w/home" >"$w/result" || fail 'fast-forward preparation failed'
assert_equals "$U" "$FM_FORK_CANDIDATE" 'fast-forward minted an unnecessary merge'
assert_equals "$(git -C "$w/u" rev-parse HEAD^)" "$(git -C "$w/ff-fork" rev-parse main)" 'fast-forward published candidate'
pass 'fast-forward preparation retains the exact upstream candidate'

world private_paths
mkdir -p "$w/u/data"
printf 'private\n' > "$w/u/data/private"
git -C "$w/u" add data/private
git -C "$w/u" commit -qm private-path
git -C "$w/u" rm -q data/private
git -C "$w/u" commit -qm remove-private-path
git -C "$w/u" push -q origin trunk
refused private_paths 'private operational paths'
pass 'private operational material in outgoing history refuses preparation'

echo '# all fm-fork-sync tests passed'
