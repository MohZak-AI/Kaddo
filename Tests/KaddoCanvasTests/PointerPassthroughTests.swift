import AppKit
import XCTest
@testable import KaddoCanvas

@MainActor
private final class AlphaTestView: NSView {
    var alternateFrame = false
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        NSColor.orange.withAlphaComponent(0.5).setFill()
        NSRect(x: alternateFrame ? 0 : 10, y: 0, width: 10, height: 10).fill()
        NSRect(x: alternateFrame ? 10 : 0, y: 10, width: 10, height: 10).fill()
    }
}

final class PointerPassthroughTests: XCTestCase {
    @MainActor
    func testRenderedAlphaCoordinatesAndFrameChanges() {
        _ = NSApplication.shared
        let panel = FloatingPetPanel(contentRect: NSRect(x: -100, y: 100, width: 20, height: 20))
        defer { panel.close() }
        let view = AlphaTestView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        panel.contentView = view
        let tracker = PointerPassthroughController(panel: panel)
        tracker.updatePointer(globalPoint: NSPoint(x: -95, y: 115))
        XCTAssertTrue(panel.ignoresMouseEvents, "Transparent top-left must pass through")
        tracker.updatePointer(globalPoint: NSPoint(x: -85, y: 115))
        XCTAssertFalse(panel.ignoresMouseEvents, "Visible top-right must receive events")
        tracker.updatePointer(globalPoint: NSPoint(x: -95, y: 105))
        XCTAssertFalse(panel.ignoresMouseEvents, "Flipped view and AppKit origins must agree")
        tracker.updatePointer(globalPoint: NSPoint(x: -85, y: 105))
        XCTAssertTrue(panel.ignoresMouseEvents)
        for point in [NSPoint(x: -101, y: 105), NSPoint(x: -80, y: 105),
                      NSPoint(x: -95, y: 120), NSPoint(x: 500, y: 500)] {
            tracker.updatePointer(globalPoint: point)
            XCTAssertTrue(panel.ignoresMouseEvents)
        }
        view.alternateFrame = true
        view.needsDisplay = true
        tracker.updatePointer(globalPoint: NSPoint(x: -95, y: 115))
        XCTAssertFalse(panel.ignoresMouseEvents, "New alpha must replace the previous frame")
    }

    @MainActor
    func testDragCaptureAndMonitorLifecycle() {
        _ = NSApplication.shared
        let panel = FloatingPetPanel(contentRect: NSRect(x: 100, y: 100, width: 20, height: 20))
        defer { panel.close() }
        panel.contentView = AlphaTestView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        let tracker = PointerPassthroughController(panel: panel)
        tracker.start()
        tracker.start()
        XCTAssertTrue(tracker.isRunning)
        tracker.beginMouseCapture()
        tracker.updatePointer(globalPoint: NSPoint(x: 500, y: 500), leftMouseIsDown: true)
        XCTAssertFalse(panel.ignoresMouseEvents)
        tracker.updatePointer(globalPoint: NSPoint(x: 500, y: 500), leftMouseIsDown: false)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(tracker.isCapturingMouse)
        tracker.stop()
        tracker.stop()
        XCTAssertFalse(tracker.isRunning)
        XCTAssertFalse(panel.ignoresMouseEvents)
    }
}
