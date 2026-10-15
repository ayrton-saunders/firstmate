#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - A dirty, offline, wrong-branch, or genuinely unique diverged target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#     Divergence leaves a durable reconciliation record, while a clean local
#     result already present upstream after a squash merge heals automatically.
#   - The update only fast-forwards; it never creates a merge commit, but may
#     consume an ancestry-preserving integration already landed in origin.
#     Advancing one worktree never disturbs another worktree's checkout or the
#     shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     the two secondmate action sets are disjoint and correctly gated -
#     restart-secondmates carries EVERY live mate this pass left on origin's tip
#     whose recorded runtime can prove a restart, INCLUDING one that was already
#     there and one whose advance touched no instruction surface, because a
#     restart is also what re-resolves launch-time harness wiring; a live mate
#     whose runtime cannot prove a restart falls to nudge-secondmates; and a mate
#     whose home was skipped or whose endpoint is stopped gets no action at all.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/fakebin" "$w/fake"
  : > "$w/fake/windows"
  cat > "$w/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) cat "$FM_FAKE_DIR/windows" ;;
  display-message)
    target=
    for arg in "$@"; do
      case "$arg" in main:fm-*) target=$arg ;; esac
    done
    case "${*: -1}" in
      *pane_current_command*)
        id=${target##*fm-}
        if [ -e "$FM_FAKE_DIR/dead-$id" ]; then printf 'zsh\n'; else printf 'claude\n'; fi
        ;;
      *) printf '\n' ;;
    esac
    ;;
esac
SH
  chmod +x "$w/fakebin/tmux"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$w/seed/bin/fm-remote-secondmate-control.sh"
  chmod +x "$w/seed/bin/fm-remote-secondmate-control.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
# The recorded runtime matters to the action split, so it is part of the fixture:
# harness defaults to a control-verified adapter on the default (tmux) backend,
# which is what makes a restart provable. Pass a backend to model one that cannot
# prove an agent stopped.
add_sm() {
  local w=$1 id=$2 harness=${3:-claude} backend=${4:-}
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s/%s\n' "$w" "$id"
    printf 'project=%s/%s\n' "$w" "$id"
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    [ -z "$backend" ] || printf 'backend=%s\n' "$backend"
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf 'fm-%s\n' "$id" >> "$w/fake/windows"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the whole instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=bin changes only bin/, which
# a running agent re-executes rather than holding; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  if [ "$mode" = bin ]; then
    printf 'echo b-%s\n' "$RANDOM" > "$w/seed/bin/tool.sh"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  shift
  PATH="$w/fakebin:$PATH" FM_FAKE_DIR="$w/fake" \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" "$@" 2>/dev/null
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "restart-secondmates: fm-sm1" "a changed AGENTS.md must move the secondmate into the restart set"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  assert_absent "$w/home/data/fork-sync" "legacy update must not stage integration"
  pass "T1 main + secondmate fast-forward (single-parent), reread + restart signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The running firstmate reads nothing new, but the mate's agent still holds its
  # launch-time wiring from before the pass, which only a restart re-resolves.
  assert_contains "$out" "restart-secondmates: fm-sm1" \
    "a live mate on the new tip must restart even when no instruction file moved"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"
  pass "T3 a non-instruction advance still restarts the live secondmate"
}

# --- T3b: a bin/-only advance restarts too ---------------------------------
# Helpers under bin/ do reload themselves on the next call, but the mate's agent
# still froze its launch-time harness wiring before this pass, so the restart is
# not redundant and the old bin/-only carve-out no longer applies.
test_bin_only_advance_restarts() {
  local w out
  w=$(new_world t3b)
  add_sm "$w" sm1
  bump_origin "$w" bin

  out=$(run_update "$w")

  assert_contains "$out" "reread-firstmate: yes" "a bin/ change is still an instruction-surface advance"
  assert_contains "$out" "restart-secondmates: fm-sm1" "a bin/-only advance must still restart the live mate"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"
  pass "T3b a bin/-only advance restarts the secondmate"
}

# --- T3c: an unverifiable runtime receives the fallback nudge ----------------
test_unprovable_runtime_gets_fallback_nudge() {
  local w out
  w=$(new_world t3c)
  # zellij has no recovery-grade agent-state classifier, so no restart there can
  # ever prove the old agent stopped and the replacement came up.
  add_sm "$w" sm1 claude zellij
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "restart-secondmates: none" "an unprovable runtime must stay out of the restart set"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "an unverifiable runtime must retain the fallback re-read nudge"
  pass "T3c an unverifiable secondmate receives the fallback nudge"
}

# --- T3d: an already-stopped mate is left to startup recovery ---------------
test_dead_secondmate_gets_no_action() {
  local w out
  w=$(new_world t3d)
  add_sm "$w" sm1
  : > "$w/fake/dead-sm1"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: updated " "the stopped mate's safe checkout still advances"
  assert_contains "$out" "restart-secondmates: none" "a stopped mate must not be sent to restart"
  assert_contains "$out" "nudge-secondmates: none" "a stopped mate must not receive a queued nudge"
  pass "T3d an already-stopped secondmate is left to startup recovery"
}

# --- T3e: a legacy remote advance still restarts ---------------------------
# The host's instr= suffix is reporting detail; the parent no longer routes on it,
# so an older host that cannot report a diff can no longer suppress the restart.
test_legacy_remote_advance_restarts() {
  local w out fake_ssh
  w=$(new_world t3e)
  fake_ssh="$w/fakebin/fake-ssh"
  cat > "$fake_ssh" <<'SH'
#!/usr/bin/env bash
set -u
cat > /dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
argv_b64=$4
decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D; }
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done < <(decode "$argv_b64")
case "${rargs[1]:-}" in
  update) printf 'synced: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
  state) printf 'alive\n' ;;
  *) exit 91 ;;
esac
SH
  chmod +x "$fake_ssh"
  cat > "$w/home/state/sm1.meta" <<EOF
window=remote:sm1
endpoint_task_id=sm1
worktree=/srv/sm1
project=/srv/sm1
harness=claude
kind=secondmate
home=/srv/sm1
remote_host=remote-mac
remote_backend=herdr
EOF
  printf -- '- sm1 - remote domain (host: remote-mac; root: /srv/fm; home: /srv/sm1; scope: things; projects: p; added 2026-09-03)\n' \
    > "$w/home/data/secondmates.md"

  out=$(FM_TEST_SSH_BIN="$fake_ssh" run_update "$w")

  assert_contains "$out" "remote secondmate sm1: updated on remote-mac" \
    "the legacy remote advance was not accepted"
  assert_contains "$out" "restart-secondmates: fm-sm1" \
    "a live remote mate on the new tip must restart even when the host reports no instruction diff"
  assert_contains "$out" "nudge-secondmates: none" \
    "a restarted remote mate must not also be steered"
  pass "T3e a legacy remote advance still restarts the live remote mate"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before marker second_out
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_contains "$out" "reconciliation required (record:" "diverged skip is actionable"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  marker="$w/home/state/.secondmate-update-reconcile/sm1.pending"
  assert_present "$marker" "diverged secondmate did not retain a durable reconciliation record"
  assert_grep 'schema=fm-secondmate-update-reconcile.v1' "$marker" "divergence record schema missing"
  assert_grep "local_commit=$before" "$marker" "divergence record lost the protected local commit"

  second_out=$(run_update "$w")
  assert_contains "$second_out" "reconciliation required (record: $marker)" \
    "a later update did not surface the durable divergence"
  pass "T5 diverged secondmate is preserved and durably actionable"
}

test_squash_merged_divergence_reconciles() {
  local w branch_base local_tip out marker
  w=$(new_world t5b)
  add_sm "$w" sm1
  branch_base=$(git -C "$w/sm1" rev-parse HEAD)

  printf 'v2\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add AGENTS.md
  git -C "$w/sm1" commit -qm local-instructions
  printf 'echo squash-landed\n' > "$w/sm1/bin/tool.sh"
  git -C "$w/sm1" add bin/tool.sh
  git -C "$w/sm1" commit -qm local-tooling
  local_tip=$(git -C "$w/sm1" rev-parse HEAD)

  bump_origin "$w" readme
  out=$(run_update "$w")
  marker="$w/home/state/.secondmate-update-reconcile/sm1.pending"
  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" \
    "unique local work was not initially protected"
  assert_present "$marker" "initial divergence did not leave its durable record"

  git -C "$w/sm1" diff "$branch_base" "$local_tip" | git -C "$w/seed" apply
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm squash-local-contribution
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: reconciled redundant divergence" \
    "the squash-merged local result did not heal"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "reconciled secondmate did not reach origin/main"
  assert_absent "$marker" "successful reconciliation left the divergence marker behind"
  assert_contains "$out" "restart-secondmates: fm-sm1" \
    "the reconciled live secondmate was excluded from restart"
  pass "T5b squash-merged divergence heals and rejoins live convergence"
}

# --- T6: the git side is idempotent; the restart set is not -----------------
# This is the SSHHIP case: that mate's home was already at the target commit, so
# the old classifier skipped it entirely and its agent kept running the launch-time
# wiring it started with. An already-current live mate must still be restarted.
test_already_current_secondmate_still_restarts() {
  local w out restart_line
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing left to fast-forward

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  assert_contains "$restart_line" "fm-sm1" \
    "an already-current live secondmate must still be in the restart set"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"
  pass "T6 an already-current live secondmate is still restarted"
}

# --- T6b: an already-current mate that cannot be restarted stays honest -----
# Unconditional restart must not become an unconditional CLAIM of one.
test_already_current_unprovable_mate_is_nudged() {
  local w out restart_line nudge_line
  w=$(new_world t6b)
  add_sm "$w" sm1 claude zellij
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: the home is already on the tip

  assert_contains "$out" "secondmate sm1: already current" "the mate must need no advance"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_not_contains "$restart_line" "sm1" "an unprovable runtime must stay out of the restart set"
  assert_contains "$nudge_line" "fm-sm1" "an unprovable runtime must keep the honest re-read steer"
  pass "T6b an already-current mate with an unprovable runtime is steered, not claimed as reloaded"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  local restart_line
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  assert_contains "$restart_line" "fm-sm1" "live-meta secondmate is restarted"
  assert_not_contains "$restart_line" "reg1" "registry-only secondmate without live metadata gets no action"
  assert_not_contains "$nudge_line" "sm1" "a restarted secondmate must not also be nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

# --- T12: a self-update rebinds a locally armed watch on the primary --------
# A self-update fast-forwards bin/ in place, changing bytes an armed
# fm-procevent-when watch's trust binding was hashed against with no
# tampering involved; without a rebind the very next fire would be refused.
test_primary_update_rebinds_local_watch() {
  local w before_hash after_hash out spec
  w=$(new_world t12)
  mkdir -p "$w/seed/bin"
  printf "#!/usr/bin/env bash\necho v1 >> \"\$1\"\n" > "$w/seed/bin/watched-action.sh"
  chmod +x "$w/seed/bin/watched-action.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm add-watched-action
  git -C "$w/seed" push -q origin main
  git -C "$w/main" pull -q origin main

  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$ROOT/bin/fm-procevent-when.sh" \
    arm rebind-primary --interval 60 --stable 1 \
    --condition true --action "$w/main/bin/watched-action.sh" "$w/rebind.log" >/dev/null
  spec="$w/home/state/when/when-rebind-primary.spec"
  before_hash=$(grep '^action_sha256=' "$spec")

  printf "#!/usr/bin/env bash\necho v2 >> \"\$1\"\n" > "$w/seed/bin/watched-action.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm bump-watched-action
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "the primary still advanced"
  assert_contains "$out" "rebound: when-rebind-primary" "the primary self-update rebound its own locally armed watch"
  after_hash=$(grep '^action_sha256=' "$spec")
  [ "$before_hash" != "$after_hash" ] \
    || fail "the watch's trust binding was not refreshed to match the updated action bytes"
  pass "T12 a self-update rebinds a locally armed watch on the primary"
}

test_fork_consumption_and_explicit_preparation() {
  local w out fork_tip upstream_tip repo candidate real_git target
  w=$(new_world fork)
  add_sm "$w" linked
  git clone -q "$w/origin.git" "$w/standalone"
  printf 'solo\n' > "$w/standalone/.fm-secondmate-home"
  printf -- '- solo - test consumer (home: %s; scope: test; projects: ; added 2026-10-12)\n' "$w/standalone" > "$w/home/data/secondmates.md"
  git clone -q --bare "$w/origin.git" "$w/upstream.git"
  git clone -q "$w/upstream.git" "$w/upstream"
  git -C "$w/main" remote add upstream "$w/upstream.git"
  bump_origin "$w" neutral
  fork_tip=$(git -C "$w/origin.git" rev-parse main)
  printf 'upstream instructions\n' > "$w/upstream/AGENTS.md"
  git -C "$w/upstream" commit -qam upstream
  git -C "$w/upstream" push -q origin main
  upstream_tip=$(git -C "$w/upstream" rev-parse HEAD)
  [ "$fork_tip" != "$upstream_tip" ] || fail 'fixture did not separate origin and upstream'
  mkdir -p "$w/home/config"
  printf 'enabled\n' > "$w/home/config/fork-publication"
  printf '#!/usr/bin/env bash\ntouch "%s/validator-called"\nexit 1\n' "$w" > "$w/validator"
  chmod +x "$w/validator"
  printf '%s\n' "$w/validator" > "$w/home/config/fork-validation"
  # Watch the real executable seam, not implementation bytes. No updater path
  # may publish, even with the previous operator approvals still present.
  real_git=$(command -v git)
  cat > "$w/fakebin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = push ]; then touch "$w/push-called"; exit 97; fi
done
exec "$real_git" "\$@"
SH
  chmod +x "$w/fakebin/git"
  out=$(run_update "$w") || fail 'origin consumption attempted upstream validation'
  assert_absent "$w/validator-called" 'consumption invoked the old validator'
  assert_absent "$w/push-called" 'consumption tried publication'
  assert_absent "$w/home/data/fork-sync" 'consumption staged upstream'
  assert_contains "$out" 'secondmate solo: updated' 'standalone did not converge'
  assert_contains "$out" 'restart-secondmates: fm-linked' 'settled mate not restarted'
  assert_contains "$out" 'reread-firstmate: no' 'README-only fork update changed reread policy'
  assert_contains "$out" 'nudge-secondmates: none' 'restart/nudge sets overlapped'
  for target in main linked standalone; do
    assert_equals "$fork_tip" "$(git -C "$w/$target" rev-parse HEAD)" "$target missed approved origin tip"
  done
  out=$(run_update "$w" --prepare-integration) || fail 'explicit integration preparation failed'
  repo=$(printf '%s\n' "$out" | awk '/^integration-repo: / {sub(/^integration-repo: /, ""); print}')
  candidate=$(printf '%s\n' "$out" | awk '/^integration-candidate: / {print $2}')
  assert_equals "$candidate" "$(git -C "$repo" rev-parse HEAD)" 'reported candidate identity differs'
  git -C "$repo" merge-base --is-ancestor "$fork_tip" "$candidate" || fail 'candidate lost fork ancestry'
  git -C "$repo" merge-base --is-ancestor "$upstream_tip" "$candidate" || fail 'candidate lost upstream ancestry'
  assert_absent "$w/validator-called" 'preparation invoked local CI'
  assert_absent "$w/push-called" 'preparation tried publication'
  assert_not_contains "$out" 'restart-secondmates:' 'preparation emitted update actions'
  for target in main linked standalone; do
    assert_equals "$fork_tip" "$(git -C "$w/$target" rev-parse HEAD)" 'preparation moved a running home'
  done
  assert_equals "$fork_tip" "$(git -C "$w/origin.git" rev-parse main)" 'preparation moved origin'
  # A separate approved PR landing is simulated only on this disposable origin.
  # The updater must consume that exact candidate without preparing it again.
  git -C "$w/seed" fetch -q "$repo" "$candidate"
  git -C "$w/seed" merge -q --ff-only "$candidate"
  git -C "$w/seed" push -q origin main
  fork_tip=$candidate
  out=$(run_update "$w") || fail 'landed integration was not consumed'
  assert_contains "$out" 'reread-firstmate: yes' 'landed instruction update missed reread'
  assert_contains "$out" 'restart-secondmates: fm-linked' 'landed update missed restart'
  assert_contains "$out" 'nudge-secondmates: none' 'landed update overlapped actions'
  for target in main linked standalone; do
    assert_equals "$candidate" "$(git -C "$w/$target" rev-parse HEAD)" "$target missed exact landed candidate"
    git -C "$w/$target" merge-base --is-ancestor "$upstream_tip" HEAD || fail "$target lost landed upstream ancestry"
  done
  assert_absent "$w/validator-called" 'landed consumption invoked local CI'
  assert_absent "$w/push-called" 'landed consumption tried publication'
  # An unsafe primary must not advance any mate or suggest a restart.
  bump_origin "$w" instr
  printf 'protected edit\n' >> "$w/main/AGENTS.md"
  if out=$(run_update "$w"); then fail 'dirty primary reported a successful update'; fi
  assert_contains "$out" 'firstmate: skipped: dirty working tree' 'primary skip reason lost'
  assert_contains "$out" 'restart-secondmates: none' 'primary skip restarted a mate'
  assert_contains "$out" 'nudge-secondmates: none' 'primary skip nudged a mate'
  assert_equals "$fork_tip" "$(git -C "$w/linked" rev-parse HEAD)" 'primary failure propagated'
  assert_grep 'protected edit' "$w/main/AGENTS.md" 'primary edit discarded'
  pass 'origin consumption is independent of upstream; explicit preparation retains an unpublished candidate'
}

test_preparation_without_upstream_refused() {
  local w out before
  w=$(new_world prepare-absent)
  before=$(git -C "$w/main" rev-parse HEAD)
  if out=$(run_update "$w" --prepare-integration); then fail 'preparation accepted absent upstream'; fi
  assert_equals "$before" "$(git -C "$w/main" rev-parse HEAD)" 'failed preparation moved primary'
  assert_absent "$w/home/data/fork-sync" 'absent upstream created an attempt'
  assert_not_contains "$out" 'restart-secondmates:' 'failed preparation emitted update actions'
  if out=$(run_update "$w" --prepare-integration extra); then fail 'preparation accepted extra arguments'; fi
  assert_absent "$w/home/data/fork-sync" 'invalid arguments staged integration'
  pass 'explicit preparation requires upstream and rejects extra arguments without update actions'
}

test_fork_consumption_and_explicit_preparation
test_preparation_without_upstream_refused
test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_bin_only_advance_restarts
test_unprovable_runtime_gets_fallback_nudge
test_dead_secondmate_gets_no_action
test_legacy_remote_advance_restarts
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_squash_merged_divergence_reconciles
test_already_current_secondmate_still_restarts
test_already_current_unprovable_mate_is_nudged
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_primary_update_rebinds_local_watch

echo "# all fm-update tests passed"
