import XCTest
@testable import KaddoCanvas

final class SessionKnowledgeTests: XCTestCase {
    private func temporary() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @MainActor func testUploadsAndConversationSurviveRestartWithoutOriginalFile() async throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Research.md")
        try Data("Orchids need bright indirect light.".utf8).write(to: file)
        let database = folder.appendingPathComponent("knowledge.sqlite")
        let library = KnowledgeLibrary(storageURL: database, embeddingProvider: nil)
        let state = PetApplicationState(knowledge: library)
        await state.startKnowledge()
        let id = state.createSession(title: "Botany")
        try await state.documentMemory.importDocument(at: file)
        state.recordSessionExchange(.init(user: "I will measure light daily", companion: "Use a daily log."), sessionID: id)
        await state.waitForSessionSave()
        try FileManager.default.removeItem(at: file)

        let reloadedLibrary = KnowledgeLibrary(storageURL: database, embeddingProvider: nil)
        let restored = PetApplicationState(knowledge: reloadedLibrary)
        await restored.startKnowledge()
        XCTAssertTrue(restored.selectSession(id: id))
        XCTAssertTrue(restored.fetchContextForActiveSession(query: "orchids").contains("indirect light"))
        XCTAssertEqual(restored.sessionSnapshot(id: id)?.exchanges.count, 1)
        XCTAssertEqual(reloadedLibrary.items.filter { $0.sourceKind == "session-document" }.count, 1)
        restored.createSession(title: "Empty")
        XCTAssertEqual(restored.fetchContextForActiveSession(query: "orchids"), "")
    }

    @MainActor func testRepeatUploadsReplaceWithinSessionAndPreserveOtherSession() async throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Notes.txt")
        try Data("Orchid first version".utf8).write(to: file)
        let state = PetApplicationState()
        await state.startKnowledge()
        let first = state.activeSessionID
        try await state.documentMemory.importDocument(at: file)
        let itemID = try XCTUnwrap(state.knowledge.items.first?.id)
        try Data("Orchid updated version".utf8).write(to: file)
        try await state.documentMemory.importDocument(at: file)
        XCTAssertEqual(state.knowledge.items.count, 1)
        XCTAssertEqual(state.knowledge.items.first?.id, itemID)
        XCTAssertEqual(state.documentMemory.fileURLs.count, 1)
        XCTAssertFalse(state.fetchContextForActiveSession(query: "orchid").contains("first version"))
        state.createSession(title: "Second")
        try await state.documentMemory.importDocument(at: file)
        XCTAssertEqual(state.knowledge.items.count, 2)
        state.selectSession(id: first)
        await state.clearSessionDocuments()
        XCTAssertEqual(state.knowledge.items.count, 1)
        XCTAssertFalse(state.knowledge.items[0].sourceKey.contains(first.uuidString))
    }

    @MainActor func testAutomaticFilingAndGeneralSummaryRetainSessionOwnership() async throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Biology.txt")
        try Data("Orchid observations for biology class".utf8).write(to: file)
        let state = PetApplicationState()
        await state.startKnowledge()
        let provider = ScriptedAssistantProvider([
            .turn(.init(text: "{\"category\":\"Study\",\"entries\":[]}")),
            .turn(.init(text: "The user is studying orchid biology."))
        ])
        state.agent.providerFactory = { provider }
        let id = state.activeSessionID
        try await state.documentMemory.importDocument(at: file)
        await state.waitForSessionAutomation(id: id)
        XCTAssertEqual(state.knowledge.items.first { $0.sourceKind == "session-document" }?.categoryID, KnowledgeCategory.study.id)
        let summary = try XCTUnwrap(state.knowledge.items.first { $0.sourceKind == "session-summary" })
        XCTAssertEqual(summary.categoryID, KnowledgeCategory.general.id)
        XCTAssertTrue(summary.text.contains(id.uuidString))
        XCTAssertTrue(state.fetchContextForActiveSession(query: "orchid").contains("observations"))
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { !$0.toolsEnabled })
        let matches = await state.knowledge.search(query: "orchid", categoryID: KnowledgeCategory.general.id)
        XCTAssertFalse(matches.isEmpty)
    }

    @MainActor func testSummaryReplacesPreviousAndRejectsStaleResponse() async throws {
        let state = PetApplicationState()
        await state.startKnowledge()
        let id = state.activeSessionID
        state.recordSessionExchange(.init(user: "My goal is botany", companion: "Study orchids"), sessionID: id)
        let provider = ScriptedAssistantProvider([.turn(.init(text: "Botany goal")), .turn(.init(text: "Updated botany goal"))])
        let saved = try await state.summarizeSession(id: id, provider: provider)
        XCTAssertTrue(saved)
        let summaryID = state.knowledge.items.first?.id
        _ = try await state.summarizeSession(id: id, provider: provider)
        XCTAssertEqual(state.knowledge.items.count, 1)
        XCTAssertEqual(state.knowledge.items.first?.id, summaryID)
        let delayed = ScriptedAssistantProvider([.delayed(.init(text: "Stale summary"))])
        let task = Task { try await state.summarizeSession(id: id, provider: delayed) }
        while await delayed.requests.isEmpty { await Task.yield() }
        state.recordSessionExchange(.init(user: "New decision", companion: "New response"), sessionID: id)
        do { _ = try await task.value; XCTFail("Stale summary saved") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(state.knowledge.items[0].text.contains("Stale summary"))
    }

    @MainActor func testSummaryRejectsActionCallsAndForgetClearsRetainedTranscript() async throws {
        let state = PetApplicationState()
        await state.startKnowledge()
        let id = state.activeSessionID
        state.recordSessionExchange(.init(user: "Botany goal", companion: "Study orchids"), sessionID: id)
        let provider = ScriptedAssistantProvider([.turn(try toolTurn(.task, .init(text: "Injected")))])
        do { _ = try await state.summarizeSession(id: id, provider: provider); XCTFail("Tool accepted") }
        catch { XCTAssertEqual(error as? AssistantError, .invalidResponse) }
        XCTAssertTrue(state.student.tasks.isEmpty)
        XCTAssertTrue(state.knowledge.items.isEmpty)
        AssistantCoordinator(state: state).forget()
        await state.waitForSessionSave()
        XCTAssertEqual(state.sessionSnapshot(id: id)?.exchanges, [])
        let saved = try await state.knowledge.store.sessions()
        XCTAssertEqual(saved.first { $0.id == id }?.exchanges, [])
    }

    @MainActor func testOrganizationToolMovesWithoutLosingOwnershipAndSummaryToolSaves() async throws {
        let state = PetApplicationState()
        await state.startKnowledge()
        let id = state.activeSessionID
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        let file = try XCTUnwrap(state.knowledge.items.first)
        let provider = ScriptedAssistantProvider([
            .turn(try toolTurn(.organize_knowledge, .init(id: file.id, category: "Botany"))),
            .turn(try toolTurn(.summarize_session, .init(id: id))),
            .turn(.init(text: "Orchid study notes")),
            .turn(.init(text: "Organized and summarized."))
        ])
        let coordinator = AssistantCoordinator(state: state)
        coordinator.providerFactory = { provider }
        await coordinator.answer("Organize and summarize this session")
        let category = try XCTUnwrap(state.knowledge.categories.first { $0.name == "Botany" })
        XCTAssertEqual(state.knowledge.items.first { $0.id == file.id }?.categoryID, category.id)
        XCTAssertTrue(state.knowledge.items.contains { $0.sourceKind == "session-summary" })
        XCTAssertFalse(state.fetchContextForActiveSession(query: "orchid").isEmpty)
        let requests = await provider.requests
        XCTAssertFalse(requests[2].toolsEnabled)
        XCTAssertFalse(try requests[3].input.map { try $0.jsonString() }.joined().contains("Orchid study notes"))
    }
}
