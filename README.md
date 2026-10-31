# Kaddo

Kaddo is a macOS desktop companion for students. An animated pet stays on the desktop while a natural-language assistant helps organize study work, manage notes, and answer questions about saved documents.

## What it does

- Organizes tasks, assignments, exams, classes, reminders, notes, flashcards, quizzes, and focus timers.
- Imports PDF, DOCX, TXT, and Markdown documents into a local knowledge library, with document search and cited answers.
- Supports OpenAI, DeepSeek, and local Ollama models. Kaddo uses the selected provider and does not silently switch providers after an error.
- Provides a personal agent for public HTTPS pages and folders the user has approved, plus read-only briefings while the app is open.
- Stores planner data and the knowledge library on the Mac. Recent casual conversation is kept in memory, not written to a chat-history file.

See [the current architecture](docs/current-architecture.md) for the data flow and local/cloud boundaries.

## Requirements

- macOS 13 or later
- Xcode or the Xcode Command Line Tools with Swift 6
- Network access on the first build to fetch the SwiftPM dependencies

Ollama is optional and is needed only for local model inference or local embeddings. PostgreSQL with pgvector is optional; the local SQLite knowledge library works without it.

## Build and run

```sh
./scripts/build-app.sh
open .build/Kaddo.app
```

The build script creates a locally ad-hoc signed app bundle for development. Distribution signing and notarization are not configured.

## Tests

Run the Swift test suite with:

```sh
./scripts/test.sh
```

To run a focused suite, pass SwiftPM options through the script, for example:

```sh
./scripts/test.sh --filter KaddoCanvasTests
```

The scripts keep SwiftPM build products and caches under `.build/`.

## AI and data setup

Choose a provider in **Kaddo → AI settings…**. OpenAI and DeepSeek require a personal API key; Ollama requires a locally installed model. Kaddo does not install or download models. See the [companion chat guide](docs/companion-chat.md), [document ingestion guide](docs/document-ingestion.md), and [knowledge library guide](docs/knowledge-library.md) for setup and data handling details.

Planner data is saved under `~/Library/Application Support/Kaddo/`. The knowledge library stores documents and notes in a local SQLite database. When a cloud provider is selected, requests that need that provider send the user message and relevant bounded context to that provider. Embeddings run locally through Ollama. The [knowledge guide](docs/knowledge-library.md) describes the boundaries in more detail.

## Project guides

- [Current architecture and data flow](docs/current-architecture.md)
- [Companion experience](docs/companion-experience.md)
- [Natural conversation and commands](docs/companion-chat.md)
- [Personal agent](docs/personal-agent.md)
- [Document ingestion](docs/document-ingestion.md)
- [Knowledge library](docs/knowledge-library.md)
- [Native desktop acceptance checklist](docs/native-acceptance.md)
- [Test plan](docs/test-plan.md)
- [Pet art research and attribution](assets/pet-research/README.md)

## License

No project-wide license has been selected for Kaddo. The bundled pet sprites have their own attribution and license terms in [`SpriteLicense.txt`](Sources/KaddoCanvas/Resources/SpriteLicense.txt).
