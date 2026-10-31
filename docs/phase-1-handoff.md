# Phase 1 compact session handoff

**Final status:** Tasks 1.1–1.4 implemented. 8 Phase 1 XCTests and 7 existing
infrastructure tests pass. Release app bundle builds and launches. Cross-app
input/Spaces/multi-display acceptance is still outstanding. Each section below
is a compact checkpoint for a subsequent session; no context-compaction API is
available to the agent in this session.

## Task 1.1 — floating panel

Implemented `FloatingPetPanel` in the new `KaddoCanvas` library, with an executable
target and XCTest target. Uses borderless/nonactivating style, status-bar level,
clear background, no shadow, no keyboard activation, all-Spaces/full-screen
auxiliary behavior, and unrestricted movement between displays.

Window levels are OS-managed priorities. Status-bar level keeps the pet above
ordinary app windows; secure/system surfaces can still appear above it.

Validation: `./scripts/test.sh --filter FloatingPetPanelTests` passes (1 XCTest).
Evidence: `artifacts/phase-1-task-1.1.log`. Setting `isFloatingPanel` resets window
level, so the explicit status-bar level is assigned after that property.
Next: alpha targeting (1.2), shared state (1.3),
SwiftUI drag wrapper and rendered-update XCTest coverage (1.4).

The pre-existing acceptance factories remain intentionally unimplemented. Phase 1
does not implement attention, AI, focus rewards, document import, or file drops.

## Task 1.2 — rendered-alpha passthrough

Added `PointerPassthroughController`. It samples one rendered device pixel at the
pointer, converts screen coordinates into the content view's coordinates, and
sets native `ignoresMouseEvents` accordingly. Local/global movement monitors plus
a 60 Hz common-mode timer refresh targeting even over other apps or when content
changes under a stationary pointer. No Accessibility permission or synthetic click
replay. Mouse-down capture preserves drag/up until release. Explicit stop/close
removes monitors and invalidates the timer.

Validation: 2 XCTests pass; see `artifacts/phase-1-task-1.2.log`. Covers transparent,
partially visible and out-of-bounds pixels, flipped view coordinates, negative
screen origins, changing alpha, capture, and start/stop lifecycle. Real browser
click delivery and rapid pointer/click timing still require desktop acceptance;
the polling/monitor strategy is not a WindowServer per-pixel input region API.

Next: shared application state, then SwiftUI hosting and dragging.

## Task 1.3 — shared application state

Added main-actor `PetApplicationState: ObservableObject`, with published
`currentEmotion`, `speechBubbleText`, and optional value-type `activeTask`.
The app will own one reference and inject it into StateObject/ObservedObject
views. Value-type tasks also publish nested title edits. Keeps macOS 13 support.

Validation: `PetApplicationStateTests` passes; evidence in
`artifacts/phase-1-task-1.3.log`. Tests synchronous publication for all three
properties, task title mutation and task removal. Next: verify real SwiftUI
rendering in the Task 1.4 XCTest suite.

## Task 1.4 — SwiftUI canvas and drag verification

Added `PetCanvasView`, `PetCanvasWindowController`, and `WindowDragController`.
The root owns the injected model via StateObject; speech and sprite subviews use
ObservedObject. The SwiftUI DragGesture measures absolute AppKit screen pointer
coordinates against a fixed starting window origin, avoiding cumulative drift
as the window moves. Gesture completion/cancellation clears its baseline.
The hosting view explicitly accepts the first mouse while another app is active.

The runnable accessory application owns the shared model and canvas, with a
menu-bar recover/quit control, emotion selection and sprite credits. It uses
the selected Frakassets cat with bundled license and static cropped frames.
No sprite animation scheduler has been added in this phase.

Validation: all 8 Phase 1 XCTests pass (`artifacts/phase-1-task-1.4.log`). The
rendering suite compares actual hosted bitmap pixels before/after each model
mutation, confirms unchanged state renders identically, verifies two canvases
share updates, and checks transparent/visible hosted pixels. SwiftUI's render
commit occurs on the next UI cycle; the tests allow a bounded one-second wait,
without replacing the root view. Drag tests cover repeated callbacks, negative
coordinates, release and a second drag. Seven existing infrastructure tests also
pass (`artifacts/phase-1-harness.log`).

`./scripts/build-app.sh` builds a release, ad-hoc signed local app bundle at
`.build/Kaddo.app`. Build evidence: `artifacts/phase-1-build-app.log`.
Native desktop smoke test: the packaged app launched, the accessibility tree
contained its speech and idle pet, and the rendered canvas was inspected.
Screenshot: `artifacts/phase-1-canvas.png`. The app was left running for inspection.

## Resume in the next session

1. Read this file, `README.md`, and `docs/native-acceptance.md`.
2. Run `./scripts/test.sh --filter KaddoCanvasTests` and
   `./scripts/test.sh --filter HarnessTests`.
3. Use `./scripts/build-app.sh` then `open .build/Kaddo.app` to launch the app.
4. Finish native acceptance for cross-app click delivery and first-click dragging,
   rapid alpha transitions, Spaces/full-screen behavior, and physical displays.
5. Proceed with the next user-authorized phase. The old acceptance factories
   still throw `PendingImplementation`; do not report the full MVP suite as green.

No dependencies were added. All original files were untracked at the start of
this session; no existing work was reverted or committed.
