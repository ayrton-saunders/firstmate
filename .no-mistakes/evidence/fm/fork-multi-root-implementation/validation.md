# Stage 1 characterization validation

The change is confined to seven test/audit files; no application runtime, enrollment producer, installed launcher, or service implementation changes.
The results below are executable fixture evidence, not live named-lane qualification.

## Observations

- The five new targeted subjects completed successfully at the target revision.
- Identical characterization, golden, cleanup, and mutation subjects completed against extracted `bin/` bytes from both the gate base `e1b433ef2fb621a442847ea4a308364dede17a80` and the plan baseline `13fa726dfcbb722e9fa7fdf2e455f5f6609a5f1d`.
- Frozen observations include orphan-reaper output and TERM footprint, candidate runner/serve/lane command shapes, route defaults, readiness check/fix/check and exit 255, actual Git fast-forward/current effects, legacy queue paths/modes/service label, and teardown's reaper invocation.
- All six deliberate mutations failed for their intended golden assertions: session default, exit 255, current-sync output, reaper output, queue label, and removal of teardown's reaper call.
- The inventory CLI emitted 308 modules and 4530 sites: 15 characterized-legacy, 4515 explicitly unclassified, all excluded from named dispatch. Non-executable Perl capture and Lua reader entries are present with explicit boundary/test mappings. The increase from the attached verification plan reflects the recorded inventory correction.
- The inventory fixture rejected an enabled-dispatch policy; actual legacy ingress rejected both known and unclassified protocol-2 payloads before state creation.
- Existing entrypoint, transport-lanes, and doctor subjects completed successfully. `fm-on` exceeded an initially imposed 240-second bound, then completed successfully in 257.763 seconds when run alone with a 600-second bound. No product repair was needed.

## Evidence files

- `remote-root-inventory.json`: actual generated audit output, including exclusion mappings and remaining stage obligations.
- `stage1-target.log`: five new targeted subjects, including negative-control outcomes.
- `stage1-baseline.log`: same characterization subjects against the gate base.
- `stage1-planned-baseline.log`: same subjects against the plan's original baseline.
- `legacy-transport.log`: existing compatibility subjects and the initial timeout.
- `fm-on-serial.log`: completed isolated rerun resolving that timeout.

## Limits and remaining stages

This increment changes test contracts and audit metadata, not the running product. Fixture stubs and sandboxed signals are not live adapter, launchd, SSH, or named-lane validation. No live fleet, route, default backend session, shared service, login, or installed bundle was operated. No GUI changed; visual evidence is not applicable.

Stage 2 retains installed pre-open admission and fixed-bundle records/diagnosis (R1/R4); the real parked-adapter slice precedes broad Stage 3 (R1/R6). Stage 3 retains complete actual-operand closure and fence-time population/drain controls (R1/R2/R6). Stage 4 retains real private workers, footprints and mixed-account ownership exclusions (R5/R6). Stage 5 retains exact-target operations, process-death reconciliation, atomic release and row-scoped publication replay (R3/R4/R6). Compatible bundle replacement remains deferred. Stage 6 alone may enable producers after complete closure and real adapter qualification, followed by separately authorized isolated macOS qualification.

All test children were awaited or terminated by the runner. A process inspection found no remaining fixture-path processes before transient fixture removal. No source changes were made. Broad suites, lint, static analysis, publication and CI were not run in this phase.
