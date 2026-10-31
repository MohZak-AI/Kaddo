import AppKit
import XCTest
@testable import KaddoCanvas

final class NotesQueryWindowTests: XCTestCase {
    @MainActor
    func testHoverRevealsWithoutFocusAndCollapsesWithoutCancellingInference() async throws {
        _ = NSApplication.shared
        let http = Phase4HTTPHarness(json: "", holdOpen: true,
                                     modelCatalog: #"{"models":[{"name":"local:test"}]}"#)
        defer { http.cleanUp() }
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("Research.pdf"))
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let controller = NotesQueryWindowController(state: state, assistant: assistant,
                                                    settings: AssistantSettings())
        let canvas = PetCanvasWindowController(model: state, presentation: controller.presentation,
                                               animationsEnabled: false)
        defer { controller.close(); canvas.close() }
        canvas.recoverToMainScreen()
        // Restricted test hosts may have no NSScreen.main for the recovery helper.
        canvas.showPet()
        controller.attach(to: canvas)
        // Drive the existing native pointer callback deterministically in this test.
        (canvas.window as? FloatingPetPanel)?.stopAlphaTracking()
        let pet = try XCTUnwrap(canvas.window)
        let composer = try XCTUnwrap(controller.window)
        let origin = pet.frame.origin
        let sprite = PetChatLayout.spriteFrame(in: pet.frame)
        let overPet = NSPoint(x: sprite.midX, y: sprite.midY)
        let away = NSPoint(x: pet.frame.minX - 100, y: pet.frame.minY)
        XCTAssertFalse(composer.isVisible)
        XCTAssertFalse(controller.presentation.isExpanded)
        XCTAssertTrue(pet.isVisible, "The pet must be visible before hover: \(pet.frame)")
        controller.updateHover(globalPoint: overPet, now: 1)
        controller.updateHover(globalPoint: overPet, now: 1.13)
        XCTAssertTrue(controller.presentation.isExpanded, "Hover point \(overPet), pet \(pet.frame), visible \(pet.isVisible)")
        XCTAssertTrue(composer.isVisible)
        XCTAssertFalse(composer.isKeyWindow, "Hover must not steal keyboard focus")
        XCTAssertEqual(pet.frame.origin, origin, "Hover must not move the pet")
        let gap = NSPoint(x: pet.frame.midX, y: pet.frame.minY - 4)
        controller.updateHover(globalPoint: gap, now: 2)
        controller.updateHover(globalPoint: gap, now: 3)
        XCTAssertTrue(controller.presentation.isExpanded)

        let answer = Task { await assistant.answer(query: "orchid", model: "local:test") }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(assistant.isAnswering)
        controller.presentation.query = "Saved draft"
        controller.updateHover(globalPoint: away, now: 4)
        controller.updateHover(globalPoint: away, now: 4.66)
        XCTAssertFalse(controller.presentation.isExpanded)
        XCTAssertTrue(composer.ignoresMouseEvents)
        XCTAssertEqual(controller.presentation.query, "Saved draft")
        XCTAssertTrue(assistant.isAnswering, "Auto-collapse must let the reply continue")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(composer.isVisible)
        controller.updateHover(globalPoint: overPet, now: 5)
        controller.updateHover(globalPoint: overPet, now: 5.13)
        XCTAssertTrue(controller.presentation.isExpanded)
        XCTAssertFalse(composer.ignoresMouseEvents)
        controller.presentation.showsControls = true
        controller.updateHover(globalPoint: away, now: 6)
        controller.updateHover(globalPoint: away, now: 7)
        XCTAssertTrue(controller.presentation.isExpanded, "Settings remain usable outside the pet bounds")
        controller.hide()
        await answer.value
        XCTAssertFalse(assistant.isAnswering, "Explicit Escape still cancels")
    }

    @MainActor
    func testComposerFocusGeometryAndReopenPreserveQuestion() async throws {
        _ = NSApplication.shared
        let http = Phase4HTTPHarness(json: "", modelCatalog: #"{"models":[{"name":"local:test"}]}"#)
        defer { http.cleanUp() }
        let state = PetApplicationState()
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let controller = NotesQueryWindowController(state: state, assistant: assistant, settings: AssistantSettings())
        let canvas = PetCanvasWindowController(model: state, presentation: controller.presentation,
                                                animationsEnabled: false)
        defer { controller.close(); canvas.close() }
        canvas.recoverToMainScreen()
        controller.attach(to: canvas)
        controller.present()
        try await Task.sleep(for: .milliseconds(100))
        let pet = try XCTUnwrap(canvas.window)
        let composer = try XCTUnwrap(controller.window)
        XCTAssertTrue(composer.canBecomeKey)
        XCTAssertFalse(composer.canBecomeMain)
        XCTAssertFalse(pet.canBecomeKey)
        XCTAssertFalse(composer.styleMask.contains(.titled))
        XCTAssertEqual(composer.frame.width, 360)
        XCTAssertEqual(composer.frame.height, 44)
        XCTAssertEqual(composer.frame.midX, pet.frame.midX)
        XCTAssertEqual(composer.frame.maxY + 8, pet.frame.minY)
        XCTAssertTrue(composer.parent === pet)
        XCTAssertTrue(composer.firstResponder is QuestionTextView)
        XCTAssertEqual(controller.presentation.modelName, "local:test")
        if let directory = snapshotDirectory {
            try snapshot(composer.contentView!).write(to: directory.appendingPathComponent("composer-idle-native.png"))
            try saveAssembly(pet: pet, composer: composer,
                             to: directory.appendingPathComponent("composer-idle-native-preview.png"))
            controller.presentation.showsControls = true
            try await Task.sleep(for: .milliseconds(150))
            let popover = try XCTUnwrap(NSApp.windows.first {
                $0.isVisible && $0.className.contains("Popover")
            })
            try snapshot(popover.contentView!).write(to: directory.appendingPathComponent("composer-controls-native.png"))
            controller.settings.provider = .openAI
            try await Task.sleep(for: .milliseconds(150))
            try snapshot(popover.contentView!).write(to: directory.appendingPathComponent("composer-openai-settings-native.png"))
            controller.presentation.showsControls = false
        }
        controller.presentation.query = "Keep this draft"
        controller.hide()
        XCTAssertFalse(controller.presentation.isComposerVisible)
        XCTAssertFalse(composer.isVisible)
        controller.present()
        XCTAssertTrue(controller.presentation.isComposerVisible)
        XCTAssertEqual(controller.presentation.query, "Keep this draft")
        controller.presentation.composerHeight = 70
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(composer.frame.height, 70)
        XCTAssertEqual(composer.frame.maxY + 8, pet.frame.minY)
    }

    @MainActor
    func testComposerFollowsPetAndAnswerRendersAboveSpriteWithCitations() async throws {
        _ = NSApplication.shared
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("Research.pdf"))
        let source = try XCTUnwrap(state.documentMemory.chunks.first)
        let line = try speechObject("Water orchids every week.", emotion: "celebrating", ids: [source.id])
        let http = Phase4HTTPHarness(json: try inferenceRecord("{\"lines\":[\(line)]}", done: true),
                                     modelCatalog: #"{"models":[{"name":"local:test"}]}"#)
        defer { http.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let controller = NotesQueryWindowController(state: state, assistant: assistant, settings: AssistantSettings())
        let canvas = PetCanvasWindowController(model: state, presentation: controller.presentation,
                                                animationsEnabled: false)
        defer { controller.close(); canvas.close() }
        canvas.recoverToMainScreen()
        controller.attach(to: canvas)
        controller.present()
        try await Task.sleep(for: .milliseconds(100))
        let host = try XCTUnwrap(canvas.window?.contentView)
        let before = try snapshot(host)
        let pet = try XCTUnwrap(canvas.window)
        let composer = try XCTUnwrap(controller.window)
        pet.setFrameOrigin(NSPoint(x: pet.frame.minX - 30, y: pet.frame.minY + 30))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(composer.frame.midX, pet.frame.midX)
        XCTAssertEqual(composer.frame.maxY + 8, pet.frame.minY)
        await assistant.answer(query: "orchid", model: "local:test")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.presentation.sources, [source])
        XCTAssertEqual(state.speechBubbleText, "Water orchids every week.")
        XCTAssertNotEqual(try snapshot(host), before)
        if let directory = snapshotDirectory {
            try saveAssembly(pet: pet, composer: composer,
                             to: directory.appendingPathComponent("composer-answer-native-preview.png"))
        }
        state.createSession(title: "Empty session")
        XCTAssertTrue(controller.presentation.sources.isEmpty)
    }

    @MainActor
    func testEscapeCancelsOpenInferenceAndOfflineServiceOffersRetry() async throws {
        _ = NSApplication.shared
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("Research.pdf"))
        let http = Phase4HTTPHarness(json: "", holdOpen: true,
                                     modelCatalog: #"{"models":[{"name":"local:test"}]}"#)
        defer { http.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let controller = NotesQueryWindowController(state: state, assistant: assistant, settings: AssistantSettings())
        let canvas = PetCanvasWindowController(model: state, presentation: controller.presentation,
                                                animationsEnabled: false)
        defer { controller.close(); canvas.close() }
        canvas.recoverToMainScreen()
        controller.attach(to: canvas)
        controller.present()
        try await Task.sleep(for: .milliseconds(50))
        let answer = Task { await assistant.answer(query: "orchid", model: "local:test") }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(assistant.isAnswering)
        if let directory = snapshotDirectory {
            try snapshot(controller.window!.contentView!).write(
                to: directory.appendingPathComponent("composer-thinking-native.png"))
            try saveAssembly(pet: canvas.window!, composer: controller.window!,
                             to: directory.appendingPathComponent("composer-thinking-native-preview.png"))
        }
        (controller.window as? FloatingQuestionPanel)?.cancelOperation(nil)
        await answer.value
        XCTAssertFalse(assistant.isAnswering)
        XCTAssertFalse(controller.presentation.isComposerVisible)
        XCTAssertEqual(state.currentEmotion, .idle)
        XCTAssertEqual(state.speechBubbleText, "Answer cancelled.")

        let offline = Phase4HTTPHarness(failure: .cannotConnectToHost)
        defer { offline.cleanUp() }
        let other = NotesQueryWindowController(state: state,
            assistant: LocalNotesAssistant(state: state, client: try OllamaClient(session: offline.session)))
        defer { other.close() }
        state.student.handle("/task Review lecture notes")
        let studentReply = state.speechBubbleText
        other.present()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(other.presentation.modelName.isEmpty)
        XCTAssertNil(other.presentation.retryTitle)
        XCTAssertEqual(state.speechBubbleText, studentReply, "Model discovery must preserve student command responses")
        XCTAssertEqual(other.presentation.modelStatus, LocalInferenceError.serviceUnavailable.localizedDescription)
        other.presentation.query = "/ask A document question"
        other.submit()
        XCTAssertEqual(other.presentation.retryTitle, "Refresh models")
        XCTAssertTrue(state.speechBubbleText.contains("Student commands work now"))
    }

    @MainActor
    func testNativeKeyboardRunsNaturalActionsAndPreservesSeparateChat() async throws {
        _ = NSApplication.shared
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost)
        defer { http.cleanUp() }
        let state = PetApplicationState()
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let controller = NotesQueryWindowController(state: state, assistant: assistant, settings: AssistantSettings())
        defer { controller.close() }
        controller.present()
        try await Task.sleep(for: .milliseconds(50))
        let editor = try XCTUnwrap(controller.window?.firstResponder as? QuestionTextView)
        func typeAndSend(_ text: String) throws {
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            editor.keyDown(with: event)
            XCTAssertEqual(editor.string, "")
        }
        try typeAndSend("start a 25-minute timer")
        XCTAssertEqual(state.student.timer?.remaining, 1500)
        try typeAndSend("pause it")
        XCTAssertEqual(state.student.timer?.status, .paused)
        try typeAndSend("hello")
        XCTAssertEqual(state.student.timer?.status, .paused)
        XCTAssertEqual(state.currentEmotion, .happy)
        XCTAssertFalse(state.speechBubbleText.contains("please use /"))
        try typeAndSend("stop it")
        XCTAssertNil(state.student.timer)
        XCTAssertFalse(http.requests.contains { $0.url?.path == "/api/generate" })
    }

    @MainActor
    private var snapshotDirectory: URL? {
        ProcessInfo.processInfo.environment["KADDO_COMPOSER_ARTIFACTS"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    /// Native view renders on a dark backdrop for reviewing the two-panel composition.
    /// These are labelled previews, separately from actual running-app CUA captures.
    @MainActor
    private func saveAssembly(pet: NSWindow, composer: NSWindow, to url: URL) throws {
        let union = pet.frame.union(composer.frame)
        let rendered = NSImage(size: union.size)
        let images = try [pet, composer].map { window in
            try XCTUnwrap(NSImage(data: snapshot(window.contentView!)))
        }
        rendered.lockFocus()
        NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
        NSRect(origin: .zero, size: union.size).fill()
        for (window, image) in zip([pet, composer], images) {
            image.draw(in: NSRect(x: window.frame.minX - union.minX, y: window.frame.minY - union.minY,
                                 width: window.frame.width, height: window.frame.height))
        }
        rendered.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(rendered.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    @MainActor
    private func snapshot(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
