# Due-date clarification fix — 29 October 2026

The user reported a failed clarification after uploading a Word lab and answering
the due-date question. Reproduced the same generic service/clarification failure
against the configured DeepSeek provider using a synthetic Lab 5 due-date prompt.
The Word document itself successfully extracts 4,863 characters, and the exact
supplied file also completed upload through the real app under Study.

## Fix

JSON-mode cloud requests now explicitly instruct the provider to return a JSON
object at the provider boundary. The clarification prompt previously requested a
structured object without mentioning JSON, while enabling JSON response mode.
The synthetic live clarification failed before this change and passed afterward,
saving the expected assignment and clearing its pending question. Neither live
test writes to the user's planner; both use RAM-only app state and synthetic text.
Credentials are read through the existing credential store and never logged.

Also fixed two reproduced regressions: queued uploads no longer disappear if
startup restores a previous session, and document questions bypass unrelated
pending due-date clarifications. Failed upload destinations now produce an error
instead of returning silently.

## Evidence

- [Live DeepSeek before](live-before.log): same clarification failure, no assignment saved.
- [Live DeepSeek after](live-after.log): passed, assignment saved, question resolved.
- [Exact reported DOCX](reported-document.log): extraction and isolated import passed.
- [Native and harness regressions](regressions.log): 315 native tests, five opt-in
  tests skipped, zero failures; seven harness checks passed. The exact Word test
  was enabled for this run; the live DeepSeek case was run separately above.
- [Release build](build.log): signed `.build/Kaddo.app` rebuilt successfully.

Restarted the actual Kaddo app into the fixed build after clearing only the temporary
“Upload check” draft created during diagnosis. Native accessibility confirmed that
the prior Lab 5 due-date question survived the restart. The supplied Lab 8 document
is retained. The user must supply their actual due date again; no date was guessed
or inserted into their planner.
