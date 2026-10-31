# Phase 4 compact session handoff

Each completed task has a durable checkpoint below. No callable session compaction
API is available; read this file to resume without replaying the session.

## Task 4.1 — local native networking

Added `OllamaClient` using ephemeral native URLSession and byte-wise bounded NDJSON
framing at `http://localhost:11434/api/generate`. POST bodies set `stream: true`,
`format: "json"`, deterministic temperature and a 2,048-token output ceiling.
No cache, cookies, credentials or proxies; redirects are refused. Endpoint is fixed
to the specified localhost port/path. HTTP/model/connection errors are localized;
cancellation is preserved. Request/resource timeouts are 120/180 seconds, stream
wire limit 2 MiB, individual wire record limit 128 KiB. Callbacks are awaited for
backpressure; underlying URLSession task is cancelled on exit.

Checkpoint: **3 tests passed** (`artifacts/phase-4-task-4.1.log`). Subsequent tasks
add retrieval, prompt policy, structured decoding, transport/lifecycle tests and
application wiring. No live Ollama/model check has been claimed.

## Task 4.2 — keyword retrieval

Added deterministic `KeywordNoteSearch`: case/width/diacritic normalization,
Unicode alphanumeric terms, exact token score 3 and substring score 1. Repeated
query words count once. Ties preserve chunk order. Queries are bounded to 2,000
characters and 32 distinct terms (minimum two characters); punctuation-only,
single-character and unmatched queries return no matches. Defaults select at most
six whole chunks within 6,000 text characters, retaining UUID/file/index metadata.
Cancellation is checked per chunk. Search is intended to run off the main actor.

Checkpoint: **4 tests passed** (`artifacts/phase-4-task-4.2.log`), including Arabic,
CJK, accent handling, ranking, repetition and whole-chunk budgets. Explicit mark
removal fixes Arabic shadda normalization beyond Foundation's diacritic folding.

## Task 4.3 — offline prompt policy

Added `OfflinePromptBuilder`, keeping immutable system rules separate from a
JSON-encoded question/reference-note data object. Rules require grounded,
localized extraction and a raw `{"lines":[...]}` envelope; each line contains
canonical `speechBubbleText`, `currentEmotion` and `sourceIDs` keys. Prose follows
the question language, while keys/emotion enum values remain stable. Each line
is at most 500 characters and the envelope permits 1–8 lines. Source IDs must
refer to supplied chunks. No-match/invalid queries fail before networking.
Builder independently enforces six whole chunks/6,000 text characters.

Checkpoint: **3 tests passed** (`artifacts/phase-4-task-4.3.log`), covering JSON
escaping, instruction-like document content outside the system field, source
identity, limits, and empty inputs. Prompt policy cannot guarantee factuality or
prompt-injection resistance; Task 4.4 enforces structure and source membership.

## Task 4.4 — structured streaming and native input

Added `OllamaStreamDecoder`: native JSONDecoder unwraps each NDJSON record, then a
bounded incremental JSON state machine identifies complete objects in `lines`.
Quoted braces, escaped quotes/backslashes and fragments within Unicode strings
are handled. Each completed line is decoded to `PetSpeechLine` before publication.
Unknown/missing payload keys, unknown emotions/source IDs, control/newline text,
empty/oversized lines, extra prose, trailing commas, >8 lines and incomplete
streams fail. A valid envelope plus `done: true` is required; `done_reason: length`
is rejected. Generated content is limited to 64 KiB. Early lines are provisional
until completion; terminal errors replace partial speech and clear citations.

`LocalNotesAssistant` searches/builds the prompt on a cancellable detached worker,
streams over native URLSession and publishes speech/emotion on the main actor.
Speech accumulates line-by-line; citations come only from decoded source IDs.
Cancel, window close, memory changes, supersession and parent cancellation stop
work. A generation ticket prevents stale speech. Every failure leaves thinking;
a successful final thinking emotion becomes idle. Clearing/changing document
memory also invalidates old answers/citations. A native key-capable Ask Notes
window accepts question/model input; the pet panel retains its native behavior.
Open it from Kaddo → Ask Notes…. The full answer is scrollable in this window;
the pet bubble still has its existing three-line layout.

Local-only hardening: `/api/show` receives only the model name before inference.
Remote host/model metadata or missing local architecture is rejected before any
notes reach `/api/generate`. This also covers remote aliases without cloud in the
name. Metadata reads are bounded to 1 MiB. No models are installed/downloaded.
The app relies on an honest local Ollama service; server-level `OLLAMA_NO_CLOUD=1`
can additionally disable cloud features for the Ollama process.

Checkpoint: **16 transport/decoder/controller/native-window tests passed** in
`artifacts/phase-4-task-4.4.log`. This includes seven-byte transport fragmentation,
character-fragmented inner JSON, Unicode/escaping, visible speech before done,
no-match without a request, HTTP/timeout errors, cloud alias rejection without
notes, oversized records, cancellation, memory clearing and stale-result guards.
The query window renders shared speech changes in its existing hosted view.

Live environment check: Ollama CLI exists, but localhost:11434 refused connection.
The only installed manifest found was `kimi-k2.7-code:cloud`; no local-weight model
was available. No service was started and no model download was attempted. Real
model quality/offline inference and desktop N10 remain unverified.

## Final validation and resume

- `./scripts/test.sh --filter KaddoCanvasTests`: **76 passed**, no failures.
  Evidence: `artifacts/phase-4-canvas.log` (23 tests added by Phase 4).
- `./scripts/test.sh --filter HarnessTests`: **7 passed**, no failures.
  Evidence: `artifacts/phase-4-harness.log`.
- `./scripts/build-app.sh`: release app rebuilt and ad-hoc signed.
  Evidence: `artifacts/phase-4-build-app.log`.
- `codesign --verify --deep --strict .build/Kaddo.app`: exit 0.
  `plutil -lint` passed and the built Info.plist contains
  `NSAppTransportSecurity.NSAllowsLocalNetworking = true` for local HTTP.
- Environment evidence: `artifacts/phase-4-local-environment.json`.

Resume by reading this file, README.md and docs/native-acceptance.md. Quit any
older Kaddo instance, then launch `.build/Kaddo.app`. This session rebuilt the
bundle but did not relaunch the user's pet. With an already installed local model
and Ollama serving, drop PDF/DOCX notes, open Kaddo → Ask Notes…, select the local
model tag, and ask using keywords present in the notes. Run N10 with external
networking disabled, test unsupported questions, stop the service and cancel a
slow answer. Actual offline model output and desktop typing/menu interaction
remain manual acceptance. No local model was downloaded and no cloud model was
used. The older test-owned factories remain unchanged; their chat/nonstreaming,
PDF-page/overlap, focus and animation contracts are still separate work.

All repository files were untracked at session start. Existing files were
preserved, no commit was made, and no sub-agents were spawned. All four tasks now
have compact checkpoints above; automatic context compaction is not callable.

Protocol references used during implementation:

- [Ollama generate API](https://docs.ollama.com/api/generate)
- [Ollama model metadata types](https://github.com/ollama/ollama/blob/main/api/types.go)
- [Ollama cloud configuration](https://github.com/ollama/ollama/blob/main/docs/cloud.mdx)
- [Apple URLSession async bytes](https://developer.apple.com/documentation/foundation/urlsession/asyncbytes)
- [Apple local HTTP configuration](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
