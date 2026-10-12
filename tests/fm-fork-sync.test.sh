#!/usr/bin/env bash
# Executable Git integration/publication tests; all remotes are disposable.
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
  printf 'enabled\n' > "$w/home/config/fork-publication"
  cat > "$w/validate" <<'SH'
#!/usr/bin/env bash
set -eu
git merge-base --is-ancestor "$1" HEAD
git merge-base --is-ancestor "$2" HEAD
SH
  chmod +x "$w/validate"
  printf '%s\n' "$w/validate" > "$w/home/config/fork-validation"
}
refused() {
  if fm_fork_sync_prepare "$w/p" "$w/home" >"$w/result" 2>&1; then fail "$1 accepted"; fi
  assert_equals "$O" "$(git -C "$w/fork" rev-parse main)" "$1 changed fork"
  assert_equals "$O" "$(git -C "$w/p" rev-parse HEAD)" "$1 changed primary"
  assert_grep "$2" "$w/result" "$1 diagnostic"
}
world merge
fm_fork_sync_prepare "$w/p" "$w/home" || fail 'merge publication failed'
M=$(git -C "$w/fork" rev-parse main)
assert_equals 2 "$(git -C "$w/fork" rev-list --parents -n1 "$M" | awk '{print NF-1}')" 'merge must retain both parents'
git -C "$w/fork" merge-base --is-ancestor "$O" "$M" || fail 'personal history lost'
git -C "$w/fork" merge-base --is-ancestor "$U" "$M" || fail 'upstream history lost'
assert_equals "$O" "$(git -C "$w/p" rev-parse HEAD)" 'prepare moved primary'
fm_fork_sync_prepare "$w/p" "$w/home" || fail 'repeat failed'
assert_equals "$M" "$(git -C "$w/fork" rev-parse main)" 'repeat minted another merge'
pass 'isolated merge preserves fork/upstream, independent defaults and idempotence'

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
world approval
rm "$w/home/config/fork-publication"
refused approval 'publication approval missing'
world validator
rm "$w/home/config/fork-validation"
refused validator 'validation policy missing'
world validation
printf '#!/usr/bin/env bash\nexit 1\n' > "$w/validate"
refused validation 'validation/review refused'
assert_present "$FM_FORK_ATTEMPT/repo/personal" 'failed candidate not retained'
pass 'malformed upstream and unapproved or failing validation refuse publication'

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
pass 'unsafe primary, changed defaults and extra push destinations refuse publication'

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
git -C "$w/p" add shared
git -C "$w/p" commit -qm personal-shared
git -C "$w/p" push -q origin main
O=$(git -C "$w/p" rev-parse HEAD)
printf 'upstream shared\n' > "$w/u/shared"
git -C "$w/u" add shared
git -C "$w/u" commit -qm upstream-shared
git -C "$w/u" push -q origin trunk
refused conflict 'unresolved paths'
assert_grep shared "$FM_FORK_ATTEMPT/conflicts" 'conflict paths retained'
assert_present "$FM_FORK_ATTEMPT/repo/.git/MERGE_HEAD" 'conflict was aborted'
assert_absent "$w/p/.git/MERGE_HEAD" 'primary conflict created'
pass 'conflicts remain unresolved only in integration clone'

world rejected
printf '#!/usr/bin/env bash\nexit 1\n' > "$w/fork/hooks/pre-receive"
chmod +x "$w/fork/hooks/pre-receive"
refused rejected 'publication failed or unknown'
pass 'server push rejection preserves fork and candidate'

world race
# A validator simulates a concurrent publisher, independently of the candidate.
cat >> "$w/validate" <<SH
printf 'concurrent\\n' > '$w/p/race'
git -C '$w/p' add race
git -C '$w/p' commit -qm concurrent
git -C '$w/p' push -q origin main
SH
if fm_fork_sync_prepare "$w/p" "$w/home" >"$w/result" 2>&1; then fail 'race accepted'; fi
assert_equals "$(git -C "$w/p" rev-parse HEAD)" "$(git -C "$w/fork" rev-parse main)" 'concurrent publisher overwritten'
assert_grep 'publication failed or unknown' "$w/result" 'race diagnostic'
pass 'concurrent fork advance is never overwritten'

world unknown
# Validation arms a Git wrapper that fails only the verification fetch.
mkdir "$w/fakebin"
real_git=$(command -v git)
cat > "$w/fakebin/git" <<SH
#!/usr/bin/env bash
if [[ "\$*" == *' fetch --quiet origin'* ]] && [ -e '$w/pushed' ]; then exit 1; fi
'$real_git' "\$@"
rc=\$?
if [[ "\$*" == *' push origin '* ]] && [ "\$rc" -eq 0 ]; then touch '$w/pushed'; fi
exit "\$rc"
SH
chmod +x "$w/fakebin/git"
if PATH="$w/fakebin:$PATH" fm_fork_sync_prepare "$w/p" "$w/home" >"$w/result" 2>&1; then fail 'unknown publication accepted'; fi
assert_grep 'publication outcome unknown' "$w/result" 'unknown publication diagnostic'
fm_fork_sync_prepare "$w/p" "$w/home" || fail 'published retry did not recover'
pass 'lost post-push verification is unknown; fresh retry proves inclusion'

world fast_forward
# A fresh fork seeded at the shared base has no personal commit to merge.
git init -q --bare "$w/ff-fork"
git -C "$w/ff-fork" symbolic-ref HEAD refs/heads/main
git -C "$w/u" push -q "$w/ff-fork" 'HEAD^:refs/heads/main'
git clone -q "$w/ff-fork" "$w/consumer"
git -C "$w/consumer" remote add upstream "$w/upstream"
fm_fork_sync_prepare "$w/consumer" "$w/home" || fail 'upstream fast-forward failed'
assert_equals "$U" "$(git -C "$w/ff-fork" rev-parse main)" 'fast-forward created unnecessary merge'
pass 'integration fast-forward publishes exact upstream tip'

world private_paths
mkdir -p "$w/u/data"
printf 'private\n' > "$w/u/data/private"
git -C "$w/u" add data/private
git -C "$w/u" commit -qm private-path
# Even removed private material must not be published in intermediate history.
git -C "$w/u" rm -q data/private
git -C "$w/u" commit -qm remove-private-path
git -C "$w/u" push -q origin trunk
refused private_paths 'private operational paths'
pass 'private operational material in outgoing history refuses publication'

world candidate_mutation
printf '#!/usr/bin/env bash\nprintf changed >> personal\n' > "$w/validate"
refused candidate_mutation 'candidate changed'
pass 'validation cannot silently alter the candidate'

echo '# all fm-fork-sync tests passed'
