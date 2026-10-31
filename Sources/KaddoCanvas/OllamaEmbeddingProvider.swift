import Foundation

/// Uses only the local Ollama embedding endpoint. Metadata is checked before text leaves the process.
public final class OllamaEmbeddingProvider: KnowledgeEmbeddingProvider, Sendable {
    public static let endpoint = URL(string: "http://localhost:11434/api/embed")!
    public let identity: String
    public let model: String
    private let endpoint: URL
    private let session: URLSession
    private let redirects = RejectEmbeddingRedirects()

    public init(model: String = "embeddinggemma", endpoint: URL = OllamaEmbeddingProvider.endpoint,
                session: URLSession? = nil) throws {
        guard endpoint.scheme == "http", ["localhost", "127.0.0.1", "[::1]", "::1"].contains(endpoint.host ?? ""),
              endpoint.port == 11434, endpoint.path == "/api/embed", endpoint.user == nil,
              endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.lowercased().contains("cloud"), model.count <= 200 else {
            throw LocalInferenceError.invalidConfiguration
        }
        self.model = model; self.endpoint = endpoint; self.identity = "ollama:\(model)"
        self.session = session ?? URLSession(configuration: Self.configuration())
    }
    public static func configuration() -> URLSessionConfiguration {
        let config = OllamaClient.configuration()
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        return config
    }
    public func modelIdentity() async throws -> String {
        struct Catalog: Decodable {
            struct Model: Decodable {
                let name: String
                let digest: String?
                let remote_host: String?
                let remote_model: String?
            }
            let models: [Model]
        }
        let data = try await read(request("tags"), maximum: 1_024 * 1_024)
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              let installed = catalog.models.first(where: { $0.name == model || $0.name == model + ":latest" }) else {
            throw LocalInferenceError.modelUnavailable
        }
        guard (installed.remote_host ?? "").isEmpty, (installed.remote_model ?? "").isEmpty,
              !installed.name.lowercased().contains("cloud") else { throw LocalInferenceError.remoteModel }
        var show = request("show")
        show.httpMethod = "POST"
        show.httpBody = try JSONEncoder().encode(["model": model])
        let metadata = try await read(show, maximum: 1_024 * 1_024)
        guard let object = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any] else {
            throw LocalInferenceError.malformedResponse
        }
        for key in ["remote_host", "remote_model"] {
            if let value = object[key], !(value is NSNull), (value as? String) != "" {
                throw LocalInferenceError.remoteModel
            }
        }
        guard let info = object["model_info"] as? [String: Any],
              let architecture = info["general.architecture"] as? String, !architecture.isEmpty else {
            throw LocalInferenceError.remoteModel
        }
        // Digest changes under a stable tag invalidate all existing vectors.
        return identity + ":" + (installed.digest ?? "unversioned")
    }
    public func embeddings(for texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty, texts.count <= 32,
              texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 1_600 }) else {
            throw KnowledgeError.invalidInput
        }
        _ = try await modelIdentity()
        try Task.checkCancellation()
        struct Body: Encodable { let model: String; let input: [String]; let truncate = false }
        var request = request("embed")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(Body(model: model, input: texts))
        guard (request.httpBody?.count ?? 0) <= 256 * 1_024 else { throw KnowledgeError.invalidInput }
        let data = try await read(request, maximum: 2 * 1_024 * 1_024)
        struct Response: Decodable { let embeddings: [[Float]] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw KnowledgeError.invalidEmbedding }
        _ = try validateKnowledgeVectors(response.embeddings, count: texts.count)
        return response.embeddings
    }
    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: endpoint.deletingLastPathComponent().appendingPathComponent(path), timeoutInterval: 60)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
    private func read(_ request: URLRequest, maximum: Int) async throws -> Data {
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw LocalInferenceError.malformedResponse }
            guard response.statusCode == 200 else {
                if response.statusCode == 404 { throw LocalInferenceError.modelUnavailable }
                throw LocalInferenceError.httpStatus(response.statusCode)
            }
            if response.expectedContentLength > maximum { throw LocalInferenceError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximum else { throw LocalInferenceError.responseTooLarge }
                data.append(byte)
            }
            return data
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw LocalInferenceError.serviceUnavailable
        }
    }
}

private final class RejectEmbeddingRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
