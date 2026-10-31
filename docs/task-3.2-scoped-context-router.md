# Task 3.2 — Scoped Document Context Router

Implemented October 26, 2026.

`ScopedDocumentContextRouter.fetchContextForActiveSession(query: String) -> String`
reads `PetApplicationState.activeSessionID`, looks up that record in
`sessionFolders`, then filters its RAM chunks against the record's `files` URL
array. `PetApplicationState` exposes the same method as a convenience. Each
`SessionFolderRecord` owns a separate `DocumentMemoryStore`; secondary records
are never traversed during retrieval. Empty context never falls back to another
session. No filesystem directory scanning or global document index is involved.

`files` is derived from successfully imported chunks' full `sourceURL` values in
import order, with duplicate URLs removed. Failed imports add no URLs; removal
and clearing remove their URL references. Identical filenames in different paths,
and the same URL imported into separate sessions, retain separate session memory
and source identities. Queries use the extracted RAM snapshot; they do not reread
changed files on disk. Reimport a file to load its updated contents.

Imports preserve paragraph boundaries using the existing extractor. Each paragraph
uses the existing four-sentence / 1,600-character windows; very long paragraphs
can therefore occupy several blocks. PDF paragraph boundaries reflect the line
breaks available in its text layer. Keyword search uses Unicode normalization,
exact-word preference, substring fallback and deterministic import-order ties.
Retrieval returns at most five whole blocks and 6,000 text characters. Fewer
matching blocks return fewer results. Empty, invalid, cancelled or unmatched
string-utility requests return an empty string. The assistant's throwing search
path retains its existing user-facing errors and avoids Ollama for no matches.

The Ask Notes window provides session boxes, selection and a New Session button.
Drops into a `SessionFolderView` capture its destination before provider loading;
pet drops capture the currently selected destination at drop time. Finishing an
import after selection changes cannot move the file into the new session. Only
the active memory store is observed by `LocalNotesAssistant`. Selection changes
cancel pending retrieval/inference, reset speech, clear citations and rebind the
memory observation. Generation tickets prevent stale stream publication. Clearing
documents clears the active session; application termination clears all records.

Validation:

- `./scripts/test.sh --filter 'KaddoCanvasTests|HarnessTests'`: 87 native XCTests
  and 7 infrastructure tests passed; no failures.
  Evidence: `artifacts/task-3.2-final-tests.log`.
- Nine added regressions cover active-session isolation, empty/no-match behavior,
  full URL identity, identical URLs across sessions, paragraph ranking/top-five
  limits, atomic failed imports, imports spanning selection changes, scoped
  Ollama prompt contents, streaming cancellation/citation invalidation and native
  session-box rendering.
- The native window test imports a real PDF, creates/selects sessions and verifies
  changes in the same hosted SwiftUI view. Render inspected at
  `artifacts/task-3.2-session-window.png`.
- `./scripts/build-app.sh`: release app rebuilt and ad-hoc signed.
  Evidence: `artifacts/task-3.2-build-app.log`.
- `codesign --verify --deep --strict .build/Kaddo.app` and Info.plist lint passed.

Native Finder drag delivery and real Ollama generation remain manual acceptance.
The automated inference checks use a fully intercepted local transport. No model
was downloaded and the running pet was not relaunched. To exercise the new UI,
launch the rebuilt `.build/Kaddo.app`, open Ask Notes, put different documents in
two session boxes, and ask a question whose answer exists only in the other box.
That query must produce no relevant context until the matching box is selected.
Also switch boxes while an answer is streaming and verify the old answer clears.

All repository files were already untracked at task start; no commit was created.
