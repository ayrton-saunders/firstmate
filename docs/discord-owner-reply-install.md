# Discord owner-reply install and test

This sheet is for the existing private Discord domain on the parent Mac and Harbour, not the shared Relay or a new bot installation.
Every numbered installation step below needs owner action or explicit owner approval for the existing trusted parent to act.
The local development run must not execute those installation steps: no live journal, service, credential, launchd job or running parent may be changed by that run.
The installed private release owns privileged installation, journal recovery and credential procedures; its reviewed deployment handoff must accompany this sheet.
Never substitute an old frozen helper with hardcoded historical pins or epochs.

## 1. Owner action: approve and freeze the domain

Confirm the exact bot, controlling owner, channel, mapped project, existing second mate and canonical parent home.
Do not infer another domain's authority from matching source revisions.
The [hook's configuration contract](../bin/fm-discord-hook.py) owns the source status fields.
Install the complete approved source, including both commands and the lifecycle hook and owners.
Keep the already approved private package and architecture-matching CPython 3.14 runtime unless a separate immutable-release upgrade is explicitly approved.
No new token, key, user, mapping, ACL, project charter or launchd job is needed for these parent commands.
Any such change needs a separate owner decision, not an installation repair.

On the parent Mac, set these to reviewed canonical absolute paths, without printing configuration contents or credentials:

```sh
SOURCE=/absolute/installed/firstmate-source
PARENT_HOME=/absolute/existing/parent-home
REVIEW=/absolute/private/owner-review-directory
PY_PARENT=/absolute/approved/private-runtime/venv/bin/python
ADMIN=/absolute/approved/private-release/bin/personal-discord-admin
```

Read the command interfaces without opening journals:

```sh
python3 -I "$SOURCE/bin/fm-discord-dispatch.py" --help
python3 -I "$SOURCE/bin/fm-discord-reply.py" --help
```

## 2. Owner action: pause and preserve

Pause only this domain's Discord parent CLI/hook invocations, not the parent reasoning session or unrelated work.
Use the private release's reviewed procedure to fence intake and delivery and quiesce endpoint writers before the cutover.
Preserve custody, pending sends, unknown delivery attempts, owed finals and coherent owner-created backups.
Do not delete SQLite sidecars, recreate journals, relaunch accepted work or fabricate a restore epoch.

On Harbour, stop only the existing transport job, in the owner Terminal:

```sh
LABEL=uk.personal.firstmate.discord.transport
PLIST="/Library/LaunchDaemons/$LABEL.plist"
/usr/bin/sudo -k /bin/launchctl bootout "system/$LABEL"
```

Confirm the label and plist against the existing approved installation before running this command.
Stop on failure or an unexpectedly absent job; do not substitute another service label or kill unrelated processes.
The endpoint remains governed by its separately reviewed pause and resume procedure; stopping transport alone does not prove all journal writers are quiescent.

## 3. Owner action: preserve the domain protections

Keep the domain's canonical home binding, mapping revision and its digest, restore epoch and mention-only admission unchanged.
The hook enforces the configuration schema and home match; the private release owns mapping revision/digest, epoch and mention admission enforcement.
Do not change that release, its transport manifest or its journals through this repository's development work.
Keep the journal paths and interpreter requirements unchanged unless separately approved.
The [hook's configuration contract](../bin/fm-discord-hook.py) owns the enrolled package root rule and treatment of legacy release hashes.
No paired Firstmate commit/digest replacement or source-pin verifier is required.
If installation fails, leave the domain paused with backups intact and follow the private owner handoff.

## 4. Owner action: reconcile, then explicitly unfence

Using the private release's reviewed recovery procedure under the actual owning principals, reconcile Harbour's remembered `remote-epoch/parent` identity and epoch against the authoritative parent.
Read the actual current parent restore epoch; never copy an epoch from this sheet, reset it to remove a warning or overwrite unknown delivery history.
Review all outstanding obligations and unknown sends before explicitly clearing intake and delivery fences on the relevant parent and transport journals.
Do not blindly clear other role journals or enable another domain.
Have each owner create coherent standalone offline backups through the reviewed journal backup procedure after reconciliation and unfencing.
A raw SQLite main-file copy is not a coherent backup when sidecars contain committed state.
Use the private release's reviewed diagnostics to establish epoch agreement and cleared intake/delivery fences.
Stop on any remaining fence or observation mismatch instead of weakening a check.

## 5. Owner action: resume the endpoint and restart only transport

Resume the existing endpoint and parent Discord invocations through the private release's approved sequence, preserving the existing identity and mappings.
On Harbour, use the same reviewed label and plist from step 2:

```sh
/usr/bin/plutil -lint "$PLIST"
/usr/bin/sudo -k /bin/launchctl enable "system/$LABEL"
/usr/bin/sudo -k /bin/launchctl bootstrap system "$PLIST"
/usr/bin/sudo -k /bin/launchctl kickstart "system/$LABEL"
```

Run each line separately and stop on the first failure.
This reloads the installed manifest in the existing transport service; do not install another plist or restart SSH, the parent session or another service.
Confirm the existing service account, reviewed executable and successful startup through owner-reviewed nonsecret diagnostics.
A running process is not proof of Discord authentication or reply delivery.
Do not retry startup blindly after an identity, restore or fence warning.

## 6. Owner action: prove one message and one final reply

1. From the configured controlling owner's Discord account, send one fresh mention to this domain's bot in the approved mapped channel, asking a harmless read-only question.
2. Let the existing trusted parent capture the request through its normal `parent-cycle` and inbox flow; use the actual captured request identifier, never a fabricated record.
3. Have the parent inspect the captured request, confirm its scope and choose the configured second mate for that same project.
4. Have the parent run the dispatch command once with that identifier, route and exact approved question.
5. Wait for the actual authoritative correlated return, then have the parent review it and explicitly approve one short plain-English answer.
6. Have the parent run the reply command with the same identifier and route and only that approved answer.
7. Confirm exactly one final reply in the original Discord thread, authored by this bot, with exactly the approved words, and the transport's corresponding delivered read-back acknowledgement.

The trusted parent uses the following two commands on the parent Mac; replace only the quoted example inputs with the reviewed actual values:

```sh
FM_HOME="$PARENT_HOME" python3 -I "$SOURCE/bin/fm-discord-dispatch.py" 'captured-request-id' 'mapped-secondmate' 'The exact approved read-only question'
FM_HOME="$PARENT_HOME" python3 -I "$SOURCE/bin/fm-discord-reply.py" 'captured-request-id' 'mapped-secondmate' 'The approved one-line answer.'
```

Do not paste the two lines together: the real return and explicit approval must occur between them.
Both commands are silent on success and select the configured pinned runtime themselves.
No lane, work binding, generation, correlation, scope digest or permit is supplied by a human.
The reply must be one nonempty line of at most 400 UTF-8 bytes, without internal identifiers, status labels, private material or progress chatter.
Local publication alone is not Discord delivery; preserve an ambiguous post for reviewed recovery rather than resending it.
Dispatch is one-shot: any error or repeated invocation requires reconciliation, not replacement authority.
An identical approved reply can repair the same final event; changed words cannot overwrite its existing approval.
Expired intake readiness blocks dispatch, but does not erase an already-owed final.
Coding, visual input preparation, continuation and public follow-up authority are outside this read-only question-and-answer path.

## Local qualification and the excluded test

These are development checks, not owner authorization to run the installation steps.
Use disposable homes and short temporary paths, with live model guards disabled; inspect optional real-backend tests before running them on an operational machine.
Preserve the intended development Bash and the suite's Python, Node and npm prerequisites when restricting `PATH` to exclude operational tools.
The enabled Discord command and hook fixtures require `python3.14` by that name on `PATH`; an uppercase `SKIP:` line can accompany a zero exit and is not proof that those fixtures ran.
Check the individual output as well as the runner summary and require the enabled dispatch and reply cases to execute, accounting for any capability skip.
The scoped executable tests are:

```sh
FM_LIVE=0 bash bin/fm-test-run.sh --jobs 1 tests/fm-discord-dispatch.test.sh tests/fm-discord-reply.test.sh tests/fm-discord-hook.test.sh
```

The dispatch suite covers exact payloads and automatic bindings, expired readiness, inadmissible lanes, existing intents, escaping package root refusal, domain isolation and missing delivery receipts.
The reply suite covers authoritative returns, generation/scope/route mismatches, non-active lanes, fences, escaping package root refusal, incomplete publication and duplicate-safe approval.
The hook suite covers source status fields present, stale or absent, optional legacy hashes, enrolled release switching, invalid package root refusal and retained home/schema protections.
Successful fixture verification is not a claim that the live installation is aligned or unfenced.

Exclude exactly `tests/fm-supervision-host.test.sh` from the broad suite for this environment.
This environment's existing live fleet lock and watcher make that supervision test unsafe to run locally; keep baseline evidence in the private qualification report.
Do not rerun, modify or try to repair that test or stop the live fleet.
This exclusion does not waive another failing script or imply that unrun tests passed.

To select every other shell test through the existing runner, in a disposable validation environment:

```bash
scripts=()
while IFS= read -r script; do
  [ "$script" = tests/fm-supervision-host.test.sh ] || scripts+=("$script")
done < <(bash bin/fm-test-run.sh --list --all)
FM_LIVE=0 bash bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 1500 --json "$REVIEW/suite.json" "${scripts[@]}"
```

Keep the exact `FM_TEST_SUMMARY` line, individual failures and capability-skip reasons with the private qualification evidence.
A timeout on another script is a bounded incomplete result, not an automatic new exclusion.
Do not declare broad qualification complete until every other completable script passes and all skips are accounted for.
The scoped checks can pass independently of that still-required broad qualification and the separately owner-run live round trip.
