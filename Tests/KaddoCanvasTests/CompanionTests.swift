import AppKit
import XCTest
@testable import KaddoCanvas

final class CompanionTests: XCTestCase {
    @MainActor
    private func controller(_ http: Phase4HTTPHarness) throws -> (PetApplicationState, NotesQueryWindowController) {
        _ = NSApplication.shared
        let state = PetApplicationState()
        let notes = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        return (state, NotesQueryWindowController(state: state, assistant: notes, settings: AssistantSettings()))
    }
    @MainActor
    private func send(_ text: String, _ controller: NotesQueryWindowController) {
        controller.presentation.query = text; controller.submit()
        XCTAssertEqual(controller.presentation.query, "")
    }
    @MainActor
    private func finish(_ controller: NotesQueryWindowController) async throws {
        try await Task.sleep(for: .milliseconds(20))
        for _ in 0..<150 {
            if !controller.isResponding { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Response did not finish")
    }

    @MainActor
    func testOfflineGreetingsAndEmotionsPreservePlanningQuestion() throws {
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost); defer { http.cleanUp() }
        let (state, c) = try controller(http); defer { c.close() }
        send("/new Exact Title", c)
        let question = state.student.pendingPrompt
        for text in ["hello", "thanks", "how are you?", "bye"] {
            send(text, c); XCTAssertEqual(state.currentEmotion, .happy)
            XCTAssertEqual(state.student.pendingPrompt, question)
        }
        send("I'm tired", c); XCTAssertEqual(state.currentEmotion, .idle)
        send("I did it!", c); XCTAssertEqual(state.currentEmotion, .celebrating)
        XCTAssertTrue(state.student.tasks.isEmpty)
        XCTAssertTrue(http.requests.isEmpty)
    }

    @MainActor
    func testPlainActionsRunThroughExistingPlannerOffline() throws {
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost); defer { http.cleanUp() }
        let (state, c) = try controller(http); defer { c.close() }
        send("start a 25-minute timer", c)
        XCTAssertEqual(state.student.timer?.remaining, 1500)
        send("pause it", c); XCTAssertEqual(state.student.timer?.status, .paused)
        send("make that 30 minutes", c)
        XCTAssertEqual(state.student.timer?.remaining, 1800)
        XCTAssertEqual(state.student.timer?.status, .paused)
        send("resume the countdown", c); XCTAssertEqual(state.student.timer?.status, .running)
        send("stop it", c); XCTAssertNil(state.student.timer)
        send("take a 5 minute break", c); XCTAssertEqual(state.currentEmotion, .sleeping)
        send("stop it", c)
        send("add a task Summarize Document ABC", c)
        XCTAssertEqual(state.student.tasks.first?.title, "Summarize Document ABC")
        send("add a note Ask Zoë About Tuesday", c)
        XCTAssertEqual(state.student.notes.first?.text, "Ask Zoë About Tuesday")
        send("create a session called Chemistry II", c)
        XCTAssertEqual(state.sessionFolders[state.activeSessionID]?.title, "Chemistry II")
        send("remind me in 10 minutes to Pack My Lab Book", c)
        XCTAssertEqual(state.student.reminders.first?.title, "Pack My Lab Book")
        send("add an exam Calculus II due tomorrow", c)
        XCTAssertEqual(state.student.tasks.last?.kind, "exam")
        send("add a class Mon 09:00 Chemistry II", c)
        XCTAssertEqual(state.student.classes.first?.time, "09:00")
        send("create a flashcard What is mitosis? | Cell division", c)
        XCTAssertEqual(state.student.cards.first?.question, "What is mitosis?")
        send("turn sounds off", c); XCTAssertFalse(state.student.soundsEnabled)
        send("mark task 1 done", c); XCTAssertTrue(state.student.tasks[0].completed)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertFalse(state.speechBubbleText.contains("please use /"))
    }

    @MainActor
    func testMissingDetailsClarifyAndForgetClearsClarification() throws {
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost); defer { http.cleanUp() }
        let (state, c) = try controller(http); defer { c.close() }
        send("save a note", c)
        XCTAssertTrue(state.speechBubbleText.contains("What would you like"))
        XCTAssertTrue(state.student.notes.isEmpty)
        send("Bring the lab book", c)
        XCTAssertEqual(state.student.notes.first?.text, "Bring the lab book")
        send("save a note", c); send("/forget", c)
        XCTAssertTrue(c.coordinator.conversation.exchanges.isEmpty)
        XCTAssertFalse(c.coordinator.respondLocally(to: "Unrelated thought"))
        XCTAssertEqual(state.student.notes.count, 1)
    }

    @MainActor
    func testMentionsNegationsQuotedAndCompoundRequestsNeverRunOffline() {
        let state = PetApplicationState()
        for text in ["how do timers work?", "don't start a timer", "do not add a task", "if I start a timer, what happens?",
                     "\"start a 25-minute timer\"", "start a timer tomorrow", "start a 5-minute timer for 25 minutes", "start a timer and add a task",
                     "show me an example of a note", "I need a break from everything", "Why do people use timers?",
                     "ابدأ مؤقتًا لمدة ٢٥ دقيقة", "لا تبدأ مؤقتًا"] {
            XCTAssertNil(NaturalActionRouter.command(for: text, state: state), text)
            XCTAssertNil(state.student.timer)
            XCTAssertTrue(state.student.tasks.isEmpty)
        }
    }

    @MainActor
    func testProfileQuestionDoesNotCaptureChatAndNewActionTakesPrecedence() throws {
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost); defer { http.cleanUp() }
        let (state, c) = try controller(http); defer { c.close() }
        send("/profile edit name", c)
        send("hello", c)
        XCTAssertNil(state.student.profile?.name)
        XCTAssertEqual(state.student.pendingProfileField, .name)
        send("My name is Zoë 🔥", c)
        XCTAssertEqual(state.student.profile?.name, "Zoë 🔥")
        send("/profile edit birthday", c)
        send("start a 25-minute timer", c)
        XCTAssertNil(state.student.pendingProfileField)
        XCTAssertEqual(state.student.timer?.remaining, 1500)
        XCTAssertNil(state.student.profile?.birthday)
    }

    @MainActor
    func testMemoryRetainsBoundedSourceExchangesForCompaction() {
        let store = InMemoryConversationStore()
        for n in 0..<12 { store.append(.init(user: "user \(n)", companion: "reply")) }
        XCTAssertEqual(store.exchanges.count, 12); XCTAssertTrue(store.needsCompaction)
        let older = Array(store.exchanges.prefix(8))
        store.compact(summary: "Older turns summarized.", covering: older.map(\.id))
        XCTAssertEqual(store.exchanges.count, 4); XCTAssertEqual(store.exchanges.first?.user, "user 8")
        XCTAssertEqual(store.coveredExchangeIDs, older.map(\.id))
        store.clear()
        for _ in 0..<5 { store.append(.init(user: String(repeating: "👩🏽‍💻", count: 3000), companion: String(repeating: "a", count: 3000))) }
        XCTAssertEqual(store.exchanges.count, 5)
        XCTAssertEqual(store.exchanges.reduce(0) { $0 + $1.characterCount }, 30000)
        store.append(.init(user: String(repeating: "x", count: 24001), companion: "a"))
        XCTAssertLessThanOrEqual(store.exchanges.reduce(0) { $0 + $1.characterCount }, 48000)
        XCTAssertEqual(store.exchanges.last?.user.count, 24001)
    }

    @MainActor
    func testOllamaGeneralChatDoesNotAutomaticallyExposeDocumentsOrPlanner() async throws {
        let response = #"{"text":"Here is an explanation.\n\n2 / 3 is a fraction.","tool":null}"#
        let http = Phase4HTTPHarness(json: try inferenceRecord(response, done: true)); defer { http.cleanUp() }
        let (state, c) = try controller(http); defer { c.close() }
        try await state.documentMemory.importDocument(at: documentFixture("Research.pdf"))
        state.student.handle("/task Planner Secret"); send("hello", c)
        c.presentation.modelName = "local:test"
        send("Explain fractions", c); try await finish(c)
        XCTAssertEqual(state.speechBubbleText, "Here is an explanation.\n\n2 / 3 is a fraction.")
        XCTAssertEqual(c.coordinator.conversation.exchanges.map(\.user), ["hello", "Explain fractions"])
        let request = try XCTUnwrap(http.requests.first { $0.url?.path == "/api/generate" })
        let body = try JSONDecoder().decode(AssistantJSON.self, from: request.body)
        let prompt = try XCTUnwrap(body["prompt"]?.string)
        XCTAssertTrue(prompt.contains("Explain fractions")); XCTAssertFalse(prompt.contains("Planner Secret"))
        XCTAssertFalse(prompt.contains("orchid")); XCTAssertTrue(c.presentation.sources.isEmpty)
    }

    @MainActor
    func testDocumentShortcutsAndSummaryKeepCitationsOutOfMemory() async throws {
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("Research.pdf"))
        let source = try XCTUnwrap(state.documentMemory.chunks.first)
        let line = try speechObject("Water weekly.", emotion: "celebrating", ids: [source.id])
        let http = Phase4HTTPHarness(json: try inferenceRecord("{\"lines\":[\(line)]}", done: true)); defer { http.cleanUp() }
        let notes = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let c = NotesQueryWindowController(state: state, assistant: notes, settings: AssistantSettings()); defer { c.close() }
        c.presentation.modelName = "local:test"
        for text in ["summarize my document", "/ask orchid"] {
            send(text, c); try await finish(c)
            XCTAssertEqual(state.speechBubbleText, "Water weekly.")
            XCTAssertEqual(c.presentation.sources, [source])
            XCTAssertTrue(c.coordinator.conversation.exchanges.isEmpty)
        }
        send("hello", c); XCTAssertTrue(c.presentation.sources.isEmpty)
    }

    @MainActor
    func testInterruptionsCancelStaleGenerationAndKeepNewerOutput() async throws {
        for interrupt in ["hello", "/task Newer Output", "/forget", "/plan", "alert", "session", "hide"] {
            let http = Phase4HTTPHarness(json: "", holdOpen: true); defer { http.cleanUp() }
            let (state, c) = try controller(http); defer { c.close() }
            c.presentation.modelName = "local:test"
            send("Tell me something fun", c)
            for _ in 0..<200 {
                if c.coordinator.isAnswering { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(c.coordinator.isAnswering)
            switch interrupt {
            case "alert": state.student.say("30 seconds remaining")
            case "session": state.createSession(title: "Other")
            case "hide": c.hide()
            default: send(interrupt, c)
            }
            let output = state.speechBubbleText
            try await Task.sleep(for: .milliseconds(30))
            if interrupt == "alert" {
                XCTAssertTrue(c.coordinator.isAnswering, "Background alerts must not cancel a foreground answer")
            } else { XCTAssertFalse(c.coordinator.isAnswering) }
            XCTAssertEqual(state.speechBubbleText, output)
            if interrupt == "alert" { send("/forget", c) }
            XCTAssertTrue(c.presentation.sources.isEmpty)
        }
    }

    @MainActor
    func testUnavailableModelAndInputLimitsLeaveToolsWorking() async throws {
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost); defer { http.cleanUp() }
        let (state, c) = try controller(http); defer { c.close() }
        send("Tell me something fun", c); try await finish(c)
        XCTAssertTrue(state.speechBubbleText.contains("local Ollama model"))
        XCTAssertTrue(c.coordinator.conversation.exchanges.isEmpty)
        send(String(repeating: "x", count: 2001), c)
        XCTAssertTrue(state.speechBubbleText.contains("2,000"))
        send("/timer 25", c); XCTAssertEqual(state.student.timer?.remaining, 1500)
        XCTAssertTrue(http.requests.isEmpty)
    }
}
