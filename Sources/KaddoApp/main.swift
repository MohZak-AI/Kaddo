import AppKit
import KaddoCanvas

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = PetApplicationState(studentStorageURL: StudentPlanner.defaultStorageURL, knowledge: KnowledgeLibrary(storageURL: KnowledgeStore.productionURL))
    private var canvas: PetCanvasWindowController?
    private var statusItem: NSStatusItem?
    private var notesAssistant: LocalNotesAssistant?
    private var queryWindow: NotesQueryWindowController?
    private var workspaceWatcher: WorkspaceContextWatcher?
    private let companionPreferences = CompanionPreferences(defaults: .standard)
    private var companionHotKey: CompanionHotKeyController?
    private var companionSettings: CompanionSettingsWindowController?
    private var studentAlerts: StudentAlertService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleURL.pathExtension == "app" {
            studentAlerts = StudentAlertService(planner: model.student)
        }
        do {
            let assistant = LocalNotesAssistant(state: model, client: try OllamaClient())
            notesAssistant = assistant
            queryWindow = NotesQueryWindowController(state: model, assistant: assistant)
        } catch { model.speechBubbleText = error.localizedDescription }
        let watcher = WorkspaceContextWatcher(model: model)
        workspaceWatcher = watcher
        watcher.start()
        let canvas = PetCanvasWindowController(
            model: model, presentation: queryWindow?.presentation ?? PetChatPresentationState(),
            preferences: companionPreferences
        ) { [weak self] in self?.queryWindow?.present() }
        self.canvas = canvas
        canvas.restorePlacement()
        queryWindow?.attach(to: canvas)
        let hotKey = CompanionHotKeyController(preferences: companionPreferences) { [weak self] in
            self?.queryWindow?.present()
        }
        companionHotKey = hotKey
        if let presentation = queryWindow?.presentation {
            companionSettings = CompanionSettingsWindowController(preferences: companionPreferences,
                hotKey: hotKey, presentation: presentation) { [weak canvas] in canvas?.recoverToMainScreen() }
            presentation.settingsAction = { [weak self] in self?.companionSettings?.present() }
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Kaddo"
        let menu = NSMenu()
        menu.delegate = self
        for (title, action) in [("Show companion", #selector(showCompanion)),
                                ("Hide companion", #selector(hideCompanion)),
                                ("Mini mode", #selector(toggleCompanionMode)),
                                ("Companion settings…", #selector(showCompanionSettings))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Recover position", action: #selector(recoverPet), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Chat & Commands…", action: #selector(askNotes), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "AI settings…", action: #selector(showAISettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Sprite Credits…", action: #selector(showCredits), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Quit Kaddo", action: #selector(quit), keyEquivalent: "q")
            .target = self
        item.menu = menu
        statusItem = item
        Task { await model.startKnowledge() }
        model.student.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        queryWindow?.present()
        return true
    }

    @objc private func showAISettings() { queryWindow?.presentAISettings() }

    @objc private func showKnowledge() { queryWindow?.presentKnowledgeLibrary() }

    @objc private func askNotes() { queryWindow?.present() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if item.action == #selector(toggleCompanionMode) {
                item.state = companionPreferences.mode == .mini ? .on : .off
            }
        }
    }

    @objc private func showCompanion() { canvas?.showPet() }
    @objc private func hideCompanion() { canvas?.hidePet() }
    @objc private func toggleCompanionMode() {
        companionPreferences.mode = companionPreferences.mode == .mini ? .flame : .mini
    }
    @objc private func showCompanionSettings() { companionSettings?.present() }

    @objc private func recoverPet() { canvas?.recoverToMainScreen() }

    @objc private func clearDocuments() {
        Task { @MainActor in
            await model.clearSessionDocuments()
            model.speechBubbleText = "Active session documents cleared."
        }
    }

    @objc private func selectEmotion(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let emotion = PetEmotion(rawValue: rawValue) else { return }
        model.currentEmotion = emotion
    }

    @objc private func showCredits() {
        let alert = NSAlert()
        alert.messageText = "Kaddo’s flame character"
        alert.informativeText = "Original flame mascot generated with OpenAI ImageGen for Kaddo.\n"
            + "Legacy bundled cat sprites by Frakassets:\nhttps://frakassets.itch.io/free-pets-pack\n"
            + "CC BY 4.0 — https://creativecommons.org/licenses/by/4.0/\n"
            + "Kaddo crops and scales the supplied frames; artwork is unchanged."
        alert.runModal()
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        companionHotKey?.stop()
        model.student.stop()
        notesAssistant?.cancel()
        queryWindow?.close()
        for record in model.sessionFolders.values { record.documentMemory.clear() }
        workspaceWatcher?.stop()
        canvas?.close()
    }
}

let application = NSApplication.shared
let delegate = ApplicationDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
