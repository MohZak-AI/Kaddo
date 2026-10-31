import Combine
import Foundation

public enum PetEmotion: String, CaseIterable, Sendable {
    case idle, thinking, happy, sleeping, celebrating
}

public struct PetTask: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String

    public init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }
}

/// One instance is owned by the application and shared by every pet view.
/// ObservableObject/StateObject keeps the canvas compatible with macOS 13.
@MainActor
public final class PetApplicationState: ObservableObject {
    public lazy var ingestion = DocumentIngestionService(state: self)
    public lazy var agent = AgentPlatform(library: knowledge, activity: activity)
    public let knowledge: KnowledgeLibrary
    private var knowledgeSync: KnowledgeSyncService?
    private var sessionsLoaded = false
    private var sessionsLoading: Task<Void, Never>?
    private var hasCreatedSession = false
    private var sessionSaveTask: Task<Void, Never>?
    private var sessionExchanges: [UUID: [ConversationExchange]] = [:]
    private var documentConversations: [UUID: DocumentConversationState] = [:]
    private var conversationContexts: [UUID: CompactedConversationContext] = [:]
    private var summaryTasks: [UUID: Task<Void, Never>] = [:]
    private var conversationCompactionTasks: [UUID: Task<Void, Never>] = [:]
    private var conversationCompactionFailures: Set<UUID> = []
    private var forcedConversationCompactions: Set<UUID> = []
    public let student: StudentPlanner
    public let activity = PetActivityStore()
    private var activityObservations: [AnyCancellable] = []
    private let plannerQuestionID = UUID()
    @Published public private(set) var sessionFolders: [UUID: SessionFolderRecord]
    @Published public private(set) var activeSessionID: UUID
    public var documentMemory: DocumentMemoryStore {
        // A default record is created at launch; selection accepts existing IDs only.
        sessionFolders[activeSessionID]!.documentMemory
    }
    @Published public internal(set) var isInactive = false
    @Published public private(set) var celebrationID = UUID()
    public private(set) var celebrationStartedAt = Date()
    @Published public var currentEmotion: PetEmotion {
        didSet {
            if currentEmotion == .celebrating { celebrationStartedAt = Date(); celebrationID = UUID() }
        }
    }
    var canPublishPlannerMessage: () -> Bool = { false }
    private(set) var foregroundOperationID: UUID?
    private(set) var foregroundEpoch = 0

    @discardableResult
    func beginForegroundOperation() -> UUID {
        foregroundEpoch += 1
        let id = UUID()
        foregroundOperationID = id
        return id
    }

    func finishForegroundOperation(_ id: UUID) {
        if foregroundOperationID == id { foregroundOperationID = nil }
    }

    func canPublishBackground(since epoch: Int) -> Bool {
        foregroundOperationID == nil && foregroundEpoch == epoch
    }

    @Published public var speechBubbleText: String
    @Published public var activeTask: PetTask?
    /// The goal timer publishes its remaining seconds here; zero at launch is inactive.
    @Published public var goalTimerSecondsRemaining: Int = 0
    public private(set) var goalTimerIsStudentManaged = false
    @Published public internal(set) var layoutCategory: PetLayoutCategory = .general

    public init(
        currentEmotion: PetEmotion = .idle,
        speechBubbleText: String = "Ready when you are.",
        activeTask: PetTask? = nil,
        studentStorageURL: URL? = nil,
        studentNow: @escaping () -> Date = Date.init,
        knowledge: KnowledgeLibrary? = nil
    ) {
        self.knowledge = knowledge ?? KnowledgeLibrary(embeddingProvider: nil)
        student = StudentPlanner(storageURL: studentStorageURL, now: studentNow)
        let initialSession = SessionFolderRecord(title: "Session 1")
        self.sessionFolders = [initialSession.id: initialSession]
        self.activeSessionID = initialSession.id
        initialSession.documentMemory.activity = activity
        self.currentEmotion = currentEmotion
        self.speechBubbleText = speechBubbleText
        self.activeTask = activeTask
        student.onMessage = { [weak self] message, emotion in
            guard let self else { return }
            if (self.foregroundOperationID != nil && !self.canPublishPlannerMessage()) || (self.student.isDeliveringAlert && self.activity.hasRunning) {
                if emotion == .celebrating { self.currentEmotion = .celebrating }
                return
            }
            self.speechBubbleText = message
            self.currentEmotion = emotion
        }
        student.onTimerChange = { [weak self] seconds, title in
            self?.goalTimerIsStudentManaged = true
            self?.goalTimerSecondsRemaining = seconds
            self?.activeTask = title.map { PetTask(title: $0) }
        }
        activityObservations.append(student.companionEvents.sink { [weak self] event in
            guard let self else { return }
            if case .alert(let text, _) = event {
                self.activity.record(title: "Study alert", message: text, preview: true)
            }
        })
        activityObservations.append(student.$pendingPrompt.sink { [weak self] prompt in
            guard let self else { return }
            self.activity.setQuestion(self.plannerQuestionID, message: prompt)
        })
        knowledgeSync = KnowledgeSyncService(planner: student, library: self.knowledge)
        student.newSession = { [weak self] title in self?.createSession(title: title) }
        configureSession(initialSession)
    }

    public func startKnowledge() async {
        await knowledgeSync?.start()
        if let sessionsLoading { await sessionsLoading.value; return }
        guard !sessionsLoaded else { return }
        let loading = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.restoreSessions()
        }
        sessionsLoading = loading
        await loading.value
        sessionsLoading = nil
    }

    private func restoreSessions() async {
        do {
            let saved = try await knowledge.store.sessions()
            let initialID = activeSessionID
            for session in saved where sessionFolders[session.id] == nil {
                let record = SessionFolderRecord(id: session.id, title: session.title)
                var restoredChunks: [DocumentChunk] = []
                for item in knowledge.items where item.sourceKey.hasPrefix("session-file:\(session.id):") {
                    restoredChunks += try await knowledge.store.documentChunks(itemID: item.id)
                }
                try record.documentMemory.restore(chunks: restoredChunks)
                configureSession(record)
                sessionFolders[record.id] = record
                sessionExchanges[record.id] = session.exchanges
                if let context = session.conversationContext { conversationContexts[record.id] = context }
                if var discussion = session.documentConversation {
                    // Evidence is always retrieved again after restoration.
                    if let context = discussion.context {
                        discussion.context = context.withEvidence([])
                    }
                    documentConversations[record.id] = discussion
                }
            }
            if let first = saved.first, !hasCreatedSession, !saved.contains(where: { $0.id == initialID }),
               sessionFolders.count == saved.count + 1,
               sessionFolders[initialID]?.documentMemory.isImporting == false,
               sessionFolders[initialID]?.files.isEmpty == true, sessionExchanges[initialID] == nil {
                sessionFolders.removeValue(forKey: initialID)
                activeSessionID = first.id
            }
            sessionsLoaded = true
            await ingestion.restore()
            resumeSessionAutomation()
        } catch {
            sessionsLoaded = false
            activity.record(title: "Session knowledge needs attention", message: error.localizedDescription, state: .blocked)
        }
    }
    public func waitForKnowledgeSync() async { await knowledgeSync?.wait() }

    public func sessionSnapshot(id: UUID) -> KnowledgeSession? {
        sessionFolders[id].map { KnowledgeSession(id: id, title: $0.title, exchanges: sessionExchanges[id] ?? [],
                                                   conversationContext: conversationContexts[id], documentConversation: documentConversations[id]) }
    }

    func documentConversation(id: UUID? = nil) -> DocumentConversationState {
        documentConversations[id ?? activeSessionID] ?? DocumentConversationState()
    }

    func saveDocumentConversation(_ discussion: DocumentConversationState, sessionID: UUID? = nil) {
        let id = sessionID ?? activeSessionID
        guard sessionFolders[id] != nil, documentConversations[id] != discussion else { return }
        documentConversations[id] = discussion
        enqueueSessionSave(id: id)
    }

    func clearDocumentConversations() {
        for id in sessionFolders.keys {
            documentConversations[id] = nil
            enqueueSessionSave(id: id)
        }
    }

    func conversationContext(id: UUID) -> CompactedConversationContext? { conversationContexts[id] }

    func saveConversationContext(_ context: CompactedConversationContext, sessionID: UUID) {
        guard sessionFolders[sessionID] != nil else { return }
        if conversationContexts[sessionID] != context { conversationCompactionFailures.remove(sessionID) }
        conversationContexts[sessionID] = context
        enqueueSessionSave(id: sessionID)
    }

    func scheduleConversationCompaction(sessionID: UUID, source: CompactedConversationContext,
                                        provider: any AssistantProvider, force: Bool = false) {
        conversationCompactionTasks[sessionID]?.cancel()
        if force { forcedConversationCompactions.insert(sessionID) }
        guard force || forcedConversationCompactions.contains(sessionID) || source.exchanges.count > 8
                || source.exchanges.reduce(0, { $0 + $1.characterCount }) > 24_000 else { return }
        conversationCompactionTasks[sessionID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
                guard let self, self.conversationContexts[sessionID] == source else { return }
                let candidates = Array(source.exchanges.dropLast(min(4, source.exchanges.count)))
                var targetCharacters = 0
                let targets = candidates.prefix(while: { exchange in
                    let next = targetCharacters + exchange.characterCount
                    guard next <= 16_000 || targetCharacters == 0 else { return false }
                    targetCharacters = next
                    return true
                })
                guard !targets.isEmpty else { return }
                let summary = try await ConversationCompactionService.compact(previous: source.summary, exchanges: Array(targets), provider: provider)
                try Task.checkCancellation()
                guard self.conversationContexts[sessionID] == source else { return }
                var updated = source
                updated.summary = summary
                updated.coveredExchangeIDs = Array((source.coveredExchangeIDs + targets.map(\.id)).suffix(80))
                updated.lastCoveredExchangeID = targets.last?.id ?? source.lastCoveredExchangeID
                let covered = Set(targets.map(\.id))
                updated.exchanges.removeAll { covered.contains($0.id) }
                await self.waitForSessionSave()
                guard self.conversationContexts[sessionID] == source,
                      var snapshot = self.sessionSnapshot(id: sessionID) else { return }
                snapshot.conversationContext = updated
                guard await self.knowledge.saveSession(snapshot) else {
                    throw KnowledgeError.database(self.knowledge.error ?? "Couldn’t save compacted conversation memory.")
                }
                guard !Task.isCancelled else {
                    self.enqueueSessionSave(id: sessionID)
                    return
                }
                if self.conversationContexts[sessionID] == source {
                    self.conversationContexts[sessionID] = updated
                } else {
                    self.enqueueSessionSave(id: sessionID)
                }
                self.conversationCompactionFailures.remove(sessionID)
                if updated.exchanges.count > 8 || updated.exchanges.reduce(0, { $0 + $1.characterCount }) > 24_000 {
                    self.scheduleConversationCompaction(sessionID: sessionID, source: updated, provider: provider,
                        force: self.forcedConversationCompactions.contains(sessionID))
                } else {
                    self.forcedConversationCompactions.remove(sessionID)
                }
            } catch is CancellationError { }
            catch {
                guard let self, self.conversationContexts[sessionID] == source,
                      !self.conversationCompactionFailures.contains(sessionID) else { return }
                self.conversationCompactionFailures.insert(sessionID)
                self.activity.record(title: "Conversation memory needs attention", message: error.localizedDescription, state: .blocked)
            }
        }
    }

    func cancelConversationCompaction() {
        for task in conversationCompactionTasks.values { task.cancel() }
        conversationCompactionTasks.removeAll()
    }

    func waitForConversationCompaction(id: UUID) async { await conversationCompactionTasks[id]?.value }

    func resumeConversationCompaction(provider: any AssistantProvider) {
        for (id, context) in conversationContexts {
            scheduleConversationCompaction(sessionID: id, source: context, provider: provider,
                force: forcedConversationCompactions.contains(id))
        }
    }

    public func recordSessionExchange(_ exchange: ConversationExchange, sessionID: UUID) {
        guard sessionFolders[sessionID] != nil else { return }
        var exchanges = sessionExchanges[sessionID] ?? []
        exchanges.append(exchange)
        while exchanges.count > 80 || exchanges.reduce(0, { $0 + $1.characterCount }) > 48_000 {
            exchanges.removeFirst()
        }
        sessionExchanges[sessionID] = exchanges
        enqueueSessionSave(id: sessionID)
        scheduleSessionSummary(id: sessionID)
    }

    func summarizeSession(id: UUID, provider: any AssistantProvider) async throws -> Bool {
        guard let snapshot = sessionSnapshot(id: id) else { throw KnowledgeError.invalidInput }
        let documents = knowledge.items.filter { $0.sourceKey.hasPrefix("session-file:\(id):") }
        guard !documents.isEmpty || !snapshot.exchanges.isEmpty else { throw KnowledgeError.invalidInput }
        let previous = knowledge.items.first { $0.sourceKey == "session-summary:\(id)" }?.text
        let text = try await SessionKnowledgeService.summarize(session: snapshot, documents: documents,
                                                               previousSummary: previous, provider: provider)
        guard sessionSnapshot(id: id) == snapshot,
              Dictionary(uniqueKeysWithValues: knowledge.items.filter({ $0.sourceKey.hasPrefix("session-file:\(id):") }).map { ($0.id, $0.contentHash) })
                == Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.contentHash) }) else { throw CancellationError() }
        return await knowledge.saveSessionSummary(snapshot, text: text)
    }

    private func scheduleSessionSummary(id: UUID) {
        summaryTasks[id]?.cancel()
        summaryTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
                guard let self, let provider = try? self.agent.providerFactory?() else { return }
                if !(try await self.summarizeSession(id: id, provider: provider)) {
                    throw KnowledgeError.database(self.knowledge.error ?? "Couldn’t save summary")
                }
            } catch is CancellationError { }
            catch {
                self?.activity.record(title: "Session summary needs attention", message: error.localizedDescription, state: .blocked)
            }
        }
    }

    private func configureSession(_ record: SessionFolderRecord) {
        record.documentMemory.activity = activity
        let sessionID = record.id
        record.documentMemory.persistImport = { [weak self] url, text in
            guard let self else { throw CancellationError() }
            await self.startKnowledge()
            // Keep the captured destination, even if the selected session changed while extracting.
            guard let snapshot = self.sessionSnapshot(id: sessionID) else { throw CancellationError() }
            _ = try await self.knowledge.saveUploadedDocument(snapshot, url: url, text: text)
        }
        record.documentMemory.persistedChunks = { [weak self] url in
            guard let self, let item = self.knowledge.items.first(where: {
                $0.sourceKey == "session-file:\(sessionID):\(url.standardizedFileURL.absoluteString)"
            }) else { throw CancellationError() }
            return try await self.knowledge.store.documentChunks(itemID: item.id)
        }
        record.documentMemory.didImport = { [weak self] url in
            guard let self else { return }
            let key = "session-file:\(sessionID):\(url.standardizedFileURL.absoluteString)"
            guard let item = self.knowledge.items.first(where: { $0.sourceKey == key }),
                  let pending = try? await self.knowledge.store.ingestionRecords().first(where: { $0.id == item.contentHash }) else { return }
            await self.ingestion.accept(pending)
            self.scheduleSessionSummary(id: sessionID)
        }
    }

    private func enqueueSessionSave(id: UUID) {
        guard let snapshot = sessionSnapshot(id: id) else { return }
        let previous = sessionSaveTask
        sessionSaveTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if !(await self.knowledge.saveSession(snapshot)) {
                self.activity.record(title: "Session could not be saved", message: self.knowledge.error ?? "Retry saving the session.", state: .blocked)
            }
        }
    }

    public func waitForSessionSave() async { await sessionSaveTask?.value }
    public func waitForSessionAutomation(id: UUID) async { await summaryTasks[id]?.value }

    func resumeSessionAutomation() {
        for task in summaryTasks.values { task.cancel() }
        summaryTasks.removeAll()
        for id in sessionFolders.keys {
            let documents = knowledge.items.filter { $0.sourceKey.hasPrefix("session-file:\(id):") }
            let summary = knowledge.items.first { $0.sourceKey == "session-summary:\(id)" }
            if summary == nil && (!documents.isEmpty || !(sessionExchanges[id] ?? []).isEmpty) {
                scheduleSessionSummary(id: id)
            }
        }
    }

    public func clearSessionDocuments() async {
        let id = activeSessionID
        documentConversations[id] = nil
        enqueueSessionSave(id: id)
        summaryTasks[id]?.cancel()
        documentMemory.clear()
        let items = knowledge.items.filter { $0.sourceKey.hasPrefix("session-file:\(id):") || $0.sourceKey == "session-summary:\(id)" }
        for item in items {
            if !(await knowledge.deleteItem(id: item.id)) {
                activity.record(title: "Session could not be cleared", message: knowledge.error ?? "Couldn’t remove saved document", state: .blocked)
            }
        }
    }

    func forgetSessionConversations() {
        clearDocumentConversations()
        cancelConversationCompaction()
        forcedConversationCompactions.removeAll()
        conversationCompactionFailures.removeAll()
        for task in summaryTasks.values { task.cancel() }
        summaryTasks.removeAll()
        for id in Set(sessionExchanges.keys).union(conversationContexts.keys).union(sessionFolders.keys) {
            sessionExchanges[id] = []
            conversationContexts[id] = CompactedConversationContext()
            enqueueSessionSave(id: id)
        }
    }

    func clearCompanionActivity() {
        activity.clear()
        activity.setQuestion(plannerQuestionID, message: student.pendingPrompt)
    }

    @discardableResult
    public func createSession(title: String) -> UUID {
        hasCreatedSession = true
        let record = SessionFolderRecord(title: title)
        record.documentMemory.activity = activity
        sessionFolders[record.id] = record
        configureSession(record)
        enqueueSessionSave(id: record.id)
        selectSession(id: record.id)
        return record.id
    }

    @discardableResult
    public func selectSession(id: UUID) -> Bool {
        guard sessionFolders[id] != nil else { return false }
        if activeSessionID != id { activeSessionID = id }
        return true
    }

    public func fetchContextForActiveSession(query: String) -> String {
        ScopedDocumentContextRouter(state: self).fetchContextForActiveSession(query: query)
    }
}
