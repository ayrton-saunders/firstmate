#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans).
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" VICTIM="$victim" bash -ec '
    mktemp() {
      if [ "$1" = -d ]; then
        case "${!#}" in
          */.fm-test-registry.*)
            template=${!#}
            planted="${template%XXXXXX}planted"
            mkdir "$planted"
            printf "%s\n" "$VICTIM" > "$planted/cleanup"
            ;;
        esac
      fi
      command mktemp "$@"
    }
    . "$1"
  ' _ "$LIB" || fail "fixture setup could not claim a fresh registry"

  assert_equals "$victim" "$(<"$shared_tmp/.fm-test-registry.planted/cleanup")" 'preexisting registry was not claimed'
  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir
  stale_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  printf 'installed package\n' > "$package_dir/entrypoint.py"
  chmod -R a-w "$stale_dir/packages"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  assert_absent "$stale_dir" \
    "the orphan reaper left a stale fixture containing a read-only package tree"
  pass "the orphan sweep reaps read-only package fixtures"
}

# A fixture poller that reparented to init and names its root on its command
# line - the shape of the leaked stub arms, hook-home watchers, and fake harness
# loops - must be stopped by the owning suite's teardown before the root is
# removed, rather than left polling for a file that removal makes impossible.
test_cleanup_reaps_orphaned_poller_naming_its_root() {
  local harness out child_dir poller i survivors
  harness=$(fm_test_tmproot fm-test-cleanup-poller-harness)
  out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-poller)
    printf "%s\n" "while [ ! -e \"\$1\" ]; do sleep 0.1; done" > "$d/poller.sh"
    ( bash "$d/poller.sh" "$d/never" </dev/null >/dev/null 2>&1 &
      printf "%s\n" "$!" > "'"$harness"'/poller.pid" )
    printf "%s\n" "$d"
  ')
  child_dir=$(printf '%s\n' "$out" | sed -n '1p')
  poller=$(cat "$harness/poller.pid" 2>/dev/null || true)
  [ -n "$poller" ] || fail "the child suite never started its poller"
  i=0
  while [ "$i" -lt 30 ] && kill -0 "$poller" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$poller" 2>/dev/null; then
    kill -KILL "$poller" 2>/dev/null || true
    fail "the owning suite's teardown left its fixture poller pid $poller running"
  fi
  survivors=$(ps -ww -eo pid=,args= | FM_ROOT_MATCH="$child_dir/" awk 'index($0, ENVIRON["FM_ROOT_MATCH"])')
  [ -z "$survivors" ] || fail "processes naming the removed fixture root survived: $survivors"
  assert_absent "$child_dir" "the fixture root survived its owning process's normal exit"
  pass "fm_test_cleanup stops an orphaned poller that names its fixture root"
}

test_registries_avoid_git_worktree_root() {
  local harness repo out rc=0
  harness=$(fm_test_tmproot fm-test-cleanup-gitroot-harness)
  repo="$harness/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  out=$(TMPDIR="$repo" bash -c '. "$1"' _ "$LIB" 2>&1) || rc=$?
  assert_equals 2 "$rc" 'checkout TMPDIR is refused'
  assert_contains "$out" 'unsafe scratch base' 'checkout refusal diagnostic'
  assert_equals '.git' "$(ls -A "$repo")" 'fixture setup left the checkout untouched'
  pass 'fixture preflight refuses checkout TMPDIR before creating registries'
}

test_interrupted_registry_allocation_cleans_up() {
  local harness rc=0
  harness=$(fm_test_tmproot fm-test-registry-interrupt)
  mkdir "$harness/tmp"
  TMPDIR="$harness/tmp" bash -c '
    export OWNER=$$
    mktemp() {
      local allocated
      allocated=$(command mktemp "$@") || return "$?"
      kill -TERM "$OWNER"
      printf "%s\n" "$allocated"
    }
    . "$1"
  ' _ "$LIB" || rc=$?
  assert_equals 143 "$rc" 'fixture setup handles TERM during allocation'
  assert_equals '' "$(ls -A "$harness/tmp")" 'interrupted fixture setup left no registry scratch'
  pass 'fixture registry allocation is cleaned up on TERM'
}

test_removal_failure_preserves_existing_status() {
  local harness mode original expected rc out
  harness=$(fm_test_tmproot fm-test-removal-status)
  for mode in standalone fixtures; do
    for original in 0 7 143; do
      mkdir "$harness/$mode-$original"
      rc=0
      out=$(TMPDIR="$harness/$mode-$original" bash -c '
        rm() { return 1; }
        if [ "$1" = standalone ]; then
          . "$3/bin/fm-test-scratch-lib.sh"
          fm_test_allocate_scratch "$TMPDIR/case.XXXXXX" || exit 2
        else
          . "$3/tests/lib.sh"
        fi
        exit "$2"
      ' _ "$mode" "$original" "$ROOT" 2>&1) || rc=$?
      expected=$original
      [ "$original" -ne 0 ] || expected=1
      assert_equals "$expected" "$rc" "$mode cleanup exit status"
      assert_contains "$out" 'could not remove scratch' "$mode cleanup reports removal failure"
    done
  done
  pass 'standalone and fixture cleanup report failures without replacing an existing status'
}

test_custom_finalizer_cleans_or_retains_after_teardown() {
  local harness rc teardown base
  harness=$(fm_test_tmproot fm-test-custom-finalizer)
  for teardown in 0 1; do
    base="$harness/$teardown"
    mkdir "$base"
    rc=0
    TMPDIR="$base" bash -c '
      . "$1"
      teardown=$2
      trap '\''fm_test_finalize "$?" "$teardown"'\'' EXIT
      root=$(fm_test_tmproot fm-custom-fixture) || exit 2
      touch "$root/sentinel" || exit 2
      exit 7
    ' _ "$LIB" "$teardown" || rc=$?
    assert_equals 7 "$rc" 'custom finalizer preserves suite failure'
    if [ "$teardown" -eq 0 ]; then
      assert_equals '' "$(ls -A "$base")" 'verified teardown cleans roots and registry'
    else
      set -- "$base"/fm-custom-fixture.*/sentinel
      assert_present "$1" 'unverified teardown retains fixture scratch'
      TMPDIR="$base" FM_TEST_ORPHAN_MAX_AGE_SECONDS=0 bash -ec '. "$1"; fm_test_reap_orphans' _ "$LIB" || fail 'fixture orphan sweep failed'
      assert_present "$1" 'a later orphan sweep leaves retained scratch alone'
    fi
  done
  pass 'custom finalizer cleans only after verified teardown'
}

test_primary_lab_copy_excludes_only_declared_scratch() {
  local harness source dest
  harness=$(fm_test_tmproot fm-test-primary-lab-copy)
  source="$harness/source"
  dest="$harness/dest"
  mkdir -p "$source/.test-phase-tmp" "$source/nested/.test-phase-tmp" "$dest"
  printf 'working bytes\n' >"$source/tracked"
  printf 'untracked bytes\n' >"$source/.untracked"
  touch "$source/.test-phase-tmp/sentinel" "$source/nested/.test-phase-tmp/sentinel"
  fm_test_copy_primary_lab "$source" "$dest" || fail 'primary lab copy failed'
  assert_absent "$dest/.test-phase-tmp" 'declared root was excluded'
  assert_present "$dest/nested/.test-phase-tmp/sentinel" 'nested work was not excluded'
  assert_equals 'working bytes' "$(<"$dest/tracked")" 'working bytes were copied'
  assert_equals 'untracked bytes' "$(<"$dest/.untracked")" 'untracked dotfile was copied'
  pass 'primary lab copies omit only root-level declared scratch'
}

test_custom_finalizer_cleans_or_retains_after_teardown
test_primary_lab_copy_excludes_only_declared_scratch
test_removal_failure_preserves_existing_status
test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_interrupted_registry_allocation_cleans_up
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
test_registries_avoid_git_worktree_root
test_cleanup_reaps_orphaned_poller_naming_its_root
