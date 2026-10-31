import AppKit
import Combine
import SwiftUI

enum PetChatStyle {
    static let blue = Color(red: 57 / 255, green: 118 / 255, blue: 203 / 255)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let controlFill = Color.primary.opacity(0.06)
    static let width: CGFloat = 360
    static let barHeight: CGFloat = 44
    static let gap: CGFloat = 8
}

/// UI-only state shared by the two native panels; no conversation is persisted.
@MainActor
public final class PetChatPresentationState: ObservableObject {
    @Published public internal(set) var isExpanded = false
    @Published public internal(set) var isComposerVisible = false
    @Published public var knowledgeCategoryID: UUID?
    @Published var query = ""
    @Published var modelName = ""
    @Published var models: [String] = []
    @Published var modelStatus = "Checking Ollama…"
    @Published var isCheckingModels = false
    @Published var showsControls = false
    @Published var isSettingsOpen = false
    @Published var isDragging = false
    @Published var isHovered = false
    @Published var overlayVisible = true
    var hideOverlayAction: (@MainActor () -> Void)?
    public var settingsAction: (@MainActor () -> Void)?
    var miniAction: (@MainActor () -> Void)?
    var recoverAction: (@MainActor () -> Void)?
    @Published var sources: [DocumentChunk] = []
    @Published var composerHeight: CGFloat = PetChatStyle.barHeight
    @Published var retryTitle: String?
    var retryAction: (@MainActor () -> Void)?
    var addDocumentAction: (@MainActor () -> Void)?
    private var hoverEnteredAt: TimeInterval?
    private var hoverExitedAt: TimeInterval?
    private var waitsForPointerExit = false

    public init() {}

    var hasQuestion: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func expand() {
        waitsForPointerExit = false
        hoverEnteredAt = nil
        hoverExitedAt = nil
        isExpanded = true
    }

    func collapse() {
        // Escape must remain effective while the pointer is still over the pet.
        waitsForPointerExit = true
        hoverEnteredAt = nil
        hoverExitedAt = nil
        isExpanded = false
    }

    func updateHover(isInside: Bool, keepsOpen: Bool, now: TimeInterval) {
        if waitsForPointerExit {
            guard !isInside else { return }
            waitsForPointerExit = false
        }
        if keepsOpen {
            hoverEnteredAt = nil
            hoverExitedAt = nil
            if !isExpanded { isExpanded = true }
        } else if isInside {
            hoverExitedAt = nil
            guard !isExpanded else { return }
            if hoverEnteredAt == nil { hoverEnteredAt = now }
            // Avoid flashing controls when the pointer just passes the pet.
            if now - (hoverEnteredAt ?? now) >= 0.12 { isExpanded = true }
        } else {
            hoverEnteredAt = nil
            guard isExpanded else { return }
            if hoverExitedAt == nil { hoverExitedAt = now }
            // Allow travel between the pet, speech bubble and composer.
            if now - (hoverExitedAt ?? now) >= 0.65 { isExpanded = false }
        }
    }
}

enum PetChatLayout {
    static func spriteFrame(in pet: NSRect, anchorSize: NSSize = NSSize(width: 108, height: 108)) -> NSRect {
        NSRect(x: pet.midX - anchorSize.width / 2, y: pet.minY,
               width: anchorSize.width, height: anchorSize.height)
    }

    static func composerFrame(below pet: NSRect, height: CGFloat) -> NSRect {
        NSRect(x: pet.midX - PetChatStyle.width / 2,
               y: pet.minY - PetChatStyle.gap - height,
               width: PetChatStyle.width, height: height)
    }

    static func constrainedOrigin(
        _ proposed: NSPoint, petSize: NSSize, composerHeight: CGFloat?, visibleFrame: NSRect
    ) -> NSPoint {
        let bottomSpace = composerHeight.map { $0 + PetChatStyle.gap } ?? 0
        let minimumX = visibleFrame.minX + max(0, (PetChatStyle.width - petSize.width) / 2)
        let maximumX = visibleFrame.maxX - max(petSize.width, (petSize.width + PetChatStyle.width) / 2)
        let minimumY = visibleFrame.minY + bottomSpace
        let maximumY = max(minimumY, visibleFrame.maxY - petSize.height)
        return NSPoint(x: min(max(proposed.x, minimumX), max(minimumX, maximumX)),
                       y: min(max(proposed.y, minimumY), maximumY))
    }
}
