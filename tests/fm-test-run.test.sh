#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of behavior suite
# selection, portable lane composition, bounded concurrency, budgets, timing
# markers, JSON artifacts, coverage guard, and aggregate exit status.
#
# These tests intentionally exercise the runner with fixtures, --list, and
# focused scheduler checks, not the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

test_list_all_exact_suite_coverage() {
  local listed expected missing extra f
  listed=$("$RUNNER" --list --all | LC_ALL=C sort)
  expected=$(
    for f in "$ROOT"/tests/*.test.sh; do
      [ -f "$f" ] || continue
      printf 'tests/%s\n' "$(basename "$f")"
    done | LC_ALL=C sort
  )
  [ -n "$listed" ] || fail "--list --all printed nothing"
  missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  [ -z "$missing" ] || fail "--list --all missing scripts: $missing"
  [ -z "$extra" ] || fail "--list --all unexpected scripts: $extra"
  # No duplicates.
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = \
    "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" ] \
    || fail "--list --all must not duplicate scripts"
  pass "exact suite coverage: --all lists every tests/*.test.sh once"
}

test_family_selection() {
  local listed line
  listed=$("$RUNNER" --list --family pure-contract-unit)
  [ -n "$listed" ] || fail "--family pure-contract-unit selected nothing"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-test-run.test.sh' \
    || fail "pure-contract-unit must include fm-test-run.test.sh"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) ;;
      *) fail "family selection produced non-test path: $line" ;;
    esac
  done <<<"$listed"
  # Family mode must not equal the complete suite for a narrow family.
  local all_count fam_count
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] \
    || fail "pure-contract-unit must be a proper subset of --all"
  pass "family selection returns a proper subset of the suite"
}

test_single_script_selection() {
  local listed
  listed=$("$RUNNER" --list tests/fm-lint.test.sh)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "single-script list expected tests/fm-lint.test.sh, got: $listed"
  pass "single-script selection lists exactly that path"
}

test_changed_file_selection_is_conservative() {
  local listed all_count fam_count listed_count
  # A path-mapped pure unit should not expand to --all.
  listed=$("$RUNNER" --list --family pure-contract-unit)
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] || fail "changed-informed pure family still full suite"
  # Directly exercise --changed: empty or partial selection is ok; must not
  # exceed the suite and must never silently become --all by accident.
  listed=$("$RUNNER" --list --changed --base HEAD 2>/dev/null || true)
  if [ -n "$listed" ]; then
    listed_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
    [ "$listed_count" -le "$all_count" ] || fail "changed selection larger than suite"
  fi
  # A single test path selects only that script (same contract as a
  # tests/*.test.sh change entry in the map).
  listed=$("$RUNNER" --list tests/fm-brief.test.sh)
  [ "$listed" = "tests/fm-brief.test.sh" ] \
    || fail "test-file-only change contract should select one script"
  pass "changed-file selection stays conservative (never silent full suite)"
}

init_changed_fixture_repo() {
  local repo=$1 script
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$ROOT/bin/fm-test-scratch-lib.sh" "$repo/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-brief.test.sh \
    fm-ask-user-authority.test.sh \
    fm-documentation-audiences.test.sh \
    fm-test-isolation-proof.test.sh \
    fm-test-run.test.sh \
    fm-test-fixtures.test.sh \
    fm-cd-pretool-check.test.sh \
    fm-daemon.test.sh \
    fm-harness-adapter-instructions-live-e2e.test.sh \
    fm-harness-adapter-references.test.sh \
    fm-backend-herdr-smoke.test.sh \
    fm-secondmate-safety.test.sh \
    fm-session-start.test.sh \
    fm-afk-pi-herdr-return-e2e.test.sh \
    fm-backend.test.sh \
    fm-pr-merge.test.sh \
    fm-procevent-quota.test.sh \
    fm-quota-choose.test.sh \
    fm-pi-watch-extension.test.sh \
    fm-pi-windows-shell-invocation.test.sh \
    fm-afk-return.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-backend-cmux.test.sh \
    fm-backend-zellij.test.sh \
    fm-control-herdr-smoke.test.sh \
    fm-backend-orca.test.sh; do
    printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
  : >"$repo/tests/lib.sh"
  : >"$repo/tests/fm-backend-herdr-eventwait.test.py"
  : >"$repo/bin/fm-supervisor-target-lib.sh"
  : >"$repo/bin/fm-control-lib.sh"
  : >"$repo/bin/fm-timeout-lib.sh"
  : >"$repo/bin/fm-procevent-quota.sh"
  : >"$repo/bin/fm-quota-axi-lib.sh"
  : >"$repo/bin/fm-quota-choose.sh"
  : >"$repo/bin/unmapped-source.sh"
  # A shared top-level test fixture read by two suites in different families,
  # beside a tests/ file nothing reads at all.
  : >"$repo/tests/shared-probe-fixture.sh"
  : >"$repo/tests/unread-thing.sh"
  printf '# shared-probe-fixture.sh\n' >>"$repo/tests/fm-pr-merge.test.sh"
  printf '# shared-probe-fixture.sh\n' >>"$repo/tests/fm-secondmate-safety.test.sh"
  # A nested fixture whose consuming suite names only the fixture directory,
  # the shape the tests/fixtures/<dir>/ arm is keyed for.
  mkdir -p "$repo/tests/fixtures/demo"
  : >"$repo/tests/fixtures/demo/demo-fixture.sh"
  printf '# tests/fixtures/demo\n' >>"$repo/tests/fm-backend-orca.test.sh"
  # A shared helper with no curated family of its own, named by exactly ONE
  # script of the expensive real-Herdr family and consumed by one curated
  # watcher script. This is the shape that made a one-line helper change select
  # every real-Herdr E2E.
  : >"$repo/bin/shared-probe-lib.sh"
  printf '# shared-probe-lib.sh\n' >>"$repo/tests/fm-backend-herdr-smoke.test.sh"
  # shellcheck disable=SC2016  # literal fixture text: the reference must reach
  # the file verbatim so the changed-file scan can find it, not expand here.
  printf '. "$ROOT/bin/shared-probe-lib.sh"\n' >"$repo/bin/fm-watch-probe.sh"
  printf '# .claude/settings.json\n# .pi/extensions/fm-primary-turnend-guard.ts\n' \
    >>"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '# .pi/extensions/fm-primary-pi-watch.ts\n' >>"$repo/tests/fm-pi-watch-extension.test.sh"
  mkdir -p \
    "$repo/.agents/skills/example" \
    "$repo/.agents/skills/harness-adapters/references/common" \
    "$repo/.claude" "$repo/.pi/extensions" "$repo/docs" "$repo/src"
  : >"$repo/.agents/skills/example/SKILL.md"
  : >"$repo/.agents/skills/harness-adapters/SKILL.md"
  : >"$repo/.agents/skills/harness-adapters/references/common/dispatch.md"
  : >"$repo/.claude/settings.json"
  : >"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : >"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$repo/.pi/extensions/lib"
  : >"$repo/.pi/extensions/lib/fm-operational-input.ts"
  : >"$repo/docs/fm-test-isolation-proof.md"
  : >"$repo/CONTRIBUTING.md"
  : >"$repo/src/unmapped.ts"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
}

# Build a repository with a primary checkout and one linked worktree, each
# holding a runnable copy of the runner and a probe suite that records the fact
# that it ran. Untracked copies are enough: the runner resolves its root from
# its own path, and the probe is named explicitly.
init_primary_and_linked_worktree() {
  local repo=$1 linked=$2 tree
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b linked-probe "$linked"
  for tree in "$repo" "$linked"; do
    mkdir -p "$tree/bin" "$tree/tests"
    cp "$RUNNER" "$ROOT/bin/fm-test-scratch-lib.sh" "$tree/bin/"
    cp "$ROOT/tests/git-config-helpers.sh" "$tree/tests/"
    chmod +x "$tree/bin/fm-test-run.sh"
    cat >"$tree/tests/probe.test.sh" <<PROBE
#!/usr/bin/env bash
echo "ok - probe suite"
: >"$tree/ran"
PROBE
    chmod +x "$tree/tests/probe.test.sh"
  done
}

# A task worker's isolated placement is checked once, when the task starts.
# Nothing re-checks it, so a worker that later changes directory into the
# repository's primary checkout would run this branch-switching suite in the one
# checkout every linked worktree resolves against. The runner refuses that.
test_task_marker_refuses_the_primary_checkout() {
  local tmp repo linked out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-primary.XXXXXX")
  repo="$tmp/repo"
  linked="$tmp/linked"
  init_primary_and_linked_worktree "$repo" "$linked"

  # Marker set, primary checkout: refuse, name the primary, and run nothing.
  out=$(FM_TASK_ID=probe-task "$repo/bin/fm-test-run.sh" tests/probe.test.sh 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "the runner must refuse the primary checkout under a task marker"; }
  assert_contains "$out" "primary checkout" "refusal did not name the primary checkout"
  assert_contains "$out" "FM_TASK_ID=probe-task" "refusal did not name the task marker"
  assert_contains "$out" "task worktree" "refusal did not point at the task worktree"
  assert_not_contains "$out" "FM_TEST_BEGIN" "the refusal must happen before any suite runs"
  assert_absent "$repo/ran" "the refused run still executed a suite"

  # Marker set, linked worktree: the assigned placement, so the suite runs.
  FM_TASK_ID=probe-task "$linked/bin/fm-test-run.sh" tests/probe.test.sh >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "the runner must still run in a linked task worktree"; }
  assert_present "$linked/ran" "the linked-worktree run did not execute its suite"

  # No marker: a person in their own checkout is unaffected.
  "$repo/bin/fm-test-run.sh" tests/probe.test.sh >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "an unmarked run in the primary checkout must be unchanged"; }
  assert_present "$repo/ran" "the unmarked run did not execute its suite"

  # Inspection executes nothing, so it stays available even in the primary.
  rm -f "$repo/ran"
  out=$(FM_TASK_ID=probe-task "$repo/bin/fm-test-run.sh" --list tests/probe.test.sh 2>&1) \
    || { rm -rf "$tmp"; fail "--list must remain available under a task marker"; }
  [ "$out" = "tests/probe.test.sh" ] \
    || { rm -rf "$tmp"; fail "--list under a task marker printed: $out"; }
  assert_absent "$repo/ran" "--list must not execute a suite"

  rm -rf "$tmp"
  pass "a task marker refuses execution in the primary checkout and leaves worktrees and inspection alone"
}

test_changed_runner_surfaces_select_their_family() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-owner-scope.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  # A change to the runner selects the WHOLE pure-contract-unit family, not
  # just its own contract test. The runner executes every script in that
  # family, so its own test passing proves its logic is right, not that the
  # suite it drives still runs. Narrowing this to the contract owners would
  # also make any wall-clock claim about the changed suite trivially true by
  # not running the work.
  printf '\n' >>"$repo/bin/fm-test-run.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD | LC_ALL=C sort)
  case "$listed" in
    *tests/fm-test-run.test.sh*) ;;
    *) fail "runner change did not select its own contract test: $listed" ;;
  esac
  case "$listed" in
    *tests/fm-brief.test.sh*) ;;
    *) fail "runner change did not select its pure-contract-unit family: $listed" ;;
  esac
  case "$listed" in
    *tests/fm-ask-user-authority.test.sh*) ;;
    *) fail "runner change did not select its pure-contract-unit family: $listed" ;;
  esac
  # The suite that proves the runner's per-suite fixture Git isolation lives in
  # the standalone family, which pure-contract-unit never reaches.
  case "$listed" in
    *tests/fm-test-fixtures.test.sh*) ;;
    *) fail "runner change did not select its fixture-isolation regression: $listed" ;;
  esac
  git -C "$repo" add bin/fm-test-run.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm runner-change

  # The same holds for the surfaces that document that contract.
  printf '\n' >>"$repo/docs/fm-test-isolation-proof.md"
  printf '\n' >>"$repo/CONTRIBUTING.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD | LC_ALL=C sort)
  case "$listed" in
    *tests/fm-documentation-audiences.test.sh*) ;;
    *) fail "documentation surface change did not select audience coverage: $listed" ;;
  esac
  case "$listed" in
    *tests/fm-brief.test.sh*) ;;
    *) fail "documentation surface change did not select its curated family: $listed" ;;
  esac

  rm -rf "$tmp"
  pass "runner and its documentation surfaces select their curated family, not just their contract owners"
}

test_changed_scratch_helper_selects_teardown_coverage() {
  local tmp repo listed expected script
  tmp=$(fm_test_tmproot fm-scratch-selection)
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  for script in fm-claude-safeguard-live fm-hermes-gateway-coexistence-live-e2e \
    fm-hermes-profile-safety-live-e2e fm-hermes-signals-live-e2e fm-live-lab-isolation \
    fm-test-fixture-cleanup fm-test-linux fm-test-tap-verify; do
    touch "$repo/tests/$script.test.sh"
  done
  git -C "$repo" add tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm teardown-fixture
  printf '\n' >>"$repo/bin/fm-test-scratch-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) || fail 'could not list scratch coverage'
  expected=$(printf 'tests/%s.test.sh\n' fm-claude-safeguard-live fm-hermes-gateway-coexistence-live-e2e \
    fm-hermes-profile-safety-live-e2e fm-hermes-signals-live-e2e fm-live-lab-isolation fm-test-fixture-cleanup fm-test-fixtures \
    fm-test-isolation-proof fm-test-linux fm-test-run fm-test-tap-verify)
  assert_equals "$expected" "$(printf '%s\n' "$listed" | LC_ALL=C sort)" 'scratch-only changes select teardown and runner regressions'
  pass 'scratch helper changes select private teardown coverage'
}

test_shell_line_ending_policy_selects_runner_contract() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-attributes.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf '*.sh text eol=lf\n' >"$repo/.gitattributes"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-test-run.test.sh" \
    "shell line-ending policy selects the runner contract"
  rm -rf "$tmp"
  pass "shell line-ending policy selects runner coverage"
}

test_changed_remote_inheritance_selects_generation_contract() {
  local tmp repo listed source
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-inheritance.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf '#!/usr/bin/env bash\n' >"$repo/tests/fm-remote-inherit-generation.test.sh"
  chmod +x "$repo/tests/fm-remote-inherit-generation.test.sh"
  for source in fm-remote-inherit-push.sh fm-remote-inherit.sh fm-secondmate-nudge-lib.sh; do
    : >"$repo/bin/$source"
  done
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm inheritance-fixture
  for source in fm-remote-inherit-push.sh fm-remote-inherit.sh fm-secondmate-nudge-lib.sh; do
    printf '\n' >>"$repo/bin/$source"
    listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
    assert_contains "$listed" "tests/fm-remote-inherit-generation.test.sh" \
      "$source change must select the generation regression"
    assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" \
      "$source change must retain secondmate coverage"
    assert_not_contains "$listed" "tests/fm-ask-user-authority.test.sh" \
      "$source change must not select the whole pure-contract-unit family"
    git -C "$repo" checkout -q -- "bin/$source"
  done
  rm -rf "$tmp"
  pass "changed inheritance sender, receiver and counter select the focused generation contract"
}

test_changed_dependency_selection_and_unmapped_failure() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "shared helper selects pr-forge dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "shared helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "shared helper selects snapshot dependents"
  git -C "$repo" add tests/lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm helper-change

  printf '\n' >>"$repo/tests/git-config-helpers.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "git-config helper selects lib.sh dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "git-config helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "git-config helper selects snapshot dependents"
  git -C "$repo" add tests/git-config-helpers.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm git-config-helper-change

  printf '\n' >>"$repo/tests/fm-backend-herdr-eventwait.test.py"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" "eventwait test selects Herdr coverage"
  assert_contains "$listed" "tests/fm-backend.test.sh" "eventwait test selects backend coverage"
  git -C "$repo" add tests/fm-backend-herdr-eventwait.test.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm eventwait-change

  printf '\n' >>"$repo/bin/fm-supervisor-target-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-daemon.test.sh" "supervisor target selects daemon coverage"
  assert_contains "$listed" "tests/fm-afk-return.test.sh" "supervisor target selects afk coverage"
  git -C "$repo" add bin/fm-supervisor-target-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm supervisor-change

  printf '\n' >>"$repo/.agents/skills/example/SKILL.md"
  printf '\n' >>"$repo/.claude/settings.json"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-ask-user-authority.test.sh" "skill source selects pure contract coverage"
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" "Claude and Pi source selects hook coverage"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" "Pi source selects watcher coverage"
  assert_contains "$listed" "tests/fm-pi-windows-shell-invocation.test.sh" \
    "turn-end extension selects native-Windows shell coverage"
  git -C "$repo" add .agents .claude .pi
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm non-bin-source-change

  printf '\n' >>"$repo/.pi/extensions/lib/fm-operational-input.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pi-windows-shell-invocation.test.sh" \
    "operational-input extension selects native-Windows shell coverage"
  git -C "$repo" add .pi/extensions/lib/fm-operational-input.ts
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm operational-input-source-change

  printf '\n' >>"$repo/.agents/skills/harness-adapters/references/common/dispatch.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-harness-adapter-references.test.sh" "harness adapter reference selects portable structural coverage"
  assert_contains "$listed" "tests/fm-harness-adapter-instructions-live-e2e.test.sh" "harness adapter reference selects opt-in instruction coverage"
  git -C "$repo" add .agents/skills/harness-adapters
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm harness-adapter-reference-change

  printf '\n' >>"$repo/.agents/skills/harness-adapters/SKILL.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-harness-adapter-references.test.sh" "harness adapter router selects portable structural coverage"
  assert_contains "$listed" "tests/fm-harness-adapter-instructions-live-e2e.test.sh" "harness adapter router selects opt-in instruction coverage"
  git -C "$repo" add .agents/skills/harness-adapters/SKILL.md
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm harness-adapter-router-change

  printf '\n' >>"$repo/bin/fm-procevent-quota.sh"
  printf '\n' >>"$repo/bin/fm-quota-choose.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent-quota.test.sh" \
    "quota process-event source selects its focused test"
  assert_contains "$listed" "tests/fm-quota-choose.test.sh" \
    "quota chooser source selects its focused test"
  git -C "$repo" add bin/fm-procevent-quota.sh bin/fm-quota-choose.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm quota-source-change

  printf '\n' >>"$repo/bin/fm-quota-axi-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent-quota.test.sh" \
    "shared quota validator selects process-event coverage"
  assert_contains "$listed" "tests/fm-quota-choose.test.sh" \
    "shared quota validator selects chooser coverage"
  git -C "$repo" add bin/fm-quota-axi-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm quota-validator-change

  printf '\n' >>"$repo/bin/fm-control-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend.test.sh" \
    "control library keeps backend coverage"
  assert_contains "$listed" "tests/fm-session-start.test.sh" \
    "control library keeps session coverage"
  assert_contains "$listed" "tests/fm-quota-choose.test.sh" \
    "control library selects chooser coverage"
  git -C "$repo" add bin/fm-control-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm control-lib-change

  printf '\n' >>"$repo/bin/fm-timeout-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent-quota.test.sh" \
    "timeout library selects quota polling coverage"
  git -C "$repo" add bin/fm-timeout-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm timeout-lib-change

  printf '\n' >>"$repo/src/unmapped.ts"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unmapped changed source must fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: src/unmapped.ts' "$tmp/err" \
    || fail "unmapped changed source failure is not actionable: $(cat "$tmp/err")"

  rm -f "$repo/src/unmapped.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  [ -z "$listed" ] || fail "a retired unmapped source without consumers selected tests: $listed"
  rm -rf "$tmp"
  pass "changed selection covers dependents, fails closed for live unmapped source, and accepts retired unconsumed source"
}

# A direct test reference is per-script evidence. Widening it to the referencing
# test's whole family is what turned a one-line change to a shared helper into
# every real-Herdr E2E, including scripts with no dependency on it at all.
# Consumer bin/ scripts must still resolve through the curated map, so recorded
# family-level coupling is not lost along the way.
test_changed_bin_reference_selects_per_script_not_per_family() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed-scope.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/bin/shared-probe-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)

  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" \
    "the one gated script that names the helper must still be selected"
  case "$listed" in
    *tests/fm-control-herdr-smoke.test.sh*)
      fail "a single gated script's reference dragged in its whole family: $listed"
      ;;
  esac
  # The curated consumer keeps its family-level coupling.
  assert_contains "$listed" "tests/fm-daemon.test.sh" \
    "a curated consumer of the helper must still select its whole family"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" \
    "a curated consumer of the helper must still select its whole family"

  rm -rf "$tmp"
  pass "a bin reference selects the referencing scripts, and consumers still select their curated families"
}

# Exercise begin/end markers from real fixture processes to prove the automatic
# changed-suite default and its explicit serial override.
test_changed_uses_bounded_automatic_concurrency() {
  local tmp repo script serial_shape parallel_shape expected_jobs
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed-consent.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  for script in fm-backend-herdr-smoke.test.sh fm-daemon.test.sh fm-pi-watch-extension.test.sh; do
    cat >"$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
sleep 1
echo "ok - concurrency consent fixture"
SH
    chmod +x "$repo/tests/$script"
  done
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixtures
  printf '\n' >>"$repo/bin/shared-probe-lib.sh"

  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/parallel.json") \
    >"$tmp/parallel.out" 2>"$tmp/parallel.err" \
    || fail "default changed fixture run failed: $(cat "$tmp/parallel.err")"
  parallel_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/parallel.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$parallel_shape" = FM_TEST_BEGIN,FM_TEST_BEGIN ] \
    || fail "plain --changed did not use bounded concurrent scheduling: $parallel_shape"

  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --jobs 1 --json "$tmp/serial.json") \
    >"$tmp/serial.out" 2>"$tmp/serial.err" \
    || fail "explicit serial changed fixture run failed: $(cat "$tmp/serial.err")"
  serial_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/serial.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$serial_shape" = FM_TEST_BEGIN,FM_TEST_END ] \
    || fail "explicit --jobs 1 did not force serial execution: $serial_shape"
  expected_jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  case "$expected_jobs" in
    ''|*[!0-9]*) expected_jobs=1 ;;
  esac
  [ "$expected_jobs" -le 4 ] || expected_jobs=4
  [ "$expected_jobs" -ge 1 ] || expected_jobs=1
  python3 - "$tmp/parallel.json" "$tmp/serial.json" "$expected_jobs" <<'PY' \
    || fail "changed timing artifacts did not record their resolved worker counts"
import json, sys
automatic = json.load(open(sys.argv[1], encoding="utf-8"))
serial = json.load(open(sys.argv[2], encoding="utf-8"))
expected = int(sys.argv[3])
assert automatic["selection"].split(";")[-1] == f"jobs={expected}"
assert serial["selection"].split(";")[-1] == "jobs=1"
PY

  rm -rf "$tmp"
  pass "changed defaults to bounded automatic scheduling with serial override"
}

test_windows_posix_mode_emulation_does_not_fail_parallel_runs() {
  local tmp repo fakebin real_stat out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-windows-modes.XXXXXX")
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  real_stat=$(command -v stat)
  init_changed_fixture_repo "$repo"
  mkdir -p "$fakebin"
  cat >"$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UNAME:-MINGW64_NT-10.0}"
SH
  cat >"$fakebin/stat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -c ] && [ "${2:-}" = %a ] && [[ ${3##*/} = w[0-9]* ]]; then
  printf '%s\n' 755
  exit 0
fi
exec "$REAL_STAT" "$@"
SH
  chmod +x "$fakebin/uname" "$fakebin/stat"
  set +e
  out=$(cd "$repo" && PATH="$fakebin:$PATH" REAL_STAT="$real_stat" \
    bin/fm-test-run.sh --jobs 2 \
      tests/fm-cd-pretool-check.test.sh tests/fm-ask-user-authority.test.sh 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "native-Windows POSIX-mode emulation"
  assert_contains "$out" "FM_TEST_SUMMARY total=2 failed=0" \
    "Windows mode emulation did not complete both parallel scripts"

  set +e
  out=$(cd "$repo" && PATH="$fakebin:$PATH" REAL_STAT="$real_stat" FAKE_UNAME=CYGWIN_NT-10.0 \
    bin/fm-test-run.sh --jobs 2 \
      tests/fm-cd-pretool-check.test.sh tests/fm-ask-user-authority.test.sh 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "Cygwin POSIX-mode enforcement"
  assert_contains "$out" "isolation failure: worker root mode is 755, expected 0700" \
    "Cygwin mode enforcement did not reject a non-0700 worker root"
  rm -rf "$tmp"
  pass "Windows emulation exempts only synthetic POSIX modes"
}

# A local verification round names the subjects it cares about. Exercise begin/end
# markers from real fixture processes to prove that a plain list of script paths
# gets bounded automatic scheduling without changing its per-script timeout
# contract, so verifying several subjects is one bounded concurrent run rather
# than a serial chain of separate `bash tests/X.test.sh` invocations.
test_script_list_uses_bounded_automatic_concurrency() {
  local tmp repo script parallel_shape serial_shape mixed_shape expected_jobs
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-script-list.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  rm -f "$repo/bin/fm-timeout-lib.sh"
  # fm-cd-pretool-check and fm-pr-merge are individually proven isolated;
  # fm-backend-orca is not, so it must still land in the serial tail.
  for script in fm-cd-pretool-check.test.sh fm-pr-merge.test.sh fm-backend-orca.test.sh; do
    cat >"$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
sleep 1
echo "ok - script-list concurrency fixture"
SH
    chmod +x "$repo/tests/$script"
  done

  (cd "$repo" && bin/fm-test-run.sh tests/fm-cd-pretool-check.test.sh tests/fm-pr-merge.test.sh \
      --json "$tmp/parallel.json") >"$tmp/parallel.out" 2>"$tmp/parallel.err" \
    || fail "default script-list run failed: $(cat "$tmp/parallel.err")"
  parallel_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/parallel.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$parallel_shape" = FM_TEST_BEGIN,FM_TEST_BEGIN ] \
    || fail "a plain script list did not use bounded concurrent scheduling: $parallel_shape"

  (cd "$repo" && bin/fm-test-run.sh tests/fm-cd-pretool-check.test.sh tests/fm-pr-merge.test.sh \
      --jobs 1 --json "$tmp/serial.json") >"$tmp/serial.out" 2>"$tmp/serial.err" \
    || fail "explicit serial script-list run failed: $(cat "$tmp/serial.err")"
  serial_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/serial.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$serial_shape" = FM_TEST_BEGIN,FM_TEST_END ] \
    || fail "explicit --jobs 1 did not force a serial script list: $serial_shape"

  # An unproven script in the list is scheduled around, never refused and never
  # run beside another script.
  (cd "$repo" && bin/fm-test-run.sh tests/fm-cd-pretool-check.test.sh tests/fm-pr-merge.test.sh \
      tests/fm-backend-orca.test.sh) >"$tmp/mixed.out" 2>"$tmp/mixed.err" \
    || fail "mixed proven/unproven script list failed: $(cat "$tmp/mixed.err")"
  mixed_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/mixed.out" | awk '{print $1}' | paste -sd, -)
  [ "$mixed_shape" = FM_TEST_BEGIN,FM_TEST_BEGIN,FM_TEST_END,FM_TEST_END,FM_TEST_BEGIN,FM_TEST_END ] \
    || fail "an unproven script was not kept in the serial tail: $mixed_shape"

  expected_jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  case "$expected_jobs" in
    ''|*[!0-9]*) expected_jobs=1 ;;
  esac
  [ "$expected_jobs" -le 4 ] || expected_jobs=4
  [ "$expected_jobs" -ge 1 ] || expected_jobs=1
  python3 - "$tmp/parallel.json" "$tmp/serial.json" "$expected_jobs" <<'PYJSON' \
    || fail "script-list timing artifacts did not record their resolved worker counts"
import json, sys
automatic = json.load(open(sys.argv[1], encoding="utf-8"))
serial = json.load(open(sys.argv[2], encoding="utf-8"))
expected = int(sys.argv[3])
assert automatic["selection"].split(";")[-1] == f"jobs={expected}"
assert serial["selection"].split(";")[-1] == "jobs=1"
PYJSON

  (cd "$repo" && bin/fm-test-run.sh tests/fm-backend-orca.test.sh) \
    >"$tmp/named.out" 2>"$tmp/named.err" \
    || fail "a named script unexpectedly required a timeout helper: $(cat "$tmp/named.err")"
  grep -Eq '^FM_TEST_END .+ tests/fm-backend-orca\.test\.sh exit=0 ' "$tmp/named.out" \
    || fail "a named script did not run without an automatic bound: $(cat "$tmp/named.out")"

  rm -rf "$tmp"
  pass "a plain script list defaults to bounded automatic concurrency without an automatic timeout"
}

test_family_proofs_run_in_separate_concurrent_phases() {
  local tmp repo script
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-family-phases.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-test-scratch-lib.sh" "$repo/bin/"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-calm-pi-extension.test.sh fm-vendor-auth-probe.test.sh \
    fm-pr-check-security.test.sh fm-teardown.test.sh; do
    cat >"$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
sleep 1
echo "ok - family phase fixture"
SH
    chmod +x "$repo/tests/$script"
  done

  (cd "$repo" && bin/fm-test-run.sh \
      tests/fm-pr-check-security.test.sh tests/fm-calm-pi-extension.test.sh \
      tests/fm-teardown.test.sh tests/fm-vendor-auth-probe.test.sh --jobs 4) \
    >"$tmp/out" 2>"$tmp/err" \
    || fail "cross-family phase fixture failed: $(cat "$tmp/err")"

  python3 - "$tmp/out" <<'PY' \
    || fail "family-proof scripts from different families overlapped: $(cat "$tmp/out")"
import re, sys
active = {}
overlap = {"pure-contract-unit": False, "pr-forge": False}
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("FM_TEST_BEGIN "):
        match = re.search(r" (tests/\S+) family=(\S+) ", line)
        assert match, line
        path, family = match.groups()
        assert not active or set(active.values()) == {family}, (active, line)
        active[path] = family
        if sum(value == family for value in active.values()) > 1:
            overlap[family] = True
    elif line.startswith("FM_TEST_END "):
        match = re.search(r" (tests/\S+) exit=", line)
        assert match and match.group(1) in active, (active, line)
        del active[match.group(1)]
assert not active, active
assert all(overlap.values()), overlap
PY

  rm -rf "$tmp"
  pass "family proofs run concurrently only within separate family phases"
}

test_empty_selection_emits_summary() {
  local tmp repo out json rc fake_bin real_git
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-empty.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf 'documentation only\n' >"$repo/README.md"
  out=$(cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/artifacts/timing.json" 2>"$tmp/err") \
    || fail "empty valid changed selection must pass"
  printf '%s\n' "$out" | grep -Eq \
    '^FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=[0-9]+$' \
    || fail "empty selection summary is missing or malformed: $out"
  json="$tmp/artifacts/timing.json"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["summary"]["total"] == 0
assert doc["summary"]["failed"] == 0
assert doc["summary"]["skipped_gate"] == 0
assert doc["summary"]["duration_ms"] >= 0
assert doc["scripts"] == []
assert doc["families"] == []
' "$json" || { rm -rf "$tmp"; fail "empty selection JSON summary is wrong"; }
  fake_bin="$tmp/fake-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  cat >"$fake_bin/git" <<'SH'
#!/usr/bin/env bash
if [ ! -e "$SLOW_GIT_MARKER" ]; then
  : >"$SLOW_GIT_MARKER"
  sleep 1
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$fake_bin/git"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$PWD"\n' >"$fake_bin/getconf"
  chmod +x "$fake_bin/getconf"
  out=$(cd "$repo" && PATH="$fake_bin:$PATH" REAL_GIT="$real_git" SLOW_GIT_MARKER="$tmp/slow-git" \
    bin/fm-test-run.sh --changed --base HEAD) || fail 'report-free empty selection needs no scratch'
  assert_contains "$out" 'FM_TEST_SUMMARY total=0 failed=0' 'report-free empty summary'
  (cd "$repo" && PATH="$fake_bin:$PATH" REAL_GIT="$real_git" SLOW_GIT_MARKER="$tmp/slow-git" \
    bin/fm-test-run.sh --changed --base HEAD --json "$tmp/no-scratch.json") \
    || fail 'empty JSON report needs no scratch'
  python3 -c 'import json,sys; doc=json.load(open(sys.argv[1])); assert doc["scripts"] == doc["families"] == []; assert doc["summary"]["total"] == 0' \
    "$tmp/no-scratch.json" || fail 'missing or incorrect empty JSON report'
  rm -f "$tmp/slow-git" "$fake_bin/getconf"
  set +e
  (cd "$repo" && PATH="$fake_bin:$PATH" REAL_GIT="$real_git" SLOW_GIT_MARKER="$tmp/slow-git" \
    bin/fm-test-run.sh --changed --base HEAD --max-wall-ms 100) \
    >"$tmp/slow-selection.out" 2>"$tmp/slow-selection.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "an empty run past its budget must fail normally, got $rc"
  grep -Eq '^FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=[0-9]+$' "$tmp/slow-selection.out" \
    || fail "over-budget empty selection omitted its summary"
  grep -Eq '^FM_TEST_BUDGET max_wall_ms=100 duration_ms=[0-9]+$' "$tmp/slow-selection.out" \
    || fail "over-budget empty selection omitted its budget result"
  [ -e "$tmp/slow-git" ] || fail "the slow selection fixture did not run"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --max-wall-ms nope) \
    >"$tmp/bad-budget.out" 2>"$tmp/bad-budget.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "malformed budget on an empty selection must be refused, got $rc"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --per-script-timeout-secs nope) \
    >"$tmp/bad-timeout.out" 2>"$tmp/bad-timeout.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "malformed timeout on an empty selection must be refused, got $rc"
  rm -rf "$tmp"
  pass "empty changed selection emits deterministic text and JSON summaries"
}

test_timing_markers_and_json() {
  local tmp fixture out json begin_n end_n summary
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-timing.XXXXXX")
  fixture="$tmp/ok.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  chmod +x "$fixture"
  "$RUNNER" --json "$json" "$fixture" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "runner should pass on a green fixture"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$out" || true)
  [ "$begin_n" -eq 1 ] || fail "expected one FM_TEST_BEGIN, got $begin_n"
  [ "$end_n" -eq 1 ] || fail "expected one FM_TEST_END, got $end_n"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$out" \
    || fail "BEGIN line missing family/expected_gate_skip: $(grep '^FM_TEST_BEGIN' "$out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false$' "$out" \
    || fail "END line missing exit/duration/gate_skip: $(grep '^FM_TEST_END' "$out")"
  summary=$(grep '^FM_TEST_SUMMARY ' "$out" || true)
  assert_contains "$summary" "total=1" "summary total"
  assert_contains "$summary" "failed=0" "summary failed"
  assert_contains "$summary" "skipped_gate=0" "summary skipped_gate"
  grep -q '^FM_TEST_SLOWEST rank=1 ' "$out" \
    || fail "expected FM_TEST_SLOWEST rank=1"
  [ -f "$json" ] || fail "JSON timing artifact was not written"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$json" \
    || fail "JSON timing artifact is not valid JSON"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert "scripts" in doc and len(doc["scripts"]) == 1, doc
assert doc["scripts"][0]["exit"] == 0
assert doc["scripts"][0]["gate_skip"] is False
assert doc["summary"]["total"] == 1
assert doc["summary"]["failed"] == 0
assert "duration_ms" in doc["scripts"][0]
assert "family" in doc["scripts"][0]
' "$json" || { rm -rf "$tmp"; fail "JSON timing artifact missing required fields"; }
  rm -rf "$tmp"
  pass "timing markers and JSON artifact are valid"
}

test_aggregate_exit_behavior() {
  local tmp pass_f fail_f rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-agg.XXXXXX")
  pass_f="$tmp/pass.test.sh"
  fail_f="$tmp/fail.test.sh"
  cat >"$pass_f" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
exit 0
SH
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
echo "not ok - fail"
exit 1
SH
  chmod +x "$pass_f" "$fail_f"
  set +e
  "$RUNNER" "$pass_f" "$fail_f" >"$tmp/out.txt" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate exit must be non-zero when any script fails"
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out.txt" \
    || fail "summary should report total=2 failed=1: $(grep FM_TEST_SUMMARY "$tmp/out.txt")"
  # All-green stays 0.
  set +e
  "$RUNNER" "$pass_f" >"$tmp/out2.txt" 2>"$tmp/err2.txt"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "aggregate exit must be 0 when every script passes"; }
  rm -rf "$tmp"
  pass "aggregate exit reflects any script failure"
}

test_gate_skip_accounting() {
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "gate-skip fixture must exit 0 from the runner"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$out" \
    || fail "END must mark gate_skip=true: $(grep '^FM_TEST_END' "$out")"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$out" \
    || fail "summary must count skipped_gate=1: $(grep FM_TEST_SUMMARY "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["scripts"][0]["gate_skip"] is True
assert doc["summary"]["skipped_gate"] == 1
assert doc["summary"]["failed"] == 0
' "$json" || { rm -rf "$tmp"; fail "JSON gate_skip accounting is wrong"; }
  rm -rf "$tmp"
  pass "gate-skip accounting is honest and non-failing"
}

test_gate_skip_reason_is_recorded() {
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skipreason.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: live: fmnosuchharness absent"
exit 0
SH
  chmod +x "$skip_f"
  "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "a capability skip must still exit 0 from the runner"
  grep -q 'live: fmnosuchharness absent' "$tmp/err.txt" \
    || fail "the runner log must name what this host could not exercise: $(cat "$tmp/err.txt")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
record = doc["scripts"][0]
assert record["gate_skip"] is True, record
assert record["gate_skip_reason"] == "live: fmnosuchharness absent", record
' "$json" || { rm -rf "$tmp"; fail "the timing artifact must carry the skip reason"; }
  rm -rf "$tmp"
  pass "a gate skip records why it skipped"
}

test_a_run_that_ran_records_no_skip_reason() {
  local tmp ran_f json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-ranreason.XXXXXX")
  ran_f="$tmp/ran.test.sh"
  json="$tmp/timing.json"
  cat >"$ran_f" <<'SH'
#!/usr/bin/env bash
echo "ok - ran"
exit 0
SH
  chmod +x "$ran_f"
  "$RUNNER" --json "$json" "$ran_f" >"$tmp/out.txt" 2>&1 \
    || fail "a passing fixture must exit 0 from the runner"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
record = doc["scripts"][0]
assert record["gate_skip"] is False, record
assert record["gate_skip_reason"] == "", record
' "$json" || { rm -rf "$tmp"; fail "a script that ran must carry an empty skip reason"; }
  rm -rf "$tmp"
  pass "a script that actually ran records no skip reason"
}

test_live_guards_expect_a_capability_skip_class() {
  local tmp out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-liveclass.XXXXXX")
  out="$tmp/out.txt"
  # FM_LIVE=0 makes every live guard refuse without touching a harness, so this
  # exercises the real family through the real runner in bounded time.
  FM_LIVE=0 "$RUNNER" --json "$tmp/timing.json" \
    tests/fm-composer-matrix-live-e2e.test.sh >"$out" 2>"$tmp/err.txt" \
    || fail "a disabled live guard must not fail the runner: $(cat "$tmp/err.txt")"
  grep -q 'expected_gate_skip=live-capability' "$out" \
    || fail "the live-harness family must expect a capability skip: $(grep FM_TEST_BEGIN "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
record = doc["scripts"][0]
assert record["expected_gate_skip"] == "live-capability", record
assert record["gate_skip"] is True, record
assert record["gate_skip_reason"].startswith("live: "), record
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "the live guard record is wrong"; }
  rm -rf "$tmp"
  pass "live guards are recorded as a capability class, not a bare env opt-in"
}

test_fail_on_gate_skip_token() {
  local tmp skip_f out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fail-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  set +e
  "$RUNNER" --fail-on-gate-skip 'herdr not found' "$skip_f" >"$out" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fail-on-gate-skip must make herdr-not-found a hard failure"
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$out" \
    || fail "summary must report failed=1 under fail-on-gate-skip: $(grep FM_TEST_SUMMARY "$out")"
  grep -q 'required gate skip token' "$tmp/err.txt" \
    || fail "runner must log the required gate skip token"
  rm -rf "$tmp"
  pass "fail-on-gate-skip converts herdr-not-found into a hard failure"
}

test_exclude_family() {
  local listed
  listed=$("$RUNNER" --list --all --exclude-family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "exclude-family real-herdr-gated left a real-herdr script"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-lint.test.sh' \
    || fail "exclude-family must retain pure-contract-unit scripts"
  # Explicit family mode still works; exclude of a different family is a no-op.
  listed=$("$RUNNER" --list --family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "family real-herdr-gated must list smoke test"
  pass "exclude-family drops the named primary family after selection"
}

test_tern_family_selection() {
  local listed families
  families=$("$RUNNER" --list-families)
  printf '%s\n' "$families" | grep -qx tern || fail "--list-families must name the tern family"
  listed=$("$RUNNER" --list --family tern)
  assert_contains "$listed" "tests/fm-backend-tern.test.sh" "family tern must select the fake-CLI suite"
  assert_contains "$listed" "tests/fm-backend-tern-smoke.test.sh" "family tern must select the real-binary smoke test"
  assert_not_contains "$listed" "tests/tern-test-safety.sh" "the safety helper is a shared library, not a runnable suite"
  assert_not_contains "$listed" "tests/fm-backend-cmux.test.sh" "family tern must not absorb the cmux suite"
  # The scripts are real members of the portable lanes, so the coverage guard
  # (every tests/*.test.sh belongs to exactly one lane) sees them.
  "$RUNNER" --list-lanes >/dev/null || fail "--list-lanes failed with the tern scripts present"
  pass "fm-test-run: family tern selects the tern suite and smoke test, and the lane coverage guard accepts them"
}

test_list_scheduled_proven_isolated_uses_serial_weights() {
  local tmp
  tmp=$(fm_test_tmproot fm-test-run-proven-schedule)
  "$RUNNER" --list --proven-isolated | LC_ALL=C sort >"$tmp/expected"
  "$RUNNER" --list-scheduled --proven-isolated >"$tmp/actual" \
    || fail "--list-scheduled --proven-isolated failed"
  cmp -s "$tmp/expected" "$tmp/actual" \
    || fail "proven-isolated scheduling must break serial-default ties by path"
  pass "proven-isolated scheduling ignores parallel hints"
}

test_list_scheduled_non_lane_selections_use_serial_weights() {
  local tmp repo script selection
  local -a scripts=(
    tests/fm-operational-input.test.sh
    tests/fm-lint.test.sh
    tests/fm-muse-harness.test.sh
    tests/fm-captain-hold-lifecycle.test.sh
    tests/fm-kimi-harness.test.sh
    tests/fm-brief.test.sh
  )
  tmp=$(fm_test_tmproot fm-test-run-non-lane-schedule)
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$ROOT/bin/fm-test-scratch-lib.sh" "$repo/bin/"
  for script in "${scripts[@]}"; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/$script"
    chmod +x "$repo/$script"
  done
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
  for script in "${scripts[@]}"; do
    printf '\n' >>"$repo/$script"
  done
  printf '%s\n' \
    tests/fm-kimi-harness.test.sh \
    tests/fm-muse-harness.test.sh \
    tests/fm-brief.test.sh \
    tests/fm-captain-hold-lifecycle.test.sh \
    tests/fm-lint.test.sh \
    tests/fm-operational-input.test.sh >"$tmp/expected"
  for selection in family all changed scripts; do
    case "$selection" in
      family) set -- --family pure-contract-unit ;;
      all) set -- --all ;;
      changed) set -- --changed --base HEAD ;;
      scripts) set -- "${scripts[@]}" ;;
    esac
    "$repo/bin/fm-test-run.sh" --list-scheduled "$@" >"$tmp/actual" \
      || fail "--list-scheduled $selection failed"
    cmp -s "$tmp/expected" "$tmp/actual" \
      || fail "$selection scheduling must use serial hints and path-ordered default ties"
  done
  pass "family, all, changed, and script selections ignore parallel hints"
}

test_portable_shard_union_and_coverage_guard() {
  local s1 s2 proven serial herdr all_count union_count overlap out lane
  s1=$("$RUNNER" --list --lane portable-parallel-1)
  s2=$("$RUNNER" --list --lane portable-parallel-2)
  proven=$("$RUNNER" --list --proven-isolated)
  serial=$("$RUNNER" --list --lane portable-serial)
  herdr=$("$RUNNER" --list --family real-herdr-gated)
  [ -n "$s1" ] && [ -n "$s2" ] || fail "portable parallel shards must be non-empty"
  printf '%s\n' "$s1" | grep -Fxq 'tests/fm-pi-primary-types.test.sh' \
    || fail "Pi typecheck must stay in portable parallel shard 1 with its CI prerequisite check"
  # Shards disjoint.
  overlap=$(comm -12 <(printf '%s\n' "$s1" | LC_ALL=C sort) <(printf '%s\n' "$s2" | LC_ALL=C sort) || true)
  [ -z "$overlap" ] || fail "portable parallel shards overlap: $overlap"
  # Union of shards equals proven-isolated.
  [ "$(printf '%s\n' "$s1" "$s2" | LC_ALL=C sort -u)" = \
    "$(printf '%s\n' "$proven" | LC_ALL=C sort -u)" ] \
    || fail "shard union must equal proven-isolated set"
  # No herdr in portable lanes.
  printf '%s\n' "$s1" "$s2" "$serial" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "portable lanes must not include real-herdr-gated smoke"
  printf '%s\n' "$herdr" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "herdr family must include smoke"
  out=$("$RUNNER" --check-coverage)
  assert_contains "$out" "FM_TEST_COVERAGE ok" "coverage guard success marker"
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  union_count=$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$union_count" = "$all_count" ] \
    || fail "union of lanes ($union_count) must equal --all ($all_count)"
  # No duplicates across the four partitions.
  [ "$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" = "0" ] \
    || fail "lanes must not duplicate scripts"
  # LPT execution order, asserted against the runner's own measured schedule
  # rather than against a script name: naming the current longest script here is
  # what let the recorded lane duration go stale unnoticed in the first place.
  for lane in portable-parallel-1 portable-parallel-2; do
    [ "$("$RUNNER" --list --lane "$lane")" = "$("$RUNNER" --list-scheduled --lane "$lane")" ] \
      || fail "$lane membership must be stored longest-measured-first"
  done
  pass "portable shard union, disjointness, and coverage guard hold"
}

# The two parallel lanes are only "duration-balanced" while every member has a
# measured hint and the packing over those hints stays even. Both halves went
# unchecked until one lane grew past its CI job cap and was cancelled on every
# run, so assert them through the guard's own reported numbers.
test_portable_parallel_lanes_stay_duration_balanced() {
  local out max imbalance unhinted
  out=$("$RUNNER" --check-coverage)
  unhinted=$(printf '%s\n' "$out" | sed -n 's/.*parallel_unhinted=\([0-9]*\).*/\1/p')
  max=$(printf '%s\n' "$out" | sed -n 's/.*parallel_max_ms=\([0-9]*\).*/\1/p')
  imbalance=$(printf '%s\n' "$out" | sed -n 's/.*parallel_imbalance_ms=\([0-9]*\).*/\1/p')
  [ -n "$unhinted" ] && [ -n "$max" ] && [ -n "$imbalance" ] \
    || fail "coverage guard must report parallel_unhinted, parallel_max_ms, parallel_imbalance_ms: $out"
  [ "$unhinted" = "0" ] \
    || fail "$unhinted proven-isolated scripts have no measured parallel hint, so the lanes are packed on a guess"
  [ "$max" -gt 0 ] || fail "parallel_max_ms must be a positive packed duration, got $max"
  # 5% of the worst lane: wide enough that one script's growth does not trip it,
  # narrow enough that a lopsided partition cannot call itself balanced.
  [ "$((imbalance * 20))" -le "$max" ] \
    || fail "parallel lanes differ by ${imbalance}ms against a ${max}ms worst lane, more than 5%"
  pass "portable parallel lanes are fully hinted and packed within 5% of each other"
}

test_portable_serial_shards_partition_the_serial_lane() {
  local lanes count serial shard listed union dups shard_lane total cap shard_size first_shard
  lanes=$("$RUNNER" --list-lanes)
  count=$(printf '%s\n' "$lanes" | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  [ "$count" -ge 2 ] || fail "expected at least two portable serial shard lanes, got $count"
  printf '%s\n' "$lanes" | grep -q "^portable-serial-1of${count}\$" \
    || fail "shard lane names must carry the shard count ${count}: $lanes"

  serial=$("$RUNNER" --list --lane portable-serial | LC_ALL=C sort)
  total=$(printf '%s\n' "$serial" | wc -l | tr -d ' ')
  cap=$((total * 6 / 10))
  union=""
  first_shard=""
  shard=1
  while [ "$shard" -le "$count" ]; do
    shard_lane="portable-serial-${shard}of${count}"
    listed=$("$RUNNER" --list --lane "$shard_lane") || fail "$shard_lane could not list tests"
    [ -n "$listed" ] || fail "$shard_lane selected no tests"
    # No shard should hold nearly all the scripts. An expensive suite can
    # still occupy its own runner; script counts are not duration weights.
    shard_size=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
    [ "$shard_size" -le "$cap" ] || fail "$shard_lane holds $shard_size of $total scripts"
    if [ "$shard" -eq 1 ]; then
      first_shard=$listed
    fi
    union=$(printf '%s\n%s' "$union" "$listed")
    shard=$((shard + 1))
  done
  union=$(printf '%s\n' "$union" | grep -v '^$' || true)

  dups=$(printf '%s\n' "$union" | LC_ALL=C sort | uniq -d || true)
  [ -z "$dups" ] || fail "portable serial shards run the same script twice: $dups"
  [ "$(printf '%s\n' "$union" | LC_ALL=C sort)" = "$serial" ] \
    || fail "portable serial shards must exactly cover the portable serial lane"

  # Compare shard 1 with a fresh invocation to check deterministic ordering.
  listed=$("$RUNNER" --list --lane "portable-serial-1of${count}") || fail "could not relist shard 1"
  [ "$first_shard" = "$listed" ] || fail "portable serial shard membership must be deterministic"
  pass "portable serial shards are a deterministic disjoint cover of the serial lane"
}

test_portable_serial_packing_rejects_failed_output() {
  local tmp fakebin real_sort count out
  tmp=$(fm_test_tmproot fm-test-run-packing-failure)
  fakebin=$(fm_fakebin "$tmp")
  real_sort=$(command -v sort)
  count=$("$RUNNER" --list-lanes | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  # A failed sorter can emit usable-looking rows before it exits nonzero.
  printf '#!/usr/bin/env bash\n"%s" "$@"\nexit 42\n' "$real_sort" > "$fakebin/sort"
  chmod +x "$fakebin/sort"
  if out=$(PATH="$fakebin:$PATH" "$RUNNER" --list --lane "portable-serial-1of${count}" 2>&1); then
    fail "serial shard accepted output from a failed packer: $out"
  fi
  assert_contains "$out" 'could not pack portable serial shards' 'shard refusal must explain the packing failure'
  assert_not_contains "$out" 'tests/' 'a failed packer must not publish a shard list'
  pass 'serial shards reject output from a failed packer'
}

test_portable_serial_hint_coverage_is_reported_and_bounded() {
  local out serial unhinted max budget
  # Shards are packed from measured duration hints, so an unmeasured script is
  # placed on a guess. Enough of them and the partition still looks balanced by
  # script count while one shard carries far more real work than another and
  # reaches its CI job cap. The coverage guard therefore reports the unmeasured
  # share and refuses past its bound; assert that contract is live rather than
  # trusting the hint table to stay fresh on its own.
  out=$("$RUNNER" --check-coverage)
  assert_contains "$out" "serial_unhinted=" "coverage guard must report the unmeasured serial share"
  serial=$(printf '%s\n' "$out" | sed -n 's/.*[^_]serial=\([0-9][0-9]*\).*/\1/p')
  unhinted=$(printf '%s\n' "$out" | sed -n 's/.*serial_unhinted=\([0-9][0-9]*\).*/\1/p')
  [ -n "$serial" ] && [ -n "$unhinted" ] \
    || fail "coverage summary must carry numeric serial counts: $out"
  [ "$serial" -gt 0 ] || fail "portable serial lane must be non-empty, got $serial"
  [ "$unhinted" -le "$serial" ] \
    || fail "unmeasured count $unhinted exceeds the serial lane size $serial"
  # 15% is the guard's own bound; staying well inside it is what keeps the
  # balance evidence-based. Refresh from a green run's timing artifacts when
  # this trips (docs/fm-test-portable-shards.md).
  [ "$((unhinted * 100))" -le "$((serial * 15))" ] \
    || fail "$unhinted of $serial portable serial scripts lack a measured hint; refresh them"
  # A complete partition can still overflow a CI job. Assert the runner's
  # modeled packing target through its executable interface, not source hints.
  max=$(printf '%s\n' "$out" | sed -n 's/.*serial_max_ms=\([0-9][0-9]*\).*/\1/p')
  budget=$(printf '%s\n' "$out" | sed -n 's/.*serial_budget_ms=\([0-9][0-9]*\).*/\1/p')
  [ -n "$max" ] && [ -n "$budget" ] \
    || fail "coverage summary must carry serial packing and budget: $out"
  [ "$budget" -eq 1200000 ] || fail "packing must leave ten minutes of the normal CI tier"
  [ "$max" -gt 0 ] && [ "$max" -le "$budget" ] \
    || fail "largest serial shard packs ${max}ms above the ${budget}ms target"
  pass "coverage guard bounds the unmeasured share and serial packing within twenty minutes"
}

test_portable_serial_packing_budget_boundary() {
  local tmp repo script weight out rc
  tmp=$(fm_test_tmproot fm-test-run-packing-boundary)
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  # Preserve the real inventory and packing policy without executing suites.
  # Give every inventory member a fixture hint so an unmeasured real script
  # cannot take the default weight and join the at-budget shard.
  while IFS= read -r script; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/$script"
  done < <("$RUNNER" --list --all)

  for weight in 1200000 1200001; do
    cp "$RUNNER" "$ROOT/bin/fm-test-scratch-lib.sh" "$repo/bin/"
    python3 - "$repo/bin/fm-test-run.sh" "$weight" <<'PY' \
      || fail "could not seed the fixture's measured timing input"
from pathlib import Path
import re, sys
runner = Path(sys.argv[1])
weight = sys.argv[2]
text = runner.read_text()
scripts = sorted(
    f"tests/{path.name}" for path in (runner.parent.parent / "tests").glob("*.test.sh")
)
if "tests/fm-watch-triage.test.sh" not in scripts:
    sys.exit("fixture inventory lost tests/fm-watch-triage.test.sh")
# Longest real serial member stays at the budget boundary; every other script
# gets 1ms so longest-processing-time packing cannot fill that shard.
lines = [
    f"{script} {weight if script == 'tests/fm-watch-triage.test.sh' else '1'}"
    for script in scripts
]
table = "\n".join(lines)
new, n = re.subn(
    r"(portable_serial_weight_hints\(\) \{\n  cat <<'EOF'\n).*?(\nEOF\n)",
    lambda match: match.group(1) + table + match.group(2),
    text,
    count=1,
    flags=re.S,
)
if n != 1:
    sys.exit("serial hint table not found")
runner.write_text(new)
PY
    out=$(bash "$repo/bin/fm-test-run.sh" --check-coverage 2>&1) && rc=0 || rc=$?
    if [ "$weight" -eq 1200000 ]; then
      expect_code 0 "$rc" "packing exactly at the budget must be accepted"
      assert_contains "$out" "FM_TEST_COVERAGE ok" "boundary coverage did not pass"
      assert_contains "$out" "serial_max_ms=1200000" "fixture did not pack exactly at the budget"
      assert_contains "$out" "serial_budget_ms=1200000" "fixture changed the packing budget"
    else
      expect_code 1 "$rc" "packing one millisecond above the budget must be refused"
      assert_contains "$out" "largest portable serial shard packs 1200001ms above the 1200000ms target" \
        "over-budget refusal did not explain the modeled excess"
      assert_not_contains "$out" "FM_TEST_COVERAGE ok" "over-budget packing reported success"
    fi
  done
  pass "serial packing accepts the exact budget and refuses one millisecond above it"
}

test_portable_serial_shard_lane_refusals() {
  local tmp count rc other
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-shard-lane.XXXXXX")
  count=$("$RUNNER" --list-lanes | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  other=$((count + 1))

  # A lane built for a different shard count must refuse rather than run a
  # partial suite: this is what keeps a CI matrix from silently dropping tests.
  set +e
  "$RUNNER" --list --lane "portable-serial-1of${other}" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "mismatched shard count must refuse (exit 2), got $rc"
  [ ! -s "$tmp/out" ] || fail "mismatched shard count must not list tests"
  grep -Fq "configured for $count" "$tmp/err" \
    || fail "mismatch refusal must name the configured count: $(cat "$tmp/err")"

  set +e
  "$RUNNER" --list --lane "portable-serial-$((count + 1))of${count}" >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "out-of-range shard index must refuse (exit 2), got $rc"
  grep -Fq "outside 1..$count" "$tmp/err2" \
    || fail "range refusal message missing: $(cat "$tmp/err2")"

  set +e
  "$RUNNER" --list --lane portable-serial-1 >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "shard lane without a count must refuse (exit 2), got $rc"
  rm -rf "$tmp"
  pass "portable serial shard lanes refuse mismatched, out-of-range, and countless names"
}

test_jobs_requires_proven_isolated() {
  local tmp rc shard_lane
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs.XXXXXX")
  set +e
  "$RUNNER" --jobs 2 --lane portable-serial >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with portable-serial must refuse (exit 2), got $rc"
  grep -Fq 'portable serial lanes stay serial' "$tmp/err" \
    || fail "--jobs refusal message missing: $(cat "$tmp/err")"
  set +e
  "$RUNNER" --jobs 2 tests/fm-afk-inject-e2e.test.sh >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs on a family with no recorded proof must refuse, got $rc"
  # Sharding across runners never relaxes the serial rule inside one shard.
  shard_lane=$("$RUNNER" --list-lanes | grep -m1 '^portable-serial-[0-9]*of[0-9]*$')
  set +e
  "$RUNNER" --jobs 2 --lane "$shard_lane" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with a portable serial shard must refuse, got $rc"
  grep -Fq 'portable serial lanes stay serial' "$tmp/err3" \
    || fail "shard --jobs refusal message missing: $(cat "$tmp/err3")"
  rm -rf "$tmp"
  pass "--jobs refuses non-proven / stateful selections"
}

# The complement of the refusal above: a family carrying a recorded concurrent
# proof is admitted and actually scheduled, so the admission rule is two-sided
# rather than a blanket refusal that happens to pass its negative cases.
test_jobs_admits_a_concurrent_safe_family() {
  local tmp rc external
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-admit.XXXXXX")
  # --list exits before the admission guard, so this has to be a real run for
  # the assertion to mean anything. Two cheap watcher-wake-lock scripts exercise
  # admission and the concurrent scheduler for real.
  set +e
  "$RUNNER" --jobs 2 \
    tests/fm-supervision-events.test.sh tests/fm-session-lock-ancestry.test.sh \
    >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "--jobs on a proven family must be admitted, got $rc: $(cat "$tmp/err") $(cat "$tmp/out")"
  grep -Fq 'FM_TEST_SUMMARY total=2 failed=0' "$tmp/out" \
    || fail "the admitted concurrent run did not report both scripts green: $(cat "$tmp/out")"

  set +e
  "$RUNNER" --jobs 5 tests/fm-session-lock-ancestry.test.sh \
    >"$tmp/over-cap.out" 2>"$tmp/over-cap.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a family run above its proven four-worker cap must be refused, got $rc"

  external="$tmp/fm-session-lock-ancestry.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - colliding external fixture"\n' >"$external"
  chmod +x "$external"
  set +e
  "$RUNNER" --jobs 2 "$external" >"$tmp/external.out" 2>"$tmp/external.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || fail "an external script colliding with a proven family member must be refused, got $rc"
  rm -rf "$tmp"
  pass "--jobs admits and schedules a family with a recorded concurrent proof"
}

# The residual `standalone` family carries a concurrent proof, but the `*)`
# catch-all it was split out of must not: a test nobody has classified yet is
# exactly the one with no proof, so it has to stay serial rather than inherit
# concurrency from the family map's default arm.
test_unmapped_new_test_never_inherits_family_concurrency() {
  local tmp repo rc script
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-unmapped.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$ROOT/bin/fm-test-scratch-lib.sh" "$repo/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  chmod +x "$repo/bin/fm-test-run.sh"
  # Two members of the proven residual family, plus a test basename the family
  # map has never seen - the shape of any test added tomorrow.
  for script in fm-procevent.test.sh fm-quota-choose.test.sh fm-zz-unmapped-fixture.test.sh; do
    printf '#!/usr/bin/env bash\necho "ok - %s fixture"\n' "$script" >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done

  set +e
  (cd "$repo" && bin/fm-test-run.sh --jobs 2 \
    tests/fm-procevent.test.sh tests/fm-quota-choose.test.sh) \
    >"$tmp/family.out" 2>"$tmp/family.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "two members of the proven residual family must be admitted, got $rc: $(cat "$tmp/family.err")"
  grep -Fq 'FM_TEST_SUMMARY total=2 failed=0' "$tmp/family.out" \
    || fail "the admitted residual-family run did not report both scripts green: $(cat "$tmp/family.out")"

  set +e
  (cd "$repo" && bin/fm-test-run.sh --jobs 2 \
    tests/fm-procevent.test.sh tests/fm-zz-unmapped-fixture.test.sh) \
    >"$tmp/unmapped.out" 2>"$tmp/unmapped.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || fail "an unclassified new test must not be admitted under --jobs, got $rc: $(cat "$tmp/unmapped.out")"
  grep -Fq 'fm-zz-unmapped-fixture.test.sh' "$tmp/unmapped.err" \
    || fail "the refusal did not name the unclassified script: $(cat "$tmp/unmapped.err")"

  # It is only concurrency that is refused: the same script still runs serially.
  set +e
  (cd "$repo" && bin/fm-test-run.sh tests/fm-zz-unmapped-fixture.test.sh) \
    >"$tmp/serial.out" 2>"$tmp/serial.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "an unclassified test must still run serially, got $rc: $(cat "$tmp/serial.err")"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$tmp/serial.out" \
    || fail "the unmapped fixture did not land in the catch-all family: $(cat "$tmp/serial.out")"
  rm -rf "$tmp"
  pass "an unclassified new test stays serial while the proven residual family runs concurrently"
}

test_changed_shared_fixture_selects_its_readers() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fixture.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/shared-probe-fixture.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" \
    "shared test fixture selects its pr-forge reader"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" \
    "shared test fixture selects its secondmate reader"
  case "$listed" in
    *fm-backend-orca.test.sh*)
      fail "shared test fixture selection widened past its readers: $listed" ;;
  esac
  git -C "$repo" add tests/shared-probe-fixture.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture-change

  printf '\n' >>"$repo/tests/unread-thing.sh"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "an unread tests/ path must still fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: tests/unread-thing.sh' "$tmp/err" \
    || fail "the refusal did not name the unread tests/ path: $(cat "$tmp/err")"
  git -C "$repo" checkout -q -- tests/unread-thing.sh

  # A nested tests/fixtures/<dir>/<name>-fixture.sh still reaches the
  # directory-scan arm rather than the top-level fixture arm's basename scan.
  printf '\n' >>"$repo/tests/fixtures/demo/demo-fixture.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-orca.test.sh" \
    "a nested fixture selects the suite that reads its directory"

  rm -rf "$tmp"
  pass "a changed shared test fixture selects its readers while an unread tests/ path still refuses"
}

test_changed_copy_helper_selects_only_its_readers() {
  local tmp repo listed expected name
  tmp=$(fm_test_tmproot fm-run-copy-selection)
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  for name in e2e backends-e2e migration-e2e naming-e2e recovery-e2e; do
    printf '%s\n' '. tests/remote-secondmate-lifecycle-fixture.sh' >"$repo/tests/fm-remote-secondmate-lifecycle-$name.test.sh"
  done
  printf '%s\n' '. tests/remote-secondmate-source-copy-helpers.sh' >"$repo/tests/fm-test-run.test.sh"
  printf '%s\n' '. tests/remote-secondmate-source-copy-helpers.sh' >"$repo/tests/remote-secondmate-lifecycle-fixture.sh"
  touch "$repo/tests/remote-secondmate-source-copy-helpers.sh" "$repo/tests/fm-ask-user-authority.test.sh"
  git -C "$repo" add tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm copy-helper-fixture
  printf '# changed\n' >>"$repo/tests/remote-secondmate-source-copy-helpers.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) || fail 'could not list copy-helper readers'
  listed=$(printf '%s\n' "$listed" | LC_ALL=C sort)
  expected=$(printf '%s\n' tests/fm-remote-secondmate-lifecycle-{backends-e2e,e2e,migration-e2e,naming-e2e,recovery-e2e}.test.sh tests/fm-test-run.test.sh)
  assert_equals "$expected" "$listed" 'copy-helper edits select direct and indirect readers without family widening'
  pass 'changed copy helper selects only its direct and indirect readers'
}

# Suites outside backend-dispatch source the T3 fake and the T3 adapter, so a
# change to either selects the suites that read them as well.
test_changed_t3_sources_select_their_readers() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-t3.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  mkdir -p "$repo/bin/backends"
  : >"$repo/bin/backends/t3code.sh"
  : >"$repo/tests/t3-fake-lib.sh"
  printf '#!/usr/bin/env bash\n# tests/lib.sh\n. tests/t3-fake-lib.sh\n' >"$repo/tests/fm-secondmate-restart.test.sh"
  chmod +x "$repo/tests/fm-secondmate-restart.test.sh"
  printf '# bin/backends/t3code.sh\n' >>"$repo/bin/fm-supervisor-target-lib.sh"
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm t3

  printf '\n' >>"$repo/tests/t3-fake-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-secondmate-restart.test.sh" \
    "a changed T3 fake selects the suite that sources it"
  git -C "$repo" checkout -q -- tests/t3-fake-lib.sh

  printf '\n' >>"$repo/bin/backends/t3code.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend.test.sh" \
    "a changed T3 adapter still selects backend-dispatch"
  assert_contains "$listed" "tests/fm-daemon.test.sh" \
    "a changed T3 adapter selects the curated family of a script that consumes it"

  rm -rf "$tmp"
  pass "a changed T3 fake or adapter selects the suites that read it beyond backend-dispatch"
}

# Workers are handed scripts in order, so the slowest script must start first or
# it runs alone at the tail and throws away most of the concurrency.
test_concurrent_runs_are_ordered_longest_first() {
  local tmp listed first
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-order.XXXXXX")
  set +e
  "$RUNNER" --jobs 2 --family watcher-wake-lock --list >"$tmp/serial" 2>&1
  set -e
  # The scheduler reorders the real run, so assert on the begin-marker order of
  # a real concurrent run over scripts whose hints differ by a wide margin.
  set +e
  "$RUNNER" --jobs 2 \
    tests/fm-session-lock-ancestry.test.sh tests/fm-task-inbox.test.sh \
    >"$tmp/out" 2>"$tmp/err"
  set -e
  first=$(grep -m1 '^FM_TEST_BEGIN' "$tmp/out" | awk '{print $3}')
  [ "$first" = tests/fm-task-inbox.test.sh ] \
    || fail "concurrent run did not start the longest script first, started: $first"
  rm -rf "$tmp"
  pass "a concurrent run starts the longest-hint script first"
}

# --max-wall-ms is checked after the run, so it cannot end a run that never
# finishes. A hung script has to become a bounded failure, because an unbounded
# suite is exactly what silently outruns its caller's invocation budget.
test_per_script_timeout_bounds_a_hang() {
  local tmp repo runner hang rc began ended grandchild_pid grandchild states run_root
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-hang.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  hang=tests/fm-hang-fixture.test.sh
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-test-scratch-lib.sh" "$repo/bin/"
  grandchild_pid="$tmp/grandchild.pid"
  cat >"$repo/$hang" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture is about to hang"
run_root=$TMPDIR
while [ ! -f "$run_root/.fm-test-run-owner" ]; do
  [ -n "$run_root" ] || exit 1
  run_root=${run_root%/*}
done
printf '%s\n' "$run_root" >"$GRANDCHILD_PID.run-root"
sh -c 'trap "" TERM; echo $$ >"$1"; exec sleep 600' _ "$GRANDCHILD_PID" &
sleep 600
SH
  chmod +x "$runner" "$repo/$hang"

  began=$(date +%s)
  set +e
  GRANDCHILD_PID="$grandchild_pid" \
    "$runner" --per-script-timeout-secs 3 "$hang" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  ended=$(date +%s)

  [ "$rc" -ne 0 ] || fail "a terminated script must fail the run: $(cat "$tmp/out")"
  [ "$((ended - began))" -lt 120 ] \
    || fail "the per-script bound did not stop a 600s hang (took $((ended - began))s)"
  grep -Fq 'exceeded the per-script bound' "$tmp/out" \
    || fail "the terminated script was not named: $(cat "$tmp/out")"
  grep -Eq 'FM_TEST_END .* exit=124 ' "$tmp/out" \
    || fail "a terminated script must be recorded as exit 124: $(cat "$tmp/out")"
  # The run still completes and accounts for the script, rather than dying.
  grep -Fq 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out" \
    || fail "the bounded run did not report a complete summary: $(cat "$tmp/out")"
  [ -s "$grandchild_pid.run-root" ] || fail 'timed test did not find its run owner marker'
  run_root=$(<"$grandchild_pid.run-root")
  [ -s "$grandchild_pid" ] || fail "the hanging fixture did not record its grandchild"
  grandchild=$(<"$grandchild_pid")
  case "$(uname -s)" in
    MINGW*|MSYS*) printf '%s\n' 'skip: timeout process-state assertion needs POSIX ps fields' ;;
    *)
      states=$(ps -e -o pid= -o stat=) || fail 'cannot observe timeout process states'
      if ! awk -v self="$$" -v pid="$grandchild" '
        $1 == self && NF == 2 { readable = 1 }
        $1 == pid && $2 !~ /^Z/ { live = 1 }
        END { exit (!readable || live) }
      ' <<<"$states"; then
        kill -KILL "$grandchild" 2>/dev/null || true
        fail "cannot confirm that timeout drained grandchild $grandchild"
      fi
      ;;
  esac
  [ ! -e "$run_root" ] || fail "timeout left its run root: $run_root"

  # 0 keeps the historical unbounded behavior, so no existing caller changes.
  set +e
  "$runner" --per-script-timeout-secs nope "$hang" >"$tmp/o2" 2>"$tmp/e2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--per-script-timeout-secs with a non-number must be refused, got $rc"

  rm -rf "$tmp"
  pass "--per-script-timeout-secs turns a hung script into a bounded failure"
}

# The duration regression this guard exists for: a suite whose scripts are all
# green but whose wall clock outgrew its caller's invocation budget. The caller
# gets killed mid-run and retries invisibly, so an over-budget run has to be a
# failure, not a note in the log.
# tests/fm-watch-triage.test.sh is the slowest watcher-wake-lock member at about
# 593s under CI load (pause and wedge-defer siblings are 467s and 527s), so the
# automatic --changed bound must leave a slow but healthy watcher-wake-lock
# script room while still bounding a genuinely hung one
# (upstream issue #3869).
test_changed_bound_gives_slow_watcher_suites_headroom() {
  local tmp repo script rc
  tmp=$(mktemp -d)
  repo="$tmp/repo"
  script=tests/fm-watch-triage.test.sh
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$ROOT/bin/fm-test-scratch-lib.sh" "$repo/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cat >"$repo/bin/fm-timeout-lib.sh" <<'SH'
fm_run_timed() {
  [ "$1" -ge 1500 ] || return 124
  [ "${SIMULATE_TIMEOUT:-0}" -eq 0 ] || return 124
  shift
  "$@"
}
SH
  cat >"$repo/$script" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-test-run.sh" "$repo/$script"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
  printf '\n' >>"$repo/$script"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD) </dev/null >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "healthy changed watcher script must pass, got $rc: $(cat "$tmp/out" "$tmp/err")"
  set +e
  (cd "$repo" && SIMULATE_TIMEOUT=1 bin/fm-test-run.sh --changed --base HEAD) </dev/null >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] && grep -Eq 'FM_TEST_END .* exit=124 ' "$tmp/out" \
    || fail "changed watcher must run through the timeout helper: $(cat "$tmp/out" "$tmp/err")"
  rm -rf "$tmp"
  pass "the automatic --changed timeout helper receives at least 1500 seconds"
}

test_parallel_timeout_during_slow_replay() {
  local tmp repo first second rc
  tmp=$(fm_test_tmproot fm-replay)
  repo="$tmp/repo"
  first=tests/fm-supervision-events.test.sh
  second=tests/fm-session-lock-ancestry.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$tmp/path"
  cp "$RUNNER" "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-test-scratch-lib.sh" "$repo/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cat >"$repo/$first" <<'SH'
for ((i=0; i<100; i++)); do
  if [ -f "$REPLAY_PROOF/started" ]; then echo replay-overlap; exit 0; fi
  sleep 0.02
done
exit 1
SH
  cat >"$repo/$second" <<'SH'
touch "$REPLAY_PROOF/started"
sleep 5
touch "$REPLAY_PROOF/escaped"
SH
  cat >"$tmp/path/cat" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [[ "$1" == */output ]] && grep -qx replay-overlap "$1"; then
  touch "$REPLAY_PROOF/replaying"
  sleep 6
fi
exec "$REAL_CAT" "$@"
SH
  chmod +x "$tmp/path/cat"
  rc=0
  PATH="$tmp/path:$PATH" REPLAY_PROOF="$tmp" REAL_CAT="$(command -v cat)" \
    "$repo/bin/fm-test-run.sh" --jobs 2 --per-script-timeout-secs 3 "$first" "$second" \
    </dev/null >"$tmp/out" 2>"$tmp/err" || rc=$?
  [ "$rc" -eq 1 ] && [ -f "$tmp/replaying" ] && [ ! -e "$tmp/escaped" ] \
    && grep -F " $second exit=124 " "$tmp/out" >/dev/null \
    || fail "a worker deadline must hold during another worker's replay: $(cat "$tmp/out" "$tmp/err")"
  pass 'parallel timeout holds during another worker’s slow output replay'
}

test_max_wall_ms_is_a_result_not_advice() {
  local tmp repo runner fast rc summary_duration budget_duration
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-budget.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  fast=tests/fm-budget-fixture.test.sh
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$ROOT/bin/fm-test-scratch-lib.sh" "$repo/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cat >"$repo/$fast" <<'SH'
#!/usr/bin/env bash
sleep 1
echo "ok - budget fixture"
SH
  chmod +x "$runner" "$repo/$fast"

  # Comfortably inside budget: the run passes and states the budget it met.
  set +e
  "$runner" --max-wall-ms 60000 "$fast" >"$tmp/under" 2>"$tmp/under.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a run inside its budget must pass, got $rc: $(cat "$tmp/under.err")"
  grep -Eq '^FM_TEST_BUDGET max_wall_ms=60000 duration_ms=[0-9]+$' "$tmp/under" \
    || fail "an inside-budget run did not report the budget: $(cat "$tmp/under")"

  # Same green script, budget it cannot meet: the run must FAIL.
  set +e
  "$runner" --max-wall-ms 500 "$fast" >"$tmp/over" 2>"$tmp/over.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "an over-budget run must fail through the result path, got $rc"
  grep -Eq '^FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=[0-9]+$' "$tmp/over" \
    || fail "an over-budget run omitted its summary: $(cat "$tmp/over")"
  grep -Eq '^FM_TEST_SUMMARY_FAMILY .+$' "$tmp/over" \
    || fail "an over-budget run omitted its family summary: $(cat "$tmp/over")"
  grep -Eq '^FM_TEST_SLOWEST rank=1 .+$' "$tmp/over" \
    || fail "an over-budget run omitted its slowest result: $(cat "$tmp/over")"
  grep -Eq '^FM_TEST_BUDGET max_wall_ms=500 duration_ms=[0-9]+$' "$tmp/over" \
    || fail "an over-budget run omitted its budget result: $(cat "$tmp/over")"
  summary_duration=$(awk '/^FM_TEST_SUMMARY / { for (i=1;i<=NF;i++) if ($i ~ /^duration_ms=/) { sub(/^duration_ms=/, "", $i); print $i } }' "$tmp/over")
  budget_duration=$(awk '/^FM_TEST_BUDGET / { for (i=1;i<=NF;i++) if ($i ~ /^duration_ms=/) { sub(/^duration_ms=/, "", $i); print $i } }' "$tmp/over")
  [ "$budget_duration" = "$summary_duration" ] \
    || fail "budget verdict used a different duration than the summary: $(cat "$tmp/over")"

  # A malformed budget is refused rather than silently ignored.
  set +e
  "$runner" --max-wall-ms 0 "$fast" >"$tmp/bad" 2>"$tmp/bad.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--max-wall-ms 0 must be refused (exit 2), got $rc"
  set +e
  "$runner" --max-wall-ms nope "$fast" >"$tmp/bad2" 2>"$tmp/bad2.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--max-wall-ms with a non-number must be refused (exit 2), got $rc"

  rm -rf "$tmp"
  pass "--max-wall-ms fails an over-budget run and refuses a malformed budget"
}

test_jobs_parallel_scheduler_and_failure_propagation() {
  local tmp repo runner evidence fake_bin a b c d rc begin_n end_n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-sched.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  fake_bin="$tmp/fake-bin"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  c=tests/fm-lint.test.sh
  d=tests/fm-supervision-instructions.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fake_bin"
  cp "$RUNNER" "$ROOT/bin/fm-test-scratch-lib.sh" "$repo/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cat >"$fake_bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
  printf '700\n'
  exit 0
fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
  printf '  File: "%s"\n    ID: fake Namelen: 255 Type: ext2/ext3\n700\n' "$3"
  exit 0
fi
exit 1
SH
  # The slow fixture blocks on the replacement fixture's own signal rather than
  # a wall-clock sleep, so a loaded machine cannot let it finish first and turn
  # a correct scheduler into a failure. The bounded deadline is only there so a
  # scheduler that really does wait for the oldest worker still reports instead
  # of hanging.
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
if [ -n "${SCHED_WAIT_FOR_REPLACEMENT:-}" ]; then
  waited=0
  while [ ! -e "$SCHED_EVIDENCE/replacement-started" ] && [ "$waited" -lt 600 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
fi
touch "$SCHED_EVIDENCE/slow-done"
echo "ok - slow fixture"
SH
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "ok - fast fixture"
SH
  cat >"$repo/$c" <<'SH'
#!/usr/bin/env bash
# Read the evidence before releasing the slow fixture, so the release can never
# race ahead of the check it is being used to make.
if [ -e "$SCHED_EVIDENCE/slow-done" ]; then
  touch "$SCHED_EVIDENCE/replacement-started"
  echo "not ok - scheduler waited for oldest worker"
  exit 1
fi
touch "$SCHED_EVIDENCE/replacement-started"
echo "ok - replacement fixture started before slow fixture finished"
SH
  chmod +x "$runner" "$repo/$a" "$repo/$b" "$repo/$c" "$fake_bin/stat"
  set +e
  PATH="$fake_bin:$PATH" SCHED_EVIDENCE="$evidence" SCHED_WAIT_FOR_REPLACEMENT=1 \
    "$runner" --jobs 2 --json "$tmp/timing.json" \
    "$a" "$b" "$c" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "jobs=2 must refill the first completed slot"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$tmp/out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$tmp/out" || true)
  [ "$begin_n" -eq 3 ] || fail "expected 3 BEGIN markers, got $begin_n"
  [ "$end_n" -eq 3 ] || fail "expected 3 END markers, got $end_n"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0' "$tmp/out" \
    || fail "summary missing for jobs run: $(grep FM_TEST_SUMMARY "$tmp/out")"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==0
assert "jobs=2" in doc["selection"]
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "jobs JSON artifact wrong"; }

  # Non-proven path is refused before any worker starts (no race masking).
  cat >"$tmp/fail.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate fail"
exit 1
SH
  chmod +x "$tmp/fail.test.sh"
  set +e
  "$runner" --jobs 2 "$a" "$tmp/fail.test.sh" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "jobs with non-proven fail fixture must refuse before run, got $rc"

  # Parallel failure propagation stays inside the private runner fixture.
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate proven-set fail"
exit 1
SH
  chmod +x "$repo/$b"
  set +e
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$a" "$b" >"$tmp/out4" 2>"$tmp/err4"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "jobs aggregate must be non-zero when a proven worker fails"; }
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out4" \
    || { rm -rf "$tmp"; fail "jobs failure summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out4")"; }

  cat >"$repo/$d" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found" >&2
exit 0
SH
  chmod +x "$repo/$d"
  set +e
  "$runner" --jobs 2 --fail-on-gate-skip 'herdr not found' "$d" >"$tmp/out5" 2>"$tmp/err5"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "parallel stderr gate skip must hard-fail"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out5" \
    || { rm -rf "$tmp"; fail "parallel stderr hard-fail summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out5")"; }

  "$runner" --jobs 2 "$d" >"$tmp/out6" 2>"$tmp/err6" \
    || { rm -rf "$tmp"; fail "ordinary parallel stderr gate skip must remain successful"; }
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr gate skip was not recorded"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr skip summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out6")"; }

  rm -rf "$tmp"
  pass "jobs scheduler runs proven scripts; failure propagates; non-proven refused"
}

test_herdr_ci_family_run_has_a_step_timeout() {
  # The required Herdr lane's hang tripwire is the family-run *step* bound, not
  # the 75-minute job cap. Parse the workflow as YAML so nested `with.name`
  # artifact keys cannot masquerade as the step contract.
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .github/workflows/ci.yml as YAML"
  local json job_timeout step_timeout
  json=$(ruby -ryaml -rjson -e '
doc = YAML.load_file(ARGV[0])
job = doc.fetch("jobs").fetch("tests-herdr")
step = job.fetch("steps").find { |s|
  s.is_a?(Hash) && s["name"] == "Run real-Herdr family (serial, required)"
}
raise "missing family-run step" if step.nil?
raise "family-run step has no timeout-minutes" unless step.key?("timeout-minutes")
puts JSON.generate(
  "job_timeout" => job.fetch("timeout-minutes"),
  "step_timeout" => step.fetch("timeout-minutes")
)
' "$ROOT/.github/workflows/ci.yml") \
    || fail "could not parse tests-herdr timeouts from ci.yml"
  job_timeout=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_timeout"])' <<<"$json") \
    || fail "could not read job timeout from parsed workflow"
  step_timeout=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["step_timeout"])' <<<"$json") \
    || fail "could not read step timeout from parsed workflow"
  [ "$job_timeout" = 75 ] \
    || fail "tests-herdr job backstop must stay 75 minutes, got $job_timeout"
  [ "$step_timeout" = 20 ] \
    || fail "family-run step timeout must be 20 minutes, got $step_timeout"
  [ "$step_timeout" -lt "$job_timeout" ] \
    || fail "family-run step timeout must be below the job backstop"
  pass "Herdr CI family-run step times out at 20 min under a 75 min job backstop"
}

test_aggregate_json() {
  local tmp a b
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggjson.XXXXXX")
  cat >"$tmp/a.json" <<'JSON'
{
  "run_id": "a",
  "selection": "lane=portable-parallel-1",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:01:00Z",
  "summary": {"total": 1, "failed": 0, "skipped_gate": 0, "duration_ms": 1000},
  "scripts": [{"path": "tests/a.test.sh", "family": "pure-contract-unit", "duration_ms": 1000, "exit": 0, "gate_skip": false}]
}
JSON
  cat >"$tmp/b.json" <<'JSON'
{
  "run_id": "b",
  "selection": "lane=portable-serial",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:02:00Z",
  "summary": {"total": 2, "failed": 1, "skipped_gate": 0, "duration_ms": 2000},
  "scripts": [
    {"path": "tests/b.test.sh", "family": "afk", "duration_ms": 1500, "exit": 1, "gate_skip": false},
    {"path": "tests/c.test.sh", "family": "afk", "duration_ms": 500, "exit": 0, "gate_skip": false}
  ]
}
JSON
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json")
  assert_contains "$out" "FM_TEST_AGGREGATE lanes=2 total=3 failed=1" "aggregate summary line"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["kind"]=="aggregate"
assert doc["summary"]["lanes"]==2
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==1
assert doc["summary"]["critical_path_duration_ms"]==2000
assert len(doc["scripts"])==3
' "$tmp/out.json" || { rm -rf "$tmp"; fail "aggregate JSON shape wrong"; }
  rm -rf "$tmp"
  pass "aggregate-json merges lane timing artifacts"
}

test_gateway_preflight_preserves_symlink() {
  local tmp profile executable rc=0
  tmp=$(fm_test_tmproot fm-gateway-refusal)
  profile="$tmp/hermes/profiles/worker"
  mkdir -p "$profile" "$tmp/path"
  printf '%s\n' 'original config' >"$profile/original.yaml"
  if ! ln -s original.yaml "$profile/config.yaml" 2>/dev/null || [ ! -L "$profile/config.yaml" ]; then
    printf '%s\n' 'skip: gateway refusal check requires symlinks'
    return 0
  fi
  printf '%s\n' 'configured' >"$profile/.env"
  for executable in hermes tmux jq; do
    printf '#!/usr/bin/env bash\nexit 99\n' >"$tmp/path/$executable"
    chmod +x "$tmp/path/$executable"
  done
  PATH="$tmp/path:$PATH" FM_HERMES_GATEWAY_LIVE=1 FM_HERMES_LIVE_HOME="$tmp/hermes" FM_HERMES_LIVE_PROFILE=worker \
    bash "$ROOT/tests/fm-hermes-gateway-coexistence-live-e2e.test.sh" >"$tmp/out" 2>&1 || rc=$?
  [ "$rc" -eq 1 ] && grep -q 'may configure a messaging platform' "$tmp/out" || fail "gateway did not refuse .env: $(<"$tmp/out")"
  [ -L "$profile/config.yaml" ] && [ "$(<"$profile/config.yaml")" = 'original config' ] \
    || fail 'gateway refusal changed the untouched config'
  rm -f "$profile/.env"
  python3 - "$profile/state.db" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.executescript('create table sessions(id); create table messages(id, session_id);')
PY
  cat >"$tmp/path/hermes" <<'SH'
#!/usr/bin/env bash
touch "$HERMES_HOME/hermes-called"
case "$3 $4 $5" in
  'config get platforms') echo null ;;
  'config set gateway.standalone')
    printf 'mutated\n' >"$HERMES_HOME/profiles/$2/config.yaml"
    touch "$HERMES_HOME/mutation-attempted"
    ;;
  *) exit 99 ;;
esac
SH
  printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/path/jq"
  rc=0
  PATH="$tmp/path:$PATH" FM_HERMES_GATEWAY_LIVE=1 FM_HERMES_LIVE_HOME="$tmp/hermes" FM_HERMES_LIVE_PROFILE=worker \
    bash "$ROOT/tests/fm-hermes-gateway-coexistence-live-e2e.test.sh" >"$tmp/out" 2>&1 || rc=$?
  [ "$rc" -eq 1 ] && grep -q 'gateway launch failed' "$tmp/out" && [ -f "$tmp/hermes/mutation-attempted" ] \
    || fail "gateway did not exercise mutation and rollback: $(<"$tmp/out")"
  [ -L "$profile/config.yaml" ] && [ "$(readlink "$profile/config.yaml")" = original.yaml ] \
    && [ "$(<"$profile/original.yaml")" = 'original config' ] || fail 'gateway rollback changed the config link or target'
  rm -f "$profile/config.yaml" "$tmp/hermes/hermes-called"
  printf 'operator config\n\n' >"$tmp/operator.yaml"
  cp "$tmp/operator.yaml" "$tmp/expected.yaml"
  ln -s "$tmp/operator.yaml" "$profile/config.yaml"
  rc=0
  PATH="$tmp/path:$PATH" FM_HERMES_GATEWAY_LIVE=1 FM_HERMES_LIVE_HOME="$tmp/hermes" FM_HERMES_LIVE_PROFILE=worker \
    bash "$ROOT/tests/fm-hermes-gateway-coexistence-live-e2e.test.sh" >"$tmp/out" 2>&1 || rc=$?
  [ "$rc" -eq 1 ] && grep -q 'config resolves outside the throwaway profile' "$tmp/out" \
    && [ ! -e "$tmp/hermes/hermes-called" ] && cmp -s "$tmp/expected.yaml" "$tmp/operator.yaml" \
    || fail "gateway crossed the profile boundary: $(<"$tmp/out")"
  pass 'gateway preserves in-profile config links and refuses escaped targets'
}

test_readonly_probe_scratch_cleanup() {
  local tmp probe hooks target
  tmp=$(fm_test_tmproot fm-probe-cleanup)
  probe="$tmp/probe"
  hooks="$probe/h/state/task.git-hooks"
  target="$tmp/target"
  mkdir -p "$hooks" "$target"
  touch "$hooks/prepare-commit-msg" "$target/sentinel"
  chmod 0500 "$hooks" "$target"
  ln -s "$target" "$probe/alias" 2>/dev/null || printf '%s\n' 'skip: probe alias requires directory symlink support'
  ( . "$ROOT/bin/fm-test-scratch-lib.sh"; fm_test_remove_tree "$probe" ) || fail 'could not remove read-only probe scratch'
  [ ! -e "$probe" ] && [ -f "$target/sentinel" ] || fail 'probe cleanup left scratch or touched its symlink target'
  case "$(uname -s)" in
    MINGW*|MSYS*) ;;
    *) [ "$(id -u)" -eq 0 ] || [ ! -w "$target" ] || fail 'probe cleanup changed permissions on its symlink target' ;;
  esac
  pass 'probe cleanup removes read-only hooks without following symlinks'
}

test_scratch_placement_and_lifecycle() {
  local tmp
  tmp=$(fm_test_tmproot fm-run-scratch-contract)
  python3 - "$tmp" "$RUNNER" "$ROOT" "$BASH" <<'PY' || fail 'runner scratch contract'
import json, os, pathlib, shutil, signal, subprocess, sys, time

tmp, runner, root = map(pathlib.Path, sys.argv[1:4])
bash = sys.argv[4]

def convert_path(flag, path):
    if os.name == 'nt':
        return subprocess.check_output([bash, '-c', 'cygpath "$1" -- "$2"', '_', flag, str(path)],
                                       text=True).strip()
    return str(path)

def shell_path(path):
    return convert_path('-u', path)

def native_path(path):
    return pathlib.Path(convert_path('-m', path))

repo = tmp / 'repo'
(repo / 'bin').mkdir(parents=True)
(repo / 'tests').mkdir()
shutil.copy2(runner, repo / 'bin')
for name in ('fm-path-lib.sh', 'fm-wake-lib.sh', 'fm-timeout-lib.sh', 'fm-test-scratch-lib.sh'):
    shutil.copy2(root / 'bin' / name, repo / 'bin')
for name in ('git-config-helpers.sh', 'remote-secondmate-source-copy-helpers.sh'):
    shutil.copy2(root / 'tests' / name, repo / 'tests')
script = repo / 'tests/copy.test.sh'
script.write_bytes(b'''#!/usr/bin/env bash
set -eu
. tests/remote-secondmate-source-copy-helpers.sh
mktemp_dir=$(mktemp -d "$TMPDIR/copy.XXXXXX")
fm_fixture_copy_remote_source "$PWD" "$mktemp_dir"
[ "$(cat "$mktemp_dir/tracked")" = 'tracked working-tree bytes' ]
[ ! -e "$mktemp_dir/.test-phase-tmp" ]
[ ! -e "$mktemp_dir/replaced/sentinel" ]
mkdir "$TMPDIR/read-only"
touch "$TMPDIR/read-only/entry"
chmod 0500 "$TMPDIR/read-only"
if [ "$PROBE_MODE" = hang ] || [ "$PROBE_MODE" = stubborn ]; then
  printf '%s\\n' "$$" > "$PROOF.pid"
fi
if [ "$PROBE_MODE" = stubborn ] || [ "$PROBE_MODE" = leaderless ]; then
  sh -c 'marker=$1; note_term() { touch "$marker.term"; }; trap note_term TERM; printf "%s\\n" "$$" > "$1"; while :; do sleep 0.05; done' \
    _ "$PROOF.child" </dev/null >/dev/null 2>&1 &
  while [ ! -s "$PROOF.child" ]; do sleep 0.01; done
fi
run_root=$TMPDIR
while [ ! -f "$run_root/.fm-test-run-owner" ]; do
  [ -n "$run_root" ] || exit 1
  run_root=${run_root%/*}
done
printf '%s\\n%s\\n' "$TMPDIR" "$run_root" > "$PROOF"
if [ "$PROBE_MODE" = hang ] || [ "$PROBE_MODE" = stubborn ]; then exec sleep 300; fi
if [ "$PROBE_MODE" = retain ]; then
  . bin/fm-test-scratch-lib.sh
  fm_test_arm_private_tmux MARKER
fi
if [ "$PROBE_MODE" = evidence ]; then
  . bin/fm-test-scratch-lib.sh
  printf '%s\\n' 'captured output' >"$TMPDIR/screen.ansi"
  mkdir "$TMPDIR/wt"
  printf '%s\\n' '80235' >"$TMPDIR/wt/answer.txt"
  printf '%s\\n' 'acknowledged' >"$TMPDIR/wt/.steer"
  base=$(bash bin/fm-test-run.sh --scratch-base)
  fm_test_copy_hermes_evidence "$TMPDIR" "$base"
elif [ "$PROBE_MODE" = empty-evidence ]; then
  . bin/fm-test-scratch-lib.sh
  base=$(bash bin/fm-test-run.sh --scratch-base)
  mkdir "$TMPDIR/empty"
  fm_test_copy_hermes_evidence "$TMPDIR/empty" "$base"
fi
if [ "$PROBE_MODE" = stale ]; then
  printf '%s|%s|%s|%s\\n' "$UID" "$DECOY_GROUP" "$DECOY_GROUP" 'different start identity' >"${TMPDIR%/*}/timed-owner"
fi
[ "$PROBE_MODE" != fail ]
''')
(repo / 'tracked').write_bytes(b'staged index bytes\n')
subprocess.run(['git', 'init', '-q', str(repo)], check=True)
replaced = repo / 'replaced'
replaced.write_bytes(b'indexed file\n')
subprocess.run(['git', '-C', str(repo), 'add', 'tracked', 'replaced'], check=True)
replaced.unlink()
replaced.mkdir()
(replaced / 'sentinel').touch()
(repo / 'tracked').write_bytes(b'tracked working-tree bytes\n')
legacy = repo / '.test-phase-tmp'
legacy.mkdir()
(legacy / 'sentinel').touch()
(legacy / 'tracked-scratch').touch()
subprocess.run(['git', '-C', str(repo), 'add', '-f', '.test-phase-tmp/tracked-scratch'], check=True)
tracked_dir = repo / 'tracked-dir'
tracked_dir.mkdir()
(tracked_dir / 'file').write_bytes(b'tracked contents\n')
subprocess.run(['git', '-C', str(repo), 'add', 'tracked-dir/file'], check=True)
ancestor = tmp / 'scratch-ancestor'
ancestor.mkdir()
(ancestor / 'file').write_bytes(b'not tracked\n')
saved = tmp / 'tracked-dir-saved'
tracked_dir.rename(saved)
try:
    tracked_dir.symlink_to(ancestor, target_is_directory=True)
except (OSError, NotImplementedError):
    print('skip: tracked ancestor check requires directory symlink support')
else:
    dest = tmp / 'copy-result'
    dest.mkdir()
    result = subprocess.run([bash, '-c', '. tests/remote-secondmate-source-copy-helpers.sh; fm_fixture_copy_remote_source . "$1"',
                             '_', shell_path(dest)], cwd=repo, capture_output=True)
    assert result.returncode != 0 and b'symlinked ancestor' in result.stderr, result
    assert not (dest / 'tracked-dir/file').exists()
    tracked_dir.unlink()
saved.rename(tracked_dir)
base = tmp / 'dedicated'
base.mkdir()
fakebin = tmp / 'fakebin'
fakebin.mkdir()
getconf = fakebin / 'getconf'
getconf.write_bytes(b'''#!/usr/bin/env bash
[ "$1" = DARWIN_USER_TEMP_DIR ] && printf '%s\\n' "$OS_TEMP_FIXTURE"
''')
getconf.chmod(0o755)
alias = tmp / 'alias'
aliases = []
try:
    alias.symlink_to(legacy, target_is_directory=True)
except (OSError, NotImplementedError):
    print('skip: scratch alias check requires directory symlink support')
else:
    aliases.append(alias)
home = tmp / 'home'
for blocked in (home / '.firstmate-preserved', home / '.treehouse', tmp / 'fm-home', tmp / 'custom-treehouse'):
    blocked.mkdir(parents=True)
env = dict(os.environ, HOME=shell_path(home), FM_HOME=shell_path(tmp / 'fm-home'),
           TREEHOUSE_ROOT=shell_path(tmp / 'custom-treehouse'), TMPDIR=shell_path(legacy),
           TMP=shell_path(legacy), TEMP=shell_path(legacy), PROBE_MODE='pass')
env.pop('FM_TASK_ID', None)
fixture_env = dict(env, PATH=str(fakebin) + os.pathsep + env['PATH'], OS_TEMP_FIXTURE=shell_path(base))
runner_cmd = [bash, 'bin/fm-test-run.sh']
cmd = [*runner_cmd, script.relative_to(repo).as_posix()]
for blocked in (legacy, *aliases, home / '.firstmate-preserved', home / '.treehouse', tmp / 'fm-home', tmp / 'custom-treehouse'):
    for command in ([*runner_cmd, '--scratch-base'], cmd):
        result = subprocess.run(command, cwd=repo, env=dict(fixture_env, OS_TEMP_FIXTURE=shell_path(blocked)),
                                capture_output=True)
        assert result.returncode == 2 and b'unsafe scratch base' in result.stderr, result

result = subprocess.run([*runner_cmd, '--scratch-base'], cwd=repo, env=fixture_env, capture_output=True)
assert result.returncode == 0 and native_path(os.fsdecode(result.stdout).strip()).resolve() == base.resolve(), result
assert not list(base.iterdir()), 'scratch-base must not allocate'
for other_arg in ('--list-lanes', cmd[-1]):
    for args in ((other_arg, '--scratch-base'), ('--scratch-base', other_arg)):
        result = subprocess.run([*runner_cmd, *args], cwd=repo, env=fixture_env, capture_output=True)
        assert result.returncode == 2 and not result.stdout, result

def restore_signal_defaults():
    for sig in (signal.SIGINT, signal.SIGQUIT):
        signal.signal(sig, signal.SIG_DFL)

def launch(name, mode, use_fixture=True, bounded=False, options=(), siblings=(),
           stdin=subprocess.DEVNULL, start_new_session=False):
    proof = tmp / name
    case_env = dict(fixture_env if use_fixture else env, PROBE_MODE=mode, PROOF=shell_path(proof))
    log = (tmp / (name + '.log')).open('w')
    with log:
        # A Bash-launched background test may inherit SIGINT ignored. Deliver
        # a catchable signal, as for a directly invoked foreground runner.
        bound = ['--per-script-timeout-secs', '60'] if bounded else []
        command = [*runner_cmd, *bound, *options, cmd[-1], *siblings]
        child = subprocess.Popen(command, cwd=repo, env=case_env, stdin=stdin, stdout=log, stderr=log,
                                 start_new_session=start_new_session,
                                 preexec_fn=restore_signal_defaults if os.name == 'posix' else None)
    return child, proof

def scratch(proof):
    for _ in range(300):
        if proof.exists():
            evidence = proof.read_text()
            if evidence.endswith('\n') and len(evidence.splitlines()) == 2:
                worker_tmp, run_root = map(native_path, evidence.splitlines())
                assert repo.resolve() not in worker_tmp.resolve().parents, worker_tmp
                assert run_root.resolve() in (worker_tmp.resolve(), *worker_tmp.resolve().parents), run_root
                return worker_tmp, run_root
        time.sleep(0.05)
    raise AssertionError(f'missing proof: {proof}')

for mode, rc in [('pass', 0), ('fail', 1)]:
    child, proof = launch(mode, mode, use_fixture=(mode == 'fail'))
    assert child.wait(timeout=20) == rc, (tmp / (mode + '.log')).read_text()
    worker_tmp, run = scratch(proof)
    assert not run.exists(), run
    if mode == 'fail':
        assert base.resolve() in worker_tmp.resolve().parents
child, _ = launch('literal-report-name', 'pass', options=('--json', '--scratch-base'))
assert child.wait(timeout=20) == 0, (tmp / 'literal-report-name.log').read_text()
assert json.loads((repo / '--scratch-base').read_text())['summary']['failed'] == 0
(repo / '--scratch-base').unlink()
child, proof = launch('retain', 'retain', options=('--json', 'retained.json'))
assert child.wait(timeout=20) == 1
_, retained_run = scratch(proof)
assert retained_run.is_dir()
assert json.loads((repo / 'retained.json').read_text())['summary']['failed'] == 1
(repo / 'retained.json').unlink()
subprocess.run([bash, '-c', '. bin/fm-test-scratch-lib.sh; fm_test_remove_tree "$1"', '_', shell_path(retained_run)], cwd=repo, check=True)
assert sorted(p.name for p in legacy.iterdir()) == ['sentinel', 'tracked-scratch']
(private,) = base.iterdir()
assert not list(private.iterdir())
remover = fakebin / 'rm'
remover.write_text('''#!/usr/bin/env bash
case "${!#}" in */r.??????) exit 1 ;; esac
exec "$REAL_RM" "$@"
''')
remover.chmod(0o755)
try:
    result = subprocess.run([*runner_cmd, '--json', 'cleanup.json', cmd[-1]], cwd=repo,
                            env=dict(fixture_env, REAL_RM=shutil.which('rm'), PROOF=shell_path(tmp / 'cleanup')),
                            capture_output=True, timeout=20)
    assert result.returncode == 1 and b'could not remove scratch' in result.stderr, result
    assert json.loads((repo / 'cleanup.json').read_text())['summary']['failed'] == 1
finally:
    remover.unlink()
_, leftover = scratch(tmp / 'cleanup')
assert leftover.is_dir()
subprocess.run([bash, '-c', '. bin/fm-test-scratch-lib.sh; fm_test_remove_tree "$1"', '_', shell_path(leftover)], cwd=repo, check=True)
result = subprocess.run(cmd, cwd=repo, env=dict(fixture_env, FM_HOME=shell_path(private)), capture_output=True)
assert result.returncode == 2 and b'unsafe scratch base' in result.stderr, result

child, proof = launch('evidence-copy', 'evidence')
assert child.wait(timeout=20) == 0
_, run = scratch(proof)
label = 'Hermes guard evidence: '
line, = [line for line in (tmp / 'evidence-copy.log').read_text().splitlines() if line.startswith(label)]
evidence = native_path(line[len(label):])
assert evidence.parent.resolve() == base.resolve(), evidence
assert not run.exists() and (evidence / 'screen.ansi').read_text() == 'captured output\n'
assert (evidence / 'wt/answer.txt').read_text() == '80235\n'
assert (evidence / 'wt/.steer').read_text() == 'acknowledged\n'
child, proof = launch('empty-evidence-copy', 'empty-evidence')
assert child.wait(timeout=20) == 1
assert label not in (tmp / 'empty-evidence-copy.log').read_text()
assert set(base.iterdir()) == {private, evidence}

if os.name == 'posix':
    allocator = fakebin / 'mktemp'
    allocator.write_bytes(b'''#!/usr/bin/env bash
allocated=$("$REAL_MKTEMP" "$@") || exit 1
kill -TERM 0
printf '%s\\n' "$allocated"
''')
    allocator.chmod(0o755)
    try:
        interrupted = subprocess.run(cmd, cwd=repo, stdin=subprocess.DEVNULL, start_new_session=True,
                                     env=dict(fixture_env, REAL_MKTEMP=shutil.which('mktemp')),
                                     capture_output=True, timeout=10)
        assert interrupted.returncode == 143, interrupted
        assert not list(private.iterdir()), 'interruption stranded the allocated run directory'
    finally:
        allocator.unlink()

for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT) if os.name == 'posix' else ():
    child, proof = launch(sig.name, 'hang')
    try:
        _, run = scratch(proof)
        child.send_signal(sig)
        assert child.wait(timeout=10) == 128 + sig, sig
        assert not run.exists(), run
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=10)

if os.name != 'posix' or subprocess.run(
        [bash, '-c', '. bin/fm-wake-lib.sh && fm_pid_start_time "$$" && ps -e -o pid= -o pgid= -o stat='],
        cwd=repo, env=dict(fixture_env, FM_STATE_OVERRIDE=str(tmp)), capture_output=True).returncode:
    print('skip: orphan recovery requires process identity and group liveness support')
    sys.exit(0)

tar_probe = fakebin / 'tar'
tar_probe.write_bytes(b'''#!/usr/bin/env bash
if [ "$1" = -C ] && [ "$3" = -xf ] && [[ "$2" == */fm-hermes-evidence.* ]]; then
    touch "$2/partial"
    touch "$PROOF.extracting"
    exec sleep 60
fi
exec "$REAL_TAR" "$@"
''')
tar_probe.chmod(0o755)
fixture_env['REAL_TAR'] = shutil.which('tar')
try:
    child, proof = launch('interrupted-evidence', 'evidence')
    try:
        _, run = scratch(proof)
        for _ in range(200):
            if (tmp / 'interrupted-evidence.extracting').is_file():
                break
            assert child.poll() is None
            time.sleep(0.05)
        else:
            raise AssertionError('evidence extractor never wrote partial data')
        assert set(base.iterdir()) == {private, evidence}, 'partial evidence already published'
        child.terminate()
        assert child.wait(timeout=10) == 143
        assert not run.exists() and set(base.iterdir()) == {private, evidence}
        assert label not in (tmp / 'interrupted-evidence.log').read_text()
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=10)
finally:
    tar_probe.unlink()
    fixture_env.pop('REAL_TAR')

with subprocess.Popen(['sleep', '60'], start_new_session=True) as decoy:
    fixture_env['DECOY_GROUP'] = str(decoy.pid)
    try:
        child, proof = launch('reused-group', 'stale', bounded=True)
        assert child.wait(timeout=10) == 0, (tmp / 'reused-group.log').read_text()
        assert decoy.poll() is None, 'cleanup signaled a group with a different start identity'
        _, run = scratch(proof)
        assert not run.exists(), run
    finally:
        fixture_env.pop('DECOY_GROUP')
        if decoy.poll() is None:
            decoy.terminate()

def live_processes(*pids):
    states = subprocess.check_output(['ps', '-e', '-o', 'pid=', '-o', 'stat='], text=True)
    processes = dict(line.split() for line in states.splitlines() if line.strip())
    assert str(os.getpid()) in processes, 'incomplete process snapshot'
    return [pid for pid in pids if str(pid) in processes and not processes[str(pid)].startswith('Z')]

rm_probe = fakebin / 'rm'
rm_probe.write_bytes(b'''#!/usr/bin/env bash
if [ -n "${PROOF:-}" ] && [ -s "$PROOF.child" ] && [ "$#" -eq 3 ] && [ "$1" = -rf ] && [ "$2" = -- ]; then
    run_root=$(tail -1 "$PROOF")
    if [ "$3" = "$run_root" ]; then
        states=$(ps -e -o pid= -o stat=) || exit 1
        awk -v self="$$" -v pid="$(<"$PROOF.child")" '
          $1 == self { readable = 1 }
          $1 == pid && $2 !~ /^Z/ { live = 1 }
          END { exit (!readable || live) }
        ' <<<"$states" || touch "$PROOF.removed-live"
        touch "$PROOF.removing"
    fi
fi
exec "$REAL_RM" "$@"
''')
rm_probe.chmod(0o755)
fixture_env['REAL_RM'] = shutil.which('rm')

for name, bounded in (('unbounded-term', False), ('bounded-term', True)):
    child, proof = launch(name, 'stubborn', bounded=bounded)
    worker_group = None
    try:
        _, run = scratch(proof)
        worker = int((tmp / (name + '.pid')).read_text())
        stubborn = int((tmp / (name + '.child')).read_text())
        worker_group = os.getpgid(stubborn)
        assert worker_group == os.getpgid(worker)
        child.terminate()
        assert child.wait(timeout=10) == 143
        assert not live_processes(worker, stubborn), (worker, stubborn)
        worker_group = None
        assert (tmp / (name + '.removing')).exists()
        assert not (tmp / (name + '.removed-live')).exists()
        assert not run.exists(), run
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=10)
        if worker_group is not None:
            try:
                os.killpg(worker_group, signal.SIGKILL)
            except ProcessLookupError:
                pass

if any(shutil.which(tool) for tool in ('timeout', 'gtimeout')) and os.environ.get('FM_TIMEOUT_MECHANISM_OVERRIDE') != 'bash':
    import pty
    master, slave = pty.openpty()
    child = None
    payload_group = None
    try:
        child, proof = launch('foreground-int', 'stubborn', bounded=True, stdin=slave, start_new_session=True)
        _, run = scratch(proof)
        payload = int((tmp / 'foreground-int.child').read_text())
        payload_group = os.getpgid(payload)
        assert payload_group != child.pid, 'timeout did not isolate the foreground payload'
        os.killpg(child.pid, signal.SIGINT)
        assert child.wait(timeout=10) == 130, (tmp / 'foreground-int.log').read_text()
        assert not live_processes(payload)
        payload_group = None
        assert (tmp / 'foreground-int.removing').exists()
        assert not (tmp / 'foreground-int.removed-live').exists() and not run.exists()
    finally:
        os.close(slave)
        os.close(master)
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=10)
        if payload_group is not None:
            try:
                os.killpg(payload_group, signal.SIGKILL)
            except ProcessLookupError:
                pass

timeout_lib = repo / 'bin/fm-timeout-lib.sh'
real_timeout_lib = timeout_lib.read_bytes()
timeout_lib.write_bytes(b'''fm_run_timed() {
    shift
    set -m
    "$@" </dev/null &
    local leader=$!
    set +m
    wait "$leader" || return 1
    return 124
}
''')
try:
    sibling = 'tests/after.test.sh'
    (repo / sibling).write_bytes(b'touch "$PROOF.sibling-started"\n')
    for name, bounded, code in (('leaderless-exit', False, 1), ('leaderless-timeout', True, 124)):
        report = tmp / (name + '.json')
        child, proof = launch(name, 'leaderless', bounded=bounded,
                              options=('--json', shell_path(report), '--max-wall-ms', '60000'),
                              siblings=(sibling,) if not bounded else ())
        stubborn = None
        try:
            _, run = scratch(proof)
            stubborn = int((tmp / (name + '.child')).read_text())
            assert child.wait(timeout=10) == 1
            log = (tmp / (name + '.log')).read_text()
            assert f'exit={code} ' in log and f'retaining scratch: {run}' in log, log
            assert not (tmp / (name + '.sibling-started')).exists()
            if not bounded:
                assert f'not run (worker group exit unconfirmed): {sibling}' in log, log
            assert 'FM_TEST_SUMMARY total=1 failed=1 ' in log, log
            assert 'FM_TEST_BUDGET max_wall_ms=60000 ' in log, log
            artifact = json.loads(report.read_text())
            assert artifact['summary']['failed'] == 1
            assert [script['exit'] for script in artifact['scripts']] == [code], artifact
            assert live_processes(stubborn) == [stubborn]
            assert not (tmp / (name + '.child.term')).exists(), log
            assert not (tmp / (name + '.removing')).exists() and run.is_dir()
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=10)
            if stubborn is not None and live_processes(stubborn):
                os.kill(stubborn, signal.SIGKILL)
finally:
    timeout_lib.write_bytes(real_timeout_lib)

live, proof = launch('live', 'hang')
worker_group = None
try:
    worker_tmp, live_root = scratch(proof)
    worker = int((tmp / 'live.pid').read_text())
    worker_group = os.getpgid(worker)
    marker = live_root / '.fm-test-run-owner'
    old = time.time() - 600
    os.utime(marker, (old, old))
    unmarked = live_root.with_name(live_root.name[:-6] + 'Other1')
    unmarked.mkdir()
    other, _ = launch('reaper-live', 'pass')
    assert other.wait(timeout=20) == 0
    assert live_root.exists() and unmarked.exists()
    live.kill()
    assert live.wait(timeout=10) == -signal.SIGKILL
    other, _ = launch('reaper-orphan-worker', 'pass')
    assert other.wait(timeout=20) == 0
    assert worker_tmp.is_dir() and unmarked.exists()
    os.killpg(worker_group, signal.SIGKILL)
    for _ in range(100):
        states = subprocess.check_output(['ps', '-e', '-o', 'pgid=', '-o', 'stat='], text=True)
        if not any(pgid == str(worker_group) and not state.startswith('Z')
                   for pgid, state in map(str.split, states.splitlines())):
            break
        time.sleep(0.05)
    else:
        raise AssertionError('worker group survived SIGKILL')
    worker_group = None
    other, _ = launch('reaper-dead', 'pass')
    assert other.wait(timeout=20) == 0
    assert not live_root.exists() and unmarked.exists()
finally:
    if live.poll() is None:
        live.terminate()
        live.wait(timeout=10)
    if worker_group is not None:
        try:
            os.killpg(worker_group, signal.SIGKILL)
        except ProcessLookupError:
            pass
PY
  pass 'runner scratch stays out of snapshots and is cleaned after results, signals and owner death'
}

test_gateway_preflight_preserves_symlink
test_readonly_probe_scratch_cleanup
test_scratch_placement_and_lifecycle
test_list_all_exact_suite_coverage
test_family_selection
test_single_script_selection
test_changed_file_selection_is_conservative
test_task_marker_refuses_the_primary_checkout
test_changed_runner_surfaces_select_their_family
test_changed_scratch_helper_selects_teardown_coverage
test_shell_line_ending_policy_selects_runner_contract
test_changed_remote_inheritance_selects_generation_contract
test_changed_dependency_selection_and_unmapped_failure
test_changed_bin_reference_selects_per_script_not_per_family
test_changed_uses_bounded_automatic_concurrency
test_windows_posix_mode_emulation_does_not_fail_parallel_runs
test_script_list_uses_bounded_automatic_concurrency
test_family_proofs_run_in_separate_concurrent_phases
test_empty_selection_emits_summary
test_timing_markers_and_json
test_aggregate_exit_behavior
test_gate_skip_accounting
test_gate_skip_reason_is_recorded
test_a_run_that_ran_records_no_skip_reason
test_live_guards_expect_a_capability_skip_class
test_fail_on_gate_skip_token
test_exclude_family
test_tern_family_selection
test_list_scheduled_proven_isolated_uses_serial_weights
test_list_scheduled_non_lane_selections_use_serial_weights
test_portable_shard_union_and_coverage_guard
test_portable_parallel_lanes_stay_duration_balanced
test_portable_serial_shards_partition_the_serial_lane
test_portable_serial_packing_rejects_failed_output
test_portable_serial_hint_coverage_is_reported_and_bounded
test_portable_serial_packing_budget_boundary
test_portable_serial_shard_lane_refusals
test_jobs_requires_proven_isolated
test_jobs_admits_a_concurrent_safe_family
test_unmapped_new_test_never_inherits_family_concurrency
test_changed_shared_fixture_selects_its_readers
test_changed_copy_helper_selects_only_its_readers
test_changed_t3_sources_select_their_readers
test_concurrent_runs_are_ordered_longest_first
test_per_script_timeout_bounds_a_hang
test_changed_bound_gives_slow_watcher_suites_headroom
test_parallel_timeout_during_slow_replay
test_max_wall_ms_is_a_result_not_advice
test_jobs_parallel_scheduler_and_failure_propagation
test_herdr_ci_family_run_has_a_step_timeout
test_aggregate_json
