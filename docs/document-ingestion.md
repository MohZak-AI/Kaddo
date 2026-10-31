# Upload documents; Kaddo handles the rest

The companion has chat and a direct **Upload documents** (+) button. The button opens
one native file picker, with multiple selection for PDF, DOCX, TXT and Markdown.
Dropping files on the pet uses the same sequential processing pipeline. There are
no category, session, prompt, or workflow choices in the composer.

Kaddo saves readable text locally before asking the selected provider to organize
it. It chooses a specific subject/course/project category, reusing a matching category
or creating one. Broad Study/Work buckets are excluded from suggested destinations.
It explains the placement in the completion reply, using General
when uncertain. Supported tasks, assignment/exam deadlines and weekly classes are
saved automatically. Ambiguous dates or conflicting schedules produce a question
in chat; unrelated chat leaves the question pending. Reply **skip** to omit the
pending entry. Conflicting entries require **yes** to keep an additional entry;
existing entries are never overwritten automatically. Ask Kaddo in chat to inspect,
correct, or remove saved planner items.

The completion reply names the document and destination, explains that choice,
reports saved planner entries, and includes source evidence. It waits for local
indexing before saying search vectors are ready. If local indexing is unavailable,
it says so explicitly and keeps ordinary text search available. A pending deadline
question explicitly states that the file is already saved and can be skipped. Document questions search across internal
sessions, with explicit filename references narrowing retrieval. Existing exercise
question handling and its source citations remain available.

**Kaddo → AI settings…** in the macOS menu bar contains provider, credentials and
model controls. Companion settings remain separately accessible there. With cloud
AI selected, extracted upload text is sent in bounded sections for organization
and extraction; questions send matching excerpts. With Ollama selected, inference
stays local. No additional provider fallback occurs.

## Recovery and persistence

- **retry uploads** or **retry documents** resumes pending/failed work from saved
  text; the original file is not needed.
- **retry indexing**, **retry vectorization**, or **finish indexing** retries only
  local vectorization. This never calls a cloud AI provider.
- **reprocess documents** explicitly analyzes retained session uploads again,
  including older uploads. Existing documents are not automatically reinterpreted.
- SQLite schema version 4 adds a document-processing journal without changing
  existing document/session tables. Document text and initial pending work commit
  together. Pending work and clarification questions survive restart.
- Persisted uploads keep a content-addressed copy of the original in the local
  `Knowledge/Originals` directory so later visual extraction can resume when the
  picker source disappears. Ephemeral stores keep their existing source location.
- Planner entries and their import receipts commit in the same atomic planner JSON
  write. Optional receipts preserve compatibility with older planner files.
  Content hashes, stable entry identities and semantic fingerprints prevent
  repeated uploads and interrupted retries from duplicating planner entries.
- Document analysis has no tools. Its output is validated and restricted to filing
  and supported planner entries with exact source evidence. Uploads cannot start
  timers, change settings, enable notifications, or create routines.
- Documents beyond 64 overlapping 12,000-character sections or 200 distinct planner
  entries are retained but marked pending with a size error. Scanned PDFs require
  an extractable text layer. No OCR is added in this change.

## Local vectorization boundary

Document extraction, chunking, document/query embeddings and vector storage run on
this Mac. Production embedding requests use local Ollama's `embeddinggemma` model
at the loopback `/api/embed` endpoint. SQLite keeps the source embeddings; when
`KADDO_PGVECTOR=1`, a rebuildable semantic index syncs them to loopback PostgreSQL
for indexed retrieval. Remote hosts, cloud model aliases, and HTTP redirects
are rejected. Every embedding batch checks the installed local model first. There
is no cloud embedding fallback, including when cloud AI is selected for chat or
classification. With DeepSeek/OpenAI selected, document text still goes to that
selected provider for classification/planner extraction and requested answers;
that is separate from local vectorization.
