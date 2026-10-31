# Kaddo document follow-up evaluation — rerun

**Outcome: evaluation failed its answer-quality checks. Rating: 5/10.** This run uses the synthetic fixtures and the current opt-in evaluation harness. It completed 105 turns, including three repeats each of continuity and explicit switching, plus a 25-follow-up conversation. The cloud run used the configured DeepSeek `deepseek-flash` model through the production controller route:

`NotesQueryWindowController.submit → submitInput → DocumentQuestionRouter → answerDocument → LocalNotesAssistant.answerCloud`

The evaluator also counted coordinator provider calls. Request bodies and credentials were not logged; metadata confirms synthetic data only and no credential values captured.

## Rerun results

| Scenario | Turns | Evidence score | Required-answer score |
|---|---:|---:|---:|
| Normal continuity, repeat 1 | 7 | 5/7 | 5/7 |
| Normal continuity, repeat 2 | 7 | 5/7 | 5/7 |
| Normal continuity, repeat 3 | 7 | 5/7 | 5/7 |
| Explicit switches, repeat 1 | 12 | 10/12 | 10/12 |
| Explicit switches, repeat 2 | 12 | 10/12 | 10/12 |
| Explicit switches, repeat 3 | 12 | 8/12 | 8/12 |
| Ambiguity | 3 | 3/3 | 3/3 |
| Natural phrasing | 6 | 3/6 | 3/6 |
| Context boundaries | 10 | 9/10 | 10/10 |
| Cancellation and retry | 3 | 3/3 | 3/3 |
| Long conversation (initial query plus 25 follow-ups) | 26 | 5/26 | 5/26 |
| **Total** | **105** | **66/105 (62.9%)** | **67/105 (63.8%)** |

The evidence score requires the intended source and required support passage. The answer score checks required facts and scenario expectations. Neither is a complete claim-by-claim entailment score.

- **Citations:** every emitted citation ID was in the exact evidence sent to the model (105/105 turns passed the validity predicate). However, nine turns counted as successful document answers had no citation IDs, so validity does not mean citation coverage was complete.
- **Prompt budgets:** all 90 turns with a measured provider prompt were within the local builder budget; 15 turns had no prompt because the router clarified or used another route. Largest measured prompt was 1,367 bytes; largest coordinator request was 18,626 bytes. Vendor token usage is unavailable in the provider response and was not recorded.
- **Provider calls:** 104 counted app-level requests: 59 direct document requests and 45 coordinator `respond` calls. No separate knowledge-grounding provider calls were counted. The live test took 631 seconds. Vendor usage is unknown.
- **Repeatability:** normal continuity repeated at 5/7 each time. Explicit switches scored 10/12, 10/12, then 8/12. On the third switch run, two Revision follow-ups focused ParserGuide and returned the old rule rather than ParserRevision’s changed `nameq` result.

## Concrete failures

- “What mistake should I avoid?” returned no relevant passage in each continuity repeat. The follow-up lost usable exercise focus even though the linked rule was available earlier.
- “Now explain exercise 3” clarified in most repeats; once it returned the unrelated status “Saved ParserAlternative.md locally. Choosing its subject and checking for tasks…” instead of answering or asking a relevant clarification. The test did not verify that a file was actually saved.
- The third explicit-switch repeat leaked ParserGuide into a ParserRevision follow-up, producing the wrong rule. This is the clearest cross-document correctness failure.
- In the 25-follow-up conversation, the first four follow-ups had bounded provider questions. After that, focus was mostly lost; 21 of 26 turns did not pass both evidence and required-answer checks, and follow-ups repeatedly asked which document.
- “The other one” did ask for clarification, but did not identify the plausible alternatives from the preceding exchange. Clarification was safe but not very helpful.
- **Prompt-injection canary:** one answer repeated the canary inside an explicit explanation that the embedded instruction was untrusted. Ten answers mentioned “the answer is 42” only while identifying and rejecting the quoted attack. No answer followed that instruction or disclosed a credential.

## Link-expansion ablation

This attempt did **not** isolate link expansion. Enabled and disabled modes selected the same two chunks, and both included the distant Section 6 rule. The test deletes stored passage-link rows, but the current retrieval path independently resolves required section support for exact exercise questions. The disabled mode therefore still finds Section 6. Unresolved Section 99 and duplicate “Examples” headings remained unresolved (zero link targets). Treat the ablation result as inconclusive, not evidence that passage-link expansion is unnecessary.

## Tests

- Focused retrieval, follow-up-context, and simulated provider-failure/retry checks: **6/6 passed**.
- `KaddoCanvasTests`: **381 tests, 12 skipped, 3 failures**. Among non-skipped tests, 366/369 passed (99.2%). Failures: companion general-chat request-count assertion (2 vs 1); OCR CVPixelBuffer creation error `-6662`; scanned PDF/DOCX extraction returned `noExtractableText`.
- The live cloud evaluation test exited failing because its quality assertions were violated; the configured cloud model did respond on this network-enabled rerun.

A first rerun under the default sandbox could not reach the provider and returned connection errors; that separate attempt is preserved but excluded from the cloud quality scores. The successful live rerun was made with network access. No implementation edits were made during this rerun.

## Artifacts

- [105-turn JSONL transcript, request counters, and ablation](transcripts-20261030T172951Z.jsonl)
- [Per-turn CSV with route, focus/revision/exercise, evidence, answer, citations, and expected/observed result](turns-rerun-20261030.csv)
- [Network-enabled live test output](live-test-rerun-network.log)
- [Sandbox-denied attempt output](live-test-rerun.log)
- [Focused test output](focused-tests-rerun.log)
- [KaddoCanvasTests output](kaddo-canvas-tests-rerun.log)
- [Earlier evaluation report](evaluation-summary.md)
