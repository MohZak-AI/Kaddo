import XCTest
@testable import KaddoCanvas

final class DeepSeekAssistantTests: XCTestCase {
    func testDeepSeekUsesFixedEndpointAndExistingResponseValidation() async throws {
        let json = #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}"#
        let http = Phase4HTTPHarness(json: json); defer { http.cleanUp() }
        let provider = OpenAIAssistantProvider(apiKey: "test-deepseek-key", model: "deepseek-flash",
                                             session: http.session, service: .deepSeek)
        let turn = try await provider.respond(to: .init(instructions: "Reply OK", input: [.message("test")], toolsEnabled: false))
        XCTAssertEqual(turn.text, "OK")
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/responses")
        let body = try JSONDecoder().decode(AssistantJSON.self, from: request.body)
        XCTAssertEqual(body["model"], .string("deepseek-flash"))
        XCTAssertEqual(body["reasoning"]?["effort"], .string("none"))
        XCTAssertEqual(body["tools"], .array([]))
        XCTAssertFalse(try body.jsonString().contains("test-deepseek-key"))
    }

    func testJSONModeAddsAnExplicitJSONInstructionForClarifications() async throws {
        let json = #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"resolved\":false}"}]}]}"#
        let http = Phase4HTTPHarness(json: json); defer { http.cleanUp() }
        for service: OpenAIAssistantProvider.Service in [.openAI, .deepSeek] {
            _ = try await OpenAIAssistantProvider(apiKey: "test", session: http.session, service: service)
                .respond(to: .init(instructions: "Resolve the pending date. Return {\"resolved\":false} for unrelated replies.",
                    input: [.message("2026-11-09")], toolsEnabled: false, responseFormat: .jsonObject))
            let body = try JSONDecoder().decode(AssistantJSON.self, from: XCTUnwrap(http.requests.last).body)
            XCTAssertTrue(body["instructions"]?.string?.localizedCaseInsensitiveContains("JSON") == true)
            XCTAssertEqual(body["text"]?["format"]?["type"], .string("json_object"))
            XCTAssertEqual(body["tools"], .array([]))
        }
    }

    @MainActor
    func testCredentialsAndModelsStaySeparateWhenSwitchingProviders() throws {
        let suite = "KaddoTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let openAI = MemoryAssistantCredentialStore(key: "openai-test")
        let deepSeek = MemoryAssistantCredentialStore()
        let settings = AssistantSettings(credentials: openAI, defaults: defaults, deepSeekCredentials: deepSeek)
        settings.provider = .deepSeek
        XCTAssertFalse(settings.hasKey)
        XCTAssertEqual(settings.cloudModel, "deepseek-flash")
        settings.saveKey("deepseek-test")
        settings.cloudModel = "deepseek-v4-pro"
        settings.provider = .openAI
        XCTAssertTrue(settings.hasKey)
        XCTAssertEqual(settings.cloudModel, "gpt-6.1-sol")
        settings.provider = .deepSeek
        XCTAssertEqual(settings.cloudModel, "deepseek-v4-pro")
        settings.removeKey()
        XCTAssertNil(try deepSeek.read())
        XCTAssertEqual(try openAI.read(), "openai-test")
    }

    @MainActor
    func testTemporaryFileCredentialsArePrivateAndRemovable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("key")
        let store = FileAssistantCredentialStore(url: url)
        XCTAssertNil(try store.read())
        try store.save("temporary-test-key")
        XCTAssertEqual(try store.read(), "temporary-test-key")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.remove()
        XCTAssertNil(try store.read())
    }

    /// Explicit opt-in: sends only synthetic prompts and never executes the returned tool.
    @MainActor
    func testLiveDeepSeekReplyToolContinuationAndJSON() async throws {
        guard ProcessInfo.processInfo.environment["KADDO_TEST_DEEPSEEK"] == "1" else {
            throw XCTSkip("Set KADDO_TEST_DEEPSEEK=1 to use the configured local credential.")
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.kaddo.canvas"))
        let credentials: any AssistantCredentialStore
        if let temporaryKey = ProcessInfo.processInfo.environment["KADDO_DEEPSEEK_TEST_KEY"] {
            credentials = MemoryAssistantCredentialStore(key: temporaryKey)
        } else {
            credentials = FileAssistantCredentialStore(url: FileAssistantCredentialStore.deepSeekURL)
        }
        let settings = AssistantSettings(credentials: MemoryAssistantCredentialStore(), defaults: defaults,
            deepSeekCredentials: credentials)
        XCTAssertEqual(settings.provider, .deepSeek)
        let provider = try settings.cloudProvider()
        let reply = try await provider.respond(to: .init(instructions: "Reply with exactly OK.", input: [.message("Connection test")], toolsEnabled: false))
        XCTAssertEqual(reply.text.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
        print("DeepSeek live reply: OK")

        let prompt: [AssistantJSON] = [.message("Start a 25 minute timer. Use the timer tool.")]
        let tool = try await provider.respond(to: .init(instructions: "Call the timer tool once with minutes 25 and text null.", input: prompt, allowedTools: [.timer]))
        let call = try XCTUnwrap(tool.calls.first)
        XCTAssertEqual(call.name, .timer)
        XCTAssertEqual(call.arguments.minutes, 25)
        let result = AssistantJSON.object(["type": .string("function_call_output"), "call_id": .string(call.id), "output": .string("Synthetic test: timer started successfully. No real timer was created.")])
        let continuation = try await provider.respond(to: .init(instructions: "The synthetic tool test finished. Reply with exactly TIMER_OK and call no tools.", input: prompt + tool.output + [result], toolsEnabled: false))
        XCTAssertEqual(continuation.text.trimmingCharacters(in: .whitespacesAndNewlines), "TIMER_OK")
        print("DeepSeek live validated timer call and continuation: OK")

        let json = try await provider.respond(to: .init(instructions: "Return JSON only: {\"ok\":true}", input: [.message("JSON test")], toolsEnabled: false, responseFormat: .jsonObject))
        let object = try JSONDecoder().decode(AssistantJSON.self, from: Data(json.text.utf8))
        XCTAssertEqual(object["ok"], .bool(true))
        print("DeepSeek live JSON output: OK")
    }
}
