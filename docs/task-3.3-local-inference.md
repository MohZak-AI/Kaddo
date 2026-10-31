# Task 3.3 — Native local inference request pipeline

The application already connected `ScopedDocumentContextRouter`,
`OfflinePromptBuilder`, `OllamaClient`, `OllamaStreamDecoder` and
`LocalNotesAssistant`. This task completes that path's requested emotion contract
and formatting tolerance while preserving scoped retrieval and cancellation.

## Request and response

`LocalNotesAssistant.answer` snapshots only the active session's chunks on the
main actor, then searches and prepares the prompt asynchronously. The question,
filenames and reference blocks are JSON data outside the fixed system rules.
Those rules require note-supported answers, stable keys, bounded statements and
citations drawn from the supplied source IDs. Retrieval selects at most five
blocks within 6,000 characters. Empty context avoids inference.

The existing native URLSession client posts to
`http://localhost:11434/api/generate` with `stream: true`, `format: "json"`, the
selected model, system rules and prepared prompt. A model-only `/api/show`
preflight rejects remote model metadata before any notes are sent. The session
is ephemeral, rejects redirects and bounds wire/record sizes.

The canonical model output is:

```json
{"lines":[{"speechBubbleText":"Water weekly.","pet_emotion":"celebrating","sourceIDs":["<supplied source UUID>"]}]}
```

`pet_emotion` maps to `PetApplicationState.currentEmotion`, accepting `idle`,
`thinking`, `happy`, `sleeping` or `celebrating`. The prompt asks for celebrating
on supported extraction and idle on insufficient evidence. Legacy
`currentEmotion` answers remain readable; an object containing both keys is
rejected as ambiguous. The existing sprite view observes this state directly;
celebrating uses the happy cat frame, and thinking uses the idle body with its
thinking label. Sprite animation scheduling remains separate work.

The decoder unwraps each NDJSON `response` fragment and incrementally parses the
inner document. It removes one optional surrounding Markdown fence (`json` or
unlabelled), including delimiters split across records. Speech strings retain
their literal contents. Arbitrary surrounding prose, missing fence closures,
unknown fields/emotions/sources, incomplete JSON and length-stopped responses
remain errors. A full response string in one final Ollama record follows the
same decoder path.

Each complete validated statement updates `speechBubbleText`, citations and
emotion on the main actor immediately, before the overall stream ends. This is
statement-level streaming; incomplete JSON strings are buffered. Thinking is set
before retrieval. Errors/cancellation clear citations and restore idle. Session
selection or document changes cancel pending work; generation tickets prevent
stale callbacks from overwriting the next question.

## Verification

- `./scripts/test.sh --filter 'OllamaStreamDecoderTests|OllamaClientTests|LocalNotesAssistantTests|OfflinePromptBuilderTests|ScopedDocumentContextRouterTests'`:
  30 tests passed; `artifacts/task-3.3-focused-tests.log`.
- `./scripts/test.sh --filter 'KaddoCanvasTests|HarnessTests'`: 92 native XCTests
  and seven infrastructure tests passed; `artifacts/task-3.3-native-tests.log`.
- Five new regressions cover fragmented fences with Unicode/escapes, full
  response strings and legacy compatibility, malformed/ambiguous formatting,
  completed celebrating answers with scoped citations, insufficient evidence
  and late generation errors. Updated open-stream coverage observes thinking
  followed by celebrating while the connection remains open.
- `./scripts/build-app.sh`: release app rebuilt and ad-hoc signed;
  `artifacts/task-3.3-build-app.log`. Strict code-signature verification and
  Info.plist lint also passed. The running app was not relaunched.

At initial implementation, live generation was unverified: a sandbox-restricted
localhost `/api/tags` probe could not connect to port 11434. That did not establish
that the service was stopped. Transport tests intercept every request with URLProtocol,
including split UTF-8 delivery and held-open connections. No model was downloaded.
For live acceptance, start Ollama with an installed local model, launch the app,
open Ask Notes, import a document into a session and ask about its contents.
Observe thinking, then decoded speech and celebrating. Also cancel a slow
answer, switch sessions during streaming and stop Ollama before asking again.

Protocol references: [Ollama generate](https://docs.ollama.com/api/generate) and
[Ollama streaming](https://docs.ollama.com/api/streaming).

## Native usability follow-up

Direct inspection found Ollama running with local `qwen3.5:4b` and one cloud alias,
while the query form defaulted to an absent `llama3.1:8b`. The startup pet had no
obvious path into the question form. Fixed both issues:

- Ask Notes opens at launch and when the app is reopened. Double-clicking the
  pet or selecting its right-click Ask Notes action also opens the window.
- `/api/tags` discovery lists installed local names, omits remote aliases,
  selects the first available model and shows connection/empty/error status.
  Refresh Models supports installations and service changes. Generation still
  checks `/api/show` before sending notes.
- Add Document opens a native PDF/DOCX picker targeting the captured session.
- Requests set `think: false` so supported thinking models spend their bounded
  output on the answer. The pet still enters its waiting/thinking state locally.

Actual CUA testing of the rebuilt release app imported `Research.pdf`, selected
`qwen3.5:4b` automatically and submitted “How often should I water orchids?”. The
form displayed “You should water orchids every seven days.” with `Research.pdf ·
block 1`. The pet displayed the same answer with its happy sprite. Closing the
form and double-clicking the pet reopened it with the answer retained. Evidence:
`artifacts/task-3.3-live-answer.png` and `artifacts/task-3.3-live-pet.png`.

`artifacts/task-3.3-fix-final-tests.log` records 95 offline native tests passing,
one opt-in live test skipped, and seven infrastructure tests passing. Three new
discovery tests cover cloud filtering, deduplication, empty/malformed catalogs
and service failure. The release app was rebuilt/ad-hoc signed and passed strict
signature verification and Info.plist lint (`artifacts/task-3.3-fix-build.log`).

Run the native live integration separately with an installed local model:

```sh
KADDO_LIVE_MODEL=qwen3.5:4b ./scripts/test.sh --filter LiveOllamaTests
```

This imports the repository's sample PDF and verifies real speech, source
citations and happy/celebrating state through `LocalNotesAssistant`. The live
test passed with `qwen3.5:4b` in 8.9 seconds; see
`artifacts/task-3.3-live-native-test.log`. Live testing
uses the installed local model; it does not download models. External networking
was not disabled, so full network-isolated acceptance is still pending.
