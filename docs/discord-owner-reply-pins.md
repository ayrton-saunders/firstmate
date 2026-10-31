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
Run the installed command on the parent machine with an explicit local copy of the intended transport manifest:

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
The command uses only the standard Python library and a read-only Git query, without importing the private package, opening journals, reading bot credentials, contacting Harbour, or changing services.
It verifies identity fields only, not the complete manifest schema, package hashes, readiness, domain mapping, or service health.
A copied manifest proves only that copy; the owner must ensure it is the manifest actually installed on the transport machine.

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
The [portable regression](../tests/fm-discord-verify-pins.test.sh) exercises identity agreement, each mismatched identity field, dirty lifecycle source, and invalid inputs in temporary local fixtures, checking that verification changes no fixture files.
