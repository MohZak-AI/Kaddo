import AppKit
import Testing

@Suite("Scope 1 · Native overlay")
@MainActor
struct OverlayTests {
    private var mask: SpriteMask {
        SpriteMask(width: 2, height: 2, alpha: [0, 255, 128, 0], scale: 10)
    }

    @Test("Uses a borderless nonactivating NSPanel")
    func nativePanel() throws {
        let overlay = try MVPFactory.overlay(mask: mask)
        defer { overlay.window.close() }
        #expect(overlay.window is NSPanel)
        #expect(overlay.window.styleMask.contains(.nonactivatingPanel))
        #expect(!overlay.window.styleMask.contains(.titled))
        #expect(!overlay.window.isOpaque)
        #expect(overlay.window.backgroundColor.alphaComponent == 0)
        #expect(!overlay.window.hasShadow)
        #expect(!overlay.window.canBecomeMain)
        #expect(!overlay.window.hidesOnDeactivate)
        #expect(overlay.window.level >= .floating)
    }

    @Test("Participates in Spaces and full-screen auxiliary windows")
    func spaces() throws {
        let overlay = try MVPFactory.overlay(mask: mask)
        defer { overlay.window.close() }
        #expect(overlay.window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(overlay.window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(overlay.window.isExcludedFromWindowsMenu)
    }

    @Test("Alpha targeting respects scaling and the AppKit bottom-left origin")
    func alphaTargeting() throws {
        let overlay = try MVPFactory.overlay(mask: mask)
        defer { overlay.window.close() }
        #expect(!overlay.isInteractive(at: NSPoint(x: 5, y: 15)))
        #expect(overlay.isInteractive(at: NSPoint(x: 15, y: 15)))
        #expect(overlay.isInteractive(at: NSPoint(x: 5, y: 5)))
        #expect(!overlay.isInteractive(at: NSPoint(x: 15, y: 5)))
    }

    @Test("Outside and exact upper bounds pass through", arguments: [
        NSPoint(x: -1, y: 5), NSPoint(x: 5, y: -1),
        NSPoint(x: 20, y: 5), NSPoint(x: 5, y: 20)
    ])
    func outsideMask(point: NSPoint) throws {
        let overlay = try MVPFactory.overlay(mask: mask)
        defer { overlay.window.close() }
        #expect(!overlay.isInteractive(at: point))
    }

    @Test("Switches whole-window mouse passthrough as the pointer crosses alpha")
    func windowPassthrough() throws {
        let overlay = try MVPFactory.overlay(mask: mask)
        defer { overlay.window.close() }
        overlay.window.setFrameOrigin(NSPoint(x: 100, y: 100))
        overlay.updatePointer(globalPoint: NSPoint(x: 105, y: 115))
        #expect(overlay.window.ignoresMouseEvents)
        overlay.updatePointer(globalPoint: NSPoint(x: 115, y: 115))
        #expect(!overlay.window.ignoresMouseEvents)
        overlay.updatePointer(globalPoint: NSPoint(x: 500, y: 500))
        #expect(overlay.window.ignoresMouseEvents)
    }

    @Test("A new animation frame immediately replaces its alpha target")
    func frameReplacement() throws {
        let overlay = try MVPFactory.overlay(mask: mask)
        defer { overlay.window.close() }
        try overlay.replaceSprite(with: SpriteMask(width: 2, height: 2, alpha: [255, 0, 0, 255], scale: 10))
        #expect(overlay.isInteractive(at: NSPoint(x: 5, y: 15)))
        #expect(!overlay.isInteractive(at: NSPoint(x: 15, y: 15)))
    }

    @Test("Movement supports negative coordinates and crossing display edges")
    func unboundedMovement() throws {
        let overlay = try MVPFactory.overlay(mask: mask)
        defer { overlay.window.close() }
        overlay.window.setFrameOrigin(NSPoint(x: 10, y: 10))
        overlay.movePet(by: NSSize(width: -200, height: -100))
        #expect(overlay.window.frame.origin == NSPoint(x: -190, y: -90))
        let proposed = NSRect(x: -1_000, y: -100, width: 20, height: 20)
        #expect(overlay.window.constrainFrameRect(proposed, to: NSScreen.main) == proposed)
    }

    @Test("Rejects inconsistent alpha storage")
    func invalidMask() {
        #expect(throws: EngineError.invalidConfiguration) {
            try MVPFactory.overlay(mask: SpriteMask(width: 2, height: 2, alpha: [255], scale: 10))
        }
    }

    @Test("Registers native file URL drops and routes supported types from transparent bounds")
    func fileDrop() throws {
        let overlay = try MVPFactory.overlay(mask: mask)
        defer { overlay.window.close() }
        #expect(overlay.window.contentView?.registeredDraggedTypes.contains(.fileURL) == true)
        var received: [URL] = []
        overlay.onFilesDropped = { received = $0 }
        let word = try fixture("FocusNotes.docx")
        let pdf = try fixture("Research.pdf")
        let unsupported = try fixture("Unsupported.txt")
        // Transparent during pointer use, but the whole bounds accepts file drops.
        #expect(overlay.acceptDrop(urls: [word, unsupported, pdf], at: NSPoint(x: 5, y: 15)))
        #expect(received == [word, pdf])
        #expect(!overlay.acceptDrop(urls: [pdf], at: NSPoint(x: -1, y: 15)))
        #expect(!overlay.acceptDrop(urls: [unsupported], at: NSPoint(x: 5, y: 15)))
        #expect(received == [word, pdf])
    }

    @Test("File dragging temporarily targets the whole frame then restores alpha passthrough")
    func fileDragTargeting() throws {
        let overlay = try MVPFactory.overlay(mask: mask)
        defer { overlay.window.close() }
        overlay.window.setFrameOrigin(NSPoint(x: 100, y: 100))
        overlay.setFileDragActive(true)
        overlay.updatePointer(globalPoint: NSPoint(x: 105, y: 115))
        #expect(!overlay.window.ignoresMouseEvents)
        overlay.setFileDragActive(false)
        overlay.updatePointer(globalPoint: NSPoint(x: 105, y: 115))
        #expect(overlay.window.ignoresMouseEvents)
    }
}
