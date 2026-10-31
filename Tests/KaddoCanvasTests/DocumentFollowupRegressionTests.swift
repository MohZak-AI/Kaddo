import XCTest
@testable import KaddoCanvas

@MainActor
final class DocumentFollowupRegressionTests: XCTestCase {
    private struct RequestObservation: Sendable {
        let question: String
        let currentQuestion: String
        let historyCount: Int
        let historyText: String
        let suppliedIDs: Set<UUID>
        let citedIDs: Set<UUID>
        let suppliedRoles: [String]
        let suppliedText: [String]
    }

    @MainActor
    private final class SnapshotCapture {
        var values: [PreparedDocumentRequestSnapshot] = []
    }

    private actor EvidenceEchoProvider: AssistantProvider {
        private(set) var observations: [RequestObservation] = []

        func respond(to request: AssistantRequest) async throws -> AssistantTurn {
            guard let content = request.input.first?["content"]?.string,
                  let payload = try? JSONDecoder().decode(AssistantJSON.self, from: Data(content.utf8)),
                  let notes = payload["referenceNotes"]?.array,
                  let question = payload["question"]?.string else { throw AssistantError.invalidResponse }
            let references = notes.compactMap { note -> (UUID, String, String)? in
                guard let rawID = note["id"]?.string, let id = UUID(uuidString: rawID) else { return nil }
                return (id, note["role"]?.string ?? "", note["text"]?.string ?? "")
            }
            guard !references.isEmpty else { throw AssistantError.invalidResponse }
            let batches = stride(from: 0, to: references.count, by: 6).map {
                Array(references[$0..<min($0 + 6, references.count)])
            }
            let lines = batches.enumerated().map { index, batch in
                AssistantJSON.object([
                    "speechBubbleText": .string(index == 0 ? "Synthetic grounded answer." : "Supporting passage."),
                    "pet_emotion": .string("celebrating"),
                    "sourceIDs": .array(batch.map { .string($0.0.uuidString) })
                ])
            }
            let answer = try AssistantJSON.object(["lines": .array(lines)]).jsonString()
            observations.append(RequestObservation(question: question,
                currentQuestion: payload["currentQuestion"]?.string ?? question,
                historyCount: payload["conversationHistory"]?.array?.count ?? 0,
                historyText: (try? payload["conversationHistory"]?.jsonString()) ?? "",
                suppliedIDs: Set(references.map { $0.0 }), citedIDs: Set(references.map { $0.0 }),
                suppliedRoles: references.map(\.1), suppliedText: references.map(\.2)))
            return AssistantTurn(text: answer)
        }

        func snapshot() -> [RequestObservation] { observations }
    }

    func testContextualFollowupPhrasesRouteToDocuments() {
        let names = ["ParserGuide.md"]
        for message in ["Walk me through it.", "What does that mean here?",
                        "Does that apply to the next question?", "Give me an example."] {
            XCTAssertTrue(DocumentQuestionRouter.isFollowup(message), message)
            XCTAssertTrue(DocumentQuestionRouter.shouldRoute(message, hasDocuments: true,
                previousQuestion: "Explain exercise 2 in ParserGuide.md.", filenames: names), message)
        }
        XCTAssertFalse(DocumentQuestionRouter.isFollowup("Tell me a joke about a cactus."))
    }

    func testProductionRouterKeepsFocusAndBoundedQuestionPastTwentyTurns() async throws {
        let (state, assistant, controller, provider, snapshots) = try await makeRig()
        let firstQuestion = "Explain exercise 2 in ParserGuide.md."
        let followups = ["Why?", "Walk me through it.", "What does that mean here?",
            "Does that apply to the next question?", "Give me an example.", "Explain the steps.",
            "Show me the steps.", "Which rule are you using?", "What mistake should I avoid?", "اشرح الخطوات"]
        var conversation = [firstQuestion]
        for index in 0..<24 {
            conversation.append(index == 6 ? "Now explain exercise 3." : followups[index % followups.count])
        }

        var originalQuestion = firstQuestion
        var currentExercise = "exercise 2"
        for (index, message) in conversation.enumerated() {
            if index == 0 || message == "Now explain exercise 3." {
                originalQuestion = message
                if message == "Now explain exercise 3." { currentExercise = "exercise 3" }
            }
            try await submit(message, to: controller)
            let context = try XCTUnwrap(assistant.documentFollowupContext, "turn \(index + 1) lost document focus")
            let guide = try XCTUnwrap(state.knowledge.items.first { $0.title == "ParserGuide.md" })
            XCTAssertEqual(context.documentID, guide.id)
            XCTAssertEqual(context.revision, guide.revision)
            XCTAssertEqual(context.exercise, currentExercise)
            XCTAssertEqual(context.originalQuestion, originalQuestion)

            if message == "Now explain exercise 3." {
                XCTAssertEqual(context.originalQuestion, message)
                XCTAssertEqual(context.exercise, currentExercise)
            }

            let observations = await provider.snapshot()
            let observation = try XCTUnwrap(observations.last)
            let expectedQuestion = index == 0 || message == "Now explain exercise 3."
                ? message : "\(originalQuestion)\nFollow-up: \(message)"
            XCTAssertEqual(observation.question, expectedQuestion)
            XCTAssertTrue(observation.citedIDs.isSubset(of: observation.suppliedIDs))
            XCTAssertEqual(snapshots.values[index].sources.map(\.id).sorted { $0.uuidString < $1.uuidString },
                observation.suppliedIDs.sorted { $0.uuidString < $1.uuidString })
            XCTAssertTrue(snapshots.values[index].prompt.contains("referenceNotes"))

            if index == 0 {
                XCTAssertTrue(observation.suppliedRoles.contains("explicit_reference"))
                XCTAssertTrue(observation.suppliedText.contains { $0.localizedCaseInsensitiveContains("Section 6") })
            }
        }
        XCTAssertEqual(conversation.count, 25)
        let finalObservations = await provider.snapshot()
        XCTAssertEqual(finalObservations.count, 25)
    }

    func testAmbiguousExerciseClarifiesBeforeProviderCall() async throws {
        let (state, assistant, controller, provider, snapshots) = try await makeRig()
        controller.presentation.query = "Explain exercise 3."
        controller.submit()
        try await waitUntilDone(controller)

        let observations = await provider.snapshot()
        XCTAssertTrue(observations.isEmpty)
        XCTAssertTrue(snapshots.values.isEmpty)
        XCTAssertNil(assistant.documentFollowupContext)
        XCTAssertTrue(state.speechBubbleText.localizedCaseInsensitiveContains("Which document do you mean"))
        XCTAssertTrue(state.speechBubbleText.contains("ParserGuide.md"))
        XCTAssertTrue(state.speechBubbleText.contains("ParserAlternative.md"))
        XCTAssertTrue(state.speechBubbleText.contains("ParserRevision.md"))
    }

    func testClearRevisionReplacementAndSessionSwitchInvalidateEvidence() async throws {
        let (state, assistant, controller, _, _) = try await makeRig()
        try await submit("Explain exercise 3 in ParserGuide.md.", to: controller)
        XCTAssertNotNil(assistant.documentFollowupContext)
        XCTAssertFalse(assistant.sources.isEmpty)

        assistant.endDocumentConversation()
        XCTAssertNil(assistant.documentFollowupContext)
        XCTAssertTrue(assistant.sources.isEmpty)

        try await submit("Explain exercise 3.", to: controller)
        XCTAssertTrue(state.speechBubbleText.localizedCaseInsensitiveContains("Which document do you mean"))
        XCTAssertTrue(state.speechBubbleText.contains("ParserGuide.md"))
        XCTAssertTrue(state.speechBubbleText.contains("ParserAlternative.md"))

        try await submit("Explain exercise 3 in ParserGuide.md.", to: controller)
        let original = try XCTUnwrap(state.knowledge.items.first {
            $0.title == "ParserGuide.md" && $0.sourceKey.hasPrefix("session-file:\(state.activeSessionID):")
        })
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/document-followups/fixtures/ParserGuide.md")
        let session = KnowledgeSession(id: state.activeSessionID, title: "Synthetic parser evaluation")
        _ = try await state.knowledge.saveUploadedDocument(session, url: source,
            text: "ParserGuide replacement. Exercise 3: Replacement tokens are changed.")
        let replacement = try XCTUnwrap(state.knowledge.items.first {
            $0.title == "ParserGuide.md" && $0.sourceKey.hasPrefix("session-file:\(state.activeSessionID):")
        })
        XCTAssertEqual(replacement.id, original.id)
        XCTAssertGreaterThan(replacement.revision, original.revision)
        XCTAssertNil(assistant.documentFollowupContext)
        XCTAssertTrue(assistant.sources.isEmpty)

        try await submit("Explain exercise 3 in ParserGuide.md.", to: controller)
        XCTAssertNotNil(assistant.documentFollowupContext)
        _ = state.createSession(title: "Synthetic second session")
        XCTAssertNil(assistant.documentFollowupContext)
        XCTAssertNil(assistant.lastDocumentQuestion)
        XCTAssertTrue(assistant.sources.isEmpty)
    }

    func testDailyFollowupsKeepHistoryAndSurviveTimerAndThanks() async throws {
        let (state, assistant, controller, provider, _) = try await makeRig()
        try await submit("Explain exercise 2 in ParserGuide.md.", to: controller)
        for message in ["Show me the steps.", "Which rule are you using?", "What mistake should I avoid?", "اشرح الخطوات"] {
            try await submit(message, to: controller)
            XCTAssertEqual(assistant.documentFollowupContext?.exercise, "exercise 2")
            let observations = await provider.snapshot()
            let observation = try XCTUnwrap(observations.last)
            XCTAssertEqual(observation.currentQuestion, message)
            XCTAssertGreaterThan(observation.historyCount, 0)
            XCTAssertLessThanOrEqual(observation.historyCount, 4)
            XCTAssertTrue(observation.historyText.contains("Synthetic grounded answer"))
        }
        let anchor = assistant.documentFollowupContext?.documentID
        try await submit("Thanks", to: controller)
        try await submit("Start a 25-minute timer.", to: controller)
        XCTAssertEqual(state.student.timer?.remaining, 1_500)
        try await submit("How do I start?", to: controller)
        XCTAssertEqual(assistant.documentFollowupContext?.documentID, anchor)
        XCTAssertEqual(state.documentConversation().mode, .active)
    }

    func testFailedAndCancelledSwitchCannotFallBackToOldDocument() async throws {
        let (state, assistant, controller, provider, _) = try await makeRig()
        try await submit("Explain exercise 2 in ParserGuide.md.", to: controller)
        let failure = ScriptedAssistantProvider([.failure(.service)])
        controller.documentCloudProviderFactory = { failure }
        try await submit("Explain exercise 2 in ParserRevision.md.", to: controller)
        let revision = try XCTUnwrap(state.knowledge.items.first { $0.title == "ParserRevision.md" })
        XCTAssertEqual(assistant.documentFollowupContext?.documentID, revision.id)
        XCTAssertEqual(assistant.lastOutcome?.kind, "failed")
        controller.documentCloudProviderFactory = { provider }
        try await submit("Why?", to: controller)
        XCTAssertEqual(assistant.documentFollowupContext?.documentID, revision.id)
        let observations = await provider.snapshot()
        let last = try XCTUnwrap(observations.last)
        XCTAssertFalse(last.suppliedText.contains { $0.contains("ParserGuide revision 1") })

        let delayed = ScriptedAssistantProvider([.delayed(.init(text: "retired invalid output"))])
        controller.documentCloudProviderFactory = { delayed }
        controller.presentation.query = "Explain exercise 2 in ParserAlternative.md."
        controller.submit()
        for _ in 0..<100 {
            if !(await delayed.requests).isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        assistant.cancel()
        try await waitUntilDone(controller)
        let alternative = try XCTUnwrap(state.knowledge.items.first { $0.title == "ParserAlternative.md" })
        XCTAssertEqual(assistant.documentFollowupContext?.documentID, alternative.id)
    }

    func testGeneralDetourRetainsTopicAndClarifiesThenResumes() async throws {
        let (state, assistant, controller, _, _) = try await makeRig()
        try await submit("Explain exercise 2 in ParserGuide.md.", to: controller)
        let general = ScriptedAssistantProvider([.turn(.init(text: "A cactus joke."))])
        controller.coordinator.providerFactory = { general }
        try await submit("Tell me a joke about a cactus.", to: controller)
        XCTAssertEqual(state.speechBubbleText, "A cactus joke.")
        let calls = await general.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertNotNil(assistant.documentFollowupContext)
        XCTAssertEqual(state.documentConversation().mode, .retained)
        try await submit("Why?", to: controller)
        XCTAssertEqual(assistant.lastOutcome?.kind, "needsInput")
        XCTAssertTrue(state.speechBubbleText.contains("ParserGuide.md"))
        try await submit("Continue with ParserGuide.md", to: controller)
        XCTAssertEqual(assistant.lastOutcome?.kind, "answered")
        XCTAssertEqual(state.documentConversation().mode, .active)
        XCTAssertEqual(assistant.documentFollowupContext?.exercise, "exercise 2")
    }

    func testUnfamiliarFollowupUsesExistingAssistantWithSafeTopicMetadata() async throws {
        let (state, assistant, controller, _, _) = try await makeRig()
        try await submit("Explain exercise 2 in ParserGuide.md.", to: controller)
        let general = ScriptedAssistantProvider([
            .turn(try toolTurn(.ask, .init(text: "Can you elaborate on the caveat?"))),
            .turn(.init(text: ""))
        ])
        controller.coordinator.providerFactory = { general }
        try await submit("Can you elaborate on the caveat?", to: controller)
        XCTAssertEqual(assistant.lastOutcome?.kind, "answered")
        XCTAssertEqual(state.speechBubbleText, "Synthetic grounded answer.")
        let requests = await general.requests
        let request = try XCTUnwrap(requests.first)
        let payload = try request.input.map { try $0.jsonString() }.joined()
        XCTAssertTrue(payload.contains("ParserGuide.md"))
        XCTAssertTrue(payload.contains("exercise 2"))
        XCTAssertFalse(payload.contains("Synthetic grounded answer"))
        XCTAssertFalse(payload.contains("DOCUMENT_INSTRUCTION_CANARY_739"))
        XCTAssertTrue(state.student.tasks.isEmpty)
    }

    func testPersistedDiscussionRestoresFreshEvidenceAndForgetClearsIt() async throws {
        let (state, assistant, controller, provider, _) = try await makeRig()
        try await submit("Explain exercise 2 in ParserGuide.md.", to: controller)
        await state.waitForSessionSave()
        let sessions = try await state.knowledge.store.sessions()
        let stored = try XCTUnwrap(sessions.first { $0.id == state.activeSessionID })
        XCTAssertNotNil(stored.documentConversation)
        let restored = PetApplicationState(knowledge: state.knowledge)
        await restored.startKnowledge()
        _ = restored.selectSession(id: state.activeSessionID)
        let next = LocalNotesAssistant(state: restored, client: try OllamaClient())
        XCTAssertTrue(next.sources.isEmpty)
        XCTAssertEqual(next.documentFollowupContext?.documentID, assistant.documentFollowupContext?.documentID)
        let outcome = await next.respond(query: "Show me the steps.", provider: provider)
        XCTAssertEqual(outcome.kind, "answered")
        XCTAssertFalse(next.sources.isEmpty)
        restored.forgetSessionConversations()
        await restored.waitForSessionSave()
        XCTAssertNil(next.documentFollowupContext)
        let saved = try await restored.knowledge.store.sessions()
        let forgotten = try XCTUnwrap(saved.first { $0.id == state.activeSessionID })
        XCTAssertNil(forgotten.documentConversation)
        let legacy = try JSONDecoder().decode(KnowledgeSession.self, from: Data("{\"id\":\"\(UUID().uuidString)\",\"title\":\"Legacy\",\"exchanges\":[]}".utf8))
        XCTAssertNil(legacy.documentConversation)
    }

    func testUnrelatedLibraryChangesDoNotInterruptAndRetiredResponsesCannotPublish() async throws {
        let (state, assistant, controller, provider, snapshots) = try await makeRig()
        try await submit("Explain exercise 2 in ParserGuide.md.", to: controller)
        let response = try AssistantJSON.object(["lines": .array([.object([
            "speechBubbleText": .string("Delayed document answer"), "pet_emotion": .string("happy"),
            "sourceIDs": .array(snapshots.values.last!.sources.map { .string($0.id.uuidString) })])])]).jsonString()
        let slow = ScriptedAssistantProvider([.delayed(.init(text: response))])
        controller.documentCloudProviderFactory = { slow }
        controller.presentation.query = "Why?"; controller.submit()
        for _ in 0..<100 {
            if !(await slow.requests).isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = await state.knowledge.addNote(title: "Unrelated", text: "Not part of the selected document")
        try await waitUntilDone(controller)
        XCTAssertEqual(assistant.lastOutcome?.kind, "answered")
        XCTAssertEqual(state.speechBubbleText, "Delayed document answer")
        controller.documentCloudProviderFactory = { provider }
        let oldEpoch = state.foregroundEpoch
        try await submit("Show me the steps.", to: controller)
        XCTAssertFalse(state.canPublishBackground(since: oldEpoch))
        let id = state.beginForegroundOperation()
        state.canPublishPlannerMessage = { false }
        state.student.say("A background planner message")
        XCTAssertNotEqual(state.speechBubbleText, "A background planner message")
        state.finishForegroundOperation(id)
    }

    func testChangedDocumentRequiresFreshTopicAndNeverPublishesDelayedOldAnswer() async throws {
        let (state, assistant, controller, provider, _) = try await makeRig()
        try await submit("Explain exercise 2 in ParserGuide.md.", to: controller)
        let slow = ScriptedAssistantProvider([.delayed(.init(text: "outdated answer must not appear"))])
        controller.documentCloudProviderFactory = { slow }
        controller.presentation.query = "Why?"; controller.submit()
        for _ in 0..<100 {
            if !(await slow.requests).isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let item = try XCTUnwrap(state.knowledge.items.first { $0.title == "ParserGuide.md" })
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/document-followups/fixtures/ParserGuide.md")
        _ = try await state.knowledge.saveUploadedDocument(try XCTUnwrap(state.sessionSnapshot(id: state.activeSessionID)),
            url: url, text: "Exercise 2: New revision facts only.")
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertNotEqual(state.speechBubbleText, "outdated answer must not appear")
        XCTAssertTrue(assistant.sources.isEmpty)
        XCTAssertNil(assistant.documentFollowupContext)
        controller.documentCloudProviderFactory = { provider }
        try await submit("Why?", to: controller)
        XCTAssertEqual(assistant.lastOutcome?.kind, "needsInput")
        try await submit("Explain exercise 2.", to: controller)
        XCTAssertEqual(assistant.lastOutcome?.kind, "answered")
        XCTAssertEqual(assistant.documentFollowupContext?.documentID, item.id)
        XCTAssertEqual(assistant.documentFollowupContext?.revision, item.revision + 1)
        let observations = await provider.snapshot()
        XCTAssertTrue(observations.last?.suppliedText.contains { $0.contains("New revision facts") } == true)
        XCTAssertFalse(observations.last?.historyText.contains("Synthetic grounded answer") ?? true)
    }

    func testMalformedCloudAnswerRepairsOnceWithoutCommittingInvalidHistory() async throws {
        let (state, assistant, controller, _, snapshots) = try await makeRig()
        try await submit("Explain exercise 2 in ParserGuide.md.", to: controller)
        let ids = snapshots.values.last!.sources.map { AssistantJSON.string($0.id.uuidString) }
        let valid = try AssistantJSON.object(["lines": .array([.object([
            "speechBubbleText": .string("A repaired, cited answer."), "pet_emotion": .string("happy"),
            "sourceIDs": .array(ids)])])]).jsonString()
        let provider = ScriptedAssistantProvider([.turn(.init(text: "invalid JSON")), .turn(.init(text: valid))])
        controller.documentCloudProviderFactory = { provider }
        let previousCount = state.documentConversation().exchanges.count
        try await submit("Why?", to: controller)
        XCTAssertEqual(state.speechBubbleText, "A repaired, cited answer.")
        XCTAssertEqual(assistant.lastOutcome?.kind, "answered")
        XCTAssertEqual(state.documentConversation().exchanges.count, previousCount + 1)
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { !$0.toolsEnabled })
        XCTAssertEqual(requests[0].input, requests[1].input)
        XCTAssertFalse(state.documentConversation().exchanges.contains { $0.companion == "invalid JSON" })
        let malformed = ScriptedAssistantProvider([.turn(.init(text: "invalid")), .turn(.init(text: "invalid"))])
        controller.documentCloudProviderFactory = { malformed }
        let before = state.documentConversation().exchanges
        try await submit("Why?", to: controller)
        let attempts = await malformed.requests
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(assistant.lastOutcome?.kind, "failed")
        XCTAssertEqual(state.documentConversation().exchanges, before)
    }

    func testRepeatedResumesKeepTheOriginalTopicBounded() async throws {
        let (state, assistant, controller, provider, _) = try await makeRig()
        let original = "Explain exercise 2 in ParserGuide.md."
        try await submit(original, to: controller)
        for _ in 0..<5 {
            assistant.retainDocumentConversation(after: "An unrelated question")
            try await submit("Continue with ParserGuide.md", to: controller)
            XCTAssertEqual(assistant.documentFollowupContext?.originalQuestion, original)
            XCTAssertLessThanOrEqual(state.documentConversation().exchanges.count, 4)
        }
        let observations = await provider.snapshot()
        XCTAssertEqual(observations.last?.question, original + "\nFollow-up: Continue with ParserGuide.md")
    }

    private func makeRig() async throws -> (PetApplicationState, LocalNotesAssistant,
        NotesQueryWindowController, EvidenceEchoProvider, SnapshotCapture) {
        let library = KnowledgeLibrary(embeddingProvider: nil)
        await library.load()
        let state = PetApplicationState(knowledge: library)
        let session = KnowledgeSession(id: state.activeSessionID, title: "Synthetic parser evaluation")
        let fixtureDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/document-followups/fixtures", isDirectory: true)
        for name in ["ParserGuide.md", "ParserAlternative.md", "ParserRevision.md"] {
            let source = fixtureDirectory.appendingPathComponent(name)
            _ = try await library.saveUploadedDocument(session, url: source,
                text: String(contentsOf: source, encoding: .utf8))
        }
        var chunks: [DocumentChunk] = []
        for item in library.items where item.sourceKey.hasPrefix("session-file:\(state.activeSessionID):") {
            chunks += try await library.store.documentChunks(itemID: item.id)
        }
        let sessionRecord = try XCTUnwrap(state.sessionFolders[state.activeSessionID])
        try sessionRecord.documentMemory.restore(chunks: chunks)

        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient())
        let defaultsName = "DocumentFollowupRegression-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = AssistantSettings(credentials: MemoryAssistantCredentialStore(key: "synthetic"), defaults: defaults)
        settings.provider = .openAI
        let controller = NotesQueryWindowController(state: state, assistant: assistant, settings: settings)
        let provider = EvidenceEchoProvider()
        controller.documentCloudProviderFactory = { provider }
        state.agent.providerFactory = { nil }
        let snapshots = SnapshotCapture()
        assistant.onPreparedDocumentRequest = { snapshots.values.append($0) }
        return (state, assistant, controller, provider, snapshots)
    }

    private func submit(_ message: String, to controller: NotesQueryWindowController) async throws {
        controller.presentation.query = message
        controller.submit()
        try await waitUntilDone(controller)
    }

    private func waitUntilDone(_ controller: NotesQueryWindowController) async throws {
        for _ in 0..<1_000 where controller.isResponding {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(controller.isResponding, "The routed answer did not finish.")
    }
}
