# Kaddo document follow-up evaluation — rerun, 31 October 2026

## Result

The synthetic live evaluation passed **105/105 evidence checks** and **105/105 expected-outcome checks**, with no critical failures. The production route was exercised end to end: `NotesQueryWindowController.submit → submitInput → DocumentQuestionRouter → answerDocument → LocalNotesAssistant.answerCloud`.

The configured provider was **DeepSeek `deepseek-flash`**. Fixtures were synthetic. The captured metadata says credential values were not captured; provider request bodies were not logged. Vendor token usage was not available because the provider adapter discards the usage object.

| Scenario | Turns | Evidence | Expected outcome |
| --- | ---: | ---: | ---: |
| Normal continuity, repeat 1 | 7 | 7/7 | 7/7 |
| Normal continuity, repeat 2 | 7 | 7/7 | 7/7 |
| Normal continuity, repeat 3 | 7 | 7/7 | 7/7 |
| Explicit document/revision switches, repeat 1 | 12 | 12/12 | 12/12 |
| Explicit document/revision switches, repeat 2 | 12 | 12/12 | 12/12 |
| Explicit document/revision switches, repeat 3 | 12 | 12/12 | 12/12 |
| Ambiguity and clarification | 3 | 3/3 | 3/3 |
| Natural phrasing | 6 | 6/6 | 6/6 |
| Session, replacement, clear, unrelated chat, and timer boundaries | 10 | 10/10 | 10/10 |
| Cancellation and retry | 3 | 3/3 | 3/3 |
| Long conversation: initial question + 25 follow-ups | 26 | 26/26 | 26/26 |

Across the run there were 94 completed document answers, all **94/94 with citations valid against the exact evidence sent to the provider**. There were 7 clarification outcomes, 1 cancelled outcome, 2 local command outcomes, and 1 general conversation outcome. The 26-turn conversation retained ParserGuide focus on all 26 records. The original question remained one anchor plus the current follow-up; earlier follow-ups did not accumulate into a growing concatenated query.

## Fixture coverage and observed limits

The three fixtures are [ParserGuide.md](fixtures/ParserGuide.md), [ParserAlternative.md](fixtures/ParserAlternative.md), and [ParserRevision.md](fixtures/ParserRevision.md). They share exercise numbers and terminology but define conflicting tokenization rules. They include distant references, distractor passages, duplicate “Examples” headings, unresolved Section 99 references, and an embedded instruction that should be treated as untrusted document text.

The live run selected the intended document and rule through the tested switches, ignored the injected instruction, and produced the expected token strings. Ambiguous requests without an established target asked for clarification. Replacing the document, changing sessions, clearing the conversation, and inserting unrelated chat or a timer did not silently reuse old evidence. A dispatched answer was cancelled and retried without replacing the last successful follow-up context. The deterministic simulated-provider-failure/retry regression also passed in the focused native suite.

Prompt-budget checks passed for all 94 provider-bound document answers. The largest captured prompt was 6,541 bytes (system prompt 3,560 bytes). Median foreground turn latency was 2.64 seconds; p95 was 3.52 seconds.

**Ablation limitation:** link expansion enabled and disabled selected the same two evidence IDs, including the distant rule. This run therefore does not establish the causal benefit of link expansion. It is a same-fixture ablation attempt, not a historical baseline. The unresolved and duplicate-heading link counters were both zero in each mode.

## Requests and local tests

The live evaluator counted **96 foreground provider requests**: 94 document calls and 2 coordinator calls. It separately recorded **18 background requests**; request bodies were not recorded. Provider-reported token usage was unavailable.

- Full KaddoCanvas suite: **392 executed, 380 passed, 12 skipped, 0 failed**.
- Focused document-follow-up/retrieval suite with normal macOS access: **62 executed, 60 passed, 2 skipped, 0 failed**. The skips were the opt-in live test (run separately above) and private-upload local validation.
- A preliminary focused run inside the restricted sandbox had two Vision/OCR failures. Both passed with normal macOS access; the complete suite also passed with normal access.

No implementation files were changed during this rerun. The earlier evaluation artifacts and failing transcripts were preserved.

## Ratings

- **Improvement: 9/10.** The current run is clean across repeated continuity and switching scenarios, corrections, ambiguity, context boundaries, cancellation, citations, and a 26-turn conversation. Compared with the earlier 66/105 evidence and 67/105 answer report, the result is substantially better. The old evaluator used a different rubric, so that comparison is directional rather than strictly apples-to-apples. The inconclusive link-expansion ablation keeps this below 10.
- **Usability: 8/10.** Follow-up wording and document switching worked reliably, and the system clarified when the target was genuinely ambiguous. The remaining limitation is conservative clarification for some implicit next-section references, plus occasional unnecessary exercise recap reported in the prior manual review. This is an automated synthetic evaluation, not a user study.

## Artifacts

- [Raw per-turn transcript with provider question, exact selected passages, answer, route, and checks](transcripts-20261031T112516Z.jsonl)
- [Per-turn CSV](turns-20261031-rerun.csv)
- [Live cloud-test log](live-evaluation-20261031-rerun.log)
- [Full KaddoCanvas test log](kaddo-canvas-tests-20261031-rerun.log)
- [Focused native-test log with normal macOS access](focused-tests-20261031-rerun-macos.log)
- [Initial sandboxed focused-test log](focused-tests-20261031-rerun.log)
- [Prior failing 105-turn transcript](transcripts-20261030T172951Z.jsonl)
- [Prior failing cloud-test log](live-test-rerun-network.log)
- [Prior rerun report and detailed failure notes](evaluation-rerun-20261030.md)
