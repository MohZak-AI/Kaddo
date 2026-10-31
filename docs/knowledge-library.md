# Knowledge Library

Open **Knowledge Library…** from Kaddo’s menu bar menu or the chat composer’s **+** menu. Create a note, import a PDF, DOCX, UTF-8 TXT or Markdown file, search saved text, and organize it into Personal, Work, Study, General or your own categories. The window can resize and close while indexing continues. Note editors support Command-S. Extracted text remains readable when the original file moves.

Session uploads automatically enter the persistent library. Add a PDF, DOCX, UTF-8 TXT or Markdown file through the picker or drop it on Kaddo or a session box. The destination is captured before extraction, so switching sessions never redirects an upload. Re-uploading the same path updates that session’s saved item; the same path in another session remains independent. Extracted text and session records survive restarts, even if the original file moves. `/ask` and assignment references continue to use only the selected session’s documents.

After a three-second pause following an upload or completed conversation, the selected AI provider chooses a useful existing category for unfiled uploads and refreshes that session’s summary in **General**. Filing a document under Study, Work or another category preserves its original session ownership. Later imports preserve manual category moves. The agent also has `organize_knowledge` and `summarize_session` tools for direct organization and summary requests, such as “summarize this session so you remember it later.” Each session has one updated summary rather than a growing collection of duplicates.

Automation requires a configured chat provider. Uploads are saved even without one; pending unfiled documents or missing summaries are retried when a provider becomes available or on restart. Classification and summarization failures appear in Activity. Summaries cover up to 20 file excerpts (24,000 characters total) and 24,000 characters of recent conversation, so they do not guarantee exhaustive recall. Full extracted documents remain searchable. **Clear Active Session Documents** removes that session’s saved files and summary; ordinary app shutdown preserves them.

## Local storage and indexing

The production SQLite database is `~/Library/Application Support/Kaddo/Knowledge/knowledge.sqlite`. Categories, extracted text, chunk IDs, source metadata and embeddings survive restarting Kaddo. The database uses SQLite FTS5 for keyword search and a local cosine search for embeddings, with a maximum of 20,000 chunks across the library. No cloud database, folder watcher, OCR, or MCP is involved. Each session retains up to 80 completed conversation exchanges within a 48,000-character budget for summarization.

Run Ollama locally and install its embedding model if it is not already present:

```sh
ollama pull embeddinggemma
```

Embeddings always use local `embeddinggemma`; the chat model remains independently selectable. Embedding-only models do not appear as chat choices. When local embedding inference is unavailable, saved text remains available through keyword search. The window shows indexing status and errors, and **Retry indexing** rebuilds pending vectors. Replacing the embedding model or its dimensions invalidates incompatible vectors before rebuilding them.

Imports extract text off the main UI actor. PDF and DOCX retain the document importer’s validation and bounds; TXT and Markdown require readable UTF-8 text with no NUL bytes and an 8 MiB file limit. Image-only PDFs require readable embedded text; there is no OCR.

## Explicit memory and managed sources

Use **New note** or a direct request such as `remember in Personal: I prefer peppermint tea`. A request without an existing category asks you to choose one; reply with a category name. Normal chat is retained in its session for automatic summaries; individual personal-memory suggestions still use their separate review flow. Model-requested save, update and delete actions are registered, typed tools with validation, replay protection and an explicit-request check.

Your optional profile is mirrored into Personal. Tasks, classes, revision cards and reminders are mirrored into Study; quick notes appear in General. Managed entries are labelled and can be moved to another category, but their text and deletion remain controlled by the original planner/profile tools. Stable source keys preserve IDs and category moves across updates. Synchronization captures immutable snapshots only after successful saves, drains snapshots serially and skips unchanged source content. A corrupt planner file cannot erase the previous index. `/profile clear` removes its derived profile items. `/forget` clears the chat, retained session transcripts, pending summary jobs and assistant clarifications while preserving saved knowledge (including existing summaries) and planner data.

## Answers and privacy

The composer starts with **All categories**. Choose a category in the + menu to filter knowledge retrieval; its name remains visible next to the composer. Relevant personal questions such as “What is my preferred tea?” automatically consult saved knowledge. The assistant can also request a knowledge search for other questions. Search yields at most five excerpts and 6,000 text characters.

A separate, tool-free generation request receives those excerpts as user data, with source IDs validated against the supplied snippets. Stored instructions cannot run planner tools. The general assistant’s action loop and conversational history receive no retrieved text or derived answer. Answers and cited source previews are displayed separately in the activity UI. Classification and summaries use separate requests with tools disabled; uploaded instructions cannot call agent tools. With OpenAI chosen, bounded file excerpts and retained conversation are sent to OpenAI for automatic organization and summarization, and relevant excerpts are sent for knowledge answers. With local Ollama, these operations stay local. Embeddings and the database stay local in both cases. If no match exists, Kaddo says it could not find saved knowledge.

Stop, Escape, model/provider changes and knowledge source changes invalidate a pending knowledge answer. A delayed provider response cannot republish an answer for an earlier library revision. Closing the library window does not cancel background indexing.

## Verification

```sh
./scripts/test.sh --filter 'SessionKnowledgeTests|KnowledgeIntegrationTests|KnowledgeCoreTests|OllamaEmbeddingTests|OllamaClientTests'
./scripts/test.sh --filter KaddoCanvasTests
./scripts/test.sh --filter HarnessTests
```

The test wrapper keeps Swift module and package caches in the writable workspace for restricted sessions.

Live local embedding evidence is in `artifacts/knowledge/live-core.log` and `artifacts/knowledge/embedding-calibration.json`. The actual local embedding-to-answer path is recorded in `artifacts/knowledge/live-grounding.log`. The final frozen integrated snapshot passed 262 native tests (3 skipped, zero failures) and all 7 Harness tests; its output is in `artifacts/knowledge/integration-isolated-tests.log`, with captured source hashes in `artifacts/knowledge/verified-sources.json`. Cloud request validation uses intercepted test requests; it does not establish that a real OpenAI key is configured. The obsolete acceptance feature factories are separate from the native canvas and HTTP harness suites.
