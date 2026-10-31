import Foundation

// Per-session registry keeps parallel tests isolated. Every request is intercepted,
// including unexpected URLs, so this harness can never fall through to the network.
final class Phase4HTTPHarness: @unchecked Sendable {
    enum Outcome: Sendable {
        case response(status: Int, body: Data)
        case failure(URLError.Code)
    }

    struct CapturedRequest: Sendable {
        let url: URL?
        let method: String?
        let contentType: String?
        let timeout: TimeInterval
        let body: Data
    }

    private let id = UUID().uuidString
    private let transport: Phase4StubTransport
    let session: URLSession
    var requests: [CapturedRequest] { transport.requests }

    init(status: Int = 200, json: String, holdOpen: Bool = false,
         modelMetadata: String = #"{"model_info":{"general.architecture":"llama"}}"#,
         modelCatalog: String? = nil) {
        transport = Phase4StubTransport(outcome: .response(status: status, body: Data(json.utf8)))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Phase4StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Kaddo-Test-ID": id, "X-Kaddo-Test-Hold": holdOpen ? "true" : "false",
                                               "X-Kaddo-Test-Metadata": Data(modelMetadata.utf8).base64EncodedString()]
        if let modelCatalog {
            configuration.httpAdditionalHeaders?["X-Kaddo-Test-Catalog"] = Data(modelCatalog.utf8).base64EncodedString()
        }
        session = URLSession(configuration: configuration)
        Phase4StubURLProtocol.registry.insert(id: id, transport: transport)
    }

    init(failure: URLError.Code) {
        transport = Phase4StubTransport(outcome: .failure(failure))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Phase4StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Kaddo-Test-ID": id]
        session = URLSession(configuration: configuration)
        Phase4StubURLProtocol.registry.insert(id: id, transport: transport)
    }

    func cleanUp() {
        session.invalidateAndCancel()
        Phase4StubURLProtocol.registry.remove(id: id)
    }
}

private final class Phase4StubTransport: @unchecked Sendable {
    let outcome: Phase4HTTPHarness.Outcome
    private let lock = NSLock()
    private var captured: [Phase4HTTPHarness.CapturedRequest] = []

    init(outcome: Phase4HTTPHarness.Outcome) { self.outcome = outcome }

    var requests: [Phase4HTTPHarness.CapturedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func record(_ request: URLRequest) {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
        }
        lock.lock()
        defer { lock.unlock() }
        captured.append(.init(url: request.url, method: request.httpMethod,
                              contentType: request.value(forHTTPHeaderField: "Content-Type"),
                              timeout: request.timeoutInterval, body: body))
    }
}

private final class Phase4TransportRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [String: Phase4StubTransport] = [:]

    func insert(id: String, transport: Phase4StubTransport) {
        lock.lock()
        defer { lock.unlock() }
        transports[id] = transport
    }

    func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        transports[id] = nil
    }

    func find(id: String) -> Phase4StubTransport? {
        lock.lock()
        defer { lock.unlock() }
        return transports[id]
    }
}

private final class Phase4StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = Phase4TransportRegistry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Kaddo-Test-ID") ?? ""
        guard let transport = Self.registry.find(id: id), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        transport.record(request)
        switch transport.outcome {
        case let .response(status, originalBody):
            let isMetadata = url.path == "/api/show"
            let catalog = request.value(forHTTPHeaderField: "X-Kaddo-Test-Catalog")
            let body: Data
            if isMetadata && status == 200 {
                body = Data(base64Encoded: request.value(forHTTPHeaderField: "X-Kaddo-Test-Metadata") ?? "")!
            } else if url.path == "/api/tags", status == 200, let catalog {
                body = Data(base64Encoded: catalog)!
            } else { body = originalBody }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Split UTF-8 sequences and NDJSON records across transport callbacks.
            for offset in stride(from: 0, to: body.count, by: 7) {
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<min(offset + 7, body.count)))
            }
            if isMetadata || request.value(forHTTPHeaderField: "X-Kaddo-Test-Hold") != "true" {
                client?.urlProtocolDidFinishLoading(self)
            }
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}
