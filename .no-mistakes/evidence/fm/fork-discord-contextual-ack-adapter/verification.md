# Local acknowledgement verification

Target: bc2546dd1b03e405793e86fcd72aa8d3e75753b8.
Transport source: ayrton-saunders/firstmate-discord at merged PR 27 commit 30e7f2df6202cb1a3becaf34bb5d89b51ae86eda.

## Executed product

Ran the actual `bin/fm-discord-acknowledge.py` CLI using disposable marked lab homes, CPython 3.14, and the real transport package's Journal, Parent and Integration implementations.
Synthetic request/custody/work/correlation inputs were created locally; no Discord account, live domain, worker runtime, fleet pane or host release was modified.
The independent expected results came from the supplied acknowledgement contract and required user intent.

`local-product.json` retains CLI exits, original origin, accepted binding, actual persisted approval records and published events.
The local scenarios exercised:

- Absent/off configuration and imminent judgement: no wording call, approval or public event; imminent also works with malformed configuration.
- Slow judgement with a deterministic external wording command: exact original origin and accepted generation survive publication; launching from another Python re-executes the acknowledgement entrypoint correctly.
- Repeating the same line produces only one acknowledgement; a final immediately afterwards remains published in order, with no suppression.
- An already-published final closes the window: silent exit 0, no acknowledgement approval or event.
- Concurrent revision change during wording raises the real Integration Conflict: silent exit 0, exactly one wording invocation, no approval/event.
- Empty, multiline and oversized UTF-8 wording, transport-forbidden internal wording/private paths, failed wording execution and mismatched generation cannot approve a line.

`real-model.json` retains a real configured Claude CLI invocation using `claude-haiku-4-5` with `--effort low`, no tools, no MCP, no settings/hooks and no session persistence.
The actual generated and approved sentence was:

> We are reviewing your invoice totals against the corresponding receipts.

Initial model setup failed because the adapter intentionally strips USER/LOGNAME; macOS Claude could not resolve the normal login in that reduced environment.
Read-only auth-status comparison identified this setup issue: normal environment logged in, minimal environment not logged in, identity-restored environment logged in.
The disposable configured wording wrapper restored only normal identity environment alongside HOME/PATH, then the fresh model scenario passed.
No credential store was read directly or changed, and no sign-in was attempted.
`model-diagnostic.json` retains the initial CLI failure; it was a setup failure, not a product failure.

## Commands and retained checks

- `FM_LIVE=0 bash bin/fm-test-run.sh --jobs 1 tests/fm-discord-dispatch.test.sh tests/fm-discord-reply.test.sh tests/fm-discord-hook.test.sh` — all three completed successfully, no gate skips; retained as `targeted-tests.log`. These fixture suites are supplemental, not the live proof.
- `PYTHONDONTWRITEBYTECODE=1 python3.14 -I .local-ack-validation/drive.py` — all five grouped local product scenarios passed; `drive.py` retained for reproduction.
- `PYTHONDONTWRITEBYTECODE=1 python3.14 -I .local-ack-validation/model.py` — real model wording and local publication passed after setup correction; `model.py` retained for reproduction.
- Process inspection after completion found no remaining acknowledgement/model child.
- Disposable sources, lab homes, journals and drivers removed from the working tree after retaining evidence.

This is local approval/publication evidence, not transport delivery evidence or a two-host deployment certification.
No Discord UI was rendered, so screenshots are not applicable.
Both-host rollout and activation remain owner-controlled and out of scope for this inactive adapter change.
The separate PR phase must retain the three firstmate-discord documentation follow-ups and the choice to rely on live caption validation, as required by intent.
