# Away notice lifecycle and slice-1 interface

`bin/fm-away-notice.py` owns this outbound-only fork adapter. Its header is the
executable contract. Selection is **off by default**: absent configuration or
`{"reach":"none"}` publishes nothing. `config/away-reach.json` can explicitly
select `{"reach":"discord-private","domain":"personal"}`. The separately
reviewed `away-notices.json` in that domain supplies the immutable mapping and
project disclosure policy; it does not enroll a bot or prove channel privacy.
No enrollment, live Discord test, reply-to-decision handling, work release or merge
authority is granted here.

## Actual merged facade

Qualified against firstmate-discord main
`45e67bfeaf33d787e7dbf7ffaf4ca186f2e9f018`, not an invented approval surface.
The trusted domain/runtime guards import `personal_discord.private_notice` and
require `CAPABILITY == 'private-notice-v1'`. Actor provenance stays intact.

- `available(config=config)` is configuration-only readiness: enabled, both
  `private_notices` capability declarations, and valid non-retired enrollment.
  It is neither transport health nor delivery proof.
- `approve(config=config, notice=proposal)` takes `notice_id`, `mapping_id`,
  `template_id`, `approved: true`, and only the template's used fields below.
  `mapping_id` comes from the real `personal_discord.mappings.mapping_id` of the
  original trusted mapping. Lifecycle identity is hashed locally, not sent.
- `state(config=config, notice_id=..., mapping_id=...)` reconciles a confirmed
  owed notice without creating another approval.
- `withdraw(config=config, notice_id=..., mapping_id=..., reason=...)` uses exactly
  `resolved`, `superseded`, `enrollment-revoked`, or `away-ended`. It always uses
  the original mapping, never a replacement. State and withdrawal do not require
  availability after capability disablement or retirement.
- All receipts are exactly `{notice_id, state}` with the same ID and state
  `owed`, `delivered`, or `stopped`. Unknown delivery remains owed; denial maps to
  stopped and remains a reconciliation concern. Withdrawal returning owed is
  not disposal. A delivered receipt is never downgraded or locally unsent.

| Template | Additional proposal fields | Parent-owned wording |
| --- | --- | --- |
| `decision-waiting` | reviewed `project_alias`; no URL | A decision is waiting for the {alias} work. Please review it in our usual conversation. |
| `sensitive-decision` | neither alias nor URL | A decision is waiting. Please review it in our usual conversation. |
| `pr-ready` | reviewed `project_alias`, exact `pr_url` | The {alias} work is ready for review: <{pr_url}>. Review it in our usual conversation. Discord replies do not approve it. |

Aliases follow the real facade's ASCII-letter initial, letters/digits/spaces/hyphens,
64-character bound. PR URLs are exact enrolled-repository HTTPS GitHub paths with
one to ten decimal PR-number digits, no userinfo, query or fragment. The parent
owns rendering, mention/preview suppression, egress, Discord retry-after and receipts.
The adapter cannot accept raw report/status/transcript/error/body/attachment fields
for publication: its only source input is an outcome sequence, task and typed kind;
its only outgoing proposal is the fixed field set above. It sends neither `origin`
nor `identity`. This is a structural disclosure restriction, not prose filtering.

## One durable lifecycle

A row owns its typed source reference, original reviewed target, frozen lifecycle
identity/proposal once checked, state, current fixed failure reason and withdrawal
reason. The six states are `queued`, `uncertain` (approval may have committed),
`owed`, `delivered`, `withdrawn`, and `reconcile` (needs reconciliation).

Report intent and the away record's binding hash are committed **before
configuration or evidence lookup**. A configuration failure leaves that queued
reference and a bounded failure record. Deferred lookup may materialize the
reviewed target only when its hash matches the original recorded binding; it
cannot adopt a replacement destination. Failed lookup therefore remains queued
and is retried on ordinary supervision drains, without requiring a new report or
waking main. Duplicate reports coalesce on the checked hold lifecycle
or PR URL/head/ready identity plus mapping ID, not on outcome sequence. Terminal
identities remain for dedupe; changed heads/holds require fresh checks.

Every drain rechecks live unsent rows. Temporary hold, forge or configuration-read
errors leave their state unchanged with a current failure; they do not prove
resolution or revoke an approval. Positive resolution, supersession, enrollment
replacement/revocation, or ended away mode starts disposal. Only never-attempted
queued rows can be cancelled locally. Every possibly approved row needs parent
withdrawal acknowledgement. Failed/uncertain withdrawal remains `reconcile`, retrying
only disposal. Parent denial without proven invalidation stays a reconciliation
concern; it is not relabelled as enrollment revocation.

`return` withdraws **every** owed, uncertain and reconciliation row with `away-ended`
before printing, including when the away record has already been archived. It has
no row-count/deadline truncation. A delivered receipt preserves delivery evidence.
No transition processes an outcome, resolves a hold, releases work, clears an inbox
note or implies human acknowledgement.

Each row is processed in a separate invocation of the same adapter entrypoint,
which re-execs into that row's pinned interpreter before loading its facade.
A mixed-domain drain or return cannot retain a previous row's domain, interpreter,
or imported modules. An explicitly supplied caller `FM_DISCORD_DOMAIN` remains a
constraint: foreign-domain operations stay pending rather than stripping that
selector to gain authority. SQLite serializes row transitions across invocations.
A durable reservation precedes every potentially new
approval, including uncertain replay: at least 30 seconds apart and at most ten
within 600 seconds for the same destination. Confirmed owed rows use `state`, not
approval replay. Excess remains queued and is rechecked, not reminded periodically.

## Selection is not health

Away entry records explicit selection and a verified binding even if capability or
current delivery health is unavailable. It never converts that selection to none
because an earlier failure exists. No binding is invented when enrollment cannot
be validated; a fresh entry can bind restored enrollment. Old obligations retain
their original target and cannot be retargeted. A changed parent journal is refused
for reconciliation rather than silently consulting a replacement journal.

Read-back derives availability from current capability and live rows: current row
failures, uncertain approval and reconciliation mean unavailable; ordinary queued
traffic and healthy owed rows mean configured, not delivered. Corresponding row
recovery or acknowledged disposal clears that row's failure. The bounded historical
failure log (twenty fixed codes) is return evidence only. There is no global or
report-keyed health latch. An unrelated successful report cannot clear another row.

The earlier, unreleased guessed-facade SQLite schema is refused rather than silently
converted, dropped or reinterpreted as real parent approvals. Any such private test
journal needs explicit disposition; no migration of live obligations is claimed.

## Offline qualification

Portable behavioral fixtures:

```sh
bash tests/fm-away-notice.test.sh
```

Real-facade qualification command used for this change (read-only archived source;
all runtime/package copies and journals are disposable test fixtures):

```sh
FM_NOTICE_REAL_SOURCE=/Users/ayrton/.treehouse/personal-3b61fd/3/personal/data/fork-discord-away-notice-adapter/slice1-main \
  bash tests/fm-away-notice.test.sh
```

The fixture executes the CLI with branch provenance and the real host report twin.
The real-facade cases use unmodified `private_notice`, `admin`, `Integration`,
`Parent`, `Mappings` and isolated real SQLite journals. They assert exact wording for
all three templates, immutable event dedupe, owed/read-back distinction, no synthetic
request, retirement/capability-disabled withdrawal, and preservation of closed
parent delivery evidence. The receipt fixture seeds closed evidence only inside its
isolated parent journal; it does not claim a live delivery. No network or Discord
transport is invoked. Portable cases additionally exercise lost receipts, crash
recovery, parallel drains, both rate limits, temporary evidence/config errors,
revocation/re-entry, failed withdrawal after archive, and independent bookkeeping.

Regression coverage also includes report-time malformed enrollment/selection,
binding replacement before deferred lookup, mixed-domain replacement and return,
per-domain runtime isolation, and explicit caller-domain refusal. Real-facade
cases exercise configuration-failure recovery and mixed-domain withdrawal against
separate isolated journals. This is offline contract evidence, not channel privacy
qualification or live delivery evidence.

Pi's report-tool-to-CLI sequence/actor contract remains covered by
`tests/fm-pi-branch-extension.test.sh`; this rewrite keeps that invocation unchanged.
The ordinary pipeline owns the remaining review, tests, lint, PR and CI phases.
