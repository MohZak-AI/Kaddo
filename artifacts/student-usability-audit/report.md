# Kaddo student usability audit

29 October 2026 · Student-first assessment · Current implementation

## Assessment

**Current usability: 6.4/10. Conditional future usability: 8.6/10.** Kaddo has a useful, responsive offline study toolkit. The weakest parts are getting a new student started, changing existing plans, protecting long drafts, and explaining what is saved. Your preferred DeepSeek provider is unavailable in the app, leaving the central AI study journey unverified and unusable with that credential alone.

The audit covers **32 scenarios: 13 Pass, 14 Partial, 2 Fail, 3 Blocked**. These are scenario-level statuses, not a 41% product pass rate: many Partial scenarios combine passing component tests with an unverified native or live-AI step. Overall confidence is **moderate for offline workflows and low for live AI quality and physical desktop/accessibility behavior**. No passing credit is assigned to the blocked live-AI capabilities.

The current score is an expert readiness judgment under the agreed student-first and DeepSeek constraints, not a statistically measured user-study result. The future score assumes all findings below meet their acceptance criteria and the currently blocked journeys pass real retesting. It is not a validated rating of a future build.

## Customer path tree

Legend: **P** = Pass; **~** = Partial; **F** = Fail; **B** = Blocked. Coverage table below identifies whether evidence is native UI, component probe or automated tests.

```text
Student opens Kaddo
├── Get started [~]
│   ├── Discover pet → open chat [~]
│   ├── Give name → daily planning [P]
│   ├── Skip optional details [P: automated]
│   └── Configure DeepSeek → ask general question [B]
├── Plan the day [~]
│   ├── Add tasks / assignments / exams / classes [P]
│   ├── Guided setup → correct invalid dates and duration [P]
│   ├── Review Today → distinguish upcoming work [F]
│   ├── Edit title / deadline of saved task [F]
│   └── Clarify ambiguous references / retry [~: mocked AI]
├── Study [~]
│   ├── Start → pause → resume → stop timer [P]
│   ├── Receive reminder [P]
│   ├── Complete task → prevent focus on completed task [P: probe]
│   └── Expiry / sleep / overlapping alerts [~]
├── Understand coursework [~]
│   ├── Create session → choose document [~: picker limitation]
│   ├── Extract PDF / Word → save blocks [P: probe]
│   ├── Reject malformed or textless file safely [P: probe]
│   ├── Switch sessions → isolate retrieved content [P: probe]
│   └── Explain exercise → follow up → inspect citations [B: live AI]
├── Remember and revise [~]
│   ├── Save note → create card → quiz → reveal → next [P]
│   ├── Save/search persistent knowledge [P: probe]
│   ├── Ask generated knowledge answer [B: live AI]
│   └── Review/correct/delete suggested memories [~]
├── Personal-agent features [~]
│   ├── Save public HTTPS source → remove access [P]
│   ├── Approve folder → read file [~: native picker unverified]
│   ├── Edit saved prompt [P]
│   ├── Schedule routine → inspect next run → remove [P]
│   └── Generate briefing / retry failed run [~: mocked AI]
└── Return and recover [~]
    ├── Compact mode → reopen same draft [P]
    ├── Hide/show, position recovery, Spaces/displays [~]
    ├── Recover from missing AI credentials [P]
    ├── Submit oversized draft → retain text [F]
    ├── Reload saved planner / session documents [P: reconstruction]
    ├── Actual quit/relaunch and next-day use [~]
    └── Forget chat → understand retention boundary [~]
```

## What was exercised

The native UI run saved a synthetic name and daily plan; added assignments, an exam, a class, a note and a card; used timer controls and revision controls; and received a two-second reminder. The personal-agent UI saved/revoked example.com, renamed a prompt, created a daily routine and removed it. Creation of a routine showed its next occurrence and explicitly stated that Kaddo must remain open. The disposable routine was removed after inspection.

The isolated component probe recorded **48 observations**, including guided validation, repeated submissions, task completion, PDF/DOCX extraction, invalid-import preservation, scoped retrieval, keyword knowledge search, planner reconstruction, SQLite document reconstruction and clearing persisted transcripts. Repeated explicit `/task Duplicate` submissions produced two items; this is recorded as observed behavior, not proof that automatic retries duplicate actions.

The native regression run executed **291 XCTest cases: 288 passed, three skipped, zero failures**, plus **seven passing infrastructure tests**. The skipped cases are the opt-in native hotkey and live Ollama tests. No local model inference was substituted for DeepSeek. The separate legacy acceptance run reported **55 test declarations and 74 issues**; its five factory methods still throw `PendingImplementation`, so those failures do not prove the underlying user features fail. Seven infrastructure declarations passed in that run.

Evidence: [native results](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/native-tests.log), [legacy results](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/legacy-acceptance.log), [UI actions](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/ui-actions.json), [speech events](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/ui-speech.jsonl), [48 probe observations](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/probe-results.json).

### Environment and isolation

macOS 26.6.2 (25G83), arm64. A separate QA app linked the freshly tested, unchanged debug KaddoCanvas library. Its launcher used disposable planner/SQLite paths, in-memory preferences and credentials, no embeddings, disabled sounds, and OpenAI selected without a key. A second launcher opened the unchanged personal-agent window directly, with its own disposable storage. That direct opening does not establish discoverability from the production menu.

The standard production launch was not used because it hard-codes real user storage. QA launchers and the probe are saved with the report; no product sources were edited. Production Keychain credentials were not accessed by the injected QA settings. The supplied DeepSeek key was not saved, displayed in evidence, or sent to another provider. No DeepSeek request was made because this audit was explicitly scoped to the current app.

Build evidence: [build identity](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/build-identity.json), [source hashes](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/source-manifest.json), [isolated launcher](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/main.swift), [component probe](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/probe.swift), [probe rerun script](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/run-probe.py).

### Performance observations

| Observation | Measured result | Interpretation |
|---|---:|---|
| 18 UI submissions → speech-model publication | Median 9.9 ms; range 6.8–16.1 ms | Fast local feedback; excludes text entry and rendered pixels. One submission was the missing-key response path. |
| Send → subsequent AX observation | Approximately 0.38–0.45 s | Includes desktop-automation overhead; not an app-only render benchmark. |
| Single warm QA launch request → initial speech publication | 5.27 s | Includes launch-tool overhead and debug initialization; not a cold-launch benchmark. |
| Initial speech publication → onboarding prompt | 2.97 s | First-run question arrived after startup work; visibility still depends on companion presentation. |
| Research PDF / assignment DOCX / long DOCX | Small fixtures imported in roughly 4–15 ms in probe runs | Parsing/chunking/persistence timing only; native import responsiveness under large-file load unverified. |
| Live answer latency | Unmeasured | Preferred provider unsupported; no live answer generated. |

Evidence: [timing details](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/timing-summary.json) and the import entries in the probe observations. These single-machine samples establish neither a hardware-wide performance guarantee nor memory/CPU behavior during extended use.

## Prioritized weaknesses

### F01 · High · Preferred AI provider cannot be configured

**Type:** capability gap, confirmed in settings and code. **Impact:** a student with only DeepSeek credentials cannot complete general AI chat, exercise explanations, generated knowledge answers or briefings.

**Reproduce:** open + → AI settings. Only OpenAI and Ollama appear. The cloud transport fixes its endpoint to OpenAI; changing the model field does not select DeepSeek. Missing-key feedback is clear, but offers only those two providers.

**Acceptance:** add an explicitly supported DeepSeek provider, protected provider-specific credentials and a successful connection check. Retest real conversation, tool actions, grounded answers, citations, interruption and failure recovery. This is a recommendation for future work; the audit did not implement it.

Evidence: [settings snapshot](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/ui-ai-settings.txt); [AssistantSettings.swift](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/Sources/KaddoCanvas/AssistantSettings.swift:59); [OpenAIAssistantProvider.swift](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/Sources/KaddoCanvas/OpenAIAssistantProvider.swift:9).

### F02 · High · Oversized submission clears the draft

**Type:** reproduced defect. **Impact:** a student pasting an assignment or detailed question loses the visible text when validation rejects it.

**Reproduce:** put 2,001 characters into the composer and submit. The reply says “Keep your message to 2,000 characters.” The bound draft is now empty. The controller clears the query before checking length. The probe establishes the empty draft; it does not establish whether a particular editor undo stack can recover it.

**Acceptance:** validate before clearing; retain the complete text and focus, show the length limit near the input, and allow editing/resubmission. A 2,000-character input remains accepted; 2,001 characters stay intact after rejection.

Evidence: probe `oversized-input`; [NotesQueryWindowController.swift](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/Sources/KaddoCanvas/NotesQueryWindowController.swift:501).

### F03 · High · Existing student plans lack an edit path

**Type:** capability gap confirmed by command/tool inspection. **Impact:** correcting a task title or moving a deadline requires removing and recreating the item. This is routine student behavior, not an advanced operation.

**Reproduce:** create a task, then attempt `/edit task 2 Updated title`. Kaddo rejects the command. The registered tools contain creation, completion and removal, but no task-update operation; there is no separate planner edit UI. This finding is not based on `/edit` being promised syntax: inspection confirms the missing capability independently.

**Acceptance:** provide title/deadline/duration editing through a discoverable interface and natural-language tool path, preserving the task ID and completion state. Ambiguous targets must be clarified and changes must survive restart.

Evidence: probe `/edit task 2 Updated title`; [KaddoTools.swift](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/Sources/KaddoCanvas/KaddoTools.swift:4); [StudentPlanner.swift](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/Sources/KaddoCanvas/StudentPlanner.swift:609).

### F04 · Medium · “Today” mixes dates and hides additional items

**Type:** reproduced behavior with misleading presentation. **Impact:** upcoming work can crowd out work due today, and a student cannot tell how to reach the omitted tasks from the summary.

**Reproduce:** add an assignment due 1 January 2099 and run `/today`: it appears under “Today.” Add enough items for 12 open tasks: the header says 12, but only eight lines appear, with no “4 more” message or link to `/tasks`. The list follows insertion order rather than urgency.

**Acceptance:** separate overdue/today/upcoming work, show each section’s count, prioritize due dates within sections, and expose omitted items through an explicit continuation. Preserve the numbering or stable identifiers used for subsequent actions.

Evidence: probe `today-future` and `today-truncation`; [StudentPlanner.swift](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/Sources/KaddoCanvas/StudentPlanner.swift:293).

### F05 · High · Retention wording does not match persistence

**Type:** UI/code inconsistency, persistence reproduced. **Impact:** students can misunderstand whether their conversations remain on disk and what forgetting removes.

**Reproduce:** open Personal agent: its footer says “Chat stays temporary.” The session implementation persists bounded exchanges for summaries. The probe saves one exchange in SQLite and `/forget` removes it. `/help` still describes forgetting as clearing “only this session’s casual chat,” although the coordinator also clears persisted session transcripts and pending suggestions.

**Acceptance:** clearly distinguish temporary action context, locally retained transcripts, saved memories and summaries. State the actual scope of `/forget` and `/profile clear` in the UI/help; verify the advertised deletion/preservation behavior after restart. Do not imply that retained transcripts are absent merely because model requests use a no-store flag.

Evidence: [agent footer snapshot](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/ui-agent-memory.txt); probe `forget-persisted-transcript`; [AgentPlatformWindowController.swift](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/Sources/KaddoCanvas/AgentPlatformWindowController.swift:47); [PetApplicationState.swift](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/Sources/KaddoCanvas/PetApplicationState.swift:258); [StudentPlanner.swift](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/Sources/KaddoCanvas/StudentPlanner.swift:608).

### F06 · Medium · First-run feature discovery requires exploration

**Type:** expert usability concern; not a measured novice-user failure rate. **Impact:** a new student initially sees a pet and status indicator, while task planning, document import, knowledge and AI setup are distributed behind hover/chat/+ controls and slash help.

**Observed:** chat can be opened and the pet’s AX help explains double-click/drag. The first-run capture does not expose a persistent, visible student workflow launcher. Automated text entry repeatedly lost the floating composer before submission; using compact mode, reopening the draft and clicking Send worked. This automation behavior alone is not treated as proof of a physical keyboard defect.

**Acceptance:** provide a one-time, dismissible first-use guide with visible actions to plan a day, add coursework and configure AI. Verify first-launch → first saved task with novice students and complete keyboard/VoiceOver checks on the production launcher.

Evidence: [first-run AX](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/ui-first-launch.txt), [first-run image](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/ui-first-launch.png), UI action log.

### F07 · Medium · Destructive management actions offer no visible recovery

**Type:** confirmed UI design risk. **Impact:** accidentally removing a routine, prompt or accepted memory has no visible undo/trash path. Deleting a prompt also removes its associated routines in code.

**Reproduce:** create a disposable routine and click Remove. It immediately disappears and no undo affordance appears. Inspect prompt deletion: associated routines are removed in the same operation. Memory and prompt rows also expose immediate destructive actions.

**Acceptance:** offer Undo or a recoverable trash path for saved content; disclose associated routine removal before deleting a prompt. Source revocation should remain immediate and clearly distinguished from deleting saved knowledge. Do not require confirmation for every ordinary planner action.

Evidence: [routine before removal](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/ui-routine-created.txt), [routine after removal](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/student-usability-audit/ui-routine-removed.txt); [AgentPlatform.swift](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/Sources/KaddoCanvas/AgentPlatform.swift:344); [AgentPlatformWindowController.swift](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/Sources/KaddoCanvas/AgentPlatformWindowController.swift:138).

### F08 · Low · Empty Word document gets PDF-specific advice

**Type:** reproduced error-copy defect. **Impact:** an empty Word file receives an irrelevant instruction about scanned PDFs, making recovery harder.

**Reproduce:** import `Empty.docx`. It returns “No readable text was found. Scanned PDFs need a text layer.” Existing imported content remains intact, which is correct.

**Acceptance:** show format-specific guidance: empty Word content should prompt the student to check that the document contains readable text; scanned PDFs can retain text-layer/OCR guidance.

Evidence: probe `import-Empty.docx` and `import-ImageOnly.pdf`.

## Coverage matrix

“Pass” applies to the method shown, not to every possible physical interaction or AI response. “Blocked” means the expected end-to-end outcome could not be exercised and is not assumed correct.

| ID | Scenario | Status | Method and observed result |
|---|---|---|---|
| 01 | First-run name | Pass | UI: Submit /reply Alex QA; acknowledgement and daily planning follow. |
| 02 | Skip and optional profile | Pass | Tests: PersonalizationTests and StudentPlannerTests cover skip, cancel and persistence. |
| 03 | Discover chat and keyboard entry | Partial | UI: Pet and chat openers exposed; empty composer repeatedly collapses during AX automation; Return path unverified. |
| 04 | Configure preferred DeepSeek AI | Blocked | UI + code: Only OpenAI and Ollama; fixed OpenAI endpoint. No API call made. |
| 05 | Add tasks, assignments, exams, classes | Pass | UI: Daily tasks and dated items saved with expected text feedback. |
| 06 | Guided task and invalid inputs | Pass | Probe: Invalid deadline and zero minutes rejected; valid 40-minute task saved. |
| 07 | Review Today and all tasks | Fail | Probe: Future-dated item listed under Today; 12 open tasks but only eight displayed without continuation hint. |
| 08 | Edit task title or deadline | Fail | Probe + code: /edit rejected; no planner update tool or edit control implemented. |
| 09 | Ambiguous natural-language reference | Partial | Tests: Mock-provider clarification coverage passes; live provider unavailable. |
| 10 | Repeated submissions and retry | Partial | UI/probe + tests: Explicit repeated /task creates two items; provider retry deduplication tested with mocks only. |
| 11 | Timer start/pause/resume/stop | Pass | UI: One-minute timer pauses at 00:59, resumes and stops without task completion. |
| 12 | Expiry, delayed ticks and sleep | Partial | Tests: Timer checkpoint and sleep accounting tests pass; physical sleep/wake not run. |
| 13 | Reminder delivery | Pass | UI: Two-second synthetic reminder fires once in observed speech log. |
| 14 | Complete task and reject focus on it | Pass | Probe: /done succeeds; /focus on completed item rejects. |
| 15 | Native import and extraction | Partial | UI + probe: Picker opens; automation cannot reliably navigate it. PDF/DOCX extraction and persistence pass in probe. |
| 16 | Malformed and textless import | Pass | Probe: Corrupt PDF/DOCX and blank inputs reject without changing 50 existing blocks. |
| 17 | Selected-session retrieval isolation | Pass | Probe: Orchid source retrieved in populated session; empty session returns no excerpt. |
| 18 | Exercise explanation and follow-up | Blocked | Tests + code: Routing tests pass; no end-to-end live inference with preferred provider. |
| 19 | Live answers and citation quality | Blocked | Tests: Citation validation passes with mocked responses; live quality unverified. |
| 20 | Notes, cards and quiz/reveal/next | Pass | UI: Saved note/card; quiz hides answer, reveal displays it and next hides it. |
| 21 | Knowledge search and answer | Partial | Probe: Keyword search finds saved chlorophyll note; generated answer blocked. |
| 22 | Review/correct/delete memories | Partial | UI + tests: Empty state inspected; acceptance/edit/deletion tests pass; live suggestion generation blocked. |
| 23 | Add and revoke public source | Pass | UI + probe: HTTPS source saved and removed in UI; HTTP source rejects in probe. |
| 24 | Approve/read/revoke folder | Partial | Tests: Confinement, invalid and revoked-grant tests pass; native permission/picker workflow unverified. |
| 25 | Edit saved prompt | Pass | UI: Daily briefing renamed to QA Daily briefing and immediately displayed. |
| 26 | Create/remove routine | Pass | UI: Daily routine shows next-run time; removal returns empty state. |
| 27 | Run routine and retry failures | Partial | Tests: Mock-provider scheduling, retry and mutation-boundary tests pass; live briefing blocked. |
| 28 | Hide/show, compact mode and placement | Partial | UI + tests: Compact mode/open chat observed; geometry/recovery tested; physical multi-display/Spaces checks unverified. |
| 29 | Cancel, drafts and overlapping alerts | Partial | UI/probe + tests: Reminder and missing-key feedback observed; long invalid draft lost; in-flight overlap/cancellation covered with mocks. |
| 30 | Return tomorrow and persistence | Partial | Probe + tests: Planner and knowledge reconstructed from disk; next-day test passes; actual app quit/relaunch not completed. |
| 31 | Forget and clearing boundaries | Partial | Probe + code: Persisted transcript changes from one exchange to zero; accepted knowledge preserved; help wording understates scope. |
| 32 | Accessibility and long answers | Partial | UI + tests: AX labels and readable agent window inspected; style/keyboard tests pass; VoiceOver and live accessibility-setting changes not run. |

## Rating and improvement potential

The anchors are: **5** means usable with frequent workarounds or missing central steps; **8** means routine use succeeds with limited friction; **10** requires consistently excellent completion and accessibility supported by representative testing. Dimension scores remain expert judgments. Unknown AI quality cannot earn a passing score through mock results.

| Dimension | Weight | Current | After fixes, projected |
|---|---:|---:|---:|
| Core student journey completion | 35% | 5.5 | 8.5 |
| Discoverability and ease of interaction | 20% | 6.0 | 8.5 |
| Reliability, persistence and recovery | 20% | 8.0 | 9.0 |
| Responsiveness | 10% | 8.0 | 8.5 |
| Accessibility | 10% | 6.0 | 8.0 |
| Clarity about data and AI behavior | 5% | 5.0 | 9.0 |
| **Weighted total** | **100%** | **6.4/10** | **8.6/10** |

Core completion is reduced by the unsupported preferred provider and missing task edits. Discoverability reflects the hidden entry points and composer automation limits. Reliability receives credit for passing persistence, isolation and validation coverage but is reduced by draft loss. Responsiveness receives credit for measured local feedback; live model speed remains unknown. Accessibility receives limited credit for native labels/style tests, with VoiceOver and physical keyboard use still unverified. Retention wording reduces clarity.

The largest expected gains come from enabling and validating the full preferred-provider study journey, adding safe plan editing, preserving rejected drafts, and correcting retention/Today presentation. The projected score also assumes deletion recovery, improved onboarding, appropriate error messages and passing accessibility retests. Gains interact across dimensions; they should not be added as independent points per finding. Even after those fixes, a 10/10 would require broader student testing and longer real-world use.

## Limits and next verification

- **Live AI:** general answers, multilingual quality, exercise follow-ups, real citation support, latency, rate limits and in-flight cancellation remain unverified with DeepSeek. No API credits were consumed by this audit.
- **Desktop automation:** native file selection and keystroke dispatch were unreliable. The importer was tested directly against real parsers; that does not certify Finder drag delivery, physical Return submission, or file-picker completion. The normal app quit/relaunch was not completed; fresh state reconstruction and automated next-day tests provide narrower persistence evidence.
- **Physical environment:** no multi-display, display disconnect, Spaces/full-screen, full system sleep, ten-minute inactivity, external-network isolation, VoiceOver session or OS accessibility-preference changes were executed.
- **Load:** no extended CPU/memory profiling or realistically large native import stress run. Supplied parser fixtures are small; their speed is not representative of all coursework.
- **Old requirements:** earlier docs describe RAM-only documents, a different focus/reward engine, overlapping chunks and PDF page provenance. Current code persists session documents, uses a student countdown with documented sleep inclusion, and uses block-based citations. Those differences are not automatically regressions; reconcile the old specifications before declaring the legacy suite a release gate.

The next audit should run the actual production launcher with isolated storage, exercise DeepSeek after provider support exists, repeat the complete study journey, and verify the findings’ acceptance criteria. Native file selection, keyboard-only use, real relaunch and accessibility remain required before claiming full customer readiness.
