# Private Discord owner-reply pins

This page covers identity verification for the [private Discord parent integration](configuration.md#private-discord-parent-integration), not the shared Relay.
It does not install or enable a bot.
The private release remains the authority for its journal and transport recovery procedures.

## Pin ownership

Every new Firstmate source commit changes the parent configuration's `source_commit`, even when the change is documentation only.
The configuration's `source_digest` is the private v2 release's SHA256 of the canonical JSON map from lifecycle filenames to their SHA256 hashes: `bin/fm-inbox.sh`, `bin/fm-send.sh`, `bin/fm-spawn.sh`, and `bin/fm-discord-hook.py`.
Uncommitted changes to those files also change the digest; the digest does not cover other uncommitted files.
The source must be the canonical installed parent source directory, not another copy with similar contents.

The transport manifest's `parent_identity` must match that same `source_commit` and `source_digest`, plus `home_identity`, the SHA256 of the canonical parent home path encoded as UTF-8.
Each domain must use its own approved home and mapping; matching a source commit alone does not authorize another domain.
Changing the home changes its identity even if the source is unchanged.
The parent configuration's private package `hashes` and `python_executable` are separate release/runtime requirements, not replaced by this comparison.

The transport journal also remembers the observed parent identity and epoch in `remote-epoch/parent`.
Updating the two configuration files does not reconcile that remembered observation or clear existing fences.
The transport fences intake on a manifest identity mismatch, and fences intake and delivery when a previously observed identity or restore epoch changes.

## Read-only verification

The [verification command's help](../bin/fm-discord-verify-pins.py) owns its flags and input requirements.
Run the installed command on the parent machine with an explicit local copy of the intended transport manifest for a configuration-only comparison:

```sh
python3 -I bin/fm-discord-verify-pins.py \
  --parent-config /absolute/parent-home/config/discord-integration.json \
  --transport-manifest /absolute/review-copy/transport.json
```

A successful comparison prints exactly:

```text
Discord source/config/manifest pins agree; journal epoch and fences not checked.
```

A mismatch returns nonzero and names the disagreeing pin without printing private paths, tokens, or configuration contents.
Disabled, malformed, missing, duplicate-key, oversized, or symlinked input files are refused rather than treated as agreement.
This mode uses only the standard Python library and a read-only Git query, without opening journals.
Neither mode imports the private package, reads bot credentials, contacts Harbour, or changes services.
Neither mode verifies the complete manifest schema, package hashes, readiness, domain mapping, or service health.
A copied manifest proves only that copy; the owner must ensure it is the manifest actually installed on the transport machine.

### Remembered epoch and fences

To include the remembered observation and unfencing checks, supply both standalone offline journal snapshots using the [command's snapshot flags](../bin/fm-discord-verify-pins.py).
Create coherent backups through the private release's reviewed backup procedure, then transfer them to a local review directory.
Never copy only a live SQLite main file: committed records may still be in its WAL.
Do not use an active journal as a snapshot, even if it currently has no sidecars.

```sh
python3 -I bin/fm-discord-verify-pins.py \
  --parent-config /absolute/parent-home/config/discord-integration.json \
  --transport-manifest /absolute/review-copy/transport.json \
  --parent-journal-snapshot /absolute/review-copy/parent.sqlite \
  --transport-journal-snapshot /absolute/review-copy/transport.sqlite
```

A successful extended comparison prints exactly:

```text
Discord source/config/manifest/remote-epoch pins agree; parent and transport intake/delivery fences are clear (offline snapshots only).
```

The transport snapshot's `remote-epoch/parent` observation must match the configured parent identity and the parent snapshot's restore epoch.
Both schema 2 snapshots must show clear intake and delivery fences.
Missing or malformed observations, stale identities or epochs, remaining fences, incomplete snapshot arguments, identical snapshot files, configured live journal paths, and snapshots with WAL, SHM, or rollback-journal sidecars are refused.
Snapshot connections are immutable and read-only; the command does not instantiate the private journal owner, create sidecars, reconcile an epoch, or clear a fence.
The result describes the supplied snapshots, not current live readiness or delivery health.
Only the owner can establish that those backups coherently represent the intended domain at the required point in the installation procedure.

## Owner actions after a source update

Do not update the parent pin alone and restart intake.
The required transition is:

1. Fence and quiesce the relevant domain through the approved private release procedure, preserving all existing custody and outstanding work.
2. Install the approved Firstmate source and any separately approved private release/runtime changes.
3. Derive the new source identity once and apply it to both the parent configuration and the transport manifest's `parent_identity`, retaining the exact domain's home identity.
4. Run the read-only comparison against the intended installed files and stop on any mismatch.
5. Reconcile the transport's `remote-epoch/parent` identity and epoch against the authoritative parent, using the private release's reviewed recovery procedure rather than deleting journal history or guessing an epoch.
6. Explicitly unfence intake and delivery only after reconciliation and outstanding obligations have been checked.
7. Restart the domain's installed service through its existing service manager and prove one owner message and one correlated final reply end to end.

This comparison is not authority to perform those actions, and agreement is not evidence that reconciliation, unfencing, or the round trip has completed.
The [portable regression](../tests/fm-discord-verify-pins.test.sh) exercises configuration and offline snapshot agreement, each mismatched identity field and restore epoch, every fence, dirty lifecycle source, and invalid inputs in temporary local fixtures, checking that verification changes no fixture files.
