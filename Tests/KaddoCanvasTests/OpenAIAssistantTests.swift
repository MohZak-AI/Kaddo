import XCTest
@testable import KaddoCanvas

final class OpenAIAssistantTests: XCTestCase {
    private func response(_ text: String) throws -> String {
        try AssistantJSON.object(["status": .string("completed"), "error": .null,
            "output": .array([.object(["type": .string("message"), "role": .string("assistant"),
                "content": .array([.object(["type": .string("output_text"), "text": .string(text)])])])])]).jsonString()
    }

    func testResponsesRequestUsesStrictSequentialToolsAndNoStoredConversation() async throws {
        let http = Phase4HTTPHarness(json: try response("Hello\n\n2 / 3")); defer { http.cleanUp() }
        let provider = OpenAIAssistantProvider(apiKey: "test-personal-key", session: http.session)
        let turn = try await provider.respond(to: .init(instructions: "General assistant", input: [.message("hi")]))
        XCTAssertEqual(turn.text, "Hello\n\n2 / 3")
        XCTAssertEqual(http.requests.count, 1)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.method, "POST")
        let body = try JSONDecoder().decode(AssistantJSON.self, from: request.body)
        XCTAssertEqual(body["store"], .bool(false)); XCTAssertEqual(body["parallel_tool_calls"], .bool(false))
        XCTAssertEqual(body["model"], .string("gpt-6.1-sol"))
        XCTAssertEqual(body["reasoning"]?["effort"], .string("low"))
        XCTAssertFalse(try body.jsonString().contains("test-personal-key"))
        let tools = try XCTUnwrap(body["tools"]?.array)
        XCTAssertEqual(tools.count, KaddoToolName.allCases.count)
        for tool in tools {
            XCTAssertEqual(tool["strict"], .bool(true))
            let parameters = try XCTUnwrap(tool["parameters"])
            XCTAssertEqual(parameters["additionalProperties"], .bool(false))
            XCTAssertEqual(Set(parameters["required"]!.array!.compactMap(\.string)), Set(parameters["properties"]!.object!.keys))
        }
    }

    func testTypedToolCallAndReasoningArePreservedForContinuation() async throws {
        let call = AssistantJSON.object(["type": .string("function_call"), "status": .string("completed"),
            "call_id": .string("call_1"), "name": .string("timer"),
            "arguments": .string(#"{"minutes":25,"text":null}"#)])
        let reasoning = AssistantJSON.object(["type": .string("reasoning"), "id": .string("rs_1"), "summary": .array([])])
        let body = try AssistantJSON.object(["status": .string("completed"), "output": .array([reasoning, call])]).jsonString()
        let http = Phase4HTTPHarness(json: body); defer { http.cleanUp() }
        let result = try await OpenAIAssistantProvider(apiKey: "test", session: http.session)
            .respond(to: .init(instructions: "Tools", input: [.message("Start a timer")]))
        XCTAssertEqual(result.calls.first?.name, .timer)
        XCTAssertEqual(result.calls.first?.arguments.minutes, 25)
        XCTAssertEqual(result.output, [reasoning, call])
    }

    func testMalformedUnknownIncompleteAndDisabledToolsAreRejectedBeforeDispatch() throws {
        for (name, arguments) in [("destroy", "{}"), ("timer", #"{"minutes":"25"}"#),
                                   ("task", #"{"text":"x","shell":"rm"}"#), ("focus", #"{"id":"not-a-uuid"}"#)] {
            let object = try JSONDecoder().decode(AssistantJSON.self, from: Data(arguments.utf8))
            XCTAssertThrowsError(try KaddoToolCall(id: "x", name: name, arguments: object))
        }
        let call = AssistantJSON.object(["type": .string("function_call"), "status": .string("completed"),
            "call_id": .string("x"), "name": .string("task"), "arguments": .string(#"{"text":"x"}"#)])
        let data = try JSONEncoder().encode(AssistantJSON.object(["status": .string("completed"), "output": .array([call])]))
        XCTAssertThrowsError(try OpenAIAssistantProvider.decode(data, toolsEnabled: false))
        let incomplete = try JSONEncoder().encode(AssistantJSON.object(["status": .string("incomplete"), "output": .array([call])]))
        XCTAssertThrowsError(try OpenAIAssistantProvider.decode(incomplete, toolsEnabled: true))
        let multiple = try JSONEncoder().encode(AssistantJSON.object(["status": .string("completed"), "output": .array([call, call])]))
        XCTAssertThrowsError(try OpenAIAssistantProvider.decode(multiple, toolsEnabled: true))
        XCTAssertThrowsError(try OpenAIAssistantProvider.decode(Data("broken".utf8), toolsEnabled: true))
        XCTAssertThrowsError(try OpenAIAssistantProvider.decode(Data(response(String(repeating: "x", count: 12001)).utf8), toolsEnabled: true))
    }

    func testErrorsDoNotExposeProviderBodyOrCredentials() async throws {
        for (status, expected) in [(401, AssistantError.authentication), (403, .authentication), (404, .unavailableModel), (429, .rateLimited), (500, .service)] {
            let http = Phase4HTTPHarness(status: status, json: "sensitive service body"); defer { http.cleanUp() }
            do {
                _ = try await OpenAIAssistantProvider(apiKey: "test", session: http.session)
                    .respond(to: .init(instructions: "x", input: [.message("hello")]))
                XCTFail("Expected failure")
            } catch {
                XCTAssertEqual(error as? AssistantError, expected)
                XCTAssertFalse(error.localizedDescription.contains("sensitive"))
            }
        }
        let http = Phase4HTTPHarness(json: "unused"); defer { http.cleanUp() }
        do {
            _ = try await OpenAIAssistantProvider(apiKey: "", session: http.session)
                .respond(to: .init(instructions: "x", input: [.message("hello")]))
            XCTFail("Expected missing key")
        } catch { XCTAssertEqual(error as? AssistantError, .missingKey) }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testNetworkCancellationStopsCloudResponse() async throws {
        let http = Phase4HTTPHarness(json: "", holdOpen: true); defer { http.cleanUp() }
        let provider = OpenAIAssistantProvider(apiKey: "test", session: http.session)
        let task = Task { try await provider.respond(to: .init(instructions: "x", input: [.message("hi")])) }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testSettingsUseCredentialBoundaryAndPersistOnlyPreferences() throws {
        let suite = "KaddoTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryAssistantCredentialStore()
        let settings = AssistantSettings(credentials: credentials, defaults: defaults)
        XCTAssertEqual(settings.provider, .ollama)
        settings.saveKey("test-private-key")
        XCTAssertEqual(settings.provider, .openAI); XCTAssertTrue(settings.hasKey)
        XCTAssertEqual(try credentials.read(), "test-private-key")
        settings.cloudModel = "gpt-6.1-sol"
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { String(describing: $0).contains("test-private-key") })
        let restored = AssistantSettings(credentials: credentials, defaults: defaults)
        XCTAssertEqual(restored.provider, .openAI); XCTAssertTrue(restored.hasKey)
        settings.removeKey(); XCTAssertNil(try credentials.read()); XCTAssertFalse(settings.hasKey)
        XCTAssertEqual(settings.provider, .openAI, "Removing a key does not silently switch providers")
    }

    @MainActor
    func testConnectionTestUsesSelectedModelAndShowsActionableResult() async throws {
        let settings = AssistantSettings(credentials: MemoryAssistantCredentialStore(key: "test"))
        let provider = ScriptedAssistantProvider([.turn(.init(text: "OK"))])
        settings.testConnection(provider: provider)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(settings.isTesting); XCTAssertTrue(settings.status.contains("Connected to OpenAI"))
        let requests = await provider.requests
        XCTAssertFalse(requests[0].toolsEnabled)
        let failure = ScriptedAssistantProvider([.failure(.authentication)])
        settings.testConnection(provider: failure)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(settings.status.contains("authenticate"))
    }

    @MainActor
    func testCloudDocumentsUseOnlySelectedExcerptsWithValidatedCitations() async throws {
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("FocusNotes.docx"))
        state.createSession(title: "Research")
        try await state.documentMemory.importDocument(at: documentFixture("Research.pdf"))
        let source = try XCTUnwrap(state.documentMemory.chunks.first)
        let line = try speechObject("Water weekly.", emotion: "celebrating", ids: [source.id])
        let provider = ScriptedAssistantProvider([.turn(.init(text: "{\"lines\":[\(line)]}"))])
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost); defer { http.cleanUp() }
        let notes = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let answer = try await notes.answerCloud(query: "orchid", provider: provider)
        XCTAssertEqual(answer, "Water weekly."); XCTAssertEqual(notes.sources, [source])
        let requests = await provider.requests
        XCTAssertFalse(requests[0].toolsEnabled)
        let payload = try XCTUnwrap(requests[0].input[0]["content"]?.string)
        XCTAssertTrue(payload.contains("Research.pdf")); XCTAssertFalse(payload.contains("FocusNotes.docx"))
        let json = try JSONDecoder().decode(AssistantJSON.self, from: Data(payload.utf8))
        let excerpts = try XCTUnwrap(json["referenceNotes"]?.array)
        XCTAssertLessThanOrEqual(excerpts.reduce(0) { $0 + ($1["text"]?.string?.count ?? 0) }, 6000)
        XCTAssertTrue(http.requests.isEmpty, "Cloud mode does not contact Ollama")
        state.createSession(title: "Empty session")
        do { _ = try await notes.answerCloud(query: "orchid", provider: provider); XCTFail("Expected no context") }
        catch { XCTAssertEqual(notes.lastOutcome?.kind, "needsInput"); XCTAssertTrue(error is DocumentRetrievalError) }
        let afterEmpty = await provider.requests
        XCTAssertEqual(afterEmpty.count, 1, "An empty selected session never falls back to another session")
    }

    @MainActor
    func testCloudDocumentUnknownCitationAndContextChangeDiscardResults() async throws {
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("Research.pdf"))
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost); defer { http.cleanUp() }
        let notes = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let badLine = try speechObject("Invented fact.", emotion: "happy", ids: [UUID()])
        let bad = ScriptedAssistantProvider([.turn(.init(text: "{\"lines\":[\(badLine)]}"))])
        do { _ = try await notes.answerCloud(query: "orchid", provider: bad); XCTFail("Expected citation failure") }
        catch { XCTAssertTrue(notes.sources.isEmpty) }
        let source = state.documentMemory.chunks[0]
        let line = try speechObject("Old answer", emotion: "happy", ids: [source.id])
        let delayed = ScriptedAssistantProvider([.delayed(.init(text: "{\"lines\":[\(line)]}"))])
        let task = Task { try await notes.answerCloud(query: "orchid", provider: delayed) }
        try await Task.sleep(for: .milliseconds(20))
        state.createSession(title: "Other")
        do { _ = try await task.value; XCTFail("Expected stale context cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(notes.sources.isEmpty)
        XCTAssertFalse(state.speechBubbleText.contains("Old answer"))
    }
}
