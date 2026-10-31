# Knowledge Library verification — 28 October 2026

Implemented and reviewed the persistent local knowledge library, categorized notes/imports, canonical profile/planner synchronization, and separate tool-free retrieval answers for local and cloud providers.

- Final frozen integrated sources: 262 XCTest cases, 3 skipped, zero failures; 7 Harness checks, zero failures. See `integration-isolated-tests.log` and capture-time `verified-sources.json`.
- Real local embeddinggemma: 768-dimensional vectors; English paraphrase and Arabic retrieval, category filters, unrelated-query rejection, persistent database reopen/stable IDs, deletion removes recall. See `live-core.log` and `embedding-calibration.json`.
- Real local qwen3.5:4b: retrieved synthetic fact answered through the tool-free grounding path with a validated citation. See `live-grounding.log`.
- Cloud transport/grounding: intercepted request tests; live OpenAI not run because no configured Kaddo credential was present. No key was displayed or logged.
- Native synthetic-data UI: category filtering, reading, editing/saving, creation after prior selection, custom category creation, moving, and category-aware searches passed. Markdown file picker selected the synthetic fixture and saved an `md` item, observed by the test app's published-item log in `native-import-observation.log`. The accessibility bridge timed out after the picker closed; this was not counted as a successful visual inspection of the imported detail panel. Thread sampling showed the app idle, not deadlocked.
- Release app built successfully and signature verified. Durable app: `.build/KnowledgeBuild/Kaddo.app`. Build log: `release-build.log`.
- Verified release app launched, Knowledge Library opened from the composer, local chat selector offered qwen3.5:4b without the embedding-only model, and the production local knowledge database initialized and indexed the existing canonical saved records. Synthetic test records were kept in isolated test databases.

Concurrent Agent feature edits were preserved. Tests and the packaged app use the frozen combined source snapshot recorded in the manifest; subsequent workspace edits from that separate work were not represented as having passed this test run.
