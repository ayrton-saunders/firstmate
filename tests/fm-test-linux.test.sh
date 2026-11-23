#!/usr/bin/env bash
# Behavior tests for bin/fm-test-linux.sh: it selects the shell tests changed on
# the branch, stops clearly without a container runtime, and (when
# FM_TEST_LINUX_CONTAINER=1 and a container engine is running) goes red on the
# GNU-incompatible `stat -f ... || stat -c ...` fixture form and green on the
# fixed form.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINUX_CHECK="$ROOT/bin/fm-test-linux.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-linux)
assert_present "$LINUX_CHECK" "bin/fm-test-linux.sh is missing"

GIT_IDENT=(-c user.email=t@example.invalid -c user.name=test)

make_repo() {  # <dir>
  mkdir -p "$1/tests"
  git -C "$1" init -q -b main
  printf 'x\n' > "$1/tests/kept.test.sh"
  printf 'x\n' > "$1/tests/gone.test.sh"
  printf 'x\n' > "$1/README.md"
  git -C "$1" add -A
  git -C "$1" "${GIT_IDENT[@]}" commit -q -m base
  git -C "$1" checkout -q -b feature
}

test_selects_changed_tests() {
  local repo="$TMP_ROOT/select" out
  make_repo "$repo"
  printf 'y\n' > "$repo/tests/added.test.sh"
  git -C "$repo" add tests/added.test.sh
  git -C "$repo" "${GIT_IDENT[@]}" commit -q -m add
  printf 'y\n' >> "$repo/tests/kept.test.sh"
  printf 'y\n' > "$repo/tests/untracked.test.sh"
  printf 'y\n' > "$repo/tests/helper.sh"
  printf 'y\n' >> "$repo/README.md"
  rm "$repo/tests/gone.test.sh"
  out=$(cd "$repo" && "$BASH" "$LINUX_CHECK" --base main --list 2>&1) || fail "--list failed: $out"
  assert_equals $'tests/added.test.sh\ntests/kept.test.sh\ntests/untracked.test.sh' "$out" "changed test selection"
  pass "selects committed, modified, and untracked tests only"
}

test_failed_selection_sort_is_not_empty_success() {
  local repo="$TMP_ROOT/sort-repo" tools="$TMP_ROOT/sort-tools" out rc=0
  make_repo "$repo"
  printf 'changed\n' >>"$repo/tests/kept.test.sh"
  mkdir "$tools"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$tools/sort"
  chmod +x "$tools/sort"
  out=$(cd "$repo" && PATH="$tools:$PATH" "$BASH" "$LINUX_CHECK" --base main 2>&1) || rc=$?
  assert_equals 2 "$rc" 'sort failure fails changed-test selection'
  assert_contains "$out" 'could not sort changed paths' 'sort failure diagnostic'
  assert_not_contains "$out" 'no changed shell tests' 'sort failure is not an empty selection'
  pass 'Linux validation does not report empty success after sort fails'
}

test_no_changed_tests_is_a_clean_pass() {
  local repo="$TMP_ROOT/none" out rc=0
  make_repo "$repo"
  out=$(cd "$repo" && FM_CONTAINER_RUNTIME=absent-runtime "$BASH" "$LINUX_CHECK" --base main 2>&1) || rc=$?
  assert_equals 0 "$rc" "no changed tests exit status"
  assert_contains "$out" "no changed shell tests" "no-change message"
  pass "no changed tests needs no runtime"
}

test_missing_runtime_stops_clearly() {
  local repo="$TMP_ROOT/runtime" out rc=0
  make_repo "$repo"
  printf 'y\n' > "$repo/tests/new.test.sh"
  out=$(cd "$repo" && FM_CONTAINER_RUNTIME=absent-runtime "$BASH" "$LINUX_CHECK" --base main 2>&1) || rc=$?
  assert_equals 2 "$rc" "missing runtime exit status"
  assert_contains "$out" "no container runtime found" "missing runtime message"
  pass "missing container runtime stops with exit 2"
}

test_checkout_scratch_is_refused_before_build_or_clone() {
  local repo="$TMP_ROOT/unsafe" out rc=0 runtime="$TMP_ROOT/runtime-stub"
  make_repo "$repo"
  mkdir "$repo/.test-phase-tmp"
  printf '%s\n' '#!/usr/bin/env bash' 'touch "$RUNTIME_CALLED"; exit 1' >"$runtime"
  chmod +x "$runtime"
  out=$(cd "$repo" && TMPDIR=.test-phase-tmp RUNTIME_CALLED="$TMP_ROOT/runtime-called" \
    FM_CONTAINER_RUNTIME="$runtime" "$BASH" "$LINUX_CHECK" tests/kept.test.sh 2>&1) || rc=$?
  assert_equals 2 "$rc" "checkout scratch exit status"
  assert_contains "$out" "unsafe scratch base" "checkout scratch refusal"
  [ ! -e "$TMP_ROOT/runtime-called" ] || fail "container build ran before scratch refusal"
  [ -z "$(ls -A "$repo/.test-phase-tmp")" ] || fail "checkout scratch was populated"
  pass "checkout scratch is refused before image build or clone"
}

test_overlay_keeps_work_but_excludes_legacy_scratch() {
  local repo="$TMP_ROOT/overlay" runtime="$TMP_ROOT/overlay-runtime" out
  make_repo "$repo"
  mkdir -p "$repo/.test-phase-tmp/nested" "$TMP_ROOT/overlay-tmp"
  printf 'committed scratch\n' >"$repo/.test-phase-tmp/nested/committed"
  mkdir "$repo/alias"
  touch "$repo/alias/committed" "$repo/replaced"
  printf '/alias\n/replaced/private\n' >"$repo/.gitignore"
  git -C "$repo" add .test-phase-tmp .gitignore replaced
  git -C "$repo" add -f alias/committed
  git -C "$repo" "${GIT_IDENT[@]}" commit -qm 'accidentally committed scratch'
  printf 'untracked scratch\n' >"$repo/.test-phase-tmp/nested/sentinel"
  rm "$repo/alias/committed" "$repo/replaced"
  rmdir "$repo/alias"
  ln -s .test-phase-tmp/nested "$repo/alias"
  mkdir "$repo/replaced"
  printf 'excluded\n' >"$repo/replaced/private"
  printf 'included\n' >"$repo/replaced/public"
  printf 'dirty\n' >"$repo/tests/kept.test.sh"
  printf 'untracked\n' >"$repo/tests/real work.txt"
  cat >"$runtime" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 1 ]; do
  if [ "$1" = -v ]; then
    copy=${2%:/work}
    [ ! -e "$copy/.test-phase-tmp" ] &&
      [ ! -e "$copy/alias/committed" ] &&
      [ ! -e "$copy/replaced/private" ] &&
      [ "$(<"$copy/replaced/public")" = included ] &&
      [ "$(<"$copy/tests/kept.test.sh")" = dirty ] &&
      [ "$(<"$copy/tests/real work.txt")" = untracked ]
    exit $?
  fi
  shift
done
SH
  chmod +x "$runtime"
  out=$(cd "$repo" && TMPDIR="$TMP_ROOT/overlay-tmp" FM_CONTAINER_RUNTIME="$runtime" \
    "$BASH" "$LINUX_CHECK" tests/kept.test.sh 2>&1) || fail "Linux overlay did not match working-tree contract: $out"
  assert_contains "$out" 'PASS tests/kept.test.sh' 'container tested the overlay'
  pass 'Linux overlay skips legacy scratch but keeps dirty and untracked work'
}

test_overlay_failure_prevents_container_run() {
  local repo="$TMP_ROOT/partial" tools="$TMP_ROOT/partial-tools" stage out rc
  make_repo "$repo"
  mkdir "$tools"
  cat >"$tools/git" <<'SH'
#!/usr/bin/env bash
if [ "$FAIL_STAGE" = inventory ] && [ "${3:-}" = ls-files ]; then
  printf '%s\0' tests/kept.test.sh
  exit 1
fi
exec "$REAL_GIT" "$@"
SH
  cat >"$tools/tar" <<'SH'
#!/usr/bin/env bash
"$REAL_TAR" "$@" || exit $?
if [ "$FAIL_STAGE" = archive ] && [ "$1" = --no-recursion ]; then exit 1; fi
SH
  cat >"$tools/runtime" <<'SH'
#!/usr/bin/env bash
if [ "$1" = run ]; then touch "$RUN_MARKER"; fi
SH
  chmod +x "$tools/"*
  for stage in inventory archive; do
    rc=0
    out=$(cd "$repo" && REAL_GIT="$(command -v git)" REAL_TAR="$(command -v tar)" \
      PATH="$tools:$PATH" FM_CONTAINER_RUNTIME="$tools/runtime" FAIL_STAGE="$stage" \
      RUN_MARKER="$tools/ran" "$BASH" "$LINUX_CHECK" tests/kept.test.sh 2>&1) || rc=$?
    assert_equals 2 "$rc" "$stage failure aborts Linux validation: $out"
    [ ! -e "$tools/ran" ] || fail "container ran after $stage failure"
    assert_not_contains "$out" 'PASS tests/kept.test.sh' "$stage failure must not report a pass"
  done
  pass 'Linux validation refuses partial inventory and archives'
}

container_ready() {
  local runtime
  [ "${FM_TEST_LINUX_CONTAINER:-}" = 1 ] || return 1
  for runtime in "${FM_CONTAINER_RUNTIME:-}" docker podman; do
    [ -n "$runtime" ] && command -v "$runtime" >/dev/null 2>&1 && "$runtime" info >/dev/null 2>&1 && return 0
  done
  return 1
}

test_gnu_stat_fixture_red_then_green() {
  local repo="$TMP_ROOT/gnu" out rc=0
  if ! container_ready; then
    pass "gnu stat fixture red then green skipped: set FM_TEST_LINUX_CONTAINER=1 with a running container engine"
    return 0
  fi
  make_repo "$repo"
  cat > "$repo/tests/stat-red.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
f=$(mktemp)
mark=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")
case "$mark" in *[!0-9]*) echo "not ok - marker contaminated"; exit 1 ;; esac
FIXTURE
  cat > "$repo/tests/stat-green.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
f=$(mktemp)
if mark=$(stat -c %Y "$f" 2>/dev/null); then :; else mark=$(stat -f %m "$f"); fi
case "$mark" in *[!0-9]*) echo "not ok - marker contaminated"; exit 1 ;; esac
FIXTURE
  out=$(cd "$repo" && "$BASH" "$LINUX_CHECK" --base main tests/stat-red.test.sh 2>&1) || rc=$?
  assert_equals 1 "$rc" "original fixture form must fail on Linux"
  assert_contains "$out" "FAIL tests/stat-red.test.sh" "red fixture reported"
  rc=0
  out=$(cd "$repo" && "$BASH" "$LINUX_CHECK" --base main tests/stat-green.test.sh 2>&1) || rc=$?
  assert_equals 0 "$rc" "fixed fixture form must pass on Linux: $out"
  assert_contains "$out" "PASS tests/stat-green.test.sh" "green fixture reported"
  cat > "$repo/tests/tools.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
[ -L tests/dangling-link ] || { echo "not ok - dangling link lost"; exit 1; }
[ "$(python3 -c 'print(6 * 7)')" = 42 ] || exit 1
[ "$(node -e 'console.log(6 * 7)')" = 42 ] || exit 1
curl --version >/dev/null || exit 1
FIXTURE
  ln -s missing-target "$repo/tests/dangling-link"
  git -C "$repo" add tests/dangling-link
  git -C "$repo" "${GIT_IDENT[@]}" commit -q -m link
  rc=0
  out=$(cd "$repo" && "$BASH" "$LINUX_CHECK" --base main tests/tools.test.sh 2>&1) || rc=$?
  assert_equals 0 "$rc" "tools and dangling link must survive the scratch copy: $out"
  assert_contains "$out" "PASS tests/tools.test.sh" "tools fixture reported"
  pass "gnu stat fixture goes red on the original form and green on the fixed form"
}

fm_test_run test_selects_changed_tests test_failed_selection_sort_is_not_empty_success test_no_changed_tests_is_a_clean_pass \
  test_missing_runtime_stops_clearly test_checkout_scratch_is_refused_before_build_or_clone \
  test_overlay_keeps_work_but_excludes_legacy_scratch test_overlay_failure_prevents_container_run \
  test_gnu_stat_fixture_red_then_green
