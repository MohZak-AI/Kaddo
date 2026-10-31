# Natural assistant validation · 2026-10-27

- Native suite: **169 executed, 168 passed, one opt-in live-model test skipped, zero failures**.
- Infrastructure suite: **seven passed**.
- Release build and ad-hoc signing: **passed**, including `codesign --verify --strict`. See `build.log`.

`tests.log` records the native regression suite. `harness.log` records the infrastructure
checks. The native composer tests exercise real AppKit text editing and Return submission
against isolated in-memory application state: start a timer, pause it, chat, and stop it.
The provider tests use scripted responses and intercepted URLSession requests. They verify
sequencing, payloads, structured results, English/Arabic follow-up handling, stable IDs,
validation failures, cancellation, replay protection, and document grounding. They do not
measure live model intent accuracy.

`composer-openai-settings-native.png` shows the rendered OpenAI setup controls and complete
cloud-data disclosure. The other PNGs are native view snapshots and assembled pet/composer
previews from XCTest, not CUA captures of a separately launched app. Visual inspection
confirmed the setup controls fit and the disclosure wraps without truncation.

Credentials in tests use an injected in-memory store and isolated UserDefaults. No real
API key was saved or removed, no API credits were spent, and no live planner items were
changed. The production path uses macOS Keychain. Its actual credential access, OpenAI
connectivity, and live multilingual model quality still need a configured user key.
The local Ollama endpoint was unavailable, so its transport and protocol were tested with
mocks rather than a live model. The earlier acceptance feature factories remain separate,
incomplete contracts outside the active native implementation.
