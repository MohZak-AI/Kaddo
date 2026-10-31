import AppKit
import SwiftUI

/// Window controls must respond on the first click while another app is active.
final class CompanionControlButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

struct CompanionWindowButton: NSViewRepresentable {
    let symbol: String
    let label: String
    let help: String
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> CompanionControlButton {
        let button = CompanionControlButton()
        button.bezelStyle = .circular
        button.isBordered = true
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.press)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: CompanionControlButton, context: Context) {
        context.coordinator.action = action
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = help
        button.setAccessibilityLabel(label)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func press() { action() }
    }
}
