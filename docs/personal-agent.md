# Kaddo personal agent

Open **+ → Personal agent…** for Memories, Sources, Prompts, and Routines.
The floating companion keeps its existing controls and providers. Conversation now uses a
shared warm, natural voice; offline replies and planner messages no longer append mascot
signoffs or smileys automatically.

## Memories

After substantive conversation or an explicit preference/correction, Kaddo can suggest one
stable detail from the user's own words. This is a separate, tool-free model request; it
never receives document excerpts, fetched pages, or assistant-generated claims. Each
suggestion includes an exact supporting quote and date. Short greetings do not trigger it.
If inference is unavailable or the response fails validation, no suggestion is created.

Review the editable suggestion and choose **Save memory**, **Save correction**, or **Dismiss**.
Corrections display the memory being replaced. Facts, provenance, and removal of the pending
suggestion commit atomically. Accepted memories use the existing local knowledge library and
can be edited or deleted in Memories. Explicit remember/save requests and profile answers
continue through their existing paths.

Accepted preferences form a bounded personalization context; longer saved information is
retrieved on demand. The live action loop remains limited to eight exchanges/24,000 characters in RAM. Separately, each session retains up to 80 exchanges/48,000 characters locally for automatic summaries in General knowledge; see [Knowledge Library](knowledge-library.md).
`/forget` cancels curation and pending summary jobs, clears pending suggestions, chat and retained session transcripts, and preserves accepted memories and existing knowledge summaries.
Up to ten suggestions and the last 100 dismissed supporting quotes are retained locally.

## Sources

Choose a folder through the native picker or add a public HTTPS page. Folder bookmarks grant
read-only access, require reselection when stale, and can be revoked with **Remove access**.
Missing/revoked sources fail explicitly, including in saved prompts and routines.

The source reader supports TXT, Markdown, PDF, and DOCX up to 8 MB. Descriptor-relative,
no-follow traversal prevents paths and concurrently replaced symlinks from escaping a grant.
PDF/Word extraction uses a private, temporary snapshot of the validated file descriptor,
then removes it. Listings scan at most 1,000 entries, return at most 100 paths/6,000 characters,
and omit hidden files, symlinks, and common application packages.

Web reading supports public HTTPS links, not search, authenticated browser pages, or scripts.
Every DNS answer and redirect is checked; validated addresses are pinned to the connection.
A fixed `/usr/bin/curl` invocation uses TLS verification, no shell, proxies, curlrc, cookies,
or user credentials. Reads have a 20-second shared deadline, three redirects, 64 KB headers,
2 MB bodies, and 6,000-character excerpts. HTML extraction uses a linear scanner. Bookmark
creation/resolution runs off the UI thread with a five-second deadline.

Ask to read a link, list/search an approved folder, or read a relative file. Approved sources
have visible IDs for disambiguation. Folder summaries use up to five supported files from
the bounded listing; request a specific file for precise coverage. Source content crosses a
separate tool-free grounding boundary and citations must identify supplied excerpts. It never
enters general conversation or memory curation. Reading does not import text permanently.
The composer indicates OpenAI source answers; selected cloud inference receives the bounded
excerpts. Local Ollama inference stays local.

## Prompts and routines

Daily briefing and Study planning start as editable saved prompts. Create, edit, duplicate,
run, delete, and select sources for other prompts. Explicit prompt execution enters chat
with its own source selection, bypassing automatic uploaded-document routing.

**Schedule…** offers daily, weekly, or intervals of 30 minutes to seven days, using this Mac's
local time. No routine is created automatically. Schedules run only while Kaddo is open.
Every scheduled inference is tool-free at both provider and application boundaries: it can
summarize approved sources and planner context, but cannot create tasks, save memories,
change settings, or execute commands.

One routine runs at a time. User conversation, pending guided questions, active/paused timers,
typing and the 60-second quiet interval defer it. New interaction interrupts in-flight work.
Missed occurrences coalesce into one catch-up; durable occurrence IDs prevent duplicate runs
after restart. Interrupted/failed runs expose Retry, and failures do not create repeated alerts.
Monitoring suppresses identical source/planner/prompt snapshots. Editing a monitoring prompt
changes its fingerprint. Briefings enter the existing activity tray; previews defer during busy UI.

The last 100 bounded run summaries persist; raw source excerpts remain temporary. Database
schema 2 adds an agent-state table to the existing knowledge database. Schema-1 data migrates
additively. Corrupt/future databases remain protected, and failed claims cannot execute work.

## Verification and attribution

See [validation and limitations](../artifacts/tomo-agent/validation.md), the
[native test log](../artifacts/tomo-agent/native-tests.log), and
[release build log](../artifacts/tomo-agent/build.log).

The Swift implementation adapts concepts from [Tomo](https://github.com/tamnd/tomo), reviewed
at revision `c785e71f9ed9ec6c4d30c8ffc94cc70881c6f76d`; it adds no Go runtime or daemon.
Tomo's MIT copyright/license notice ships in `Resources/Tomo-LICENSE.txt`.
