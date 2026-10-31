import AppKit

@MainActor
public final class WindowDragController {
    private weak var panel: FloatingPetPanel?
    private var initialOrigin: NSPoint?
    private var initialPointer: NSPoint?
    public var onEnd: (() -> Void)?
    public var constrainOrigin: ((NSPoint) -> NSPoint)?

    public init(panel: FloatingPetPanel) {
        self.panel = panel
    }

    public func begin(at screenPoint: NSPoint) {
        guard initialOrigin == nil, let panel else { return }
        initialOrigin = panel.frame.origin
        initialPointer = screenPoint
    }

    public func update(to screenPoint: NSPoint) {
        guard let initialOrigin, let initialPointer else { return }
        // Screen coordinates stay stable as the hosting window itself moves. Applying
        // cumulative SwiftUI translation to the current window origin causes drift.
        let proposed = NSPoint(
            x: initialOrigin.x + screenPoint.x - initialPointer.x,
            y: initialOrigin.y + screenPoint.y - initialPointer.y
        )
        panel?.setFrameOrigin(constrainOrigin?(proposed) ?? proposed)
    }

    public func end() {
        let wasDragging = initialOrigin != nil
        initialOrigin = nil
        initialPointer = nil
        if wasDragging { onEnd?() }
    }
}
