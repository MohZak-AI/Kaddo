# Companion validation — 27 October 2026

Implemented the Codex-inspired companion controls, activity model/tray, six-second message previews, placement preferences, configurable native shortcut, Mini mode, and flame reactions described in [the companion guide](../../docs/companion-experience.md).

## Automated results

The final desktop-enabled run executed **200 native XCTest cases: 198 passed, two opt-in live Ollama tests skipped, zero failures**. All **seven infrastructure checks passed**. This includes 15 companion experience tests and the existing assistant, planner, document, canvas, pointer, workspace, and keyboard regressions.

Command:

```sh
KADDO_DESKTOP_TESTS=1 KADDO_COMPANION_ARTIFACTS="$PWD/artifacts/companion" \
  ./scripts/test.sh --filter 'KaddoCanvasTests|HarnessTests'
```

Evidence: [final native log](final-native-tests.log). The restricted run also passed; its Carbon integration test is additionally skipped without the desktop opt-in. The older incomplete acceptance factories were not included in this native validation.

Coverage includes:

- Activity priority and acknowledgement; unresolved questions remain Needs input after reading.
- Cancelled/cleared operation rejection; bounded snapshots and citations; a long-running result still appears when its initial row was evicted by more than 20 updates.
- Six-second preview duration, queueing while busy, hover pause, visibility suppression, and disabled previews.
- Reminder delivery during held inference without cancelling the request or overwriting the live answer.
- Hide preserving a running answer and draft; repeated opening focusing the native editor; Escape cancelling inference.
- Preferences, size bounds, Mini/Flame geometry, composer alignment, negative display coordinates, and recovery after a display disappears.
- Native Carbon hotkey registration and dispatch, a real conflicting registration, and release/re-registration. The test uses a temporary Control–Option–Command–F1 combination, leaving the app’s Option–Shift–Space binding untouched.
- Hosted celebration playback under forced Reduce Motion, replay of a new celebration, interruption by a newer pose, sprite cadence/transparency, rendered-alpha click targeting, and native drag controller capture/geometry.
- Both slash and natural-language forget actions clearing retained result snapshots.

Restricted shells return Carbon `eventInternalErr` when registering a global shortcut. The desktop-enabled integration passed outside that restriction; this is why that test is opt-in. [Separate native hotkey result](native-hotkey-desktop.log).

## Build and final launch

The release app rebuilt successfully and passed strict signature verification and Info.plist lint. See [build output](build.log) and [signature checks](signature-check.log). The final build was reopened with Flame mode at 96 points; [final live capture](final-flame-live.png) and [launch accessibility state](final-launch-live.txt) confirm the status and activity controls. The temporary QA browser tab was closed.

## Native app smoke check

The ad-hoc signed app was opened through Computer Use after restarting the older workspace executable. Verified the flame’s double-click chat action, document/AI controls, companion settings, Mini mode, Hide/Show, native size increments from 96 to 144 points, reset to 96, and preservation of an unsent draft across Hide/Show. The temporary draft was removed and Flame mode restored.

Evidence:

- [Running settings panel](settings-live.png)
- [Running Mini companion](mini-live.png)
- [Activity tray](activity-live.png)
- [Preserved draft accessibility state](draft-preserved-live.txt)
- [144-point size accessibility state](resize-live.txt)

The final native previews show the latest layout, including the widened Mini capsule and corrected snapshot footer:

- [Flame preview](flame-native-preview.png)
- [Alert preview](alert-native-preview.png)
- [Mini preview](mini-native-preview.png)
- [Settings preview](settings-native-preview.png)

## Limits of verification

Computer Use’s synthetic key presses did not demonstrate OS-level global hotkey delivery; native registration, conflict handling, dispatch, and editor focus are verified separately by tests. Its native drag API returned `AXError.notImplemented`, so physical dragging remains a desktop acceptance item despite passing controller/capture/geometry regressions. Physical multi-display/full-screen behavior, an actual keyboard hotkey press from another app, and toggling the operating system’s Reduce Motion setting also remain manual checks. The sprite still-frame/celebration path was tested with an injected Reduce Motion policy.

The two live Ollama tests were not enabled in this run. Existing mocked cloud/local transports passed. This work does not change model behavior, document retrieval, or planner storage.
