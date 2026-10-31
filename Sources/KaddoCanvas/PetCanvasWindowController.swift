import AppKit
import Combine
import SwiftUI

@MainActor
final class PetHostingView<Content: View>: NSHostingView<Content> {
    // The browser can remain active while the first pet click starts a SwiftUI drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
public final class PetCanvasWindowController: NSWindowController {
    public let model: PetApplicationState
    public let dragController: WindowDragController
    public let preferences: CompanionPreferences
    private let presentation: PetChatPresentationState
    private var observations: [AnyCancellable] = []
    private var restoringPlacement = false

    public init(model: PetApplicationState,
                presentation: PetChatPresentationState = PetChatPresentationState(),
                preferences: CompanionPreferences = CompanionPreferences(),
                animationsEnabled: Bool = true,
                onAskNotes: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.preferences = preferences
        self.presentation = presentation
        let panel = FloatingPetPanel(contentRect: NSRect(origin: .zero, size: preferences.canvasSize))
        dragController = WindowDragController(panel: panel)
        super.init(window: panel)
        let hostingView = PetHostingView(rootView: FloatingPetWindowView(
            model: model,
            dragController: dragController,
            presentation: presentation,
            preferences: preferences, animationsEnabled: animationsEnabled,
            onAskNotes: onAskNotes
        ))
        hostingView.frame = NSRect(origin: .zero, size: preferences.canvasSize)
        panel.contentView = hostingView
        presentation.overlayVisible = preferences.isVisible
        model.activity.configure(visible: preferences.isVisible, previewsEnabled: preferences.previewsEnabled)
        presentation.hideOverlayAction = { [weak self] in self?.hidePet() }
        presentation.miniAction = { [weak preferences] in
            guard let preferences else { return }
            preferences.mode = preferences.mode == .mini ? .flame : .mini
        }
        presentation.recoverAction = { [weak self] in self?.recoverToMainScreen() }
        dragController.onEnd = { [weak self] in self?.savePlacement() }
        for publisher in [preferences.$size.map { _ in () }.eraseToAnyPublisher(),
                          preferences.$mode.map { _ in () }.eraseToAnyPublisher()] {
            observations.append(publisher.dropFirst().sink { [weak self] in
                DispatchQueue.main.async { self?.updateGeometry() }
            })
        }
        observations.append(preferences.$isVisible.dropFirst().sink { [weak self] visible in
            self?.applyVisibility(visible)
        })
        observations.append(preferences.$previewsEnabled.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            self.model.activity.configure(visible: self.preferences.isVisible, previewsEnabled: enabled)
        })
        observations.append(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.restorePlacement() })
        observations.append(NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.savePlacement() })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    public func showPet() {
        if !preferences.isVisible { preferences.isVisible = true }
        applyVisibility(true)
    }

    public func hidePet() {
        if preferences.isVisible { preferences.isVisible = false }
        applyVisibility(false)
    }

    private func applyVisibility(_ visible: Bool) {
        guard let panel = window as? FloatingPetPanel else { return }
        presentation.overlayVisible = visible
        model.activity.configure(visible: visible, previewsEnabled: preferences.previewsEnabled)
        if visible { panel.orderFrontRegardless(); panel.startAlphaTracking() }
        else {
            dragController.end()
            panel.stopAlphaTracking()
            panel.orderOut(nil)
        }
    }

    private func updateGeometry() {
        guard let window else { return }
        window.setContentSize(preferences.canvasSize)
        if let frame = CompanionPlacementResolver.origin(saved: currentPlacement(), screens: CompanionScreen.current,
            petSize: window.frame.size, composerHeight: presentation.composerHeight) {
            window.setFrameOrigin(frame)
        }
        savePlacement()
    }

    public func restorePlacement() {
        guard let window else { return }
        restoringPlacement = true
        defer { restoringPlacement = false }
        if let origin = CompanionPlacementResolver.origin(saved: preferences.placement,
            screens: CompanionScreen.current, petSize: window.frame.size,
            composerHeight: presentation.composerHeight) { window.setFrameOrigin(origin) }
        applyVisibility(preferences.isVisible)
    }

    private func currentPlacement() -> CompanionPlacement? {
        guard let window else { return nil }
        let screens = CompanionScreen.current
        guard let screen = screens.max(by: {
            let a = $0.visibleFrame.intersection(window.frame)
            let b = $1.visibleFrame.intersection(window.frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }) else { return nil }
        return CompanionPlacement(displayID: screen.id, x: window.frame.minX - screen.visibleFrame.minX,
                                  y: window.frame.minY - screen.visibleFrame.minY)
    }

    private func savePlacement() {
        guard !restoringPlacement else { return }
        if let placement = currentPlacement(), placement != preferences.placement { preferences.placement = placement }
    }

    public func recoverToMainScreen() {
        dragController.end()
        guard let screen = NSScreen.main, let window else { return }
        let visible = screen.visibleFrame
        let proposed = NSPoint(x: visible.maxX - window.frame.width - 24,
                               y: visible.minY + presentation.composerHeight + 16)
        window.setFrameOrigin(PetChatLayout.constrainedOrigin(proposed, petSize: window.frame.size,
            composerHeight: presentation.composerHeight, visibleFrame: visible))
        savePlacement()
        showPet()
    }

    public override func close() {
        dragController.end()
        super.close()
    }
}
