import Foundation

public enum LocalInferenceError: Error, LocalizedError, Equatable {
    case invalidConfiguration, noRelevantContext, ambiguousDocumentReference, invalidQuery, malformedResponse, responseTooLarge
    case httpStatus(Int), modelUnavailable, serviceUnavailable, generationFailed, remoteModel

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Use an installed model and the local Ollama generate endpoint."
        case .noRelevantContext: "No matching notes. Drop a document or try more specific keywords."
        case .ambiguousDocumentReference: "That exercise number appears in multiple uploaded documents. Include the filename in your question."
        case .invalidQuery: "Enter a question of at most 2,000 characters."
        case .malformedResponse: "The local model returned invalid or incomplete JSON. Try again."
        case .responseTooLarge: "The local model response exceeded the allowed size."
        case .httpStatus(let status): "Ollama returned HTTP \(status)."
        case .modelUnavailable: "The selected model is not installed in Ollama."
        case .serviceUnavailable: "Cannot reach Ollama. Start Ollama locally and try again."
        case .remoteModel: "Choose a locally installed model. Cloud models cannot receive document notes."
        case .generationFailed: "Ollama could not finish this answer. Try again."
        }
    }
}

public struct OllamaGenerateRequest: Encodable, Sendable {
    public let model: String
    public let system: String
    public let prompt: String
    public let stream = true
    public let think = false
    public let format = "json"
    public let options = Options()

    public struct Options: Encodable, Sendable {
        public let temperature = 0
        public let num_predict = 2_048
        public let num_ctx = 16_384
    }

    public init(model: String, system: String, prompt: String) {
        self.model = model
        self.system = system
        self.prompt = prompt
    }
}

/// Native, ephemeral HTTP streaming. Context is never cached or redirected to another host.
public final class OllamaClient: Sendable {
    public static let endpoint = URL(string: "http://localhost:11434/api/generate")!
    private let session: URLSession
    private let url: URL
    private let redirects = RejectInferenceRedirects()
    private let maximumWireBytes = 2 * 1_024 * 1_024
    private let maximumLineBytes = 128 * 1_024

    public init(endpoint: URL = OllamaClient.endpoint, session: URLSession? = nil) throws {
        guard endpoint.scheme == "http", endpoint.host == "localhost",
              endpoint.port == 11434, endpoint.path == "/api/generate",
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else {
            throw LocalInferenceError.invalidConfiguration
        }
        url = endpoint
        self.session = session ?? URLSession(configuration: Self.configuration())
    }

    public static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        return configuration
    }

    /// Model discovery sends no document text. Generation still verifies /show.
    public func localModelNames() async throws -> [String] {
        let request = URLRequest(url: url.deletingLastPathComponent().appendingPathComponent("tags"),
                                 timeoutInterval: 5)
        do {
            let data = try await readMetadata(request)
            guard let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data) else {
                throw LocalInferenceError.malformedResponse
            }
            let candidates = Array(Set(catalog.models.filter {
                ($0.remote_host ?? "").isEmpty && ($0.remote_model ?? "").isEmpty
                    && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.map(\.name))).sorted()
            var chatModels: [String] = []
            for name in candidates {
                try Task.checkCancellation()
                var show = URLRequest(url: url.deletingLastPathComponent().appendingPathComponent("show"), timeoutInterval: 15)
                show.httpMethod = "POST"
                show.setValue("application/json", forHTTPHeaderField: "Content-Type")
                show.httpBody = try JSONEncoder().encode(["model": name])
                do {
                    let data = try await readMetadata(show)
                    let value = try JSONDecoder().decode(AssistantJSON.self, from: data)
                    if !(value["remote_host"]?.string ?? "").isEmpty || !(value["remote_model"]?.string ?? "").isEmpty { continue }
                    if let capabilities = value["capabilities"]?.array {
                        if capabilities.contains(.string("completion")) { chatModels.append(name) }
                    } else if !name.lowercased().contains("embeddinggemma") && !name.lowercased().contains("nomic-embed") && !name.lowercased().contains("mxbai-embed") {
                        chatModels.append(name) // Older Ollama metadata omitted capabilities.
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if Task.isCancelled { throw CancellationError() }
                    if !name.lowercased().contains("embed") { chatModels.append(name) }
                }
            }
            return chatModels
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw LocalInferenceError.serviceUnavailable
        }
    }

    private struct ModelCatalog: Decodable {
        let models: [Model]
        struct Model: Decodable {
            let name: String
            let remote_host: String?
            let remote_model: String?
        }
    }

    public func generate(
        _ body: OllamaGenerateRequest,
        onLine: @Sendable (String) async throws -> Void
    ) async throws {
        guard !body.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalInferenceError.invalidConfiguration
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        do {
            try await verifyLocalModel(body.model)
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
            defer { bytes.task.cancel() }
            try validate(response)
            var line = Data()
            var received = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                received += 1
                guard received <= maximumWireBytes else { throw LocalInferenceError.responseTooLarge }
                if byte == 10 {
                    if !line.isEmpty {
                        try await deliver(line, to: onLine)
                        line.removeAll(keepingCapacity: true)
                    }
                } else {
                    guard line.count < maximumLineBytes else {
                        throw LocalInferenceError.responseTooLarge
                    }
                    line.append(byte)
                }
            }
            if !line.isEmpty { try await deliver(line, to: onLine) }
            try Task.checkCancellation()
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw LocalInferenceError.serviceUnavailable
        }
    }

    /// Only the model name is sent until Ollama confirms local model metadata.
    private func verifyLocalModel(_ model: String) async throws {
        var request = URLRequest(url: url.deletingLastPathComponent().appendingPathComponent("show"),
                                 timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["model": model])
        let data = try await readMetadata(request)
        guard let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalInferenceError.malformedResponse
        }
        // Reject remote aliases before any document text is sent to generate.
        for key in ["remote_host", "remote_model"] {
            if let value = metadata[key], !(value is NSNull) {
                guard let text = value as? String, text.isEmpty else {
                    throw LocalInferenceError.remoteModel
                }
            }
        }
        guard let info = metadata["model_info"] as? [String: Any],
              let architecture = info["general.architecture"] as? String,
              !architecture.isEmpty else { throw LocalInferenceError.remoteModel }
    }

    private func readMetadata(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
        defer { bytes.task.cancel() }
        try validate(response)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_024 * 1_024 else { throw LocalInferenceError.responseTooLarge }
            data.append(byte)
        }
        return data
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LocalInferenceError.malformedResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 { throw LocalInferenceError.modelUnavailable }
            throw LocalInferenceError.httpStatus(http.statusCode)
        }
    }

    private func deliver(
        _ data: Data, to callback: @Sendable (String) async throws -> Void
    ) async throws {
        guard let line = String(data: data, encoding: .utf8) else {
            throw LocalInferenceError.malformedResponse
        }
        if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await callback(line)
        }
    }
}

private final class RejectInferenceRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
