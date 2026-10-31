import Foundation

// Per-session registry keeps parallel tests isolated. Every request is intercepted,
// including unexpected URLs, so this harness can never fall through to the network.
final class HTTPHarness: @unchecked Sendable {
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
    private let transport: StubTransport
    let session: URLSession
    var requests: [CapturedRequest] { transport.requests }

    init(status: Int = 200, json: String = #"{"message":{"role":"assistant","content":"Water orchids weekly."},"done":true}"#) {
        transport = StubTransport(outcome: .response(status: status, body: Data(json.utf8)))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Kaddo-Test-ID": id]
        session = URLSession(configuration: configuration)
        StubURLProtocol.registry.insert(id: id, transport: transport)
    }

    init(failure: URLError.Code) {
        transport = StubTransport(outcome: .failure(failure))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Kaddo-Test-ID": id]
        session = URLSession(configuration: configuration)
        StubURLProtocol.registry.insert(id: id, transport: transport)
    }

    func cleanUp() {
        session.invalidateAndCancel()
        StubURLProtocol.registry.remove(id: id)
    }
}

private final class StubTransport: @unchecked Sendable {
    let outcome: HTTPHarness.Outcome
    private let lock = NSLock()
    private var captured: [HTTPHarness.CapturedRequest] = []

    init(outcome: HTTPHarness.Outcome) { self.outcome = outcome }

    var requests: [HTTPHarness.CapturedRequest] {
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

private final class TransportRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [String: StubTransport] = [:]

    func insert(id: String, transport: StubTransport) {
        lock.lock()
        defer { lock.unlock() }
        transports[id] = transport
    }

    func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        transports[id] = nil
    }

    func find(id: String) -> StubTransport? {
        lock.lock()
        defer { lock.unlock() }
        return transports[id]
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = TransportRegistry()

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
        case let .response(status, body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}
