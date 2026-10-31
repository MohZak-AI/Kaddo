import XCTest
@testable import KaddoCanvas

final class AssistantCoordinatorTests: XCTestCase {
    @MainActor
    private func make(_ provider: any AssistantProvider) -> (PetApplicationState, AssistantCoordinator) {
        let state = PetApplicationState()
        let coordinator = AssistantCoordinator(state: state)
        coordinator.providerFactory = { provider }
        coordinator.onReply = { state.speechBubbleText = $0.text; state.currentEmotion = $0.emotion }
        state.student.beforeMessage = { [weak coordinator] in
            if coordinator?.isExecutingTool == false { coordinator?.cancel() }
        }
        return (state, coordinator)
    }

    @MainActor
    func testModelRunsSequentialActionsAndGeneralReplyInUserLanguage() async throws {
        let provider = ScriptedAssistantProvider([
            .turn(try toolTurn(.task, .init(text: "مراجعة الأحياء"))),
            .turn(try toolTurn(.timer, .init(minutes: 25))),
            .turn(.init(text: "حفظت المهمة وبدأت المؤقت. يمكنك البدء بخطوة صغيرة."))
        ])
        let (state, c) = make(provider)
        await c.answer("أضف مهمة مراجعة الأحياء وابدأ مؤقتًا لمدة ٢٥ دقيقة وشجعني")
        XCTAssertEqual(state.student.tasks.first?.title, "مراجعة الأحياء")
        XCTAssertEqual(state.student.timer?.remaining, 1500)
        XCTAssertTrue(state.speechBubbleText.hasPrefix("حفظت"))
        XCTAssertFalse(c.isAnswering)
        XCTAssertEqual(c.conversation.exchanges.count, 1)
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(try requests[1].input.last!.jsonString().contains("success"))
    }

    @MainActor
    func testContextualReplyDoesNotConsumeUnrelatedChat() async throws {
        let provider = ScriptedAssistantProvider([
            .turn(.init(text: "We can talk about that. What has been on your mind?")),
            .turn(try toolTurn(.reply, .init(text: "Biology"))),
            .turn(.init(text: "Biology—when is it due?"))
        ])
        let (state, c) = make(provider)
        c.performShortcut("/new Essay")
        let question = state.student.pendingPrompt
        await c.answer("I feel nervous about tomorrow")
        XCTAssertEqual(state.student.pendingPrompt, question)
        XCTAssertTrue(state.student.tasks.isEmpty)
        await c.answer("It is for biology")
        XCTAssertTrue(state.student.pendingPrompt?.hasPrefix("When is it due?") == true)
        let requests = await provider.requests
        let contextText = try XCTUnwrap(requests[0].input.first { $0["content"]?.string?.hasPrefix("Current application context") == true }?["content"]?.string)
        let context = try JSONDecoder().decode(AssistantJSON.self, from: Data(contextText.dropFirst("Current application context (data): ".count).utf8))
        XCTAssertEqual(context["pendingQuestion"]?.string, question)
    }

    @MainActor
    func testArabicFollowupResolvesStableTaskIDAndAmbiguityAsksWithoutMutation() async throws {
        let state = PetApplicationState()
        state.student.handle("/task Biology lab"); state.student.handle("/task Biology revision")
        let id = state.student.tasks[1].id
        let provider = ScriptedAssistantProvider([
            .turn(try toolTurn(.read_state, .init(collection: "tasks"))),
            .turn(.init(text: "هل تقصد المختبر أم المراجعة؟")),
            .turn(try toolTurn(.focus, .init(id: id))),
            .turn(.init(text: "بدأت مؤقت مراجعة الأحياء."))
        ])
        let c = AssistantCoordinator(state: state)
        c.providerFactory = { provider }; c.onReply = { state.speechBubbleText = $0.text }
        await c.answer("ابدأ مهمة الأحياء")
        XCTAssertNil(state.student.timer)
        XCTAssertTrue(state.speechBubbleText.contains("هل تقصد"))
        await c.answer("المراجعة")
        XCTAssertEqual(state.student.timer?.title, "Biology revision")
        let requests = await provider.requests
        XCTAssertTrue(try requests[1].input.last!.jsonString().contains(id.uuidString))
    }

    @MainActor
    func testDuplicateDeliveryAndRetryDoNotRepeatCompletedWrites() async throws {
        let call = try toolTurn(.task, .init(text: "Only once"), id: "first")
        let repeated = try toolTurn(.task, .init(text: "Only once"), id: "second")
        let provider = ScriptedAssistantProvider([.turn(call), .failure(.service), .turn(repeated), .turn(.init(text: "Saved once."))])
        let (state, c) = make(provider)
        await c.answer("Add a task called Only once")
        XCTAssertEqual(state.student.tasks.count, 1); XCTAssertTrue(c.canRetry)
        XCTAssertTrue(state.speechBubbleText.contains("Only once"))
        await c.retry()
        XCTAssertEqual(state.student.tasks.count, 1); XCTAssertFalse(c.canRetry)
        let requests = await provider.requests
        XCTAssertEqual(requests[1].input, requests[2].input, "Retry resumes after committed tool output")
    }

    @MainActor
    func testSameCallDeliveryDoesNotDuplicateWritesOrWireItems() async throws {
        let call = try toolTurn(.task, .init(text: "One task"), id: "same-delivery")
        let provider = ScriptedAssistantProvider([.turn(call), .turn(call), .turn(.init(text: "Saved."))])
        let (state, c) = make(provider)
        await c.answer("Save one task")
        XCTAssertEqual(state.student.tasks.count, 1)
        let requests = await provider.requests
        XCTAssertEqual(requests[1].input, requests[2].input)
    }

    @MainActor
    func testReusedCallIDWithDifferentArgumentsIsRejected() async throws {
        let provider = ScriptedAssistantProvider([
            .turn(try toolTurn(.task, .init(text: "First"), id: "same")),
            .turn(try toolTurn(.task, .init(text: "Second"), id: "same"))
        ])
        let (state, c) = make(provider); await c.answer("Add two tasks")
        XCTAssertEqual(state.student.tasks.map(\.title), ["First"])
        XCTAssertTrue(state.speechBubbleText.contains("invalid response"))
    }

    @MainActor
    func testRepeatedReadFetchesFreshStateAfterAWrite() async throws {
        let provider = ScriptedAssistantProvider([
            .turn(try toolTurn(.read_state, .init(collection: "tasks"))),
            .turn(try toolTurn(.task, .init(text: "New task"))),
            .turn(try toolTurn(.read_state, .init(collection: "tasks"))),
            .turn(.init(text: "Your list now includes New task."))
        ])
        let (_, c) = make(provider)
        await c.answer("Check my list, add New task, and check again")
        let requests = await provider.requests
        let first = try XCTUnwrap(requests[1].input.last?["output"]?.string)
        let second = try XCTUnwrap(requests[3].input.last?["output"]?.string)
        XCTAssertFalse(first.contains("New task"))
        XCTAssertTrue(second.contains("New task"))
    }

    @MainActor
    func testCancellationBeforeToolExecutionPreventsStaleWrites() async throws {
        let provider = ScriptedAssistantProvider([.delayed(try toolTurn(.task, .init(text: "Stale")))])
        let (state, c) = make(provider)
        let work = Task { await c.answer("Add a task") }
        try await Task.sleep(for: .milliseconds(20))
        c.cancel(); state.speechBubbleText = "Newer output"
        await work.value
        XCTAssertTrue(state.student.tasks.isEmpty)
        XCTAssertEqual(state.speechBubbleText, "Newer output")
    }

    @MainActor
    func testEightToolLimitRetainsCompletedResults() async throws {
        var steps = try (1...9).map { ScriptedAssistantProvider.Step.turn(try toolTurn(.task, .init(text: "Task \($0)"))) }
        steps.append(.turn(.init(text: "Done")))
        let (state, c) = make(ScriptedAssistantProvider(steps))
        await c.answer("Add nine tasks")
        XCTAssertEqual(state.student.tasks.count, 8)
        XCTAssertTrue(state.speechBubbleText.contains("eight-action limit"))
        XCTAssertFalse(c.canRetry)
    }

    @MainActor
    func testToolValidationAndStableIDsPreventUnintendedChanges() {
        let state = PetApplicationState()
        let executor = KaddoToolExecutor(state: state)
        XCTAssertEqual(executor.execute(.init(name: .timer, arguments: .init(minutes: 0))).status, .failure)
        XCTAssertNil(state.student.timer)
        let coordinator = AssistantCoordinator(state: state)
        XCTAssertTrue(coordinator.respondLocally(to: "start a 99999999999999999999999-minute timer"))
        XCTAssertNil(state.student.timer, "An overflowing duration must never become the default duration")
        XCTAssertEqual(executor.execute(.init(name: .remind, arguments: .init(text: "Book", seconds: 604801))).status, .needsInput)
        XCTAssertTrue(state.student.reminders.isEmpty)
        XCTAssertEqual(executor.execute(.init(name: .focus, arguments: .init(id: UUID()))).status, .needsInput)
        XCTAssertEqual(executor.execute(.init(name: .assignment, arguments: .init(text: "Lab", date: "2026-02-30"))).status, .failure)
        XCTAssertTrue(state.student.tasks.isEmpty)
        XCTAssertEqual(executor.execute(.init(name: .class, arguments: .init(text: "Lab", day: "Mon", time: "25:01"))).status, .failure)
        XCTAssertTrue(state.student.classes.isEmpty)
        XCTAssertEqual(executor.execute(.init(name: .note)).status, .needsInput)
        XCTAssertTrue(state.student.notes.isEmpty)
    }

    @MainActor
    func testStorageFailureIsReportedAndMutationRolledBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = PetApplicationState(studentStorageURL: root.appendingPathComponent("planner.json"))
        let executor = KaddoToolExecutor(state: state)
        let result = executor.execute(.init(name: .task, arguments: .init(text: "Cannot save")))
        XCTAssertEqual(result.status, .failure)
        XCTAssertTrue(result.message.contains("Couldn’t save"))
        XCTAssertTrue(state.student.tasks.isEmpty)
    }

    @MainActor
    func testCorruptPlannerRemainsPreservedWithFailureResult() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data("corrupt planner".utf8); try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let state = PetApplicationState(studentStorageURL: file)
        let result = KaddoToolExecutor(state: state).execute(.init(name: .note, arguments: .init(text: "Do not overwrite")))
        XCTAssertEqual(result.status, .failure); XCTAssertTrue(state.student.notes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    @MainActor
    func testCardQuizAndSessionToolsUseSharedOperations() throws {
        let state = PetApplicationState(); let executor = KaddoToolExecutor(state: state)
        XCTAssertEqual(executor.execute(.init(name: .card, arguments: .init(text: "a | b?", answer: "a OR b"))).status, .success)
        XCTAssertEqual(state.student.cards.first?.question, "a | b?")
        _ = executor.execute(.init(name: .quiz)); XCTAssertFalse(state.student.answerRevealed)
        _ = executor.execute(.init(name: .reveal)); XCTAssertTrue(state.student.answerRevealed)
        let previous = state.activeSessionID
        _ = executor.execute(.init(name: .session, arguments: .init(text: "Biology")))
        XCTAssertNotEqual(previous, state.activeSessionID)
        _ = executor.execute(.init(name: .select_session, arguments: .init(id: previous)))
        XCTAssertEqual(previous, state.activeSessionID)
    }

    @MainActor
    func testOfflineActionOutcomeSurvivesIntoNextModelRequest() async throws {
        let provider = ScriptedAssistantProvider([.turn(.init(text: "Which part would you like to change?"))])
        let (_, c) = make(provider)
        XCTAssertTrue(c.respondLocally(to: "add a task Biology lab"))
        await c.answer("Can we change that?")
        let requests = await provider.requests
        let input = try requests[0].input.map { try $0.jsonString() }.joined()
        XCTAssertTrue(input.contains("Biology lab"))
        c.forget()
        XCTAssertTrue(c.conversation.exchanges.isEmpty)
    }

    @MainActor
    func testConfiguredAIReceivesAmbiguousGuidedRepliesInsteadOfSavingThem() async throws {
        let provider = ScriptedAssistantProvider([.turn(.init(text: "Glad you like it!"))])
        let (state, c) = make(provider)
        c.understandsFreeform = { true }
        c.performShortcut("/profile edit name")
        XCTAssertFalse(c.respondLocally(to: "Cool"))
        await c.answer("Cool")
        XCTAssertNil(state.student.profile?.name)
        XCTAssertEqual(state.student.pendingProfileField, .name)
        XCTAssertTrue(c.respondLocally(to: "save a note"))
        XCTAssertFalse(c.respondLocally(to: "It is a beautiful day"))
        XCTAssertTrue(state.student.notes.isEmpty)
    }

    @MainActor
    func testNotificationPermissionResultDoesNotCancelRemainingActions() async throws {
        let provider = ScriptedAssistantProvider([
            .turn(try toolTurn(.notifications, .init(enabled: true))),
            .turn(try toolTurn(.timer, .init(minutes: 25))),
            .turn(.init(text: "Notification permission was denied, but your timer is running."))
        ])
        let (state, c) = make(provider)
        state.student.notificationRequest = { _ in
            await Task.yield()
            return .init(.failure, "Notification permission denied")
        }
        await c.answer("Enable notifications and start a timer")
        XCTAssertEqual(state.student.timer?.remaining, 1500)
        XCTAssertTrue(state.speechBubbleText.contains("denied"))
        let requests = await provider.requests
        XCTAssertTrue(requests[1].input.last?["output"]?.string?.contains("failure") == true)
    }

    @MainActor
    func testImporterToolCanContinueWithAnotherRequestedAction() async throws {
        let provider = ScriptedAssistantProvider([
            .turn(try toolTurn(.add_document)),
            .turn(try toolTurn(.timer, .init(minutes: 25))),
            .turn(.init(text: "The picker is open and your timer has started."))
        ])
        let (state, c) = make(provider)
        var opened = false
        c.openDocument = {
            XCTAssertTrue(c.isExecutingTool)
            opened = true
            state.student.say("Choose a document")
        }
        await c.answer("Open the importer and start a timer")
        XCTAssertTrue(opened)
        XCTAssertEqual(state.student.timer?.remaining, 1500)
        XCTAssertFalse(c.isAnswering)
    }

    @MainActor
    func testProfileClearRemovesPersonalizedHistory() async throws {
        let provider = ScriptedAssistantProvider([.turn(try toolTurn(.profile, .init(text: "clear")))])
        let (state, c) = make(provider)
        c.performShortcut("/profile edit name"); c.performShortcut("/reply Sam")
        c.conversation.append(.init(user: "hi", companion: "Hello Sam"))
        await c.answer("Clear my personal details")
        XCTAssertNil(state.student.profile?.name)
        XCTAssertTrue(c.conversation.exchanges.isEmpty)
        XCTAssertFalse(c.canRetry)
    }

    @MainActor
    func testDocumentResultsNeverEnterGeneralModelContextOrChatHistory() async throws {
        let provider = ScriptedAssistantProvider([
            .turn(try toolTurn(.ask, .init(text: "Explain orchids in my notes"))),
            .turn(.init(text: "I’ve shown the answer with its sources."))
        ])
        let (state, c) = make(provider)
        c.answerDocument = { _ in .answered(.init(text: "Private document answer", sources: [], context: nil)) }
        await c.answer("Explain orchids in my notes")
        XCTAssertTrue(state.speechBubbleText.contains("Private document answer"))
        XCTAssertTrue(c.conversation.exchanges.isEmpty)
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(try requests.flatMap(\.input).map { try $0.jsonString() }.joined().contains("Private document answer"))
    }
}
