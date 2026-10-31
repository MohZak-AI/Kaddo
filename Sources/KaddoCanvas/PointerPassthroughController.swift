import AppKit

@MainActor
enum RenderedAlphaHitTester {
    static func containsVisiblePixel(at point: NSPoint, in view: NSView) -> Bool {
        guard view.bounds.contains(point), !view.isHidden, view.alphaValue > 0 else { return false }
        view.layoutSubtreeIfNeeded()
        let scale = view.window?.backingScaleFactor ?? 1
        let pixel = NSRect(
            x: floor(point.x * scale) / scale,
            y: floor(point.y * scale) / scale,
            width: 1 / scale,
            height: 1 / scale
        )
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: pixel) else { return false }
        // A one-device-pixel snapshot includes actual SwiftUI text, shapes and image alpha.
        view.cacheDisplay(in: pixel, to: bitmap)
        return (bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
            .alphaComponent ?? 0) > 0
    }
}

/// NSView.hitTest(nil) alone cannot forward a click to a different application's window.
/// Switch native window passthrough *before* mouse-down; never replay synthetic clicks.
@MainActor
final class PointerPassthroughController {
    private weak var panel: FloatingPetPanel?
    private var timer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var dragPasteboardBaseline = NSPasteboard(name: .drag).changeCount
    private(set) var isCapturingMouse = false
    var isRunning: Bool { timer != nil }

    init(panel: FloatingPetPanel) {
        self.panel = panel
    }

    func start() {
        guard timer == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.refreshPointer() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPointer() }
        }
        // Poll while other apps own the pointer, and when content changes under a stationary
        // pointer. Common mode keeps this running during AppKit's mouse tracking loops.
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPointer() }
        }
        timer.tolerance = 1 / 240
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refreshPointer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        isCapturingMouse = false
        panel?.ignoresMouseEvents = false
    }

    func beginMouseCapture() {
        isCapturingMouse = true
        panel?.ignoresMouseEvents = false
    }

    func endMouseCapture() {
        isCapturingMouse = false
        refreshPointer()
    }

    private func refreshPointer() {
        let leftMouseIsDown = NSEvent.pressedMouseButtons & 1 != 0
        let pasteboard = NSPasteboard(name: .drag)
        if !leftMouseIsDown { dragPasteboardBaseline = pasteboard.changeCount }
        let documentDragIsActive = leftMouseIsDown
            && pasteboard.changeCount != dragPasteboardBaseline
            && (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?
                .contains(where: DocumentDropTypes.accepts) == true
        updatePointer(
            globalPoint: NSEvent.mouseLocation,
            leftMouseIsDown: leftMouseIsDown,
            documentDragIsActive: documentDragIsActive
        )
    }

    func updatePointer(
        globalPoint: NSPoint,
        leftMouseIsDown: Bool = false,
        documentDragIsActive: Bool = false
    ) {
        guard let panel else { return }
        let interacting = (isCapturingMouse && leftMouseIsDown)
            || (documentDragIsActive && panel.frame.contains(globalPoint))
        panel.onPointerUpdate?(globalPoint, interacting)
        // SwiftUI must receive drag entry even above transparent canvas pixels.
        if documentDragIsActive {
            panel.ignoresMouseEvents = false
            return
        }
        // Keep delivering drag/up even if the pet moves or changes alpha below the cursor.
        if isCapturingMouse, leftMouseIsDown {
            panel.ignoresMouseEvents = false
            return
        }
        isCapturingMouse = false
        guard let view = panel.contentView else {
            panel.ignoresMouseEvents = true
            return
        }
        let point = view.convert(panel.convertPoint(fromScreen: globalPoint), from: nil)
        panel.ignoresMouseEvents = !RenderedAlphaHitTester.containsVisiblePixel(at: point, in: view)
    }
}
