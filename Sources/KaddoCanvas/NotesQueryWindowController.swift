import AppKit
import Combine
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

final class FloatingQuestionPanel: NSPanel {
    var dismiss: (() -> Void)?
    var closeCompanion: (() -> Void)?
    var minimizeCompanion: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": closeCompanion?(); return true
            case "m": minimizeCompanion?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A key-capable composer is a child of the nonactivating pet, never a full desktop overlay.
@MainActor
public final class NotesQueryWindowController: NSWindowController, NSWindowDelegate {
    public let presentation: PetChatPresentationState
    private let state: PetApplicationState
    private let assistant: LocalNotesAssistant
    public let companion: LocalCompanionAssistant
    public let coordinator: AssistantCoordinator
    public let settings: AssistantSettings
    private weak var canvas: PetCanvasWindowController?
    private var knowledgeAnswerDisplayed = false
    private var knowledgeWindow: KnowledgeLibraryWindowController?
    private var agentWindow: AgentPlatformWindowController?
    private var observations: [AnyCancellable] = []
    private var geometryObservations: [AnyCancellable] = []
    private var discovery: Task<Void, Never>?
    private var answerRequest: Task<Void, Never>?
    private var pendingCollapse: Task<Void, Never>?
    private var lastQuestion = ""
    private var workflowSources: Set<UUID>?
    private var responseActivityID: UUID?
    private var responseOutcome: KaddoToolResult.Status = .success
    private let assistantQuestionID = UUID()
    private var isPositioning = false
    var isResponding: Bool { answerRequest != nil || assistant.isAnswering || coordinator.isAnswering }
    var documentCloudProviderFactory: (() throws -> any AssistantProvider)?

    private func documentCloudProvider() throws -> any AssistantProvider {
        if let documentCloudProviderFactory { return try documentCloudProviderFactory() }
        return try settings.cloudProvider()
    }

    public init(state: PetApplicationState, assistant: LocalNotesAssistant,
                presentation: PetChatPresentationState = PetChatPresentationState(),
                conversation: any ConversationStore = InMemoryConversationStore(),
                settings: AssistantSettings? = nil) {
        self.state = state
        self.assistant = assistant
        self.presentation = presentation
        self.settings = settings ?? .live()
        coordinator = AssistantCoordinator(state: state, conversation: conversation)
        companion = assistant.makeCompanion(conversation: conversation)
        let panel = FloatingQuestionPanel(contentRect: NSRect(x: 0, y: 0, width: PetChatStyle.width,
                                                             height: PetChatStyle.barHeight),
                                          styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.title = "Kaddo Chat & Commands"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        super.init(window: panel)
        state.student.beforeMessage = { [weak self] in
            guard let self, self.state.foregroundOperationID == nil, !self.coordinator.isExecutingTool, !self.state.student.isDeliveringAlert else { return }
            self.cancelResponses()
        }
        state.canPublishPlannerMessage = { [weak self] in self?.isResponding == false }
        state.student.canPresentCheckIn = { [weak self] in
            guard let self else { return false }
            return !self.isResponding && self.answerRequest == nil
                && self.presentation.query.isEmpty && !self.presentation.showsControls
        }
        assistant.onContextChange = { [weak self] in
            guard let self, !self.coordinator.isExecutingTool else { return }
            self.state.student.dismissPersonalQuestion()
            self.cancelResponses()
        }
        companion.onReply = { [weak self] reply in
            self?.state.student.noteUserInteraction()
            self?.state.agent.deferCheckIns()
            self?.state.speechBubbleText = reply.text
            self?.state.currentEmotion = reply.emotion
        }
        coordinator.onForget = { [weak state] in state?.clearCompanionActivity(); state?.clearDocumentConversations() }
        coordinator.onGeneralAnswer = { [weak assistant] question in assistant?.retainDocumentConversation(after: question) }
        coordinator.documentRoutingContext = { [weak assistant] in assistant?.routingContext ?? .null }
        coordinator.onOutcome = { [weak self] status, text in
            guard let self else { return }
            if self.responseActivityID != nil {
                if status == .failure { self.responseOutcome = .failure }
                else if self.responseOutcome != .failure { self.responseOutcome = status }
            } else {
                self.state.activity.record(title: status == .failure ? "Action failed" : "Kaddo",
                                           message: text, state: status == .failure ? .blocked : .ready)
            }
        }
        observations.append(coordinator.$pendingClarification.sink { [weak self] question in
            guard let self else { return }
            self.state.activity.setQuestion(self.assistantQuestionID,
                message: question.map { "Please provide the missing details for \($0)." })
        })
        coordinator.onReply = { [weak self] reply in
            self?.state.student.noteUserInteraction()
            self?.state.agent.deferCheckIns()
            self?.state.speechBubbleText = reply.text
            self?.state.currentEmotion = reply.emotion
        }
        coordinator.providerFactory = { [weak self] in
            guard let self else { return nil }
            if self.settings.provider.isCloud { return try self.settings.cloudProvider() }
            guard !self.presentation.modelName.isEmpty else { throw AssistantError.localModelUnavailable }
            return self.assistant.makeProvider(model: self.presentation.modelName)
        }
        state.agent.providerFactory = { [weak self] in try self?.coordinator.providerFactory?() }
        state.agent.usesCloud = { [weak self] in self?.settings.provider.isCloud == true }
        state.agent.isUserBusy = { [weak self] in
            guard let self else { return true }
            return self.isResponding || self.presentation.hasQuestion || self.presentation.showsControls
                || self.state.student.isLocalInputPending
                || (self.state.student.timer != nil && self.state.student.timer?.status != .completed)
        }
        state.agent.plannerContext = { [weak state] in state?.student.todaySummary() ?? "" }
        state.agent.onFolderPicker = { [weak self] in self?.chooseSourceFolder() }
        state.agent.onAnswer = { [weak self] _, excerpts in
            self?.presentation.sources = excerpts.map { .init(id: $0.id, documentID: $0.id,
                filename: "Source · " + $0.title, index: 0, text: $0.text, sourceURL: $0.url) }
        }
        state.agent.onRunWorkflow = { [weak self] workflow in
            guard let self else { return }
            self.workflowSources = workflow.sourceIDs
            self.presentation.query = workflow.instructions
            self.submit()
        }
        state.ingestion.onSources = { [weak self] sources in self?.presentation.sources = sources }
        state.agent.start()
        coordinator.understandsFreeform = { [weak self] in
            guard let self else { return false }
            return self.settings.provider.isCloud ? self.settings.hasKey : !self.presentation.modelName.isEmpty
        }
        coordinator.openDocument = { [weak self] in self?.chooseDocument() }
        coordinator.answerKnowledge = { [weak self] question, category in
            guard let self else { throw CancellationError() }
            let revision = self.state.knowledge.revision
            let documents = self.state.knowledge.items.filter {
                $0.sourceKind == "session-document" && (DocumentRetrievalService.allowsOtherSessions(question) || $0.sourceKey.hasPrefix("session-file:\(self.state.activeSessionID):"))
            }
            if !documents.isEmpty, DocumentQuestionRouter.shouldRoute(question, hasDocuments: true,
                previousQuestion: self.assistant.lastDocumentQuestion, filenames: documents.map(\.title)) {
                return try await self.answerDocumentKnowledge(question)
            }
            let named = documents.filter { item in
                let stem = URL(fileURLWithPath: item.title).deletingPathExtension().lastPathComponent
                return question.localizedCaseInsensitiveContains(item.title)
                    || (stem.count >= 3 && question.localizedCaseInsensitiveContains(stem))
            }
            let documentIDs: Set<UUID>? = named.isEmpty
                ? Set(self.state.knowledge.items.filter { item in
                    if item.sourceKind == "session-document" { return documents.contains(where: { $0.id == item.id }) }
                    if item.sourceKind == "session-summary" {
                        return DocumentRetrievalService.allowsOtherSessions(question) || item.sourceKey == "session-summary:\(self.state.activeSessionID)"
                    }
                    return true
                }.map(\.id))
                : Set(named.map(\.id))
            let matches = await self.state.knowledge.search(query: question, categoryID: nil, documentIDs: documentIDs)
            try Task.checkCancellation()
            if matches.first?.sourceKind == "session-document" {
                return try await self.answerDocumentKnowledge(question)
            }
            if matches.isEmpty {
                return KnowledgeAnswer(text: "I couldn’t find matching saved knowledge. Try a more specific question or save a note in Knowledge Library.", sources: [])
            }
            let answer: KnowledgeAnswer
            if self.settings.provider.isCloud {
                answer = try await KnowledgeGroundingService.answer(question: question, matches: matches, provider: self.settings.cloudProvider())
            } else {
                guard !self.presentation.modelName.isEmpty else { throw LocalInferenceError.modelUnavailable }
                answer = try await KnowledgeGroundingService.answer(question: question, matches: matches, client: self.assistant.client, model: self.presentation.modelName)
            }
            guard revision == self.state.knowledge.revision else { throw CancellationError() }
            return answer
        }
        coordinator.onKnowledgeAnswer = { [weak self] answer in
            guard let self else { return }
            self.knowledgeAnswerDisplayed = true
            self.presentation.sources = answer.sources.map { .init(id: $0.id, documentID: $0.itemID, filename: "Knowledge · " + $0.title, index: 0, text: $0.text, sourceURL: $0.sourceURL) }
        }
        observations.append(state.knowledge.$revision.dropFirst().sink { [weak self] _ in
            guard let self, !self.coordinator.isExecutingTool else { return }
            if self.coordinator.isGroundingKnowledge || self.knowledgeAnswerDisplayed {
                self.cancelResponses()
                self.state.speechBubbleText = "Saved knowledge changed. Ask a new question."
            }
        })
        observations.append(presentation.$modelName.dropFirst().removeDuplicates().sink { [weak self] _ in
            self?.cancelResponses()
            self?.state.resumeSessionAutomation()
            self?.resumeConversationCompaction()
        })
        observations.append(presentation.$knowledgeCategoryID.dropFirst().sink { [weak self] category in
            guard let self else { return }
            let grounding = self.coordinator.isGroundingKnowledge || self.knowledgeAnswerDisplayed
            self.coordinator.knowledgeCategoryID = category
            if grounding {
                self.cancelResponses()
                self.state.speechBubbleText = "Knowledge category changed. Ask a new question."
            }
        })
        coordinator.answerDocument = { [weak self] question in
            guard let self else { return .cancelled }
            let sessionID = self.state.activeSessionID
            let outcome: DocumentResponseOutcome
            if self.settings.provider.isCloud {
                do { outcome = await self.assistant.respond(query: question, provider: try self.documentCloudProvider()) }
                catch { outcome = .failed(error) }
            } else {
                outcome = await self.assistant.respond(query: question, model: self.presentation.modelName)
            }
            if case .answered(let answer) = outcome {
                self.state.recordSessionExchange(.init(user: question, companion: answer.text), sessionID: sessionID)
            }
            return outcome
        }
        observations.append(self.settings.$provider.dropFirst().sink { [weak self] _ in
            self?.cancelResponses()
            self?.state.resumeSessionAutomation()
            self?.resumeConversationCompaction()
        })
        observations.append(self.settings.$hasKey.dropFirst().sink { [weak self] _ in
            self?.cancelResponses()
            self?.state.resumeSessionAutomation()
            self?.resumeConversationCompaction()
        })
        observations.append(self.settings.$cloudModel.dropFirst().sink { [weak self] _ in
            self?.cancelResponses()
            self?.state.resumeSessionAutomation()
            self?.resumeConversationCompaction()
        })
        presentation.addDocumentAction = { [weak self] in self?.chooseDocument() }
        panel.delegate = self
        panel.dismiss = { [weak self] in self?.hide() }
        panel.closeCompanion = { [weak presentation] in presentation?.hideOverlayAction?() }
        panel.minimizeCompanion = { [weak presentation] in presentation?.miniAction?() }
        panel.contentView = NSHostingView(rootView: QuestionComposerView(
            state: state, student: state.student, assistant: assistant, companion: companion, coordinator: coordinator,
            settings: self.settings, chat: presentation,
            submit: { [weak self] in self?.submit() },
            stop: { [weak self] in self?.stopResponse() },
            dismiss: { [weak self] in self?.hide() },
            addDocument: { [weak self] in self?.chooseDocument() }
        ))
        observations.append(presentation.$composerHeight.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.positionComposer() }
        })
        observations.append(assistant.$sources.sink { [weak presentation] sources in
            MainActor.assumeIsolated { presentation?.sources = sources }
        })
        observations.append(assistant.$isAnswering.dropFirst().sink { [weak self] answering in
            MainActor.assumeIsolated {
                guard let self, !answering else { return }
                // Long generations need a quiet interval after the answer, too.
                self.state.student.noteUserInteraction()
                if let failure = self.assistant.lastFailure { self.offerRetry(for: failure) }
            }
        })
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(state:assistant:)") }

    public func attach(to canvas: PetCanvasWindowController) {
        geometryObservations.removeAll()
        (self.canvas?.window as? FloatingPetPanel)?.onPointerUpdate = nil
        self.canvas = canvas
        guard let pet = canvas.window, let window else { return }
        (pet as? FloatingPetPanel)?.onPointerUpdate = { [weak self] point, interacting in
            self?.updateHover(globalPoint: point, interacting: interacting)
        }
        canvas.dragController.constrainOrigin = { [weak self] proposed in
            self?.constrainedOrigin(proposed) ?? proposed
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            geometryObservations.append(NotificationCenter.default.publisher(for: name, object: pet)
                .receive(on: RunLoop.main).sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.positionComposer() }
                })
        }
        geometryObservations.append(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        ).receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.positionComposer() }
        })
        observations.append(canvas.preferences.$isVisible.dropFirst().sink { [weak self] visible in
            guard !visible else { return }
            self?.dismissOverlayControls()
        })
        geometryObservations.append(canvas.preferences.$mode.dropFirst().sink { [weak self] mode in
            if mode == .mini { self?.dismissOverlayControls() }
        })
        if presentation.isComposerVisible { pet.addChildWindow(window, ordered: .above) }
        positionComposer()
    }

    public func presentAgentPlatform() {
        if agentWindow == nil { agentWindow = AgentPlatformWindowController(platform: state.agent, presentation: presentation) }
        agentWindow?.present()
    }
    private func chooseSourceFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Allow read access"
        if panel.runModal() == .OK, let url = panel.url { Task { await state.agent.addFolder(url) } }
    }

    private var aiSettingsWindow: NSWindowController?
    public func presentAISettings() {
        if aiSettingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Kaddo · AI settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AISettingsView(library: state.knowledge, settings: settings, chat: presentation,
                assistant: assistant, refresh: { [weak self] in self?.refreshModels() }).padding(20))
            window.center()
            aiSettingsWindow = NSWindowController(window: window)
        }
        aiSettingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshModels()
    }

    public func presentKnowledgeLibrary() {
        if knowledgeWindow == nil { knowledgeWindow = KnowledgeLibraryWindowController(library: state.knowledge, ingestion: state.ingestion) }
        knowledgeWindow?.present()
    }

    public func present() {
        canvas?.showPet()
        state.activity.dismissPreview()
        state.activity.returnToLive()
        presentation.expand()
        showComposer(focus: true)
    }

    private func showComposer(focus: Bool) {
        pendingCollapse?.cancel()
        pendingCollapse = nil
        let wasVisible = presentation.isComposerVisible
        presentation.isComposerVisible = true
        if let pet = canvas?.window, let window { pet.addChildWindow(window, ordered: .above) }
        positionComposer()
        window?.ignoresMouseEvents = false
        if window?.isVisible == false {
            window?.alphaValue = 0
            window?.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PetMotion.visibilityDuration(showing: true,
                reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window?.animator().alphaValue = 1
        }
        if !wasVisible { refreshModels() }
        // Hover reveals controls without activating Kaddo or taking keyboard focus.
        guard focus else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        focusEditor(in: window?.contentView)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentation.isComposerVisible else { return }
            self.window?.contentView?.layoutSubtreeIfNeeded()
            self.focusEditor(in: self.window?.contentView)
        }
    }

    /// Hiding the whole companion preserves work. Escape remains a cancellation action.
    public func dismissOverlayControls() {
        presentation.collapse()
        hideComposer(animated: false)
    }

    public func hide() {
        stopResponse()
        presentation.collapse()
        hideComposer(animated: false)
    }

    private func hideComposer(animated: Bool) {
        pendingCollapse?.cancel()
        pendingCollapse = nil
        presentation.isComposerVisible = false
        presentation.showsControls = false
        guard let window else { return }
        // Hidden controls must immediately stop blocking the application underneath.
        window.ignoresMouseEvents = true
        if animated {
            let duration = PetMotion.visibilityDuration(showing: false,
                reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().alphaValue = 0
            }
            // AppKit animation completions can be deferred without an active compositor.
            // Retire the native panel after the fade, and cancel retirement on re-entry.
            pendingCollapse = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(duration)) }
                catch { return }
                guard let self, !self.presentation.isExpanded, !self.presentation.isComposerVisible else { return }
                window.parent?.removeChildWindow(window)
                window.orderOut(nil)
                self.pendingCollapse = nil
            }
        } else {
            window.alphaValue = 0
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
        }
    }

    func updateHover(globalPoint: NSPoint, interacting: Bool = false,
                     now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let pet = canvas?.window, pet.isVisible else { return }
        let sprite = PetChatLayout.spriteFrame(in: pet.frame,
            anchorSize: canvas?.preferences.anchorSize ?? NSSize(width: 108, height: 108))
            .insetBy(dx: -48, dy: -6)
        let expanded = pet.frame.union(PetChatLayout.composerFrame(
            below: pet.frame, height: presentation.composerHeight
        )).insetBy(dx: -6, dy: -6)
        let inside = (presentation.isExpanded ? expanded : sprite).contains(globalPoint)
        let hovered = sprite.contains(globalPoint)
        if presentation.isHovered != hovered { presentation.isHovered = hovered }
        state.activity.tick(now: now,
            busy: state.agent.isUserBusy() || state.agent.isWithinQuietInterval || interacting || presentation.isDragging || presentation.showsControls
                || presentation.isSettingsOpen || (window?.isKeyWindow == true && presentation.hasQuestion)
                || state.activity.showsTray,
            hovered: expanded.contains(globalPoint))
        let wasExpanded = presentation.isExpanded
        presentation.updateHover(
            isInside: inside,
            keepsOpen: interacting || presentation.showsControls || presentation.isSettingsOpen
                || state.activity.showsTray
                || (window?.isKeyWindow == true && presentation.hasQuestion),
            now: now
        )
        guard presentation.isExpanded != wasExpanded else { return }
        if presentation.isExpanded {
            showComposer(focus: false)
        } else {
            // Auto-collapse preserves drafts and lets an in-flight reply finish.
            hideComposer(animated: true)
        }
    }

    public func windowWillClose(_ notification: Notification) { hide() }

    @discardableResult
    private func focusEditor(in view: NSView?) -> Bool {
        guard let view else { return false }
        if let editor = view as? QuestionTextView {
            window?.initialFirstResponder = editor
            return window?.makeFirstResponder(editor) ?? false
        }
        for child in view.subviews where focusEditor(in: child) { return true }
        return false
    }

    private func constrainedOrigin(_ proposed: NSPoint) -> NSPoint {
        guard let pet = canvas?.window else { return proposed }
        let proposedFrame = NSRect(origin: proposed, size: pet.frame.size)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: proposedFrame.midX, y: proposedFrame.midY)) }
            ?? pet.screen ?? NSScreen.main
        guard let screen else { return proposed }
        return PetChatLayout.constrainedOrigin(
            proposed, petSize: pet.frame.size,
            // Reserve the bar's space while compact so revealing it never moves the pet.
            composerHeight: presentation.composerHeight,
            visibleFrame: screen.visibleFrame
        )
    }

    private func positionComposer() {
        guard !isPositioning, let window else { return }
        isPositioning = true
        defer { isPositioning = false }
        if let pet = canvas?.window {
            let origin = constrainedOrigin(pet.frame.origin)
            if origin != pet.frame.origin { pet.setFrameOrigin(origin) }
            window.setFrame(PetChatLayout.composerFrame(below: pet.frame, height: presentation.composerHeight),
                            display: true)
        } else {
            window.setContentSize(NSSize(width: PetChatStyle.width, height: presentation.composerHeight))
        }
    }

    private func refreshModels() {
        guard !assistant.isAnswering, !presentation.isCheckingModels else { return }
        presentation.isCheckingModels = true
        discovery = Task { [weak self] in
            guard let self else { return }
            defer { self.presentation.isCheckingModels = false }
            do {
                let available = try await self.assistant.localModelNames()
                self.presentation.models = available
                if !available.contains(self.presentation.modelName) {
                    self.presentation.modelName = available.first ?? ""
                }
                self.presentation.modelStatus = available.isEmpty
                    ? "No local models installed. Install one in Ollama, then refresh."
                    : "Ollama connected · \(available.count) local model(s)"
                if !available.isEmpty, self.presentation.retryTitle == "Refresh models" {
                    self.presentation.retryTitle = nil
                    self.presentation.retryAction = nil
                }
            } catch is CancellationError {
                // A torn-down controller must not replace another UI's speech.
            } catch {
                self.presentation.models = []
                self.presentation.modelName = ""
                self.presentation.modelStatus = error.localizedDescription
            }
        }
    }

    func submit() {
        guard presentation.hasQuestion else { return }
        let input = presentation.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if coordinator.isSessionNavigationInput(input) { submitInput(input); return }
        let needsIngestion = state.ingestion.pendingQuestion != nil
            || DocumentIngestionService.isMaintenanceRequest(input)
        if needsIngestion {
            cancelResponses()
            presentation.query = ""
            answerRequest = Task { [weak self] in
                guard let self else { return }
                let handled = await self.state.ingestion.handleChat(input)
                guard !Task.isCancelled else { return }
                self.answerRequest = nil
                if !handled { self.submitInput(input) }
            }
        } else { submitInput(input) }
    }

    private func submitInput(_ message: String) {
        presentation.query = message
        let sourceIDs = workflowSources
        workflowSources = nil
        let input = presentation.query.trimmingCharacters(in: .whitespacesAndNewlines)
        state.student.noteUserInteraction()
        state.agent.noteInteraction()
        cancelResponses()
        let inputOperation = state.beginForegroundOperation()
        defer { if answerRequest == nil { state.finishForegroundOperation(inputOperation) } }
        presentation.query = ""
        state.activity.returnToLive()
        state.activity.dismissPreview()
        presentation.showsControls = false
        guard input.count <= 2_000 else {
            state.currentEmotion = .idle
            state.speechBubbleText = "Keep your message to 2,000 characters."
            return
        }
        if coordinator.respondToSessionNavigation(input) { return }
        if input.hasPrefix("/") {
            let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let command = String(parts[0]).lowercased()
            let argument = parts.count > 1 ? String(parts[1]) : ""
            if command == "/ask" {
                state.student.prepareForCommand(command)
                guard !argument.isEmpty else {
                    state.speechBubbleText = "What would you like to know from your documents?"; return
                }
                guard settings.provider.isCloud || !presentation.modelName.isEmpty else {
                    state.speechBubbleText = "Document questions need an AI model. Student commands work now; choose a cloud provider or a local model in Kaddo → AI settings."
                    state.currentEmotion = .idle
                    offerRetry(for: .modelUnavailable); return
                }
                startResponse(input: input, documentQuestion: argument)
            } else {
                if command == "/forget" || (command == "/profile" && argument.lowercased() == "clear") {
                    companion.forget()
                }
                coordinator.performShortcut(input)
            }
            return
        }
        if sourceIDs != nil {
            assistant.retainDocumentConversation(after: input)
            startResponse(input: input, sourceIDs: sourceIDs)
            return
        }
        if companion.respondLocally(to: input) { return }
        if coordinator.isExplicitKnowledgeRequest(input) {
            assistant.retainDocumentConversation(after: input)
            startResponse(input: input, sourceIDs: sourceIDs); return
        }
        let localCommand = NaturalActionRouter.command(for: input, state: state)
        if let document = localCommand, document.hasPrefix("/ask ") {
            startResponse(input: input, documentQuestion: String(document.dropFirst(5))); return
        }
        if localCommand == nil, DocumentQuestionRouter.shouldRoute(input,
            hasDocuments: state.knowledge.items.contains { $0.sourceKind == "session-document" && (DocumentRetrievalService.allowsOtherSessions(input) || $0.sourceKey.hasPrefix("session-file:\(state.activeSessionID):")) },
            previousQuestion: assistant.lastDocumentQuestion,
            filenames: state.knowledge.items.filter { $0.sourceKind == "session-document" && (DocumentRetrievalService.allowsOtherSessions(input) || $0.sourceKey.hasPrefix("session-file:\(state.activeSessionID):")) }.map(\.title)) {
            startResponse(input: input, documentQuestion: input); return
        }
        if coordinator.respondLocally(to: input) { return }
        startResponse(input: input, sourceIDs: sourceIDs)
    }

    private func answerDocumentKnowledge(_ question: String) async throws -> KnowledgeAnswer {
        guard let respond = coordinator.answerDocument else { throw CancellationError() }
        let answer = try await respond(question).answerOrThrow()
        let text = answer.text
        let sources = answer.sources.compactMap { chunk -> KnowledgeMatch? in
            guard let item = state.knowledge.items.first(where: { $0.id == chunk.documentID }) else { return nil }
            return KnowledgeMatch(id: chunk.id, itemID: item.id, title: item.title, categoryID: item.categoryID,
                sourceKey: item.sourceKey, sourceKind: item.sourceKind, sourceURL: item.sourceURL, text: chunk.text, score: 1)
        }
        return KnowledgeAnswer(text: text, sources: sources)
    }

    private func startResponse(input: String, documentQuestion: String? = nil, sourceIDs: Set<UUID>? = nil) {
        let operationID = state.foregroundOperationID ?? state.beginForegroundOperation()
        lastQuestion = input
        responseOutcome = .success
        let activityID = state.activity.begin(title: documentQuestion == nil ? "Answer" : "Document answer")
        responseActivityID = activityID
        state.currentEmotion = .thinking
        state.speechBubbleText = "Let me think…"
        answerRequest = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            if let documentQuestion {
                let outcome = await self.coordinator.answerDocument?(documentQuestion) ?? .cancelled
                guard !Task.isCancelled, self.state.foregroundOperationID == operationID else { return }
                switch outcome {
                case .answered(let answer):
                    self.state.speechBubbleText = answer.text
                    self.presentation.sources = answer.sources
                case .needsInput(let error):
                    self.responseOutcome = .needsInput
                    self.state.speechBubbleText = error.localizedDescription
                    self.presentation.retryTitle = nil; self.presentation.retryAction = nil
                case .failed(let error):
                    self.state.currentEmotion = .idle
                    self.responseOutcome = .failure
                    self.state.speechBubbleText = error.localizedDescription
                    self.presentation.retryTitle = "Try again"
                    self.presentation.retryAction = { [weak self] in self?.presentation.query = input; self?.submit() }
                case .cancelled:
                    self.state.currentEmotion = .idle
                    self.state.activity.cancel(activityID)
                    self.responseActivityID = nil
                    self.state.speechBubbleText = "Answer cancelled."
                }
            } else {
                await self.coordinator.answer(input, sourceIDs: sourceIDs)
                if self.coordinator.canRetry, !Task.isCancelled {
                    self.presentation.retryTitle = "Try again"
                    self.presentation.retryAction = { [weak self] in self?.retryAssistant() }
                }
            }
            if !Task.isCancelled, self.responseActivityID == activityID {
                self.finishResponseActivity(activityID)
                self.answerRequest = nil
            } else if self.state.foregroundOperationID == operationID {
                self.answerRequest = nil
            }
            self.state.finishForegroundOperation(operationID)
        }
    }

    private func finishResponseActivity(_ id: UUID) {
        let status: PetActivityState = switch responseOutcome {
        case .success: .ready
        case .failure: .blocked
        case .needsInput: .needsInput
        }
        state.activity.finish(id, state: status, message: state.speechBubbleText, sources: presentation.sources)
        responseActivityID = nil
    }

    private func retryAssistant() {
        guard coordinator.canRetry else { return }
        presentation.retryTitle = nil; presentation.retryAction = nil
        let operationID = state.beginForegroundOperation()
        let activityID = state.activity.begin(title: "Retry answer")
        responseActivityID = activityID; responseOutcome = .success
        answerRequest = Task { [weak self] in
            guard let self else { return }
            await self.coordinator.retry()
            if !Task.isCancelled, self.responseActivityID == activityID {
                self.finishResponseActivity(activityID)
                self.answerRequest = nil
            }
            self.state.finishForegroundOperation(operationID)
        }
    }

    private func cancelResponses() {
        knowledgeAnswerDisplayed = false
        if let responseActivityID { state.activity.cancel(responseActivityID) }
        responseActivityID = nil
        let wasResponding = answerRequest != nil || isResponding
        answerRequest?.cancel()
        answerRequest = nil
        assistant.cancel()
        coordinator.cancel()
        if let id = state.foregroundOperationID { state.finishForegroundOperation(id) }
        if wasResponding, state.currentEmotion == .thinking { state.currentEmotion = .idle }
        assistant.clearSources()
        presentation.sources = []
        presentation.retryTitle = nil
        presentation.retryAction = nil
    }

    private func resumeConversationCompaction() {
        state.cancelConversationCompaction()
        do {
            if let provider = try coordinator.providerFactory?() {
                state.resumeConversationCompaction(provider: provider)
            }
        } catch { }
    }

    private func stopResponse() {
        let chatting = coordinator.isAnswering || (answerRequest != nil && !assistant.isAnswering)
        cancelResponses()
        if chatting {
            state.currentEmotion = .idle
            state.speechBubbleText = "paused that thought :) I’m here when you’re ready."
        }
    }

    private func offerRetry(for failure: LocalInferenceError) {
        if responseActivityID == nil {
            state.activity.record(title: "Document answer needs attention", message: failure.localizedDescription,
                                  state: .blocked)
        }
        switch failure {
        case .noRelevantContext:
            presentation.retryTitle = "Add document"
            presentation.retryAction = { [weak self] in self?.chooseDocument() }
        case .modelUnavailable, .serviceUnavailable, .remoteModel, .invalidConfiguration:
            presentation.retryTitle = "Refresh models"
            presentation.retryAction = { [weak self] in self?.refreshModels() }
        default:
            presentation.retryTitle = "Try again"
            presentation.retryAction = { [weak self] in
                guard let self else { return }
                self.presentation.query = self.lastQuestion
                self.submit()
            }
        }
    }

    private func chooseDocument() {
        state.student.dismissPersonalQuestion()
        if !coordinator.isExecutingTool { stopResponse() }
        presentation.showsControls = false
        let panel = NSOpenPanel()
        panel.title = "Upload documents — Kaddo will organize them"
        panel.allowedContentTypes = [.pdf, DocumentDropTypes.word, .plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let sessionID = state.activeSessionID
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.state.ingestion.enqueue(panel.urls, sessionID: sessionID)
        }
    }

    deinit {
        discovery?.cancel()
        answerRequest?.cancel()
        pendingCollapse?.cancel()
    }
}

private struct QuestionComposerView: View {
    @ObservedObject var state: PetApplicationState
    @ObservedObject var student: StudentPlanner
    @ObservedObject var assistant: LocalNotesAssistant
    @ObservedObject var companion: LocalCompanionAssistant
    @ObservedObject var coordinator: AssistantCoordinator
    @ObservedObject var settings: AssistantSettings
    @ObservedObject var chat: PetChatPresentationState
    let submit: () -> Void
    let stop: () -> Void
    let dismiss: () -> Void
    let addDocument: () -> Void
    @State private var editorHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: addDocument) {
                Image(systemName: "plus").font(.system(size: 17, weight: .regular))
                    .frame(width: 28, height: 28).background(PetChatStyle.controlFill, in: Circle())
            }
            .buttonStyle(PetPressButtonStyle()).accessibilityLabel("Upload documents")
            .help("Upload PDF, DOCX, TXT or Markdown. Kaddo chooses the subject. Search vectors stay on this Mac.")
            if settings.provider.isCloud {
                Image(systemName: "cloud").font(.system(size: 11))
                    .foregroundStyle(PetChatStyle.muted)
                    .accessibilityLabel("\(settings.cloudName) cloud AI selected")
                    .help("\(settings.cloudName) cloud AI is selected")
            }
            ComposerTextEditor(text: $chat.query, isEnabled: true,
                               placeholder: student.pendingProfileField?.inputHint ?? "Ask anything, or give me a task…",
                               onSubmit: submit, onDismiss: dismiss) { height in
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    editorHeight = height
                    chat.composerHeight = max(PetChatStyle.barHeight, height + 16)
                }
            }
            .frame(height: editorHeight)
            .frame(minHeight: 28)
            Button {
                if isStopping { stop() } else { submit() }
            } label: {
                PetActionSymbol(name: isStopping ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(PetChatStyle.blue.opacity(canSend || isAnswering ? 1 : 0.4), in: Circle())
            }
            .buttonStyle(PetPressButtonStyle())
            .disabled(!isAnswering && !canSend)
            .accessibilityLabel(isStopping ? "Stop answer" : "Send chat or command")
        }
        .foregroundStyle(.primary)
        .padding(8)
        .frame(width: PetChatStyle.width, height: chat.composerHeight)
        .petSurface(.control, in: RoundedRectangle(cornerRadius: 22))
        .onExitCommand(perform: dismiss)
    }

    private var canSend: Bool { chat.hasQuestion }
    private var isAnswering: Bool { assistant.isAnswering || coordinator.isAnswering }
    private var isStopping: Bool { isAnswering && !chat.hasQuestion }

}

private struct AISettingsView: View {
    @ObservedObject var library: KnowledgeLibrary
    @ObservedObject var settings: AssistantSettings
    @ObservedObject var chat: PetChatPresentationState
    @ObservedObject var assistant: LocalNotesAssistant
    let refresh: () -> Void
    @State private var apiKey = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search & AI settings").font(.system(size: 12, weight: .semibold))
            Text(library.localVectorizationSummary).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Picker("Provider", selection: $settings.provider) {
                Text("OpenAI").tag(AssistantSettings.Provider.openAI)
                Text("DeepSeek").tag(AssistantSettings.Provider.deepSeek)
                Text("Ollama · Local").tag(AssistantSettings.Provider.ollama)
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.provider) { _ in apiKey = "" }
            if settings.provider.isCloud {
                SecureField("Personal \(settings.cloudName) API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Personal \(settings.cloudName) API key")
                HStack {
                    Button("Save key") { settings.saveKey(apiKey); apiKey = "" }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove key") { settings.removeKey(); apiKey = "" }.disabled(!settings.hasKey)
                }
                Text("Model").font(.system(size: 11)).foregroundStyle(PetChatStyle.muted)
                TextField("\(settings.cloudName) model", text: $settings.cloudModel).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(settings.cloudName) model")
                Button(settings.isTesting ? "Testing…" : "Test connection") { settings.testConnection() }
                    .disabled(!settings.hasKey || settings.isTesting)
                Text(settings.status).font(.system(size: 11)).foregroundStyle(PetChatStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Uploads send extracted document text to this provider for organization and planner extraction. Document questions send matching excerpts. API usage is billed to your account.")
                    .font(.system(size: 11)).foregroundStyle(PetChatStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
            Text("Local model").font(.system(size: 11)).foregroundStyle(PetChatStyle.muted)
            if chat.models.isEmpty {
                Text("No local model available").foregroundStyle(PetChatStyle.muted)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(chat.models, id: \.self) { model in
                            Button { chat.modelName = model } label: {
                                HStack {
                                    Text(model)
                                    Spacer()
                                    if model == chat.modelName { Image(systemName: "checkmark") }
                                }
                            }
                            .accessibilityLabel("Use local model \(model)")
                            .accessibilityValue(model == chat.modelName ? "Selected" : "")
                        }
                    }
                }
                .frame(height: min(96, CGFloat(chat.models.count) * 34))
                .disabled(assistant.isAnswering)
            }
            Text(chat.modelStatus).font(.system(size: 11)).foregroundStyle(PetChatStyle.muted)
            Button("Refresh models", action: refresh).disabled(chat.isCheckingModels || assistant.isAnswering)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .buttonStyle(PetControlButtonStyle())
    }
}

private struct PetControlButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.05),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reducedMotion ? 0.97 : 1)
            .animation(reducedMotion ? nil : .easeOut(duration: PetMotion.pressDuration),
                       value: configuration.isPressed)
    }
}
