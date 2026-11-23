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
  local repo="$TMP_ROOT/overlay" runtime="$TMP_ROOT/overlay-runtime" out expected_tmp check_alias=0
  make_repo "$repo"
  mkdir -p "$repo/.test-phase-tmp/nested" "$TMP_ROOT/overlay-tmp"
  expected_tmp=$(cd "$TMP_ROOT/overlay-tmp" && pwd -P) || fail 'could not resolve overlay temp fixture'
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
  if ln -s .test-phase-tmp/nested "$repo/alias" 2>/dev/null && [ -L "$repo/alias" ]; then
    check_alias=1
  fi
  mkdir "$repo/replaced"
  printf 'excluded\n' >"$repo/replaced/private"
  printf 'included\n' >"$repo/replaced/public"
  printf 'dirty\n' >"$repo/tests/kept.test.sh"
  printf 'untracked\n' >"$repo/tests/real work.txt"
  cat >"$runtime" <<'SH'
#!/usr/bin/env bash
if [ "$TMPDIR" != "$EXPECTED_TMP" ] || [ "$TMP" != "$EXPECTED_TMP" ] || [ "$TEMP" != "$EXPECTED_TMP" ]; then
  printf 'unexpected host temp paths for %s: %s %s %s\n' "$1" "$TMPDIR" "$TMP" "$TEMP" >&2
  exit 1
fi
while [ "$#" -gt 1 ]; do
  if [ "$1" = -v ]; then
    copy=${2%:/work}
    [ ! -e "$copy/.test-phase-tmp" ] &&
      { [ "$CHECK_ALIAS" -eq 0 ] || [ ! -e "$copy/alias/committed" ]; } &&
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
  out=$(cd "$repo" && TMPDIR=../overlay-tmp TMP="$repo/.test-phase-tmp" TEMP="$repo/.test-phase-tmp" \
    EXPECTED_TMP="$expected_tmp" FM_CONTAINER_RUNTIME="$runtime" CHECK_ALIAS="$check_alias" \
    "$BASH" "$LINUX_CHECK" tests/kept.test.sh 0<&- 2>&1) || fail "Linux overlay did not match working-tree contract: $out"
  assert_not_contains "$out" 'unexpected host temp paths' 'host runtime receives the validated base'
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

test_attach_failure_verifies_container_stop() {
  local repo="$TMP_ROOT/detached" runtime="$TMP_ROOT/detached-runtime" state mode rc out scratch hook="$TMP_ROOT/prelaunch-hook"
  make_repo "$repo"
  cat >"$runtime" <<'SH'
#!/usr/bin/env bash
case "$1" in
  ps)
    if [ "$MODE" = prelaunch ]; then touch "$FAKE_RUNTIME_STATE/daemon-contacted"; exit 1; fi
    if [ "$MODE" = undrained ]; then touch "$FAKE_RUNTIME_STATE/daemon-contacted"; exit 0; fi
    pattern=.
    if [ "${3:-}" = --filter ]; then pattern=${4#name=}; fi
    name=$(<"$FAKE_RUNTIME_STATE/container-name")
    if [[ "/$name" =~ $pattern ]] && { [ -f "$FAKE_RUNTIME_STATE/running" ] || { [ "$2" = -aq ] && [ -f "$FAKE_RUNTIME_STATE/created" ]; }; }; then
      printf '%s\n' container-id
    fi
    if [[ "/$name-neighbor" =~ $pattern ]] && [ -f "$FAKE_RUNTIME_STATE/neighbor" ]; then
      printf '%s\n' neighbor-id
    fi
    ;;
  rm)
    if [[ "${!#}" == *neighbor-id* ]]; then rm "$FAKE_RUNTIME_STATE/neighbor"; fi
    [ "${!#}" = container-id ] && [ -d "$(<"$FAKE_RUNTIME_STATE/scratch-path")" ] || exit 2
    touch "$FAKE_RUNTIME_STATE/remove-called"
    if [ "$MODE" != unresolved ]; then rm -f "$FAKE_RUNTIME_STATE/running" "$FAKE_RUNTIME_STATE/created"; fi
    ;;
  run)
    while [ "$#" -gt 1 ]; do
      if [ "$1" = --name ]; then printf '%s\n' "$2" >"$FAKE_RUNTIME_STATE/container-name"; fi
      if [ "$1" = -v ]; then
        [ ! -f "$FAKE_RUNTIME_STATE/running" ] && [ ! -f "$FAKE_RUNTIME_STATE/created" ] || { touch "$FAKE_RUNTIME_STATE/overlap"; exit 2; }
        if [ -f "$FAKE_RUNTIME_STATE/scratch-path" ]; then touch "$FAKE_RUNTIME_STATE/next-test"; exit 0; fi
        printf '%s\n' "${2%:/work}" >"$FAKE_RUNTIME_STATE/scratch-path"
        touch "$FAKE_RUNTIME_STATE/neighbor"
        if [ "$MODE" = undrained ]; then
          kill -TERM "$WRAPPER_PID" || exit 2
          exec sleep 3
        fi
        if [ "$MODE" = created ]; then touch "$FAKE_RUNTIME_STATE/created"; else touch "$FAKE_RUNTIME_STATE/running"; fi
        if [ "$MODE" = killed ]; then kill -KILL "$WRAPPER_PID" || exit 2; fi
        exit 7
      fi
      shift
    done
    ;;
esac
SH
  chmod +x "$runtime"
  cat >"$hook" <<'SH'
unset BASH_ENV
if [ "$MODE" = prelaunch ]; then
  trap 'if [ -f "$FM_TEST_RETAIN_MARKER.$$.linux" ]; then trap - DEBUG; kill -TERM "$$"; fi' DEBUG
elif [ "$MODE" = undrained ]; then
  ps() {
    if [ "$*" = '-e -o pid= -o pgid= -o stat=' ]; then return 0; fi
    command ps "$@"
  }
fi
SH
  for mode in resolved unresolved created killed prelaunch undrained; do
    state="$TMP_ROOT/$mode"
    mkdir "$state"
    rc=0
    out=$(cd "$repo" && TMPDIR="$state" FM_CONTAINER_RUNTIME="$runtime" FAKE_RUNTIME_STATE="$state" MODE="$mode" \
      FM_TEST_RETAIN_MARKER="$state/.retain-scratch" "$BASH" -c 'export WRAPPER_PID=$$; exec "$@"' _ \
      env BASH_ENV="$hook" "$BASH" "$LINUX_CHECK" tests/kept.test.sh tests/gone.test.sh 2>&1) || rc=$?
    if [ "$mode" = prelaunch ]; then
      assert_equals 143 "$rc" "TERM after marker publication: $out"
      assert_equals '' "$(ls -A "$state")" 'prelaunch cancellation leaves no container state, scratch, or retention marker'
      continue
    fi
    scratch=$(<"$state/scratch-path")
    if [ "$mode" = undrained ]; then
      assert_equals 143 "$rc" "TERM with an unverified client: $out"
      assert_contains "$out" 'retaining scratch:' 'unverified drain retains scratch'
      assert_absent "$state/daemon-contacted" 'daemon teardown must wait for verified client drain'
      assert_present "$scratch/tests/kept.test.sh" 'unverified client keeps its backing tree'
      fm_test_scratch_retained "$state" || fail 'unverified client lost parent retention'
      continue
    fi
    if [ "$mode" = killed ]; then
      assert_equals 137 "$rc" "wrapper was killed during container run: $out"
      assert_present "$state/running" 'daemon still owns the container'
      fm_test_scratch_retained "$state" || fail 'wrapper did not publish retention before launch'
      assert_present "$scratch/tests/kept.test.sh" 'killed wrapper left the backing tree intact'
      continue
    fi
    assert_equals 1 "$rc" "client failure fails validation: $out"
    assert_present "$state/remove-called" 'validator tried to remove its daemon-side container before cleanup'
    assert_absent "$state/overlap" 'a new test did not start while a container was running'
    assert_present "$state/neighbor" 'teardown did not remove the similarly named container'
    if [ "$mode" != unresolved ]; then
      assert_present "$state/next-test" 'tests continue after confirmed teardown'
      assert_absent "$scratch" 'confirmed teardown allows scratch removal'
      if fm_test_scratch_retained "$state"; then fail 'confirmed removal left a retention marker'; fi
    else
      assert_absent "$state/next-test" 'unconfirmed teardown stops test admission'
      assert_present "$scratch/tests/kept.test.sh" 'unconfirmed teardown keeps mounted scratch'
      fm_test_scratch_retained "$state" || fail 'retention was not propagated'
      assert_contains "$out" 'retaining scratch:' 'retention diagnostic'
    fi
  done
  pass 'Linux validation confirms daemon teardown after attach failure'
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

fm_test_run test_selects_changed_tests test_no_changed_tests_is_a_clean_pass \
  test_missing_runtime_stops_clearly test_checkout_scratch_is_refused_before_build_or_clone \
  test_overlay_keeps_work_but_excludes_legacy_scratch test_overlay_failure_prevents_container_run \
  test_attach_failure_verifies_container_stop test_gnu_stat_fixture_red_then_green
