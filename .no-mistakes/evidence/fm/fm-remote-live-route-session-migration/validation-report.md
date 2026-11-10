# Session migration validation

## Real executable evidence

`live-cli-guards.log` records actual invocations of `bin/fm-remote-session-migrate.sh` against disposable synthetic primary records. Empty, reserved, malformed and overlong names, missing/duplicated route IDs, disagreeing parent metadata, a registered destination collision and the current session as destination all refused with the expected reason. Registry and endpoint bytes remained unchanged and no relocation intent appeared. These scenarios stopped before transport; no SSH endpoint, agent or Herdr session was simulated to establish these results.

The repeatable driver is retained as `live-guards-driver.py` (creates `.test-tmp` under the current repository).

## Fixture evidence — NOT live fleet validation

Ran the migration-only section of `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` through a disposable copy named `tests/.nm-relocation-evidence.test.sh` with `FM_TEST_RELOCATION_ONLY=1` and workspace-local TMPDIR. The copy added only evidence collection, exclusion of `.test-tmp` from fixture tar materialization, and a remote fixture cwd inside its own git repository.

The successful run exited 0. It exercised migration and normal-route recovery, failed session birth, busy/unknown source refusal, remote endpoint disagreement, existing-name collision, lost preparation response, partial source snapshot copy in forward and reverse operations, interrupted local publication, no-answer recovery, tracing preservation across resumed launch, refreshed trace/profile preservation on reversal, interrupted reversal preparation and retry, unchanged home/config/instructions/sibling records and retained source terminal/session. Product transcripts and final synthetic records are retained as `fixture-*`. SSH, Herdr, harness and readiness boundaries are fakes in this test; its passing result is not live proof of a running mate.

Initial setup attempts did not test migration: placing TMPDIR inside the materialized tree caused recursive tar copying and a 650-second timeout; the next attempt reached a gate refusal because the fake remote worker inherited a cwd under the gate repository. Both setup issues were corrected only in the disposable runner before the successful run. No production source or permanent tests were changed.

## Live migration blocker

Attempted the supported helper with an isolated HOME, XDG_CONFIG_HOME, HERDR_CONFIG_PATH and FM_HERDR_LAB_STATE_DIR under the worktree:

```
bin/fm-herdr-lab.sh prepare fm-lab-migration-validation
```

It exited 1: `fleet-state tripwire requires exactly one running default session` (`isolated-herdr-prepare.log`). No session was provisioned. Creating a default session would violate the named-non-default-only lab contract. Using the operator's normal Herdr directories or macOS migration birth would intentionally write outside the worktree (the doctor creates/reloads a user LaunchAgent), also forbidden. The fake-transport suite cannot resolve this live evidence gap. Full migration, source-agent lifecycle, crash recovery and reversal need a sanctioned disposable remote account/environment with SSH, the required running-default tripwire, a real logged-in harness, and explicit permission for that environment's session/LaunchAgent writes through the approved lab lifecycle. No operator route, credentials or fleet data was used or moved.

## Completion

All disposable runner files, fixture homes and workspace TMPDIR were removed. No test worker remains running and git status is clean. No linters, static analysis, full suite, push, PR or CI phases were run. This is a CLI change, so CLI transcripts rather than screenshots are the relevant surface. Verdict: inconclusive; real preflight checks passed and targeted fixture checks passed, but successful running-mate relocation was not demonstrated live.
