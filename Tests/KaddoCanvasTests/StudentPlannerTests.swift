import AppKit
import XCTest
@testable import KaddoCanvas

final class StudentPlannerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testTimerAllCheckpointsAreDeliveredExactlyOnce() {
        var timer = StudyTimer(title: "Essay", seconds: 1500, now: start)
        XCTAssertNil(timer.advance(to: start.addingTimeInterval(749)))
        XCTAssertTrue(timer.advance(to: start.addingTimeInterval(750))?.contains("Halfway") == true)
        XCTAssertNil(timer.advance(to: start.addingTimeInterval(751)))
        XCTAssertTrue(timer.advance(to: start.addingTimeInterval(1200))?.contains("5 minutes") == true)
        XCTAssertTrue(timer.advance(to: start.addingTimeInterval(1470))?.contains("30 seconds") == true)
        XCTAssertTrue(timer.advance(to: start.addingTimeInterval(1500))?.contains("Time’s up") == true)
        XCTAssertEqual(timer.status, .completed)
        XCTAssertNil(timer.advance(to: start.addingTimeInterval(1600)))
    }

    func testTimerPauseExcludesPausedTimeAndResumeUsesRemainingTime() {
        var timer = StudyTimer(title: "Reading", seconds: 1500, now: start)
        XCTAssertNil(timer.pause(at: start.addingTimeInterval(120)))
        XCTAssertEqual(timer.remaining, 1380)
        XCTAssertEqual(timer.status, .paused)
        XCTAssertNil(timer.advance(to: start.addingTimeInterval(10000)))
        XCTAssertEqual(timer.remaining, 1380)
        timer.resume(at: start.addingTimeInterval(10000))
        XCTAssertTrue(timer.advance(to: start.addingTimeInterval(11380))?.contains("Time’s up") == true)
    }

    func testTimerShortDurationsCombineCoincidentMilestonesAndDelayedTicksCoalesce() {
        var short = StudyTimer(title: "Recap", seconds: 60, now: start)
        let combined = short.advance(to: start.addingTimeInterval(30))
        XCTAssertTrue(combined?.contains("Halfway") == true)
        XCTAssertTrue(combined?.contains("30 seconds") == true)
        var ten = StudyTimer(title: "Recap", seconds: 600, now: start)
        let five = ten.advance(to: start.addingTimeInterval(300))
        XCTAssertTrue(five?.contains("Halfway") == true)
        XCTAssertTrue(five?.contains("5 minutes") == true)
        var delayed = StudyTimer(title: "Recap", seconds: 1500, now: start)
        XCTAssertTrue(delayed.advance(to: start.addingTimeInterval(2000))?.contains("Time’s up") == true)
        XCTAssertNil(delayed.advance(to: start.addingTimeInterval(2001)))
    }

    @MainActor
    func testGuidedNewTaskValidatesAnswersAndEmotesAtEachStep() {
        let state = PetApplicationState()
        let planner = state.student
        planner.handle("/new")
        XCTAssertEqual(state.currentEmotion, .thinking)
        planner.handle("/reply Lab report")
        planner.handle("/reply Biology")
        planner.handle("/reply 2026-02-30")
        XCTAssertTrue(planner.tasks.isEmpty)
        XCTAssertTrue(planner.pendingPrompt?.contains("couldn’t read") == true)
        planner.handle("/reply tomorrow")
        planner.handle("/reply 0")
        XCTAssertTrue(planner.tasks.isEmpty)
        planner.handle("/reply 40")
        XCTAssertEqual(planner.tasks.first?.title, "Lab report")
        XCTAssertEqual(planner.tasks.first?.subject, "Biology")
        XCTAssertEqual(planner.tasks.first?.minutes, 40)
        XCTAssertEqual(state.currentEmotion, .happy)
        XCTAssertNil(planner.pendingPrompt)
        planner.handle("/done 1")
        XCTAssertEqual(state.currentEmotion, .celebrating)
        XCTAssertTrue(planner.tasks[0].completed)
        planner.handle("/whatever")
        XCTAssertEqual(state.currentEmotion, .idle)
        XCTAssertEqual(planner.tasks.count, 1)
    }

    @MainActor
    func testDailyPlanningAndCheckInOnlyOncePerDayAcrossReload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("planner.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var time = start
        let planner = StudentPlanner(storageURL: url, now: { time })
        planner.checkInIfNeeded()
        XCTAssertEqual(planner.pendingProfileField, .name)
        planner.handle("/skip")
        XCTAssertEqual(planner.pendingPrompt, "What are your tasks for today?")
        planner.handle("/reply Math homework; Read chapter 2\nEmail tutor")
        XCTAssertEqual(planner.tasks.count, 3)
        XCTAssertTrue(planner.tasks.allSatisfy { $0.due != nil })
        let reloaded = StudentPlanner(storageURL: url, now: { time })
        reloaded.checkInIfNeeded()
        XCTAssertNil(reloaded.pendingPrompt)
        time = Calendar.current.date(byAdding: .day, value: 1, to: time)!
        reloaded.checkInIfNeeded()
        XCTAssertEqual(reloaded.pendingProfileField, .birthday)
        reloaded.handle("/skip")
        XCTAssertEqual(reloaded.pendingPrompt, "What are your tasks for today?")
        reloaded.handle("/skip")
        XCTAssertEqual(reloaded.tasks.count, 3)
    }

    @MainActor
    func testTimerCommandsPublishProgressAndActionEmotionsWithoutFalseCompletion() {
        var time = start
        let planner = StudentPlanner(now: { time })
        var messages: [String] = []
        var emotions: [PetEmotion] = []
        var alerts: [String] = []
        var remaining = 0
        planner.onMessage = { messages.append($0); emotions.append($1) }
        planner.onAlert = { alerts.append($0) }
        planner.onTimerChange = { remaining = $0; _ = $1 }
        planner.handle("/timer 25 Essay")
        XCTAssertEqual(emotions.last, .thinking)
        time = start.addingTimeInterval(750)
        planner.tick()
        XCTAssertEqual(remaining, 750)
        XCTAssertEqual(emotions.last, .happy)
        time = start.addingTimeInterval(1471)
        planner.tick()
        XCTAssertEqual(emotions.last, .thinking)
        planner.handle("/stop")
        XCTAssertEqual(remaining, 0)
        XCTAssertNil(planner.timer)
        XCTAssertFalse(alerts.contains { $0.contains("Time’s up") })
        planner.handle("/break 5")
        XCTAssertEqual(emotions.last, .sleeping)
        planner.handle("/pause")
        XCTAssertEqual(emotions.last, .sleeping)
        planner.handle("/resume")
        XCTAssertEqual(emotions.last, .sleeping)
        time = time.addingTimeInterval(300)
        planner.tick()
        XCTAssertEqual(emotions.last, .celebrating)
        XCTAssertTrue(messages.last?.contains("Time’s up") == true)
        planner.tick()
        XCTAssertEqual(alerts.filter { $0.contains("Time’s up") }.count, 1)
    }

    @MainActor
    func testAssignmentsClassesNotesCardsAndRemovalPersist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("planner.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let planner = StudentPlanner(storageURL: url)
        var emotion: PetEmotion?
        var speech = ""
        planner.onMessage = { speech = $0; emotion = $1 }
        planner.handle("/assignment 2026-11-02 Biology lab")
        planner.handle("/exam tomorrow Algebra")
        planner.handle("/class Wed 14:00 Physics")
        planner.handle("/class Mon 09:00 Chemistry")
        planner.handle("/note Ask about the rubric")
        planner.handle("/card What is mitosis? | Cell division")
        XCTAssertEqual(emotion, .happy)
        planner.handle("/quiz")
        XCTAssertEqual(emotion, .thinking)
        XCTAssertFalse(planner.answerRevealed)
        XCTAssertFalse(speech.contains("Cell division"))
        planner.handle("/reveal")
        XCTAssertEqual(emotion, .happy)
        XCTAssertTrue(speech.contains("Cell division"))
        planner.handle("/next")
        XCTAssertFalse(planner.answerRevealed)
        planner.handle("/schedule")
        XCTAssertTrue(speech.contains("1. Mon 09:00"))
        planner.handle("/remove class 1")
        XCTAssertEqual(planner.classes.map(\.title), ["Physics"])
        let restored = StudentPlanner(storageURL: url)
        XCTAssertEqual(restored.tasks.map(\.kind), ["assignment", "exam"])
        XCTAssertEqual(restored.notes.first?.text, "Ask about the rubric")
        XCTAssertEqual(restored.cards.first?.answer, "Cell division")
        XCTAssertEqual(restored.classes, planner.classes)
        XCTAssertNil(restored.timer)
        restored.handle("/remove card 1")
        XCTAssertTrue(restored.cards.isEmpty)
    }

    @MainActor
    func testRemindersSurviveRestartAndFireExactlyOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("planner.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var time = start
        let planner = StudentPlanner(storageURL: url, now: { time })
        planner.handle("/remind 10s Pack lab book")
        let restored = StudentPlanner(storageURL: url, now: { time })
        var alerts: [String] = []
        restored.onAlert = { alerts.append($0) }
        time = start.addingTimeInterval(9)
        restored.tick()
        XCTAssertTrue(alerts.isEmpty)
        time = start.addingTimeInterval(10)
        restored.tick(); restored.tick()
        XCTAssertEqual(alerts, ["Reminder: Pack lab book"])
        let final = StudentPlanner(storageURL: url, now: { time })
        final.onAlert = { alerts.append($0) }
        final.tick()
        XCTAssertEqual(alerts.count, 1)
    }

    @MainActor
    func testMalformedCommandsDontCreateItemsOrReplaceActiveTimer() {
        let planner = StudentPlanner()
        for command in ["/task", "/exam invalid title", "/assignment 2026-02-30 Invalid", "/class Mon 25:00 Maths", "/card Q | ", "/remind 0m Invalid", "/remind 999999999999999h Invalid", "/timer -2", "/timer 721"] {
            XCTAssertTrue(planner.handle(command), command)
        }
        XCTAssertTrue(planner.tasks.isEmpty)
        XCTAssertTrue(planner.classes.isEmpty)
        XCTAssertTrue(planner.cards.isEmpty)
        XCTAssertTrue(planner.reminders.isEmpty)
        XCTAssertNil(planner.timer)
        planner.handle("/timer 25")
        let timer = planner.timer
        planner.handle("/timer 10")
        XCTAssertEqual(planner.timer, timer)
        planner.handle("/new Title")
        XCTAssertTrue(planner.isLocalInputPending)
        planner.handle("/cancel")
        XCTAssertFalse(planner.isLocalInputPending)
        XCTAssertFalse(planner.handle("A document question"))
    }

    @MainActor
    func testCorruptPlannerIsPreservedAndReported() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("broken json".utf8)
        try original.write(to: url)
        let planner = StudentPlanner(storageURL: url)
        var speech = ""
        planner.onMessage = { speech = $0; _ = $1 }
        planner.handle("/task Homework")
        XCTAssertNotNil(planner.storageError)
        XCTAssertTrue(speech.contains("Couldn’t read"))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor
    func testComposerRunsSlashCommandsAndGuidedRepliesWithNoModelOrHTTP() throws {
        _ = NSApplication.shared
        let state = PetApplicationState()
        let harness = Phase4HTTPHarness(failure: .cannotConnectToHost)
        defer { harness.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: harness.session))
        let controller = NotesQueryWindowController(state: state, assistant: assistant)
        defer { controller.close() }
        for input in ["/new", "/reply Essay", "/skip", "/skip", "/reply 25", "/focus 1"] {
            controller.presentation.query = input
            controller.submit()
            XCTAssertEqual(controller.presentation.query, "")
        }
        XCTAssertEqual(state.student.tasks.first?.title, "Essay")
        XCTAssertEqual(state.goalTimerSecondsRemaining, 1500)
        XCTAssertEqual(state.currentEmotion, .thinking)
        XCTAssertFalse(assistant.isAnswering)
        XCTAssertTrue(harness.requests.isEmpty)
        controller.presentation.query = "/stop"
        controller.submit()
        XCTAssertEqual(state.goalTimerSecondsRemaining, 0)
        XCTAssertEqual(state.currentEmotion, .idle)
        XCTAssertFalse(state.speechBubbleText.contains("Time’s up"))
    }

    @MainActor
    func testStopOnHostedCanvasDoesNotTriggerLegacyCompletionHook() async throws {
        _ = NSApplication.shared
        let state = PetApplicationState()
        let canvas = PetCanvasWindowController(model: state, animationsEnabled: false)
        defer { canvas.close() }
        canvas.showWindow(nil)
        state.student.handle("/timer 25")
        try await Task.sleep(for: .milliseconds(30))
        state.student.handle("/stop")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(state.currentEmotion, .idle)
        XCTAssertTrue(state.speechBubbleText.contains("Timer stopped"))
        XCTAssertNil(state.activeTask)
    }

    @MainActor
    func testStudentActionCancelsInferenceAndClearsStaleCitations() async throws {
        _ = NSApplication.shared
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("Research.pdf"))
        let harness = Phase4HTTPHarness(json: "", holdOpen: true)
        defer { harness.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: harness.session))
        let controller = NotesQueryWindowController(state: state, assistant: assistant)
        defer { controller.close() }
        let answer = Task { await assistant.answer(query: "orchid", model: "local:test") }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(assistant.isAnswering)
        controller.presentation.query = "/task Study chemistry"
        controller.submit()
        await answer.value
        XCTAssertFalse(assistant.isAnswering)
        XCTAssertTrue(controller.presentation.sources.isEmpty)
        XCTAssertTrue(state.speechBubbleText.contains("Added: Study chemistry"))
        XCTAssertEqual(state.currentEmotion, .happy)
    }

    @MainActor
    func testCommandCancelsDocumentRequestBeforeItsTaskStarts() async throws {
        _ = NSApplication.shared
        let state = PetApplicationState()
        let harness = Phase4HTTPHarness(failure: .cannotConnectToHost)
        defer { harness.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: harness.session))
        let controller = NotesQueryWindowController(state: state, assistant: assistant)
        defer { controller.close() }
        controller.presentation.modelName = "local:test"
        controller.presentation.query = "/ask orchid"
        controller.submit()
        controller.presentation.query = "/task Study chemistry"
        controller.submit()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(state.speechBubbleText.contains("Added: Study chemistry"))
        XCTAssertEqual(state.currentEmotion, .happy)
        XCTAssertTrue(harness.requests.isEmpty)
        XCTAssertFalse(assistant.isAnswering)
    }

    @MainActor
    func testRealTickerDeliversReminderAndStopRemovesSubscription() async throws {
        var time = start
        let planner = StudentPlanner(now: { time })
        planner.handle("/remind 1s Stretch")
        var alerts = 0
        planner.onAlert = { _ in alerts += 1 }
        planner.start()
        defer { planner.stop() }
        time = start.addingTimeInterval(1)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(alerts, 1)
        planner.stop()
        planner.handle("/remind 1s Read")
        time = time.addingTimeInterval(2)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(alerts, 1)
    }
}
