# Document retrieval

Document questions share `DocumentRetrievalService`, regardless of the answer provider. Retrieval selects documents by session ownership (`session-file:<session UUID>:`), rather than filing category. Explicit filenames override remembered focus; clear follow-ups retain the current focus. Unnamed standalone questions search every document in the current session and return ranked evidence with per-document coverage. Other-session access requires a request mentioning other/all sessions or documents.

Broad assignment questions collect requirements across sections. Exercise questions select the full matching section, avoiding package-name references and preferring a substantive section over a contents-list entry. Search questions use local embeddings and SQLite full-text search with reciprocal-rank fusion. When enabled, a local PostgreSQL/pgvector HNSW index ranks semantic candidates; SQLite remains authoritative and provides keyword fallback. Search never invents a missing exercise or treats every scoped chunk as a positive match.

Chunks preserve newlines, code and table separators, target 1,200 characters and cannot exceed 1,600. The answer context allows 12,000 characters / 48 evidence blocks and bounds the encoded prompt to 24,000 bytes. Local Ollama requests reserve a 16,384-token context with a 2,048-token output limit. This uses a conservative byte budget rather than a model-specific tokenizer. The selected cloud/local answer provider remains unchanged. The answer boundary has no action tools; document text and OCR remain untrusted data.

Apple Vision reads DOCX embedded images in place and PDF pages with insufficient selectable text, entirely locally. Sparse/scanned PDF pages can additionally use the explicitly installed local `qwen3-vl:4b` model for bounded layout, table and diagram interpretation. Qwen text is labeled as interpretation and never replaces extracted quotes. Missing models, failures, and non-PDF embedded images retain text and report limitations. Work is bounded to 40 candidate PDF pages per upload.

Schema version 5 adds independent document-index versioning and persistent focus. Legacy uploads rebuild their search index locally on load. The old index stays usable until the replacement text/chunks commit together. File contents are checked against the saved native text before re-reading images. Missing or changed originals use saved text with a visible extraction limitation. Original content hashes, categories, source revisions and ingestion/planner records are preserved. Rebuilds resume document by document; embedding batches commit independently so interrupted work resumes at the first missing chunk. `retry indexing` retries unavailable extraction and local vectorization without planner reprocessing.

## Validation

Start local pgvector with `docker compose -f docker-compose.pgvector.yml up -d` and set `KADDO_PGVECTOR=1` before launching Kaddo. The database listens only on loopback at port 55432 and keeps data in a Docker volume. Set `KADDO_PGVECTOR_PASSWORD` in the launch environment to change the local development password. Pull `qwen3-vl:4b` manually in Ollama to enable PDF visual interpretation; Kaddo does not download models.

Run `scripts/test.sh --filter KaddoCanvasTests`. Apple Vision and native UI tests need normal macOS access outside a restrictive process sandbox.

`KADDO_VERIFY_LOCAL_LABS=1 scripts/test.sh --filter DocumentRetrievalTests` also reads the two reported lab files from Downloads, locally, using an ephemeral database and no inference provider. Private uploads are not repository fixtures. Live local embeddings are covered by `KADDO_TEST_LOCAL_VECTORS=1 scripts/test.sh --filter ReportedDocumentTests.testLiveLocalVectorsAndCourseFiling`, using synthetic text.
