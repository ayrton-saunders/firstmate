---
name: updatefirstmate
description: >-
  Update Firstmate when the captain invokes /updatefirstmate or asks to update Firstmate.
  On the personal fork, prepare and qualify original-upstream integration separately from verified origin consumption; preserve independent secondmate origins and finish primary activation by human-owned fresh-process handover.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Keep preparation, checked publication, consumption and loaded activation distinct.
`bin/fm-update.sh --help` and its header own exact interfaces and task-record mechanics.
No-argument callers retain origin-only consumption; they never integrate or publish upstream changes.
Consumption needs no contributor role, but any integration publication loads `firstmate-self-repo` and uses normal task consent and delivery ownership.

## 1. Choose the bounded target

On personal fork `github.com/ayrton-saunders/firstmate`, read the advertised default branches and exact fork O and original-upstream U (`github.com/kunchenguid/firstmate`).
Confirm configured identities rather than trusting remote names.
Canonical is read/fetch only; publication, push and evidence destinations must all be the personal fork.
The selected setup uses canonical's read remote named `canonical`, with fork `origin` unchanged and no higher-precedence publication remote selecting the parent.
If role resolution or actual installed no-mistakes routing disagrees, stop with the concrete mismatch; do not reinitialize, change shared routing/settings, broaden consent or migrate origins.
Other installations retain their existing origin-only operation unless their operator separately authorized integration.

If O contains U, skip integration and consume the freshly verified intended fork revision.
If it does not, dispatch an ordinary isolated integration task at exact O under the accepted intent, with normal no-mistakes delivery and fork-only consent.
Use that already-dispatched copy; the updater never allocates a copy or manages pool slots.
A new upstream target after this bounded attempt is a later update, not a reason for an endless catch-up loop.

## 2. Prepare without touching active homes

The integration worker invokes `--prepare-upstream` with the observed identities/defaults/O/U and a new private directory under its existing task report.
It classifies contained, fast-forward or divergent history, preserves both ancestries, and retains its conflict/unknown record even across interruptions and a later clean index.
A preparation refusal preserves the index and existing task material; inspect it rather than resetting, stashing, aborting or overwriting an occupied attempt.
Repeated preparation requires the same identities and a retained candidate containing O and U.
If refs moved, retain this attempt and reclassify before starting a newly authorized one.
Preparation emits no restart actions, runs no validator and publishes nothing.

Record the deliberate fork delta `merge-base(O,U)..O`, including skill behavior, in this task's qualification evidence.
A textual no-conflict result is not semantic preservation.
Normal no-mistakes review and focused behavior tests must exercise those customizations against the combined result, including subsequent pipeline repairs.
Repair an in-scope semantic defect through that normal path without inventing another human approval or a parallel manual review.
Changing deliberate behavior, expanding scope, destructive changes and security-sensitive choices still escalate.
For prose-only behavior, retain real evaluation evidence; file/source-string presence does not prove the instruction is obeyed.

## 3. Qualify the actual published head

Use the existing no-mistakes pipeline as the sole review/test/docs/push/PR/CI owner.
Recheck actual fork-only destinations immediately before entering it.
The initial updater implementation and unrelated PRs retain their own merge approval; this skill's scoped automatic authority covers only future qualified upstream integrations.

Keep one qualification package in the existing integration task:

- O/U, original candidate and deliberate fork behavior evidence.
- Actual final published H/tree and real recorded PR URL, current fork base B and the actual tested merge T with exact B,H parents.
- Actual normal Review/Test evidence heads, every later repair delta and evidence artifact, plus current required checks at H.
- Preparation and every pipeline round's conflict provenance, resolved paths/diff/rationale, applicable authority or explicit conflict-resolution approval bound to H.
- Actual landed M/parents/tree, publication outcome, consumption results and outstanding activation.

Obtain evidence from the installed tool's supported status/log/evidence interfaces, not from an ancestor's green label or a fabricated compliance body.
`--qualify-upstream` checks the supplied normal evidence heads, both final ancestries, published task branch, fresh base/upstream identities and tested-merge provenance.
Supply its pipeline-history input only from actual complete pipeline provenance, including later repair rounds; absent or uncertain provenance is `unknown`, never inferred clean from an index.
The checker is a local proof check, not an attestation of how its caller obtained evidence and not merge authority.
Its strict supported evidence path requires the current base in H, T's tree equal to H's reviewed tree, Review at H and Test at H or that actual tested merge T.
A later repair with different evidence heads stops until supported narrow normal revalidation supplies final-head coverage; do not enable global/trusted defaults or substitute another audit.
An ancestry-only/empty-tree-diff candidate currently stops qualification: skipped pipeline phases or absence of a real checked PR cannot prove publication.

If the pipeline lost O/U ancestry, preserve its fixes and original conflict evidence.
Regain exclusive custody only through a supported terminal/custody handoff, then append an integration retaining both histories and run normal validation again.
A green CI-ready return alone is not exclusive custody: a monitor may still publish repairs.
If the installed tool cannot establish custody, final evidence, tested-base provenance or conflict history through a supported bounded route, record that exact compatibility blocker and stop before merge/consumption.
Do not hand-edit an active pipeline, change dependency code/settings, force its branch or loop through the same unsupported rebase path.

## 4. Land exactly what qualified

Future conflict-free upstream integrations need no separate human merge approval once normal review/tests, preservation evidence, qualification and every current required check pass.
Any integration that required conflict resolution returns for explicit approval of exact H with its resolution evidence, even if the final index is clean.
Unknown history cannot use the conflict-free exception.
Any changed H returns to normal qualification, not automatically to another human call for an ordinary in-scope repair.

Use only the existing `bin/fm-pr-merge.sh` checked merge owner, with `--expected-head H` before its separator and explicit `-- --merge` to preserve ancestry.
The expected-head input must be the same full H just qualified; the helper compares its fresh live head and passes that identical H to backend head matching.
Squash/rebase landing is unsuitable for preserving canonical identity.
Never merge red or missing required checks or treat this integration policy as approval of the initial implementation PR.

Head matching does not freeze a non-strict base.
If observed base content changes, revalidate it before landing.
After a merge response, independently read the actual PR's merged state and actual landed M from the forge; queued, timed-out and unreadable responses remain unproved until reconciled.
Then invoke `--verify-landed` in the retained integration copy to check actual fork M, exact qualified B,H parents/tree and H/U ancestry.
This is Git correspondence proof, not a replacement for the forge merge record or normal checked-publication evidence.
A discrepancy is an already-published partial outcome: stop consumption, preserve history and report it without rewinding.

## 5. Consume only the verified origin

Run `--consume-origin M` in the intended primary source with the active explicit `FM_HOME` after all publication proof is complete.
Verify the physical source/home and clear stale task/root/path overrides or set their intended values explicitly; current directory alone does not override inherited paths.
For the contained case, pin the independently verified intended landed origin instead.
The primary must safely advance to that exact advertised origin commit; movement, dirty/wrong-branch/active-operation/shallow/divergent conditions refuse before any secondmate action.
Never silently substitute a newer origin revision; reconcile it first.
No-argument origin-only callers retain their older best-effort skip behavior and are not a substitute for this pinned path.

Read actual per-home results and only the emitted action sets.
Linked and standalone local homes retain their own origin semantics; remote routes update their configured code root from its own origin, then sync the persistent home.
Parent-targeted startup convergence is different from origin consumption and does not migrate an origin.
Dirty, unique-divergent, unsafe and unreachable homes stay preserved; retain their durable reconciliation records.
No successful primary update implies every home reached the same revision.

For the entire emitted restart list, use `fm-secondmate-restart.sh` with the active `FM_HOME`; skip an empty list.
Its existing persistence replies, ownership checks and current-incarnation reconciliation remain authoritative, including concurrent automatic relaunch and interrupted operations.
Timeout never authorizes killing a mate; reconcile the current incarnation before retrying an old list.
Already-current live mates can still need restart because a file diff cannot prove loaded wiring.
Read actual `restarted`, `nudged` and `unreached` results; only the first proves replacement.
Use `fm-send.sh` only for emitted nudge targets; a reread is not a reload.
Do not restart skipped homes or reconstruct an unreachable remote locally.

## 6. Finish activation truthfully

If the updater reports changed instructions, reread `AGENTS.md` before further decisions, but do not claim this reloads skills/extensions.
Persist open work and a handover containing intended source/head/home and remaining per-home actions.
Primary activation is a separate human-owned fresh-process handover: the human quits the old primary normally, proves it exited, then launches a fresh ordinary process from the intended source with the same explicit home and no stale source/task overrides.
Do not self-restart the primary or launch a concurrent replacement.

After that fresh launch, verify source/head/home, new process ownership, intended loaded resource paths and source/turnend/watch hashes.
A branch marker is PID evidence only; child capability probes or arbitrary marker writes cannot establish primary activation.
Keep the original home and its current private work/journals rather than rolling back operational records.

Report published revision, source-on-disk result, loaded activation and per-home skips/unknowns separately.
A PR alone means review/checks/publication remain pending, not that the fleet updated.
Repeated/interrupted operations resume from exact recorded identities and actual outcomes, never duplicate an unproved merge/restart or erase partial success to look atomic.
