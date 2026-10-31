# Phase 3 compact session handoff

The four task checkpoints are recorded here as work completes. There is no
callable session compaction tool; this durable file is the next-session handoff.

## Task 3.1 — native drop surface

Added PDF and imported Word UTTypes to `.onDrop`, with file-URL transport for
Finder. Resolved URLs must be local and end in `.docx` or `.pdf` (case insensitive).
Provider loading begins inside the drop callback. Unsupported URLs get a visible
message, and non-file providers return false. Batches are limited to eight files.
The alpha tracker opens the full transparent canvas during a supported native
file drag and restores normal passthrough afterward.

The Word type uses `UTType(importedAs:conformingTo:)`, because plain identifier
lookup can return nil on Macs without an application registering DOCX support.
Validation is recorded in `artifacts/phase-3-task-3.1.log`.

Checkpoint: **3 drop tests passed**. Native Finder drag acceptance remains manual.

## Task 3.2 — dependency-free extraction

`DocumentTextExtractor.extract(at:emit:)` runs synchronously on a worker and emits
Word runs/breaks or PDF pages. Uses Apple's PDFKit/XMLParser and the macOS zlib
system library through `CZlib`; no downloaded dependencies or external processes.
Reads at most 20 MiB input, 8 MiB main XML, 8 MiB extracted UTF-8 text, 2,000 pages.
ZIP central/local headers, entry bounds, decompressed size and CRC are checked.
Only `word/document.xml` is inflated, in 32 KiB buffers. Nothing is unpacked to disk.
DTD/entity declarations (including UTF-16) and deep XML nesting are rejected.
ZIP64, encrypted ZIP/PDF, and OCR are deliberately unsupported. Word headers,
footers and notes are outside main-body extraction. Callers must discard partial
stream output if parsing fails. Security-scoped access is balanced with defer.

Checkpoint: **7 extractor tests passed** using real DOCX/PDF fixtures, damaged and
textless files, resource limits, consumer cancellation, XML attacks and truncated
ZIPs. Evidence: `artifacts/phase-3-task-3.2.log`.

## Task 3.3 — non-overlapping sentence windows and RAM storage

Added `DocumentTextChunker` with native NaturalLanguage sentence segmentation:
four sentences per window, maximum 1,600 Swift Characters, 20,000 chunks. A long
sentence is split at grapheme boundaries. Unicode whitespace becomes a single
space and control-only characters are removed. Chunks retain boundary spaces;
joining with an empty separator reconstructs the normalized text exactly.

`PetApplicationState.documentMemory` owns a main-actor `DocumentMemoryStore`.
Extraction and chunking run in a detached worker; only a successful full result
is published. UUIDs, document ID, filename and sequential indices accompany each
chunk. Store limits are 16 MiB UTF-8 text and 20,000 chunks. One import at a time
is allowed; concurrent drops receive a useful retry message. Clear cancels the
worker and invalidates its generation so late results cannot repopulate memory.
Removal, clear, failure, cancellation and reimport are covered. There is no disk
index, network request or persisted document context. The menu includes Clear
Documents, and shutdown clears context.

Checkpoint: **13 chunker/store tests passed** in
`artifacts/phase-3-task-3.3.log`. Later hardening adds one chunk-count test.

## Task 3.4 — adversarial and lifecycle verification

Phase 3 adds **28 tests**: 3 drop, 11 extractor, 8 chunker and 6 store tests.
Adversarial cases include whitespace-only and control-only text, CRLF/Unicode
line separators, nonbreaking spaces, Arabic/CJK, combining marks, flags and emoji
with skin tones/ZWJ, script-like and instruction-like strings, and long text
without punctuation. Chunk reconstruction proves non-overlap and no text loss
after documented normalization. Invalid configuration and chunk-count limits
are checked. XML coverage includes UTF-16/UTF-32 DTD bypass attempts, encoding
reinterpretation, namespace variations, CDATA, and excessive nesting. ZIP tests
cover stored/deflated entries, truncation, mutated headers/CRC and dishonest
expanded sizes; output is bounded while inflating.

Store tests exercise atomic publication, stable provenance within a document,
independent instances, limits, failed imports, removal, clear, cancellation,
concurrent import rejection, and reimport. Thirty import/clear cycles followed
by a weak-reference check confirm the completed worker does not retain its
owner. This and Address Sanitizer are targeted evidence, not a guarantee about
all leaks in macOS frameworks or every possible malformed input.

Final validation:

- `./scripts/test.sh --filter KaddoCanvasTests`: **53 passed**, no failures.
  Evidence: `artifacts/phase-3-canvas.log`.
- `./scripts/test.sh --filter HarnessTests`: **7 passed**, no failures.
  Evidence: `artifacts/phase-3-harness.log`.
- `./scripts/test.sh --scratch-path .build/phase-3-asan --sanitize=address
  --filter 'Document(TextChunker|TextExtractor|MemoryStore)Tests'`: **25 passed**,
  no sanitizer errors reported. Evidence: `artifacts/phase-3-address-sanitizer.log`.
- The Phase 3 combined task checkpoint is `artifacts/phase-3-task-3.4.log`.
- `./scripts/build-app.sh`: release app built and ad-hoc signed;
  `codesign --verify --deep --strict .build/Kaddo.app` succeeds.
  Evidence: `artifacts/phase-3-build-app.log`.

## Resume in the next session

1. Read this file, `README.md`, and `docs/native-acceptance.md`.
2. Launch `.build/Kaddo.app` after quitting an older running Kaddo process.
   This session rebuilt the bundle but did not relaunch the user's pet.
3. Complete N05/N09: actual Finder DOCX/PDF drops over transparent and opaque
   pixels, TXT rejection, Escape cancellation, memory clear, and responsiveness
   during a realistic large import. Native drag delivery has not been claimed.
4. Continue only the next authorized phase. Retrieval, Ollama, page references,
   focus rewards, and animation remain later work.

The older `MVPFactory.documents` remains unbound. Its contract expects overlapping
character windows, page references, and ranked retrieval. Phase 3 follows the
newer explicit non-overlap requirement; old assertions were preserved. The full
legacy acceptance suite is still expected to fail at its unimplemented factories
and was not represented as passing. Earlier workspace/focus adapter differences
are documented in `phase-2-handoff.md`.

All repository files were untracked at session start. Existing work was preserved,
and no commit was created. All four task checkpoints are recorded above; this
file is the durable substitute for programmatic session compaction.
