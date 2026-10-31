> Current routing: ordinary text is casual conversation. Tools require slash commands;

The [companion experience](companion-experience.md) extends this implementation with activity, Mini mode, saved placement, and updated celebration playback. The details below record the earlier composer handoff.
> planning answers use `/reply <answer>` and document retrieval uses `/ask <question>`.
> `/forget` clears bounded, session-only conversation memory. The composer’s Stop/Escape
> cancels both assistants, and timer/command messages invalidate pending generation.
> See [the companion implementation](companion-chat.md) for current behavior and validation.

# Floating pet question composer

Implemented the approved desktop composer plan. Two native panels form one
visual assembly: the existing nonactivating pet and a separate key-capable,
borderless question panel beneath it. No inference or document history is saved.

## Interface

The capsule uses the requested 360 × 44-point size, #242424 surface, #414141
border, #3976CB send button and native 14-point typography. Input grows to three
lines, then scrolls. Return sends; Shift–Return adds a line. Command–A/C/X/V/Z
and Shift–Command–Z route directly to native text editing because this accessory
app has no standard Edit menu. The send arrow is disabled for blank input and becomes Stop during inference when the
editor is empty. Entering new text allows a new send, which cancels the previous response.
Greetings and student tools stay available without a model. Escape hides the composer,
closes its controls and cancels an active answer; the draft remains available.

The + popover contains document import, existing RAM-backed session boxes, new
session creation, installed local model selection and refresh. Cloud aliases stay
excluded, and the existing /api/show preflight still runs before sending notes.
Errors show a relevant import, model-refresh or answer-retry action. Session
selection and document changes retain inference cancellation and source invalidation.

Answers appear above the pet in a dark bubble with a 180-point height cap and
scrolling. Sources expand inline. The visible emotion label is removed; the pet
retains its spoken accessibility description. The composer stays visible when
another app receives focus. Launch, reopen, double-click and the pet/menu-bar
Chat & Commands actions reveal the composer and focus its native editor.

## Architecture and assets

- `PetChatPresentationState` shares composer visibility, draft, selected model,
  sources, size and retry actions across the panels. `LocalNotesAssistant` exposes
  `lastFailure` for contextual retry controls; its request/decoder protocol is unchanged.
- `NotesQueryWindowController.attach(to:)` connects the composer to the pet as an
  AppKit child window. Dragging and screen-change notifications maintain alignment.
  `WindowDragController.constrainOrigin` clamps the combined bounds, including
  displays with negative origins. The pet remains non-key with rendered-alpha
  click-through; dragging is restricted to the sprite so answer controls can scroll.
- `PetSpriteView` renders five transparent six-frame strips generated with the
  built-in ImageGen tool. Assets are bundled in
  `Sources/KaddoCanvas/Resources/FlamePet/`; exact prompts/provenance are in
  `assets/flame-pet/prompts.md`. Legacy cat assets and attribution remain bundled.
- Idle loops at 6 fps, thinking/happy at 8, sleeping at 4. Celebration plays at
  10 fps once and holds its last frame. Animation never changes logical emotion.
  Reduce Motion selects a representative still. One shared crop keeps pose/jump
  offsets; the loader clears only <=16/255 alpha noise from generated transparent
  margins so sizing and hit testing follow visible pixels. Original PNGs are retained.

## Verification

- `KADDO_COMPOSER_ARTIFACTS="$PWD/artifacts" ./scripts/test.sh --filter 'KaddoCanvasTests|HarnessTests'`:
  99 offline native tests passed, one opt-in live test skipped, seven infrastructure
  tests passed. Log: `artifacts/floating-composer-final-tests.log`.
- `KADDO_LIVE_MODEL=qwen3.5:4b ./scripts/test.sh --filter LiveOllamaTests`:
  passed in 23.4 seconds with real PDF extraction, local inference, source citation
  and happy emotion. Log: `artifacts/floating-composer-live-tests.log`.
- Release rebuild/ad-hoc signing: `artifacts/floating-composer-final-build.log`.
  Strict signature verification and Info.plist lint pass.
- Native tests cover panel focus/reopen/alignment, negative-screen constraints,
  Return/Shift–Return/Command–A, input height bounds, Escape cancellation of a held
  stream, source binding/session invalidation, service retry and distinct transparent
  animation frames/cadence. Existing alpha-hit and goal-celebration regressions pass.
- CUA testing of the running app opened the + controls, imported Research.pdf,
  verified the session had one file, submitted with Return and received “Orchids
  should be watered every seven days.” The pet changed to happy and expanding
  Sources displayed Research.pdf · block 1. Escape and double-click reopening
  were exercised. Actual pet capture: `artifacts/composer-live-answer-pet.png`;
  control accessibility evidence: `artifacts/composer-plus-controls.txt`.
  The final signed build also passed actual Command–A draft replacement and
  live Stop cancellation: the control changed back to Send and the pet displayed
  “Answer cancelled.” in idle. Evidence: `artifacts/composer-stop-actual.txt`.

Native view previews on a dark backdrop are exported separately from CUA captures:

- `artifacts/composer-idle-native-preview.png`
- `artifacts/composer-controls-native.png`
- `artifacts/composer-thinking-native-preview.png`
- `artifacts/composer-answer-native-preview.png`

The preview question/model responses use isolated test transport; the live model
test and CUA result above provide separate real-inference evidence. External
networking was not disabled during live testing. Physical multi-display movement,
full-screen Spaces and cross-app rapid click timing remain desktop acceptance
items; simulated screen geometry and rendered-alpha tests cover their code paths.
