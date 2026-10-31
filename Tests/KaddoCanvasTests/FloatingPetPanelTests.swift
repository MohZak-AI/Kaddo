import AppKit
import XCTest
@testable import KaddoCanvas

final class FloatingPetPanelTests: XCTestCase {
    @MainActor
    func testPanelConfiguration() {
        _ = NSApplication.shared
        let panel = FloatingPetPanel(contentRect: NSRect(x: 50, y: 50, width: 240, height: 220))
        defer { panel.close() }
        XCTAssertEqual(panel.styleMask, [.borderless, .nonactivatingPanel])
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.isExcludedFromWindowsMenu)
        let proposed = NSRect(x: -1_000, y: -100, width: 240, height: 220)
        XCTAssertEqual(panel.constrainFrameRect(proposed, to: NSScreen.main), proposed)
    }
}
