import AppKit
import XCTest
@testable import KaddoCanvas

final class WindowDragTests: XCTestCase {
    @MainActor
    func testScreenCoordinatesPreventAccumulatedDragAndAllowNegativeOrigins() {
        _ = NSApplication.shared
        let panel = FloatingPetPanel(contentRect: NSRect(x: 100, y: 100, width: 260, height: 260))
        defer { panel.close() }
        let drag = WindowDragController(panel: panel)
        drag.begin(at: NSPoint(x: 130, y: 140))
        drag.update(to: NSPoint(x: 140, y: 155))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 110, y: 115))
        drag.begin(at: NSPoint(x: 140, y: 155)) // Repeated gesture callbacks do not reset baseline.
        drag.update(to: NSPoint(x: 150, y: 160))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 120, y: 120))
        drag.update(to: NSPoint(x: -200, y: -50))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: -230, y: -90))
        drag.end()
        drag.update(to: NSPoint(x: 500, y: 500))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: -230, y: -90))
        drag.begin(at: NSPoint(x: -200, y: -50))
        drag.update(to: NSPoint(x: -190, y: -40))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: -220, y: -80))
        drag.end()
    }
}
