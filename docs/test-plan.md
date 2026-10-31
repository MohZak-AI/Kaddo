# Kaddo test plan

**Status — 26 October 2026:** Phases 1–3 implement the native canvas, workspace context watcher, and local document ingestion, with 53 passing native XCTests. Seven infrastructure checks pass. The 25 extraction/chunking/storage tests pass under Address Sanitizer. The older MVP feature factories still fail with `PendingImplementation`; their full acceptance assertions have not run against the new implementation. See `phase-2-handoff.md` and `phase-3-handoff.md` for implementation coverage and remaining adapter boundaries.

## Test boundaries

All contracts live under `Tests/KaddoAcceptanceTests/Support`. The five methods in `MVPFactory` are the only bindings to replace as the engines are implemented. The contracts define observable behavior and dependency injection for clocks, timer subscriptions, app notifications, HTTP transport, storage, and resource limits.

Use the real engine behind each binding. A fake engine that simply reproduces expected values would not satisfy these acceptance tests' purpose. Production types may expose a different API through a thin test adapter.

| File | Behavior specified | Verification still needed |
| --- | --- | --- |
| `OverlayTests.swift` | Nonactivating panel, transparency, scaled alpha coordinates, frame targeting, movement and drop callbacks | Real mouse dispatch, activation, continuous dragging, Spaces and displays |
| `AttentionTests.swift` | Bundle-ID mapping, native notification payload, inactivity boundary, stopped observers | Live app switching, native idle provider and periodic sampling |
| `DocumentTests.swift` | Real parser fixtures, bounded overlapping chunks, relevance, provenance and memory lifetime | Native drops, asynchronous responsiveness and realistic large documents |
| `OllamaTests.swift` | Request/response protocol, local endpoint restriction, excerpt budgets, errors and cancellation | Installed local model, response quality, offline operation and UI cancellation |
| `FocusTests.swift` | Injected timer callbacks, elapsed focused time, rewards and restored progress | Real background dispatch timer, power notifications and app wiring |
| `HarnessTests.swift` | Fixture validity, isolated stub HTTP sessions, error simulation, test clock, defaults and ticker | Infrastructure only; these checks do not exercise an engine |

## Scope 1: native overlay

The alpha mask uses top-left, row-major pixel coordinates. AppKit view coordinates use a bottom-left origin. A 2×2 fixture at 10× scale checks both transformations, transparency, partial alpha, and exact outside bounds. Every nonzero alpha value is interactive.

The panel must be borderless, nonactivating, transparent and shadowless. It must remain visible when another app activates, float above ordinary windows, join Spaces, and permit full-screen auxiliary behavior. Movement and frame constraints must permit negative display coordinates.

The tests specify switching `ignoresMouseEvents` for the whole window. Returning `nil` from a view's hit test alone does not establish desktop click-through. The MVP must continuously update pointer targeting even while the panel ignores mouse events. Apple's API exposes the whole-window setting. [1](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents)

During a file drag, the entire panel bounds becomes a drop zone, including transparent pixels. Ending the drag restores normal alpha targeting. This reconciles frame-wide drops with normal click-through behavior. The test invokes the drop-routing seam; actual `NSDraggingDestination` delivery remains a native acceptance check.

## Scope 2: attention

Defaults classify Xcode, VS Code and IntelliJ as focused, and Slack and Discord as distracted. Other apps and missing bundle identifiers are idle. These defaults are provisional and configurable. A user with at least 600 seconds of inactivity is sleeping, regardless of the foreground app. Renewed input restores the app's mode.

The engine starts with the current foreground app and then consumes `NSWorkspace.didActivateApplicationNotification`. It must tolerate malformed notifications and repeated start/stop calls. The test posts Apple's notification name and `NSRunningApplication` payload to an isolated notification center. This tests the subscription contract without switching the user's actual foreground app. [2](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)

This scope observes application activation. It does not require browser URLs, document contents, keystroke capture, or changes between windows inside the same application.

## Scope 3: documents and local synthesis

Phase 3 follows the latest user requirement: non-overlapping windows of four
sentences, capped at 1,600 Characters. Its production tests live in
`Tests/KaddoCanvasTests/Document*Tests.swift`. They verify real extraction,
whitespace/control normalization, exact normalized-text reconstruction, Unicode
graphemes, resource limits, malformed ZIP/XML, cancellation, atomic RAM storage,
and owner release after 30 import/clear cycles. Address Sanitizer found no errors
in those 25 extraction/chunking/storage tests; this is not an exhaustive leak audit
of PDFKit, Foundation, or native desktop sessions. The older overlapping contract
below is preserved for explicit resolution when building its adapter. Retrieval
and PDF page provenance remain outside Phase 3.

`scripts/generate-test-fixtures.py` generates deterministic inputs with Python's standard library. Fixtures include a real DOCX ZIP/XML package, a searchable two-page PDF, a PDF without a text layer, Unicode text, long text, corrupt inputs, a missing DOCX main part, and a DOCX external-entity declaration. The textless PDF is a blank page, used to model the absence of a searchable text layer; it is not an OCR fixture.

The DOCX acceptance text preserves paragraph breaks, tabs, line breaks, entities and table text. PDF chunks retain 1-based page references. OCR and encrypted-document support are not required by the current tests; unsupported input must produce a useful error in the app.

Chunk limits count Swift `Character` values. The overlap is exact, chunks have unique IDs, and reconstructing the long fixture must preserve its text and Unicode. Input-file and extracted-text limits bound ingestion. The implementation should enforce decompression limits during reading, rather than allocating unlimited decompressed data first.

Retrieval uses case-insensitive lexical matching, ranks relevant excerpts, respects result and character limits, and returns no matches for unrelated or empty queries. Keyword matching is the MVP baseline. True semantic similarity would require an additional local embedding engine and its own tests.

Document context stays in RAM. Another engine instance must not restore it. Failed imports preserve existing context, and explicit removal/clear releases the indexed records.

Ollama requests use `/api/chat`, the configured local model, separate system/user messages, and `stream: false`. The test transport intercepts every request before networking. It checks attribution and source excerpts, including an instruction-like document string that must remain outside the system message. This establishes prompt structure; it does not prove an LLM will resist every document instruction. The protocol follows Ollama's chat API. [3](https://docs.ollama.com/api/chat)

The excerpt budget applies to document text, not the full prompt or token count. Only complete excerpts that fit are sent, and only those excerpts become answer sources. Returned source references show supplied context; they are not proof that every generated claim is supported.

Remote endpoint configuration is rejected. A loopback URL alone cannot prove the Ollama daemon uses local inference. Native acceptance must use an installed local 7B/8B model with external networking disabled. No cloud credentials or paid service are needed for these tests.

## Scope 4: focus and persistence

The user approved focused-time accounting. State changes first account for elapsed time under the previous state. Distracted, idle and sleeping states pause the interval. Wake excludes time spent asleep and requires a fresh attention state before progress resumes. A partially completed session does not resume or earn rewards while the app is closed.

The fake clock and ticker avoid actual waits. Every focus test receives a manual ticker by default; the application will construct the real dispatch timer separately. Delayed ticks must account for elapsed time rather than decrement once per callback. Completion grants one reward, even after an overdue tick or repeated refresh. Cancel grants nothing. A live session cannot be silently replaced. The timer subscription must be removed on cancellation/completion, then recreated once for a new session.

For test purposes, a completed session earns 25 XP and 5 coins; a blue scarf costs 10 coins. `FocusPolicy` makes these values configurable. Insufficient funds, unknown items and selecting an unowned item must preserve balances. Repeat purchases are idempotent. Rewards, ownership and selection persist promptly in isolated `UserDefaults`, and reconstruction restores them without restoring an active session.

The actual MVP should use a background dispatch timer while the system is awake and native power notifications. macOS suspends dispatch timer sources during system sleep, so a thread cannot keep executing then. Sleeping intervals must be excluded when reconciling on wake. Display sleep and system sleep need distinct native checks. [4](https://developer.apple.com/library/archive/documentation/General/Conceptual/ConcurrencyProgrammingGuide/GCDWorkQueues/GCDWorkQueues.html)

## Completion criteria

1. Bind each factory to its real engine and turn its acceptance suite green.
2. Keep all infrastructure checks green; do not skip or invert pending tests to get a passing build.
3. Run the full suite and retain the result log.
4. Package the actual app and execute every applicable [native acceptance scenario](native-acceptance.md), recording results and evidence.
5. Report any pending desktop or model check explicitly. Automated contracts alone cannot establish native runtime behavior.

## Natural assistant regression

Run `./scripts/test.sh --filter KaddoCanvasTests` for the active native implementation.
`AssistantCoordinatorTests`, `CompanionTests`, `OpenAIAssistantTests`, and native composer
checks cover direct actions, chat distinctions, English/Arabic follow-ups, stable IDs,
clarification, duplicates/retry, cancellation, persistence failures, Keychain injection,
Responses API requests, selected-session cloud excerpts, citation rejection, and memory limits.
These use isolated planner state and mock HTTP; they do not spend API credits.

For live acceptance, configure a personal key in + → AI settings, test the connection,
ask a general question in English and Arabic, start and pause a timer naturally, clarify
an ambiguous task name, and ask about an imported document. Verify the cloud indicator
and sources. Select local Ollama explicitly and repeat with an installed local model.
A missing credential or model should explain setup while slash commands and common
unambiguous actions continue to work. Stop a request before tool execution; retry a
failed response after a saved task and verify only one task exists.
