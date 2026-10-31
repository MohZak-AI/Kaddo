import AppKit
import SwiftUI

struct CompanionSettingsView: View {
    @ObservedObject var preferences: CompanionPreferences
    @ObservedObject var hotKey: CompanionHotKeyController
    let recover: () -> Void
    @State private var isRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your companion").font(.system(size: 20, weight: .semibold))
            Text("Keep Kaddo close while you study.")
                .foregroundStyle(PetChatStyle.muted)
            Picker("Appearance", selection: $preferences.mode) {
                Text("Flame").tag(CompanionMode.flame)
                Text("Mini").tag(CompanionMode.mini)
            }.pickerStyle(.segmented)
            HStack {
                Text("Flame size")
                Spacer()
                Text("\(Int(preferences.size)) pt").monospacedDigit().foregroundStyle(PetChatStyle.muted)
            }
            Slider(value: $preferences.size, in: 64...144, step: 16)
                .disabled(preferences.mode == .mini).accessibilityLabel("Flame size")
            Button("Reset size") { preferences.size = 96 }
            Divider()
            Toggle("Preview important messages", isOn: $preferences.previewsEnabled)
            Text("Answers, reminders and timer alerts appear for six seconds without taking focus.")
                .font(.system(size: 12)).foregroundStyle(PetChatStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Quick chat shortcut").fontWeight(.medium)
            HStack {
                if isRecording {
                    ShortcutRecorder { shortcut in
                        if let shortcut { hotKey.apply(shortcut) }
                        isRecording = false
                    }.frame(width: 220, height: 32)
                } else {
                    Button(preferences.shortcut?.label ?? "Disabled") { isRecording = true }
                        .frame(minWidth: 140)
                        .accessibilityLabel("Record quick chat shortcut")
                        .accessibilityValue(preferences.shortcut?.label ?? "Disabled")
                }
                Button("Disable") { isRecording = false; hotKey.apply(nil) }
            }
            Button("Use ⌥⇧Space") { isRecording = false; hotKey.apply(.standard) }
            if let error = hotKey.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Record a key with Option, Command, or Control. Escape cancels recording.")
                .font(.system(size: 12)).foregroundStyle(PetChatStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button(preferences.isVisible ? "Hide companion" : "Show companion") {
                    preferences.isVisible.toggle()
                }
                Spacer()
                Button("Recover position", action: recover)
            }
        }
        .font(.system(size: 13))
        .padding(24).frame(width: 380)
        .foregroundStyle(.primary).background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let finish: (CompanionShortcut?) -> Void
    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.finish = finish
        view.setAccessibilityLabel("Press a quick chat shortcut")
        return view
    }
    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) { nsView.finish = finish }
}

private final class ShortcutRecorderView: NSView {
    var finish: ((CompanionShortcut?) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        ("Press shortcut…" as NSString).draw(at: NSPoint(x: 10, y: 8),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { keyDown(with: event); return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish?(nil); return }
        let flags = event.modifierFlags
        guard !flags.intersection([.option, .command, .control]).isEmpty else { return }
        let modifiers: UInt32 = (flags.contains(.command) ? 0x0100 : 0)
            | (flags.contains(.shift) ? 0x0200 : 0) | (flags.contains(.option) ? 0x0800 : 0)
            | (flags.contains(.control) ? 0x1000 : 0)
        let special: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
                                       123: "←", 124: "→", 125: "↓", 126: "↑"]
        let label = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        finish?(.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label))
    }
}

@MainActor
public final class CompanionSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let presentation: PetChatPresentationState

    public init(preferences: CompanionPreferences, hotKey: CompanionHotKeyController,
                presentation: PetChatPresentationState, recover: @escaping () -> Void) {
        self.presentation = presentation
        let window = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow],
                             backing: .buffered, defer: false)
        window.title = "Kaddo Companion"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CompanionSettingsView(
            preferences: preferences, hotKey: hotKey, recover: recover))
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(preferences:hotKey:presentation:recover:)") }

    public func present() {
        presentation.isSettingsOpen = true
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    public func windowWillClose(_ notification: Notification) { presentation.isSettingsOpen = false }
}
