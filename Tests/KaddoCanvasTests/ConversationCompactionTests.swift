import XCTest
@testable import KaddoCanvas

@MainActor
final class ConversationCompactionTests: XCTestCase {
    func testCompactionKeepsRecentExchangesAndCarriesCoverageForward() async throws {
        let store = await MainActor.run { InMemoryConversationStore() }
        let old = (0..<5).map { ConversationExchange(user: "goal \($0)", companion: "reply \($0)") }
        let recent = (5..<9).map { ConversationExchange(user: "follow-up \($0)", companion: "answer \($0)") }
        await MainActor.run {
            old.forEach(store.append)
            store.compact(summary: "Previous goals.", covering: old.map(\.id))
            recent.forEach(store.append)
        }
        let context = await MainActor.run { CompactedConversationContext(summary: store.summary,
            coveredExchangeIDs: store.coveredExchangeIDs, lastCoveredExchangeID: store.lastCoveredExchangeID,
            exchanges: store.exchanges) }
        XCTAssertEqual(context.summary, "Previous goals.")
        XCTAssertEqual(context.coveredExchangeIDs, old.map(\.id))
        XCTAssertEqual(context.lastCoveredExchangeID, old.last?.id)
        XCTAssertEqual(context.exchanges.map(\.id), recent.map(\.id))
    }

    func testSessionRestoresCompactedContextAndLegacyExchangeWithoutIDDecodes() async throws {
        let db = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: db) }
        let library = KnowledgeLibrary(storageURL: db, embeddingProvider: nil)
        let state = PetApplicationState(knowledge: library)
        await state.startKnowledge()
        let sessionID = state.createSession(title: "Biology")
        let exchange = ConversationExchange(user: "My goal is botany", companion: "Let’s plan that.")
        let context = CompactedConversationContext(summary: "User goal: botany.",
            coveredExchangeIDs: [UUID()], exchanges: [exchange])
        state.saveConversationContext(context, sessionID: sessionID)
        state.recordSessionExchange(.init(user: "What does the uploaded paper say?", companion: "SECRET DOCUMENT ANSWER"), sessionID: sessionID)
        await state.waitForSessionSave()

        let restored = PetApplicationState(knowledge: KnowledgeLibrary(storageURL: db, embeddingProvider: nil))
        await restored.startKnowledge()
        XCTAssertEqual(restored.conversationContext(id: sessionID), context)
        XCTAssertFalse(try JSONEncoder().encode(restored.conversationContext(id: sessionID)).contains(Data("SECRET DOCUMENT ANSWER".utf8)))

        let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000001","title":"Old","exchanges":[{"user":"hi","companion":"hello"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(KnowledgeSession.self, from: legacy)
        XCTAssertNil(decoded.conversationContext)
        XCTAssertEqual(decoded.exchanges.first?.user, "hi")
        XCTAssertNotNil(decoded.exchanges.first?.id)
    }

    func testCompactionUsesToolFreeStructuredSelectedProviderRequest() async throws {
        let provider = ScriptedAssistantProvider([.turn(.init(text: #"{"goals":["Finish biology"],"decisions":[],"corrections":["Exam is Friday"],"unresolved":[],"assistantSuggestions":[]}"#))])
        let exchanges = [ConversationExchange(user: "My goal is biology", companion: "Let’s make a plan.")]
        let summary = try await ConversationCompactionService.compact(previous: "", exchanges: exchanges, provider: provider)
        XCTAssertTrue(summary.contains("Finish biology"))
        XCTAssertTrue(summary.contains("Exam is Friday"))
        let requests = await provider.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertFalse(request.toolsEnabled)
        XCTAssertTrue(request.toolSchemas.isEmpty)
        if case .jsonObject = request.responseFormat { } else { XCTFail("Compaction must request structured JSON.") }
    }

    func testBudgeterDropsOldHistoryAndRejectsOversizedToolContinuation() throws {
        let estimator = CharacterTokenEstimator()
        let budgeter = AssistantRequestBudgeter(contextCapacity: 700, responseReserve: 0, estimator: estimator)
        let history = (0..<8).flatMap { i in [AssistantJSON.message(String(repeating: "u", count: 60) + "\(i)"),
                                                AssistantJSON.message(String(repeating: "a", count: 60) + "\(i)", role: "assistant")] }
        let request = AssistantRequest(instructions: "system", input: history + [
            .message("Current application context (data): {}"), .message("current user message")
        ], toolsEnabled: false)
        let fitted = try budgeter.fit(request)
        XCTAssertEqual(fitted.input.suffix(2), Array(request.input.suffix(2)))
        XCTAssertLessThan(fitted.input.count, request.input.count)
        XCTAssertEqual((request.input.count - fitted.input.count) % 2, 0)

        let continuation = AssistantRequest(instructions: "system", input: [
            .message("context"), .message("current"),
            .object(["type": .string("function_call_output"), "call_id": .string("1"),
                     "output": .string(String(repeating: "x", count: 2_000))])
        ], toolsEnabled: false)
        XCTAssertThrowsError(try budgeter.fit(continuation)) { error in
            XCTAssertEqual(error as? AssistantError, .requestTooLarge)
        }
    }

    func testStaleDebouncedCompactionCannotReplaceNewerSessionContext() async throws {
        let state = PetApplicationState()
        await state.startKnowledge()
        let sessionID = state.activeSessionID
        let exchanges = (0..<9).map { ConversationExchange(user: "turn \($0)", companion: "response \($0)") }
        let original = CompactedConversationContext(exchanges: exchanges)
        state.saveConversationContext(original, sessionID: sessionID)
        let provider = ScriptedAssistantProvider([.turn(.init(text: #"{"goals":[],"decisions":["stale"],"corrections":[],"unresolved":[],"assistantSuggestions":[]}"#))])
        state.scheduleConversationCompaction(sessionID: sessionID, source: original, provider: provider)

        var newer = original
        newer.exchanges.append(.init(user: "new turn", companion: "new answer"))
        state.saveConversationContext(newer, sessionID: sessionID)
        try await Task.sleep(for: .seconds(3.1))
        await state.waitForConversationCompaction(id: sessionID)
        XCTAssertEqual(state.conversationContext(id: sessionID), newer)
        let requests = await provider.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testSuccessfulDebouncedCompactionPersistsSummaryAndRecentTurns() async throws {
        let db = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: db) }
        let state = PetApplicationState(knowledge: KnowledgeLibrary(storageURL: db, embeddingProvider: nil))
        await state.startKnowledge()
        let sessionID = state.createSession(title: "History")
        let exchanges = (0..<9).map { ConversationExchange(user: "goal \($0)", companion: "reply \($0)") }
        let source = CompactedConversationContext(exchanges: exchanges)
        state.saveConversationContext(source, sessionID: sessionID)
        await state.waitForSessionSave()
        let provider = ScriptedAssistantProvider([.turn(.init(text: #"{"goals":["Keep the botany goal"],"decisions":[],"corrections":[],"unresolved":[],"assistantSuggestions":[]}"#))])
        state.scheduleConversationCompaction(sessionID: sessionID, source: source, provider: provider)
        try await Task.sleep(for: .seconds(3.1))
        await state.waitForConversationCompaction(id: sessionID)
        await state.waitForSessionSave()

        let compacted = try XCTUnwrap(state.conversationContext(id: sessionID))
        XCTAssertEqual(compacted.exchanges.map(\.id), exchanges.suffix(4).map(\.id))
        XCTAssertEqual(compacted.coveredExchangeIDs, exchanges.prefix(5).map(\.id))
        XCTAssertEqual(compacted.lastCoveredExchangeID, exchanges[4].id)
        XCTAssertTrue(compacted.summary.contains("Keep the botany goal"))

        let restored = PetApplicationState(knowledge: KnowledgeLibrary(storageURL: db, embeddingProvider: nil))
        await restored.startKnowledge()
        XCTAssertEqual(restored.conversationContext(id: sessionID), compacted)
    }
}

private struct CharacterTokenEstimator: AssistantTokenEstimating {
    func estimatedTokens(for text: String) -> Int { text.utf8.count }
}
