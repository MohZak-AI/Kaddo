# Native glass and motion validation — 27 October 2026

## Implemented

- Native SwiftUI regular Liquid Glass on macOS 26+ for the composer, Mini capsule, status badge, and standalone activity button. Mini uses one surface without nested glass.
- Active, behind-window `NSVisualEffectView` materials for replies and the macOS 13–25 control fallback. Replies add a light adaptive backing for text readability.
- Opaque adaptive surfaces under Reduce Transparency; visible boundaries under Increase Contrast. Native glass retains its system accessibility behavior.
- Semantic foreground, secondary, text, caret, placeholder, and shortcut-recorder colors. Settings and activity/document popovers follow the Mac appearance.
- Shared 180 ms reveal and 140 ms hide timing across AppKit and SwiftUI; reply travel is four points. Interrupted hides retain the current panel opacity, cancel retirement, and preserve drafts and focus behavior.
- Subtle 0.97 button press feedback, native Send/Stop symbol replacement on macOS 14+, crossfade on macOS 13, a 220 ms source disclosure spring, and a cancellable 240 ms mascot tap response. Custom motion respects Reduce Motion.
- Composer growth is explicitly outside animated transactions. Reply height measurement is cached and stops remeasuring appended text once its scrolling viewport is full. Replacement and shorter answers still resize correctly.
- No new dependencies, public API changes, assistant behavior changes, or data migrations.

## Automated verification

Final command: `./scripts/test.sh --filter 'KaddoCanvasTests|HarnessTests'`.

**206 native XCTest cases: 203 passed, three skipped, zero failures. All seven infrastructure checks passed.** [Final test log](final-native-tests.log).

The skipped cases are the two opt-in live Ollama cases and desktop-only Carbon registration. The older incomplete acceptance feature factories are outside this native test selection.

Six new regression tests cover:

- Opaque Light/Dark accessibility surfaces, rounded-corner transparency, and contrast borders.
- Active behind-window reply material.
- Three rapid collapse/reentry cycles, stale retirement prevention, click-through on hide, draft preservation, fixed pet position, and no hover focus theft.
- Appearance changes while editing a multiline draft, including caret/text colors, selection, first responder, and stable expanded height.
- Reduced Motion disabling custom transition policies.
- Long streaming replies avoiding repeated measurement, with correct invalidation for replacement, shorter, and empty replies.

Existing rendering, sprite, focus, keyboard, drag-controller, placement, assistant, and document regressions also passed.

The final release app is `.build/Kaddo.app`. [Build log](build.log). Strict signature verification and Info.plist lint passed; the minimum deployment target remains macOS 13.

## Running native UI checks

The [local preview harness](preview.swift) uses production Kaddo views, RAM-only preferences/planner state, a sample textured backdrop, and a URLProtocol that blocks all requests. It never reads saved planner data or sends AI requests. Its appearance commands affect only that preview process.

Computer Use verified native multiline input, preserved draft content across Light/Dark changes, the documents/AI popover, the companion settings window, and selection of Mini mode with the size slider correctly disabled.

- [Light composer capture](composer-light-live.png)
- [Dark composer capture](composer-dark-live.png)
- [Light settings capture](settings-light-live.png)
- [Dark settings capture](settings-dark-live.png)

These are live window captures. Isolated window capture does not reproduce the complete desktop backdrop behind glass; material appearance over arbitrary wallpapers needs in-person desktop review. The captures precede the text-measurement optimization, which changes sizing work without changing the visual style.

## Performance investigation

Recorded the Instruments SwiftUI template against six deterministic reveal / native drag-controller / streaming / hide cycles, before and after the text-measurement optimization. The final scenario completed normally: [scenario log](profile-scenario.log).

| Metric | Initial capture | Optimized capture |
| --- | ---: | ---: |
| Capture duration | 27.47 s | 26.88 s |
| Hangs at the configured 250 ms threshold | 0 | 0 |
| In-range hitch events | 298 | 357 |
| Hitch events longer than 25 ms | 12 | 6 |
| Longest in-range hitch | 50.00 ms | 50.00 ms |
| Inclusive samples in reply height getter, after first 5 s | 3,977 / 66,203 | 1,388 / 32,111 |

CPU sampling identified repeated full NSString text layout as an actionable cost; the caching regression test now prevents that work on appends to a full reply. The runs show reduced sampled sizing work, but they are debug-build, single-run observations under different desktop loads, not a controlled frame-rate benchmark. The total hitch count did not improve, so this does **not** establish hitch-free rendering.

Both recordings warned that no SwiftUI-specific update data was available. The scenario log reports a `swiftuitraced` connection error, so per-view SwiftUI update counts cannot be assessed. Time Profiler, Hitches, and Hangs data were available. Two events with timestamps/durations outside each recorded interval were excluded explicitly.

Evidence: [initial summary](profile-summary.json), [optimized summary](optimized-profile-summary.json), [initial recording log](profile.log), [optimized recording log](profile-optimized.log), [initial trace](swiftui-validation.trace), [optimized trace](swiftui-optimized.trace). The [summary script](summarize-profile.py) documents the filtering and sample counting.

## Remaining verification limits

The host runs macOS 26.6.2. macOS 13–25 fallback code compiles with the existing deployment target and its AppKit material path is exercised by reply tests; those OS versions were not available for runtime testing. Accessibility policy rendering was injected in native tests; global system settings were not changed. Physical dragging across multiple displays, system-wide appearance/accessibility transitions, and full-screen Space behavior remain desktop acceptance checks. No live provider calls were needed for this UI work.
