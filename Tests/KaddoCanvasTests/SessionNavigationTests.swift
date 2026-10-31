import AppKit
import XCTest
@testable import KaddoCanvas

@MainActor
final class SessionNavigationTests: XCTestCase {
    private func coordinator(_ state: PetApplicationState) -> AssistantCoordinator {
        let value = AssistantCoordinator(state: state)
        value.understandsFreeform = { true }
        value.providerFactory = { XCTFail("Session navigation must never need an AI provider"); throw AssistantError.service }
        value.onReply = { state.speechBubbleText = $0.text }
        return value
    }
    func testCommonRequestsAreLocalAndNegationsAreNotCommands() {
        let state = PetApplicationState()
        for question in ["change sessions", "switch session", "please switch to another session", "show my sessions", "list sessions", "/sessions"] {
            XCTAssertEqual(NaturalActionRouter.command(for: question, state: state), "/select_session", question)
        }
        for question in ["switch to session Biology", "change session to Biology", "open session Biology", "go to Biology session"] {
            XCTAssertEqual(NaturalActionRouter.command(for: question, state: state), "/select_session Biology", question)
        }
        for question in ["don't change sessions", "how do I change sessions?", "the document says switch sessions", "\"switch sessions\""] {
            XCTAssertNil(SessionNavigation.command(question), question)
        }
    }
    func testBareRequestClarifiesAndNumberSelectsWithoutProvider() {
        let state = PetApplicationState()
        let biology = state.createSession(title: "Biology")
        state.createSession(title: "Physics")
        let current = state.activeSessionID
        let c = coordinator(state)
        XCTAssertTrue(c.respondLocally(to: "change sessions"))
        XCTAssertEqual(state.activeSessionID, current)
        XCTAssertTrue(state.speechBubbleText.contains("Which session"))
        XCTAssertTrue(state.speechBubbleText.contains("Biology"))
        XCTAssertTrue(c.respondLocally(to: "1"))
        XCTAssertEqual(state.activeSessionID, biology)
        XCTAssertEqual(state.speechBubbleText, "Switched to Biology.")
        XCTAssertNil(c.pendingClarification)
    }
    func testNamesUUIDsAndSessionNumbersSelectExistingOnly() {
        let state = PetApplicationState()
        let biology = state.createSession(title: "Biology")
        let numbered = state.createSession(title: "Session 2")
        let c = coordinator(state)
        XCTAssertTrue(c.respondLocally(to: "open session biology"))
        XCTAssertEqual(state.activeSessionID, biology)
        XCTAssertTrue(c.respondLocally(to: "switch to session 2"))
        XCTAssertEqual(state.activeSessionID, numbered)
        XCTAssertTrue(c.respondLocally(to: "/select_session \(biology)"))
        XCTAssertEqual(state.activeSessionID, biology)
        let count = state.sessionFolders.count
        XCTAssertTrue(c.respondLocally(to: "switch session Missing"))
        XCTAssertEqual(state.sessionFolders.count, count)
        XCTAssertEqual(state.activeSessionID, biology)
        XCTAssertTrue(state.speechBubbleText.contains("couldn’t find"))
    }
    func testDuplicateNamesNeedNumberAndCancellationKeepsCurrentSession() {
        let state = PetApplicationState()
        state.createSession(title: "Biology"); state.createSession(title: "Biology")
        let original = state.activeSessionID
        let c = coordinator(state)
        XCTAssertTrue(c.respondLocally(to: "switch session Biology"))
        XCTAssertEqual(state.activeSessionID, original)
        XCTAssertTrue(state.speechBubbleText.contains("More than one"))
        XCTAssertTrue(c.respondLocally(to: "99"))
        XCTAssertEqual(state.activeSessionID, original)
        XCTAssertTrue(c.respondLocally(to: "cancel"))
        XCTAssertNil(c.pendingClarification)
        XCTAssertEqual(state.activeSessionID, original)
    }
    func testChoiceIDsDoNotShiftWhenAnotherSessionIsCreated() {
        let state = PetApplicationState()
        let biology = state.createSession(title: "Biology")
        let c = coordinator(state)
        XCTAssertTrue(c.respondLocally(to: "change sessions"))
        state.createSession(title: "AAA New")
        XCTAssertTrue(c.respondLocally(to: "1"))
        XCTAssertEqual(state.activeSessionID, biology)
    }
    func testToolAcceptsExactTitleWhileInvalidUUIDStaysInvalid() throws {
        let state = PetApplicationState()
        let biology = state.createSession(title: "Biology")
        state.createSession(title: "Physics")
        let call = try KaddoToolCall(id: "test", name: "select_session", arguments: .object(["title": .string("Biology")]))
        XCTAssertEqual(KaddoToolExecutor(state: state).execute(call).status, .success)
        XCTAssertEqual(state.activeSessionID, biology)
        XCTAssertThrowsError(try KaddoToolCall(id: "bad", name: "select_session", arguments: .object(["id": .string("Biology")])))
    }
    func testNativeComposerSwitchBypassesPendingDocumentClarification() async throws {
        _ = NSApplication.shared
        let state = PetApplicationState(); await state.startKnowledge()
        let first = state.activeSessionID
        let other = state.createSession(title: "Biology")
        state.selectSession(id: first)
        let session = try XCTUnwrap(state.sessionSnapshot(id: first))
        var record = try await state.knowledge.saveUploadedDocument(session,
            url: URL(fileURLWithPath: "/tmp/synthetic-session-navigation.txt"), text: "Complete Lab 1")
        record.analysis = .init(category: "Study", entries: [.init(kind: .assignment, title: "Lab 1", evidence: "Complete Lab 1", question: "What is the full due date?", id: UUID())])
        try await state.knowledge.store.saveIngestion(record)
        await state.ingestion.accept(record)
        let pending = state.ingestion.pendingQuestion
        XCTAssertNotNil(pending)
        state.agent.providerFactory = { XCTFail("Navigation must not submit a due-date clarification to AI"); throw AssistantError.service }
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost); defer { http.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let controller = NotesQueryWindowController(state: state, assistant: assistant, settings: AssistantSettings())
        defer { controller.close() }
        controller.coordinator.providerFactory = { XCTFail("No model needed"); throw AssistantError.service }
        controller.presentation.query = "change sessions"; controller.submit()
        XCTAssertTrue(state.speechBubbleText.contains("Which session"))
        controller.presentation.query = "Biology"; controller.submit()
        XCTAssertEqual(state.activeSessionID, other)
        XCTAssertEqual(state.speechBubbleText, "Switched to Biology.")
        XCTAssertEqual(state.ingestion.pendingQuestion, pending)
        XCTAssertTrue(state.student.tasks.isEmpty)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertFalse(controller.isResponding)
    }
}
