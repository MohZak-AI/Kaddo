# Kaddo native acceptance checklist

**The complete scenarios below remain pending; partial checks are recorded below.** Phase 1 now has a runnable canvas app
(`./scripts/build-app.sh`, then `open .build/Kaddo.app`) and 8 passing native XCTests.
A desktop smoke check launched the packaged app and verified its speech text and
idle sprite via native accessibility inspection and a saved screenshot at
`artifacts/phase-1-canvas.png`. This does not establish cross-app click delivery,
physical dragging, Spaces behavior, or the later MVP engines. The older acceptance
contracts remain behind unimplemented factories.

Phase 2 now adds the workspace activation observer, normalized layout categories,
and ten-minute activity sleep/wake logic. Its 17 additional native XCTests cover
mock notification dispatch, real activity-provider reads, lifecycle, and a real
100 ms polling timer with 300 ms transition assertions. N06 still needs live app
switching and a ten-minute desktop check; focus rewards belong to a later phase.

Phase 3 adds 28 native unit tests for URL/provider filtering, temporary transparent
drop targeting, bounded Word/PDF extraction, non-overlapping sentence windows,
and transactional RAM storage. The 25 extraction/chunking/storage tests pass
Address Sanitizer, and the app bundle builds. Actual Finder drag delivery,
Escape cancellation, mixed drops, and realistic import responsiveness remain
NOT RUN (N05/N09). One import at a time is supported; additional concurrent drops
show a retry message. PDF page provenance and retrieval belong to later work.

Phase 4 adds 23 tests for keyword retrieval, offline prompts, native URLSession
transport, incremental structured decoding, answer lifecycle and a native key-capable
query window. Use Kaddo → Ask Notes… for N10. The client uses streaming
`/api/generate`, with model-only `/api/show` checks rejecting remote models before
sending notes. Tests establish decoded speech publication before an open stream
finishes and cleanup on cancellation/memory changes. They do not establish live
model quality. Earlier sandbox-restricted checks could not reach Ollama.
Filenames/block indices are available; PDF page references remain
outside the implemented chunk model.

Task 3.3 adds five inference regressions and updates live-stream coverage for
`pet_emotion`: thinking while waiting, celebrating as a validated answer arrives,
and idle on insufficient evidence, cancellation or failure. Optional JSON fences
are stripped across fragments; full response strings also decode. All 92 native
tests and seven infrastructure tests passed at initial implementation.

The usability follow-up verifies actual native generation with the installed
`qwen3.5:4b`: launch opens Ask Notes, `/api/tags` selects that local model and omits
the cloud alias, Add Document imports `Research.pdf`, and submitting the orchid
question displays “You should water orchids every seven days.” plus block 1.
The pet shows the same speech and the happy frame. Double-clicking it reopens
Ask Notes. Screenshots: `artifacts/task-3.3-live-answer.png` and
`artifacts/task-3.3-live-pet.png`. N10 is partial: external networking was not
disabled and live cancellation/service-stop cases remain to be checked. The
updated suite passes 95 offline native tests plus seven infrastructure tests;
one live-model test is opt-in.

The floating composer follow-up replaces the titled question window with an
anchored borderless input panel and the cat with an original animated flame
mascot. 99 offline native tests and seven infrastructure tests pass; the separate
live qwen3.5:4b PDF test also passes. CUA verifies import, Return submission,
the happy pet's answer, expandable citation and Escape/double-click reopening.
See [the composer handoff](floating-composer.md) for logs and previews. Full
physical desktop scenarios below remain pending where marked.

Use a regular macOS desktop with Finder, an editor, a chat app, and a browser. For multi-display checks, include a display positioned to the left of the main display so its coordinates are negative. Use the supplied parser fixtures and generated flame mascot. Record macOS version, app build, model tag and hardware with results.

| ID | Scenario and steps | Required result | Status |
| --- | --- | --- | --- |
| N01 | Launch the packaged app while typing in an editor. Switch to another app and back. Inspect Dock, app switcher and menu bar behavior. | Pet appears without taking keyboard focus or becoming an ordinary Dock app. Deactivation does not hide it. A recover/quit control remains available. | NOT RUN |
| N02 | Place the pet over browser tabs and editor text. Click visible pixels, then transparent pixels and corners, including immediately after pointer movement and during an animation-frame change. | Visible pixels handle pet interactions; transparent pixels deliver the original click to the underlying app with correct keyboard focus. No click replay or double dispatch. | NOT RUN |
| N03 | Drag from body, ears and other visible pixels. Cross menu-bar and display edges, including negative coordinates. Release when animation changes under the cursor. | A continuous drag follows the pointer without breaking, activating other apps or snapping to the main display. The pet can be recovered after moving partly offscreen. | NOT RUN |
| N04 | Change Spaces, enter a full-screen editor, disconnect a display, then reconnect it. | Pet follows the intended Spaces/full-screen behavior and remains recoverable. Document any macOS restrictions on system or secure surfaces. | NOT RUN |
| N05 | Drag DOCX/PDF files from Finder over both opaque and transparent parts of the panel. Try a mixed drop including TXT. Cancel a drag with Escape. | Supported files reach parsing, unsupported types are ignored, and the entire bounds works as a drop zone. Normal click-through returns immediately after drop/cancellation. | NOT RUN |
| N06 | Switch Xcode → Slack → an unmapped app. Keep a focused app frontmost for ten minutes without input, then resume input. | Modes follow focused → distracted → idle. At 600 seconds without input, mode becomes sleeping; input restores the current app mode. Rewards follow those states. | NOT RUN |
| N07 | Minimize all normal app windows and use a short diagnostic focus interval while a mapped editor remains active. Turn only the display off while the Mac stays awake; inspect callback diagnostics on return. | The background timer remains subscribed independently of UI windows. Callback timestamps establish execution while awake; progress follows the attention mode and is not based on callback count. | NOT RUN |
| N08 | Start an interval, record focused seconds, put the Mac into full system sleep, then wake. Repeat near interval completion. | No progress or rewards accrue during sleep. Wake reconciles once and resumes only after a fresh attention sample. No duplicate reward. | NOT RUN |
| N09 | Drop `FocusNotes.docx`, `Research.pdf`, then each malformed/textless fixture. Drag the pet while importing a realistically large supported document. | Expected text and PDF page references appear; errors preserve existing context. UI remains responsive, memory is bounded, and no document-context file is persisted. | NOT RUN |
| N10 | With Ollama and a local model installed, disable external networking. Ask about orchid watering, then an unrelated question. Stop Ollama and try again; also cancel a slow answer. | Local answer includes the relevant source references. No-match, unavailable-service and cancellation states are understandable. Thinking state clears on every terminal path. No external inference is required. | PARTIAL — real qwen3.5:4b PDF answer, citation and pet update verified; network isolation and live error/cancel cases pending |
| N11 | Finish sessions, purchase/select a customization, quit, then relaunch. Also quit partway through a session and relaunch after a delay. | XP, coins, ownership and selection survive; an unfinished session earns no offline rewards. Document context is gone. | NOT RUN |
| N12 | Observe the selected sprite while focusing, waiting for synthesis, completing a session, and idle for ten minutes. Inspect at Retina and non-Retina scales. | Animation rows match the asset map; nearest-neighbor rendering stays crisp; alpha targeting follows the current frame. Thinking and celebration states return to the correct attention state. Attribution is available in the app. | NOT RUN |

For each executed scenario, replace the status with PASS/FAIL and attach the observed result plus a recording, screenshot, diagnostic log, or saved-state comparison appropriate to that scenario. A screenshot alone cannot establish click delivery, timer continuity, or successful offline inference.
