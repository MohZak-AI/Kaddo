# Session navigation fix — 2026-10-29

Explicit session navigation is resolved locally, without requiring an AI-generated tool call or a UUID supplied by the user. Session names, valid UUIDs, and numbered replies to a pending choice are supported. Missing and duplicate names ask a concise follow-up; no session is created implicitly. The tool also accepts a title field while retaining strict UUID validation for its id field.

Navigation takes precedence over document clarification handling. It preserves pending ingestion questions and routes selection through the existing guarded executor, so session-change observers do not cancel the action itself. Numbered choices retain the displayed session IDs if another session is subsequently created.

Validation:
- Seven focused regression tests pass, including native composer navigation with a pending document deadline question and no AI requests.
- Full KaddoCanvas suite: 343 tests, 10 skipped, zero failures. See swift-tests.log.
- Rebuilt/signed the release app and restarted the idle older process.
- Live companion: sent “change sessions”; observed a clear choice between Session 1 (current) and Session 2, with no invalid-response error. The original Lab 5 due-date clarification remained pending.
- Sent “cancel”; observed “Okay, I’ve kept the current session.” Closed the activity popover afterward. No file was uploaded or sent to a cloud provider during this manual check.
- Updated an existing interruption test to wait for bounded readiness instead of assuming initialization finishes in 30 ms.
