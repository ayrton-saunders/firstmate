#!/usr/bin/env bash
# fm-test-run.sh - single owner of Firstmate's behavior-test runner, lane
# composition for portable CI shards, local --jobs for proven-concurrent work,
# timing markers, and the complete-regression coverage guard.
#
# Selection modes (exactly one of: --all, --family, --changed, --lane,
# --proven-isolated, or script paths):
#   fm-test-run.sh --all
#   fm-test-run.sh --family <name>
#   fm-test-run.sh --changed [--base <git-ref>]
#   fm-test-run.sh --lane portable-parallel-1|portable-parallel-2|portable-serial
#   fm-test-run.sh --lane portable-serial-<k>of<n>   (one CI serial shard)
#   fm-test-run.sh --proven-isolated
#   fm-test-run.sh tests/<name>.test.sh [more scripts...]
#
# Inspection (no execution):
#   fm-test-run.sh --list --all
#   fm-test-run.sh --list --family <name>
#   fm-test-run.sh --list --lane portable-parallel-1
#   fm-test-run.sh --list-scheduled --family <name>
#   fm-test-run.sh --list-scheduled --lane portable-parallel-1
#   fm-test-run.sh --list-families
#   fm-test-run.sh --list-concurrent-safe-families
#   fm-test-run.sh --concurrent-safe-family-jobs-max <name>
#   fm-test-run.sh --list-lanes
#   fm-test-run.sh --check-coverage
#
# Aggregation (no suite execution):
#   fm-test-run.sh --aggregate-json <out.json> <lane.json> [more lane.json...]
#
# Options:
#   --json <path>   write a deterministic timing artifact after the run. Each
#                   script record carries its family, expected gate-skip class,
#                   exit, duration, whether it gate-skipped, and the reason it
#                   gave (empty when it ran), so a lane can say which harness or
#                   tool this host could not exercise.
#   --list          print selected script paths (one per line) and exit 0
#   --list-scheduled
#                   print selected paths longest-hint-first and exit 0.
#                   Only --lane portable-parallel-1 or portable-parallel-2 uses
#                   parallel hints, falling back to serial weights if missing.
#                   Every other selection uses serial weights alone.
#                   Equal weights are ordered by path under LC_ALL=C.
#   --base <ref>    with --changed, compare against this ref (default: origin/main)
#   --exclude-family <name>
#                   drop scripts whose primary family matches <name> after selection
#                   (repeatable; portable CI lanes exclude real-herdr-gated so the
#                   dedicated required Herdr lane owns that coverage)
#   --fail-on-gate-skip <token>
#                   after each script, fail the run if any output line contains
#                   "skip: <token>" (e.g. --fail-on-gate-skip 'herdr not found').
#                   The required Herdr CI lane uses this so a missing pin cannot
#                   silently pass as a gate skip.
#   --jobs N        run the selected scripts with up to N concurrent workers.
#                   Plain --changed and a plain list of script paths use
#                   min(4, cpus) workers when multiple selected scripts are
#                   admissible; --lane, --family, and --all stay serial unless
#                   asked for concurrency explicitly.
#                   N>1 is allowed only when every selected script is proven
#                   safe to run concurrently: individually in the proven-isolated
#                   set (bin/fm-test-isolation-proof.sh --list), or in a family
#                   carrying a recorded concurrent proof
#                   (list_concurrent_safe_families below). Overall cap is 8;
#                   family proofs may impose a lower cap. Individually proven
#                   scripts share one phase; scripts admitted only by a family
#                   proof run in a separate phase for each family. Concurrent
#                   phases use serial weights, longest-hint-first. Unproven stateful
#                   scripts run serially after all concurrent phases. Default is
#                   1 (serial) except for plain --changed and a plain list of
#                   script paths, which use the bounded automatic scheduler.
#   --per-script-timeout-secs N
#                   terminate a script that runs longer than N seconds and
#                   record it as exit 124 (0 disables, the default). The
#                   --changed applies 1500s automatically, above the current
#                   slowest CI hint with margin; exceeding it becomes a bounded
#                   failure, not proof of a hang. --max-wall-ms is checked
#                   after the run and so cannot catch a hang on its own.
#   --scratch-base  print the validated scratch base for direct probes; allocate nothing
#
# Scratch is independent of inherited TMPDIR and uses the OS per-user temp
# area on macOS and /tmp elsewhere. Neither base nor run root may resolve
# into the checkout, FM_HOME, preserved copies or a Treehouse pool. Using OS
# temp keeps reproducible scratch out of backups without changing Time Machine.
# Within the base, a private per-UID directory holds marked runs and wN/tmp
# directories. EXIT, INT, HUP and TERM drain owned worker groups before removing
# the run; a test that starts a separate session/group owns that group's cleanup.
# A subsequent run recovers aged, marked roots when the runner and workers are gone.
# Windows-style shells do not support orphan recovery; normal-exit and signal cleanup still apply.
# If cleanup cannot verify a live group's leader before signaling, it waits briefly without signaling and fails with scratch retained if the group remains.
# If interruption cuts short a nested runner's cleanup, its scratch is recovered on a later run once those workers are gone.
# PID-directed TERM/HUP waits for a foreground TTY test to finish or time out, or for blocked output replay to return; background worker waits are interruptible.
# Keep requested reports and redirected logs outside runner scratch.
#   --max-wall-ms N fail the run when its measured invocation wall clock exceeds
#                   N milliseconds, including an empty selection. It is
#                   evaluated after selection and suite execution and cannot
#                   interrupt a running script; per-script hangs are
#                   bounded by --per-script-timeout-secs. Pathological output
#                   sinks that block finalization are explicitly out of scope.
#   -h, --help      print this header
#
# Per-script machine-parseable markers (stdout):
#   FM_TEST_BEGIN <iso8601> <script> family=<family> expected_gate_skip=<class>
#   FM_TEST_END <iso8601> <script> exit=<code> duration_ms=<n> gate_skip=<true|false>
#
# After all scripts (stdout):
#   FM_TEST_SUMMARY total=<n> failed=<n> skipped_gate=<n> duration_ms=<n>
#   FM_TEST_SUMMARY_FAMILY family=<name> count=<n> duration_ms=<n> failed=<n>
#   FM_TEST_SLOWEST rank=<k> script=<path> duration_ms=<n>
#   FM_TEST_BUDGET max_wall_ms=<n> duration_ms=<n>   (only with --max-wall-ms)
#
# Placement refusal:
#   A task worker is assigned an isolated worktree, and that placement is
#   checked only when its task starts. When FM_TASK_ID marks such a worker and
#   this runner resolves to the repository's PRIMARY checkout, every executing
#   mode refuses before selecting a suite: the suite creates and switches
#   branches, and the primary is the checkout every linked worktree resolves
#   against. Inspection modes execute nothing and stay available, and a run with
#   no FM_TASK_ID set is unchanged.
#
# Exit status is non-zero if any selected script exits non-zero, a configured
# --fail-on-gate-skip token appears, the measured duration exceeds
# --max-wall-ms, timing-artifact finalization fails, or a concurrent worker
# violates its isolation check. Other gate skips (first meaningful line
# matching ^skip:) remain successful and are counted as skipped_gate; each one
# is logged with its reason and recorded in the timing artifact.
#
# expected_gate_skip classes name why a family is allowed to skip: herdr (the
# pinned real-Herdr lane), optional-binary (a backend whose binary is optional),
# live-capability (a live-harness guard governed by fm_live_gate, which records
# unavailable tools and explicit policy skips; see tests/lib.sh), or none.
#
# Every selected script runs isolated from the host's global and system Git
# configuration, including one that sources no test helper of its own;
# tests/git-config-helpers.sh owns that contract and its limits.
#
# Family labels, the changed-file map, and production portable-shard composition
# live in this script only (one owner). The proven-isolated candidate set remains
# owned by bin/fm-test-isolation-proof.sh; portable parallel shards are a
# duration-balanced partition of that exact set, packed from the measured hints
# in portable_parallel_weight_hints (see docs/fm-test-portable-shards.md).
# --check-coverage reports parallel_max_ms (the larger lane hint sum),
# parallel_imbalance_ms (the absolute difference between the sums), and
# parallel_unhinted (the number of members missing a parallel hint).
# These sums exclude unhinted members and are estimates, not measured job wall
# times. Missing parallel hints are reported without failing this guard.
#
# portable-serial stays strictly serial. Its CI shards (portable-serial-<k>of<n>)
# split it across separate runners, so two of its stateful scripts still never
# share a machine. This script owns <n>: a lane whose <n> disagrees with the
# configured shard count is refused, so a CI matrix cannot silently drop a shard.
# --check-coverage also reports serial_max_ms (largest packed hint sum, including
# default weights) and serial_budget_ms (the 20-minute packing target), refusing
# a split above that target. Neither figure is an execution timeout or proof of
# observed headroom: refresh growing files from CI measurements.
# --changed is conservative: it over-selects related families rather than
# under-selecting, and never expands to the complete suite unless --all. The one
# place it is deliberately narrow is a bin/ path with no curated family: a test
# that names it is selected as that SCRIPT, because the reference is per-script
# evidence. Consumer bin/ scripts still resolve through the curated map, so
# recorded family-level coupling still expands to the whole family.
# tests/lib.sh, tests/fixtures.sh, tests/*-helpers.sh and tests/*-fixture.sh are
# shared files that map to the suites naming them; a fixture under
# tests/fixtures/<dir>/ or a recorded capture under tests/captures/<dir>/ is
# mapped by that directory instead. Curated family arms above those also name
# individual tests/ files explicitly.
set -eu

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    echo $(($(date +%s) * 1000))
  fi
}

RUN_STARTED_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_STARTED_MS=$(now_ms)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT" || exit 1

MODE=
LIST_ONLY=0
LIST_SCHEDULED=0
LIST_FAMILIES=0
LIST_CONCURRENT_SAFE_FAMILIES=0
LIST_LANES=0
CHECK_COVERAGE=0
AGGREGATE_OUT=
FAMILY=
LANE=
BASE_REF=origin/main
JSON_PATH=
SCRIPTS=()
EXCLUDE_FAMILIES=()
FAIL_ON_GATE_SKIP=
JOBS=1
JOBS_EXPLICIT=0
JOBS_MAX=8
MAX_WALL_MS=
PER_SCRIPT_TIMEOUT_SECS=0
# Bound applied automatically on the automatic --changed path, derived from
# measured healthy runtimes with margin rather than picked: the slowest measured
# script was tests/fm-watch-triage.test.sh at about 1075s under CI load before
# its upstream split (the hint table below records the split suites). 1500s
# retains headroom over that loaded measurement, and stays under the 45-minute
# normal CI tier so a wedged script fails here,
# with its output, before the job cap
# cancels the lane. It is a guard, not a speed control: a HUNG script becomes a
# bounded failure instead of an unbounded suite, which is the shape that
# silently outruns a caller's invocation budget.
CHANGED_DEFAULT_TIMEOUT_SECS=1500

# How many separate-runner shards the portable serial remainder splits into.
# One owner: CI lane names carry this count and are refused when they disagree.
PORTABLE_SERIAL_SHARDS=12

# Conservative balance hint for a portable-serial script with no measurement.
# Rounded above the current CI mean, including the capability-skipped scripts.
PORTABLE_SERIAL_DEFAULT_WEIGHT_MS=45000

# Packing target, not an execution timeout: leave at least ten minutes of the
# normal CI tier for setup and runtime variance. --check-coverage refuses a
# modeled serial shard above this target; refresh hints or rebalance instead.
PORTABLE_SERIAL_MAX_WEIGHT_MS=1200000

# Largest share of the serial lane allowed to run on the default weight above.
# Hints are what keep the shards balanced, so once too much of the lane is
# unmeasured the balance is guesswork and one shard can reach its CI job cap
# while another sits idle. The coverage guard refuses past this share, which
# leaves room for newly added tests while making a stale hint table fail loudly
# instead of silently. docs/fm-test-portable-shards.md owns the refresh.
PORTABLE_SERIAL_MAX_UNHINTED_PERCENT=15

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-test-run: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'fm-test-run: %s\n' "$*" >&2
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Enforce the placement refusal described in this script's header.
#
# The primary checkout is the working tree whose own git dir IS the repository's
# common git dir; every linked worktree has a git dir under it instead. That is
# the same predicate bin/fm-spawn.sh uses to keep a launch out of the primary,
# and unlike comparing top-level paths it still holds when the primary is
# reached through a different path. When git resolves neither directory - a
# non-repository fixture, a detached copy - nothing proves this is the primary,
# so the run proceeds.
refuse_primary_checkout_for_task() {
  local task_id git_dir common_dir top
  task_id=${FM_TASK_ID:-}
  [ -n "$task_id" ] || return 0
  git_dir=$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null) \
    && git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P) || git_dir=
  common_dir=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    && common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P) || common_dir=
  [ -n "$git_dir" ] && [ -n "$common_dir" ] || return 0
  [ "$git_dir" = "$common_dir" ] || return 0
  top=$(cd "$ROOT" && pwd -P)
  die "refusing to run in the repository primary checkout $top while FM_TASK_ID=$task_id is set; run from the assigned task worktree instead"
}

cpu_count() {
  local n
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  case "$n" in
    ''|*[!0-9]*) n=1 ;;
  esac
  [ "$n" -ge 1 ] || n=1
  printf '%s\n' "$n"
}

# Primary family for one tests/*.test.sh basename. Unmapped scripts are
# unclassified so new tests are still runnable and visible in summaries.
#
# `standalone` is the residual family: scripts that belong to no subsystem
# family above but each own their own surface. Its membership is enumerated
# rather than inherited from the `*)` catch-all precisely because the catch-all
# also swallows every test nobody has classified yet. Keeping the two separate
# is what lets `standalone` carry a concurrent proof while a brand-new test
# lands in `unclassified` and stays serial until someone proves it.
family_for_basename() {
  case "$1" in
    fm-arm-pretool-check.test.sh|fm-ask-user-authority.test.sh|\
    fm-bearings-board.test.sh|\
    fm-brief.test.sh|fm-dod-lib.test.sh|fm-merge-local.test.sh|fm-vendor-auth-probe.test.sh|\
    fm-calm-pi-extension.test.sh|fm-cd-pretool-check.test.sh|\
    fm-classify-decision-key.test.sh|\
    fm-composer-ghost.test.sh|fm-composer-lib.test.sh|\
    fm-crew-state.test.sh|fm-captain-hold-lifecycle.test.sh|\
    fm-documentation-audiences.test.sh|fm-ensure-agents-md.test.sh|fm-forge-detect.test.sh|fm-grok-harness.test.sh|\
    fm-fork-free-helpers.test.sh|\
    fm-harness-precedence.test.sh|fm-install-herdr.test.sh|\
    fm-kimi-harness.test.sh|fm-devin-harness.test.sh|fm-commandcode-harness.test.sh|fm-cortex-harness.test.sh|fm-hermes-harness.test.sh|fm-muse-harness.test.sh|fm-rovo-harness.test.sh|fm-agy-harness.test.sh|fm-kiro-harness.test.sh|fm-omp-harness.test.sh|fm-polytoken-harness.test.sh|fm-herdr-lab.test.sh|fm-lint.test.sh|\
    fm-lint-workflows.test.sh|\
    fm-operational-input.test.sh|fm-pi-primary-types.test.sh|fm-read-repetition.test.sh|\
    fm-calm-claude-mod.test.sh|\
    fm-harness-adapter-references.test.sh|fm-project-mode.test.sh|\
    fm-send-popup-settle.test.sh|fm-send-settle.test.sh|\
    fm-subagent-pretool-check.test.sh|\
    fm-supervision-instructions.test.sh|fm-task-delivery.test.sh|\
    fm-timeout-lib.test.sh|fm-remote-inherit-generation.test.sh|\
    fm-tmux-submit-busy.test.sh|fm-trace-context-lib.test.sh|\
    fm-transition-lib.test.sh|\
    fm-test-run.test.sh|fm-test-isolation-proof.test.sh|fm-test-tap-verify.test.sh|\
    fm-test-linux.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    fm-daemon.test.sh|fm-guard-stale-banner.test.sh|fm-pi-watch-extension.test.sh|\
    fm-session-lock-ancestry.test.sh|fm-cursor-primary.test.sh|fm-agy-primary.test.sh|\
    fm-parent-channel-scan-exclusion.test.sh|\
    fm-supervision-events.test.sh|fm-turnend-guard.test.sh|fm-wake-daemon-lifecycle-e2e.test.sh|\
    fm-wake-drain-unread-status.test.sh|\
    fm-tool-update-check.test.sh|\
    fm-mail.test.sh|fm-mail-check.test.sh|\
    fm-turnend-foreign-owner-arm-fix.test.sh|\
    fm-wake-queue.test.sh|fm-watch-arm.test.sh|fm-watch-checkpoint.test.sh|fm-watch-recovery-loop.test.sh|\
    fm-codex-stop-park.test.sh|\
    fm-watch-inbox-meta.test.sh|fm-watch-open-decisions.test.sh|\
    fm-watch-triage.test.sh|fm-watch-triage-pause.test.sh|\
    fm-watch-triage-wedge-defer.test.sh|fm-task-inbox.test.sh|\
    fm-watcher-lock.test.sh|fm-inactive-reconcile.test.sh|fm-watch-wedge-cap.test.sh|\
    fm-watch-wedge-cap-unconfigured-parity.test.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    fm-afk-inject-herdr-e2e.test.sh|fm-afk-launch.test.sh|fm-backend-autodetect-smoke.test.sh|\
    fm-backend-herdr-eventwait-smoke.test.sh|fm-backend-herdr-presentation-e2e.test.sh|\
    fm-backend-herdr-launcher-workspace-e2e.test.sh|\
    fm-backend-herdr-prune-safety-e2e.test.sh|fm-backend-herdr-respawn-idem-e2e.test.sh|\
    fm-backend-herdr-focus-flash-e2e.test.sh|\
    fm-backend-herdr-stale-active-tab-e2e.test.sh|\
    fm-backend-herdr-agent-exit-shell-e2e.test.sh|\
    fm-herdr-attached-viewer-live-e2e.test.sh|fm-herdr-session-cleanup-e2e.test.sh|\
    fm-backend-herdr-smoke.test.sh|fm-backend-herdr-workspace-per-home-e2e.test.sh|\
    fm-control-herdr-smoke.test.sh)
      printf '%s\n' real-herdr-gated
      ;;
    fm-backlog-handoff.test.sh|fm-on.test.sh|fm-remote-backlog-handoff.test.sh|\
    fm-remote-doctor.test.sh|fm-remote-herdr-guard.test.sh|fm-remote-job.test.sh|fm-remote-job-orphan-reap.test.sh|fm-remote-job-process-start.test.sh|\
    fm-remote-job-per-root.test.sh|fm-remote-job-launchagent.test.sh|fm-remote-transport-lanes.test.sh|\
    fm-remote-reply.test.sh|fm-remote-secondmate-lifecycle-e2e.test.sh|\
    fm-remote-secondmate-lifecycle-backends-e2e.test.sh|fm-remote-secondmate-lifecycle-recovery-e2e.test.sh|\
    fm-remote-secondmate-lifecycle-naming-e2e.test.sh|fm-remote-secondmate-lifecycle-migration-e2e.test.sh|\
    fm-remote-secondmate-trace-context.test.sh|\
    fm-secondmate-harness.test.sh|fm-secondmate-lifecycle-e2e.test.sh|\
    fm-secondmate-liveness.test.sh|fm-secondmate-reconcile.test.sh|\
    fm-secondmate-restart.test.sh|fm-remote-secondmate-relaunch.test.sh|\
    fm-secondmate-safety.test.sh|fm-secondmate-sync.test.sh|\
    fm-startup-memory-budget.test.sh|fm-stow-cascade.test.sh|\
    fm-send-secondmate-marker.test.sh|fm-shared-captain-inheritance.test.sh)
      printf '%s\n' secondmate
      ;;
    fm-backlog-atomicity.test.sh|\
    fm-bootstrap.test.sh|fm-bootstrap-network-parallel.test.sh|fm-fleet-sync.test.sh|fm-gate-refuse.test.sh|fm-gotmp.test.sh|\
    fm-session-start.test.sh|fm-sessionstart-nudge.test.sh|fm-startup-network.test.sh|\
    fm-tangle-guard.test.sh|fm-update.test.sh)
      printf '%s\n' session-bootstrap
      ;;
    fm-afk-pi-herdr-return-e2e.test.sh|\
    fm-bearings-board-lavish-live-e2e.test.sh|\
    fm-claude-stop-autoarm-live-e2e.test.sh|\
    fm-cmux-claude-composer-live-e2e.test.sh|\
    fm-composer-matrix-live-e2e.test.sh|\
    fm-composer-codex-idle-live-e2e.test.sh|\
    fm-codex-continuity-live-e2e.test.sh|fm-codex-hook-layer-live-e2e.test.sh|\
    fm-grok-continuity-live-e2e.test.sh|\
    fm-cursor-primary-live-e2e.test.sh|fm-agy-primary-live-e2e.test.sh|\
    fm-grok-stop-live-e2e.test.sh|fm-harness-adapter-instructions-live-e2e.test.sh|\
    fm-harness-liveness-drift-live-e2e.test.sh|fm-backend-hc-liveness-live-e2e.test.sh|\
    fm-kimi-trust-prompt-live-e2e.test.sh|\
    fm-devin-signals-live-e2e.test.sh|fm-commandcode-signals-live-e2e.test.sh|fm-cortex-signals-live-e2e.test.sh|fm-hermes-signals-live-e2e.test.sh|fm-hermes-profile-safety-live-e2e.test.sh|fm-hermes-gateway-coexistence-live-e2e.test.sh|fm-muse-signals-live-e2e.test.sh|fm-rovo-signals-live-e2e.test.sh|fm-agy-signals-live-e2e.test.sh|fm-kiro-signals-live-e2e.test.sh|fm-polytoken-signals-live-e2e.test.sh|\
    fm-launch-prompt-signals-live-e2e.test.sh|fm-backend-t3code-live-e2e.test.sh|\
    fm-backend-t3code-pr-tools-live-e2e.test.sh|\
    fm-pi-seeded-home-trust-live-e2e.test.sh|\
    fm-herdr-version-floor-live-e2e.test.sh|\
    fm-herdr-projected-cd-live-e2e.test.sh|\
    fm-herdr-pi-stale-registration-live-e2e.test.sh|\
    fm-worker-account-live-e2e.test.sh|\
    fm-opencode-primary-live-e2e.test.sh|fm-pi-branch-live-e2e.test.sh|\
    fm-pi-branch-responsiveness-live-e2e.test.sh|\
    fm-pi-primary-live-e2e.test.sh|fm-pi-worker-stream-live-e2e.test.sh|fm-pi-codex-native.test.sh|fm-omp-primary-live-e2e.test.sh|\
    fm-pr-state-live-e2e.test.sh|\
    fm-sessionstart-hook-live-e2e.test.sh|fm-sessionstart-instruction-refresh-live-e2e.test.sh|\
    fm-supervision-host-live-e2e.test.sh|fm-supervision-host-attended-live-e2e.test.sh|\
    fm-host-mirror-live-e2e.test.sh|\
    fm-quota-array-dispatch-live-e2e.test.sh|fm-send-secondmate-marker-herdr-e2e.test.sh|\
    fm-send-inbox-doorbell-live-e2e.test.sh|\
    fm-secondmate-busy-contract-live-e2e.test.sh|\
    fm-calm-claude-mod-plugin.test.sh|fm-calm-claude-mod-live-e2e.test.sh|\
    fm-calm-pi-queue-retention-live-e2e.test.sh|\
    fm-herdr-submit-confirm-live-e2e.test.sh|\
    fm-backend-rex-composer-live-e2e.test.sh|\
    fm-watch-wedge-cap-live.test.sh|fm-read-repetition-live.test.sh|\
    fm-claude-tool-exclude-live.test.sh|fm-claude-safeguard-live.test.sh)
      printf '%s\n' live-harness-optin
      ;;
    fm-backend-herdr.test.sh|fm-backend-tmux-smoke.test.sh|fm-backend.test.sh|\
    fm-backend-t3code.test.sh|fm-t3-mcp.test.sh|fm-tmux-agent-liveness.test.sh|\
    fm-control.test.sh|fm-control-relaunch.test.sh|\
    fm-herdr-session-cleanup.test.sh|fm-send-resolve-key.test.sh|fm-send-strict.test.sh|\
    fm-send-inbox.test.sh|fm-spawn-batch.test.sh|\
    fm-spawn-dispatch-profile.test.sh|fm-claude-trust.test.sh|\
    fm-worker-account.test.sh|\
    fm-git-strip-ai-trailers.test.sh|\
    fm-trace-context-spawn.test.sh|fm-spawn-worktree-settle.test.sh|\
    fm-spawn-compact-adviser-disable.test.sh|\
    fm-spawn-compact-adviser-disable-remote.test.sh|\
    fm-project-capacity.test.sh|fm-lane-capacity-integration.test.sh|\
    fm-teardown-endpoint-safety.test.sh)
      printf '%s\n' backend-dispatch
      ;;
    fm-check-unregister.test.sh|fm-park.test.sh|fm-pipeline-spend.test.sh|fm-pr-check-security.test.sh|\
    fm-pr-health.test.sh|fm-pr-merge.test.sh|fm-pr-reviewers.test.sh|fm-pr-state.test.sh|\
    fm-review-diff.test.sh|fm-teardown.test.sh|fm-x-mode.test.sh)
      printf '%s\n' pr-forge
      ;;
    fm-afk-contract.test.sh|fm-afk-inject-e2e.test.sh|fm-afk-return.test.sh|\
    fm-supervision-host.test.sh|fm-supervision-host-drain.test.sh|\
    fm-supervision-host-hook.test.sh|fm-supervision-host-park.test.sh|\
    fm-host-mirror.test.sh)
      printf '%s\n' afk
      ;;
    fm-bearings-board-render.test.sh|fm-bearings-snapshot.test.sh|fm-contributions.test.sh|\
    fm-fleet-snapshot-view.test.sh|fm-home-summary-refresh.test.sh)
      printf '%s\n' snapshot-bearings
      ;;
    fm-backend-cmux.test.sh|fm-backend-cmux-smoke.test.sh)
      printf '%s\n' cmux
      ;;
    fm-backend-paseo.test.sh|fm-backend-paseo-smoke.test.sh)
      printf '%s\n' paseo
      ;;
    fm-backend-rex.test.sh|fm-backend-rex-smoke.test.sh|fm-backend-rex-eventwait-smoke.test.sh)
      printf '%s\n' rex
      ;;
    fm-backend-zellij.test.sh|fm-backend-zellij-smoke.test.sh)
      printf '%s\n' zellij
      ;;
    fm-backend-orca.test.sh)
      printf '%s\n' orca
      ;;
    fm-backend-tern.test.sh|fm-backend-tern-smoke.test.sh)
      printf '%s\n' tern
      ;;
    fm-backend-hc.test.sh|fm-backend-hc-smoke.test.sh|fm-backend-hc-appdetect-smoke.test.sh)
      printf '%s\n' hc
      ;;
    fm-branch-supervision.test.sh|fm-busy-adapter-wiring.test.sh|\
    fm-busy-state.test.sh|fm-capacity.test.sh|fm-capacity-auto.test.sh|fm-lane-vitals.test.sh|\
    fm-classify-corr-token.test.sh|\
    fm-claude-account-quota.test.sh|\
    fm-claude-stop-autoarm.test.sh|fm-cursor-harness.test.sh|\
    fm-dispatch-resolve.test.sh|\
    fm-extension-binding.test.sh|fm-gitignore-config.test.sh|\
    fm-no-mistakes-required.test.sh|fm-peek-remote.test.sh|\
    fm-pending-reply.test.sh|fm-pi-branch-extension.test.sh|\
    fm-procevent-extension-errors.test.sh|fm-procevent-quota.test.sh|fm-procevent-when.test.sh|fm-procevent.test.sh|\
    fm-live-gate.test.sh|\
    fm-project-origin.test.sh|fm-public-followup.test.sh|fm-quota-choose.test.sh|\
    fm-remote-entrypoint.test.sh|fm-remote-secondmate-parent-binding.test.sh|\
    fm-send-remote-delivery.test.sh|fm-spawn-pool-base-freshen.test.sh|\
    fm-test-fixture-cleanup.test.sh|fm-test-fixtures.test.sh|\
    fm-voice-relay.test.sh|fm-wake-drain-open-decisions-cursor.test.sh|\
    fm-wake-drain-open-decisions.test.sh|fm-wake-drain-outcome-backstop.test.sh)
      printf '%s\n' standalone
      ;;
    *)
      printf '%s\n' unclassified
      ;;
  esac
}

expected_gate_skip_for_family() {
  case "$1" in
    real-herdr-gated) printf '%s\n' herdr ;;
    live-harness-optin) printf '%s\n' live-capability ;;
    cmux|zellij|orca|paseo|rex|tern|hc) printf '%s\n' optional-binary ;;
    snapshot-bearings) printf '%s\n' optional-binary ;;
    *) printf '%s\n' none ;;
  esac
}

list_known_families() {
  cat <<'EOF'
pure-contract-unit
watcher-wake-lock
real-herdr-gated
secondmate
session-bootstrap
live-harness-optin
backend-dispatch
pr-forge
afk
snapshot-bearings
cmux
zellij
orca
paseo
rex
tern
hc
standalone
unclassified
EOF
}

list_known_lanes() {
  local i
  printf '%s\n' portable-parallel-1
  printf '%s\n' portable-parallel-2
  printf '%s\n' portable-serial
  i=1
  while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    printf 'portable-serial-%sof%s\n' "$i" "$PORTABLE_SERIAL_SHARDS"
    i=$((i + 1))
  done
  printf '%s\n' real-herdr-gated
}

# Exact proven-isolated candidate set (same paths as
# bin/fm-test-isolation-proof.sh --list). Do not expand without a new concurrent
# isolation proof archive.
list_proven_isolated() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-backend-t3code.test.sh
tests/fm-brief.test.sh
tests/fm-captain-hold-lifecycle.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-composer-lib.test.sh
tests/fm-crew-state.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-grok-harness.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-lint.test.sh
tests/fm-park.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-pr-merge.test.sh
tests/fm-review-diff.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-send-settle.test.sh
tests/fm-send-strict.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-t3-mcp.test.sh
tests/fm-test-run.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-transition-lib.test.sh
tests/fm-x-mode.test.sh
EOF
}

# Per-script serial CI duration hints, one "<path> <ms>" per line, used to
# pack only the two portable parallel lanes. Measurement provenance and the
# refresh procedure are owned by docs/fm-test-portable-shards.md.
portable_parallel_weight_hints() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh 35987
tests/fm-backend-herdr.test.sh 47528
tests/fm-backend-t3code.test.sh 242671
tests/fm-brief.test.sh 16554
tests/fm-captain-hold-lifecycle.test.sh 856327
tests/fm-cd-pretool-check.test.sh 21835
tests/fm-composer-ghost.test.sh 2838
tests/fm-composer-lib.test.sh 26719
tests/fm-crew-state.test.sh 131641
tests/fm-ensure-agents-md.test.sh 941
tests/fm-grok-harness.test.sh 9193
tests/fm-herdr-lab.test.sh 18323
tests/fm-lint.test.sh 365530
tests/fm-park.test.sh 70085
tests/fm-pi-primary-types.test.sh 31176
tests/fm-pr-merge.test.sh 458953
tests/fm-review-diff.test.sh 18818
tests/fm-send-popup-settle.test.sh 8804
tests/fm-send-settle.test.sh 3055
tests/fm-send-strict.test.sh 6177
tests/fm-spawn-batch.test.sh 4690
tests/fm-supervision-instructions.test.sh 1660
tests/fm-t3-mcp.test.sh 32872
tests/fm-test-run.test.sh 378918
tests/fm-tmux-submit-busy.test.sh 2985
tests/fm-transition-lib.test.sh 279
tests/fm-x-mode.test.sh 45654
EOF
}

# Sum the hints above for the scripts read on stdin, and report how many of
# them had no hint at all, as "<summed_ms> <unhinted_count>".
portable_parallel_lane_weight() {
  awk '
    NR == FNR { if (NF) { hint[$1] = $2 } ; next }
    NF {
      if ($1 in hint) { total += hint[$1] } else { unhinted++ }
    }
    END { printf "%d %d\n", total + 0, unhinted + 0 }
  ' <(portable_parallel_weight_hints) -
}

# Seed shard 1 with the Pi typecheck so it stays under the workflow's required
# gate-skip check, then pack the remaining proven set longest-first into the
# lighter shard. Store each shard in --list-scheduled order.
list_portable_parallel_1() {
  cat <<'EOF'
tests/fm-pr-merge.test.sh
tests/fm-test-run.test.sh
tests/fm-backend-t3code.test.sh
tests/fm-crew-state.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-x-mode.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-composer-lib.test.sh
tests/fm-review-diff.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-send-settle.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-transition-lib.test.sh
EOF
}

# Portable parallel shard 2: the complementary LPT half of the proven set.
list_portable_parallel_2() {
  cat <<'EOF'
tests/fm-captain-hold-lifecycle.test.sh
tests/fm-lint.test.sh
tests/fm-park.test.sh
tests/fm-arm-pretool-check.test.sh
tests/fm-t3-mcp.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-brief.test.sh
tests/fm-grok-harness.test.sh
tests/fm-send-strict.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-ensure-agents-md.test.sh
EOF
}

# Families whose scripts are proven safe to run concurrently WITH EACH OTHER
# under the bounded local scheduler. Deliberately separate from the
# proven-isolated set, which must stay exactly equal to the portable CI shard
# union (see the coverage guard); these families keep their serial CI lane and
# only gain concurrency for a local run.
#
# Membership is empirical, never assumed:
# `bin/fm-test-isolation-proof.sh --pool <family> --jobs 4` is the owner of the
# proof, and docs/fm-test-isolation-proof.md records the dated result.
list_concurrent_safe_families() {
  cat <<'EOF'
watcher-wake-lock
pure-contract-unit
pr-forge
secondmate
session-bootstrap
standalone
EOF
}

family_is_concurrent_safe() {
  local want=$1 line
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done < <(list_concurrent_safe_families)
  return 1
}

concurrent_safe_family_jobs_max() {
  case "$1" in
    watcher-wake-lock|pure-contract-unit|pr-forge) printf '4\n' ;;
    secondmate|session-bootstrap|standalone) printf '4\n' ;;
    *) printf '1\n' ;;
  esac
}

# A script may run under --jobs when it is individually proven isolated or is
# an exact repository member of a family carrying a recorded concurrent proof.
script_allows_concurrency() {
  local s=$1 family repo_script
  is_proven_isolated_script "$s" && return 0
  family=$(family_for_basename "$(basename "$s")")
  family_is_concurrent_safe "$family" || return 1
  while IFS= read -r repo_script; do
    [ "$repo_script" = "$s" ] && return 0
  done < <(all_repo_tests)
  return 1
}

is_proven_isolated_script() {
  local want=$1 line
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done < <(list_proven_isolated)
  return 1
}

# The portable serial remainder: every tests/*.test.sh that is neither
# proven-isolated nor real-herdr-gated. Watcher, lock, AFK, real tmux, daemon,
# secondmate lifecycle, bootstrap, the live-harness-optin family, GUI-backend,
# and other unproven work stays here. Derived rather than enumerated so a newly added test
# lands here by default instead of falling out of every lane.
list_portable_serial() {
  local s fam proven_paths
  # Load the portable exclusions once, with delimiters for exact path matches.
  proven_paths=$(list_proven_isolated) || return 1
  proven_paths=$'\n'$proven_paths$'\n'
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    case "$proven_paths" in
      *$'\n'"$s"$'\n'*) continue ;;
    esac
    fam=$(family_for_basename "${s##*/}")
    if [ "$fam" = "real-herdr-gated" ]; then
      continue
    fi
    printf '%s\n' "$s"
  done < <(all_repo_tests)
}

# Measured portable-serial script durations in milliseconds, from the CI timing
# artifacts recorded in docs/fm-test-portable-shards.md. Each value is the
# slowest successful sample in the referenced complete/partial CI runs, with
# the version-specific host and native-Windows exceptions documented there.
# These are balance hints only: the shard
# partition stays complete and disjoint whatever they say, so a stale hint costs
# balance rather than coverage. That doc owns the refresh procedure.
portable_serial_weight_hints() {
  cat <<'EOF'
tests/fm-afk-contract.test.sh 11101
tests/fm-afk-inject-e2e.test.sh 41958
tests/fm-afk-pi-herdr-return-e2e.test.sh 52
tests/fm-afk-return.test.sh 47380
tests/fm-agy-harness.test.sh 50959
tests/fm-agy-primary-live-e2e.test.sh 75
tests/fm-agy-primary.test.sh 45000
tests/fm-agy-signals-live-e2e.test.sh 53
tests/fm-approval-failover.test.sh 5410
tests/fm-ask-user-authority.test.sh 171
tests/fm-backend-cmux-smoke.test.sh 34
tests/fm-backend-cmux.test.sh 3754
tests/fm-backend-hc-liveness-live-e2e.test.sh 9000
tests/fm-backend-hc-smoke.test.sh 3700
tests/fm-backend-hc.test.sh 4000
tests/fm-backend-orca.test.sh 27102
tests/fm-backend-paseo-smoke.test.sh 40
tests/fm-backend-paseo.test.sh 8000
tests/fm-backend-t3code-live-e2e.test.sh 51
tests/fm-backend-t3code-pr-tools-live-e2e.test.sh 52
tests/fm-backend-tern-smoke.test.sh 60
tests/fm-backend-tern.test.sh 6000
tests/fm-backend-tmux-smoke.test.sh 291
tests/fm-backend-zellij-smoke.test.sh 23
tests/fm-backend-zellij.test.sh 10453
tests/fm-backend.test.sh 23932
tests/fm-backlog-atomicity.test.sh 219379
tests/fm-backlog-handoff.test.sh 57458
tests/fm-backlog-read-bound.test.sh 24743
tests/fm-bearings-board-lavish-live-e2e.test.sh 51
tests/fm-bearings-board-render.test.sh 15612
tests/fm-bearings-board.test.sh 40817
tests/fm-bearings-snapshot.test.sh 186219
tests/fm-bootstrap-network-parallel.test.sh 30424
tests/fm-bootstrap.test.sh 50965
tests/fm-branch-supervision.test.sh 22979
tests/fm-busy-adapter-wiring.test.sh 31642
tests/fm-busy-state.test.sh 3185
tests/fm-calm-claude-mod-live-e2e.test.sh 47
tests/fm-calm-claude-mod-plugin.test.sh 77
tests/fm-calm-claude-mod.test.sh 2527
tests/fm-calm-pi-extension.test.sh 56463
tests/fm-calm-pi-queue-retention-live-e2e.test.sh 1345
tests/fm-capacity-auto.test.sh 36243
tests/fm-check-unregister.test.sh 469
tests/fm-ci-workflow.test.sh 5833
tests/fm-classify-corr-token.test.sh 23085
tests/fm-classify-decision-key.test.sh 4362
tests/fm-claude-account-quota.test.sh 2492
tests/fm-claude-stop-autoarm-live-e2e.test.sh 73
tests/fm-claude-stop-autoarm.test.sh 61189
tests/fm-claude-tool-exclude-live.test.sh 75
tests/fm-claude-trust.test.sh 12010
tests/fm-cmux-claude-composer-live-e2e.test.sh 77
tests/fm-codex-continuity-live-e2e.test.sh 108
tests/fm-codex-hook-layer-live-e2e.test.sh 108
tests/fm-codex-stop-park.test.sh 35000
tests/fm-commandcode-harness.test.sh 8182
tests/fm-commandcode-signals-live-e2e.test.sh 49
tests/fm-composer-codex-idle-live-e2e.test.sh 77
tests/fm-composer-matrix-live-e2e.test.sh 51
tests/fm-contributions.test.sh 140911
tests/fm-control-relaunch.test.sh 114115
tests/fm-control.test.sh 72794
tests/fm-cortex-harness.test.sh 5400
tests/fm-cortex-signals-live-e2e.test.sh 49
tests/fm-cursor-harness.test.sh 30088
tests/fm-cursor-primary-live-e2e.test.sh 75
tests/fm-cursor-primary.test.sh 69845
tests/fm-daemon.test.sh 33606
tests/fm-devin-harness.test.sh 3725
tests/fm-devin-signals-live-e2e.test.sh 49
tests/fm-discord-dispatch.test.sh 3524
tests/fm-discord-hook.test.sh 8860
tests/fm-discord-reply.test.sh 2632
tests/fm-dispatch-resolve.test.sh 10051
tests/fm-documentation-audiences.test.sh 1301
tests/fm-dod-lib.test.sh 2035
tests/fm-extension-binding.test.sh 11105
tests/fm-fleet-ledger.test.sh 19980
tests/fm-fleet-snapshot-view.test.sh 23334
tests/fm-fleet-sync.test.sh 40541
tests/fm-forge-detect.test.sh 193
tests/fm-fork-free-helpers.test.sh 746
tests/fm-gate-refuse.test.sh 9953
tests/fm-gemini-harness.test.sh 947
tests/fm-git-strip-ai-trailers.test.sh 2067
tests/fm-gitignore-config.test.sh 59
tests/fm-gotmp.test.sh 1509
tests/fm-grok-continuity-live-e2e.test.sh 46
tests/fm-grok-stop-live-e2e.test.sh 48
tests/fm-guard-stale-banner.test.sh 17234
tests/fm-harness-adapter-instructions-live-e2e.test.sh 72
tests/fm-harness-adapter-references.test.sh 64
tests/fm-harness-liveness-drift-live-e2e.test.sh 1309
tests/fm-harness-precedence.test.sh 4083
tests/fm-herdr-groups.test.sh 5418
tests/fm-herdr-pi-stale-registration-live-e2e.test.sh 55
tests/fm-herdr-projected-cd-live-e2e.test.sh 28000
tests/fm-herdr-session-cleanup.test.sh 7425
tests/fm-herdr-submit-confirm-live-e2e.test.sh 51
tests/fm-herdr-version-floor-live-e2e.test.sh 50
tests/fm-home-summary-refresh.test.sh 37057
tests/fm-host-mirror-live-e2e.test.sh 79
tests/fm-host-mirror.test.sh 11587
tests/fm-inactive-reconcile.test.sh 60823
tests/fm-inbox.test.sh 6062
tests/fm-install-herdr.test.sh 1000
tests/fm-jev-mem-guard.test.sh 336
tests/fm-kimi-harness.test.sh 58917
tests/fm-kimi-trust-prompt-live-e2e.test.sh 60
tests/fm-lane-capacity-integration.test.sh 48000
tests/fm-lane-vitals.test.sh 5077
tests/fm-launch-prompt-signals-live-e2e.test.sh 50
tests/fm-lavish-url.test.sh 30000
tests/fm-lint-workflows.test.sh 872
tests/fm-live-gate.test.sh 7452
tests/fm-live-lab-isolation.test.sh 6459
tests/fm-live-lab-up-mate.test.sh 17363
tests/fm-live-lab.test.sh 79639
tests/fm-mail-check.test.sh 7524
tests/fm-mail.test.sh 9684
tests/fm-muse-harness.test.sh 46548
tests/fm-muse-signals-live-e2e.test.sh 52
tests/fm-nm-test-contract.test.sh 853
tests/fm-no-mistakes-required.test.sh 270
tests/fm-omp-harness.test.sh 63796
tests/fm-omp-primary-live-e2e.test.sh 74
tests/fm-on.test.sh 11473
tests/fm-opencode-primary-live-e2e.test.sh 47
tests/fm-operational-input.test.sh 2404
tests/fm-osc7501.test.sh 14000
tests/fm-peek-remote.test.sh 1082
tests/fm-pending-reply.test.sh 41090
tests/fm-pi-branch-extension.test.sh 77218
tests/fm-pi-branch-live-e2e.test.sh 48
tests/fm-pi-branch-responsiveness-live-e2e.test.sh 12834
tests/fm-pi-codex-native.test.sh 75
tests/fm-pi-primary-live-e2e.test.sh 72
tests/fm-pi-seeded-home-trust-live-e2e.test.sh 45
tests/fm-pi-watch-extension.test.sh 56515
tests/fm-pi-windows-shell-invocation.test.sh 5121
tests/fm-polytoken-harness.test.sh 21090
tests/fm-polytoken-signals-live-e2e.test.sh 103
tests/fm-pr-check-security.test.sh 300675
tests/fm-pr-reviewers.test.sh 157
tests/fm-pr-state-live-e2e.test.sh 47
tests/fm-pr-state.test.sh 525
tests/fm-procevent-quota.test.sh 2459
tests/fm-procevent-when.test.sh 25674
tests/fm-procevent.test.sh 292297
tests/fm-project-origin.test.sh 123
tests/fm-public-followup.test.sh 381564
tests/fm-quota-array-dispatch-live-e2e.test.sh 50
tests/fm-quota-choose.test.sh 2860
tests/fm-read-repetition-live.test.sh 1110
tests/fm-read-repetition.test.sh 602
tests/fm-remote-backlog-handoff.test.sh 82063
tests/fm-remote-doctor.test.sh 14460
tests/fm-remote-entrypoint.test.sh 134
tests/fm-remote-herdr-guard.test.sh 3140
tests/fm-remote-herdr-identity.test.sh 6158
tests/fm-remote-job-orphan-reap.test.sh 2985
tests/fm-remote-job-process-start.test.sh 11871
tests/fm-remote-job.test.sh 81046
tests/fm-remote-reply.test.sh 140887
tests/fm-remote-secondmate-lifecycle-backends-e2e.test.sh 775127
tests/fm-remote-secondmate-lifecycle-e2e.test.sh 776428
tests/fm-remote-secondmate-lifecycle-migration-e2e.test.sh 356054
tests/fm-remote-secondmate-lifecycle-naming-e2e.test.sh 365210
tests/fm-remote-secondmate-lifecycle-recovery-e2e.test.sh 190297
tests/fm-remote-secondmate-parent-binding.test.sh 42294
tests/fm-remote-secondmate-relaunch.test.sh 879
tests/fm-remote-secondmate-trace-context.test.sh 74870
tests/fm-remote-transport-lanes.test.sh 66089
tests/fm-rovo-harness.test.sh 15691
tests/fm-rovo-signals-live-e2e.test.sh 52
tests/fm-secondmate-harness.test.sh 188187
tests/fm-secondmate-busy-contract-live-e2e.test.sh 90000
tests/fm-secondmate-lifecycle-e2e.test.sh 11268
tests/fm-secondmate-liveness.test.sh 24564
tests/fm-secondmate-reconcile.test.sh 100853
tests/fm-secondmate-restart.test.sh 52591
tests/fm-secondmate-safety.test.sh 69424
tests/fm-secondmate-sync.test.sh 55501
tests/fm-send-agy-confirm.test.sh 4440
tests/fm-send-inbox-doorbell-live-e2e.test.sh 108
tests/fm-send-inbox.test.sh 41713
tests/fm-send-remote-delivery.test.sh 31964
tests/fm-send-resolve-key.test.sh 47317
tests/fm-send-secondmate-marker-herdr-e2e.test.sh 80
tests/fm-send-secondmate-marker.test.sh 7574
tests/fm-session-lock-ancestry.test.sh 18918
tests/fm-session-lock-ps-denied.test.sh 3012
tests/fm-session-start.test.sh 363574
tests/fm-sessionstart-hook-live-e2e.test.sh 50
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh 49
tests/fm-sessionstart-nudge.test.sh 71802
tests/fm-shared-captain-inheritance.test.sh 7991
tests/fm-spawn-compact-adviser-disable-remote.test.sh 38561
tests/fm-spawn-compact-adviser-disable.test.sh 21654
tests/fm-spawn-dispatch-profile.test.sh 197548
tests/fm-spawn-orca-worktree.test.sh 2400
tests/fm-spawn-pool-base-freshen.test.sh 68652
tests/fm-spawn-worktree-settle.test.sh 9309
tests/fm-startup-memory-budget.test.sh 8086
tests/fm-startup-network.test.sh 72106
tests/fm-stat-shadowing.test.sh 75
tests/fm-stow-cascade.test.sh 3058
tests/fm-stow-guard.test.sh 30000
tests/fm-subagent-pretool-check.test.sh 998
tests/fm-supervision-events.test.sh 673
tests/fm-supervision-host-attended-live-e2e.test.sh 49
tests/fm-supervision-host-drain.test.sh 45950
tests/fm-supervision-host-hook.test.sh 403793
tests/fm-supervision-host-live-e2e.test.sh 75
tests/fm-supervision-host-park.test.sh 329326
tests/fm-supervision-host.test.sh 435581
tests/fm-tangle-guard.test.sh 8501
tests/fm-task-delivery.test.sh 32789
tests/fm-task-inbox.test.sh 31965
tests/fm-tasks-axi.test.sh 2293
tests/fm-teardown-endpoint-safety.test.sh 40851
tests/fm-teardown.test.sh 202132
tests/fm-test-fixture-cleanup.test.sh 866
tests/fm-test-fixtures.test.sh 1802
tests/fm-test-isolation-proof.test.sh 2866
tests/fm-test-linux.test.sh 1500
tests/fm-test-tap-verify.test.sh 1000
tests/fm-timeout-lib.test.sh 10750
tests/fm-tmux-agent-liveness.test.sh 3770
tests/fm-tool-update-check.test.sh 14383
tests/fm-trace-context-lib.test.sh 221
tests/fm-trace-context-spawn.test.sh 57488
tests/fm-turnend-foreign-owner-arm-fix.test.sh 5575
tests/fm-turnend-guard.test.sh 34727
tests/fm-update.test.sh 11894
tests/fm-vendor-auth-probe.test.sh 43278
tests/fm-voice-relay.test.sh 28917
tests/fm-wake-daemon-lifecycle-e2e.test.sh 7345
tests/fm-wake-drain-open-decisions-cursor.test.sh 47677
tests/fm-wake-drain-open-decisions.test.sh 8781
tests/fm-wake-drain-outcome-backstop.test.sh 46316
tests/fm-wake-drain-unread-status.test.sh 24251
tests/fm-wake-queue.test.sh 165906
tests/fm-warm-compact-herdr-live-e2e.test.sh 170
tests/fm-warm-compact.test.sh 1500
tests/fm-watch-arm.test.sh 113076
tests/fm-watch-checkpoint.test.sh 11234
tests/fm-watch-inbox-meta.test.sh 283
tests/fm-watch-recovery-loop.test.sh 59092
tests/fm-watch-triage-pause.test.sh 466750
tests/fm-watch-triage-wedge-defer.test.sh 526980
tests/fm-watch-triage.test.sh 592950
tests/fm-watch-wedge-cap.test.sh 374225
tests/fm-watch-wedge-cap-unconfigured-parity.test.sh 27763
tests/fm-watch-wedge-cap-live.test.sh 74
tests/fm-watcher-lock.test.sh 72022
tests/fm-worker-account-live-e2e.test.sh 3179
tests/fm-worker-account.test.sh 37445
tests/fm-assertions.test.sh 129
tests/fm-backend-hc-appdetect-smoke.test.sh 55
tests/fm-backend-rex-composer-live-e2e.test.sh 57
tests/fm-backend-rex-eventwait-smoke.test.sh 49
tests/fm-backend-rex-smoke.test.sh 47
tests/fm-backend-rex.test.sh 73423
tests/fm-capacity.test.sh 7102
tests/fm-fleet-snapshot-contribution-input.test.sh 232
tests/fm-git-push-guard.test.sh 1284
tests/fm-hc-lab.test.sh 701
tests/fm-hermes-gateway-coexistence-live-e2e.test.sh 53
tests/fm-hermes-harness.test.sh 10115
tests/fm-hermes-profile-safety-live-e2e.test.sh 55
tests/fm-hermes-signals-live-e2e.test.sh 49
tests/fm-kiro-harness.test.sh 33365
tests/fm-kiro-signals-live-e2e.test.sh 56
tests/fm-merge-local.test.sh 7606
tests/fm-opencode-abs-cwd-rail-live-e2e.test.sh 56
tests/fm-opencode-live-selection.test.sh 1436
tests/fm-parent-channel-scan-exclusion.test.sh 3783
tests/fm-pi-worker-stream-live-e2e.test.sh 5359
tests/fm-pipeline-spend.test.sh 3093
tests/fm-pr-health.test.sh 82915
tests/fm-procevent-extension-errors.test.sh 104684
tests/fm-project-capacity.test.sh 73279
tests/fm-project-mode.test.sh 611
tests/fm-record-export-remote-home.test.sh 3209
tests/fm-record-export.test.sh 15685
tests/fm-remote-delta-read.test.sh 5260
tests/fm-remote-job-claim-reap.test.sh 3561
tests/fm-remote-job-claim-retention.test.sh 173
tests/fm-remote-job-launchagent.test.sh 60332
tests/fm-remote-secondmate-omp.test.sh 4136
tests/fm-review-check.test.sh 1927
tests/fm-self-repo-role.test.sh 8157
tests/fm-send-kiro-confirm.test.sh 1327
tests/fm-session-lock-windows-consumers.test.sh 1846
tests/fm-spawn-external-review.test.sh 7273
tests/fm-spawn-herdr-lease.test.sh 8808
tests/fm-spawn-manual-pr-text.test.sh 8234
tests/fm-startup-growth-check.test.sh 6131
tests/fm-usage-warner.test.sh 28641
tests/fm-watch-open-decisions.test.sh 11824
EOF
}

# The portable-serial scripts with no measured hint, one per line. These fall
# back to PORTABLE_SERIAL_DEFAULT_WEIGHT_MS, so they are balanced on a guess
# rather than on evidence; the coverage guard bounds how many there may be.
portable_serial_unhinted() {
  local tmp="$RUN_TMP/unhinted"
  mkdir "$tmp" || return 1
  portable_serial_weight_hints | awk 'NF { print $1 }' | LC_ALL=C sort -u >"$tmp/hinted"
  list_portable_serial | LC_ALL=C sort -u >"$tmp/serial"
  LC_ALL=C comm -23 "$tmp/serial" "$tmp/hinted"
  rm -rf "$tmp"
}

# Sum serial weights for paths on stdin, including the unmeasured default.
portable_serial_lane_weight() {
  awk -v fallback="$PORTABLE_SERIAL_DEFAULT_WEIGHT_MS" '
    NR == FNR { if (NF) { hint[$1] = $2 }; next }
    NF { total += ($1 in hint) ? hint[$1] : fallback }
    END { printf "%d\n", total + 0 }
  ' <(portable_serial_weight_hints) -
}

portable_parallel_weight_for() {
  local want=$1 ms
  ms=$(portable_parallel_weight_hints | awk -v want="$want" '$1 == want { print $2; exit }')
  if [ -n "$ms" ]; then
    printf '%s\n' "$ms"
    return 0
  fi
  portable_serial_weight_for "$want"
}

portable_serial_weight_for() {
  local want=$1 path ms
  while read -r path ms; do
    if [ "$path" = "$want" ]; then
      printf '%s\n' "$ms"
      return 0
    fi
  done < <(portable_serial_weight_hints)
  printf '%s\n' "$PORTABLE_SERIAL_DEFAULT_WEIGHT_MS"
}

# Longest-processing-time assignment of the serial remainder to
# PORTABLE_SERIAL_SHARDS bins, printing "<shard>\t<script>" for every script.
# Deterministic: candidates are ordered by hint descending then path, and ties
# between equally loaded bins always take the lowest bin index.
portable_serial_assignments() (
  local paths
  paths=$(list_portable_serial) || return
  set -o pipefail
  # Resolve all paths against one copy of the hints, keeping the first hint
  # per path just as the individual lookup does.
  {
    portable_serial_weight_hints && printf '%s\n' -- "$paths"
  } | LC_ALL=C awk -v fallback="$PORTABLE_SERIAL_DEFAULT_WEIGHT_MS" '
    $0 == "--" { paths = 1; next }
    !paths { if (NF && !($1 in hint)) hint[$1] = $2; next }
    NF { printf "%s\t%s\n", ($0 in hint) ? hint[$0] : fallback, $0 }
  ' | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2 | LC_ALL=C awk -F '\t' -v shards="$PORTABLE_SERIAL_SHARDS" '
    {
      best = 1
      for (i = 2; i <= shards; i++) {
        if (load[i] + 0 < load[best] + 0) best = i
      }
      load[best] += $1
      printf "%d\t%s\n", best, substr($0, index($0, FS) + 1)
    }
  '
)

# Parse "<k>of<n>" from a portable-serial shard lane and echo <k>, refusing when
# <n> disagrees with this script's configured count so a CI matrix built for a
# different shard count fails loudly instead of dropping tests.
portable_serial_shard_index() {
  local lane=$1 spec index count
  spec=${lane#portable-serial-}
  index=${spec%%of*}
  count=${spec#*of}
  case "$spec" in
    *of*) ;;
    *) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$index" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$count" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  if [ "$count" -ne "$PORTABLE_SERIAL_SHARDS" ]; then
    die "lane '$lane' asks for $count portable serial shards but this runner is configured for $PORTABLE_SERIAL_SHARDS (see --list-lanes)"
  fi
  if [ "$index" -lt 1 ] || [ "$index" -gt "$PORTABLE_SERIAL_SHARDS" ]; then
    die "lane '$lane' shard index is outside 1..$PORTABLE_SERIAL_SHARDS (see --list-lanes)"
  fi
  printf '%s\n' "$index"
}

select_proven_isolated() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(list_proven_isolated)
}

select_lane() {
  local want=$1 assignments=${2:-} s shard idx found=0
  case "$want" in
    portable-parallel-1)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_1)
      ;;
    portable-parallel-2)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_2)
      ;;
    portable-serial)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_serial)
      ;;
    portable-serial-*)
      # One separate-runner shard of the same remainder, still serial in itself.
      shard=$(portable_serial_shard_index "$want")
      if [ "$#" -lt 2 ]; then
        assignments=$(portable_serial_assignments) || die 'could not pack portable serial shards'
      fi
      while IFS=$'\t' read -r idx s; do
        [ -n "$s" ] || continue
        if [ "$idx" = "$shard" ]; then
          add_script "$s"
          found=1
        fi
      done <<< "$assignments"
      ;;
    real-herdr-gated)
      select_family real-herdr-gated
      found=1
      ;;
    *)
      die "unknown lane '$want' (see --list-lanes)"
      ;;
  esac
  [ "$found" -eq 1 ] || die "lane '$want' selected no tests"
}

run_coverage_guard() {
  local tmp missing extra a b shard assignments unhinted serial_total serial_ms serial_max_ms=0
  local p1_ms p1_unhinted p2_ms p2_unhinted parallel_max_ms parallel_imbalance_ms
  local -a saved_scripts=()
  tmp="$RUN_TMP/coverage"
  mkdir "$tmp"

  all_repo_tests | LC_ALL=C sort -u >"$tmp/all"
  list_proven_isolated | LC_ALL=C sort -u >"$tmp/proven"
  list_portable_parallel_1 | LC_ALL=C sort -u >"$tmp/s1"
  list_portable_parallel_2 | LC_ALL=C sort -u >"$tmp/s2"

  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort | uniq -d >"$tmp/shard_dups"
  if [ -s "$tmp/shard_dups" ]; then
    log "coverage guard: portable parallel shards share scripts:"
    cat "$tmp/shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort -u >"$tmp/shards_union"
  missing=$(LC_ALL=C comm -23 "$tmp/proven" "$tmp/shards_union" || true)
  extra=$(LC_ALL=C comm -13 "$tmp/proven" "$tmp/shards_union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable shards must equal the proven-isolated set"
    [ -z "$missing" ] || { log "missing from shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond proven:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Serial (whole lane and each CI shard) + Herdr lane listings without
  # disturbing a caller's selection.
  saved_scripts=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
  SCRIPTS=()
  select_lane portable-serial
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/serial"
  # Reuse one packing across all shard selections in this guard invocation.
  if ! assignments=$(portable_serial_assignments); then
    log 'coverage guard: could not pack portable serial shards'
    SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")
    rm -rf "$tmp"
    return 1
  fi
  : >"$tmp/serial_shards_raw"
  shard=1
  while [ "$shard" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    SCRIPTS=()
    select_lane "portable-serial-${shard}of${PORTABLE_SERIAL_SHARDS}" "$assignments"
    if [ "${#SCRIPTS[@]}" -eq 0 ]; then
      log "coverage guard: portable serial shard $shard of $PORTABLE_SERIAL_SHARDS is empty"
      SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")
      rm -rf "$tmp"
      return 1
    fi
    printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" >>"$tmp/serial_shards_raw"
    serial_ms=$(printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | portable_serial_lane_weight)
    [ "$serial_ms" -le "$serial_max_ms" ] || serial_max_ms=$serial_ms
    shard=$((shard + 1))
  done
  SCRIPTS=()
  select_family real-herdr-gated
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/herdr"
  SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")

  # Every serial script runs in exactly one CI shard: no duplicate work across
  # runners, and no script silently left out of the required lane.
  LC_ALL=C sort "$tmp/serial_shards_raw" | uniq -d >"$tmp/serial_shard_dups"
  if [ -s "$tmp/serial_shard_dups" ]; then
    log "coverage guard: portable serial shards share scripts:"
    cat "$tmp/serial_shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/serial_shards_raw" >"$tmp/serial_shards"
  missing=$(LC_ALL=C comm -23 "$tmp/serial" "$tmp/serial_shards" || true)
  extra=$(LC_ALL=C comm -13 "$tmp/serial" "$tmp/serial_shards" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable serial shards must equal the portable serial lane"
    [ -z "$missing" ] || { log "missing from serial shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond serial lane:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  for pair in "shards_union:serial" "shards_union:herdr" "serial:herdr"; do
    a=${pair%%:*}
    b=${pair#*:}
    LC_ALL=C comm -12 "$tmp/$a" "$tmp/$b" >"$tmp/overlap"
    if [ -s "$tmp/overlap" ]; then
      log "coverage guard: overlap between $a and $b:"
      cat "$tmp/overlap" >&2
      rm -rf "$tmp"
      return 1
    fi
  done

  cat "$tmp/shards_union" "$tmp/serial" "$tmp/herdr" | LC_ALL=C sort >"$tmp/union_raw"
  uniq -d "$tmp/union_raw" >"$tmp/union_dups"
  if [ -s "$tmp/union_dups" ]; then
    log "coverage guard: duplicate scripts across lanes:"
    cat "$tmp/union_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/union_raw" >"$tmp/union"
  missing=$(LC_ALL=C comm -23 "$tmp/all" "$tmp/union" || true)
  extra=$(LC_ALL=C comm -13 "$tmp/all" "$tmp/union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: union of portable shards + portable serial + Herdr must equal tests/*.test.sh"
    [ -z "$missing" ] || { log "missing from union:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond inventory:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Hint drift is what makes a balanced-looking partition run unbalanced: the
  # shards are packed from hints, so every unmeasured script is balanced on a
  # guess and enough of them let one shard reach its CI job cap while another
  # runner sits idle. Bound the unmeasured share here rather than waiting for a
  # shard to time out.
  portable_serial_unhinted >"$tmp/unhinted"
  unhinted=$(wc -l <"$tmp/unhinted" | tr -d ' ')
  serial_total=$(wc -l <"$tmp/serial" | tr -d ' ')
  if [ "$serial_total" -gt 0 ] &&
    [ "$((unhinted * 100))" -gt "$((serial_total * PORTABLE_SERIAL_MAX_UNHINTED_PERCENT))" ]; then
    log "coverage guard: $unhinted of $serial_total portable serial scripts have no measured duration hint (max ${PORTABLE_SERIAL_MAX_UNHINTED_PERCENT}%)"
    log "refresh the hints from a green run's timing artifacts: docs/fm-test-portable-shards.md"
    cat "$tmp/unhinted" >&2
    rm -rf "$tmp"
    return 1
  fi

  if [ "$serial_max_ms" -gt "$PORTABLE_SERIAL_MAX_WEIGHT_MS" ]; then
    log "coverage guard: largest portable serial shard packs ${serial_max_ms}ms above the ${PORTABLE_SERIAL_MAX_WEIGHT_MS}ms target"
    log "refresh CI hints and rebalance or add shards; do not raise the job timeout: docs/fm-test-portable-shards.md"
    rm -rf "$tmp"
    return 1
  fi

  if [ -x "$ROOT/bin/fm-test-isolation-proof.sh" ]; then
    "$ROOT/bin/fm-test-isolation-proof.sh" --list | LC_ALL=C sort -u >"$tmp/proof_list"
    if ! cmp -s "$tmp/proven" "$tmp/proof_list"; then
      log "coverage guard: embedded proven-isolated set diverges from bin/fm-test-isolation-proof.sh --list"
      LC_ALL=C comm -3 "$tmp/proven" "$tmp/proof_list" >&2 || true
      rm -rf "$tmp"
      return 1
    fi
  fi

  # Keep these estimates derived from the membership and hint owners; see the
  # header for the distinction between packed weights and measured job time.
  read -r p1_ms p1_unhinted <<<"$(list_portable_parallel_1 | portable_parallel_lane_weight)"
  read -r p2_ms p2_unhinted <<<"$(list_portable_parallel_2 | portable_parallel_lane_weight)"
  parallel_max_ms=$p1_ms
  [ "$p2_ms" -le "$parallel_max_ms" ] || parallel_max_ms=$p2_ms
  parallel_imbalance_ms=$((p1_ms - p2_ms))
  [ "$parallel_imbalance_ms" -ge 0 ] || parallel_imbalance_ms=$((-parallel_imbalance_ms))

  printf 'FM_TEST_COVERAGE ok total=%s parallel=%s parallel_max_ms=%s parallel_imbalance_ms=%s parallel_unhinted=%s serial=%s serial_shards=%s serial_unhinted=%s serial_max_ms=%s serial_budget_ms=%s herdr=%s\n' \
    "$(wc -l <"$tmp/all" | tr -d ' ')" \
    "$(wc -l <"$tmp/shards_union" | tr -d ' ')" \
    "$parallel_max_ms" \
    "$parallel_imbalance_ms" \
    "$((p1_unhinted + p2_unhinted))" \
    "$(wc -l <"$tmp/serial" | tr -d ' ')" \
    "$PORTABLE_SERIAL_SHARDS" \
    "$unhinted" \
    "$serial_max_ms" \
    "$PORTABLE_SERIAL_MAX_WEIGHT_MS" \
    "$(wc -l <"$tmp/herdr" | tr -d ' ')"
  rm -rf "$tmp"
  return 0
}

aggregate_timing_json() {
  local out=$1
  shift
  [ "$#" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  command -v python3 >/dev/null 2>&1 || die "--aggregate-json requires python3"
  python3 - "$out" "$@" <<'PY'
import json, sys
from pathlib import Path

out = Path(sys.argv[1])
inputs = [Path(p) for p in sys.argv[2:]]
lanes = []
all_scripts = []
failed = 0
skipped = 0
total = 0
wall_ms = 0
for path in inputs:
    doc = json.loads(path.read_text(encoding="utf-8"))
    summary = doc.get("summary") or {}
    lane = {
        "path": str(path),
        "run_id": doc.get("run_id"),
        "selection": doc.get("selection"),
        "started_at": doc.get("started_at"),
        "finished_at": doc.get("finished_at"),
        "summary": summary,
    }
    lanes.append(lane)
    total += int(summary.get("total") or 0)
    failed += int(summary.get("failed") or 0)
    skipped += int(summary.get("skipped_gate") or 0)
    wall_ms = max(wall_ms, int(summary.get("duration_ms") or 0))
    for s in doc.get("scripts") or []:
        row = dict(s)
        row["lane_selection"] = doc.get("selection")
        row["lane_run_id"] = doc.get("run_id")
        all_scripts.append(row)

all_scripts.sort(key=lambda s: (-int(s.get("duration_ms") or 0), s.get("path") or ""))
agg = {
    "kind": "aggregate",
    "lanes": lanes,
    "summary": {
        "lanes": len(lanes),
        "total": total,
        "failed": failed,
        "skipped_gate": skipped,
        "critical_path_duration_ms": wall_ms,
    },
    "scripts": all_scripts,
    "slowest": all_scripts[:15],
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(agg, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"FM_TEST_AGGREGATE lanes={len(lanes)} total={total} failed={failed} skipped_gate={skipped} critical_path_duration_ms={wall_ms}")
PY
}

all_repo_tests() {
  # Deterministic lexical order (same as bash glob expansion under LC_ALL=C).
  local f
  # shellcheck disable=SC2035
  for f in tests/*.test.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

normalize_script_path() {
  local p=$1
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    tests/*|./tests/*)
      p=${p#./}
      printf '%s\n' "$p"
      ;;
    *.test.sh)
      if [ -f "tests/$p" ]; then
        printf 'tests/%s\n' "$p"
      else
        printf '%s\n' "$p"
      fi
      ;;
    *)
      printf '%s\n' "$p"
      ;;
  esac
}

# Append unique relative-or-absolute script paths to SCRIPTS.
add_script() {
  local p existing
  p=$(normalize_script_path "$1")
  for existing in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    [ "$existing" = "$p" ] && return 0
  done
  SCRIPTS+=("$p")
}

select_all() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(all_repo_tests)
}

select_family() {
  local want=$1 s base fam found=0
  [ -n "$want" ] || die "--family requires a name"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    base=$(basename "$s")
    fam=$(family_for_basename "$base")
    if [ "$fam" = "$want" ]; then
      add_script "$s"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ] || die "no tests mapped to family '$want'"
}

families_for_test_reference() {  # <needle>...
  local s needle
  local found=0
  local -a needles=()
  for needle in "$@"; do needles+=(-e "$needle"); done
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "${needles[@]}" "$s"; then
      family_for_basename "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ]
}

# Tests that name <needle>, selected as individual scripts rather than widened
# to each referencing test's whole family. A direct reference is per-script
# evidence, so it selects per script: one real-Herdr E2E sourcing a shared
# helper must not drag in every other script of that expensive family.
scripts_for_test_reference() {  # <needle>...
  local needle s found=0
  local -a needles=()
  for needle in "$@"; do needles+=(-e "$needle"); done
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "${needles[@]}" "$s"; then
      printf '__script__:%s\n' "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ]
}

# bin/ scripts other than <needle> itself that name <needle>.
bin_consumers_of() {
  local needle=$1 b
  for b in bin/*.sh bin/backends/*.sh; do
    [ -f "$b" ] || continue
    [ "$(basename "$b")" = "$needle" ] || ! grep -Fq "$needle" "$b" || printf '%s\n' "$b"
  done
}

# An unmapped bin/ path has no curated family of its own. Its blast radius is
# the tests that name it, plus the curated families of the bin/ scripts that
# consume it. Direct test references resolve per script (above) while consumer
# scripts resolve back through the curated map, so genuine family-level
# coupling a maintainer recorded is preserved while an incidental single-script
# reference no longer selects that script's whole family.
BIN_FALLBACK_DEPTH=0
families_for_unmapped_bin() {
  local path=$1 needle consumer out found=0
  needle=$(basename "$path")
  if out=$(scripts_for_test_reference "$needle"); then
    printf '%s\n' "$out"
    found=1
  fi
  if [ "$BIN_FALLBACK_DEPTH" -lt 2 ]; then
    BIN_FALLBACK_DEPTH=$((BIN_FALLBACK_DEPTH + 1))
    while IFS= read -r consumer; do
      [ -n "$consumer" ] || continue
      out=$(families_for_changed_path "$consumer" | grep -v '^__unmapped__:' || true)
      if [ -n "$out" ]; then
        printf '%s\n' "$out"
        found=1
      fi
    done < <(bin_consumers_of "$needle")
    BIN_FALLBACK_DEPTH=$((BIN_FALLBACK_DEPTH - 1))
  fi
  [ "$found" -eq 1 ]
}

# Conservative path → family map. Over-selects rather than under-selects.
# Never expands to the complete suite.
families_for_changed_path() {
  local path=$1 fixture_ref capture_ref
  case "$path" in
    bin/fm-remote*|bin/fm-secondmate*)
      printf '%s\n' "__script__:fm-remote-inherit-generation.test.sh"
      ;;
  esac
  case "$path" in
    tests/fm-backend-herdr-eventwait.test.py)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    tests/*.test.sh)
      # A single test file change selects only that script via basename family
      # resolution in the caller; emit a marker family of __script__
      printf '%s\n' "__script__:$(basename "$path")"
      ;;
    bin/fm-test-run.sh|bin/fm-test-scratch-lib.sh)
      # Deliberately the WHOLE family, not just the two contract tests. This
      # runner executes every pure-contract-unit script, so a change to it is
      # only proven by running them: its own contract test passing says the
      # runner's logic is right, not that the suite it drives still runs.
      printf '%s\n' pure-contract-unit
      # Only this script wraps each suite in run_script_bounded's fixture Git
      # isolation, and only a standalone-family script proves it.
      printf '%s\n' "__script__:fm-test-fixtures.test.sh"
      ;;
    bin/fm-test-isolation-proof.sh)
      # Same reason as the runner above: the proof drives every
      # pure-contract-unit script. It runs each candidate directly, never
      # through run_script_bounded, so it cannot regress fixture Git isolation.
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-test-tap-verify.sh)
      printf '%s\n' "__script__:fm-test-tap-verify.test.sh"
      ;;
    bin/fm-test-linux.sh|tests/linux/Dockerfile)
      printf '%s\n' "__script__:fm-test-linux.test.sh"
      ;;
    bin/backends/herdr*|bin/fm-herdr-lab.sh|tests/herdr-test-safety.sh|tests/herdr-client-pair-fixture.sh)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-herdr-session-cleanup.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/zellij*|tests/zellij-test-safety.sh)
      printf '%s\n' zellij
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/cmux*|tests/cmux-test-safety.sh)
      printf '%s\n' cmux
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/paseo*)
      printf '%s\n' paseo
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/rex*|bin/fm-rex-marks.sh|tests/rex-test-safety.sh)
      printf '%s\n' rex
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/tern*|tests/tern-test-safety.sh)
      printf '%s\n' tern
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/hc.sh|bin/fm-hc-lab.sh|tests/hc-test-safety.sh)
      printf '%s\n' hc
      printf '%s\n' backend-dispatch
      printf '%s\n' "__script__:fm-backend-hc-liveness-live-e2e.test.sh"
      ;;
    bin/fm-install-hc.sh|bin/fm-hc-ci-cleanup.sh)
      printf '%s\n' pure-contract-unit
      # Pin or cleanup changes also select the hc family so the real lane's
      # coverage re-runs, mirroring the real-herdr-gated arm above.
      printf '%s\n' hc
      ;;
    bin/backends/orca*|bin/backends/tmux.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' orca
      ;;
    bin/backends/t3code*|bin/fm-t3-mcp.mjs)
      printf '%s\n' backend-dispatch
      families_for_unmapped_bin "$path" || true
      ;;
    tests/t3-fake-*)
      families_for_test_reference "$(basename "$path")" t3-fake-lib.sh \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    bin/fm-backend.sh|bin/fm-backend-hometag-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-agent-process-lib.sh)
      # The shared harness-process classifier feeds both the tmux and Herdr
      # liveness verdicts, so a change to it is proven by both backends' suites.
      printf '%s\n' backend-dispatch
      printf '%s\n' real-herdr-gated
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-watch*|bin/fm-classify-lib.sh)
      printf '%s\n' watcher-wake-lock
      printf '%s\n' "__script__:fm-backend-t3code.test.sh"
      ;;
    bin/fm-wake*|bin/fm-inactive-reconcile.sh|\
    bin/fm-daemon*|bin/fm-turnend-guard*|bin/fm-guard.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    bin/fm-afk*)
      printf '%s\n' afk
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-supervision-host.sh|bin/fm-supervision-handoff.sh|bin/fm-supervision-engine-lib.sh|\
    bin/fm-branch-report.sh|bin/fm-branch-dispatch.mjs)
      # The supervision host and its parts: its own suite and live guard, plus
      # the Claude Stop hook that runs it.
      printf '%s\n' afk
      printf '%s\n' "__script__:fm-claude-stop-autoarm.test.sh"
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-supervisor-target-lib.sh)
      printf '%s\n' watcher-wake-lock
      printf '%s\n' real-herdr-gated
      printf '%s\n' live-harness-optin
      printf '%s\n' afk
      ;;
    bin/fm-startup-memory-budget.sh|bin/fm-startup-memory-budget-lib.sh)
      printf '%s\n' secondmate
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-secondmate*)
      printf '%s\n' secondmate
      printf '%s\n' "__script__:fm-backend-t3code.test.sh"
      ;;
    bin/fm-remote*|bin/fm-on.sh|bin/fm-home-seed.sh|\
    bin/fm-backlog-handoff.sh|bin/fm-backlog-receive.sh|bin/fm-procevent-remote-reply.sh|\
    bin/fm-config-inherit-lib.sh|bin/fm-config-push.sh|bin/fm-shared*|\
    bin/fm-stow-cascade.sh)
      printf '%s\n' secondmate
      ;;
    bin/fm-session-start.sh|bin/fm-fleet-sync.sh|\
    bin/fm-sessionstart-nudge.sh|bin/fm-startup-network.sh|bin/fm-tangle*|bin/fm-update.sh|\
    bin/fm-gate-refuse*|bin/fm-lock*)
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-bootstrap.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' "__script__:fm-brief.test.sh"
      ;;
    bin/fm-quota-axi-lib.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' "__script__:fm-procevent-quota.test.sh"
      printf '%s\n' "__script__:fm-quota-choose.test.sh"
      printf '%s\n' "__script__:fm-dispatch-resolve.test.sh"
      printf '%s\n' "__script__:fm-claude-account-quota.test.sh"
      ;;
    bin/fm-procevent-quota.sh)
      printf '%s\n' "__script__:fm-procevent-quota.test.sh"
      ;;
    bin/fm-quota-choose.sh)
      printf '%s\n' "__script__:fm-quota-choose.test.sh"
      ;;
    bin/fm-claude-account-quota.sh)
      printf '%s\n' "__script__:fm-claude-account-quota.test.sh"
      ;;
    bin/fm-dispatch-resolve.sh)
      printf '%s\n' "__script__:fm-dispatch-resolve.test.sh"
      ;;
    bin/fm-capacity.sh)
      printf '%s\n' "__script__:fm-capacity.test.sh"
      printf '%s\n' "__script__:fm-capacity-auto.test.sh"
      printf '%s\n' "__script__:fm-project-capacity.test.sh"
      printf '%s\n' "__script__:fm-lane-capacity-integration.test.sh"
      ;;
    bin/fm-lane-vitals-lib.sh)
      printf '%s\n' "__script__:fm-lane-vitals.test.sh"
      printf '%s\n' "__script__:fm-capacity-auto.test.sh"
      printf '%s\n' "__script__:fm-lane-capacity-integration.test.sh"
      ;;
    bin/fm-env-lib.sh)
      # The one .env accessor, sourced by bin/fm-x-lib.sh (Relay token) and
      # bin/fm-dispatch-resolve.sh (TYPESAFE_API_KEY).
      printf '%s\n' pr-forge
      printf '%s\n' "__script__:fm-dispatch-resolve.test.sh"
      ;;
    .pi/extensions/fm-primary-read-repetition.ts|.pi/extensions/lib/fm-primary-read-repetition-policy.ts|tests/fixtures/fm-read-repetition-sdk.mjs|tests/fixtures/fm-read-repetition-live.mjs)
      printf '%s\n' __script__:fm-read-repetition.test.sh
      printf '%s\n' __script__:fm-read-repetition-live.test.sh
      printf '%s\n' __script__:fm-pi-primary-types.test.sh
      ;;
    tests/fixtures/fm-claude-request-capture.py)
      printf '%s\n' __script__:fm-claude-tool-exclude-live.test.sh
      ;;
    tests/fixtures/fm-claude-refusal.py)
      printf '%s\n' __script__:fm-claude-safeguard-live.test.sh
      ;;
    .pi/extensions/fm-branch-supervision.ts|.pi/extensions/lib/fm-async-exec.ts|\
    .pi/extensions/lib/fm-branch-dispatch.ts|.pi/extensions/lib/fm-native-contract.ts)
      # The portable suites that actually load these files, named one by one.
      # Left unmapped, a Pi extension library resolves through the reference
      # scan, which widens to each referencing suite's WHOLE family - and
      # these suites sit in four different families, so that pulls in dozens
      # of suites with nothing to do with Pi.
      printf '%s\n' __script__:fm-pi-branch-extension.test.sh
      printf '%s\n' __script__:fm-pi-watch-extension.test.sh
      printf '%s\n' __script__:fm-calm-pi-extension.test.sh
      printf '%s\n' __script__:fm-watch-recovery-loop.test.sh
      printf '%s\n' __script__:fm-wake-queue.test.sh
      printf '%s\n' __script__:fm-pi-primary-types.test.sh
      printf '%s\n' __script__:fm-supervision-host.test.sh
      printf '%s\n' __script__:fm-supervision-host-drain.test.sh
      printf '%s\n' __script__:fm-supervision-host-hook.test.sh
      printf '%s\n' __script__:fm-supervision-host-park.test.sh
      # Whether an arriving outcome still lets the captain type is a fact only
      # a real Pi TUI can answer, so the live guards are selected too.
      printf '%s\n' live-harness-optin
      ;;
    .pi/extensions/lib/fm-operational-input.ts)
      # The same rule for the operational-input library, whose reach is wider:
      # every Pi extension that classifies or encodes operational text.
      printf '%s\n' __script__:fm-pi-windows-shell-invocation.test.sh
      printf '%s\n' __script__:fm-pi-branch-extension.test.sh
      printf '%s\n' __script__:fm-pi-watch-extension.test.sh
      printf '%s\n' __script__:fm-calm-pi-extension.test.sh
      printf '%s\n' __script__:fm-watch-recovery-loop.test.sh
      printf '%s\n' __script__:fm-turnend-guard.test.sh
      printf '%s\n' __script__:fm-sessionstart-nudge.test.sh
      printf '%s\n' __script__:fm-pi-primary-types.test.sh
      printf '%s\n' live-harness-optin
      ;;
    .claude/mods/firstmate-calm/*|.pi/extensions/lib/fm-calm-working-ship.ts|\
    .pi/extensions/lib/fm-calm-working-ship-sprite.ts)
      # The Claude Code Calm mod and the sprite core it shares with the Pi Calm
      # extension: the portable Node checks, the Pi suites that draw the shared
      # sprite, the Pi typecheck, and the Claude-dependent guards.
      printf '%s\n' __script__:fm-calm-claude-mod.test.sh
      printf '%s\n' __script__:fm-calm-pi-extension.test.sh
      printf '%s\n' __script__:fm-pi-primary-types.test.sh
      printf '%s\n' live-harness-optin
      ;;
    .agents/hooks.json|bin/fm-sessionstart-agy.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' watcher-wake-lock
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-sessionstart-run.sh|.claude/settings.json|.codex/hooks.json|\
    .pi/extensions/fm-primary-turnend-guard.ts)
      # The run tier's two harness-supplied facts (source vocabulary and
      # context-reset stdout injection) only show up against a real harness.
      printf '%s\n' __script__:fm-pi-windows-shell-invocation.test.sh
      printf '%s\n' session-bootstrap
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-extension*.mjs|bin/fm-extension.sh|docs/examples/process-event-extension/*)
      printf '%s\n' __script__:fm-extension-binding.test.sh
      printf '%s\n' __script__:fm-procevent-extension-errors.test.sh
      ;;
    bin/fm-procevent-diagnostic-stderr.pl|tests/extension-binding-diagnostics.py)
      printf '%s\n' __script__:fm-extension-binding.test.sh
      printf '%s\n' __script__:fm-procevent.test.sh
      ;;
    bin/fm-procevent.sh|bin/fm-procevent-lib.sh|bin/fm-procevent-extension-capture.pl)
      printf '%s\n' __script__:fm-extension-binding.test.sh
      printf '%s\n' __script__:fm-procevent-extension-errors.test.sh
      printf '%s\n' __script__:fm-procevent.test.sh
      printf '%s\n' __script__:fm-procevent-when.test.sh
      printf '%s\n' __script__:fm-remote-reply.test.sh
      ;;
    bin/fm-timeout-lib.sh)
      # The shared hard bound: session start's runtime bound, the fleet/bearings
      # snapshots, the vendor auth probe, the stow cascade's per-home step, and
      # the wedge detector's worktree write probe all depend on it.
      printf '%s\n' session-bootstrap
      printf '%s\n' snapshot-bearings
      printf '%s\n' pure-contract-unit
      printf '%s\n' secondmate
      printf '%s\n' watcher-wake-lock
      printf '%s\n' "__script__:fm-procevent-quota.test.sh"
      ;;
    bin/fm-teardown.sh)
      printf '%s\n' pr-forge
      printf '%s\n' "__script__:fm-backend-t3code.test.sh"
      ;;
    bin/fm-pr-*|bin/fm-merge-local.sh|bin/fm-review-diff.sh|\
    bin/fm-x-*|bin/fm-check*|bin/fm-pipeline-spend.sh)
      printf '%s\n' pr-forge
      ;;
    bin/fm-nm-run-lib.sh)
      # Shared no-mistakes run-attribution primitives, sourced by
      # bin/fm-crew-state.sh (pure-contract-unit), bin/fm-teardown.sh's
      # pre-teardown run abort (pr-forge), and bin/fm-rex-marks.sh's
      # validation progress (rex).
      printf '%s\n' pure-contract-unit
      printf '%s\n' pr-forge
      printf '%s\n' rex
      ;;
    bin/fm-control-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' session-bootstrap
      printf '%s\n' "__script__:fm-quota-choose.test.sh"
      ;;
    bin/fm-composer-lib.sh)
      # The shared shape catalogue is vendor-rendered signal; a change to it
      # re-selects the live guard (fm-composer-matrix-live-e2e) alongside the
      # portable families.
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-spawn.sh|bin/fm-send.sh|bin/fm-harness.sh|\
    bin/fm-peek.sh|bin/fm-composer*)
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-kimi-trust-lib.sh)
      # Kimi's folder-prompt predicates are vendor-rendered signal: the Kimi
      # suite replays recorded prompts, and the live guard
      # (fm-kimi-trust-prompt-live-e2e) asks the installed binary.
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-task-inbox-lib.sh)
      # The steering-inbox record/doorbell/ladder owner: fm-send's data plane
      # (backend-dispatch), the watcher's re-ring check (watcher-wake-lock),
      # and the live doorbell guard against real harnesses.
      printf '%s\n' backend-dispatch
      printf '%s\n' watcher-wake-lock
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-bearings-snapshot.sh|bin/fm-fleet-snapshot.sh|bin/fm-fleet-view.sh|bin/fm-contributions.sh|bin/fm-contributions.jq|\
    bin/fm-home-summary-refresh.sh)
      printf '%s\n' snapshot-bearings
      ;;
    bin/fm-install-herdr.sh|bin/fm-install-treehouse.sh|bin/fm-herdr-ci-cleanup.sh)
      printf '%s\n' pure-contract-unit
      # Pin or cleanup changes also select the real-Herdr family so the required
      # lane's contract coverage re-runs.
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-lint.sh|bin/fm-lint-workflows.sh|bin/fm-install-shellcheck.sh|\
    bin/fm-install-actionlint.sh|\
    bin/fm-brief.sh|bin/fm-ensure-agents-md.sh|bin/fm-crew-state.sh|\
    bin/fm-captain-hold.sh|bin/fm-hold-reason-lib.sh|bin/fm-decision-hold.sh|bin/fm-supervision*|bin/fm-transition-lib.sh|\
    bin/fm-tmux-lib.sh|bin/fm-marker-lib.sh|bin/fm-operational-input.sh|bin/fm-tasks-axi-lib.sh|\
    bin/fm-vendor-auth-probe.sh|\
    bin/fm-primary-scope-lib.sh|bin/fm-project-mode.sh|bin/fm-forge-detect.sh|bin/fm-promote.sh|\
    bin/fm-ff-lib.sh|bin/fm-gotmp*|bin/*pretool*)
      printf '%s\n' pure-contract-unit
      ;;
    .agents/skills/quota-array-dispatch/SKILL.md)
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    .agents/skills/harness-adapters/SKILL.md|.agents/skills/harness-adapters/references/*)
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    .agents/skills/lavish-url/assets/*|.agents/skills/lavish-url/enhancers/*)
      # The layers bin/fm-lavish-url.sh injects into every snapshot.
      printf '%s\n' "__script__:fm-lavish-url.test.sh"
      ;;
    .agents/skills/*/SKILL.md)
      printf '%s\n' pure-contract-unit
      ;;
    .github/workflows/ci.yml|.no-mistakes.yaml)
      printf '%s\n' pure-contract-unit
      printf '%s\n' real-herdr-gated
      ;;
    docs/fm-test-portable-shards.md|docs/fm-test-isolation-proof.md|\
    docs/fm-test-isolation-proof.json)
      printf '%s\n' pure-contract-unit
      ;;
    .github/*|.gitattributes|.tasks.toml|AGENTS.md|CLAUDE.md|CONTRIBUTING.md|\
    docs/configuration.md|docs/supervision-protocols/*)
      printf '%s\n' pure-contract-unit
      ;;
    tests/remote-secondmate-source-copy-helpers.sh)
      scripts_for_test_reference remote-secondmate-source-copy-helpers.sh remote-secondmate-lifecycle-fixture.sh \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    tests/git-config-helpers.sh)
      # The reference scan is not transitive, so match the two helpers that
      # source this one as well: most suites inherit it only through them.
      families_for_test_reference git-config-helpers.sh lib.sh herdr-test-safety.sh \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    tests/fixtures/*/*)
      # A fixture belongs to whichever suite reads its directory, found by the
      # same reference scan used for shared helpers. Keyed on the directory
      # rather than the file so adding a fixture selects the same suite.
      # A removed fixture directory has no consuming suite left to select.
      fixture_ref=${path#tests/fixtures/}
      fixture_ref=${fixture_ref%%/*}
      if [ -d "tests/fixtures/$fixture_ref" ]; then
        families_for_test_reference "fixtures/$fixture_ref" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    tests/captures/*/*)
      # A recorded capture selects the suites that read its directory, by the
      # same rule as a fixture directory.
      capture_ref=${path#tests/captures/}
      capture_ref=${capture_ref%%/*}
      if [ -d "tests/captures/$capture_ref" ]; then
        families_for_test_reference "captures/$capture_ref" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    tests/lib.sh|tests/*-helpers.sh|tests/fixtures.sh|tests/*-fixture.sh)
      # Shared top-level test files, selected by the suites that name them.
      # Must stay below the tests/fixtures/*/* arm: a case glob's * spans /, so
      # tests/*-fixture.sh would otherwise swallow a nested
      # tests/fixtures/<dir>/<name>-fixture.sh and scan for its basename
      # instead of the fixture directory its readers actually name.
      families_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    bin/*)
      # A deleted script has no consuming suite left to select, the same rule
      # the fixture case above applies. Refusing on its absent mapping would
      # make every retirement branch unable to select its changed tests.
      if [ -e "$path" ]; then
        families_for_unmapped_bin "$path" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    tests/*)
      printf '%s\n' "__unmapped__:$path"
      ;;
    README.md|LICENSE|assets/*|docs/*|.gitignore)
      ;;
    *)
      if [ -e "$path" ]; then
        families_for_test_reference "$path" \
          || printf '%s\n' "__unmapped__:$path"
      else
        # A retired source path with no remaining test consumer cannot select
        # a runnable suite. Known source paths above retain their mappings,
        # and a still-referenced removal is found by the same reference scan.
        families_for_test_reference "$path" || true
      fi
      ;;
  esac
}

select_changed() {
  local base=$1 path entry fam script_name s
  local -a wanted_families=()
  local -a wanted_scripts=()

  if ! git -C "$ROOT" rev-parse --verify "$base" >/dev/null 2>&1; then
    die "changed-file base ref not found: $base (pass --base <ref>)"
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$entry" in
        __script__:*)
          script_name=${entry#__script__:}
          wanted_scripts+=("$script_name")
          ;;
        __unmapped__:*)
          die "no changed-test mapping for source path: ${entry#__unmapped__:}"
          ;;
        *)
          wanted_families+=("$entry")
          ;;
      esac
    done < <(families_for_changed_path "$path")
  done < <(git -C "$ROOT" diff --name-only "${base}...HEAD" 2>/dev/null; \
           git -C "$ROOT" diff --name-only HEAD 2>/dev/null; \
           git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)

  # Dedup families
  local f seen_f
  local -a unique_families=()
  for f in "${wanted_families[@]+"${wanted_families[@]}"}"; do
    seen_f=0
    for u in "${unique_families[@]+"${unique_families[@]}"}"; do
      [ "$u" = "$f" ] && { seen_f=1; break; }
    done
    [ "$seen_f" -eq 0 ] && unique_families+=("$f")
  done

  for f in "${unique_families[@]+"${unique_families[@]}"}"; do
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if [ "$(family_for_basename "$(basename "$s")")" = "$f" ]; then
        add_script "$s"
      fi
    done < <(all_repo_tests)
  done

  for script_name in "${wanted_scripts[@]+"${wanted_scripts[@]}"}"; do
    if [ -f "tests/$script_name" ]; then
      add_script "tests/$script_name"
    fi
  done

  if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    log "no tests selected for changes vs $base (map is conservative; use --all for the complete suite)"
  fi
}

detect_gate_skip() {
  # True when the first non-empty output line is a skip: gate message.
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  case "$first" in
    skip:*) return 0 ;;
    *) return 1 ;;
  esac
}

# Echo the reason a gate skip gave, i.e. the first meaningful output line with
# its leading "skip:" removed. Tabs and stray whitespace are folded so the
# reason stays one field of the tab-separated record the JSON artifact is built
# from. Callers only use this once detect_gate_skip has already said yes.
gate_skip_reason() {
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  first=${first#skip:}
  printf '%s\n' "$first" | tr '\t' ' ' | sed -e 's/^ *//' -e 's/ *$//'
}

# True when any output line contains "skip: <token>" (token may contain spaces).
detect_gate_skip_token() {
  local file=$1 token=$2
  [ -n "$token" ] || return 1
  grep -F -q "skip: $token" "$file" 2>/dev/null
}

apply_exclude_families() {
  local s fam keep ex
  local -a kept=()
  [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ] || return 0
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    fam=$(family_for_basename "$(basename "$s")")
    keep=1
    for ex in "${EXCLUDE_FAMILIES[@]+"${EXCLUDE_FAMILIES[@]}"}"; do
      if [ "$fam" = "$ex" ]; then
        keep=0
        break
      fi
    done
    [ "$keep" -eq 1 ] && kept+=("$s")
  done
  SCRIPTS=("${kept[@]+"${kept[@]}"}")
}

write_json_artifact() {
  local out=$1
  local started=$2
  local finished=$3
  local run_id=$4
  local total=$5
  local failed=$6
  local skipped=$7
  local duration=$8
  local selection=$9
  local records_file=${10}
  local families_file=${11}

  if ! command -v python3 >/dev/null 2>&1; then
    die "--json requires python3 to emit a valid timing artifact"
  fi

  python3 - "$out" "$started" "$finished" "$run_id" "$total" "$failed" "$skipped" "$duration" "$selection" "$records_file" "$families_file" <<'PY'
import json, sys

out, started, finished, run_id, total, failed, skipped, duration, selection, records_file, families_file = sys.argv[1:]

scripts = []
with open(records_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        path, family, expected, exit_s, dur_s, gate, reason = line.split("\t")
        scripts.append({
            "path": path,
            "family": family,
            "expected_gate_skip": expected,
            "duration_ms": int(dur_s),
            "exit": int(exit_s),
            "gate_skip": gate == "true",
            "gate_skip_reason": reason,
        })

families = []
with open(families_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        name, count_s, dur_s, failed_s = line.split("\t")
        families.append({
            "name": name,
            "count": int(count_s),
            "duration_ms": int(dur_s),
            "failed": int(failed_s),
        })

doc = {
    "run_id": run_id,
    "started_at": started,
    "finished_at": finished,
    "selection": selection,
    "summary": {
        "total": int(total),
        "failed": int(failed),
        "skipped_gate": int(skipped),
        "duration_ms": int(duration),
    },
    "scripts": scripts,
    "families": families,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

# Compare ancestors by identity as well as using physical paths: macOS and
# Windows can resolve case variants to the same directory.
check_scratch_placement() {
  local base=$1 blocked ancestor checkout
  checkout=$(git rev-parse --show-toplevel 2>/dev/null) || checkout=$ROOT
  for blocked in "$ROOT" "$checkout" "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" \
    "$HOME/.firstmate-preserved" "$HOME/.treehouse" "${TREEHOUSE_ROOT:-}"; do
    [ -n "$blocked" ] || continue
    ancestor=$base
    while :; do
      if [ "$ancestor" = "${blocked%/}" ] || [ "$ancestor" -ef "$blocked" ]; then
        die "unsafe scratch base $base resolves inside $blocked"
      fi
      [ "$ancestor" != / ] || break
      ancestor=${ancestor%/*}
      ancestor=${ancestor:-/}
    done
  done
}

scratch_base() {
  local base
  base=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || base=/tmp
  case "$base" in /*) ;; *) die "scratch base must be absolute: $base" ;; esac
  base=$(cd -P -- "$base" && pwd -P) || die 'cannot resolve scratch base'
  check_scratch_placement "$base"
  printf '%s\n' "$base"
}

if [ "$#" -eq 1 ] && [ "$1" = --scratch-base ]; then
  scratch_base
  exit $?
fi
for arg in "$@"; do
  [ "$arg" != --scratch-base ] || die '--scratch-base must be used alone'
done

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=all
      shift
      ;;
    --family)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--family requires a name"
      MODE=family
      FAMILY=$2
      shift 2
      ;;
    --family=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=family
      FAMILY=${1#--family=}
      shift
      ;;
    --lane)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--lane requires a name (see --list-lanes)"
      MODE=lane
      LANE=$2
      shift 2
      ;;
    --lane=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=lane
      LANE=${1#--lane=}
      shift
      ;;
    --proven-isolated)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=proven-isolated
      shift
      ;;
    --changed)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=changed
      shift
      ;;
    --base)
      [ "$#" -gt 1 ] || die "--base requires a git ref"
      BASE_REF=$2
      shift 2
      ;;
    --base=*)
      BASE_REF=${1#--base=}
      shift
      ;;
    --json)
      [ "$#" -gt 1 ] || die "--json requires a path"
      JSON_PATH=$2
      shift 2
      ;;
    --json=*)
      JSON_PATH=${1#--json=}
      shift
      ;;
    --jobs)
      [ "$#" -gt 1 ] || die "--jobs requires a positive integer"
      JOBS=$2
      JOBS_EXPLICIT=1
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#--jobs=}
      JOBS_EXPLICIT=1
      shift
      ;;
    --max-wall-ms)
      [ "$#" -gt 1 ] || die "--max-wall-ms requires a positive integer"
      MAX_WALL_MS=$2
      shift 2
      ;;
    --max-wall-ms=*)
      MAX_WALL_MS=${1#--max-wall-ms=}
      shift
      ;;
    --per-script-timeout-secs)
      [ "$#" -gt 1 ] || die "--per-script-timeout-secs requires a whole number of seconds"
      PER_SCRIPT_TIMEOUT_SECS=$2
      shift 2
      ;;
    --per-script-timeout-secs=*)
      PER_SCRIPT_TIMEOUT_SECS=${1#--per-script-timeout-secs=}
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --list-scheduled)
      LIST_SCHEDULED=1
      shift
      ;;
    --list-families)
      LIST_FAMILIES=1
      shift
      ;;
    --list-concurrent-safe-families)
      LIST_CONCURRENT_SAFE_FAMILIES=1
      shift
      ;;
    --concurrent-safe-family-jobs-max)
      [ "$#" -gt 1 ] || die "--concurrent-safe-family-jobs-max requires a family name"
      concurrent_safe_family_jobs_max "$2"
      exit 0
      ;;
    --concurrent-safe-family-jobs-max=*)
      concurrent_safe_family_jobs_max "${1#--concurrent-safe-family-jobs-max=}"
      exit 0
      ;;
    --list-lanes)
      LIST_LANES=1
      shift
      ;;
    --check-coverage)
      CHECK_COVERAGE=1
      shift
      ;;
    --aggregate-json)
      [ "$#" -gt 1 ] || die "--aggregate-json requires an output path"
      AGGREGATE_OUT=$2
      shift 2
      # Remaining args after options will be collected as inputs below via MODE.
      # For aggregation we accept only input JSON paths as free args after this.
      MODE=aggregate
      ;;
    --exclude-family)
      [ "$#" -gt 1 ] || die "--exclude-family requires a name"
      EXCLUDE_FAMILIES+=("$2")
      shift 2
      ;;
    --exclude-family=*)
      EXCLUDE_FAMILIES+=("${1#--exclude-family=}")
      shift
      ;;
    --fail-on-gate-skip)
      [ "$#" -gt 1 ] || die "--fail-on-gate-skip requires a token (e.g. 'herdr not found')"
      FAIL_ON_GATE_SKIP=$2
      shift 2
      ;;
    --fail-on-gate-skip=*)
      FAIL_ON_GATE_SKIP=${1#--fail-on-gate-skip=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        SCRIPTS+=("$1")
        shift
      done
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ "${MODE:-}" = "aggregate" ]; then
        SCRIPTS+=("$1")
      elif [ -z "$MODE" ] || [ "$MODE" = scripts ]; then
        MODE=scripts
        SCRIPTS+=("$1")
      else
        die "script paths cannot be combined with --$MODE"
      fi
      shift
      ;;
  esac
done

if [ "$LIST_FAMILIES" -eq 1 ]; then
  list_known_families
  exit 0
fi

if [ "$LIST_CONCURRENT_SAFE_FAMILIES" -eq 1 ]; then
  list_concurrent_safe_families
  exit 0
fi

if [ "$LIST_LANES" -eq 1 ]; then
  list_known_lanes
  exit 0
fi

run_owner_start() (
  [ -r "$ROOT/bin/fm-wake-lib.sh" ] && [ -r "$ROOT/bin/fm-path-lib.sh" ] || return 1
  FM_STATE_OVERRIDE=$RUN_TMP
  unset FM_PROC_ROOT_OVERRIDE
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh" || return 1
  fm_pid_start_time "$1"
)

record_run_owner() {
  local pid=$1 group=${2:-0} marker=${3:-$RUN_TMP/.fm-test-run-owner} start
  start=$(run_owner_start "$pid") || start=unknown
  printf '%s|%s|%s|%s\n' "$UID" "$pid" "$group" "$start" >>"$marker"
}

run_owners_gone() {
  local marker=$1 snapshot=$2 owner pid group start extra current found=0
  while IFS='|' read -r owner pid group start extra; do
    [ "$owner" = "$UID" ] && [ -z "$extra" ] || return 1
    case "$pid" in ''|0*|*[!0-9]*) return 1 ;; esac
    case "$group" in ''|*[!0-9]*) return 1 ;; esac
    case "$start" in ''|unknown) return 1 ;; esac
    if [ "$group" -ne 0 ]; then
      awk -v group="$group" '$2 == group && $3 !~ /^Z/ { live = 1 } END { exit live }' \
        <<<"$snapshot" || return 1
    fi
    if awk -v pid="$pid" '$1 == pid && $3 !~ /^Z/ { live = 1 } END { exit !live }' <<<"$snapshot"; then
      current=$(run_owner_start "$pid") || return 1
      case "$start|$current" in
        proc-starttime=*\|proc-starttime=*) ;;
        *proc-starttime=*) return 1 ;;
        *) ;;
      esac
      [ "$start" != "$current" ] || return 1
    fi
    found=1
  done <"$marker"
  [ "$found" -eq 1 ] && [ -z "$owner$pid$group$start$extra" ]
}

reap_orphan_runs() {
  local parent=$1 dir marker snapshot timed
  run_owner_start "$$" >/dev/null || return 0
  for dir in "$parent"/r.??????; do
    marker="$dir/.fm-test-run-owner"
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || continue
    [ -f "$marker" ] && [ ! -L "$marker" ] && [ -O "$marker" ] || continue
    [ -n "$(find "$marker" -prune -mmin +1 -print)" ] || continue
    snapshot=$(LC_ALL=C ps -e -o pid= -o pgid= -o stat= 2>/dev/null) || return 0
    awk -v pid="$$" '
      NF != 3 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { invalid = 1 }
      $1 == pid { found = 1 }
      END { exit (invalid || !found) }
    ' <<<"$snapshot" || return 0
    run_owners_gone "$marker" "$snapshot" || continue
    for timed in "$dir"/w*/timed-owner; do
      [ -e "$timed" ] || continue
      [ -f "$timed" ] && [ ! -L "$timed" ] && [ -O "$timed" ] || continue 2
      run_owners_gone "$timed" "$snapshot" || continue 2
    done
    compgen -G "$dir/.retain-scratch.??????" >/dev/null && continue
    fm_test_remove_tree "$dir" || true
  done
}

RUN_TMP=
RUN_INTERRUPT=0
RUN_CRITICAL=0
WORKER_PIDS=()
WORKER_SCRIPTS=()
KEEP_RUN_TMP=0

# Traps defer exit only while publishing an allocation or a background PID.
# shellcheck disable=SC2329
interrupt_run() {
  RUN_INTERRUPT=$1
  [ "$RUN_CRITICAL" -ne 0 ] || exit "$RUN_INTERRUPT"
}

owned_group_live() {
  local pid=$1 start=$2 current snapshot
  kill -0 -- "-$pid" 2>/dev/null || return 1
  current=$(run_owner_start "$pid") || current=
  if [ -n "$current" ]; then
    [ "$start" != unknown ] || return 2
    [ "$current" = "$start" ] || return 1
  fi
  if snapshot=$(LC_ALL=C ps -e -o pid= -o pgid= -o stat= 2>/dev/null); then
    awk -v self="$$" -v pid="$pid" -v start="$start" -v checked="$current" '
      $1 == self && NF == 3 { readable = 1 }
      $2 == pid && $3 !~ /^Z/ { live = 1 }
      END {
        if (!readable) exit 2
        if (!live) exit 1
        exit (start == "unknown" || checked == "") ? 2 : 0
      }
    ' <<<"$snapshot"
  else
    [ -n "$current" ] || return 2
  fi
}

group_members() {
  LC_ALL=C ps -e -o pid= -o pgid= -o stat= 2>/dev/null |
    awk -v group="$1" '$2 == group && $1 ~ /^[1-9][0-9]*$/ && $3 !~ /^Z/ { print $1 }'
}

group_member_identities() {
  local pid identity
  for pid in $(group_members "$1"); do
    if identity=$(run_owner_start "$pid"); then printf '%s|%s\n' "$pid" "$identity"; fi
  done
}

group_has_continuity() {
  local group=$1 identities=$2 members pid identity current
  members=$'\n'$(group_members "$group")$'\n'
  while IFS='|' read -r pid identity; do
    [[ "$members" == *$'\n'"$pid"$'\n'* ]] || continue
    current=$(run_owner_start "$pid") || continue
    [ "$identity" != "$current" ] || return 0
  done <<<"$identities"
  return 1
}

stop_owned_workers() {
  local slot work pid record owner group start extra rc i attempt members drained=0
  local -a records=() groups=() starts=() witnesses=()
  for slot in "$@"; do
    work="$RUN_TMP/w$slot"
    pid=${WORKER_PIDS[$slot]:-}
    : >"$work/stopping"
    if [ -n "$pid" ]; then
      record=$(awk -F '|' -v pid="$pid" '$2 == pid && $3 == pid { print; exit }' "$RUN_TMP/.fm-test-run-owner")
      if [ -n "$record" ]; then records+=("$record"); fi
    fi
    if [ -f "$work/timed-owner" ] && IFS= read -r record <"$work/timed-owner"; then
      records+=("$record")
    fi
  done
  for record in "${records[@]+"${records[@]}"}"; do
    IFS='|' read -r owner pid group start extra <<<"$record"
    [ "$owner" = "$UID" ] && [ "$pid" = "$group" ] && [ -n "$start" ] && [ -z "$extra" ] || continue
    case "$group" in ''|0*|*[!0-9]*) continue ;; esac
    rc=0
    owned_group_live "$group" "$start" || rc=$?
    case "$rc" in
      0|2)
        groups+=("$group"); starts+=("$start")
        members=
        if [ "$rc" -eq 0 ]; then
          members=$(group_member_identities "$group")
          members=${members:-$group|$start}
          if ! owned_group_live "$group" "$start" || ! kill -TERM -- "-$group" 2>/dev/null; then members=; fi
        fi
        witnesses+=("$members")
        ;;
    esac
  done
  if [ "${#groups[@]}" -gt 0 ]; then
    sleep 0.2
    for i in "${!groups[@]}"; do
      if [ -n "${witnesses[$i]}" ] && { owned_group_live "${groups[$i]}" "${starts[$i]}" ||
          group_has_continuity "${groups[$i]}" "${witnesses[$i]}"; }; then
        kill -KILL -- "-${groups[$i]}" 2>/dev/null || true
      fi
    done
    for i in "${!groups[@]}"; do
      for ((attempt=0; attempt<20; ++attempt)); do
        rc=0
        owned_group_live "${groups[$i]}" "${starts[$i]}" || rc=$?
        [ "$rc" -ne 1 ] || break
        sleep 0.01
      done
      [ "$rc" -eq 1 ] || drained=1
    done
  fi
  [ "$drained" -eq 0 ] || return 1
  for slot in "$@"; do
    pid=${WORKER_PIDS[$slot]:-}
    if [ -n "$pid" ]; then wait "$pid" 2>/dev/null || true; fi
  done
}

# shellcheck disable=SC2329
cleanup_run() {
  local status=$?
  trap '' HUP INT QUIT TERM
  stop_owned_workers "${!WORKER_PIDS[@]}" || KEEP_RUN_TMP=1
  if [ "$KEEP_RUN_TMP" -eq 1 ]; then
    log "could not confirm worker group exit; retaining scratch: $RUN_TMP"
    [ "$status" -ne 0 ] || status=1
    exit "$status"
  fi
  if [ -n "$RUN_TMP" ]; then
    if compgen -G "$RUN_TMP/.retain-scratch.??????" >/dev/null; then
      log "private teardown unverified; retaining scratch: $RUN_TMP"
      [ "$status" -ne 0 ] || status=1
      exit "$status"
    fi
    fm_test_remove_tree "$RUN_TMP"
  fi
}

prepare_run_scratch() {
  # shellcheck source=bin/fm-test-scratch-lib.sh
  . "$ROOT/bin/fm-test-scratch-lib.sh"
  local base parent mode
  base=$(scratch_base) || exit "$?"
  parent="${base%/}/fm$UID"
  check_scratch_placement "$parent"
  (umask 077; mkdir -- "$parent") 2>/dev/null || true
  [ -d "$parent" ] && [ ! -L "$parent" ] && [ -O "$parent" ] \
    || die "scratch directory is not an owned, real directory: $parent"
  if worker_root_mode_is_enforceable; then
    mode=$(stat -c %a "$parent" 2>/dev/null || stat -f %Lp "$parent" 2>/dev/null) || mode=unknown
    case "$mode" in 700|0700) ;; *) die "scratch directory must have mode 0700: $parent" ;; esac
  fi
  trap cleanup_run EXIT
  trap 'interrupt_run 129' HUP
  trap 'interrupt_run 130' INT
  trap 'interrupt_run 131' QUIT
  trap 'interrupt_run 143' TERM
  RUN_CRITICAL=1
  RUN_TMP=$(trap '' HUP INT QUIT TERM; mktemp -d "$parent/r.XXXXXX") || die "cannot allocate test scratch under $parent"
  record_run_owner "$$"
  RUN_CRITICAL=0
  [ "$RUN_INTERRUPT" -eq 0 ] || exit "$RUN_INTERRUPT"
  reap_orphan_runs "$parent"
  # Also covers temporary files used by runner helpers rather than the tests.
  export TMPDIR="$RUN_TMP" TMP="$RUN_TMP" TEMP="$RUN_TMP"
  export FM_TEST_RETAIN_MARKER="$RUN_TMP/.retain-scratch"
}

worker_root_mode_is_enforceable() {
  case "$(uname -s)" in
    MINGW*|MSYS*) return 1 ;;
    *) return 0 ;;
  esac
}

if [ "$CHECK_COVERAGE" -eq 1 ]; then
  prepare_run_scratch
  run_coverage_guard
  exit $?
fi

if [ "${MODE:-}" = "aggregate" ]; then
  [ -n "$AGGREGATE_OUT" ] || die "--aggregate-json requires an output path"
  [ "${#SCRIPTS[@]}" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || die "aggregate input not found: $s"
  done
  aggregate_timing_json "$AGGREGATE_OUT" "${SCRIPTS[@]}"
  exit 0
fi

case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"
[ "$JOBS" -le "$JOBS_MAX" ] || die "--jobs is capped at $JOBS_MAX (got $JOBS)"

if [ -n "$MAX_WALL_MS" ]; then
  case "$MAX_WALL_MS" in
    ''|*[!0-9]*) die "--max-wall-ms requires a positive integer" ;;
  esac
  [ "$MAX_WALL_MS" -gt 0 ] || die "--max-wall-ms requires a positive integer"
fi

case "$PER_SCRIPT_TIMEOUT_SECS" in
  ''|*[!0-9]*) die "--per-script-timeout-secs requires a whole number of seconds (0 disables)" ;;
esac

# Refuse before any suite is selected or run. The inspection modes execute
# nothing: --list-families, --list-concurrent-safe-families, --list-lanes,
# --check-coverage, --concurrent-safe-family-jobs-max and --aggregate-json have
# already exited above, and --list/--list-scheduled print their selection and
# exit below. An unset MODE still falls through to the usage error, so a caller
# who named no selection mode is told that rather than this.
if [ -n "${MODE:-}" ] && [ "$LIST_ONLY" -eq 0 ] && [ "$LIST_SCHEDULED" -eq 0 ]; then
  refuse_primary_checkout_for_task
fi

case "${MODE:-}" in
  all)
    select_all
    SELECTION_DESC="all"
    ;;
  family)
    select_family "$FAMILY"
    SELECTION_DESC="family=$FAMILY"
    ;;
  lane)
    select_lane "$LANE"
    SELECTION_DESC="lane=$LANE"
    ;;
  proven-isolated)
    select_proven_isolated
    SELECTION_DESC="proven-isolated"
    ;;
  changed)
    select_changed "$BASE_REF"
    SELECTION_DESC="changed:base=$BASE_REF"
    ;;
  scripts)
    # Normalize and re-add through add_script for consistent paths.
    raw=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
    SCRIPTS=()
    for s in "${raw[@]}"; do
      add_script "$s"
    done
    SELECTION_DESC="scripts"
    ;;
  *)
    die "select with --all, --family <name>, --lane <name>, --proven-isolated, --changed, or one or more script paths (see --help)"
    ;;
esac

apply_exclude_families
if [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ]; then
  SELECTION_DESC="${SELECTION_DESC};exclude-family=$(IFS=,; printf '%s' "${EXCLUDE_FAMILIES[*]}")"
fi
if [ -n "$FAIL_ON_GATE_SKIP" ]; then
  SELECTION_DESC="${SELECTION_DESC};fail-on-gate-skip=$FAIL_ON_GATE_SKIP"
fi
if [ "$LIST_ONLY" -eq 1 ] || [ "$LIST_SCHEDULED" -eq 1 ]; then
  if [ "$LIST_SCHEDULED" -eq 1 ]; then
    for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
      case "$MODE:$LANE" in
        lane:portable-parallel-1|lane:portable-parallel-2)
          printf '%s\t%s\n' "$(portable_parallel_weight_for "$s")" "$s"
          ;;
        *)
          printf '%s\t%s\n' "$(portable_serial_weight_for "$s")" "$s"
          ;;
      esac
    done | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k2,2 | cut -f2-
  else
    for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
      printf '%s\n' "$s"
    done
  fi
  exit 0
fi

if [ "${#SCRIPTS[@]}" -ne 0 ] || [ -n "$JSON_PATH" ]; then
  prepare_run_scratch
fi

# An empty selection is a clean result, not a no-op that falls through. Exiting
# here also keeps every array expansion below off the empty-array path: under
# `set -u`, bash 3.2 (the stock macOS shell) treats "${arr[@]}" on an empty
# array as an unbound-variable error, while bash 4.4+ makes it a harmless no-op.
# A contributor on stock macOS who changes only documentation must still get
# total=0 and exit 0 rather than a crash.
if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  log "nothing to run"
  empty_finished_ms=$(now_ms)
  empty_duration=$((empty_finished_ms - RUN_STARTED_MS))
  [ "$empty_duration" -ge 0 ] || empty_duration=0
  empty_rc=0
  printf 'FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=%s\n' "$empty_duration"
  # The budget covers the whole invocation, so a selection phase that outran it
  # still fails - reporting zero work is not the same as reporting no time.
  if [ -n "$MAX_WALL_MS" ]; then
    printf 'FM_TEST_BUDGET max_wall_ms=%s duration_ms=%s\n' "$MAX_WALL_MS" "$empty_duration"
    if [ "$empty_duration" -gt "$MAX_WALL_MS" ]; then
      log "wall-clock budget exceeded: ${empty_duration}ms > ${MAX_WALL_MS}ms for $SELECTION_DESC"
      empty_rc=1
    fi
  fi
  if [ -n "$JSON_PATH" ]; then
    empty_rec="$RUN_TMP/empty-records.tsv"
    empty_fam="$RUN_TMP/empty-families.tsv"
    : >"$empty_rec"
    : >"$empty_fam"
    empty_finished_iso=$(now_iso)
    mkdir -p "$(dirname "$JSON_PATH")"
    write_json_artifact "$JSON_PATH" "$RUN_STARTED_ISO" "$empty_finished_iso" \
      "fm-test-run-${RUN_STARTED_MS}-$$" 0 0 0 "$empty_duration" \
      "$SELECTION_DESC" "$empty_rec" "$empty_fam"
    rm -f "$empty_rec" "$empty_fam"
  fi
  exit "$empty_rc"
fi

# Verify selected scripts exist before starting.
for s in "${SCRIPTS[@]}"; do
  [ -f "$s" ] || die "test script not found: $s"
  [ -x "$s" ] || [ -r "$s" ] || die "test script not readable: $s"
done

# Plain --changed and a plain list of script paths both use the bounded
# representative-suite scheduler; numeric --jobs retains the strict all-script
# admission rule below. Naming scripts is how a local verification round asks
# for exactly those subjects, so it gets bounded concurrency rather than a
# serial chain of separate runs.
# The curated selections stay untouched: --lane composes CI shards whose serial
# lane must stay strictly serial, --family is what the required Herdr lane runs,
# and --all is a deliberate complete regression.
AUTO_CONCURRENCY=0
if { [ "$MODE" = changed ] || [ "$MODE" = scripts ]; } && [ "$JOBS_EXPLICIT" -eq 0 ]; then
  if [ "$MODE" = changed ] && [ "${#SCRIPTS[@]}" -gt 0 ] && [ "$PER_SCRIPT_TIMEOUT_SECS" -eq 0 ]; then
    PER_SCRIPT_TIMEOUT_SECS=$CHANGED_DEFAULT_TIMEOUT_SECS
  fi
  auto_admissible=0
  for s in "${SCRIPTS[@]}"; do
    script_allows_concurrency "$s" && auto_admissible=$((auto_admissible + 1))
  done
  if [ "$auto_admissible" -gt 1 ]; then
    JOBS=$(cpu_count)
    [ "$JOBS" -le 4 ] || JOBS=4
    [ "$JOBS" -ge 1 ] || JOBS=1
    [ "$JOBS" -eq 1 ] || AUTO_CONCURRENCY=1
  fi
fi
if [ "$JOBS" -gt 1 ] || [ "$MODE" = changed ] || [ "$MODE" = scripts ]; then
  SELECTION_DESC="${SELECTION_DESC};jobs=$JOBS"
fi

# An explicit --jobs names a concurrency for exactly the selection given, so an
# unproven script in it is a refusal rather than something to schedule around.
if [ "$JOBS" -gt 1 ] && [ "$AUTO_CONCURRENCY" -eq 0 ]; then
  # A single heavy suite can occupy a whole serial shard. Its family may have
  # a separate concurrency proof, but that never changes this lane's contract.
  if [ "$MODE" = lane ]; then
    case "$LANE" in
      portable-serial|portable-serial-*) die "--jobs $JOBS refused: portable serial lanes stay serial; use --jobs 1" ;;
    esac
  fi
  for s in "${SCRIPTS[@]}"; do
    if ! script_allows_concurrency "$s"; then
      die "--jobs $JOBS refused: $s is not in the proven-isolated set (see bin/fm-test-isolation-proof.sh --list) and its family has no recorded concurrent proof. Unproven stateful scripts stay serial."
    fi
    if ! is_proven_isolated_script "$s"; then
      family=$(family_for_basename "$(basename "$s")")
      family_jobs_max=$(concurrent_safe_family_jobs_max "$family")
      [ "$JOBS" -le "$family_jobs_max" ] \
        || die "--jobs $JOBS refused: family $family is proven only up to $family_jobs_max concurrent workers"
    fi
  done
fi

# Split the run into proven concurrent phases and an unproven remainder.
# Individually proven scripts share one phase. Scripts admitted only by a family
# proof get a separate phase per family, because that proof establishes safety
# only among members of that family. The serial remainder runs after every
# concurrent phase, never beside another test.
CONCURRENT_SCRIPTS=()
SERIAL_TAIL_SCRIPTS=()
CONCURRENT_PHASE_BREAK=__fm_test_concurrent_phase_break__
if [ "$JOBS" -gt 1 ]; then
  SCHEDULE_TMP="$RUN_TMP/schedule.tsv"
  : >"$SCHEDULE_TMP"
  for s in "${SCRIPTS[@]}"; do
    if script_allows_concurrency "$s"; then
      if is_proven_isolated_script "$s"; then
        phase=0
      else
        family=$(family_for_basename "$(basename "$s")")
        phase=1
        while IFS= read -r admitted_family; do
          [ "$family" = "$admitted_family" ] && break
          phase=$((phase + 1))
        done < <(list_concurrent_safe_families)
      fi
      # Longest first within each isolation phase: workers are handed scripts
      # in order, so starting the longest last strands it at the tail.
      printf '%s\t%s\t%s\n' "$phase" "$(portable_serial_weight_for "$s")" "$s" >>"$SCHEDULE_TMP"
    else
      SERIAL_TAIL_SCRIPTS+=("$s")
    fi
  done
  previous_phase=
  while IFS=$'\t' read -r phase _weight s; do
    [ -n "$s" ] || continue
    if [ -n "$previous_phase" ] && [ "$phase" != "$previous_phase" ]; then
      CONCURRENT_SCRIPTS+=("$CONCURRENT_PHASE_BREAK")
    fi
    CONCURRENT_SCRIPTS+=("$s")
    previous_phase=$phase
  done < <(LC_ALL=C sort -t"$(printf '\t')" -k1,1n -k2,2nr -k3,3 "$SCHEDULE_TMP")
  rm -f "$SCHEDULE_TMP"
fi

if [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ]; then
  [ -r "$ROOT/bin/fm-timeout-lib.sh" ] || die 'per-script timeout helper not found: bin/fm-timeout-lib.sh'
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$ROOT/bin/fm-timeout-lib.sh"
fi

RECORDS="$RUN_TMP/records.tsv"
FAMILIES_TSV="$RUN_TMP/families.tsv"
: >"$RECORDS"

RUN_ID="fm-test-run-${RUN_STARTED_MS}-$$"
TOTAL=0
FAILED=0
SKIPPED_GATE=0
AGG_RC=0

# Family accumulators as TSV lines updated in-memory via temp files.
# family -> count, duration_ms, failed
family_bump() {
  local fam=$1 dur=$2 failed_delta=$3
  local line name count duration failed_count rest
  local found=0
  local tmp="$RUN_TMP/families.new"
  : >"$tmp"
  if [ -s "$FAMILIES_TSV" ]; then
    while IFS= read -r line; do
      name=${line%%$'\t'*}
      rest=${line#*$'\t'}
      count=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      duration=${rest%%$'\t'*}
      failed_count=${rest#*$'\t'}
      if [ "$name" = "$fam" ]; then
        count=$((count + 1))
        duration=$((duration + dur))
        failed_count=$((failed_count + failed_delta))
        found=1
      fi
      printf '%s\t%s\t%s\t%s\n' "$name" "$count" "$duration" "$failed_count" >>"$tmp"
    done <"$FAMILIES_TSV"
  fi
  if [ "$found" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$fam" 1 "$dur" "$failed_delta" >>"$tmp"
  fi
  mv "$tmp" "$FAMILIES_TSV"
}

record_script_result() {
  local script=$1 rc=$2 duration=$3 out=$4 end_iso=$5
  local base family expected gate_skip gate_reason fail_delta
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")

  if [ -n "$FAIL_ON_GATE_SKIP" ] && detect_gate_skip_token "$out" "$FAIL_ON_GATE_SKIP"; then
    log "required gate skip token seen in $script: skip: $FAIL_ON_GATE_SKIP"
    rc=1
  fi

  gate_skip=false
  gate_reason=
  if [ "$rc" -eq 0 ] && detect_gate_skip "$out"; then
    gate_skip=true
    gate_reason=$(gate_skip_reason "$out")
    SKIPPED_GATE=$((SKIPPED_GATE + 1))
    # A capability skip is the runner's only record of what this host could not
    # exercise, so name it rather than leaving a silent green.
    log "gate skip: $script: ${gate_reason:-<no reason given>}"
  fi

  printf 'FM_TEST_END %s %s exit=%s duration_ms=%s gate_skip=%s\n' \
    "$end_iso" "$script" "$rc" "$duration" "$gate_skip"

  fail_delta=0
  if [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    fail_delta=1
    AGG_RC=1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$script" "$family" "$expected" "$rc" "$duration" "$gate_skip" "$gate_reason" >>"$RECORDS"
  family_bump "$family" "$duration" "$fail_delta"
  TOTAL=$((TOTAL + 1))
}

worker_n=0
active_workers=0

start_worker() {
  local script=$1 stream=$2 foreground=${3:-0} work base family expected
  worker_n=$((worker_n + 1))
  work="$RUN_TMP/w$worker_n"
  mkdir -p "$work/t"
  chmod 0700 "$work" "$work/t" || die "could not chmod 0700 worker root $work"
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")
  printf 'FM_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
    "$(now_iso)" "$script" "$family" "$expected"
  # Monitor mode gives each worker its own group before this shell proceeds.
  # Turn it off inside the worker so the test and tee share the same group.
  : >"$work/output"
  WORKER_SCRIPTS[worker_n]=$script
  active_workers=$((active_workers + 1))
  if [ "$foreground" -eq 1 ]; then
    (execute_worker "$script" "$stream" "$work" "$foreground") || true
  else
    RUN_CRITICAL=1
    set -m
    execute_worker "$script" "$stream" "$work" "$foreground" <&0 &
    WORKER_PIDS[worker_n]=$!
    set +m
    RUN_CRITICAL=0
    [ "$RUN_INTERRUPT" -eq 0 ] || exit "$RUN_INTERRUPT"
  fi
}

register_timed_owner() {
  local work=$1 worker=$2 group
  group=$(LC_ALL=C ps -p "$$" -o pgid= 2>/dev/null | awk 'NF == 1 { print $1 }')
  if [ -z "$group" ]; then
    group=$(LC_ALL=C ps -e 2>/dev/null | awk -v pid="$$" '
      NR == 1 { for (i=1; i<=NF; ++i) if ($i == "PGID") col=i }
      col && $1 == pid { print $col; exit }
    ')
  fi
  case "$group" in ''|0*|*[!0-9]*) return 1 ;; esac
  record_run_owner "$group" "$group" "$work/timed-owner" || return 1
  [ ! -e "$work/stopping" ] && kill -0 "$worker" 2>/dev/null
}

run_owned_timed() {
  local work=$1 worker=$2
  shift 2
  export ROOT RUN_TMP
  export -f register_timed_owner record_run_owner run_owner_start
  fm_run_timed "$PER_SCRIPT_TIMEOUT_SECS" bash -c '
    register_timed_owner "$1" "$2" || exit 1
    shift 2
    exec "$@"
  ' _ "$work" "$worker" "$@"
}

execute_worker() {
  local script=$1 stream=$2 work=$3 foreground=$4 pid group=0 rc begin_ms end_ms duration
  trap - EXIT HUP INT QUIT TERM
  set +m
  pid=${BASHPID:-$(exec bash -c 'printf "%s\n" "$PPID"')}
  [ "$foreground" -eq 1 ] || group=$pid
  record_run_owner "$pid" "$group" || exit 1
  [ ! -e "$work/stopping" ] && kill -0 "$$" 2>/dev/null || exit 1
  export TMPDIR="$work/t" TMP="$work/t" TEMP="$work/t"
  if [ "$stream" -eq 0 ]; then
    unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE \
      FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND 2>/dev/null || true
  fi
  # shellcheck source=tests/git-config-helpers.sh
  . "$ROOT/tests/git-config-helpers.sh" || exit 1
  cd "$ROOT" || exit 1
  set +e
  begin_ms=$(now_ms)
  if [ "$stream" -eq 1 ]; then
    if [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ]; then
      # shellcheck disable=SC2016
      run_owned_timed "$work" "$pid" bash -c \
        'bash "$1" 2>&1 | tee "$2"; exit "${PIPESTATUS[0]}"' _ "$script" "$work/output"
      rc=$?
    else
      bash "$script" 2>&1 | tee "$work/output"
      rc=${PIPESTATUS[0]}
    fi
  elif [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ]; then
    run_owned_timed "$work" "$pid" bash "$script" >"$work/output" 2>&1
    rc=$?
  else
    bash "$script" >"$work/output" 2>&1
    rc=$?
  fi
  if [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ] && [ "$rc" -eq 124 ]; then
    printf 'not ok - %s exceeded the per-script bound of %ss and was terminated\n' \
      "$script" "$PER_SCRIPT_TIMEOUT_SECS" >>"$work/output"
    [ "$stream" -eq 0 ] || tail -1 "$work/output"
  fi
  end_ms=$(now_ms)
  duration=$((end_ms - begin_ms))
  [ "$duration" -ge 0 ] || duration=0
  printf '%s\n' "$duration" >"$work/duration_ms"
  printf '%s\n' "$rc" >"$work/exit"
}

run_one_serial() {
  if [ -t 0 ]; then
    start_worker "$1" 1 1
  else
    start_worker "$1" 1
  fi
  collect_worker "$worker_n" 1
}

collect_worker() {
  local slot=$1 stream=$2 pid work script rc duration mode out end_iso undrained=0
  pid=${WORKER_PIDS[$slot]:-}
  script=${WORKER_SCRIPTS[$slot]}
  work="$RUN_TMP/w$slot"
  out="$work/output"
  if [ -n "$pid" ]; then wait "$pid" || true; fi
  if stop_owned_workers "$slot"; then
    rm -f "$work/timed-owner"
  else
    KEEP_RUN_TMP=1
    undrained=1
  fi
  rc=$(cat "$work/exit" 2>/dev/null || echo 1)
  if [ "$undrained" -eq 1 ] && [ "$rc" -eq 0 ]; then rc=1; fi
  duration=$(cat "$work/duration_ms" 2>/dev/null || echo 0)
  unset 'WORKER_PIDS[slot]' 'WORKER_SCRIPTS[slot]'
  end_iso=$(now_iso)
  # Replay captured parallel output after the worker finishes, in one block.
  if [ "$stream" -eq 0 ] && [ -s "$out" ]; then
    cat "$out"
  fi
  if worker_root_mode_is_enforceable; then
    mode=$(stat -c %a "$work" 2>/dev/null || stat -f %Lp "$work" 2>/dev/null || echo unknown)
    case "$mode" in
      700|0700) ;;
      *)
        log "isolation failure: worker root mode is $mode, expected 0700 ($work)"
        rc=1
        ;;
    esac
  fi
  record_script_result "$script" "$rc" "$duration" "$out" "$end_iso"
  active_workers=$((active_workers - 1))
}

wait_one_completed_job_worker() {
  local slot running
  while :; do
    # Keep `jobs` in this shell. A subshell does not have its job table.
    jobs -p >"$RUN_TMP/running-pids"
    running=$'\n'$(<"$RUN_TMP/running-pids")$'\n'
    for slot in "${!WORKER_PIDS[@]}"; do
      if [ -f "$RUN_TMP/w$slot/exit" ] || [[ "$running" != *$'\n'"${WORKER_PIDS[$slot]}"$'\n'* ]]; then
        collect_worker "$slot" 0
        return
      fi
    done
    sleep 0.01
  done
}

run_serial_if_isolated() {
  if [ "$KEEP_RUN_TMP" -eq 0 ]; then
    run_one_serial "$1"
  else
    log "not run (worker group exit unconfirmed): $1"
  fi
}

if [ "$JOBS" -eq 1 ]; then
  for script in "${SCRIPTS[@]}"; do
    run_serial_if_isolated "$script"
  done
else
  for script in "${CONCURRENT_SCRIPTS[@]+"${CONCURRENT_SCRIPTS[@]}"}"; do
    if [ "$script" = "$CONCURRENT_PHASE_BREAK" ]; then
      while [ "$active_workers" -gt 0 ]; do
        wait_one_completed_job_worker
      done
      continue
    fi
    while [ "$active_workers" -ge "$JOBS" ]; do
      wait_one_completed_job_worker
    done
    if [ "$KEEP_RUN_TMP" -eq 0 ]; then
      start_worker "$script" 0 </dev/null
    else
      log "not run (worker group exit unconfirmed): $script"
    fi
  done
  while [ "$active_workers" -gt 0 ]; do
    wait_one_completed_job_worker
  done
  # Unproven remainder, after every concurrent worker has finished.
  for script in "${SERIAL_TAIL_SCRIPTS[@]+"${SERIAL_TAIL_SCRIPTS[@]}"}"; do
    run_serial_if_isolated "$script"
  done
fi

RUN_FINISHED_ISO=$(now_iso)
RUN_FINISHED_MS=$(now_ms)
RUN_DURATION=$((RUN_FINISHED_MS - RUN_STARTED_MS))
if [ "$RUN_DURATION" -lt 0 ]; then
  RUN_DURATION=0
fi

printf 'FM_TEST_SUMMARY total=%s failed=%s skipped_gate=%s duration_ms=%s\n' \
  "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION"

if [ -s "$FAMILIES_TSV" ]; then
  # Stable family summary order by name.
  sort -t$'\t' -k1,1 "$FAMILIES_TSV" | while IFS=$'\t' read -r name count duration failed_count; do
    printf 'FM_TEST_SUMMARY_FAMILY family=%s count=%s duration_ms=%s failed=%s\n' \
      "$name" "$count" "$duration" "$failed_count"
  done
fi

# Slowest scripts (top 15) from records.
if [ -s "$RECORDS" ]; then
  rank=1
  sort -t$'\t' -k5,5nr "$RECORDS" | head -n 15 | while IFS=$'\t' read -r path _family _expected _rc duration _gate; do
    printf 'FM_TEST_SLOWEST rank=%s script=%s duration_ms=%s\n' \
      "$rank" "$path" "$duration"
    rank=$((rank + 1))
  done
fi

if [ -n "$JSON_PATH" ]; then
  mkdir -p "$(dirname "$JSON_PATH")"
  # Families file may be unsorted; write_json reads as-is (deterministic sort in python).
  if [ -s "$FAMILIES_TSV" ]; then
    sort -t$'\t' -k1,1 "$FAMILIES_TSV" -o "$FAMILIES_TSV"
  else
    : >"$FAMILIES_TSV"
  fi
  set +e
  write_json_artifact "$JSON_PATH" \
    "$RUN_STARTED_ISO" "$RUN_FINISHED_ISO" "$RUN_ID" \
    "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION" \
    "$SELECTION_DESC" "$RECORDS" "$FAMILIES_TSV"
  json_rc=$?
  set -e
  if [ "$json_rc" -eq 0 ]; then
    log "wrote timing artifact: $JSON_PATH"
  else
    log "timing artifact finalization failed: $JSON_PATH"
    AGG_RC=1
  fi
fi

if [ -n "$MAX_WALL_MS" ]; then
  printf 'FM_TEST_BUDGET max_wall_ms=%s duration_ms=%s\n' "$MAX_WALL_MS" "$RUN_DURATION"
  if [ "$RUN_DURATION" -gt "$MAX_WALL_MS" ]; then
    log "wall-clock budget exceeded: ${RUN_DURATION}ms > ${MAX_WALL_MS}ms for $SELECTION_DESC"
    AGG_RC=1
  fi
fi

exit "$AGG_RC"
