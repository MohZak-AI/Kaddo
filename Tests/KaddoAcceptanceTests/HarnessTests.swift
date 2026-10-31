import Foundation
import PDFKit
import Testing

@Suite("Harness · Test infrastructure")
struct HarnessTests {
    @Test("Generated PDF has two searchable pages with the expected text")
    func pdfFixture() throws {
        let document = try #require(PDFDocument(url: fixture("Research.pdf")))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.string?.contains("Orchid research") == true)
        #expect(document.page(at: 1)?.string?.contains("Cactus research") == true)
        let empty = try #require(PDFDocument(url: fixture("ImageOnly.pdf")))
        #expect((empty.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Generated Word package exposes the intended XML entry")
    func docxFixture() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", try fixture("FocusNotes.docx").path, "word/document.xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let xml = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let text = try #require(String(data: xml, encoding: .utf8))
        #expect(text.contains("Alpha &amp; Beta"))
        #expect(text.contains("café 🐈"))
        #expect(text.contains("<w:tab/>"))
        #expect(text.contains("<w:br/>"))
    }

    @Test("HTTP harness captures requests and returns a response without networking")
    func httpHarness() async throws {
        let http = HTTPHarness(status: 201, json: #"{"ok":true}"#)
        defer { http.cleanUp() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        request.httpMethod = "POST"
        request.httpBody = Data("test body".utf8)
        let (data, response) = try await http.session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 201)
        #expect(String(data: data, encoding: .utf8) == #"{"ok":true}"#)
        #expect(http.requests.count == 1)
        #expect(http.requests.first?.body == Data("test body".utf8))
    }

    @Test("HTTP stubs remain isolated across concurrently active sessions")
    func isolatedHTTP() async throws {
        let first = HTTPHarness(json: "first")
        let second = HTTPHarness(json: "second")
        defer { first.cleanUp(); second.cleanUp() }
        let url = URL(string: "http://127.0.0.1:11434/api/chat")!
        async let one = first.session.data(from: url)
        async let two = second.session.data(from: url)
        let (firstResponse, secondResponse) = try await (one, two)
        #expect(String(data: firstResponse.0, encoding: .utf8) == "first")
        #expect(String(data: secondResponse.0, encoding: .utf8) == "second")
        #expect(first.requests.count == 1)
        #expect(second.requests.count == 1)
    }

    @Test("HTTP harness can simulate a transport failure")
    @MainActor
    func transportFailure() async throws {
        let http = HTTPHarness(failure: .timedOut)
        defer { http.cleanUp() }
        try await expectURLError(.timedOut) {
            _ = try await http.session.data(from: URL(string: "http://127.0.0.1:11434/api/chat")!)
        }
        #expect(http.requests.count == 1)
    }

    @Test("Test clock and defaults suites are independent")
    @MainActor
    func clockAndStorage() throws {
        let first = try IsolatedDefaults()
        let second = try IsolatedDefaults()
        defer { first.cleanUp(); second.cleanUp() }
        first.defaults.set(25, forKey: "experience")
        #expect(second.defaults.object(forKey: "experience") == nil)
        let clock = TestClock()
        clock.advance(100)
        #expect(clock.time == 100)
    }

    @Test("Manual timer delivers callbacks until cancellation")
    @MainActor
    func tickerHarness() {
        let ticker = ManualTicker()
        var ticks = 0
        let subscription = ticker.subscribe { ticks += 1 }
        ticker.fire()
        #expect(ticks == 1)
        subscription.cancel()
        ticker.fire()
        #expect(ticks == 1)
        #expect(ticker.activeSubscriptionCount == 0)
    }
}
