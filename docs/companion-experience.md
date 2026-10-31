# Kaddo companion experience

Kaddo adopts the floating quick-chat and activity patterns described in [OpenAI’s Pets guide](https://learn.chatgpt.com/docs/pets), keeping its original flame and student tools. The implementation is native SwiftUI/AppKit and supports macOS 13 or later.

## Everyday controls

- **Option–Shift–Space** shows the companion and focuses chat. Repeating it focuses the same draft. Change or disable the combination in **Companion settings**. Registration conflicts leave the previous working binding in place.
- Hover reveals chat after 120 ms without taking focus. Departure collapses it after 650 ms; drafts and running answers survive. Double-click the flame, click Mini’s chat button, or use the menu bar to type.
- **Hide companion** hides the whole overlay and its controls without stopping work. **Show companion** restores it. Escape retains its earlier meaning: cancel the current answer and collapse chat. The Send/Stop control also stops inference.
- Open **Companion settings** from the pet context menu, Kaddo menu bar, or **+** controls. Choose Flame or Mini, resize the flame from 64–144 points, configure previews and the shortcut, or recover an offscreen companion. The default flame size is 96 points.
- Mini replaces the character with a draggable capsule containing Chat and Activity. Drag its handle to move it. Both appearances use the same conversation, provider, and document sessions.

Appearance, visibility, shortcut, size, and display-relative placement save in `UserDefaults` under `pet.*` keys. Planner storage is unchanged. Position recovery clamps the companion, speech area, and composer to available display bounds; disconnected displays fall back to the first available display.

## Activity and previews

Activity is independent of the pet’s emotion. The badge prioritizes **Needs input → Blocked → Ready → Running**, otherwise **Idle**. Pending questions remain Needs input after being read, until answered or dismissed. An active study timer has its own countdown indicator.

The Activity button opens the latest 20 updates in RAM. Select an item to acknowledge it and inspect a captured result. This neither switches the document session nor repeats an action. Document results retain their original citation metadata. **Current answer** returns to the live response.

Completed answers, reminders, and timer alerts preview for six seconds without activating Kaddo. Hover pauses the countdown. Typing, dragging, settings, and activity inspection defer previews. Clicking a preview opens chat and retains the captured message for inspection. Explicit Hide drops pending previews and suppresses new ones until Show; unread updates remain in the tray. Disabling previews has the same effect on previews alone. Existing sounds and notification preferences remain in force.

Alerts have their own presentation snapshot and no longer cancel or overwrite inference. Operation IDs reject results from cancelled or superseded requests. `/forget`, natural-language forget actions, and profile clearing remove retained activity alongside conversation memory. Nothing in the activity tray is written to disk.

## Motion and implementation

The flame enlarges by 3% on hover, bobs briefly on click, and tilts up to four degrees while dragged. It stays where placed. Celebration plays once and returns to the underlying inference, break, inactivity, or ordinary pose. Celebration timestamps prevent visibility or appearance changes from replaying an old celebration.

Reduce Motion uses representative still frames and removes movement and transitions. Hidden companions stop sprite playback and native pointer tracking. Character frames, timing, looping, representative stills, and transform anchor are described by `PetAnimationDefinition`, so a future bundled character can replace the flame without changing the assistant. Custom import, voice, screenshots, and autonomous roaming are not included.

`PetActivityStore` owns bounded result snapshots, operation lifetimes, acknowledgement, priority, and preview timing. `PetChatPresentationState` continues to own transient UI state. Planner events use a Combine publisher alongside the existing sound/notification callback; coordinator outcomes and clarifications are typed. Geometry is shared by the canvas, composer, hover regions, and rendered-alpha click targeting.

## Validation

Run the native suite with:

```sh
./scripts/test.sh --filter 'KaddoCanvasTests|HarnessTests'
```

The Carbon integration test requires desktop access and is opt-in because restricted shells return `eventInternalErr` during registration:

```sh
KADDO_DESKTOP_TESTS=1 ./scripts/test.sh --filter testNativeHotKeyRegistersDispatchesAndReleases
```

It registers a temporary Control–Option–Command–F1 binding, verifies native event dispatch, tests a real conflicting registration, and checks release/re-registration. Existing live Ollama tests remain separately opt-in. The older incomplete acceptance factories remain separate specifications.

See `artifacts/companion/validation.md` for the executed checks, screenshots, and desktop limitations.
