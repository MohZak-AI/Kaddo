import XCTest
@testable import KaddoCanvas

final class AgentSourceReaderTests: XCTestCase, @unchecked Sendable {
    private let grant = AgentFolderGrant(name: "Test", bookmark: Data())

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.resolvingSymlinksInPath()
    }

    private func reader(_ root: URL) -> AgentSourceReader {
        AgentSourceReader(resolveBookmark: { _ in root })
    }

    func testReadsBoundedTextAndDocumentFormats() async throws {
        let root = try directory()
        try String(repeating: "a", count: 7_000).write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        let excerpt = try await reader(root).read(grant: grant, relativePath: "note.md")
        XCTAssertEqual(excerpt.text.count, 6_000)
        XCTAssertEqual(excerpt.title, "note.md")
        XCTAssertEqual(excerpt.url, root.appendingPathComponent("note.md"))
        for name in ["FocusNotes.docx", "Research.pdf"] {
            try FileManager.default.copyItem(at: documentFixture(name), to: root.appendingPathComponent(name))
            let document = try await reader(root).read(grant: grant, relativePath: name)
            XCTAssertFalse(document.text.isEmpty)
        }
    }

    func testRejectsEscapesAbsolutePathsAndSymlinkEscapes() async throws {
        let root = try directory(), outside = try directory()
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.txt"),
                                                   withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape-dir"), withDestinationURL: outside)
        for path in ["../secret.txt", "/secret.txt", "a/../secret.txt", "", "escape.txt", "escape-dir/secret.txt", "a\\b.txt"] {
            do {
                _ = try await reader(root).read(grant: grant, relativePath: path)
                XCTFail("Accepted unsafe path: \(path)")
            } catch { XCTAssertEqual(error as? AgentSourceError, .invalidPath, path) }
        }
        let listed = try await reader(root).list(grant: grant)
        XCTAssertTrue(listed.isEmpty)
    }

    func testListsOnlySupportedVisibleFilesAndCapsResults() async throws {
        let root = try directory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try "hidden".write(to: root.appendingPathComponent(".hidden/a.txt"), atomically: true, encoding: .utf8)
        for name in [".hidden.txt", "binary.exe", "visible.txt", "UPPER.MD"] {
            try "text".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let visible = try await reader(root).list(grant: grant)
        let filtered = try await reader(root).list(grant: grant, query: "VIS")
        XCTAssertEqual(visible, ["UPPER.MD", "visible.txt"])
        XCTAssertEqual(filtered, ["visible.txt"])
        for index in 0..<110 { FileManager.default.createFile(atPath: root.appendingPathComponent("\(index).txt").path, contents: Data()) }
        let capped = try await reader(root).list(grant: grant)
        XCTAssertEqual(capped.count, 100)
    }

    func testRejectsUnsupportedOversizedAndEmptySources() async throws {
        let root = try directory()
        let cases: [(String, Data, AgentSourceError)] = [
            ("bad.exe", Data("code".utf8), .unsupportedType),
            ("large.txt", Data(repeating: 65, count: AgentSourceReader.maximumFileBytes + 1), .tooLarge),
            ("empty.txt", Data("  \n".utf8), .emptyText)
        ]
        for (name, data, expected) in cases {
            try data.write(to: root.appendingPathComponent(name))
            do { _ = try await reader(root).read(grant: grant, relativePath: name); XCTFail(name) }
            catch { XCTAssertEqual(error as? AgentSourceError, expected) }
        }
    }

    func testInvalidStaleAndRevokedGrantsFailClosed() async throws {
        do { _ = try await AgentSourceReader().list(grant: grant); XCTFail("Invalid bookmark accepted") }
        catch { XCTAssertEqual(error as? AgentSourceError, .invalidGrant) }
        let stale = AgentSourceReader(resolveBookmark: { _ in throw AgentSourceError.staleGrant })
        do { _ = try await stale.list(grant: grant); XCTFail("Stale bookmark accepted") }
        catch { XCTAssertEqual(error as? AgentSourceError, .staleGrant) }
        let root = try directory()
        let revoked = AgentSourceReader(resolveBookmark: { _ in root }, startAccess: { _ in false })
        do { _ = try await revoked.list(grant: grant); XCTFail("Revoked scope accepted") }
        catch { XCTAssertEqual(error as? AgentSourceError, .accessDenied) }
    }

    func testHTMLRemovesActiveContentCommentsAndDecodesEntities() {
        let html = "<html><head><style>secret style</style><script src='x'>secret script</script></head>"
            + "<body><!-- secret comment --><h1>A &amp; B</h1><p>&#x1F408; &#233; &lt;safe&gt; &nbsp; end</p></body></html>"
        XCTAssertEqual(AgentSourceReader.readableHTML(html), "A & B 🐈 é <safe> end")
        XCTAssertEqual(AgentSourceReader.readableHTML("Visible<script>unterminated"), "Visible")
        XCTAssertEqual(AgentSourceReader.readableHTML("Visible<!--unterminated"), "Visible")
    }

    func testMalformedHTMLIsLinearAndTagNamesMatchExactly() {
        let began = Date()
        XCTAssertEqual(AgentSourceReader.readableHTML(String(repeating: "<", count: 100_000)), "")
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
        XCTAssertEqual(AgentSourceReader.readableHTML("<script>hidden</scripture>still hidden</script><p>Shown</p>"), "Shown")
        XCTAssertEqual(AgentSourceReader.readableHTML("<style>hidden</stylesheet>still hidden</style><p>Shown</p>"), "Shown")
        XCTAssertEqual(AgentSourceReader.readableHTML("<script-widget>Visible</script-widget>"), "Visible")
    }

    func testRejectsNonPublicAddressesIncludingMappedIPv6() {
        for address in ["0.0.0.0", "10.0.0.1", "100.64.1.1", "127.0.0.1", "169.254.169.254", "172.16.0.1",
                        "192.168.1.1", "192.0.2.1", "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1",
                        "240.0.0.1", "255.255.255.255", "::", "::1", "fe80::1", "fc00::1", "ff02::1",
                        "::ffff:127.0.0.1", "::ffff:8.8.8.8", "2001:db8::1", "2002:0808:0808::1", "3fff::1",
                        "2001::1", "2130706433", "0x7f000001", "127.1"] {
            XCTAssertFalse(AgentSourceReader.isPublicAddress(address), address)
        }
        for address in ["8.8.8.8", "1.1.1.1", "93.184.216.34", "2606:4700:4700::1111", "2001:4860:4860::8888"] {
            XCTAssertTrue(AgentSourceReader.isPublicAddress(address), address)
        }
    }

    func testURLPolicyAndMixedDNSAnswersFailBeforeTransport() async throws {
        for value in ["file:///etc/passwd", "http://example.com", "https://user:pass@example.com", "https://example.com:444/",
                      "https://localhost/", "https://localhost./", "https://host.local/", "https://127.0.0.1/",
                      "https://[::1]/", "https://2130706433/", "https://0x7f000001/", "https://127.1/"] {
            XCTAssertThrowsError(try AgentSourceReader.publicHTTPSHost(URL(string: value)!)) { error in
                XCTAssertEqual(error as? AgentSourceError, .unsafeURL, value)
            }
        }
        XCTAssertEqual(try AgentSourceReader.publicHTTPSHost(URL(string: "https://example.com:443/path")!), "example.com")
        let mixed = AgentSourceReader(resolveBookmark: { _ in throw AgentSourceError.invalidGrant },
                                      resolveHost: { _ in ["93.184.216.34", "10.0.0.1"] })
        do { try await mixed.validateURL(URL(string: "https://example.com")!); XCTFail("Mixed DNS accepted") }
        catch { XCTAssertEqual(error as? AgentSourceError, .unsafeURL) }
        let empty = AgentSourceReader(resolveBookmark: { _ in throw AgentSourceError.invalidGrant }, resolveHost: { _ in [] })
        do { try await empty.validateURL(URL(string: "https://example.com")!); XCTFail("Empty DNS accepted") }
        catch { XCTAssertEqual(error as? AgentSourceError, .unsafeURL) }
    }

    func testRedirectsRevalidateDNSAndReturnFinalDestination() async throws {
        let transport = SourceTransportStub(responses: [
            .init(status: 302, headers: ["location": "https://second.example/article"], body: Data()),
            .init(status: 200, headers: ["content-type": "text/html; charset=utf-8"], body: Data("<p>Final &amp; readable</p>".utf8))
        ])
        let resolver = SourceResolverStub()
        let reader = AgentSourceReader(resolveBookmark: { _ in throw AgentSourceError.invalidGrant },
            resolveHost: { await resolver.resolve($0) }, transport: { try await transport.fetch($0, $1, $2) })
        let result = try await reader.fetch(url: URL(string: "https://first.example/start")!)
        XCTAssertEqual(result.url.absoluteString, "https://second.example/article")
        XCTAssertEqual(result.text, "Final & readable")
        let hosts = await resolver.hosts
        let calls = await transport.calls
        XCTAssertEqual(hosts, ["first.example", "second.example"])
        XCTAssertEqual(calls.map(\.1), ["93.184.216.34", "93.184.216.34"])
    }

    func testRedirectsToPrivateDestinationsAndRedirectLoopsAreRejected() async throws {
        let privateTransport = SourceTransportStub(responses: [
            .init(status: 301, headers: ["location": "https://127.0.0.1/secret"], body: Data())
        ])
        let privateReader = AgentSourceReader(resolveBookmark: { _ in throw AgentSourceError.invalidGrant },
            resolveHost: { _ in ["93.184.216.34"] }, transport: { try await privateTransport.fetch($0, $1, $2) })
        do { _ = try await privateReader.fetch(url: URL(string: "https://first.example")!); XCTFail("Private redirect followed") }
        catch { XCTAssertEqual(error as? AgentSourceError, .unsafeURL) }
        let privateCalls = await privateTransport.calls
        XCTAssertEqual(privateCalls.count, 1)
        let loop = SourceTransportStub(responses: Array(repeating:
            .init(status: 302, headers: ["location": "/again"], body: Data()), count: 4))
        let loopReader = AgentSourceReader(resolveBookmark: { _ in throw AgentSourceError.invalidGrant },
            resolveHost: { _ in ["93.184.216.34"] }, transport: { try await loop.fetch($0, $1, $2) })
        do { _ = try await loopReader.fetch(url: URL(string: "https://first.example")!); XCTFail("Redirect loop followed") }
        catch { XCTAssertEqual(error as? AgentSourceError, .tooManyRedirects) }
        let loopCalls = await loop.calls
        XCTAssertEqual(loopCalls.count, 4)
    }

    func testTransportResponseLimitsAndUnsupportedMIME() async throws {
        for (response, expected) in [
            (AgentSourceHTTPResponse(status: 200, headers: ["content-type": "text/plain"],
                body: Data(repeating: 65, count: AgentSourceReader.maximumResponseBytes + 1)), AgentSourceError.tooLarge),
            (.init(status: 200, headers: ["content-type": "application/javascript"], body: Data("alert(1)".utf8)), .unsupportedType),
            (.init(status: 403, headers: ["content-type": "text/plain"], body: Data("Forbidden".utf8)), .invalidResponse)
        ] {
            let reader = AgentSourceReader(resolveBookmark: { _ in throw AgentSourceError.invalidGrant },
                resolveHost: { _ in ["93.184.216.34"] }, transport: { _, _, _ in response })
            do { _ = try await reader.fetch(url: URL(string: "https://example.com")!); XCTFail("Response accepted") }
            catch { XCTAssertEqual(error as? AgentSourceError, expected) }
        }
        let reader = AgentSourceReader(resolveBookmark: { _ in throw AgentSourceError.invalidGrant },
            resolveHost: { _ in ["93.184.216.34"] }, transport: { _, _, _ in
                .init(status: 200, headers: ["content-type": "text/plain"], body: Data(repeating: 65, count: 10_000))
            })
        let result = try await reader.fetch(url: URL(string: "https://example.com")!)
        XCTAssertEqual(result.text.count, 6_000)
    }

    func testCancellationInterruptsSuspendedTransport() async throws {
        let started = expectation(description: "transport started")
        let reader = AgentSourceReader(resolveBookmark: { _ in throw AgentSourceError.invalidGrant },
            resolveHost: { _ in ["93.184.216.34"] }, transport: { _, _, _ in
                started.fulfill()
                try await Task.sleep(for: .seconds(30))
                return .init(status: 200, headers: ["content-type": "text/plain"], body: Data("late".utf8))
            })
        let task = Task { try await reader.fetch(url: URL(string: "https://example.com")!) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled transport completed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testListingHasAggregateCharacterBudget() async throws {
        let root = try directory()
        for index in 0..<80 {
            try Data("safe".utf8).write(to: root.appendingPathComponent(String(repeating: "a", count: 180) + "\(index).txt"))
        }
        let paths = try await reader(root).list(grant: grant)
        XCTAssertLessThanOrEqual(paths.joined(separator: "\n").count, 6_000)
    }

    func testConcurrentSymlinkReplacementCannotReadOutsideGrant() async throws {
        let root = try directory(), outside = try directory()
        let target = root.appendingPathComponent("race.txt")
        let secret = outside.appendingPathComponent("secret.txt")
        try "OUTSIDE SECRET".write(to: secret, atomically: true, encoding: .utf8)
        try "safe".write(to: target, atomically: true, encoding: .utf8)
        let attacker = Task.detached {
            for _ in 0..<150 {
                let replacement = root.appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createSymbolicLink(at: replacement, withDestinationURL: secret)
                _ = rename(replacement.path, target.path)
                let valid = root.appendingPathComponent(UUID().uuidString)
                try? Data("safe".utf8).write(to: valid)
                _ = rename(valid.path, target.path)
            }
        }
        for _ in 0..<150 {
            do {
                let excerpt = try await reader(root).read(grant: grant, relativePath: "race.txt")
                XCTAssertEqual(excerpt.text, "safe")
            } catch { XCTAssertTrue(error is AgentSourceError) }
        }
        await attacker.value
    }

    func testStalledDNSIsBoundedAndCancellationDoesNotWaitForResolver() async throws {
        for cancel in [true, false] {
            let gate = SourceResolverGate()
            let reader = AgentSourceReader(resolveBookmark: { _ in throw AgentSourceError.invalidGrant },
                resolveHost: { _ in await gate.wait() }, requestTimeout: 0.05)
            let began = Date()
            let task = Task { try await reader.fetch(url: URL(string: "https://example.com")!) }
            if cancel { task.cancel() }
            do { _ = try await task.value; XCTFail("Stalled DNS completed") }
            catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
            }
            XCTAssertLessThan(Date().timeIntervalSince(began), 1)
            await gate.release()
        }
    }

    func testCancellationStopsAllEntryPointsBeforeReadingOrNetworking() async throws {
        let root = try directory()
        let reader = reader(root)
        let grant = grant
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            for operation in 0..<3 {
                do {
                    switch operation {
                    case 0: _ = try await reader.list(grant: grant)
                    case 1: _ = try await reader.read(grant: grant, relativePath: "a.txt")
                    default: _ = try await reader.fetch(url: URL(string: "https://example.com")!)
                    }
                    XCTFail("Cancelled operation proceeded")
                } catch { XCTAssertTrue(error is CancellationError) }
            }
        }
        await task.value
    }
}

private actor SourceTransportStub {
    private var responses: [AgentSourceHTTPResponse]
    private(set) var calls: [(URL, String)] = []

    init(responses: [AgentSourceHTTPResponse]) { self.responses = responses }

    func fetch(_ url: URL, _ address: String, _ timeout: TimeInterval) throws -> AgentSourceHTTPResponse {
        calls.append((url, address))
        guard timeout > 0, !responses.isEmpty else { throw AgentSourceError.invalidResponse }
        return responses.removeFirst()
    }
}

private actor SourceResolverStub {
    private(set) var hosts: [String] = []

    func resolve(_ host: String) -> [String] {
        hosts.append(host)
        return ["93.184.216.34"]
    }
}

private actor SourceResolverGate {
    private var waiter: CheckedContinuation<[String], Never>?
    private var released = false
    func wait() async -> [String] {
        if released { return ["93.184.216.34"] }
        return await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(returning: ["93.184.216.34"]); waiter = nil }
}
