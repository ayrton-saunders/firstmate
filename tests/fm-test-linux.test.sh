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
  # shellcheck disable=SC2016 # Expand variables when the stub runs.
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
  local repo="$TMP_ROOT/overlay" runtime="$TMP_ROOT/overlay-runtime" out expected_tmp check_alias=0 distinct_case=0
  make_repo "$repo"
  local indexed_scratch=.test-phase-tmp
  mkdir "$repo/.CASE-PROBE"
  if [ -d "$repo/.case-probe" ]; then indexed_scratch=.TEST-PHASE-TMP; else distinct_case=1; fi
  rmdir "$repo/.CASE-PROBE"
  mkdir -p "$repo/$indexed_scratch/nested" "$TMP_ROOT/overlay-tmp"
  expected_tmp=$(cd "$TMP_ROOT/overlay-tmp" && pwd -P) || fail 'could not resolve overlay temp fixture'
  printf 'committed scratch\n' >"$repo/$indexed_scratch/nested/committed"
  mkdir "$repo/alias"
  touch "$repo/alias/committed" "$repo/replaced"
  printf '/alias\n/replaced/private\n' >"$repo/.gitignore"
  git -C "$repo" add "$indexed_scratch" .gitignore replaced
  git -C "$repo" add -f alias/committed
  git -C "$repo" "${GIT_IDENT[@]}" commit -qm 'accidentally committed scratch'
  if [ "$distinct_case" -eq 1 ]; then
    mkdir "$repo/.TEST-PHASE-TMP"
    printf 'distinct work\n' >"$repo/.TEST-PHASE-TMP/keep"
    # The case-distinct work must be discovered as untracked, not from the index.
    git -C "$repo" config core.ignoreCase false
  else
    mv "$repo/$indexed_scratch" "$repo/scratch-intermediate"
    mv "$repo/scratch-intermediate" "$repo/.test-phase-tmp"
  fi
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
  mkdir "$repo/tests/.test-phase-tmp"
  printf 'nested work\n' >"$repo/tests/.test-phase-tmp/keep"
  cat >"$runtime" <<'SH'
#!/usr/bin/env bash
if [ "$TMPDIR" != "$EXPECTED_TMP" ] || [ "$TMP" != "$EXPECTED_TMP" ] || [ "$TEMP" != "$EXPECTED_TMP" ]; then
  printf 'unexpected host temp paths for %s: %s %s %s\n' "$1" "$TMPDIR" "$TMP" "$TEMP" >&2
  exit 1
fi
case "$1" in
  build|ps) exit 0 ;;
  run) ;;
  *) exit 1 ;;
esac
copy=
workdir=/
while [ "$#" -gt 1 ]; do
  if [ "$#" -eq 3 ] && [ "$1" = sh ] && [ "$2" = -c ] && [ "$3" = 'uname -sr' ]; then
    printf '%s\n' 'Linux fixture'
    exit 0
  fi
  if [ "$#" -eq 2 ] && [ "$1" = bash ] && [ "$2" = tests/kept.test.sh ]; then
    suite="${workdir%/}/$2"
    case "$suite" in /work/*) ;; *) exit 1 ;; esac
    [ -n "$copy" ] && [ ! -e "$copy/.test-phase-tmp" ] &&
      { [ "$DISTINCT_CASE" -eq 0 ] || [ "$(<"$copy/.TEST-PHASE-TMP/keep")" = 'distinct work' ]; } &&
      { [ "$CHECK_ALIAS" -eq 0 ] || [ ! -e "$copy/alias/committed" ]; } &&
      [ ! -e "$copy/replaced/private" ] &&
      [ "$(<"$copy/replaced/public")" = included ] &&
      [ "$(<"$copy/${suite#/work/}")" = dirty ] &&
      [ "$(<"$copy/tests/.test-phase-tmp/keep")" = 'nested work' ] &&
      [ "$(<"$copy/tests/real work.txt")" = untracked ] || exit 1
    printf '%s\n' 'verified tests/kept.test.sh mount'
    exit 0
  fi
  if [ "$1" = -v ]; then
    case "$2" in /*:/work) ;; *) exit 1 ;; esac
    copy=${2%:/work}
    shift
  elif [ "$1" = -w ]; then
    workdir=$2
    shift
  fi
  shift
done
exit 1
SH
  chmod +x "$runtime"
  out=$(cd "$repo" && TMPDIR=../overlay-tmp TMP="$repo/.test-phase-tmp" TEMP="$repo/.test-phase-tmp" \
    EXPECTED_TMP="$expected_tmp" FM_CONTAINER_RUNTIME="$runtime" CHECK_ALIAS="$check_alias" DISTINCT_CASE="$distinct_case" \
    "$BASH" "$LINUX_CHECK" tests/kept.test.sh 0<&- 2>&1) || fail "Linux overlay did not match working-tree contract: $out"
  assert_not_contains "$out" 'unexpected host temp paths' 'host runtime receives the validated base'
  assert_contains "$out" 'verified tests/kept.test.sh mount' 'selected suite used the verified overlay'
  assert_contains "$out" 'PASS tests/kept.test.sh' 'container tested the overlay'
  if [ "$distinct_case" -eq 1 ]; then
    local rc=0
    git -C "$repo" config core.ignoreCase true
    out=$(cd "$repo" && TMPDIR="$expected_tmp" FM_CONTAINER_RUNTIME="$runtime" \
      "$BASH" "$LINUX_CHECK" tests/kept.test.sh 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail 'Linux probe silently dropped case-distinct untracked work'
    assert_contains "$out" 'core.ignoreCase would prune distinct entry' 'case-policy mismatch diagnostic'
    assert_equals 'distinct work' "$(<"$repo/.TEST-PHASE-TMP/keep")" 'refusal preserves source work'
  fi
  pass 'Linux overlay skips legacy scratch but keeps dirty and untracked work'
}

test_overlay_failure_prevents_container_run() {
  local repo="$TMP_ROOT/partial" mock_bin="$TMP_ROOT/partial-tools" stage out rc
  make_repo "$repo"
  mkdir "$mock_bin"
  cat >"$mock_bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$FAIL_STAGE" = inventory ] && [ "${3:-}" = ls-files ]; then
  printf '%s\0' tests/kept.test.sh
  exit 1
fi
exec "$REAL_GIT" "$@"
SH
  cat >"$mock_bin/tar" <<'SH'
#!/usr/bin/env bash
"$REAL_TAR" "$@" || exit $?
if [ "$FAIL_STAGE" = archive ] && [ "$1" = --no-recursion ]; then exit 1; fi
SH
  cat >"$mock_bin/runtime" <<'SH'
#!/usr/bin/env bash
if [ "$1" = run ]; then
  touch "$RUN_MARKER"
  mount=
  workdir=/
  while [ "$#" -gt 1 ]; do
    if [ "$#" -eq 3 ] && [ "$1" = sh ] && [ "$2" = -c ] && [ "$3" = 'uname -sr' ]; then
      printf '%s\n' 'Linux fixture'
      exit 0
    fi
    if [ "$#" -eq 2 ] && [ "$1" = bash ] && [ "$2" = tests/kept.test.sh ]; then
      [ "$workdir" = /work ] && [ -n "$mount" ] || exit 1
      cd -- "$mount" && exec "$@"
      exit 1
    fi
    case "$1" in
      -v) case "$2" in /*:/work) mount=${2%:/work} ;; *) exit 1 ;; esac; shift ;;
      -w) workdir=$2; shift ;;
    esac
    shift
  done
  exit 1
fi
SH
  chmod +x "$mock_bin/"*
  for stage in inventory archive nested gitlink empty-gitlink; do
    case "$stage" in
      nested) make_repo "$repo/tests/nested checkout" ;;
      gitlink)
        git -C "$repo" update-index --add --cacheinfo "160000,$(git -C "$repo/tests/nested checkout" rev-parse HEAD),tests/nested checkout"
        ;;
      empty-gitlink)
        rm -rf -- "$repo/tests/nested checkout"
        mkdir "$repo/tests/nested checkout"
        cat > "$repo/tests/kept.test.sh" <<'SH'
dir="tests/nested checkout"
[ -d "$dir" ] || exit 1
entries=$(ls -Aq -- "$dir") || exit 1
[ -z "$entries" ] || exit 1
printf '%s\n' 'selected suite saw empty gitlink directory'
SH
        ;;
    esac
    rc=0
    out=$(cd "$repo" && REAL_GIT="$(command -v git)" REAL_TAR="$(command -v tar)" \
      PATH="$mock_bin:$PATH" FM_CONTAINER_RUNTIME="$mock_bin/runtime" FAIL_STAGE="$stage" \
      RUN_MARKER="$mock_bin/ran" "$BASH" "$LINUX_CHECK" tests/kept.test.sh 2>&1) || rc=$?
    if [ "$stage" = empty-gitlink ]; then
      assert_equals 0 "$rc" "empty gitlink permits Linux validation: $out"
      assert_contains "$out" 'selected suite saw empty gitlink directory' 'the selected suite observes the placeholder from its workdir'
      assert_contains "$out" 'PASS tests/kept.test.sh' 'the selected suite ran'
      continue
    fi
    assert_equals 2 "$rc" "$stage failure aborts Linux validation: $out"
    [ ! -e "$mock_bin/ran" ] || fail "container ran after $stage failure"
    assert_not_contains "$out" 'PASS tests/kept.test.sh' "$stage failure must not report a pass"
    if [ "$stage" = nested ]; then
      assert_contains "$out" "cannot copy untracked directory 'tests/nested checkout'" 'refusal names the nested checkout'
      assert_contains "$out" 'ignore it or move it' 'refusal explains how to proceed'
    elif [ "$stage" = gitlink ]; then
      assert_contains "$out" "cannot copy Git checkout 'tests/nested checkout' recorded as a gitlink" 'refusal names the indexed checkout'
    fi
  done
  pass 'Linux validation refuses incomplete overlays'
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
    label=
    for arg; do
      case "$arg" in label=*) label=${arg#label=} ;; esac
    done
    if { [ -f "$FAKE_RUNTIME_STATE/running" ] || [ -f "$FAKE_RUNTIME_STATE/created" ]; } &&
        { [ -z "$label" ] || [ "$label" = "$(<"$FAKE_RUNTIME_STATE/launch-label")" ]; }; then
      printf '%s\n' container-id
    fi
    if [ -f "$FAKE_RUNTIME_STATE/foreign" ] &&
        { [ -z "$label" ] || [ "$label" = "$(<"$FAKE_RUNTIME_STATE/foreign")" ]; }; then
      printf '%s\n' foreign-id
    fi
    ;;
  rm)
    if [[ "$*" == *foreign-id* ]]; then rm "$FAKE_RUNTIME_STATE/foreign"; fi
    [ "${!#}" = container-id ] && [ -d "$(<"$FAKE_RUNTIME_STATE/scratch-path")" ] || exit 2
    touch "$FAKE_RUNTIME_STATE/remove-called"
    if [ "$MODE" != unresolved ]; then rm -f "$FAKE_RUNTIME_STATE/running" "$FAKE_RUNTIME_STATE/created"; fi
    ;;
  run)
    label=
    while [ "$#" -gt 1 ]; do
      case "$1" in
        --name|--name=*) printf 'requested container name is already in use\n' >&2; exit 125 ;;
        --label) label=$2; shift ;;
      esac
      if [ "$1" = -v ]; then
        [ ! -f "$FAKE_RUNTIME_STATE/running" ] && [ ! -f "$FAKE_RUNTIME_STATE/created" ] || { touch "$FAKE_RUNTIME_STATE/overlap"; exit 2; }
        printf '%s\n' "$label" >>"$FAKE_RUNTIME_STATE/labels"
        if [ -f "$FAKE_RUNTIME_STATE/scratch-path" ]; then touch "$FAKE_RUNTIME_STATE/next-test"; exit 0; fi
        printf '%s\n' "$label" >"$FAKE_RUNTIME_STATE/launch-label"
        printf '%s\n' "${2%:/work}" >"$FAKE_RUNTIME_STATE/scratch-path"
        if [ "$MODE" = undrained ]; then
          kill -TERM "$WRAPPER_PID" || exit 2
          exec sleep 3
        fi
        if [ "$MODE" = created ]; then touch "$FAKE_RUNTIME_STATE/created"; else touch "$FAKE_RUNTIME_STATE/running"; fi
        case "$MODE" in
          killed) kill -KILL "$WRAPPER_PID" || exit 2 ;;
          interrupted) kill -TERM "$WRAPPER_PID" || exit 2 ;;
        esac
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
  for mode in resolved unresolved created killed prelaunch undrained interrupted; do
    state="$TMP_ROOT/$mode"
    mkdir "$state"
    if [ "$mode" != prelaunch ]; then printf '%s\n' 'firstmate.test-launch=previous' >"$state/foreign"; fi
    rc=0
    out=$(cd "$repo" && TMPDIR="$state" FM_CONTAINER_RUNTIME="$runtime" FAKE_RUNTIME_STATE="$state" MODE="$mode" \
      FM_TEST_RETAIN_MARKER="$state/.retain-scratch" "$BASH" -c 'export WRAPPER_PID=$$; exec "$@"' _ \
      env BASH_ENV="$hook" "$BASH" "$LINUX_CHECK" tests/kept.test.sh tests/gone.test.sh 2>&1) || rc=$?
    if [ "$mode" = prelaunch ]; then
      assert_equals 143 "$rc" "TERM after marker publication: $out"
      assert_equals '' "$(ls -A "$state")" 'prelaunch cancellation leaves no container state, scratch, or retention marker'
      continue
    fi
    assert_present "$state/scratch-path" "suite reached the mounted launch: $out"
    scratch=$(<"$state/scratch-path")
    if [ "$mode" = undrained ]; then
      assert_equals 143 "$rc" "TERM with an unverified client: $out"
      assert_contains "$out" "retaining scratch: $scratch" 'unverified drain retains scratch'
      assert_contains "$out" "Linux container selector: label=$(<"$state/launch-label")" 'EXIT reports the retained launch selector'
      assert_absent "$state/daemon-contacted" 'daemon teardown must wait for verified client drain'
      assert_present "$scratch/tests/kept.test.sh" 'unverified client keeps its backing tree'
      fm_test_scratch_retained "$state" || fail 'unverified client lost parent retention'
      continue
    fi
    if [ "$mode" = killed ]; then
      assert_equals 137 "$rc" "wrapper was killed during container run: $out"
      assert_present "$state/running" 'daemon still owns the container'
      assert_contains "$out" "Linux container launch: scratch: $scratch; selector: label=$(<"$state/launch-label")" 'launch reports the backing tree and selector even without EXIT'
      fm_test_scratch_retained "$state" || fail 'wrapper did not publish retention before launch'
      assert_present "$scratch/tests/kept.test.sh" 'killed wrapper left the backing tree intact'
      continue
    fi
    if [ "$mode" = interrupted ]; then
      assert_equals 143 "$rc" "TERM exits after container teardown: $out"
    else
      assert_equals 1 "$rc" "client failure fails validation: $out"
    fi
    assert_present "$state/remove-called" 'validator tried to remove its daemon-side container before cleanup'
    assert_absent "$state/overlap" 'a new test did not start while a container was running'
    assert_present "$state/foreign" 'teardown leaves a differently labeled container running'
    if [ "$mode" != unresolved ]; then
      if [ "$mode" = interrupted ]; then
        assert_absent "$state/next-test" 'TERM stops test admission'
      else
        assert_present "$state/next-test" 'tests continue after confirmed teardown'
        assert_equals 2 "$(sort -u "$state/labels" | awk 'END {print NR}')" 'sequential launches carry distinct identities'
      fi
      assert_absent "$state/running" 'teardown stopped the owned container'
      assert_absent "$state/created" 'teardown removed the created container'
      assert_absent "$scratch" 'confirmed teardown allows scratch removal'
      if fm_test_scratch_retained "$state"; then fail 'confirmed removal left a retention marker'; fi
    else
      assert_absent "$state/next-test" 'unconfirmed teardown stops test admission'
      assert_present "$scratch/tests/kept.test.sh" 'unconfirmed teardown keeps mounted scratch'
      fm_test_scratch_retained "$state" || fail 'retention was not propagated'
      assert_contains "$out" "retaining scratch: $scratch" 'retention diagnostic'
      assert_contains "$out" "Linux container selector: label=$(<"$state/launch-label")" 'failed removal reports the retained launch selector'
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
