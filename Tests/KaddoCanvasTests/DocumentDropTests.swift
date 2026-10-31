import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import KaddoCanvas

final class DocumentDropTests: XCTestCase {
    func testStrictLocalFileTypes() {
        XCTAssertTrue(DocumentDropTypes.accepts(URL(fileURLWithPath: "/tmp/Notes.DOCX")))
        XCTAssertTrue(DocumentDropTypes.accepts(URL(fileURLWithPath: "/tmp/Notes.pdf")))
        XCTAssertTrue(DocumentDropTypes.accepts(URL(fileURLWithPath: "/tmp/Notes.txt")))
        XCTAssertTrue(DocumentDropTypes.accepts(URL(fileURLWithPath: "/tmp/Notes.md")))
        for path in ["a.doc", "a.pdf.exe", "no-extension"] {
            XCTAssertFalse(DocumentDropTypes.accepts(URL(fileURLWithPath: "/tmp/\(path)")))
        }
        XCTAssertFalse(DocumentDropTypes.accepts(URL(string: "https://example.com/a.pdf")!))
        XCTAssertTrue(DocumentDropTypes.supported.contains(.pdf))
        XCTAssertTrue(DocumentDropTypes.supported.contains(DocumentDropTypes.word))
    }

    @MainActor
    func testProviderResolutionAndRejection() async {
        let received = expectation(description: "local document delivered")
        let rejected = expectation(description: "unsupported file rejected")
        for (path, valid) in [("/tmp/a.docx", true), ("/tmp/a.exe", false)] {
            let provider = NSItemProvider(item: URL(fileURLWithPath: path) as NSURL,
                                          typeIdentifier: UTType.fileURL.identifier)
            XCTAssertTrue(DocumentDropHandler.receive([provider], onURL: { url in
                XCTAssertTrue(valid)
                XCTAssertEqual(url.path, path)
                received.fulfill()
            }, onFailure: {
                XCTAssertFalse(valid)
                rejected.fulfill()
            }))
        }
        XCTAssertFalse(DocumentDropHandler.receive([NSItemProvider(object: "text" as NSString)],
                                                  onURL: { _ in XCTFail() }, onFailure: { XCTFail() }))
        await fulfillment(of: [received, rejected], timeout: 2)
    }

    @MainActor
    func testDocumentDragTemporarilyDisablesTransparentPassthrough() {
        _ = NSApplication.shared
        let panel = FloatingPetPanel(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20))
        defer { panel.close() }
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        let tracker = PointerPassthroughController(panel: panel)
        tracker.updatePointer(globalPoint: NSPoint(x: 5, y: 5), documentDragIsActive: true)
        XCTAssertFalse(panel.ignoresMouseEvents)
        tracker.updatePointer(globalPoint: NSPoint(x: 500, y: 500))
        XCTAssertTrue(panel.ignoresMouseEvents)
    }
}
