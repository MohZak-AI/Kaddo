# Gradual personalization

Kaddo uses its existing native pet bubble and composer to ask one optional personal
question per local calendar day. The order is name, birthday, subjects, current goal,
interests, and focus duration. Acknowledgment leads into daily planning; sharing more
details on the same day requires `/profile continue` or `/profile edit <field>`.

## Behavior and storage

- `StudentPlannerData.profile` is optional. Existing planner JSON needs no migration.
  `UserProfile` stores volunteered values, skipped fields, last question date, and the
  last birthday celebration. Atomic writes and corrupt-file preservation are retained.
- A stored value marks a field answered; a skipped field is excluded from automatic
  questions. Cancel, unrelated commands, document import/session changes, and clear
  dismiss pending personal input. Dismissal records the current local date, including
  when a question was carried across midnight. Editing can revisit skipped fields.
- Personal questions accept natural text and `/reply`. Planner questions continue to
  require `/reply`. The composer observes planner state directly to update its hint
  and accessibility help. Answers are handled locally and excluded from chat history.
- A 60-second quiet interval after submitted input, completed replies, or alerts defers automatic questions.
  Composer typing, controls, scheduled/active inference, active/paused timers, and any
  guided question also block automatic check-ins. Explicit profile commands remain usable.
- Names accept 1–80 Unicode characters; other text accepts 1–200 characters on one line.
  Control characters and line separators are rejected while emoji joiners are preserved.
  Focus accepts 1–720 whole minutes, including `45m` and `45 minutes`.
- Birthday parsing accepts `MM-DD`, English month-name/day, and day/month-name, without
  a year. Gregorian date validation includes February 29. Celebrations use the current
  local date and February 28 in non-leap years. App messages prepend a birthday wish
  once per day and retain any pending personal question.
- Preferred focus length applies only to newly created tasks and `/timer` without
  arguments. Existing tasks, explicit lengths, and the five-minute break default persist.
- `/profile clear` removes profile values/progress and defers automatic questions until
  tomorrow. The composer also clears casual RAM history, which may contain old names in
  greetings. `/forget` continues to clear chat alone. Neither command removes planner items.

## Conversation boundary

`LocalCompanionAssistant` reads a `UserProfileSnapshot` provider for each request or local
reply. Only six volunteered values are included; scheduling and planner state are omitted.
`CompanionPromptBuilder.prepare` accepts an optional snapshot and encodes `userProfile`
inside prompt JSON. The constant system prompt treats it as untrusted data, uses names
sparingly, and prohibits inferring age. Profile changes cannot execute student commands
through chat, and document inference remains a separate path.

## Verification

Run `./scripts/test.sh --filter 'KaddoCanvasTests|HarnessTests'`; results are saved in
`artifacts/personalization-tests.log`: 143 native cases, zero failures, one opt-in case
skipped, plus seven passing infrastructure tests. `PersonalizationTests` covers daily progression,
quit-before-answer, reload, skip/cancel/edit/clear, field validation, legacy/corrupt files,
default precedence, annual and leap-day birthdays, timezone boundaries, generation and
typing deferral, timer/reminder ordering, structured profile prompts, and Unicode replies.
The opt-in live Ollama test remains skipped during the offline regression run.

`./scripts/build-app.sh` produces the ad-hoc signed `.build/Kaddo.app`; build output is
saved in `artifacts/personalization-build.log`.

Manual native QA used `artifacts/personalization-preview.swift`, linked against the actual
debug library and launched as `.build/KaddoPersonalizationPreview.app`. The preview uses
RAM-only planner storage and does not alter the user's saved planner. Native keyboard
input verified a plain name answer, personalized welcome, `/profile continue`, birthday
hint, invalid birthday feedback, valid birthday saving, profile review, and clear deferral.
The preview was closed after QA. Screenshots captured from the running app:

- `artifacts/personalization-name-native.png`
- `artifacts/personalization-welcome-native.png`
- `artifacts/personalization-birthday-input-native.png`
- `artifacts/personalization-birthday-validation-native.png`
- `artifacts/personalization-profile-native.png`
- `artifacts/personalization-clear-native.png`

Daily rollover and birthday dates were validated with injected clocks in automated tests;
the manual check did not change the system date or run a live model.
