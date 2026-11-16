# Away notice parent boundary

The authoritative executable contract is the header of `bin/fm-away-notice.py`.
This fork uses the separately enrolled `personal_discord.private_notice` API;
it does not implement Discord transport or authorize enrollment or live tests.

## Authorized interface addition: withdrawal

Firstmate must confirm this addition with the slice-1 builder and include it in
the eventual PR description:

`withdraw(config=..., notice=...)` accepts the original immutable notice, preserving
its ID, origin and actor provenance. It returns exactly
`{"notice_id": "<same ID>", "state": "stopped"}` or the same receipt with state
`delivered` when receipt closure already proved delivery. Withdrawal must be
idempotent and atomically fence parent-owned pending egress, including uncertain
approvals and notices whose original enrollment has since changed or been revoked.
It must not create an approval, retarget a notice, or claim to unsend delivery.

The fork rechecks every queued or owed notice on drains. Resolved/replaced holds,
changed PR evidence, revoked or changed enrollment, mismatched recorded bindings,
and ending away mode trigger withdrawal. Unavailable evidence also stops approval
and requests withdrawal conservatively. Failed or unsupported withdrawal retains
a durable reconciliation obligation, retried only as withdrawal, never approval.
Reach reads unavailable while reconciliation or an unrecovered failure remains;
return summaries retain bounded historical failures separately from current health.
Report validation/evidence failures belong to the exact typed report invocation
(outcome sequence, task and kind). Replay that invocation to recover it; an
unrelated drain, another report or restored parent capability cannot clear it.
A successful evidence recheck can also establish that the report is no longer
useful without creating a notice. Configuration and binding failures recover
only through their respective successful checks.

Uncertain approval attempts reserve durable destination traffic allowance before
crossing the parent boundary, including recovery after failure or a crash. Only a
validated approval receipt exempts subsequent reconciliation from new-notice
accounting. Transport retry-after, ambiguous POST recovery and delivery receipts
remain exclusively parent-owned. Outcome, hold and inbox bookkeeping is untouched.
