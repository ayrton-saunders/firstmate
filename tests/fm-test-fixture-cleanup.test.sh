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
  local harness dirfile active_dir custom_dir registry_dir stale_dir fresh_dir unmarked_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  TMPDIR="$harness" TMP="$ROOT" TEMP="$ROOT" bash -ec '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    [ "$TMPDIR" -ef "'"$harness"'" ] && [ "$TMP" = "$TMPDIR" ] && [ "$TEMP" = "$TMPDIR" ] || exit 1
    d=$(fm_test_tmproot oenv)
    custom=$(fm_test_tmproot ".custom fixture")
    printf "%s\n%s\n%s\n" "$d" "$FM_TEST_REGISTRY_DIR" "$custom" > "'"$dirfile"'"
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
  { IFS= read -r active_dir; IFS= read -r registry_dir; IFS= read -r custom_dir; } < "$dirfile"
  assert_present "$registry_dir/cleanup" 'standalone child registered fixtures'
  touch -c -t 202001010000 "$active_dir/.fm-test-fixture" "$registry_dir/.fm-test-fixture" "$custom_dir/.fm-test-fixture"
  unmarked_dir=$(mktemp -d "$harness/.custom fixture.XXXXXX")
  touch -t 202001010000 "$unmarked_dir"

  stale_dir=$(mktemp -d "$harness/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$pid" invalid-start-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "$harness/fm-test-cleanup-fresh.XXXXXX")
  cp "$active_dir/.fm-test-fixture" "$fresh_dir/.fm-test-fixture"

  TMPDIR="$harness" bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_present "$stale_dir" 'an aged malformed owner marker must not authorize removal'
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  assert_present "$registry_dir" 'orphan recovery leaves a live registry intact'
  assert_present "$custom_dir" 'orphan recovery leaves a live hidden fixture intact'
  kill -KILL "$pid"
  wait "$pid" 2>/dev/null || true
  TMPDIR="$harness" bash -ec '. "$1"' _ "$LIB"
  assert_absent "$active_dir" 'orphan recovery removed the killed suite oenv fixture'
  assert_absent "$custom_dir" 'orphan recovery removed the killed suite hidden fixture'
  assert_present "$unmarked_dir" 'orphan recovery leaves an old unmarked directory intact'
  assert_absent "$registry_dir" 'orphan recovery removed the killed suite registry'
  assert_present "$fresh_dir" 'a fresh fixture survives even after its owner exits'
  assert_present "$stale_dir" 'an aged malformed marker for a dead owner does not authorize removal'
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir pid identity
  stale_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  sleep 30 &
  pid=$!
  identity=$(fm_test_pid_identity "$pid") || { kill "$pid"; fail 'could not identify fixture owner'; }
  printf '%s\n%s\n' "$pid" "$identity" > "$stale_dir/.fm-test-fixture"
  kill "$pid"
  wait "$pid" 2>/dev/null || true
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
    TMPDIR="$base" FM_TEST_RETAIN_MARKER="$base/.retain-scratch" bash -c '
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
      set -- "$base"/.retain-scratch.*.fixture
      assert_present "$1" 'unverified teardown publishes retention to the fixture marker'
      set -- "$base"/fm-custom-fixture.*/sentinel
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
  mv "$source/.test-phase-tmp" "$source/rename-scratch"
  mv "$source/rename-scratch" "$source/.TEST-PHASE-TMP"
  fm_test_copy_primary_lab "$source" "$dest" || fail 'primary lab copy with case variant failed'
  if [ -d "$source/.test-phase-tmp" ]; then
    assert_absent "$dest/.TEST-PHASE-TMP" 'case alias of scratch was excluded'
  else
    assert_present "$dest/.TEST-PHASE-TMP/sentinel" 'distinct case variant was preserved'
  fi
  assert_present "$dest/nested/.test-phase-tmp/sentinel" 'nested work was not excluded'
  assert_equals 'working bytes' "$(<"$dest/tracked")" 'working bytes were copied'
  assert_equals 'untracked bytes' "$(<"$dest/.untracked")" 'untracked dotfile was copied'
  mkdir -p "$harness/symlink-copy" "$source/notes"
  printf 'real work\n' >"$source/notes/draft"
  mv "$source/.TEST-PHASE-TMP" "$harness/old-scratch"
  if ! ln -s notes "$source/.test-phase-tmp" 2>/dev/null || [ ! -L "$source/.test-phase-tmp" ] ||
     ! ln -s notes "$source/notes-link" 2>/dev/null || [ ! -L "$source/notes-link" ]; then
    pass 'primary lab copies omit only root-level declared scratch (symlinks unavailable)'
    return 0
  fi
  fm_test_copy_primary_lab "$source" "$harness/symlink-copy" || fail 'primary lab copy with symlink failed'
  assert_absent "$harness/symlink-copy/.test-phase-tmp" 'the declared symlink was excluded'
  assert_equals 'real work' "$(<"$harness/symlink-copy/notes/draft")" 'the declared symlink target was copied normally'
  assert_equals notes "$(readlink "$harness/symlink-copy/notes-link")" 'an unrelated symlink to the same work was kept'
  if ln -P "$source/.test-phase-tmp" "$source/notes-hardlink" 2>/dev/null && [ -L "$source/notes-hardlink" ]; then
    mkdir "$harness/hardlink-copy"
    fm_test_copy_primary_lab "$source" "$harness/hardlink-copy" || fail 'primary lab copy with hardlinked symlink failed'
    assert_absent "$harness/hardlink-copy/.test-phase-tmp" 'declared entry was excluded despite its hard link'
    assert_equals notes "$(readlink "$harness/hardlink-copy/notes-hardlink")" 'distinct hardlinked symlink was preserved'
  fi
  mv "$source/.test-phase-tmp" "$harness/declared-link"
  mv "$harness/declared-link" "$source/.TEST-PHASE-TMP"
  mkdir "$harness/symlink-alias-copy"
  fm_test_copy_primary_lab "$source" "$harness/symlink-alias-copy" || fail 'primary lab copy with symlink case variant failed'
  if [ -L "$source/.test-phase-tmp" ]; then
    assert_absent "$harness/symlink-alias-copy/.TEST-PHASE-TMP" 'case alias of the declared symlink was excluded'
  else
    assert_equals notes "$(readlink "$harness/symlink-alias-copy/.TEST-PHASE-TMP")" 'distinct symlink case variant was preserved'
  fi
  pass 'primary lab copies omit only root-level declared scratch'
}

test_registry_cleanup_guards() {
  local harness rc=0
  harness=$(fm_test_tmproot fm-test-cleanup-guards)
  mkdir "$harness/unmarked" "$harness/original" "$harness/original/tmp" "$harness/unsafe"$'\n'
  TMPDIR="$harness" bash -ec '
    . "$1"
    printf "%s\n" "$2/unmarked" >> "$FM_TEST_CLEANUP_REGISTRY"
  ' _ "$LIB" "$harness" || fail 'unmarked record interrupted normal cleanup'
  [ -d "$harness/unmarked" ] || fail 'cleanup deleted an unmarked root'
  FM_TEST_RETAIN_MARKER="$harness/.retain-scratch" TMPDIR="$harness" FM_HOME="$harness/original" bash -ec '
    . "$1"
    if TMPDIR="$2/original/tmp" fm_test_tmproot blocked; then exit 8; fi
    if fm_test_tmproot $'"'"'prefix\nsplit'"'"'; then exit 9; fi
    ln -s "$2/unsafe"$'"'"'\n'"'"' "$2/alias"
    if TMPDIR="$2/alias" fm_test_tmproot blocked; then exit 10; fi
    d=$(fm_test_tmproot fm-cwd-only)
    printf "%s\n" "$d" > "$2/root"
    # With job control disabled the child shares our process group and the
    # finalizer must retain scratch rather than signal an unowned group.
    (cd "$d" && touch "$2/ready" && exec sleep 30) &
    for ((i=0; i<100; ++i)); do
      [ ! -f "$2/ready" ] || break
      sleep 0.02
    done
    [ -f "$2/ready" ] || exit 11
    printf "%s\n" "$!" > "$2/pid"
    exit 0
  ' _ "$LIB" "$harness" >"$harness/out" 2>&1 || rc=$?
  if [ -f "$harness/pid" ]; then kill "$(<"$harness/pid")" 2>/dev/null || true; fi
  assert_equals 1 "$rc" 'unverified teardown returns failure'
  [ -f "$(<"$harness/root")/.retain-scratch.fixture" ] || fail 'cwd-only child did not retain the fixture'
  grep -q 'fixture teardown unverified' "$harness/out" || fail 'missing retention warning'
  grep -q 'unsafe scratch base' "$harness/out" || fail 'original home was not rejected'
  grep -q 'unsupported character in resolved scratch base' "$harness/out" || fail 'newline alias was not rejected'
  pass 'cleanup guards cwd-only children, fixture ownership, and inherited boundaries'
}

test_msys_fixture_process_inventory() {
  local harness mode rc fixture poller survivor=0
  harness=$(fm_test_tmproot fm-test-msys-ps)
  mkdir "$harness/bin"
  sleep 30 &
  poller=$!
  # shellcheck disable=SC2016 # Expand variables when the stub runs.
  printf '%s\n' '#!/usr/bin/env bash' 'if [ "${1:-}" = -s ]; then echo MSYS_NT-10.0; else exec "$REAL_UNAME" "$@"; fi' > "$harness/bin/uname"
  cat > "$harness/bin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  -e)
    case "$INVENTORY" in empty) exit 0 ;; failed) exit 1 ;; esac
    printf '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND\n'
    printf ' %8s %7s %7s %10s     ?    Jane Doe    12:00 /usr/bin/bash\n' "$SUITE_PID" 1 "$SUITE_PID" 1000
    if [ "$INVENTORY" = ready ] && kill -0 "$POLLER_PID" 2>/dev/null; then
      printf 'I%8s %7s %7s %10s     ?    Jane Doe    12:00 /usr/bin/bash\n' "$POLLER_PID" 1 "$POLLER_PID" 1001
    fi
    ;;
  -ef) printf ' UID PID PPID TTY STIME COMMAND\n Jane Doe %s 1 ? 12:00 /usr/bin/bash\n' "$SUITE_PID" ;;
  *ppid=*|*pgid=*|*-eo*) exit 1 ;;
  *) exec "$REAL_PS" "$@" ;;
esac
SH
  chmod +x "$harness/bin/uname" "$harness/bin/ps"
  for mode in ready clean empty failed; do
    rc=0
    REAL_UNAME=$(command -v uname) REAL_PS=$(command -v ps) INVENTORY="$mode" \
      PATH="$harness/bin:$PATH" TMPDIR="$harness" FM_TEST_RETAIN_MARKER="$harness/.retain-scratch" \
      POLLER_PID="$poller" FM_TEST_SKIP_ORPHAN_REAP=1 bash -ec '
        export SUITE_PID=$$
        . "$1"
        fm_test_msys_cmdline() {
          case "$1" in
            "$$") printf "bash " ;;
            "$POLLER_PID") printf "bash %s/poller.sh " "$fixture" ;;
          esac
        }
        fixture=$(fm_test_tmproot "fixture with spaces")
        extra=$(fm_test_tmproot extra)
        printf "%s\n%s\n" "$fixture" "$extra" > "$2"
      ' _ "$LIB" "$harness/root" >"$harness/out" 2>&1 || rc=$?
    if [ "$mode" = ready ]; then
      if kill -0 "$poller" 2>/dev/null; then
        survivor=1
        kill "$poller" 2>/dev/null || true
      fi
      wait "$poller" 2>/dev/null || true
      assert_equals 0 "$survivor" 'cleanup stops the process named only by MSYS argv'
    fi
    IFS= read -r fixture < "$harness/root"
    [ -n "$fixture" ] || fail "MSYS-style suite did not allocate a fixture: $(<"$harness/out")"
    if [ "$mode" = ready ] || [ "$mode" = clean ]; then
      assert_equals 0 "$rc" 'passing suite with MSYS process columns exits cleanly'
      assert_absent "$fixture" 'passing suite with MSYS process columns removes scratch'
    else
      assert_equals 1 "$rc" "suite with $mode inventory fails cleanup"
      assert_present "$fixture/.retain-scratch.fixture" "suite with $mode inventory retains scratch"
    fi
  done
  pass 'MSYS fixture cleanup requires a valid process inventory'
}

test_successful_cleanup_can_be_repeated() {
  local harness rc=0
  harness=$(fm_test_tmproot fm-repeat-cleanup)
  FM_TEST_RETAIN_MARKER="$harness/retained" TMPDIR="$harness" bash -ec '
    . "$1"
    fixture=$(fm_test_tmproot fm-repeat)
    manual="$FM_TEST_TMPDIR/manual-fixture"
    mkdir() {
      local allocator
      allocator=${BASHPID:-$(exec sh -c '\''printf "%s\n" "$PPID"'\'')}
      command mkdir "$@" || return 1
      kill -TERM "$allocator"
    }
    fm_test_mkdir_scratch "$manual"
    unset -f mkdir
    [ -d "$manual" ]
    fm_test_cleanup
    [ ! -e "$fixture" ]
    [ ! -e "$manual" ]
    fm_test_cleanup
  ' _ "$LIB" >"$harness/out" 2>&1 || rc=$?
  assert_equals 0 "$rc" "explicit cleanup followed by cleanup and EXIT: $(<"$harness/out")"
  if compgen -G "$harness/retained.*" >/dev/null; then fail 'repeated successful cleanup marked scratch retained'; fi
  pass 'successful fixture cleanup is safe to repeat from EXIT'
}

test_orphan_sweep_retains_private_tmux() {
  local harness
  if ! command -v tmux >/dev/null || ! command -v python3 >/dev/null; then
    printf '%s\n' 'skip: private tmux orphan recovery needs tmux and python3'
    return 0
  fi
  harness=$(fm_test_tmproot t)
  TMPDIR="$harness" python3 - "$BASH" "$LIB" "$harness" <<'PY' || fail 'registered scratch was not protected until tmux teardown'
import os, pathlib, signal, subprocess, sys

bash, lib, base = sys.argv[1:]
env = os.environ.copy()
for key in ('TMUX', 'TMUX_PANE', 'FM_TEST_RETAIN_MARKER'):
    env.pop(key, None)
env['FM_TEST_SKIP_ORPHAN_REAP'] = '1'
env['FM_TEST_ORPHAN_MAX_AGE_SECONDS'] = '0'
base = pathlib.Path(base)
script = '''
. "$1"
root=$(fm_test_tmproot oenv)
printf '%s\\n' "$root" > "$2/root"
printf '%s\\n' "$FM_TEST_REGISTRY_DIR" > "$2/registry"
marker=
FM_TEST_RETAIN_MARKER= fm_test_arm_private_tmux marker "$root"
tmux -S "$root/s" -f /dev/null new-session -d -s scoped-source 'exec sleep 60'
if [ "$3" != normal ]; then
  pid=$(tmux -S "$root/s" display-message -p '#{pid}')
  printf '%s\\n' "$pid" > "$2/pid"
  if [ "$3" = stopped ]; then kill -STOP "$pid"; fi
  kill -KILL "$$"
fi
fm_test_stop_private_tmux "$root/s" tmux "$marker"
'''
for mode in ('live', 'stopped'):
    (base / 'root').unlink(missing_ok=True)
    (base / 'pid').unlink(missing_ok=True)
    try:
        result = subprocess.run([bash, '-ec', script, '_', lib, base, mode], env=env, timeout=10)
        assert result.returncode == -signal.SIGKILL, result.returncode
        root = pathlib.Path((base / 'root').read_text().strip())
        registry = pathlib.Path((base / 'registry').read_text().strip())
        assert registry.is_dir(), 'killed fixture did not leave a registry to reap'
        subprocess.run([bash, '-ec', '. "$1"; fm_test_reap_orphans', '_', lib], env=env, check=True, timeout=10)
        assert not registry.exists(), 'orphan recovery did not remove the abandoned registry'
        assert (root / 's').is_socket(), f'recovery deleted scratch below the {mode} Orca server'
        if mode == 'live':
            subprocess.run(['tmux', '-S', str(root / 's'), 'has-session', '-t', '=scoped-source'],
                           env=env, check=True, timeout=5)
    finally:
        if (base / 'root').is_file():
            root = pathlib.Path((base / 'root').read_text().strip())
            if (base / 'pid').is_file():
                pid = int((base / 'pid').read_text())
                try:
                    os.kill(pid, signal.SIGCONT)
                    if not (root / 's').is_socket():
                        os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            subprocess.run(['tmux', '-S', str(root / 's'), 'kill-server'], env=env, capture_output=True, timeout=5)
subprocess.run([bash, '-ec', script, '_', lib, base, 'normal'], env=env, check=True, timeout=10)
assert not pathlib.Path((base / 'root').read_text().strip()).exists(), 'verified teardown left scratch behind'
PY
  pass 'orphan recovery preserves live and stopped Orca tmux fixtures'
}

test_orphan_sweep_retains_private_tmux
test_successful_cleanup_can_be_repeated
test_msys_fixture_process_inventory
test_registry_cleanup_guards
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
