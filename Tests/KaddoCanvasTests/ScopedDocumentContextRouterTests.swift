import Combine
import XCTest
@testable import KaddoCanvas

final class ScopedDocumentContextRouterTests: XCTestCase {
    @MainActor
    func testOnlySelectedRecordURLsAreSearchedAndEmptySessionsNeverFallBack() async throws {
        let state = PetApplicationState()
        let firstID = state.activeSessionID
        try await state.documentMemory.importDocument(at: documentFixture("Research.pdf"))
        let secondID = state.createSession(title: "Focus")
        XCTAssertEqual(state.fetchContextForActiveSession(query: "orchid"), "")
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))

        let router = ScopedDocumentContextRouter(state: state)
        XCTAssertEqual(router.fetchContextForActiveSession(query: "cactus"), "")
        XCTAssertTrue(router.fetchContextForActiveSession(query: "orchid").contains("25-minute"))
        XCTAssertFalse(router.fetchContextForActiveSession(query: "orchid").contains("seven days"))
        XCTAssertEqual(state.sessionFolders[secondID]?.files,
                       [documentFixture("FocusNotes.docx").standardizedFileURL])

        XCTAssertTrue(state.selectSession(id: firstID))
        XCTAssertTrue(router.fetchContextForActiveSession(query: "cactus").contains("dry soil"))
        XCTAssertFalse(router.fetchContextForActiveSession(query: "orchid").contains("25-minute"))
        XCTAssertTrue(state.selectSession(id: secondID))
        state.documentMemory.clear()
        XCTAssertEqual(state.sessionFolders[secondID]?.files, [])
        XCTAssertEqual(router.fetchContextForActiveSession(query: "orchid"), "")
    }

    @MainActor
    func testRankedTopFiveParagraphsAndInvalidOrUnmatchedQueries() async throws {
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("LongNotes.docx"))
        let router = ScopedDocumentContextRouter(state: state)
        let context = router.fetchContextForActiveSession(query: "orchid paragraph 07")
        XCTAssertTrue(context.contains("Paragraph 07:"))
        XCTAssertLessThanOrEqual(context.count, 6_000)
        XCTAssertTrue(state.documentMemory.chunks.contains {
            $0.text.components(separatedBy: "Paragraph").count > 2
        }, "Small related paragraphs should share a coherent retrieval block")
        for query in ["", " \n", "?!", "nonexistent", String(repeating: "x", count: 2_001)] {
            XCTAssertEqual(router.fetchContextForActiveSession(query: query), "")
        }
    }

    @MainActor
    func testIdenticalFilenamesAndIdenticalURLsDoNotShareSessionMemory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first/Notes.docx")
        let secondURL = directory.appendingPathComponent("second/Notes.docx")
        for (source, destination) in [("FocusNotes.docx", firstURL), ("LongNotes.docx", secondURL)] {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: documentFixture(source), to: destination)
        }
        let state = PetApplicationState()
        let firstID = state.activeSessionID
        try await state.documentMemory.importDocument(at: firstURL)
        state.createSession(title: "Second")
        try await state.documentMemory.importDocument(at: secondURL)
        XCTAssertTrue(state.fetchContextForActiveSession(query: "measure").contains("Measure light"))
        state.selectSession(id: firstID)
        XCTAssertEqual(state.fetchContextForActiveSession(query: "measure"), "")

        state.createSession(title: "Same URL")
        try await state.documentMemory.importDocument(at: firstURL)
        let source = try XCTUnwrap(state.documentMemory.chunks.first)
        state.documentMemory.removeDocument(id: source.documentID)
        XCTAssertTrue(state.documentMemory.fileURLs.isEmpty)
        XCTAssertEqual(state.fetchContextForActiveSession(query: "focus"), "")
        state.selectSession(id: firstID)
        XCTAssertFalse(state.fetchContextForActiveSession(query: "focus").isEmpty)
    }

    @MainActor
    func testImportFinishesInItsOriginalSessionAfterSelectionChanges() async throws {
        let state = PetApplicationState()
        let originalID = state.activeSessionID
        let destination = state.documentMemory
        let pending = Task { try await destination.importDocument(at: documentFixture("LongNotes.docx")) }
        for _ in 0..<1_000 {
            if destination.isImporting { break }
            await Task.yield()
        }
        XCTAssertTrue(destination.isImporting)
        state.createSession(title: "Other")
        _ = try await pending.value
        XCTAssertEqual(state.fetchContextForActiveSession(query: "orchid"), "")
        XCTAssertTrue(state.documentMemory.chunks.isEmpty)
        state.selectSession(id: originalID)
        XCTAssertFalse(state.fetchContextForActiveSession(query: "orchid").isEmpty)
    }

    @MainActor
    func testFailedImportsLeaveNoFileReferences() async throws {
        let state = PetApplicationState()
        do {
            try await state.documentMemory.importDocument(at: documentFixture("Corrupt.docx"))
            XCTFail("Corrupt document imported")
        } catch { XCTAssertEqual(error as? DocumentImportError, .invalidDocument) }
        XCTAssertEqual(state.sessionFolders[state.activeSessionID]?.files, [])
        XCTAssertEqual(state.fetchContextForActiveSession(query: "orchid"), "")
    }

    @MainActor
    func testInferencePromptContainsOnlyActiveSessionParagraphs() async throws {
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        state.createSession(title: "Research")
        try await state.documentMemory.importDocument(at: documentFixture("LongNotes.docx"))
        let http = Phase4HTTPHarness(json: try inferenceRecord(
            "{\"lines\":[\(try speechObject("Measured daily."))]}", done: true))
        defer { http.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        await assistant.answer(query: "orchid")
        let request = try XCTUnwrap(http.requests.first { $0.url?.path == "/api/generate" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let prompt = try XCTUnwrap(body["prompt"] as? String)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: Any])
        let notes = try XCTUnwrap(input["referenceNotes"] as? [[String: Any]])
        XCTAssertGreaterThan(notes.count, 0)
        XCTAssertLessThanOrEqual(notes.count, 48)
        XCTAssertTrue(notes.allSatisfy { $0["filename"] as? String == "LongNotes.docx" })
        XCTAssertFalse(prompt.contains("25-minute"))
        XCTAssertEqual(state.speechBubbleText, "Measured daily.")
    }

    @MainActor
    func testSelectionCancelsStreamingAndClearsCitationsWithoutLateOverwrite() async throws {
        let state = PetApplicationState()
        let firstID = state.activeSessionID
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        let originalMemory = state.documentMemory
        let source = try XCTUnwrap(originalMemory.chunks.first { $0.text.contains("focus") })
        let line = try speechObject("Old session answer", ids: [source.id])
        let http = Phase4HTTPHarness(json: try inferenceRecord("{\"lines\":[\(line)") + "\n",
                                     holdOpen: true)
        defer { http.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let published = expectation(description: "Old session is streaming")
        let token = state.$speechBubbleText.sink { if $0 == "Old session answer" { published.fulfill() } }
        let answer = Task { await assistant.answer(query: "focus") }
        await fulfillment(of: [published], timeout: 3)
        XCTAssertEqual(assistant.sources, [source])
        state.createSession(title: "Empty")
        await answer.value
        XCTAssertFalse(assistant.isAnswering)
        XCTAssertTrue(assistant.sources.isEmpty)
        XCTAssertEqual(state.speechBubbleText, "Session changed. Ask a new question.")
        originalMemory.clear()
        XCTAssertEqual(state.speechBubbleText, "Session changed. Ask a new question.")
        let requests = http.requests.count
        await assistant.answer(query: "focus")
        XCTAssertEqual(http.requests.count, requests, "Empty session must not send another session's notes")
        XCTAssertEqual(state.speechBubbleText, LocalInferenceError.noRelevantContext.localizedDescription)
        state.selectSession(id: firstID)
        try await state.documentMemory.importDocument(at: documentFixture("Research.pdf"))
        XCTAssertTrue(state.speechBubbleText.contains("Research.pdf is saved. Organization is pending:"))
        withExtendedLifetime(token) {}
    }
}
