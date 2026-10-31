import AppKit
import XCTest
import SwiftUI
@testable import KaddoCanvas

final class PetComposerTests: XCTestCase {
    @MainActor
    func testWindowButtonAcceptsInactiveAppClickAndRunsNativeAction() {
        _ = NSApplication.shared
        let button = CompanionControlButton()
        var presses = 0
        let target = CompanionWindowButton.Coordinator { presses += 1 }
        button.target = target
        button.action = #selector(CompanionWindowButton.Coordinator.press)
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        XCTAssertFalse(button.mouseDownCanMoveWindow)
        button.performClick(nil)
        XCTAssertEqual(presses, 1)
    }

    @MainActor
    func testWindowShortcutsHideAndMinimizeWithoutLosingDraft() throws {
        _ = NSApplication.shared
        let state = PetApplicationState()
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost)
        defer { http.cleanUp() }
        let chat = PetChatPresentationState()
        let preferences = CompanionPreferences()
        let canvas = PetCanvasWindowController(model: state, presentation: chat, preferences: preferences,
                                               animationsEnabled: false)
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let controller = NotesQueryWindowController(state: state, assistant: assistant,
                                                   presentation: chat, settings: AssistantSettings())
        controller.attach(to: canvas)
        defer { controller.close(); canvas.close() }
        let panel = try XCTUnwrap(controller.window as? FloatingQuestionPanel)
        func shortcut(_ character: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .command, timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: character == "w" ? 13 : 46))
            XCTAssertTrue(panel.performKeyEquivalent(with: event))
        }
        chat.query = "Keep this draft"
        controller.present()
        try shortcut("m")
        XCTAssertEqual(preferences.mode, .mini)
        XCTAssertFalse(chat.isComposerVisible)
        XCTAssertEqual(chat.query, "Keep this draft")
        try shortcut("m")
        XCTAssertEqual(preferences.mode, .flame)
        try shortcut("w")
        XCTAssertFalse(preferences.isVisible)
        XCTAssertFalse(chat.overlayVisible)
        XCTAssertFalse(chat.isComposerVisible)
        XCTAssertFalse(canvas.window?.isVisible ?? true)
        canvas.showPet()
        XCTAssertTrue(preferences.isVisible)
        XCTAssertTrue(chat.overlayVisible)
        XCTAssertEqual(chat.query, "Keep this draft")
    }

    @MainActor
    func testHoverDebouncesEntryAndAllowsTravelBeforeCollapsing() {
        let presentation = PetChatPresentationState()
        XCTAssertFalse(presentation.isExpanded)
        presentation.updateHover(isInside: true, keepsOpen: false, now: 0)
        presentation.updateHover(isInside: false, keepsOpen: false, now: 0.1)
        XCTAssertFalse(presentation.isExpanded, "Passing the pet must not flash the UI")
        presentation.updateHover(isInside: true, keepsOpen: false, now: 1)
        presentation.updateHover(isInside: true, keepsOpen: false, now: 1.13)
        XCTAssertTrue(presentation.isExpanded)
        presentation.updateHover(isInside: false, keepsOpen: false, now: 2)
        presentation.updateHover(isInside: false, keepsOpen: false, now: 2.5)
        XCTAssertTrue(presentation.isExpanded, "Allow travel to the composer")
        presentation.updateHover(isInside: true, keepsOpen: false, now: 2.6)
        presentation.updateHover(isInside: false, keepsOpen: false, now: 3)
        presentation.updateHover(isInside: false, keepsOpen: false, now: 3.66)
        XCTAssertFalse(presentation.isExpanded)
    }

    @MainActor
    func testEditingAndControlsKeepExpandedAndEscapeRequiresFreshHover() {
        let presentation = PetChatPresentationState()
        presentation.expand()
        presentation.updateHover(isInside: false, keepsOpen: false, now: 0)
        presentation.updateHover(isInside: false, keepsOpen: true, now: 2)
        XCTAssertTrue(presentation.isExpanded)
        presentation.updateHover(isInside: false, keepsOpen: false, now: 3)
        presentation.updateHover(isInside: false, keepsOpen: false, now: 3.66)
        XCTAssertFalse(presentation.isExpanded)
        presentation.expand()
        presentation.collapse()
        presentation.updateHover(isInside: true, keepsOpen: false, now: 4)
        presentation.updateHover(isInside: true, keepsOpen: false, now: 5)
        XCTAssertFalse(presentation.isExpanded, "Escape must not immediately reopen the UI")
        presentation.updateHover(isInside: false, keepsOpen: false, now: 6)
        presentation.updateHover(isInside: true, keepsOpen: false, now: 7)
        presentation.updateHover(isInside: true, keepsOpen: false, now: 7.13)
        XCTAssertTrue(presentation.isExpanded)
    }

    @MainActor
    func testReturnSendsShiftReturnAddsLineAndEscapeDismisses() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 272, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = QuestionTextView(frame: window.contentView!.bounds)
        editor.isRichText = false
        window.contentView?.addSubview(editor)
        window.makeFirstResponder(editor)
        editor.string = "Question"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        var sends = 0, dismissals = 0
        editor.onSubmit = { sends += 1 }
        editor.onDismiss = { dismissals += 1 }
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: code == 53 ? "\u{1b}" : "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: code))
        }
        editor.keyDown(with: try key(36))
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(editor.string, "Question")
        editor.keyDown(with: try key(36, flags: .shift))
        XCTAssertTrue(editor.string.contains("\n"))
        XCTAssertEqual(sends, 1)
        let selectAll = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertTrue(editor.performKeyEquivalent(with: selectAll))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
        editor.keyDown(with: try key(53))
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(ComposerTextEditor.Coordinator.visibleHeight(0), 18)
        XCTAssertEqual(ComposerTextEditor.Coordinator.visibleHeight(35), 35)
        XCTAssertEqual(ComposerTextEditor.Coordinator.visibleHeight(200), 54)
    }

    @MainActor
    func testCommandSubmissionClearsNativeEditorBeforeNextKeyEvent() {
        var text = "/status"
        let parent = ComposerTextEditor(text: Binding(get: { text }, set: { text = $0 }),
            isEnabled: true, onSubmit: { text = "" }, onDismiss: {}, onHeightChange: { _ in })
        let coordinator = ComposerTextEditor.Coordinator(parent)
        let editor = QuestionTextView()
        editor.string = text
        coordinator.submit(editor)
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(editor.selectedRange().location, 0)
        editor.string = "/pause"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertEqual(text, "/pause", "The next command must not contain the previous one")
    }

    func testCombinedLayoutStaysOnNegativeCoordinateScreens() {
        let visible = NSRect(x: -1440, y: -100, width: 1440, height: 900)
        let petSize = NSSize(width: 360, height: 300)
        for proposed in [NSPoint(x: -2000, y: -2000), NSPoint(x: -20, y: 900), NSPoint(x: -1000, y: 100)] {
            let origin = PetChatLayout.constrainedOrigin(proposed, petSize: petSize,
                                                         composerHeight: 70, visibleFrame: visible)
            let pet = NSRect(origin: origin, size: petSize)
            let composer = PetChatLayout.composerFrame(below: pet, height: 70)
            XCTAssertTrue(visible.contains(pet))
            XCTAssertTrue(visible.contains(composer))
            XCTAssertEqual(composer.midX, pet.midX)
            XCTAssertEqual(composer.maxY + 8, pet.minY)
        }
    }

    @MainActor
    func testSpriteStripsHaveDistinctTransparentFramesAndCorrectCadence() throws {
        for emotion in PetEmotion.allCases {
            let frames = try XCTUnwrap(PetSpriteFrames.animations[emotion])
            XCTAssertEqual(frames.count, 6)
            let data = try frames.map { try XCTUnwrap($0.tiffRepresentation) }
            XCTAssertGreaterThan(Set(data).count, 1, "\(emotion) must have actual pose changes")
            let frame = try XCTUnwrap(NSBitmapImageRep(data: data[0]))
            XCTAssertTrue(frame.hasAlpha)
            XCTAssertEqual(frame.colorAt(x: 0, y: 0)?.alphaComponent, 0)
            XCTAssertEqual(PetAnimation.frameIndex(elapsed: 1 / PetAnimation.framesPerSecond(for: emotion),
                                                  emotion: emotion, reducedMotion: false), 1)
            XCTAssertEqual(PetAnimation.frameIndex(elapsed: 100, emotion: emotion, reducedMotion: true),
                           emotion == .celebrating ? 5 : 0)
        }
        XCTAssertEqual(PetAnimation.frameIndex(elapsed: 10, emotion: .celebrating, reducedMotion: false), 5)
        XCTAssertEqual(PetAnimation.frameIndex(elapsed: 1, emotion: .idle, reducedMotion: false), 0)
    }
}
