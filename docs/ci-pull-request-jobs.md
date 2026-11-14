# Pull-request CI job audit

## Scope and evidence

This audit covers every pull-request-triggered workflow in `.github/workflows/`: `CI` and `Require no-mistakes`.
`Windows Herdr automation spike` is manual-only and runs no job on a pull request.
The workflows own execution; [CONTRIBUTING.md](../CONTRIBUTING.md#maintaining-required-checks) owns the required-check maintenance procedure.
This document records the current coverage rationale and proposals, not permission to change validation policy.

Costs below reuse the **Personal-fork CI duration review**, measured November 10, 2026, sections 2-5 and Appendix A.
No duration, journal, or runner study was repeated for this change.
Linux costs are mean elapsed runner seconds per first attempt, calculated from that report's ten existing observations, not CPU seconds or additive wall time.
Its baseline median first-attempt CI wall is 28m14.5s; serial tests account for 70.7% of execution and lint for 13.5%.
The baseline does not measure the new lint verdict jobs or compliance workflow execution.
Their costs are explicitly unmeasured rather than inferred from the CI-only sample.

### Required checks versus jobs

The effective `main` branch rules read on November 14, 2026 from `GET /repos/ayrton-saunders/firstmate/rules/branches/main` require 22 contexts, all bound to GitHub Actions integration 15368, with `strict_required_status_checks_policy` off.
They are marked **yes** in the table below.
The actual rule differs from the recommended list in CONTRIBUTING: it also requires `Behavior portable serial 11` and `Behavior tests (herdr-core)`, and does not require the timing aggregate.
Requiring `Full suite` matters because individual jobs can skip before an outside PR receives `full-ci`, and the required individual names alone do not enforce the go-ahead.

Normal CI names below acquire the existing `Not run for label - ` prefix on an unrelated label event, so that event cannot replace a real failure under the required name.
The `full-ci` trust/label policy and fork skip variables are unchanged.
The compliance workflow also triggers on body edits.

## Named inventory and verdicts

**Required** means directly required by the effective personal-fork rule, not merely a job that runs or is recommended upstream.
Costs describe the pre-change shape unless explicitly marked projected or unmeasured.
Each serial row is a distinct, disjoint assignment exposed by `fm-test-run.sh --list`; assertions are not duplicated between portable lanes.

| Workflow / job ID | Published context | Required | Failure caught and overlap | Cost per PR | Verdict |
|---|---|---|---|---|---|
| CI / lint (matrix 1) | `Lint 1` | yes | Canonical source-aware shell analysis, workflow syntax and backend purity; lint self-tests exercise the checker, not this repository's findings. | Baseline 1381.9s; now an unmeasured short verdict requiring all four execution partitions. | Keep. |
| CI / lint (matrix 2) | `Lint 2` | yes | Same obligation over the other baseline root partition; both stable contexts now reject any unsuccessful execution partition. | Baseline 1483.0s; now an unmeasured short verdict. | Keep. |
| CI / lint-partitions (matrix 1) | `Lint partition 1` | no | One quarter of the canonical roots; full source following and per-root bounds, workflow lint and backend purity retained. | New; see the projection below. | Keep, enforced through both existing required lint contexts. |
| CI / lint-partitions (matrix 2) | `Lint partition 2` | no | Disjoint quarter, same analysis and auxiliary checks. | New; see projection. | Keep, enforced through required lint. |
| CI / lint-partitions (matrix 3) | `Lint partition 3` | no | Disjoint quarter, same analysis and auxiliary checks. | New; see projection. | Keep, enforced through required lint. |
| CI / lint-partitions (matrix 4) | `Lint partition 4` | no | Disjoint quarter, same analysis and auxiliary checks. | New; see projection. | Keep, enforced through required lint. |
| CI / test-coverage | `Test coverage guard` | yes | Missing/duplicate lane membership, missing hint entries and modeled budget violations; passing selected tests cannot detect omitted scripts. | 27.8s. | Keep. |
| CI / tests-portable-parallel-1 | `Behavior portable parallel 1` | yes | Proven-isolated regression subset, including checker and Pi prerequisites; lint cannot prove behavior. | 1288.4s. | Keep. |
| CI / tests-portable-parallel-2 | `Behavior portable parallel 2` | yes | Other disjoint proven-isolated subset, not a repeat of lane 1. | 1234.9s. | Keep. |
| CI / tests-portable-serial (1) | `Behavior portable serial 1` | yes | Stateful regression assignment 1, with per-script serial isolation; no other portable shard executes these scripts. | 1200.0s. | Keep. |
| CI / tests-portable-serial (2) | `Behavior portable serial 2` | yes | Disjoint stateful assignment 2. | 1489.6s. | Keep. |
| CI / tests-portable-serial (3) | `Behavior portable serial 3` | yes | Disjoint stateful assignment 3. | 1314.6s. | Keep. |
| CI / tests-portable-serial (4) | `Behavior portable serial 4` | yes | Disjoint stateful assignment 4. | 1494.2s. | Keep. |
| CI / tests-portable-serial (5) | `Behavior portable serial 5` | yes | Disjoint stateful assignment 5. | 1372.5s. | Keep. |
| CI / tests-portable-serial (6) | `Behavior portable serial 6` | yes | Disjoint stateful assignment 6. | 1043.0s. | Keep. |
| CI / tests-portable-serial (7) | `Behavior portable serial 7` | yes | Disjoint stateful assignment 7. | 1242.0s. | Keep. |
| CI / tests-portable-serial (8) | `Behavior portable serial 8` | yes | Disjoint stateful assignment 8. | 1441.7s. | Keep. |
| CI / tests-portable-serial (9) | `Behavior portable serial 9` | yes | Disjoint stateful assignment 9. | 1549.4s. | Keep. |
| CI / tests-portable-serial (10) | `Behavior portable serial 10` | yes | Disjoint stateful assignment 10. | 1296.3s. | Keep. |
| CI / tests-portable-serial (11) | `Behavior portable serial 11` | yes | Disjoint stateful assignment 11. | 1555.9s. | Keep. |
| CI / tests-herdr | `Behavior tests (Herdr)` | yes | Pinned real Herdr protocol, focus, cleanup and default-session safety; fake/portable fixtures cannot prove these. | 548.2s. | Keep. |
| CI / tests-hc | `Behavior tests (herdr-core)` | yes | Real hc backend and lab cleanup; some unit behavior overlaps portable tests but actual hc execution does not. | 47.6s. | Keep; removing it loses distinct backend coverage for negligible critical-path benefit. |
| CI / tests-timing-aggregate | `Behavior timing aggregate` | no | Invalid aggregate inputs and artifact assembly; collects even after failed lanes and does not prove every lane passed. | 8.4s. | Make advisory if future rules add it: no need for a separate blocking context. |
| CI / macos-stock-bash | `Stock macOS Bash snapshot compatibility` | yes | Real Bash 3.2 parse sweep and snapshot/helper regressions with BSD tools; Linux assertions are not a substitute. | Successful execution 317-439s, median 387s; failed acquisitions execute nothing and wait 901s. | Keep, unchanged runner/pool and conditions. |
| CI / invariants | `Repo invariants` | yes | Broken CLAUDE pointer/skill symlink or tracked private fleet paths; some local verification overlaps, but behavioral test success alone does not establish these invariants. | 6.1s. | Merge into another job as a future proposal, retaining every assertion. |
| CI / full-suite | `Full suite` | yes | Missing outside-PR go-ahead or failed/cancelled dependencies; individual skipped jobs can otherwise look acceptable. | 3.4s. | Keep. |
| Require no-mistakes / check | `PR must be raised via no-mistakes` | yes | Missing/stale pipeline attestation or invalid focused-integration qualification; neither behavioral CI nor local lint establishes provenance. | Unmeasured; fresh runner plus base qualification or native verification. | Keep with all current exceptions, digest and pass conditions. |

## What actually overlaps, and what removal costs

- **Merge invariants into coverage guard:** loses no assertions if pointer, symlink and private-path checks remain mandatory there; loses independent failure isolation and requires a coordinated decision about the existing required context.
  Only one six-second job's runner/setup is at stake, not minutes on the critical path; captain approval is required before merging checks or retiring a name.
- **Timing aggregate advisory:** current personal-fork rules already do not require it, and Full suite does not depend on it.
  Keep collecting per-head diagnostic artifacts; making it mandatory adds a merge dependency for evidence plumbing rather than new product assertions.
  Removing a future blocking requirement loses assurance that evidence assembly succeeded, not the independently checked lane results; captain approval is required for any such policy change.
- **No scheduled-only product job recommended:** moving stock Bash or real-backend execution to a schedule loses per-head platform/backend assurance.
  Scheduling the aggregate instead also loses the per-head data needed to identify hint drift.
  These are explicit coverage/diagnostic trades, requiring the captain's word, not free speedups.
- **Lint duplication:** every partition repeats workflow validation and backend-purity checks; shared shell dependencies are also analyzed from multiple roots intentionally.
  The measured cost is full ShellCheck root analysis, not duplicated workflow validation; removing external-source analysis or exclusions is not equivalent coverage.
  Keep those checks and the memory fallback; lint regression tests must also remain because they test the checker itself.
- **No duplicate full portable suite:** the coverage guard proves disjoint membership; main-push duplication is already disabled on this fork through its existing variable.
  No removal of tests is justified by this evidence.

## Prerequisites and caches

Portable serial shards all install Pi and tasks-axi, and all portable jobs install pinned ShellCheck/actionlint; only some selected scripts actually exercise each tool.
Parallel lane 1 installs Pi; parallel lane 2 already does not.
The existing report section 2 measures median Pi installation at 10s, tasks-axi at about 1s, checkout at 4s, and linter downloads mostly below one-second timestamp resolution.
Those are setup costs incurred concurrently, not minute-scale additive wall savings.
A prerequisite-elision proposal must derive requirements from actual selected scripts and preserve strict missing-prerequisite enforcement; capability-skipping a newly unprovisioned test is lost coverage.
No such provisioning change is made here, and full-history checkout remains because fixtures may depend on history.

**No cache is introduced:** this evidence does not establish a cache whose restore is faster than those tiny verified downloads.
Pi and Linux tasks-axi installs are unversioned; caching installed trees would freeze correctness-relevant dependency inputs.
Caching linter binaries without rechecking archive digests would bypass provenance, while storing only verified downloads would still require digest validation and adds restore/save overhead.
The report section 5 rank 2 explicitly requires pinning identities and checking restore overhead before claiming a saving.
Pinning dependencies is a separate dependency-policy change, not a free cache; consider content-addressed download reuse with unchanged verification only after that decision.
There is no delivered caching saving and no cache-staleness risk in this PR.

## Implemented lint split and deferred repack

CI executes four byte-weight-balanced canonical lint partitions on separate runners, preserving every root, rule, external-source flag, fallback and resource limit.
The two existing required contexts `Lint 1` and `Lint 2` are retained as verdicts, each requiring all four execution partitions to succeed.
A failed, cancelled or skipped execution matrix fails both verdicts; therefore roots moved to partitions 3/4 cannot silently become optional under the existing rules.
Full suite still depends on the same `lint` job, and no repository setting changes are needed.
Two-way local partition selectors remain supported.

Expected lint-only saving comes from the existing report section 5 rank 4: measured root work totals 3080.290s; four ideal runners average 770.073s (12.83m) versus the slower two-way root sum of 26.21m.
That is approximately 13.38m less **lint-stage work on the slowest runner in the ideal projection**, not a measured CI-wall reduction.
Byte weights are not duration weights, setup and verdict acquisition add overhead, and tests still dominate overall latency.
More runner demand can erase the benefit if shared capacity queues jobs; no paid capacity or concurrency change is authorized.
No numeric end-to-end saving is claimed for this lint-only change.

**Serial repack is a recorded deferral:** the existing report sections 4 and 5 rank 3 put refreshed eleven-way serial packing at **24.10 minutes against the unchanged 1200-second guard**.
The single remote lifecycle suite reaches **21m14.867s**, so repacking or adding runners alone cannot meet that guard.
Neither hints, lane membership, budgets, the coverage guard nor lifecycle assertions are changed here.
Two future routes require separate human approval: a coverage-preserving split or acceleration of that suite as independently reviewed work, or an explicit modeled-target decision.
The repack share of the originally combined optimization is **not delivered**, and no repack saving is claimed.
The recorded narrower delivery retains lint splitting and the caching assessment, with no caching saving delivered; deferring repacking reduces speed gains, not coverage.
The PR awaits explicit human merge approval covering this narrower delivery; the recorded deferral is not merge approval, and audit proposals require separate approval.
The macOS pool question remains separate: existing cancellations are runner acquisition failures, not suite slowness; its required job is untouched.

## Verification entry points

`tests/fm-lint.test.sh` compares two-way and four-way partitions against the full canonical inventory, then checks executed roots, initial analysis flags and rejection of weakened modes.
`tests/fm-ci-workflow.test.sh` compares actual execution-matrix roots to that same inventory and executes the required lint verdict against success, failure, cancellation and skip results.
`bin/fm-test-run.sh --check-coverage` remains the unchanged authority for test selection and budgets.
The implementation PR retains the before/after inventory comparison and final-head CI result; projected savings above are not a replacement for passing checks.
