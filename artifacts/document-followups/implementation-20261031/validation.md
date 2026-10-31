# Document conversations: implementation and validation — 31 October 2026

Implemented shared per-session document discussion state, bounded dialogue context, restart restoration, explicit response outcomes and foreground response ownership. Cloud answering has a maximum of one repair retry for invalid JSON/citation output, using the same selected provider and evidence. No classifier or additional model dependency was added.

## Live evaluation

DeepSeek `deepseek-flash`, synthetic fixtures only, through the production composer/controller route.

- **Evidence checks: 105/105. Answer checks: 105/105.**
- All 105 turns passed the corrected evaluator; no critical failures.
- **94/94 completed document answers had citations**, checked against the exact supplied evidence. Clarifications, cancellations, and local commands are separate outcomes.
- The initial question plus 25 follow-ups kept ParserGuide focus throughout: **26/26**.
- No wrong-file answers, unexplained focus loss, foreground reply overwrites, accepted injected instructions, or prompt-budget violations were observed.
- Foreground latency: **median 2.85 s; p95 3.55 s**. This measures the complete submitted turn, including any routing and repair calls.
- **98 foreground provider requests** (96 document calls and 2 coordinator calls). **35 background requests** were observed during measured turns. These are app-level dispatch counts, not vendor billing records.
- Vendor token usage remains unavailable.

| Scenario | Turns | Evidence | Answer |
| --- | ---: | ---: | ---: |
| normal_continuity_repeat_1 | 7 | 7/7 | 7/7 |
| normal_continuity_repeat_2 | 7 | 7/7 | 7/7 |
| normal_continuity_repeat_3 | 7 | 7/7 | 7/7 |
| explicit_switches_repeat_1 | 12 | 12/12 | 12/12 |
| explicit_switches_repeat_2 | 12 | 12/12 | 12/12 |
| explicit_switches_repeat_3 | 12 | 12/12 | 12/12 |
| ambiguity | 3 | 3/3 | 3/3 |
| natural_phrasing | 6 | 6/6 | 6/6 |
| context_boundaries | 10 | 10/10 | 10/10 |
| failure_recovery | 3 | 3/3 | 3/3 |
| long_conversation_25_turns | 26 | 26/26 | 26/26 |

### Evaluation corrections and comparison

The earlier report scored 66/105 evidence and 67/105 answers. Its evaluation inferred completion from shared UI state and sometimes substituted hypothetical prompts. The new evaluator uses actual typed outcomes and provider-boundary snapshots, and counts repair attempts. It accepts equivalent “one token” and “single token” phrasing. The older aggregate scores are therefore not a strictly identical rubric.

The first implementation run preserved evidence on 105/105 turns but flagged four response-format/citation failures and two correct “single token” paraphrases. Required citation IDs are now explicit in the prompt, malformed cloud output can be repaired once, and the final run above passed.

## Native verification and build

**Final native suite: 392 tests executed, 12 skipped, zero failures (380 passed).** This includes the repeated-resume bound regression, response repair, restart restoration and background isolation. The release app built successfully and passed `codesign --verify --deep --strict`; its binary is newer than all implementation sources.

Two OCR tests fail under the restricted sandbox but both pass with normal macOS access. The complete final suite was therefore run with normal macOS access. No OCR implementation changes were made, and no native test failures remain unresolved.

- [Final native tests](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/document-followups/implementation-20261031/native-tests-macos-final.log)
- [Focused repair tests](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/document-followups/implementation-20261031/repair-focused-tests.log)
- [OCR with normal macOS access](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/document-followups/implementation-20261031/ocr-native-access.log)
- [Final release build](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/document-followups/implementation-20261031/release-build-final.log)
- [Live evaluation log](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/document-followups/implementation-20261031/live-evaluation-final.log)
- [105-turn transcript](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/document-followups/transcripts-20261031T111405Z.jsonl)
- [Per-turn CSV](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/document-followups/implementation-20261031/turns-final.csv)
- [Machine-readable results](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/document-followups/implementation-20261031/results.json)
- [Review patch](/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/artifacts/document-followups/implementation-20261031/changes.patch)

## Manual answer review and limitations

Reviewed representative initial answers, definitions, examples, corrections, conflicting-file switches, clarification cases and the long conversation, including the points that previously failed. The responses used the intended rules and addressed the latest requests. Some still include an unnecessary exercise recap.

A relative request such as “does that apply to the next question?” can still ask for explicit wording when the next section was not retrieved. The current work deliberately retains the existing passage-link/vector strategy; broader relative-section retrieval remains a later improvement. Safe clarification is preferable to inventing the next problem.

These results cover one synthetic document corpus and one configured cloud model. They are not claim-by-claim entailment measurements or a guarantee for arbitrary real documents. Restart, repeated resumption, Arabic routing, invalid history, revision replacement, delayed responses, background upload isolation and tool-boundary protection have deterministic native regression coverage.

To use the release, quit the running Kaddo instance and launch `/Users/mohammedmoulai/Documents/ChatGPT/Kaddo/.build/Kaddo.app`. Provider settings, planner data and uploaded knowledge remain in their existing local storage.
