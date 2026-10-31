# Retrieval fix validation — 2026-10-29

- Native Swift suite: **336 tests, 9 skipped, 0 failures**. Log: `swift-tests.log`.
- Local-only Lab 5 verification: complete overview, 21 coherent evidence blocks, 8,448 extracted characters including image text.
- Local-only Lab 8 verification: complete overview, 12 coherent evidence blocks, 10,815 extracted characters including image text. Exercise 1 returns its instructions instead of package-name references.
- Generated scanned PDF and embedded DOCX image fixtures: Apple Vision reads text locally; corrupt images preserve readable document text with a limitation.
- Session ownership after category moves, filename focus, exercise follow-ups after restart, stable citations, missing exercises, Markdown headings, long lines, neighboring context, scoped candidate filtering and legacy migration are covered.
- Rebuilding search preserves original content/hash/revision and planner ingestion records; stale embedding writes are rejected by chunk identity.
- Live synthetic upload indexed with local Ollama successfully; no cloud provider used. Log: `local-vector-test.log`.
- Apple Vision requires normal macOS buffer access: the restricted process sandbox initially rejected image-buffer allocation; the same tests passed with normal access.
- One intermediate full-suite run hit the pre-existing 30ms interruption timing assertion in CompanionTests; the final complete run passed.

No private document contents or cloud credentials are included in these artifacts. Live cloud answers against private uploads were not run.

## Running app verification

- Rebuilt and signed the release app at `.build/Kaddo.app`, then stopped the old idle process and launched the updated executable.
- Confirmed the live database migrated to schema 5 and both retained uploaded labs have structured indexes, with no unavailable-source fallback.
- Both uploaded documents report `indexed`; the embedding profile remains local Ollama `embeddinggemma`, 768 dimensions.
- Manually opened the native Upload documents picker directly from the companion; no organization menu appeared. Canceled without selecting or uploading files.
- The selected answer provider was not changed. Native composer broad-question, exercise, citation and clarification behavior is exercised with synthetic provider responses in AssignmentQuestionTests. Private-document cloud answers were not manually submitted. macOS menu-bar settings were unchanged and checked in source; they were not manually opened during this run.
