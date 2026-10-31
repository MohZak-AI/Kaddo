import XCTest
@testable import KaddoCanvas

final class AgentPlatformTests: XCTestCase {
    @MainActor private func make(_ data: AgentPlatformData = AgentPlatformData(), now: @escaping () -> Date = Date.init) async throws -> AgentPlatform {
        let library = KnowledgeLibrary(embeddingProvider: nil)
        await library.load()
        try await library.store.saveAgentData(data)
        let platform = AgentPlatform(library: library, activity: PetActivityStore(), now: now)
        await platform.load()
        return platform
    }
    @MainActor func testSharedVoiceAndOfflineReplies() {
        XCTAssertTrue(AssistantCoordinator.instructions.contains(CompanionConversationPolicy.instructions))
        let assistant = LocalCompanionAssistant()
        var replies: [String] = []
        assistant.onReply = { replies.append($0.text) }
        for greeting in ["hello", "thanks", "i'm tired", "مرحبا", "شكرا"] { XCTAssertTrue(assistant.respondLocally(to: greeting)) }
        XCTAssertFalse(replies.contains { $0.contains(":)") || $0.contains("buddy") || $0.contains("flame dance") })
        let planner = StudentPlanner()
        var output = ""
        planner.onMessage = { text, _ in output = text }
        planner.say("Timer paused.")
        XCTAssertEqual(output, "Timer paused.")
    }
    func testLocalStructuredResponsesAvoidNestedConversationEnvelope() async throws {
        let fact = #"{"suggestions":[{"fact":"Prefers tea.","quote":"I prefer tea.","replacesID":null}]}"#
        let line = try AssistantJSON.object(["response": .string(fact), "done": .bool(true)]).jsonString() + "\n"
        let http = Phase4HTTPHarness(json: line); defer { http.cleanUp() }
        let provider = OllamaAssistantProvider(client: try OllamaClient(session: http.session), model: "local")
        let turn = try await provider.respond(to: .init(instructions: "Return JSON suggestions.", input: [.message("I prefer tea.")], toolsEnabled: false, responseFormat: .jsonObject))
        let json = try JSONDecoder().decode(AssistantJSON.self, from: Data(turn.text.utf8))
        XCTAssertEqual(json["suggestions"]?.array?.count, 1); XCTAssertTrue(turn.calls.isEmpty)
        let body = try XCTUnwrap(http.requests.last { $0.url?.path == "/api/generate" }?.body)
        let payload = try JSONDecoder().decode(AssistantJSON.self, from: body)
        XCTAssertFalse(payload["system"]?.string?.contains("text (string) and tool") ?? true)
        XCTAssertTrue(payload["system"]?.string?.contains("You have no tools") ?? false)
    }

    func testScheduledCapabilitiesFailClosedEvenWithWideAllowList() {
        let request = AssistantRequest(instructions: "Routine", input: [], toolsEnabled: true,
                                       allowedTools: Set(KaddoToolName.allCases), executionMode: .scheduled)
        for name in KaddoToolName.allCases { XCTAssertFalse(request.permits(name)) }
        XCTAssertTrue(request.toolSchemas.isEmpty)
        let read = AssistantRequest(instructions: "", input: [], allowedTools: [.today])
        XCTAssertTrue(read.permits(.today)); XCTAssertFalse(read.permits(.task)); XCTAssertEqual(read.toolSchemas.count, 1)
    }
    @MainActor func testSuggestAcceptEditDeleteAndCorrectionAreDurable() async throws {
        let text = "I prefer short answers."
        let response = #"{"suggestions":[{"fact":"Prefers short answers.","quote":"I prefer short answers.","replacesID":null}]}"#
        let p = try await make()
        let provider = ScriptedAssistantProvider([.turn(.init(text: response))])
        p.providerFactory = { provider }
        p.suggestMemory(from: text); await p.waitForSuggestions()
        let suggestion = try XCTUnwrap(p.data.suggestions.first)
        XCTAssertTrue(p.library.items.isEmpty)
        await p.accept(suggestion, fact: suggestion.fact)
        XCTAssertTrue(p.data.suggestions.isEmpty)
        let id = try XCTUnwrap(p.data.memories.first?.itemID)
        XCTAssertEqual(p.library.items.first?.text, "Prefers short answers.")
        XCTAssertEqual(p.personalization(for: "hello"), ["Prefers short answers."])
        await p.updateMemory(id, text: "Prefers detailed answers.")
        XCTAssertEqual(p.library.items.first?.text, "Prefers detailed answers.")
        var data = p.data
        let correction = AgentMemorySuggestion(fact: "Prefers concise answers.", quote: "Actually I prefer concise answers.", createdAt: Date(), replacesID: id)
        data.suggestions.append(correction)
        let p2 = try await make(data)
        // Target does not exist in this separate library, so replacement cannot silently create a new fact.
        await p2.accept(correction, fact: correction.fact)
        XCTAssertTrue(p2.library.items.isEmpty)
        XCTAssertFalse(p2.data.suggestions.isEmpty)
        await p.deleteMemory(id)
        XCTAssertTrue(p.library.items.isEmpty); XCTAssertTrue(p.data.memories.isEmpty)
        let requests = await provider.requests
        XCTAssertFalse(requests[0].toolsEnabled)
        XCTAssertFalse(try requests[0].input[0].jsonString().contains("companion"))
    }
    @MainActor func testUnsupportedQuotesAndToolCallsCannotCreateSuggestions() async throws {
        let p = try await make()
        let provider = ScriptedAssistantProvider([
            .turn(.init(text: #"{"suggestions":[{"fact":"Invented fact","quote":"Not said by the user","replacesID":null}]}"#)),
            .turn(try toolTurn(.save_knowledge, .init(text: "Secret")))
        ])
        p.providerFactory = { provider }
        p.suggestMemory(from: "I prefer tea."); await p.waitForSuggestions()
        p.suggestMemory(from: "I usually drink tea."); await p.waitForSuggestions()
        XCTAssertTrue(p.data.suggestions.isEmpty); XCTAssertTrue(p.library.items.isEmpty)
    }
    @MainActor func testForgetCancelsInFlightSuggestionAndKeepsAcceptedMemory() async throws {
        let p = try await make()
        let response = #"{"suggestions":[{"fact":"Prefers tea.","quote":"I prefer tea.","replacesID":null}]}"#
        let provider = ScriptedAssistantProvider([.delayed(.init(text: response))])
        p.providerFactory = { provider }
        p.suggestMemory(from: "I prefer tea.")
        await Task.yield(); p.forget(); await p.waitForSuggestions(); await p.waitForPersistence()
        XCTAssertTrue(p.data.suggestions.isEmpty)
        let saved = try await p.library.store.agentData()
        XCTAssertTrue(saved.suggestions.isEmpty)
    }
    @MainActor func testDismissedSuggestionDoesNotReturn() async throws {
        let suggestion = AgentMemorySuggestion(fact: "Prefers tea.", quote: "I prefer tea.", createdAt: Date())
        var data = AgentPlatformData(); data.suggestions = [suggestion]
        let p = try await make(data)
        await p.dismiss(suggestion)
        let provider = ScriptedAssistantProvider([.turn(.init(text: #"{"suggestions":[{"fact":"Prefers tea.","quote":"I prefer tea.","replacesID":null}]}"#))])
        p.providerFactory = { provider }
        p.suggestMemory(from: "I prefer tea."); await p.waitForSuggestions()
        XCTAssertTrue(p.data.suggestions.isEmpty)
    }
    @MainActor func testValidCorrectionUpdatesSameItemAndPreservesProvenance() async throws {
        var data = AgentPlatformData()
        let first = AgentMemorySuggestion(fact: "Prefers tea.", quote: "I prefer tea.", createdAt: Date())
        data.suggestions = [first]
        let p = try await make(data)
        await p.accept(first, fact: first.fact)
        let id = try XCTUnwrap(p.data.memories.first?.itemID)
        var update = p.data
        let correction = AgentMemorySuggestion(fact: "Prefers coffee.", quote: "Actually, I prefer coffee.", createdAt: Date(), replacesID: id)
        update.suggestions = [correction]
        try await p.library.store.saveAgentData(update)
        try await p.library.store.acceptMemory(correction, fact: correction.fact, now: Date())
        let items = try await p.library.store.items(), saved = try await p.library.store.agentData()
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items.first?.id, id); XCTAssertEqual(items.first?.text, correction.fact)
        XCTAssertEqual(saved.memories.first?.quote, correction.quote); XCTAssertTrue(saved.suggestions.isEmpty)
    }
    @MainActor func testGroundedSourcesRejectToolsAndUnknownCitations() async throws {
        let p = try await make()
        let excerpt = AgentSourceExcerpt(title: "Test", text: "Untrusted content", url: URL(string: "https://example.com")!)
        let provider = ScriptedAssistantProvider([
            .turn(try toolTurn(.task, .init(text: "Injected"))),
            .turn(.init(text: #"{"text":"Claim","sourceIDs":["bogus"]}"#)),
            .turn(.init(text: "{\"text\":\"Supported\",\"sourceIDs\":[\"\(excerpt.id.uuidString)\"]}"))
        ])
        p.providerFactory = { provider }
        for _ in 0..<2 {
            do { _ = try await p.sourceAnswer("Question", excerpts: [excerpt]); XCTFail("Must reject") }
            catch { XCTAssertEqual(error as? AssistantError, .invalidResponse) }
        }
        let answer = try await p.sourceAnswer("Question", excerpts: [excerpt])
        XCTAssertEqual(answer, "Supported")
        let requests = await provider.requests
        XCTAssertTrue(requests.allSatisfy { !$0.toolsEnabled && $0.allowedTools == [] })
    }
    @MainActor func testRevokedSourceFailsAndNoGrantOpensPicker() async throws {
        let p = try await make()
        var picked = false
        p.onFolderPicker = { picked = true }
        do { _ = try await p.readSource(.init(name: .read_source_file, arguments: .init(id: UUID(), path: "notes.txt"))); XCTFail() }
        catch { XCTAssertTrue(picked) }
    }
    @MainActor func testWorkflowCRUDAndPersistence() async throws {
        let p = try await make()
        let workflow = AgentWorkflow(name: "Weekly review", instructions: "Summarize my tasks.")
        await p.saveWorkflow(workflow); await p.duplicateWorkflow(workflow)
        XCTAssertEqual(p.data.workflows.count, 4)
        let saved = try await p.library.store.agentData()
        XCTAssertEqual(saved.workflows.count, 4)
        await p.schedule(workflow, schedule: AgentSchedule(), monitoring: false)
        XCTAssertEqual(p.data.routines.count, 1)
        await p.deleteWorkflow(workflow.id)
        XCTAssertTrue(p.data.routines.isEmpty)
        XCTAssertEqual(p.data.workflows.count, 3)
    }
    @MainActor func testRoutineCoalescesMissedRunsAndPersistsOccurrence() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let workflow = AgentWorkflow(name: "Briefing", instructions: "Summarize only")
        var schedule = AgentSchedule(); schedule.frequency = .interval
        let routine = AgentRoutine(workflowID: workflow.id, schedule: schedule, nextRun: date.addingTimeInterval(-10_000), timeZoneID: TimeZone.current.identifier)
        var data = AgentPlatformData(); data.workflows = [workflow]; data.routines = [routine]
        let p = try await make(data, now: { date })
        let provider = ScriptedAssistantProvider([.turn(.init(text: "Here are your priorities."))])
        p.providerFactory = { provider }; p.plannerContext = { "One task" }
        await p.tick(); await p.waitForRoutine(); await p.tick()
        XCTAssertEqual(p.data.runs.count, 1); XCTAssertEqual(p.data.runs.first?.status, "completed")
        XCTAssertTrue(try XCTUnwrap(p.data.routines.first).nextRun > date)
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests[0].executionMode, .scheduled)
        XCTAssertTrue(requests[0].toolSchemas.isEmpty)
        let reload = AgentPlatform(library: p.library, activity: PetActivityStore(), now: { date })
        await reload.load(); reload.providerFactory = { provider }
        await reload.tick(); await reload.waitForRoutine()
        XCTAssertEqual(reload.data.runs.count, 1)
    }
    @MainActor func testScheduledToolInjectionFailsOnceAndRetryIsExplicit() async throws {
        let date = Date()
        let workflow = AgentWorkflow(name: "Briefing", instructions: "Summarize")
        let routine = AgentRoutine(workflowID: workflow.id, schedule: AgentSchedule(), nextRun: date, timeZoneID: TimeZone.current.identifier)
        var data = AgentPlatformData(); data.workflows = [workflow]; data.routines = [routine]
        let p = try await make(data, now: { date })
        let provider = ScriptedAssistantProvider([.turn(try toolTurn(.task, .init(text: "Injected"))), .turn(.init(text: "Read-only briefing."))])
        p.providerFactory = { provider }
        await p.tick(); await p.waitForRoutine(); await p.tick()
        XCTAssertEqual(p.data.runs.count, 1); XCTAssertEqual(p.data.runs.first?.status, "failed")
        await p.retry(try XCTUnwrap(p.data.runs.first)); await p.waitForRoutine()
        XCTAssertEqual(p.data.runs.count, 2); XCTAssertEqual(p.data.runs.first?.status, "completed")
    }
    @MainActor func testBusyAndQuietIntervalDeferRoutineAndMonitoringSuppressesUnchanged() async throws {
        let date = Date()
        let workflow = AgentWorkflow(name: "Monitor", instructions: "Report changes")
        let routine = AgentRoutine(workflowID: workflow.id, schedule: AgentSchedule(), monitoring: true, nextRun: date, timeZoneID: TimeZone.current.identifier)
        var data = AgentPlatformData(); data.workflows = [workflow]; data.routines = [routine]
        let p = try await make(data, now: { date })
        p.isUserBusy = { true }; await p.tick(); XCTAssertTrue(p.data.runs.isEmpty)
        p.isUserBusy = { false }; p.noteInteraction(); await p.tick(); XCTAssertTrue(p.data.runs.isEmpty)
        let p2 = try await make(data, now: { date })
        let provider = ScriptedAssistantProvider([.turn(.init(text: "Nothing urgent."))]); p2.providerFactory = { provider }
        await p2.tick(); await p2.waitForRoutine()
        let snapshot = p2.data
        var next = snapshot; next.routines[0].nextRun = date.addingTimeInterval(-86_400)
        // Use a later date for the second daily occurrence, preserving its source signature.
        let p3 = try await make(next, now: { date.addingTimeInterval(86_400) }); p3.providerFactory = { provider }
        await p3.tick(); await p3.waitForRoutine()
        XCTAssertEqual(p3.data.runs.first?.status, "unchanged")
        let requests = await provider.requests; XCTAssertEqual(requests.count, 1)
    }
    @MainActor func testConcurrentAcceptancesAndSourceSaveCannotPersistFailedCorrection() async throws {
        let valid = AgentMemorySuggestion(fact: "Prefers tea.", quote: "I prefer tea.", createdAt: Date())
        let missing = UUID()
        let invalid = AgentMemorySuggestion(fact: "Prefers coffee.", quote: "I prefer coffee.", createdAt: Date(), replacesID: missing)
        var data = AgentPlatformData(); data.suggestions = [valid, invalid]
        data.memories = [.init(itemID: missing, source: "Deleted memory", quote: "old", acceptedAt: Date())]
        let p = try await make(data)
        let first = Task { await p.accept(valid, fact: valid.fact) }
        await Task.yield()
        let correction = Task { await p.accept(invalid, fact: invalid.fact) }
        let source = Task { await p.addWeb(URL(string: "https://example.com")!) }
        await first.value; await correction.value; await source.value; await p.waitForPersistence()
        let saved = try await p.library.store.agentData()
        XCTAssertTrue(saved.suggestions.contains { $0.id == invalid.id })
        XCTAssertFalse(saved.suggestions.contains { $0.id == valid.id })
        XCTAssertEqual(saved.memories.first { $0.itemID == missing }?.quote, "old")
        XCTAssertTrue(saved.memories.contains { $0.itemID == valid.id })
        XCTAssertEqual(saved.sources.count, 1)
    }
    @MainActor func testClaimStorageFailureLeavesRetryableRunWithoutCallingProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("knowledge.sqlite")
        let library = KnowledgeLibrary(storageURL: path, embeddingProvider: nil)
        await library.load()
        let date = Date(), workflow = AgentWorkflow(name: "Brief", instructions: "Summarize")
        var data = AgentPlatformData(); data.workflows = [workflow]
        data.routines = [.init(workflowID: workflow.id, schedule: AgentSchedule(), nextRun: date, timeZoneID: TimeZone.current.identifier)]
        try await library.store.saveAgentData(data)
        let p = AgentPlatform(library: library, activity: PetActivityStore(), now: { date }); await p.load()
        let provider = ScriptedAssistantProvider([.turn(.init(text: "Briefing."))]); p.providerFactory = { provider }
        let moved = root.appendingPathComponent("moved.sqlite")
        try FileManager.default.moveItem(at: path, to: moved)
        await p.tick(); await p.waitForRoutine()
        XCTAssertEqual(p.data.runs.first?.status, "failed"); XCTAssertFalse(p.isRunning)
        let requests = await provider.requests; XCTAssertTrue(requests.isEmpty)
        try FileManager.default.moveItem(at: moved, to: path)
        await p.retry(try XCTUnwrap(p.data.runs.first)); await p.waitForRoutine()
        XCTAssertEqual(p.data.runs.first?.status, "completed")
    }
    @MainActor func testSavedWorkflowBypassesUploadedDocumentAutoRouting() async throws {
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost); defer { http.cleanUp() }
        let state = PetApplicationState()
        _ = try await state.documentMemory.importDocument(at: documentFixture("Research.pdf"))
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let controller = NotesQueryWindowController(state: state, assistant: assistant, settings: AssistantSettings())
        defer { controller.close(); state.agent.stop() }
        let provider = ScriptedAssistantProvider([.turn(.init(text: "The saved prompt ran."))])
        controller.coordinator.providerFactory = { provider }
        let workflow = AgentWorkflow(name: "Selected source", instructions: "Summarize the document")
        state.agent.runWorkflow(workflow)
        for _ in 0..<100 {
            if !(await provider.requests).isEmpty, !controller.coordinator.isAnswering { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(state.speechBubbleText, "The saved prompt ran.")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testScheduleValidationAndLocalCalendarDST() throws {
        var schedule = AgentSchedule(); schedule.frequency = .interval; schedule.intervalMinutes = 29
        XCTAssertNil(schedule.next(after: Date()))
        schedule.intervalMinutes = 30
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(schedule.next(after: date), date.addingTimeInterval(1800))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        schedule.frequency = .daily; schedule.hour = 2; schedule.minute = 30
        let before = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1)))
        let after = try XCTUnwrap(schedule.next(after: before, calendar: calendar))
        XCTAssertTrue(after > before); XCTAssertEqual(calendar.component(.day, from: after), 8)
    }
}
