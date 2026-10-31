import AppKit
import Carbon
import Combine
import SwiftUI
import XCTest
@testable import KaddoCanvas

final class CompanionExperienceTests: XCTestCase {
    @MainActor
    func testActivityPriorityAndQuestionAcknowledgement() {
        let store = PetActivityStore()
        XCTAssertEqual(store.state, .idle)
        let work = store.begin(title: "Answer")
        XCTAssertEqual(store.state, .running)
        let ready = store.record(title: "Timer", message: "Done")
        XCTAssertEqual(store.state, .ready)
        let blocked = store.record(title: "Import", message: "Unreadable file", state: .blocked)
        XCTAssertEqual(store.state, .blocked)
        let question = UUID()
        store.setQuestion(question, message: "Which task?")
        store.open(question)
        XCTAssertEqual(store.state, .needsInput, "Reading a question does not answer it")
        store.setQuestion(question, message: nil)
        XCTAssertEqual(store.state, .blocked)
        store.open(blocked)
        XCTAssertEqual(store.state, .ready)
        store.open(ready)
        XCTAssertEqual(store.state, .running)
        store.cancel(work)
        XCTAssertEqual(store.state, .idle)
    }

    @MainActor
    func testCancelledOrClearedOperationsCannotPublishLateResults() {
        let store = PetActivityStore()
        let first = store.begin(title: "Old request")
        store.cancel(first)
        let second = store.begin(title: "Current request")
        store.finish(first, state: .ready, message: "Stale")
        XCTAssertEqual(store.items.map(\.id), [second])
        store.clear()
        store.finish(second, state: .ready, message: "Also stale")
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.hasRunning)
        XCTAssertNil(store.preview)
    }

    @MainActor
    func testBoundedSnapshotsPreserveCitationsAndDoNotTouchLiveState() {
        let state = PetApplicationState(speechBubbleText: "Still streaming")
        let store = state.activity
        for n in 0..<25 { store.record(title: "Reminder", message: "\(n)") }
        XCTAssertEqual(store.items.count, 20)
        let source = DocumentChunk(id: UUID(), documentID: UUID(), filename: "Biology.pdf",
                                   index: 2, text: "Evidence")
        let id = store.begin(title: "Document answer")
        store.finish(id, state: .ready, message: "Captured answer", sources: [source])
        let session = state.activeSessionID
        store.open(id)
        XCTAssertEqual(store.selected?.sources, [source])
        XCTAssertEqual(state.activeSessionID, session)
        XCTAssertEqual(state.speechBubbleText, "Still streaming")
        XCTAssertFalse(store.items.first!.unread)
    }

    @MainActor
    func testLongRunningResultReturnsToTopAfterItsRunningRowWasEvicted() {
        let store = PetActivityStore()
        let id = store.begin(title: "Long document answer")
        for number in 0..<25 { store.record(title: "Reminder", message: "\(number)") }
        XCTAssertFalse(store.items.contains { $0.id == id })
        XCTAssertTrue(store.hasRunning)
        store.finish(id, state: .ready, message: "Completed answer", preview: true)
        XCTAssertEqual(store.items.count, 20)
        XCTAssertEqual(store.items.first?.id, id)
        XCTAssertEqual(store.items.first?.message, "Completed answer")
        XCTAssertFalse(store.hasRunning)
    }

    @MainActor
    func testPreviewQueueSixSecondsHoverPauseAndBusyUI() {
        let store = PetActivityStore()
        let first = store.record(title: "Answer", message: "Finished", preview: true)
        let second = store.record(title: "Reminder", message: "Stand up", preview: true)
        store.tick(now: 0, busy: true, hovered: false)
        XCTAssertNil(store.preview)
        store.tick(now: 5, busy: false, hovered: false)
        XCTAssertEqual(store.preview?.id, first)
        store.tick(now: 10, busy: false, hovered: true)
        store.tick(now: 20, busy: true, hovered: false)
        XCTAssertEqual(store.preview?.id, first)
        store.tick(now: 25, busy: false, hovered: false)
        XCTAssertEqual(store.preview?.id, first)
        store.tick(now: 26.01, busy: false, hovered: false)
        XCTAssertEqual(store.preview?.id, second)
        store.tick(now: 32.02, busy: false, hovered: false)
        XCTAssertNil(store.preview)
        XCTAssertEqual(store.unreadCount, 2, "A passive preview does not acknowledge an item")
    }

    @MainActor
    func testExplicitHideAndDisabledPreviewsDoNotReplayQueuedMessages() {
        let store = PetActivityStore()
        store.record(title: "Answer", message: "Finished", preview: true)
        store.configure(visible: false, previewsEnabled: true)
        store.record(title: "Reminder", message: "Hidden", preview: true)
        store.configure(visible: true, previewsEnabled: true)
        store.tick(now: 0, busy: false, hovered: false)
        XCTAssertNil(store.preview)
        XCTAssertEqual(store.unreadCount, 2)
        store.configure(visible: true, previewsEnabled: false)
        store.record(title: "Answer", message: "Disabled", preview: true)
        store.tick(now: 10, busy: false, hovered: false)
        XCTAssertNil(store.preview)
    }

    @MainActor
    func testPreferencesRoundTripAndDefensiveSizeBounds() throws {
        let suite = "KaddoCompanionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CompanionPreferences(defaults: defaults)
        XCTAssertEqual(preferences.size, 96)
        XCTAssertEqual(preferences.shortcut, .standard)
        preferences.mode = .mini; preferences.isVisible = false; preferences.previewsEnabled = false
        preferences.size = 900
        preferences.placement = .init(displayID: 2, x: 100, y: 80)
        preferences.saveShortcut(nil)
        let restored = CompanionPreferences(defaults: defaults)
        XCTAssertEqual(restored.mode, .mini)
        XCTAssertFalse(restored.isVisible)
        XCTAssertFalse(restored.previewsEnabled)
        XCTAssertEqual(restored.size, 144)
        XCTAssertNil(restored.shortcut)
        XCTAssertEqual(restored.placement, preferences.placement)
        restored.size = -.infinity
        XCTAssertEqual(restored.size, 96)
        restored.size = 1
        XCTAssertEqual(restored.size, 64)
    }

    @MainActor
    func testPlacementRestoresNegativeScreenAndRecoversMissingDisplay() throws {
        let screens = [CompanionScreen(id: 1, visibleFrame: NSRect(x: 0, y: 24, width: 1440, height: 850)),
                       CompanionScreen(id: 2, visibleFrame: NSRect(x: -1280, y: -200, width: 1280, height: 900))]
        let prefs = CompanionPreferences()
        for size in [64.0, 96, 144] {
            prefs.size = size
            for mode in CompanionMode.allCases {
                prefs.mode = mode
                let origin = try XCTUnwrap(CompanionPlacementResolver.origin(
                    saved: .init(displayID: 2, x: -500, y: -900), screens: screens,
                    petSize: prefs.canvasSize, composerHeight: 70))
                let pet = NSRect(origin: origin, size: prefs.canvasSize)
                XCTAssertTrue(screens[1].visibleFrame.contains(pet))
                XCTAssertTrue(screens[1].visibleFrame.contains(PetChatLayout.composerFrame(below: pet, height: 70)))
            }
        }
        let recovered = try XCTUnwrap(CompanionPlacementResolver.origin(
            saved: .init(displayID: 99, x: 10000, y: .nan), screens: screens,
            petSize: prefs.canvasSize, composerHeight: 44))
        XCTAssertTrue(screens[0].visibleFrame.contains(NSRect(origin: recovered, size: prefs.canvasSize)))
        XCTAssertNil(CompanionPlacementResolver.origin(saved: nil, screens: [],
                                                       petSize: prefs.canvasSize, composerHeight: 44))
    }

    @MainActor
    func testHotKeyConflictKeepsPreviousBindingAndRepeatedInvocationFocuses() {
        let preferences = CompanionPreferences()
        let registrar = TestHotKeyRegistrar()
        var invocations = 0
        let controller = CompanionHotKeyController(preferences: preferences, registrar: registrar) { invocations += 1 }
        registrar.action?(); registrar.action?()
        XCTAssertEqual(invocations, 2)
        XCTAssertEqual(registrar.registered, .standard)
        registrar.accept = false
        let replacement = CompanionShortcut(keyCode: 0, modifiers: 0x0100 | 0x0800, keyLabel: "A")
        XCTAssertFalse(controller.apply(replacement))
        XCTAssertNotNil(controller.error)
        XCTAssertEqual(preferences.shortcut, .standard)
        XCTAssertEqual(registrar.registered, .standard)
        XCTAssertTrue(controller.apply(nil))
        XCTAssertNil(preferences.shortcut)
        XCTAssertNil(registrar.registered)
    }

    @MainActor
    func testHidePreservesRequestAndDraftWhileEscapeCancels() async throws {
        _ = NSApplication.shared
        let http = Phase4HTTPHarness(json: "", holdOpen: true,
                                     modelCatalog: #"{"models":[{"name":"local:test"}]}"#)
        defer { http.cleanUp() }
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("Research.pdf"))
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let controller = NotesQueryWindowController(state: state, assistant: assistant, settings: AssistantSettings())
        let canvas = PetCanvasWindowController(model: state, presentation: controller.presentation, animationsEnabled: false)
        defer { controller.close(); canvas.close() }
        canvas.showPet(); controller.attach(to: canvas); controller.present()
        controller.presentation.modelName = "local:test"
        controller.presentation.query = "/ask orchid"
        controller.submit()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(assistant.isAnswering)
        controller.presentation.query = "Keep this draft"
        canvas.hidePet()
        XCTAssertFalse(canvas.window!.isVisible)
        XCTAssertFalse(controller.window!.isVisible)
        XCTAssertFalse((canvas.window as! FloatingPetPanel).isTrackingPointer)
        XCTAssertFalse(controller.presentation.overlayVisible)
        XCTAssertTrue(assistant.isAnswering)
        XCTAssertEqual(controller.presentation.query, "Keep this draft")
        controller.present(); controller.present()
        XCTAssertTrue(canvas.window!.isVisible)
        XCTAssertTrue(controller.window!.firstResponder is QuestionTextView)
        XCTAssertEqual(controller.presentation.query, "Keep this draft")
        controller.hide()
        XCTAssertFalse(assistant.isAnswering)
        XCTAssertFalse(state.activity.hasRunning)
    }

    @MainActor
    func testReminderDuringInferenceUsesSnapshotAndDoesNotCancelAnswer() async throws {
        _ = NSApplication.shared
        let http = Phase4HTTPHarness(json: "", holdOpen: true,
                                     modelCatalog: #"{"models":[{"name":"local:test"}]}"#)
        defer { http.cleanUp() }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = PetApplicationState(studentNow: { now })
        state.student.handle("/remind 1s Stand up")
        try await state.documentMemory.importDocument(at: documentFixture("Research.pdf"))
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let controller = NotesQueryWindowController(state: state, assistant: assistant, settings: AssistantSettings())
        defer { controller.close() }
        controller.presentation.modelName = "local:test"
        controller.presentation.query = "/ask orchid"
        controller.submit()
        try await Task.sleep(for: .milliseconds(50))
        let liveText = state.speechBubbleText
        XCTAssertTrue(assistant.isAnswering)
        now = now.addingTimeInterval(2)
        state.student.tick()
        XCTAssertTrue(assistant.isAnswering)
        XCTAssertEqual(state.speechBubbleText, liveText)
        XCTAssertTrue(state.activity.items.contains { $0.title == "Study alert" && $0.message.contains("Stand up") })
        state.activity.tick(now: 0, busy: false, hovered: false)
        XCTAssertTrue(state.activity.preview?.message.contains("Stand up") == true)
        XCTAssertEqual(state.speechBubbleText, liveText)
    }

    @MainActor
    func testMiniAndResizeKeepComposerAlignedAndExportNativePreviews() async throws {
        _ = NSApplication.shared
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost)
        defer { http.cleanUp() }
        let state = PetApplicationState(speechBubbleText: "Your study companion is ready.")
        let prefs = CompanionPreferences()
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let controller = NotesQueryWindowController(state: state, assistant: assistant, settings: AssistantSettings())
        let canvas = PetCanvasWindowController(model: state, presentation: controller.presentation,
                                               preferences: prefs, animationsEnabled: false)
        defer { controller.close(); canvas.close() }
        canvas.recoverToMainScreen(); canvas.showPet(); controller.attach(to: canvas); controller.present()
        (canvas.window as? FloatingPetPanel)?.stopAlphaTracking()
        prefs.size = 144
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(canvas.window!.frame.size, prefs.canvasSize)
        XCTAssertEqual(controller.window!.frame.midX, canvas.window!.frame.midX)
        XCTAssertEqual(controller.window!.frame.maxY + 8, canvas.window!.frame.minY)
        try export(canvas.window!.contentView!, name: "flame-native-preview.png")
        state.activity.record(title: "Timer finished", message: "A little break is well earned.", preview: true)
        state.activity.tick(now: 0, busy: false, hovered: false)
        try await Task.sleep(for: .milliseconds(50))
        try export(canvas.window!.contentView!, name: "alert-native-preview.png")
        prefs.mode = .mini
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(canvas.window!.frame.size, prefs.canvasSize)
        XCTAssertEqual(controller.window!.frame.maxY + 8, canvas.window!.frame.minY)
        XCTAssertEqual(prefs.anchorSize, NSSize(width: 128, height: 44))
        try export(canvas.window!.contentView!, name: "mini-native-preview.png")
        state.activity.showsTray = true
        try await Task.sleep(for: .milliseconds(100))
        if let popover = NSApp.windows.first(where: { $0.isVisible && $0.className.contains("Popover") }) {
            try export(popover.contentView!, name: "activity-native-preview.png")
        }
        state.activity.showsTray = false
        let hotkey = CompanionHotKeyController(preferences: prefs, registrar: TestHotKeyRegistrar(), action: {})
        let settings = CompanionSettingsWindowController(preferences: prefs, hotKey: hotkey,
            presentation: controller.presentation, recover: {})
        settings.present()
        defer { settings.close() }
        try await Task.sleep(for: .milliseconds(80))
        try export(settings.window!.contentView!, name: "settings-native-preview.png")
    }

    @MainActor
    func testForgetClearsCapturedActivityAndClarification() throws {
        let state = PetApplicationState()
        let coordinator = AssistantCoordinator(state: state)
        coordinator.onForget = { state.activity.clear() }
        state.activity.record(title: "Private chat", message: "Personal answer", preview: true)
        state.activity.open(state.activity.items[0].id)
        _ = coordinator.performShortcut("/forget")
        XCTAssertTrue(state.activity.items.isEmpty)
        XCTAssertNil(state.activity.selected)
        XCTAssertNil(state.activity.preview)
        XCTAssertNil(coordinator.pendingClarification)
        state.activity.record(title: "Another private answer", message: "Temporary detail")
        XCTAssertTrue(coordinator.respondLocally(to: "forget our conversation"))
        XCTAssertTrue(state.activity.items.isEmpty)
    }

    @MainActor
    func testNativeHotKeyRegistersDispatchesAndReleases() throws {
        guard ProcessInfo.processInfo.environment["KADDO_DESKTOP_TESTS"] == "1" else {
            throw XCTSkip("Set KADDO_DESKTOP_TESTS=1 with desktop access to exercise Carbon registration.")
        }
        _ = NSApplication.shared
        let registrar = NativeCompanionHotKey()
        defer { registrar.unregister() }
        // A separate combination avoids the user's running Kaddo or Codex bindings.
        let shortcut = CompanionShortcut(keyCode: 122, modifiers: 0x0100 | 0x0800 | 0x1000,
                                         keyLabel: "F1")
        var fired = 0
        XCTAssertTrue(registrar.register(shortcut) { fired += 1 }, "Carbon registration status: \(registrar.registrationStatus)")
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                   0, EventAttributes(kEventAttributeUserEvent), &event), noErr)
        let actual = try XCTUnwrap(event)
        defer { ReleaseEvent(actual) }
        var keyID = EventHotKeyID(signature: 0x4B414444, id: 1)
        XCTAssertEqual(SetEventParameter(actual, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &keyID), noErr)
        XCTAssertEqual(SendEventToEventTarget(actual, GetApplicationEventTarget()), noErr)
        XCTAssertEqual(fired, 1)
        let competitor = NativeCompanionHotKey()
        XCTAssertFalse(competitor.register(shortcut) {})
        registrar.unregister()
        XCTAssertTrue(competitor.register(shortcut) {})
        competitor.unregister()
    }

    @MainActor
    func testCelebrationReturnsToUnderlyingStillAndNewCelebrationsReplay() async throws {
        _ = NSApplication.shared
        let state = PetApplicationState(currentEmotion: .celebrating)
        let host = NSHostingView(rootView: AnimationTestHost(state: state))
        let panel = FloatingPetPanel(contentRect: NSRect(x: 0, y: 0, width: 96, height: 96))
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(50))
        let celebration = try rendered(host)
        try await Task.sleep(for: .milliseconds(650))
        let sleeping = try rendered(host)
        XCTAssertNotEqual(celebration, sleeping)
        state.currentEmotion = .celebrating
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try rendered(host), celebration, "A repeated celebration must replay even with the same logical emotion")
        state.currentEmotion = .thinking
        try await Task.sleep(for: .milliseconds(50))
        let thinking = try rendered(host)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(try rendered(host), thinking, "A superseded celebration must not replace the newer pose")
    }

    @MainActor
    private func rendered(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    private func export(_ view: NSView, name: String) throws {
        guard let root = ProcessInfo.processInfo.environment["KADDO_COMPANION_ARTIFACTS"] else { return }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: root).appendingPathComponent(name))
    }
}

@MainActor
private final class TestHotKeyRegistrar: CompanionHotKeyRegistering {
    var accept = true
    var registered: CompanionShortcut?
    var action: (@MainActor () -> Void)?
    func register(_ shortcut: CompanionShortcut, action: @escaping @MainActor () -> Void) -> Bool {
        guard accept else { return false }
        registered = shortcut; self.action = action
        return true
    }
    func unregister() { registered = nil; action = nil }
}

private struct AnimationTestHost: View {
    @ObservedObject var state: PetApplicationState
    var body: some View {
        PetSpriteView(emotion: state.currentEmotion, underlyingEmotion: .sleeping,
                      celebrationID: state.celebrationID, reducedMotionOverride: true)
    }
}
