import Combine
import XCTest
@testable import KaddoCanvas

final class LocalNotesAssistantTests: XCTestCase {
    @MainActor
    func testTransportRequestAndLiveUpdatesBeforeDone() async throws {
        let first = try speechObject("Water weekly.", emotion: "celebrating")
        let body = try inferenceRecord("```json\n{\"lines\":[\(first)") + "\n"
        let http = Phase4HTTPHarness(json: body, holdOpen: true)
        defer { http.cleanUp() }
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let published = expectation(description: "Decoded line arrives while connection is still open")
        let token = state.$speechBubbleText.sink { if $0 == "Water weekly." { published.fulfill() } }
        var emotions: [PetEmotion] = []
        let emotionToken = state.$currentEmotion.sink { emotions.append($0) }
        let answer = Task { await assistant.answer(query: "focus") }
        await fulfillment(of: [published], timeout: 3)
        XCTAssertTrue(assistant.isAnswering)
        XCTAssertEqual(state.currentEmotion, .celebrating)
        XCTAssertTrue(emotions.contains(.thinking))
        let request = try XCTUnwrap(http.requests.first { $0.url?.path == "/api/generate" })
        XCTAssertEqual(request.url, OllamaClient.endpoint)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.contentType, "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["format"] as? String, "json")
        XCTAssertEqual(json["model"] as? String, "llama3.1:8b")
        assistant.cancel()
        await answer.value
        XCTAssertFalse(assistant.isAnswering)
        XCTAssertEqual(state.currentEmotion, .idle)
        XCTAssertEqual(state.speechBubbleText, "Answer cancelled.")
        withExtendedLifetime(token) {}
        withExtendedLifetime(emotionToken) {}
    }

    @MainActor
    func testCompleteFencedAnswerCelebratesAndCitesOnlyScopedSource() async throws {
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        let source = try XCTUnwrap(state.documentMemory.chunks.first)
        let line = try speechObject("Focus note extracted.", emotion: "celebrating", ids: [source.id])
        // A full response string in one Ollama record uses the same decoding path.
        let body = try inferenceRecord("```json\n{\"lines\":[\(line)]}\n```", done: true)
        let http = Phase4HTTPHarness(json: body)
        defer { http.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        await assistant.answer(query: "focus")
        XCTAssertEqual(state.speechBubbleText, "Focus note extracted.")
        XCTAssertEqual(state.currentEmotion, .celebrating)
        XCTAssertEqual(assistant.sources, [source])
        XCTAssertFalse(assistant.isAnswering)
    }

    @MainActor
    func testInsufficientEvidenceStaysIdleAndLateStreamErrorClearsAnswer() async throws {
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        let source = try XCTUnwrap(state.documentMemory.chunks.first)
        let insufficient = try speechObject("The supplied notes do not answer it.", emotion: "idle")
        let supported = try speechObject("Focus note extracted.", emotion: "celebrating", ids: [source.id])
        let bodies = [
            try inferenceRecord("{\"lines\":[\(insufficient)]}", done: true),
            try inferenceRecord("{\"lines\":[\(supported)") + "\n{\"error\":\"generation failed\"}\n"
        ]
        for (index, body) in bodies.enumerated() {
            let http = Phase4HTTPHarness(json: body)
            defer { http.cleanUp() }
            let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
            await assistant.answer(query: "focus")
            XCTAssertEqual(state.speechBubbleText, index == 0
                           ? "The supplied notes do not answer it."
                           : LocalInferenceError.generationFailed.localizedDescription)
            XCTAssertEqual(state.currentEmotion, .idle)
            XCTAssertTrue(assistant.sources.isEmpty)
            XCTAssertFalse(assistant.isAnswering)
        }
    }

    @MainActor
    func testCompletedLinesSourcesAndFinalThinkingCleanup() async throws {
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        let source = try XCTUnwrap(state.documentMemory.chunks.first)
        let first = try speechObject("Focus note extracted.", ids: [source.id])
        let second = try speechObject("More evidence.", emotion: "thinking", ids: [source.id])
        let body = try inferenceRecord("{\"lines\":[\(first),") + "\r\n"
            + inferenceRecord("\(second)]}", done: true)
        let http = Phase4HTTPHarness(json: body)
        defer { http.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        await assistant.answer(query: "focus")
        XCTAssertEqual(state.speechBubbleText, "Focus note extracted.\nMore evidence.")
        XCTAssertEqual(state.currentEmotion, .idle)
        XCTAssertFalse(assistant.isAnswering)
        XCTAssertEqual(assistant.sources, [source])
        state.documentMemory.clear()
        XCTAssertTrue(assistant.sources.isEmpty)
        XCTAssertNil(assistant.documentFollowupContext)
        XCTAssertEqual(state.speechBubbleText, "Document notes changed. Ask a new question.")
    }

    @MainActor
    func testCompletedAnswersKeepOriginalQuestionAndOnlyLatestFollowupInContext() async throws {
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        let line = try speechObject("Supported answer")
        let http = Phase4HTTPHarness(json: try inferenceRecord("{\"lines\":[\(line)]}", done: true))
        defer { http.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))

        await assistant.answer(query: "focus")
        let initial = try XCTUnwrap(assistant.documentFollowupContext)
        XCTAssertEqual(initial.sessionID, state.activeSessionID)
        XCTAssertEqual(initial.documentID, state.knowledge.items.first { $0.sourceKind == "session-document" }?.id)
        XCTAssertEqual(initial.originalQuestion, "focus")
        XCTAssertNil(initial.latestFollowup)
        XCTAssertFalse(initial.evidenceChunkIDs.isEmpty)

        func prompt(for request: Phase4HTTPHarness.CapturedRequest) throws -> AssistantJSON {
            let envelope = try JSONDecoder().decode(AssistantJSON.self, from: request.body)
            let prompt = try XCTUnwrap(envelope["prompt"]?.string)
            return try JSONDecoder().decode(AssistantJSON.self, from: Data(prompt.utf8))
        }
        let firstRequest = try XCTUnwrap(http.requests.first { $0.url?.path == "/api/generate" })
        let references = try XCTUnwrap(prompt(for: firstRequest)["referenceNotes"]?.array)
        let sentIDs = references.compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) }
        XCTAssertEqual(sentIDs.count, references.count)
        XCTAssertEqual(initial.evidenceChunkIDs, Set(sentIDs))

        await assistant.answer(query: "how do I start?")
        let second = try XCTUnwrap(assistant.documentFollowupContext)
        XCTAssertEqual(second.originalQuestion, "focus")
        XCTAssertEqual(second.latestFollowup, "how do I start?")

        await assistant.answer(query: "why?")
        let third = try XCTUnwrap(assistant.documentFollowupContext)
        XCTAssertEqual(third.originalQuestion, "focus")
        XCTAssertEqual(third.latestFollowup, "why?")

        await assistant.answer(query: "summarize this")
        let fourth = try XCTUnwrap(assistant.documentFollowupContext)
        XCTAssertEqual(fourth.originalQuestion, "focus")
        XCTAssertEqual(fourth.latestFollowup, "summarize this")

        let requests = http.requests.filter { $0.url?.path == "/api/generate" }
        XCTAssertEqual(requests.count, 4)
        let secondPrompt = try XCTUnwrap(prompt(for: requests[1])["question"]?.string)
        let thirdPrompt = try XCTUnwrap(prompt(for: requests[2])["question"]?.string)
        let fourthPrompt = try XCTUnwrap(prompt(for: requests[3])["question"]?.string)
        XCTAssertEqual(secondPrompt, "focus\nFollow-up: how do I start?")
        XCTAssertEqual(thirdPrompt, "focus\nFollow-up: why?")
        XCTAssertEqual(fourthPrompt, "focus\nFollow-up: summarize this")
    }

    @MainActor
    func testFailedOrCancelledAnswersDoNotCreateFollowupContext() async throws {
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        let failedHTTP = Phase4HTTPHarness(failure: .cannotConnectToHost)
        defer { failedHTTP.cleanUp() }
        let failed = LocalNotesAssistant(state: state, client: try OllamaClient(session: failedHTTP.session))
        await failed.answer(query: "focus")
        XCTAssertNil(failed.documentFollowupContext)
        XCTAssertNil(failed.lastDocumentQuestion)

        let line = try speechObject("A partial answer")
        let openHTTP = Phase4HTTPHarness(json: try inferenceRecord("{\"lines\":[\(line)") + "\n", holdOpen: true)
        defer { openHTTP.cleanUp() }
        let cancelled = LocalNotesAssistant(state: state, client: try OllamaClient(session: openHTTP.session))
        let received = expectation(description: "Partial answer streams before completion")
        let token = state.$speechBubbleText.sink { if $0 == "A partial answer" { received.fulfill() } }
        let task = Task { await cancelled.answer(query: "focus") }
        await fulfillment(of: [received], timeout: 3)
        XCTAssertNil(cancelled.documentFollowupContext)
        cancelled.cancel()
        await task.value
        XCTAssertNil(cancelled.documentFollowupContext)
        XCTAssertNil(cancelled.lastDocumentQuestion)
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testUnscopedReferentialFollowupAsksForDocumentInsteadOfSearchingNewest() async throws {
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        try await state.documentMemory.importDocument(at: documentFixture("Research.pdf"))
        let http = Phase4HTTPHarness(json: "not JSON")
        defer { http.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))

        await assistant.answer(query: "how do I start?")

        await assistant.answer(query: "summarize this")

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertNil(assistant.documentFollowupContext)
        XCTAssertEqual(assistant.retrievalFailure?.localizedDescription,
            DocumentRetrievalError.chooseDocument(state.knowledge.items.filter { $0.sourceKind == "session-document" }.map(\.title).sorted()).localizedDescription)
        XCTAssertTrue(state.speechBubbleText.hasPrefix("Which document do you mean:"))

        await assistant.answer(query: "what about ex2?")
        XCTAssertTrue(http.requests.isEmpty, "A referential exercise follow-up must not select the newest upload")
        XCTAssertTrue(state.speechBubbleText.localizedCaseInsensitiveContains("exercise 2"))
    }

    @MainActor
    func testCloudFollowupContextUpdatesOnlyAfterProviderSuccess() async throws {
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        let line = try speechObject("Cloud answer")
        let success = ScriptedAssistantProvider([
            .turn(.init(text: "{\"lines\":[\(line)]}")),
            .turn(.init(text: "{\"lines\":[\(line)]}"))
        ])
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost)
        defer { http.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))

        _ = try await assistant.answerCloud(query: "focus", provider: success)
        XCTAssertEqual(assistant.documentFollowupContext?.originalQuestion, "focus")
        _ = try await assistant.answerCloud(query: "how do I start?", provider: success)
        XCTAssertEqual(assistant.documentFollowupContext?.originalQuestion, "focus")
        XCTAssertEqual(assistant.documentFollowupContext?.latestFollowup, "how do I start?")
        let requests = await success.requests
        XCTAssertEqual(requests.count, 2)
        let prompt = try XCTUnwrap(requests[1].input.first?["content"]?.string)
        let payload = try JSONDecoder().decode(AssistantJSON.self, from: Data(prompt.utf8))
        XCTAssertEqual(payload["question"]?.string, "focus\nFollow-up: how do I start?")
        let retained = try XCTUnwrap(assistant.documentFollowupContext)

        let failing = ScriptedAssistantProvider([.failure(.service)])
        do {
            _ = try await assistant.answerCloud(query: "why?", provider: failing)
            XCTFail("Failed provider call must not replace follow-up context")
        } catch { XCTAssertEqual(assistant.documentFollowupContext, retained) }

        let delayed = ScriptedAssistantProvider([.delayed(.init(text: "{\"lines\":[\(line)]}"))])
        let task = Task { try await assistant.answerCloud(query: "why?", provider: delayed) }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled provider call must not replace follow-up context")
        } catch { XCTAssertEqual(assistant.documentFollowupContext, retained) }
    }

    @MainActor
    func testLocalAndCloudProvidersReceiveEquivalentSelectedEvidence() async throws {
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        let line = try speechObject("Supported answer")
        let http = Phase4HTTPHarness(json: try inferenceRecord("{\"lines\":[\(line)]}", done: true))
        defer { http.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        await assistant.answer(query: "focus")

        func suppliedIDs(_ prompt: String) throws -> Set<UUID> {
            let payload = try JSONDecoder().decode(AssistantJSON.self, from: Data(prompt.utf8))
            let references = try XCTUnwrap(payload["referenceNotes"]?.array)
            return Set(references.compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) })
        }
        let localRequest = try XCTUnwrap(http.requests.first { $0.url?.path == "/api/generate" })
        let localEnvelope = try JSONDecoder().decode(AssistantJSON.self, from: localRequest.body)
        let localPrompt = try XCTUnwrap(localEnvelope["prompt"]?.string)
        let localIDs = try suppliedIDs(localPrompt)
        XCTAssertFalse(localIDs.isEmpty)

        let cloud = ScriptedAssistantProvider([.turn(.init(text: "{\"lines\":[\(line)]}"))])
        _ = try await assistant.answerCloud(query: "focus", provider: cloud)
        let cloudRequests = await cloud.requests
        let cloudPrompt = try XCTUnwrap(cloudRequests.first?.input.first?["content"]?.string)
        XCTAssertEqual(try suppliedIDs(cloudPrompt), localIDs)
    }

    @MainActor
    func testExplicitExerciseStartsFreshQuestionAndEvidenceWithinRetainedDocument() async throws {
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("AssignmentExercises.docx"))
        let line = try speechObject("Supported answer")
        let http = Phase4HTTPHarness(json: try inferenceRecord("{\"lines\":[\(line)]}", done: true))
        defer { http.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))

        await assistant.answer(query: "what does ex1?")
        let firstContext = try XCTUnwrap(assistant.documentFollowupContext)
        await assistant.answer(query: "how do I start?")
        XCTAssertEqual(assistant.documentFollowupContext?.originalQuestion, firstContext.originalQuestion)
        XCTAssertEqual(assistant.documentFollowupContext?.latestFollowup, "how do I start?")

        await assistant.answer(query: "what about ex2?")

        let replacement = try XCTUnwrap(assistant.documentFollowupContext)
        XCTAssertEqual(replacement.originalQuestion, "what about ex2?")
        XCTAssertNil(replacement.latestFollowup)
        let requests = http.requests.filter { $0.url?.path == "/api/generate" }
        XCTAssertEqual(requests.count, 3)
        let envelope = try JSONDecoder().decode(AssistantJSON.self, from: requests[2].body)
        let prompt = try XCTUnwrap(envelope["prompt"]?.string)
        let payload = try JSONDecoder().decode(AssistantJSON.self, from: Data(prompt.utf8))
        XCTAssertEqual(payload["question"]?.string, "what about ex2?")
        XCTAssertFalse(payload["question"]?.string?.contains("what does ex1?") ?? true)
        let references = try XCTUnwrap(payload["referenceNotes"]?.array)
        XCTAssertTrue(references.contains { $0["text"]?.string?.localizedCaseInsensitiveContains("triangle") == true })
    }

    @MainActor
    func testNoMatchNeverContactsOllamaAndErrorsClearThinking() async throws {
        let http = Phase4HTTPHarness(json: "not JSON")
        defer { http.cleanUp() }
        let state = PetApplicationState()
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        await assistant.answer(query: "orchid")
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(state.speechBubbleText, LocalInferenceError.noRelevantContext.localizedDescription)
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        await assistant.answer(query: "focus")
        XCTAssertEqual(state.speechBubbleText, LocalInferenceError.malformedResponse.localizedDescription)
        XCTAssertEqual(state.currentEmotion, .idle)
        XCTAssertFalse(assistant.isAnswering)
        XCTAssertTrue(assistant.sources.isEmpty)
    }

    @MainActor
    func testClearCancelsOpenStreamAndStaleResultCannotOverwriteNewQuestion() async throws {
        let line = try speechObject("First answer")
        let http = Phase4HTTPHarness(json: try inferenceRecord("{\"lines\":[\(line)") + "\n", holdOpen: true)
        defer { http.cleanUp() }
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let published = expectation(description: "First answer streaming")
        let token = state.$speechBubbleText.sink { if $0 == "First answer" { published.fulfill() } }
        let firstAnswer = Task { await assistant.answer(query: "focus") }
        await fulfillment(of: [published], timeout: 3)
        state.documentMemory.clear()
        await assistant.answer(query: "unrelated")
        await firstAnswer.value
        XCTAssertEqual(state.speechBubbleText, LocalInferenceError.noRelevantContext.localizedDescription)
        XCTAssertFalse(assistant.isAnswering)
        XCTAssertEqual(state.currentEmotion, .idle)
        XCTAssertTrue(assistant.sources.isEmpty)
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testParentCancellationStopsOpenStream() async throws {
        let http = Phase4HTTPHarness(json: "", holdOpen: true)
        defer { http.cleanUp() }
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let started = expectation(description: "Request reaches transport")
        let token = state.$speechBubbleText.sink { if $0 == "Reading local notes…" { started.fulfill() } }
        let answer = Task { await assistant.answer(query: "focus") }
        await fulfillment(of: [started], timeout: 3)
        answer.cancel()
        await answer.value
        XCTAssertEqual(state.speechBubbleText, "Answer cancelled.")
        XCTAssertFalse(assistant.isAnswering)
        XCTAssertEqual(state.currentEmotion, .idle)
        withExtendedLifetime(token) {}
    }
}
