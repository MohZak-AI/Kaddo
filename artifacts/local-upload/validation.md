# Clear uploads and local vectors — 29 October 2026

## User-facing behavior

- Upload progress names the actual stage: reading locally, choosing a subject,
  and finishing search vectors on this Mac. A running activity is updated through
  these stages and becomes a completion summary only when the operation finishes.
- Filing favors a specific subject/course/project. Broad built-in buckets are no
  longer offered as category candidates. Completion includes the chosen destination
  and its short explanation. Internal session categories cannot be destinations.
- File completion waits for the current local indexing job, including replacement
  jobs triggered by filing/planner sync. Failed indexing is explicitly distinguished
  from successful filing, with text search retained and a local-only chat retry.
- Missing planner details explicitly say the file is already saved and may be
  skipped. Zero planner entries are described as “Ready for questions.”
- AI settings and upload help explicitly describe local vectorization. The selected
  cloud provider still handles organization and requested answers; it does not
  compute embeddings.

## Local boundary verified

Production document and query embeddings use `OllamaEmbeddingProvider`, whose
endpoint is restricted to loopback port 11434 `/api/embed`. It disables proxies,
caches and stored credentials, refuses redirects, and checks both installed-model
catalog and metadata before transmitting text to the local endpoint. Cloud model
aliases, remote hosts and missing local architecture metadata are rejected.
There is no cloud embedding fallback.

The current local database contains **204 chunks and 204 stored vectors**. Its
embedding profile is local `ollama:embeddinggemma`, matching the installed model
digest, with **768 dimensions**. The supplied Lab 8 Word document is indexed and
was filed under **Computer Science**, using a locally generated subject explanation.
The apply helper checks filename and content hash before changing only category
and explanation. It preserves the document text, source/session identity, planner
entries and pending questions. [Local filing result](applied-local-filing.log).

## Tests and live verification

- [Final native suite and harness](final-native-tests.log): **322 native cases,
  nine opt-in/environment skips, zero failures; seven harness checks passed**.
- Native regressions cover waiting for gated/replaced indexing jobs; honest offline
  status and chat retry; cloud-selected organization with embed requests confined
  to localhost; destination explanations; and internal-session destination rejection.
- [Live local upload](live-synthetic-local.log): synthetic upload indexed through
  the actual local `embeddinggemma` model. This initial run also exposed broad
  Study classification in the cloud path; the candidate-list fix resolved that.
- [Live specific routing](live-specific-routing.log): actual DeepSeek classified
  synthetic inheritance coursework into **Object-Oriented Programming**, gave a
  topic-based reason, and local Ollama finished the vectors before completion.
- [Actual document local check](reported-local-subject-vectors.log): the supplied
  Word document was extracted locally, classified by local `qwen3.5:4b` for its
  subject, then indexed by local `embeddinggemma`. Its contents were not resent
  to a cloud provider for this verification. The test does not claim full local
  planner extraction: an exploratory full local extraction response was rejected
  by validation, while the text and local vectors remained available.

Automatic approval review rejected an optional test that would resend the private
Word document to DeepSeek because explicit authorization for that export was absent.
The task continued with local-only actual-document checks and synthetic cloud
checks; no workaround cloud export was performed.

The rebuilt application is `.build/Kaddo.app`. It was restarted after applying the
verified local destination. The running app's `retry indexing` command visibly
reported “Vectors stay on this Mac using local Ollama. Search vectors are ready
on this Mac.” A final UI check also removed misleading Ready history entries for
in-progress stages: progress now updates a running operation instead.
