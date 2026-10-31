import XCTest
@testable import KaddoCanvas

final class OllamaClientTests: XCTestCase {
    func testLocalEndpointAndEphemeralConfiguration() throws {
        _ = try OllamaClient()
        XCTAssertEqual(OllamaClient.endpoint.absoluteString, "http://localhost:11434/api/generate")
        let configuration = OllamaClient.configuration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 120)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 180)
    }

    func testRejectsOtherDestinations() {
        for address in ["https://example.com/api/generate", "http://192.168.1.1:11434/api/generate",
                        "http://localhost:11434/api/chat", "http://localhost:80/api/generate",
                        "http://user@localhost:11434/api/generate", "http://localhost:11434/api/generate?q=x"] {
            XCTAssertThrowsError(try OllamaClient(endpoint: URL(string: address)!))
        }
    }

    func testRequestEncodingUsesStreamingJSON() throws {
        let request = OllamaGenerateRequest(model: "llama3.1:8b", system: "Rules", prompt: "Notes")
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["think"] as? Bool, false)
        XCTAssertEqual(json["format"] as? String, "json")
        XCTAssertEqual(json["system"] as? String, "Rules")
        XCTAssertEqual(json["model"] as? String, "llama3.1:8b")
    }
    func testHTTPAndTransportErrorsAreLocalized() async throws {
        let request = OllamaGenerateRequest(model: "test", system: "rules", prompt: "notes")
        for status in [302, 404, 500, 503] {
            let http = Phase4HTTPHarness(status: status, json: "{}")
            defer { http.cleanUp() }
            do {
                try await OllamaClient(session: http.session).generate(request) { _ in }
                XCTFail("HTTP error accepted")
            } catch {
                XCTAssertEqual(error as? LocalInferenceError,
                               status == 404 ? .modelUnavailable : .httpStatus(status))
            }
        }
        for code in [URLError.cannotConnectToHost, .timedOut, .cancelled] {
            let http = Phase4HTTPHarness(failure: code)
            defer { http.cleanUp() }
            do {
                try await OllamaClient(session: http.session).generate(request) { _ in }
                XCTFail("Transport failure accepted")
            } catch {
                if code == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? LocalInferenceError, .serviceUnavailable) }
            }
        }
    }

    func testOversizedWireRecordIsRejected() async throws {
        let request = OllamaGenerateRequest(model: "test", system: "rules", prompt: "notes")
        let http = Phase4HTTPHarness(json: String(repeating: "x", count: 128 * 1_024 + 1))
        defer { http.cleanUp() }
        do {
            try await OllamaClient(session: http.session).generate(request) { _ in }
            XCTFail("Unbounded wire record accepted")
        } catch { XCTAssertEqual(error as? LocalInferenceError, .responseTooLarge) }
    }

    func testRemoteModelsAndAliasesNeverReceivePromptData() async throws {
        for metadata in [
            #"{"remote_host":"https://ollama.com","remote_model":"remote","model_info":{}}"#,
            #"{"remote_host":"https://ollama.com","model_info":{"general.architecture":"llama"}}"#,
            #"{"model_info":{}}"#
        ] {
            let http = Phase4HTTPHarness(json: "", modelMetadata: metadata)
            defer { http.cleanUp() }
            let request = OllamaGenerateRequest(model: "innocent-alias", system: "rules", prompt: "PRIVATE NOTE")
            do {
                try await OllamaClient(session: http.session).generate(request) { _ in }
                XCTFail("Remote inference accepted")
            } catch { XCTAssertEqual(error as? LocalInferenceError, .remoteModel) }
            XCTAssertEqual(http.requests.count, 1)
            XCTAssertEqual(http.requests.first?.url?.path, "/api/show")
            XCTAssertFalse(String(decoding: http.requests[0].body, as: UTF8.self).contains("PRIVATE NOTE"))
        }
    }

    func testDiscoverySelectsInstalledLocalModelsAndExcludesCloudAliases() async throws {
        let catalog = #"{"models":[{"name":"qwen3.5:4b"},{"name":"cloud-alias","remote_host":"https://ollama.com"},{"name":"other-alias","remote_model":"remote"},{"name":"qwen3.5:4b"},{"name":" "},{"name":"local:small","remote_host":null}]}"#
        let http = Phase4HTTPHarness(json: catalog)
        defer { http.cleanUp() }
        let names = try await OllamaClient(session: http.session).localModelNames()
        XCTAssertEqual(names, ["local:small", "qwen3.5:4b"])
        XCTAssertEqual(http.requests.count, 3)
        XCTAssertEqual(http.requests.first?.url?.absoluteString, "http://localhost:11434/api/tags")
        XCTAssertEqual(http.requests.first?.method, "GET")
        XCTAssertTrue(http.requests[0].body.isEmpty)
    }

    func testDiscoveryExcludesEmbeddingCapabilitiesAndOlderEmbeddingNames() async throws {
        let catalog = #"{"models":[{"name":"embeddinggemma:latest"},{"name":"qwen3.5:4b"}]}"#
        for metadata in [#"{"capabilities":["embedding"],"model_info":{"general.architecture":"gemma-embedding"}}"#,
                         #"{"model_info":{"general.architecture":"llama"}}"#] {
            let http = Phase4HTTPHarness(json: catalog, modelMetadata: metadata)
            defer { http.cleanUp() }
            let names = try await OllamaClient(session: http.session).localModelNames()
            XCTAssertFalse(names.contains("embeddinggemma:latest"))
            if !metadata.contains("capabilities") { XCTAssertEqual(names, ["qwen3.5:4b"]) }
            else { XCTAssertTrue(names.isEmpty) }
        }
    }

    func testDiscoveryHandlesEmptyAndMalformedCatalogs() async throws {
        for body in [#"{"models":[]}"#, #"{"models":[{"name":"cloud","remote_model":"cloud"}]}"#] {
            let http = Phase4HTTPHarness(json: body)
            defer { http.cleanUp() }
            let names = try await OllamaClient(session: http.session).localModelNames()
            XCTAssertTrue(names.isEmpty)
        }
        let http = Phase4HTTPHarness(json: "{}")
        defer { http.cleanUp() }
        do {
            _ = try await OllamaClient(session: http.session).localModelNames()
            XCTFail("Invalid catalog accepted")
        } catch { XCTAssertEqual(error as? LocalInferenceError, .malformedResponse) }
    }

    func testDiscoveryReportsUnavailableService() async throws {
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost)
        defer { http.cleanUp() }
        do {
            _ = try await OllamaClient(session: http.session).localModelNames()
            XCTFail("Connection error ignored")
        } catch { XCTAssertEqual(error as? LocalInferenceError, .serviceUnavailable) }
    }

}
