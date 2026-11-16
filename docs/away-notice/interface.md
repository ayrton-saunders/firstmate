# Away notice lifecycle

The [adapter header and help](../../bin/fm-away-notice.py) own invocation, trusted enrollment, disclosure constraints and the slice-1 facade interface.
This page owns the fork's delivery lifecycle and recovery contract.
Domain binding does not enroll a bot, provision credentials or prove channel privacy.
Enrollment and a harmless live test each require separate concrete approval; reply-to-decision handling is out of scope.

## One durable lifecycle

A row owns its typed source reference, original reviewed target, frozen lifecycle identity/proposal once checked, state, current fixed failure reason and withdrawal reason.
The six states are `queued`, `uncertain` (approval may have committed), `owed`, `delivered`, `withdrawn`, and `reconcile` (needs reconciliation).

For a typed report while away with private reach selected, report intent and the away record's binding hash are committed before configuration or evidence lookup.
A configuration failure leaves that queued reference and a bounded failure record.
Deferred lookup may materialize the reviewed target only when its hash matches the original recorded binding; it cannot adopt a replacement destination.
Failed lookup remains queued and is retried on subsequent report/drain invocations, without requiring a new typed report or waking main.
Duplicate reports coalesce on the checked hold lifecycle or PR URL/head/ready identity plus mapping ID, not on outcome sequence.
Terminal identities remain for dedupe; changed heads/holds require fresh checks.
PR readiness follows the repository's no-CI semantics ([readiness implementation](../../bin/fm-dod-lib.sh)): a successful empty check rollup at the recorded head is ready without CI; otherwise checks must pass.
Pending/failing checks and forge-query errors never count as ready.
Positively observed head change or lost readiness withdraws possibly approved unsent notices as superseded.
Red/pending checks leave never-attempted queued work waiting; genuine forge errors preserve every live notice with temporary failure health.

Every drain rechecks live unsent rows.
Temporary hold, forge or configuration-read errors leave their state unchanged with a current failure; they do not prove resolution or revoke an approval.
Positive resolution, supersession, enrollment replacement/revocation, or ended away mode starts disposal.
Only never-attempted queued rows can be cancelled locally.
Every possibly approved row needs parent withdrawal acknowledgement.
Failed/uncertain withdrawal remains `reconcile`, retrying only disposal.
Parent denial without proven invalidation stays a reconciliation concern; it is not relabelled as enrollment revocation.

`return` attempts withdrawal of every owed, uncertain and reconciliation row with `away-ended` before printing, including when the away record has already been archived.
It has no row-count truncation; individual row and facade calls have bounded timeouts, with failures retained for reconciliation.
A delivered receipt preserves delivery evidence.
No transition processes an outcome, resolves a hold, releases work, clears an inbox note or implies human acknowledgement.

Each row is processed in a separate invocation of the same adapter entrypoint, which re-execs into that row's pinned interpreter before loading its facade.
A mixed-domain drain or return cannot retain a previous row's domain, interpreter, or imported modules.
An explicitly supplied caller `FM_DISCORD_DOMAIN` remains a constraint: foreign-domain operations stay pending rather than stripping that selector to gain authority.
SQLite serializes row transitions across invocations.
A durable reservation precedes every potentially new approval, including uncertain replay: at least 30 seconds apart and at most ten within 600 seconds for the same destination.
Confirmed owed rows use `state`, not approval replay.
Excess remains queued and is rechecked, not reminded periodically.

## Selection is not health

Away entry records explicit selection and a verified binding even if capability or current delivery health is unavailable.
It never converts that selection to none because an earlier failure exists.
No binding is invented when enrollment cannot be validated; a fresh entry can bind restored enrollment.
Old obligations retain their original target and cannot be retargeted.
A changed parent journal is refused for reconciliation rather than silently consulting a replacement journal.

Read-back derives availability from current capability and live rows: current row failures, uncertain approval and reconciliation mean unavailable; ordinary queued traffic and healthy owed rows mean configured, not delivered.
Corresponding row recovery or acknowledged disposal clears that row's failure.
The bounded historical failure log (twenty fixed codes) is return evidence only.
There is no global or report-keyed health latch.
An unrelated successful report cannot clear another row.

Journals with the incompatible pre-release schema are refused rather than silently converted, dropped or reinterpreted as real parent approvals.
Such journals need explicit disposition; no migration of live obligations is claimed.

## Offline verification entry points

[Adapter fixtures](../../tests/fm-away-notice.test.sh) exercise the CLI and host report twin, including lifecycle recovery, traffic shaping, domain isolation and independent bookkeeping.
Its optional `FM_NOTICE_REAL_SOURCE` input selects a reviewed slice-1 source checkout for isolated real-facade tests; the runner owns invocation details.
Those cases use disposable journals and seed closed receipt evidence locally, without network or Discord transport.
They are not channel privacy qualification or live delivery evidence.
[Pi report-tool fixtures](../../tests/fm-pi-branch-extension.test.sh) cover the sequence/actor contract and outcome durability when the adapter fails.
