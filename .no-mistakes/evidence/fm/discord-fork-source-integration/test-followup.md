# Selected finding test-2 follow-up

No product failure reproduced; the existing `tests/fm-discord-hook.test.sh` passed before and after testing.
The newly supplied private dependency enabled two targeted real-core checks against this pipeline's actual source.
Both initially failed with exit 3 because the original private fixtures use unmarked homes and disallowed override combinations inside a gate.
This is a fixture/environment incompatibility, not a reason to weaken the lifecycle guard.
The task-local adapter creates each empty home through `bin/fm-lab-home.sh create`, keeps FM_HOME explicit, sets FM_ROOT_OVERRIDE to the actual source, and removes redundant data/projects overrides.
It never enables FM_GATE_REFUSE_BYPASS or modifies the private snapshot or product source.
Both selected checks then passed twice.

## Evidence

- `enabled-tests.txt`: two focused checks pass: complete simulated request/parent routing/progress/decision/final flow and actual capacity deferral without consuming dispatch authority.
- `enabled-driver.py`: test adapter only, imports the supplied snapshot without copying private implementation into evidence.
- Each test-named directory contains exact JSON exports of all four synthetic journal tables, including real permits, readiness, intents, delivery receipts and pending-final outcomes.
- `private-core-provenance.json`: SHA256 manifest of the explicitly supplied source-only archive at pinned commit 2ae30eca3ec48f13a5067c24f7960d3da791d274; copied files matched exactly before cleanup; no Git history/remotes or symlinks copied.
- `targeted-regression.txt`: existing executable regression passes, including unset-FM_HOME inbox, spawn and capacity calls with disabled integration.

## Reproduction

Copy the explicitly supplied snapshot into ignored `.no-mistakes/private-core-test`, then copy `enabled-driver.py` to `.no-mistakes/check-enabled.py`.
Run from the exact pipeline source directory:

```sh
TEST_EVIDENCE=/Users/ayrton/.no-mistakes/evidence/01M5Z6S3D1YEKGGHKF6B2RZ6HH \
FIRSTMATE_SOURCE="$PWD" TMPDIR="$PWD/.test-tmp" PYTHONDONTWRITEBYTECODE=1 \
PYTHONPATH="$PWD/.no-mistakes/private-core-test:$PWD/.no-mistakes/private-core-test/tests" \
/Users/ayrton/Firstmates/personal/data/discord-isolated-adaptation/venv/bin/python .no-mistakes/check-enabled.py
```

No installs, network, Discord/SSH activation, real workers, real IDs or credentials were used.
Media remains OFF; only fake external services and disposable journals/mappings were exercised.
The existing runtime was reused without modification.
The private copied snapshot, task driver and temporary directories were removed from the worktree after testing; no private bytes were staged or tracked.

## Residual limitation requiring supervisor disposition

Live default-home worker launch/capacity with FM_HOME absent remains untested.
The authorized disposable lifecycle allowance requires explicit FM_HOME, so it cannot exercise that condition without violating the safety rule.
The existing executable regression passes with fake launch tools but must not be described as live-worker acceptance.
The enabled integration checks above use real core permits and journals with fake external services, not live Discord or agent execution.
No broad test suite, lint, static analysis, push, PR or CI phase was run.
