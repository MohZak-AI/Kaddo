# Phase 2 compact session handoff

Task checkpoints are saved here for the next session. There is no callable context
compaction API in this session; this file preserves the completed work instead.

## Task 2.1 — workspace subscription

Implemented `WorkspaceContextWatcher` with a direct subscription to
`NSWorkspace.shared.notificationCenter` / `didActivateApplicationNotification`.
Startup reads the current frontmost app. Native `NSRunningApplication` payloads
become Sendable value snapshots; background notifications hop to the main actor.
Malformed payloads are ignored. Start/stop are idempotent, observer release
unsubscribes, and generation IDs prevent queued events from surviving a restart.

Validation: package builds and `PetApplicationStateTests` passes. Evidence:
`artifacts/phase-2-task-2.1.log`. Dedicated integration tests follow in Task 2.4.

## Task 2.2 — normalized layout mapper

Added immutable `ApplicationContextMapper` and strict `PetLayoutCategory` cases:
`coding`, `communication`, and `general`. Identifiers are trimmed and lowercased
on both configuration and lookup. Exact membership prevents prefix/suffix matches.
Xcode, VS Code and IntelliJ default to coding; Slack/Discord to communication;
unknown/empty/missing IDs to general. Configurable sets have documented coding
precedence for overlap.

Validation: 2 mapper XCTests pass, covering normalization, defaults, lookalikes,
unknown IDs, custom sets and overlapping configuration. Evidence:
`artifacts/phase-2-task-2.2.log`.

## Task 2.3 — activity polling and shared state

The application delegate now owns/starts/stops the watcher. Added published
`PetApplicationState.layoutCategory`; layout mapping and sleeping emotion are
separate, so an app category remains available while the pet sleeps.

A 100 ms common-run-loop timer samples screen pointer coordinates and the native
combined-session last-input interval. The latter includes keyboard, mouse, and
tablet input ([Apple API reference](https://developer.apple.com/documentation/coregraphics/cgeventsource/secondssincelasteventtype(_:eventtype:))).
No event tap or keyboard contents are captured. Native elapsed input durations
remain durations to avoid timestamp-rounding errors at the 600-second boundary.
App changes and cursor displacement reset a monotonic local activity timestamp.
At >=600 seconds without either local context activity or native input,
`currentEmotion` becomes `.sleeping`. Renewed input or an app switch restores the
emotion the watcher suspended. An intervening explicit emotion takes precedence
on wake. Duplicate app activations do not reset inactivity. Invalid idle samples
fall back to awake. The observer token owns its timer and invalidates/removes both
on stop or deallocation. No threshold wall-clock waits are needed in tests.

Validation: all 10 then-existing canvas XCTests passed after integration; evidence
`artifacts/phase-2-task-2.3.log`. Dedicated boundary, timer and recovery coverage is
in Task 2.4. Ten-minute live desktop inactivity remains a native acceptance check.

## Task 2.4 — notification and activity integration tests

Added `WorkspaceContextWatcherTests` (15 XCTests) beside the existing native canvas
harness. Tests exercise the production watcher and shared observable model with
isolated NotificationCenters, Apple's notification name and native
`NSRunningApplication` payloads. They also verify the default workspace center
and read the real native activity provider. The fake clock/activity samples avoid
waiting ten minutes; a separate test runs the real common-mode timer at the
production 100 ms interval.

Coverage includes normalized startup mapping, published category changes, native
and background activation, malformed payloads, duplicate start/stop, queued events
across restart, automatic observer/timer release, 599.9/600-second boundary,
keyboard/transient-pointer activity, negative pointer coordinates, app-switch
wake, duplicate activation, emotion preservation and invalid idle samples.
Notification, polling sleep and wake assertions each have a 300 ms deadline.
A rounding failure found during implementation was fixed by retaining native
input intervals as durations rather than repeatedly reconstructing timestamps.

Final validation:

- `./scripts/test.sh --filter KaddoCanvasTests`: **25 passed**, 0 failures,
  including 2 mapper and 15 watcher tests. `artifacts/phase-2-canvas.log`.
- `./scripts/test.sh --filter HarnessTests`: **7 passed**, 0 failures.
  `artifacts/phase-2-harness.log`.
- `./scripts/build-app.sh`: release build and ad-hoc signing verified in
  `artifacts/phase-2-build-app.log`; output `.build/Kaddo.app`.

## Resume in the next session

1. Read this handoff, `README.md`, and `docs/native-acceptance.md`.
2. Re-run the native canvas and harness filters above as needed.
3. Launch the rebuilt app with `open .build/Kaddo.app` for desktop acceptance.
   No app was relaunched during Phase 2; a still-running Phase 1 process must be
   quit/reopened before evaluating the new watcher.
4. Finish N06: actual app switches, 600 seconds without input, then keyboard and
   cursor wake. Phase 2 publishes categories; layout variants and focus rewards
   remain later work. Earlier cross-app/Spaces/display checks remain pending.
5. Continue the next user-authorized phase. No packages or permissions were added.

The older `MVPFactory.attention` is still unbound, like the other MVP factories.
It exposes a different focused/distracted attention protocol, not layout categories.
Its legacy `inactivityHasPriority` test requires stale 700-second idle data to keep
the pet sleeping even when a different app activates. This phase follows the new
workspace inactivity requirement: a changed app resets the no-switch interval and
wakes the pet. Resolve that contract difference explicitly when adapting the
broader focus/attention engine; do not claim the full acceptance suite passes.
The existing factory assertions were preserved. The full suite was not rerun
because those unimplemented factory boundaries are already known to fail.

All repository files were untracked at session start. No existing work was
reverted and no commit was created. All four task checkpoints are complete;
this durable handoff is the next-session compaction substitute.
