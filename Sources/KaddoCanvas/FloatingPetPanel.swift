import AppKit

/// A nonactivating canvas above ordinary application windows on every Space.
@MainActor
public final class FloatingPetPanel: NSPanel {
    private var pointerTracker: PointerPassthroughController?
    var isTrackingPointer: Bool { pointerTracker != nil }
    var onPointerUpdate: ((NSPoint, Bool) -> Void)?

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // isFloatingPanel resets the level, so assign our priority afterwards.
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = false
        animationBehavior = .none
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// Call after installing the hosting view. Closing the panel removes all monitors.
    public func startAlphaTracking() {
        guard pointerTracker == nil else { return }
        let tracker = PointerPassthroughController(panel: self)
        pointerTracker = tracker
        tracker.start()
    }

    public func stopAlphaTracking() {
        pointerTracker?.stop()
        pointerTracker = nil
        ignoresMouseEvents = false
    }

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            pointerTracker?.beginMouseCapture()
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp {
            pointerTracker?.endMouseCapture()
        }
    }

    public override func close() {
        stopAlphaTracking()
        super.close()
    }

    // Pets can cross menu bars and screens whose origins have negative coordinates.
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
