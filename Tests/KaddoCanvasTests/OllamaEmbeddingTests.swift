import XCTest
@testable import KaddoCanvas

final class OllamaEmbeddingTests: XCTestCase {
    private let catalog = #"{"models":[{"name":"embeddinggemma:latest","digest":"abc123"}]}"#
    func testLoopbackConfigurationAndInputBounds() async throws {
        for url in ["https://example.com/api/embed", "http://192.168.1.1:11434/api/embed", "http://localhost:11434/api/generate", "http://user@localhost:11434/api/embed", "http://localhost:11434/api/embed?q=x"] {
            XCTAssertThrowsError(try OllamaEmbeddingProvider(endpoint: URL(string: url)!))
        }
        XCTAssertThrowsError(try OllamaEmbeddingProvider(model: "private:cloud"))
        let config = OllamaEmbeddingProvider.configuration()
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertEqual(config.connectionProxyDictionary?.count, 0)
        let http = Phase4HTTPHarness(json: "{}")
        defer { http.cleanUp() }
        let provider = try OllamaEmbeddingProvider(session: http.session)
        do { _ = try await provider.embeddings(for: [String(repeating: "x", count: 1_601)]); XCTFail("Oversized input accepted") } catch { }
        XCTAssertTrue(http.requests.isEmpty)
    }
    func testPreflightDigestAndTruncateFalseRequest() async throws {
        let http = Phase4HTTPHarness(json: #"{"embeddings":[[1,0],[0,1]]}"#, modelCatalog: catalog)
        defer { http.cleanUp() }
        let provider = try OllamaEmbeddingProvider(session: http.session)
        let identity = try await provider.modelIdentity()
        XCTAssertEqual(identity, "ollama:embeddinggemma:abc123")
        let vectors = try await provider.embeddings(for: ["private fact one", "private fact two"])
        XCTAssertEqual(vectors, [[1,0],[0,1]])
        let embed = try XCTUnwrap(http.requests.last)
        XCTAssertEqual(embed.url?.path, "/api/embed")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: embed.body) as? [String: Any])
        XCTAssertEqual(body["truncate"] as? Bool, false)
        XCTAssertEqual(body["input"] as? [String], ["private fact one", "private fact two"])
        XCTAssertTrue(http.requests.dropLast().allSatisfy { !String(decoding: $0.body, as: UTF8.self).contains("private fact") })
    }
    func testRemoteAliasRejectedBeforeTextAndMalformedVectorsRejected() async throws {
        for metadata in [#"{"remote_host":"https://ollama.com","model_info":{"general.architecture":"gemma"}}"#, #"{"model_info":{}}"#] {
            let http = Phase4HTTPHarness(json: #"{"embeddings":[[1,0]]}"#, modelMetadata: metadata, modelCatalog: catalog)
            defer { http.cleanUp() }
            do { _ = try await OllamaEmbeddingProvider(session: http.session).embeddings(for: ["PRIVATE"]); XCTFail("Cloud alias accepted") }
            catch { XCTAssertEqual(error as? LocalInferenceError, .remoteModel) }
            XCTAssertFalse(http.requests.contains { $0.url?.path == "/api/embed" })
        }
        for response in [#"{"embeddings":[[0,0]]}"#, #"{"embeddings":[[1],[1,2]]}"#, #"{"embeddings":[]}"#, #"{"embeddings":[[1e999,2]]}"#] {
            let http = Phase4HTTPHarness(json: response, modelCatalog: catalog)
            defer { http.cleanUp() }
            do { _ = try await OllamaEmbeddingProvider(session: http.session).embeddings(for: ["fact"]); XCTFail("Invalid vectors accepted") }
            catch { XCTAssertEqual(error as? KnowledgeError, .invalidEmbedding) }
        }
    }
    func testRemoteCatalogAndHTTPFailuresNeverSendText() async throws {
        let remote = Phase4HTTPHarness(json: "{}", modelCatalog: #"{"models":[{"name":"embeddinggemma:latest","remote_model":"secret-cloud"}]}"#)
        defer { remote.cleanUp() }
        do { _ = try await OllamaEmbeddingProvider(session: remote.session).embeddings(for: ["PRIVATE"]); XCTFail("Remote catalog accepted") }
        catch { XCTAssertEqual(error as? LocalInferenceError, .remoteModel) }
        XCTAssertEqual(remote.requests.count, 1)
        let http = Phase4HTTPHarness(status: 302, json: "{}")
        defer { http.cleanUp() }
        do { _ = try await OllamaEmbeddingProvider(session: http.session).embeddings(for: ["PRIVATE"]); XCTFail("Redirect accepted") }
        catch { XCTAssertEqual(error as? LocalInferenceError, .httpStatus(302)) }
        XCTAssertEqual(http.requests.count, 1)
    }
}
