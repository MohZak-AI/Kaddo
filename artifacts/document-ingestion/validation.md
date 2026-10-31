# Document ingestion validation — 29 October 2026

Implemented chat plus direct upload, automatic category selection/creation, supported
planner extraction, durable clarification questions, source evidence, and retries.
See [the behavior and recovery guide](../../docs/document-ingestion.md).

## Automated checks

The native suite executed **309 XCTest cases: 305 passed, four skipped, zero failures**.
All **seven harness checks passed**. The skipped checks require opt-in desktop/live
Ollama conditions. Command:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/kaddo-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/kaddo-swift-cache \
swift test --disable-sandbox --cache-path /tmp/kaddo-package-cache \
  --filter 'KaddoCanvasTests|HarnessTests'
```

[Native and harness log](native-and-harness-tests.log). After the final cancellation
and completion-emotion adjustments, the directly affected ingestion, assignment,
and native composer tests were rerun: [final focused log](final-focused-tests.log).

Fourteen ingestion tests cover category creation/General fallback; tasks and weekly
classes with provenance; sequential PDF/DOCX/TXT/Markdown imports; bad-file isolation;
repeated/renamed uploads; restart without the original file; durable clarification;
unrelated chat; skip/confirm conflicts; missing-year rejection; evidence/tool-call
validation; planner write failure and retry; interruption between planner commit
and journal completion; no automatic reinterpretation of legacy uploads; explicit
reprocessing; and filename-filtered retrieval across internal sessions.

An initial unrestricted suite attempt also exercised the older acceptance target.
That target has unfinished MVP factories that intentionally throw “MVP pending …
Wire this factory to the real engine,” producing 74 issues. The same initial run
caught an assignment-response integration regression, which was corrected and is
covered by the passing native suite. [Initial full-suite attempt](full-suite-attempt.log).
The unfinished acceptance target is not claimed to pass.

## Native UI smoke check

Built and launched a separate **Kaddo Upload Preview** app against the actual native
components. Knowledge and planner state were RAM-only, with a synthetic provider;
no user documents or credentials were uploaded or modified. The synthetic input
was [Biology.txt](Biology.txt). The preview was closed after testing.

Verified through native accessibility and interaction:

1. Composer exposes **Upload documents**, message input, and Send. It has no category,
   session, library, workflow, or settings popover. [Composer capture](composer-live.png)
   and [accessibility state](composer-live.txt).
2. Clicking Upload opens **Upload documents — Kaddo will organize them** directly.
3. Selected Biology.txt in the native picker. Observed the actual completion text:
   **“Biology.txt: Filed under Biology. 2 planner entries saved.”** A **Sources**
   disclosure opened to **“Biology.txt · block 1”**. Automated checks also assert
   that these two entries are the assignment deadline and weekly class.
4. Opened the separate **Kaddo · AI settings** window, containing provider controls,
   installed local models, and Refresh models. [Settings capture](ai-settings-live.png)
   and [accessibility state](ai-settings-live.txt).
5. Reopened chat and verified that its unsent question was preserved through upload.

The [idle companion capture](companion-idle-live.png) shows its collapsed state,
not the completion reply. Completion was verified in the native accessibility tree;
the screenshot auto-collapsed before capture. These checks use synthetic inference
and do not claim live provider extraction accuracy or manual drag-and-drop coverage.
Drop delivery and ingestion formats are covered by native tests.

## Build

The release application is `.build/Kaddo.app`. The build script assembles resources
and ad-hoc signs it. See [release build log](release-build.log) and
[signature/plist checks](signature-checks.log).
