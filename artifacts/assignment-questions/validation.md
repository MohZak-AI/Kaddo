# Assignment question fix · 2026-10-27

Reported question: **“what does ex1?”**. Kaddo previously treated this as general chat and
asked what “ex1” meant. The general assistant had no document-availability context, the
offline router recognized only narrow summary requests, and literal keyword retrieval
could not match “ex1” to “Exercise 1” or include its following problem paragraphs.

The fix adds selected-session exercise routing, normalized numbered references, section
retrieval with continuation/subparts, filename disambiguation, and reference-only follow-up
context. General chat receives an availability/count flag, not document text. The document
prompt now explains assignment requirements and can derive a solution from the supplied
problem while distinguishing reasoning from document facts. Existing citation validation,
selected-session isolation, and disabled document tools remain in place.

Validation:

- Native suite: **181 executed, 179 passed, two opt-in live tests skipped, zero failures**.
  See `tests.log`.
- The new opt-in assignment check then **passed against local `qwen3.5:4b`**. It imported
  the generated `AssignmentExercises.docx` fixture, submitted the user's exact wording
  through the native composer controller, and received a cited explanation of Exercise 1.
  The answer used its actual polynomial, derived `f′(x) = 2x + 3`, and evaluated `f′(2) = 7`.
  See `live-model.log`. This check used a synthetic assignment, not the user's private file.
- Eleven dedicated regression tests cover abbreviations, Arabic digits, numbered and inline
  headings, exercise continuation, subquestions, non-heading cross references, Ex1 versus
  Ex10, multiple files, explicit filenames, bounds, unrelated chat, follow-ups, both provider
  paths, citations, and context invalidation.
- Release build and ad-hoc signing: **passed**, including `codesign --verify --strict`. See `build.log`.

The running app is not automatically quit: its uploaded document text is RAM-only.
Quit the old process, open the rebuilt `.build/Kaddo.app`, and re-upload the assignment
before retrying the question. No live planner entries or real credentials were changed.
