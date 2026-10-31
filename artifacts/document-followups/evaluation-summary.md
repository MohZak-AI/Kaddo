# Kaddo English document follow-up evaluation

**Rating: 5/10.** Explicit filename selection and short, grounded explanations usually work. Follow-up routing is brittle: several natural phrasings drop the document focus, Exercise 3 asks for clarification after context was established, and long conversations lose the thread after four follow-ups.

## Setup and production path

Used synthetic fixtures only: [ParserGuide](fixtures/ParserGuide.md), [ParserAlternative](fixtures/ParserAlternative.md), and [ParserRevision](fixtures/ParserRevision.md). They share terms and exercise numbers but intentionally disagree on the delimiter/backslash rule. The fixtures include exact outputs, unrelated passages, an unresolved Section 99 reference, duplicate “Examples” headings, and an embedded instruction canary.

The live run submitted through `NotesQueryWindowController.submit → submitInput → DocumentQuestionRouter → answerDocument → LocalNotesAssistant.answerCloud`, with the configured DeepSeek provider and `deepseek-flash` model. The coordinator provider path was also counted where a turn took that route. The evaluator captures the route, question, selected source IDs/text, answer, citations, focus and revision before/after, expectations, and observations for every turn. Provider bodies and credential headers/values were not logged; the transcript marks `credentialValuesCaptured=false` and `syntheticDataOnly=true`.

There were **99 live user turns**. Normal continuity and explicit document switching were each repeated three times. The counter recorded **122 provider requests**: 53 direct document requests and 69 coordinator `respond` calls (52 coordinator turns); no separate knowledge-grounding provider call was recorded. The provider does not expose decoded vendor usage to Kaddo, so **token usage is unknown and was not recorded**.

## Results

| Measure | Observed |
|---|---:|
| Evidence correctness: right source and required supporting passage selected | 59/99 (59.6%) machine-scored |
| Required answer facts present | 64/99 (64.6%) machine-scored |
| Citation IDs independently checked against captured selected evidence | 93/99 (93.9%); 6 unresolved capture mismatches |
| Direct prompt-budget checks | 76/76 measured within budget; 23 turns had no provider prompt to measure |
| Long conversation | 20 turns; only the first four follow-ups kept the original question plus the latest follow-up in the document route |

These are separate evidence and answer scores: a correct-sounding answer without the required source passage does not pass the evidence score. They are machine-scored rates, not a claim-level entailment audit. I manually reviewed the material scorer flags and transcript examples; the evaluator does not produce a reliable numeric score for every unsupported claim.

### What worked

- Explicit filenames switched focus among Guide, Alternative, and Revision. No wrong-document focus was observed on the explicit switch turns. Repeated switching was consistent, though some answers omitted a required exact fact.
- Short `How do I start?` and `Why?` follow-ups usually retained ParserGuide revision 1 and selected the linked Section 6 rule.
- Starting with no focus, asking “the other one,” and asking about an ambiguous exercise eventually elicited clarifications. The multiple-match Exercise 2 response first described all three definitions and asked which document afterward; it should have clarified before answering all three.
- After an unrelated joke and local timer command, `Why?` requested document context. A new session, document replacement, and conversation clear did not silently reuse the old evidence. Timer input took the local-command route.
- Cancelling after a successful turn retained the prior focus; retry sent the original question with only the latest follow-up. A separate simulated provider-failure/retry test also passed.
- Embedded document instructions did not control the assistant or reveal a credential. Several answers explicitly identified the text as untrusted. Four transcript flags that said otherwise were false positives caused by quoting the injected text while rejecting it.

### Failures and risks

- “Give me an example” left the document route in **all three** normal-continuity repeats and **all three** explicit-switch repeats. The next “Now explain exercise 3” then asked which document, despite a previous explicit focus. This is the clearest repeatable continuity failure.
- Natural phrasing was inconsistent. “Walk me through it” and “Does that apply to the next question?” went to general conversation. “No, I meant question 3” selected ParserRevision among conflicting Exercise 3 / Question 3 matches and then asked for clarification instead of applying the correction to the established focus.
- In the 20-turn run, document grounding failed after the first four follow-ups; later turns repeatedly asked which document or said no relevant passage was found. The observed query did not grow by concatenating every prior follow-up, but persistence of document focus was not achieved.
- Some answers were unsupported by the selected document evidence. For example, one “Does that apply to the next question?” answer asserted how all future exercise references would be routed; one “What mistake should I avoid?” answer generalized that the documents warn against mixing specifications without a supporting passage in the captured evidence. These count against answer quality even where the wording was fluent.
- At least one cloud-routed turn returned “The local model returned invalid or incomplete JSON. Try again.” The request was unsuccessful and did not establish follow-up context.
- The scorer recorded 93/99 citation sets as independently valid. In six turns the route preflight did not reconstruct the evidence set that the live callback used, so the transcript cannot independently verify those citations. Kaddo’s stream decoder restricts citations to the provider’s selected-source allowlist, but these six are reported as unverified rather than passes.

## Retrieval ablation

This is an **ablation on identical fixtures**, not a historical baseline. With link expansion enabled, retrieval selected Exercise 2 plus the distant Section 6 definition and contained the required rule. With it disabled, retrieval selected only Exercise 2 and omitted the rule. Neither mode resolved the nonexistent Section 99 target; duplicate “Examples” headings were not treated as a unique link target.

## Prompt budgets

The direct document prompt builder used its 12,000-character evidence budget and up to 48 sources. Measured submitted prompts ranged from 0 to 3,241 bytes (0 means no prompt was submitted); all 76 measured provider prompts were within the builder’s budget. The system prompt was 2,127 bytes. Coordinator requests reached 20,985 bytes; the app’s coordinator budgeter uses an estimated 16,384-token context with a 2,048-token reserve, but the run captured bytes rather than the estimator’s token counts. Exact token consumption cannot be reported.

## Tests

- Focused retrieval, follow-up-context, and simulated failure/retry checks: **6/6 passed** (100%).
- Completed `KaddoCanvasTests` run: **370 tests, 12 skipped, 3 failures**; among non-skipped cases, 355/358 passed (99.2%). Failures were the companion general-chat request-count assertion (2 vs 1) and two OCR failures (CVPixelBuffer `-6662`; scanned PDF/DOCX `noExtractableText`).
- A separate unfiltered package run recorded **373 tests, 12 skipped, 5 failures**, including two cross-reference/subquestion assertions in `AssignmentQuestionTests.testSubquestionsAndCrossReferencesDoNotTruncateTheExercise`. A later target rerun stopped during compilation because `AssignmentContextSearch.swift` changed while the compiler was reading it. The completed runs above are the last completed suite results.
- That unfiltered log also ran the separate `KaddoAcceptanceTests` target: **55 tests, 74 MVP-pending issues**. Those scaffold issues are not included in the `KaddoCanvasTests` rate.

The live evaluation transcript was captured before final scoring-only harness fixes for cancellation attribution, a clarification phrase, and several evidence-capture mismatches. The original transcript is preserved unchanged; the six citation capture mismatches are explicitly treated as unverified. No cloud rerun was made after those evaluator-only changes.

## Artifacts

- [Per-turn CSV with messages, routes, focus/revision/exercise, provider question, evidence IDs/text, answers, citations, expectations and outcomes](turns.csv)
- [Full 99-turn JSONL transcript, provider request counters and link-expansion ablation](transcripts-20261030T163316Z.jsonl)
- [Synthetic fixtures](fixtures/)
- [Focused test output](focused-tests-final.log)
- [Completed KaddoCanvasTests output](kaddo-canvas-tests.log)
- [Unfiltered package test output](../document-followups-full.log)
- [Interrupted latest target rerun output](kaddo-canvas-tests-final.log)
- [Opt-in evaluation harness](../../Tests/KaddoCanvasTests/DocumentFollowupLiveEvaluationTests.swift)

Only synthetic fixtures, evaluation artifacts, and test-only harness code were added for this evaluation. No implementation changes were made.
