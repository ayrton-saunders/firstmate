# Remote doctor probe-session live validation

## Scope and oracle

The author requires the queued required-tool probe to retain the calling route's non-default Herdr session, without bypassing endpoint ownership checks. A matching route must produce the six required-tool facts; an incorrect session must refuse before returning tool facts. Seed readiness must not create a secondmate marker. Migration birth without an explicit route id must validate the marked home's source assignment before checking migration intent.

## Real execution

`bash .test-live/drive.sh` exited 0. The retained reproduction driver is `live-driver.sh`. It launched the actual `bin/fm-remote-job-worker.sh --serve` with a disposable account HOME and route FM_HOME inside the worktree. It used the real queue staging/waiting/reaping library and actual doctor executable; no worker, guard, backend CLI, or tool output was mocked.

The parent doctor used a deliberately minimal bootstrap PATH with neither backend CLI. The real worker's filesystem-composed PATH discovered the installed Herdr CLI. This exercises default backend recomputation and the session guard without starting, inspecting, or mutating a Herdr server. `fm-lab-probe-personal` is synthetic endpoint metadata, not a running session. No Herdr lifecycle calls occurred.

The baseline parent was extracted from commit `0644e6e17cbbc6580b666c80c7dd6487416da040` into a disposable sibling script directory, with dependencies linked to the current bin directory. Both baseline and fixed parents queued their child against the same current worker and current doctor, isolating the parent's missing-session staging defect.

## Results

- `before-fix.log`: baseline caller reports an invalid required-tool probe for the marked custom-session route.
- `assigned.log`: fixed caller reports `check remote-job-probe=ok: the remote job worker completed the required-tool probe` and six worker-derived facts including `required herdr=/opt/homebrew/bin/herdr`.
- `inferred.log`: the same probe succeeds without an explicit route id, using the home's marker and parent-route record.
- `seed.log`: the unmarked home probes successfully; the driver confirms no marker was created.
- `wrong-session.log`: readiness rejects a different session.
- `wrong-worker-probe.stderr` and `.log`: a real queued `--worker-tool-probe --backend herdr` rejects the different session, exits 1, and emits no stdout.
- `migration-source.log`: the correct inferred source reaches the missing-intent refusal.
- `migration-wrong-source.log`: the incorrect source is rejected by the endpoint guard before intent admission.

These are probe and admission results, not full host-readiness results. The intentionally uninstalled lab LaunchAgent and entrypoint link, minimal parent PATH, and the actual tasks-axi compatibility result leave full doctor exit status 1. The valid six-fact missing-tool report is accepted as a completed probe rather than being mislabeled an invalid probe. No packages, services, credentials, real route records, or operator settings were changed. Remote fpl/SSH readiness was not exercised.

## Supplemental targeted regression

`TMPDIR="$PWD/.test-live/tmp" bash tests/fm-remote-doctor.test.sh` exited 0. This suite includes the explicit Herdr-backend regression, but its simulated platform/backend boundaries are supplemental regression evidence, not live Herdr server validation.

## Cleanup

The worker was terminated and waited for by the driver. A subsequent process-table check found no worker launched from this worktree. Disposable files were removed and `git status --short` was empty. No source changes were made. This is a CLI-only change; no visual UI evidence applies.
