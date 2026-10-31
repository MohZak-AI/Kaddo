# Personal-agent validation

Implemented the approved Tomo-inspired Swift adaptation. Open **+ → Personal agent…**.

## Automated results

- `./scripts/test.sh --filter 'KaddoCanvasTests|HarnessTests'`: **284 native XCTest cases,
  zero failures, three skipped**; **seven infrastructure cases passed**. See `native-tests.log`.
- `./scripts/build-app.sh`: release compilation and ad-hoc signing passed. Result:
  `.build/Kaddo.app`. See `build.log`.
- New coverage includes shared voice, raw JSON local responses, memory evidence validation,
  acceptance/corrections/provenance/deletion, forget cancellation, concurrent acceptance and
  source writes, unknown citations/tool injection, workflow CRUD and document routing,
  missed schedules/restart dedupe, scheduled mutation rejection, monitoring suppression,
  busy/quiet deferral, DST, persistence failure and explicit recovery/retry.
- Source tests cover escaped paths, concurrent symlink replacement, supported extraction,
  listing/file/body bounds, invalid/stale/revoked bookmarks, public/private/mapped addresses,
  mixed DNS, redirect revalidation/loops, cancellation, stalled resolvers, HTML/entity parsing,
  malformed HTML performance and exact script/style/custom-tag boundaries.

The three skipped cases are opt-in live suites in the existing suite. Older acceptance
factories remain separate incomplete MVP specifications; this filter does not establish
that those unrelated contracts have been implemented.

## Live smoke checks

`probe.swift` uses an ephemeral planner/library and only synthetic prompts. `live-smoke.log`
records the compiled probe's final results:

- Actual public HTTPS fetch of example.com succeeded, with the expected page text.
- Installed **qwen3.5:4b** answered an overwhelmed student in English and Arabic without
  forced mascot language.
- A synthetic study-note question produced the correct two-daughter-cell answer with a validated supplied source ID.
- A preference statement produced a valid, evidence-backed memory suggestion after fixing
  local structured responses to avoid a nested conversation JSON envelope.

No live OpenAI key was used. Cloud transport, credentials, capability validation, and
payload isolation are covered by mocks; this does not establish live cloud model quality.
A brief smoke test also does not establish comprehensive conversational quality.

## Native manual QA

Built `.build/KaddoAgentPreview.app` against current debug objects using `build-preview.py`.
The preview uses **RAM-only** state and a synthetic provider; it does not change the user's
planner, personal key, saved knowledge, prompts, or routines.

Desktop accessibility inspection and screenshots verified:

- Editing a suggested fact, Save memory, the accepted provenance/date, and immediate display
  updates after editing an accepted memory.
- Source empty state, public HTTPS entry, and the saved source/Remove access controls.
- Native folder picker navigation to `source-fixture/` and its read-access action.
- Built-in prompt editing and persisted-in-preview title update.
- Schedule sheet, explicit routine creation, and next-run display in Routines.
- Run invoking the preview provider and displaying its synthetic result.

**Folder-permission QA limitation:** UI automation repeatedly lost access to the preview
window after closing the folder picker. Native scoped-bookmark persistence/reselection was
therefore not established end-to-end. Invalid/stale/revoked/scope lifecycle cases use injected
permission seams. Bookmark creation/resolution is off the UI thread, bounded to five seconds,
and failures report a reselection error. The source reader never falls back to unrestricted
folder access.

The UI uses native system text/colors, 8/16/24-point spacing, restrained headings, labeled
controls, scrolling content, and a resizable window (minimum 680 × 500). Screenshots showed
readable grouping and no clipped content at the default size. No custom color-token gaps
were introduced. Native focus and contrast behavior come from AppKit/SwiftUI controls.

## Review

Separate specification and code-quality reviews approved the source reader and the
platform/coordinator/UI/storage integration after the following corrections:

- File-descriptor confinement, pinned DNS addresses, bounded resolver cancellation, and
  linear HTML parsing.
- Serialized memory acceptance including failure rollback with multiple waiters.
- Durable routine claims, cancellation revalidation, failed-claim retry/recovery, and
  acceptance barriers around routine completion.
- Saved-workflow source routing, prompt-aware monitoring signatures, and memory edit refresh.

Tomo attribution and its MIT notice ship in `Resources/Tomo-LICENSE.txt`.
