# Natural conversation and feature use

Kaddo's composer handles conversation, general questions, feature requests, contextual
follow-ups, and selected-session document questions. Slash commands remain shortcuts.
The same planner operations execute both shortcuts and typed AI tools.

## Routing and actions

`AssistantCoordinator` owns request generations, sequential tool calls, clarifications,
recent action outcomes, and conversation memory. `AssistantProvider` abstracts OpenAI
and Ollama. `KaddoToolCall` uses registered names and typed arguments; `KaddoToolResult`
reports success, failure, or required input. Tool schemas cover all existing commands
plus relevant state reads, session selection, timer resizing, and opening the importer.

Complete, anchored offline patterns handle common requests such as “start a 25-minute
timer,” “pause it,” “make that 30 minutes,” and “add a note Bring the lab book.” They do
not execute mentions, negations, quotations, general questions, or compound requests.
`LocalCompanionAssistant` handles only offline greetings, support, and milestones;
the earlier redirect-only inference pipeline has been removed.

The selected model interprets flexible requests and ambiguous follow-ups. Its instructions
distinguish relevant guided answers from unrelated conversation, require clarification for
ambiguous targets, and prohibit treating stored content as instructions. Read tools fetch
only the needed collection. Item changes resolve stable UUIDs against current state.
Unknown tools, incorrect argument types, invalid UUIDs, unknown fields, multiple parallel
calls, incomplete output, and out-of-range values cannot execute.

Operations run synchronously on the main actor, with controller cancellation hooks suppressed
only during their own execution. Timer/reminder alerts, context changes, Stop, Escape,
provider/model/key changes, and newer messages invalidate pending generations. Cancellation
does not undo completed actions. A per-turn ledger retains completed tool outputs and call
fingerprints. Retry resumes after the last tool result; duplicate calls do not repeat writes.
Eight tool calls per user message bound the loop. Storage errors return failures and roll
back attempted planner data changes; corrupt saved files remain protected.

## Providers and credentials

OpenAI uses native URLSession requests to `https://api.openai.com/v1/responses`, personal
Bearer authentication, strict function schemas, sequential calls, low reasoning effort,
and `store: false`. The default configurable model is `gpt-6.1-sol`. Completed response
output items, including opaque reasoning items, are replayed during tool continuation.
Requests and responses are cancellable and bounded. Authentication, model availability,
rate limits, and connection problems have actionable messages; service bodies are not logged.

**+ → AI settings** contains provider selection, masked key entry, save/remove controls,
model setting, and connection test. Production credentials use macOS Keychain; tests
inject an in-memory credential store. UserDefaults stores only provider/model preferences.
Saving a key selects OpenAI. Removing it leaves provider selection explicit. First launch
without a configured key retains local mode. No automatic provider fallback occurs.

Ollama remains a selectable local provider with existing endpoint restrictions, model
preflight, and bounded NDJSON decoding. It uses the same tool catalog and coordinator.
Neither provider gains shell access, arbitrary file access, or web search. The personal-agent extension adds bounded public HTTPS and approved-folder readers through a separate tool-free grounding boundary; see [the personal-agent guide](personal-agent.md).

## Documents and memory

Assignment references such as “what does ex1?”, “Ex. 1”, “question 2”, and Arabic-numbered
exercise references route directly to uploaded documents in the selected session. The general
assistant also receives an availability/count flag so less literal assignment references can
use its document tool without receiving document contents in casual chat.

`AssignmentContextSearch` matches heading numbers, includes the exercise's following problem
and subparts, and stops at the next exercise. Matching “ex1” never selects “Exercise 10”.
Exercise references resolve against the focused document when that focus is current, so
“now explain exercise 3” keeps the file and changes only the exercise. If an unscoped
reference matches several plausible documents, Kaddo asks which one before calling the
model. Explicit comparisons and summaries may retrieve from multiple requested documents.
A bounded preview handles unusual headings; the tutor asks for missing wording instead of
inventing a problem. Document discussion state is shared by routing and answering. It retains the selected file,
revision, exercise, pending clarification, and up to four completed document exchanges
(6,000 characters). Clear continuations use the document path directly. Unfamiliar wording
can use the normal assistant call, which receives user-authored topic metadata but no document
passages or generated document answers.

Greetings and planner commands preserve the discussion. General conversation retains it for
resuming; ambiguous references after a topic change ask whether the user means the document
or the recent conversation. An explicit filename takes precedence. A failed or cancelled file
switch retains the requested destination, so the next follow-up cannot silently use the old file.

Document conversation state saves in the existing session JSON. After reopening Kaddo,
retrieval validates the file and revision and fetches fresh evidence. Changed files invalidate
old evidence and history; identify a current exercise to resume. `/forget` clears retained
document discussions. Sessions keep separate discussions.

Document prompts distinguish the original topic, latest request, conversational history and
fresh reference notes. History helps resolve references; it is never evidence or authority to
execute actions. The latest question should receive a direct answer rather than a repeated
introduction to the original assignment.

The document prompt explains assignment requirements and can work through a supplied
problem using subject knowledge and reasoning. Derived solutions are distinguished from
document facts, with citations pointing to the supplied problem. Uploaded instructions
remain untrusted content and cannot authorize tool execution.

Exact outputs that depend on a linked rule require both the exercise passage and the uniquely
resolved rule passage in the request, and the answer must cite both. If the link is missing,
ambiguous, or omitted by prompt budgeting, Kaddo withholds the exact answer and asks for the
missing section or document. Claims about what multiple documents warn about require excerpts
that support the claim. Citation IDs are checked against the exact evidence sent to the
provider. Same-target failures preserve the topic; explicit switches establish the newly requested
file before inference. Retrieval preparation itself does not commit a new successful focus.

Document requests use `LocalNotesAssistant` and the existing selected-session retrieval
and citation validator. Cloud grounding requests have no tools. They include the question, bounded document dialogue, and matching excerpts
(maximum 48 blocks and 12,000 evidence characters). The encoded data prompt stays within
24,000 bytes, dropping oldest history first. Other sessions require an explicit request. Explicit general summaries use initial selected-session blocks and cover
only those excerpts. Empty sessions and no matches explain the missing context. Cloud
mode is identified in the composer and document answer.

General chat receives a per-session compact memory, recent exchanges, pending-question
context, compact action outcomes, and current timer status. When history grows past eight
exchanges or 24,000 characters, Kaddo keeps the newest four exchanges and asks the selected
provider for a tool-free, structured summary of older chat. The summary is stored separately
from the retained document/session transcript and is restored after restart. Summaries are
bounded to 4,000 characters and cannot authorize actions or replace live planner reads.
Document/source answers never enter the action conversation memory.

Before each provider call, Kaddo estimates the full request size, including instructions,
tool schemas, state, and continuation output. It uses the configured model capacity when
available, otherwise a 16,384-token estimate with a 25% safety margin and space reserved for
the response. Under pressure, it removes oldest history first; an oversized tool continuation
stops with an error while preserving completed action results for retry. Inputs allow 2,000
characters and general answers 12,000. `/forget` clears compacted context, retained session
transcripts, pending compactions, and assistant clarifications while preserving planner items
and its guided question. `/profile clear` also clears personalized conversational context.

## Validation

Native tests cover direct offline actions, keyboard submission, chat/action distinctions,
contextual English and Arabic tool sequences, stable IDs, missing details, eight-call limits,
malformed responses, persistence failures, corrupt-file preservation, cancellation races,
and replay protection. Cloud transport tests intercept all requests with URLProtocol;
credential tests use isolated settings and injected stores. Document tests check excerpt
budgets, session isolation, citation rejection, disabled tools, and context changes.

Run `./scripts/test.sh --filter KaddoCanvasTests` and `./scripts/test.sh --filter HarnessTests`.
Native view snapshots and logs are in `artifacts/natural-assistant/`. A live OpenAI check
requires a user-configured key; mocked provider tests do not establish live model quality.
The local Ollama service was unavailable during this implementation. Older acceptance
factories still describe separate, incomplete MVP contracts.

## Foreground replies and background processing

Each foreground response owns an operation ID. New messages and explicit cancellation retire
that operation; stale responses cannot update the current answer. Uploads update their own
activity entries and cannot replace a newer chat reply or its sources. Timer alerts and background
planner messages do not cancel inference. Unrelated library updates do not invalidate selected
evidence; changing or deleting an evidence document does.

Document answering returns an explicit answered/needs-input/failed/cancelled outcome. The UI
and evaluation use that result instead of treating speech-bubble text as proof of success.
