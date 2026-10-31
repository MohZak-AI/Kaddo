import AppKit
import SwiftUI

final class QuestionTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onDismiss: (() -> Void)?
    var placeholder = "Ask anything, or give me a task…"

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleEditingShortcut(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleEditingShortcut(event) { return }
        if !hasMarkedText(), event.keyCode == 53 { onDismiss?(); return }
        if !hasMarkedText(), [36, 76].contains(event.keyCode),
           !event.modifierFlags.contains(.shift) { onSubmit?(); return }
        super.keyDown(with: event)
    }

    private func handleEditingShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), !hasMarkedText() else { return false }
        // Accessory apps have no standard Edit menu to route these to the first responder.
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": pasteAsPlainText(nil)
        case "z":
            if event.modifierFlags.contains(.shift) { undoManager?.redo() }
            else { undoManager?.undo() }
        default: return false
        }
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(
                at: NSPoint(x: 0, y: 0),
                withAttributes: [.font: NSFont.systemFont(ofSize: 14),
                                 .foregroundColor: NSColor.placeholderTextColor])
        }
    }
}

struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    var placeholder: String = "Ask anything, or give me a task…"
    let onSubmit: () -> Void
    let onDismiss: () -> Void
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let editor = QuestionTextView(frame: NSRect(x: 0, y: 0, width: 272, height: 18))
        editor.isRichText = false
        editor.allowsUndo = true
        editor.importsGraphics = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.drawsBackground = false
        editor.textColor = .textColor
        editor.insertionPointColor = .textColor
        editor.font = .systemFont(ofSize: 14)
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Kaddo message or action")
        editor.setAccessibilityIdentifier("questionInput")
        editor.placeholder = placeholder
        editor.setAccessibilityHelp(placeholder)
        editor.delegate = context.coordinator
        editor.onSubmit = { [weak coordinator = context.coordinator, weak editor] in
            guard let editor else { return }
            coordinator?.submit(editor)
        }
        editor.onDismiss = onDismiss
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? QuestionTextView else { return }
        if editor.string != text { editor.string = text }
        editor.isEditable = isEnabled
        editor.placeholder = placeholder
        editor.setAccessibilityHelp(placeholder)
        editor.onDismiss = onDismiss
        editor.needsDisplay = true
        context.coordinator.measure(editor)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextEditor
        private var lastHeight: CGFloat = 0
        init(_ parent: ComposerTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? QuestionTextView else { return }
            parent.text = editor.string
            editor.needsDisplay = true
            measure(editor)
        }

        func submit(_ editor: QuestionTextView) {
            parent.onSubmit()
            // Commands clear the binding synchronously. Reflect that before another
            // key event can append to the command awaiting SwiftUI's next render pass.
            if editor.string != parent.text {
                editor.string = parent.text
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                editor.needsDisplay = true
                measure(editor)
            }
        }

        func measure(_ editor: NSTextView) {
            guard let manager = editor.layoutManager, let container = editor.textContainer else { return }
            manager.ensureLayout(for: container)
            let height = Self.visibleHeight(manager.usedRect(for: container).height)
            guard height != lastHeight else { return }
            lastHeight = height
            // Never publish state during NSViewRepresentable's update pass.
            DispatchQueue.main.async { [weak self] in self?.parent.onHeightChange(height) }
        }

        static func visibleHeight(_ measured: CGFloat) -> CGFloat {
            min(54, max(18, ceil(measured)))
        }
    }
}
