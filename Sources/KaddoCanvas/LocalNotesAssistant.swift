import Combine
import Foundation

public struct DocumentFollowupContext: Codable, Equatable, Sendable {
    let sessionID: UUID
    let documentID: UUID
    let revision: Int
    let exercise: String?
    let originalQuestion: String
    let latestFollowup: String?
    let evidenceChunkIDs: Set<UUID>

    func withEvidence(_ ids: Set<UUID>) -> Self {
        Self(sessionID: sessionID, documentID: documentID, revision: revision, exercise: exercise,
             originalQuestion: originalQuestion, latestFollowup: latestFollowup, evidenceChunkIDs: ids)
    }
}

struct PreparedDocumentRequestSnapshot: Sendable {
    let systemPrompt: String
    let prompt: String
    let sources: [DocumentChunk]
}

@MainActor
public final class LocalNotesAssistant: ObservableObject {
    @Published public private(set) var isAnswering = false
    @Published public private(set) var sources: [DocumentChunk] = []
    @Published public private(set) var lastFailure: LocalInferenceError?
    private(set) var retrievalFailure: DocumentRetrievalError?
    private(set) var lastOutcome: DocumentResponseOutcome?
    private let state: PetApplicationState
    let client: OllamaClient
    var onContextChange: (() -> Void)?
    var onPreparedDocumentRequest: ((PreparedDocumentRequestSnapshot) -> Void)?
    var onDocumentOutcome: ((DocumentResponseOutcome) -> Void)?
    private var generation = UUID()
    private var worker: Task<DocumentResponseOutcome, Never>?
    private var decoder: OllamaStreamDecoder?
    private var selectedSources: [DocumentChunk] = []
    private var speechLines: [String] = []
    private var dependencies: [UUID: Int] = [:]
    private var foregroundID: UUID?
    private var ownedForegroundID: UUID?
    private var observations: [AnyCancellable] = []
    private var memoryObservation: AnyCancellable?

    var documentFollowupContext: DocumentFollowupContext? {
        let discussion = state.documentConversation()
        guard !discussion.needsReanchor, let context = discussion.context, isCurrent(context) else { return nil }
        return context
    }
    var lastDocumentQuestion: String? { documentFollowupContext?.originalQuestion }
    var hasPendingClarification: Bool { state.documentConversation().pendingClarification != nil }
    var isDiscussionActive: Bool { state.documentConversation().mode == .active }

    func makeCompanion(conversation: any ConversationStore) -> LocalCompanionAssistant {
        let companion = LocalCompanionAssistant(conversation: conversation, profile: { [weak state] in state?.student.profile?.snapshot })
        companion.onExchange = { [weak state] exchange in
            guard let state else { return }
            state.recordSessionExchange(exchange, sessionID: state.activeSessionID)
        }
        return companion
    }

    public init(state: PetApplicationState, client: OllamaClient) {
        self.state = state; self.client = client
        observeMemory(state.documentMemory)
        observations.append(state.$activeSessionID.dropFirst().sink { [weak self] id in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cancel(); self.sources = []
                self.onContextChange?()
                self.state.speechBubbleText = "Session changed. Ask a new question."
                if let memory = self.state.sessionFolders[id]?.documentMemory { self.observeMemory(memory) }
            }
        })
        observations.append(state.knowledge.$revision.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.validateDocuments() }
        })
    }

    private func observeMemory(_ memory: DocumentMemoryStore) {
        memoryObservation = memory.$chunks.dropFirst().sink { [weak self] chunks in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.student.dismissPersonalQuestion()
                guard chunks.isEmpty else { return }
                self.endDocumentConversation(); self.cancel(); self.onContextChange?()
                self.state.speechBubbleText = "Document notes changed. Ask a new question."
            }
        }
    }

    private func isCurrent(_ context: DocumentFollowupContext) -> Bool {
        context.sessionID == state.activeSessionID && state.knowledge.items.contains {
            $0.id == context.documentID && $0.revision == context.revision
                && $0.sourceKey.hasPrefix("session-file:\(context.sessionID):")
        }
    }

    private func validateDocuments() {
        for sessionID in state.sessionFolders.keys {
            var discussion = state.documentConversation(id: sessionID)
            guard let context = discussion.context else { continue }
            let item = state.knowledge.items.first {
                $0.id == context.documentID && $0.sourceKey.hasPrefix("session-file:\(sessionID):")
            }
            guard item?.revision != context.revision else { continue }
            if item != nil {
                discussion.context = context.withEvidence([])
                discussion.needsReanchor = true
                discussion.exchanges = []
            } else { discussion = DocumentConversationState() }
            state.saveDocumentConversation(discussion, sessionID: sessionID)
            if sessionID == state.activeSessionID { sources = [] }
        }
        if dependencies.contains(where: { id, revision in
            !state.knowledge.items.contains { $0.id == id && $0.revision == revision }
        }) {
            cancel(); sources = []; onContextChange?()
            state.speechBubbleText = "Document notes changed. Which current section or exercise should we resume?"
        }
    }

    func endDocumentConversation() {
        state.saveDocumentConversation(DocumentConversationState())
        sources = []
    }

    func retainDocumentConversation(after question: String? = nil) {
        var discussion = state.documentConversation()
        guard discussion.context != nil else { return }
        discussion.mode = .retained
        discussion.detourQuestion = question.map { String($0.prefix(300)) }
        state.saveDocumentConversation(discussion)
        sources = []
    }

    private func prepareInput(_ input: String) throws -> (question: String, context: DocumentFollowupContext?, history: [ConversationExchange]) {
        validateDocuments()
        var discussion = state.documentConversation()
        let documents = state.knowledge.items.filter {
            $0.sourceKind == "session-document" && (DocumentRetrievalService.allowsOtherSessions(input)
                || $0.sourceKey.hasPrefix("session-file:\(state.activeSessionID):"))
        }
        let named = documents.filter { DocumentQuestionRouter.explicitlyNamesDocument(input, filenames: [$0.title]) }
        if named.isEmpty && DocumentQuestionRouter.isAmbiguousReference(input) {
            throw DocumentRetrievalError.chooseDocument(documents.map(\.title).sorted())
        }
        var question = input
        if named.count == 1, let pending = discussion.pendingInput,
           DocumentQuestionReference.first(in: input) == nil,
           input.split(whereSeparator: \.isWhitespace).count <= 3 {
            question = pending + " in " + named[0].title
        }
        let reference = DocumentQuestionReference.first(in: question)
        if named.isEmpty, discussion.needsReanchor, let reference,
           let previous = discussion.context, let item = documents.first(where: { $0.id == previous.documentID }) {
            discussion.context = DocumentFollowupContext(sessionID: state.activeSessionID, documentID: item.id,
                revision: item.revision, exercise: "\(reference.kind) \(reference.number)",
                originalQuestion: question, latestFollowup: nil, evidenceChunkIDs: [])
            discussion.needsReanchor = false
        }
        if named.count == 1, let item = named.first {
            let previous = discussion.context
            let switched = previous?.documentID != item.id || previous?.revision != item.revision
            if DocumentQuestionRouter.isExplicitResume(input), !switched, let previous {
                question = previous.originalQuestion + "\nFollow-up: " + input
            }
            if switched { discussion.exchanges = [] }
            discussion.context = DocumentFollowupContext(sessionID: state.activeSessionID, documentID: item.id,
                revision: item.revision, exercise: reference.map { "\($0.kind) \($0.number)" },
                originalQuestion: DocumentQuestionRouter.isExplicitResume(input) && !switched
                    ? (previous?.originalQuestion ?? question) : question,
                latestFollowup: nil, evidenceChunkIDs: [])
            discussion.needsReanchor = false; discussion.mode = .active
        } else if named.isEmpty, let context = discussion.context {
            if discussion.needsReanchor {
                let title = documents.first { $0.id == context.documentID }?.title ?? "the changed document"
                throw DocumentRetrievalError.resumeDiscussion("\(title) changed. Which current section or exercise should we resume?")
            }
            if discussion.mode == .retained && reference == nil && !DocumentQuestionRouter.isExplicitResume(question) {
                let title = documents.first { $0.id == context.documentID }?.title ?? "your document"
                throw DocumentRetrievalError.resumeDiscussion("Do you mean \(title)\(context.exercise.map { ", " + $0 } ?? ""), or the recent general conversation? Say ‘continue with \(title)’ or clarify the topic.")
            }
            if let reference {
                question = input
                discussion.context = DocumentFollowupContext(sessionID: context.sessionID, documentID: context.documentID,
                    revision: context.revision, exercise: "\(reference.kind) \(reference.number)", originalQuestion: question,
                    latestFollowup: nil, evidenceChunkIDs: [])
            }
            discussion.mode = .active
        }
        discussion.pendingClarification = nil; discussion.pendingInput = nil
        state.saveDocumentConversation(discussion)
        let context = discussion.context
        if context == nil && DocumentQuestionRouter.isFollowup(question) && named.isEmpty {
            throw DocumentRetrievalError.chooseDocument(documents.map(\.title).sorted())
        }
        let continuation = named.isEmpty && reference == nil && context != nil
        let query = continuation ? DocumentQuestionRouter.groundedQuery(question,
            previousQuestion: context?.originalQuestion, filenames: documents.map(\.title)) : question
        return (query, context, continuation ? discussion.exchanges : [])
    }

    /// The action model receives only user-authored topic metadata, never passages or document answers.
    var routingContext: AssistantJSON {
        let discussion = state.documentConversation()
        guard let context = discussion.context,
              let item = state.knowledge.items.first(where: { $0.id == context.documentID }) else { return .null }
        return .object(["filename": .string(item.title), "documentID": .string(item.id.uuidString),
            "revision": .number(Double(item.revision)), "topic": context.exercise.map(AssistantJSON.string) ?? .null,
            "originalQuestion": .string(String(context.originalQuestion.prefix(600))), "mode": .string(discussion.mode.rawValue),
            "pendingClarification": discussion.pendingClarification.map(AssistantJSON.string) ?? .null,
            "recentUserRequests": .array(discussion.exchanges.suffix(3).map { .string(String($0.user.prefix(200))) })])
    }

    func makeProvider(model: String) -> OllamaAssistantProvider { OllamaAssistantProvider(client: client, model: model) }
    public func localModelNames() async throws -> [String] { try await client.localModelNames() }

    public func answer(query: String, model: String = "llama3.1:8b") async {
        _ = await respond(query: query, model: model)
    }
    func answerCloud(query: String, provider: any AssistantProvider) async throws -> String {
        try await respond(query: query, provider: provider).answerOrThrow().text
    }

    /// Local and cloud transports share preparation, validation, commits, and typed outcomes.
    func respond(query: String, model: String = "cloud", provider: (any AssistantProvider)? = nil) async -> DocumentResponseOutcome {
        cancel()
        let ticket = UUID(); generation = ticket
        let sessionID = state.activeSessionID
        let ownsForeground = state.foregroundOperationID == nil
        let operationID = state.foregroundOperationID ?? state.beginForegroundOperation()
        foregroundID = operationID
        if ownsForeground { ownedForegroundID = operationID }
        isAnswering = true; lastOutcome = nil; sources = []
        state.currentEmotion = .thinking
        let operation = Task<DocumentResponseOutcome, Never> { [weak self] in
            guard let self else { return .cancelled }
            do {
                try Task.checkCancellation()
                if provider == nil && self.state.documentMemory.chunks.isEmpty && !DocumentRetrievalService.allowsOtherSessions(query) {
                    throw LocalInferenceError.noRelevantContext
                }
                let preparedInput = try self.prepareInput(query.trimmingCharacters(in: .whitespacesAndNewlines))
                let result = try await DocumentRetrievalService(library: self.state.knowledge).retrieve(.init(
                    sessionID: sessionID, question: preparedInput.question,
                    preferredDocumentID: preparedInput.context?.documentID,
                    preferredRevision: preparedInput.context?.revision,
                    preferredExercise: preparedInput.context?.exercise,
                    contextChunkIDs: Array(preparedInput.context?.evidenceChunkIDs ?? [])))
                guard !result.evidence.isEmpty else { throw DocumentRetrievalError.noEvidence("this document") }
                self.dependencies = Dictionary(uniqueKeysWithValues: self.state.knowledge.items.filter { item in
                    result.evidence.contains { $0.documentID == item.id }
                }.map { ($0.id, $0.revision) })
                let prepared = try OfflinePromptBuilder().prepare(query: preparedInput.question, matches: result.matches,
                    model: model, characterBudget: 12_000, maximumSources: 48, limitations: result.limitations,
                    evidenceRoles: result.evidenceRoles, currentQuestion: query,
                    history: preparedInput.history, focus: preparedInput.context, requiredSourceIDs: result.requiredSupportIDs)
                guard result.requiredSupportIDs.isSubset(of: Set(prepared.sources.map(\.id))) else {
                    throw DocumentRetrievalError.missingRequiredSupport
                }
                try self.checkCurrent(ticket, operationID: operationID)
                self.selectedSources = prepared.sources
                self.decoder = OllamaStreamDecoder(sourceIDs: Set(prepared.sources.map(\.id)), requiredSourceIDs: result.requiredSupportIDs)
                self.state.speechBubbleText = provider == nil ? "Reading local notes…" : "Reading document excerpts with the cloud AI provider…"
                if let provider {
                    var request = AssistantRequest(instructions: prepared.request.system,
                        input: [.message(prepared.request.prompt)], toolsEnabled: false, responseFormat: .jsonObject)
                    for attempt in 0..<2 {
                        do {
                            self.onPreparedDocumentRequest?(.init(systemPrompt: request.instructions,
                                prompt: prepared.request.prompt, sources: prepared.sources))
                            let turn = try await provider.respond(to: request)
                            guard turn.calls.isEmpty else { throw AssistantError.invalidResponse }
                            try self.receive(AssistantJSON.object(["response": .string(turn.text), "done": .bool(true)]).jsonString(), ticket: ticket)
                            try self.decoder?.finish()
                            break
                        } catch {
                            let invalid = (error as? LocalInferenceError) == .malformedResponse
                                || (error as? AssistantError) == .invalidResponse
                            guard attempt == 0, invalid else { throw error }
                            try self.checkCurrent(ticket, operationID: operationID)
                            self.speechLines = []; self.sources = []
                            self.decoder = OllamaStreamDecoder(sourceIDs: Set(prepared.sources.map(\.id)),
                                requiredSourceIDs: result.requiredSupportIDs)
                            self.state.speechBubbleText = "Checking the document answer format…"
                            request.instructions += "\nThe previous attempt violated the response contract. Return valid JSON with 1–8 lines, no line over 500 characters, properly escaped strings, and all requiredCitationIDs cited on supported statements."
                        }
                    }
                } else {
                    self.onPreparedDocumentRequest?(.init(systemPrompt: prepared.request.system,
                        prompt: prepared.request.prompt, sources: prepared.sources))
                    try await self.client.generate(prepared.request) { [weak self] line in
                        guard let self else { throw CancellationError() }
                        try await self.receive(line, ticket: ticket)
                    }
                }
                try self.checkCurrent(ticket, operationID: operationID)
                try self.decoder?.finish()
                let text = self.speechLines.joined(separator: "\n")
                var discussion = self.state.documentConversation(id: sessionID)
                if let focus = result.focus {
                    if discussion.context?.documentID != focus.documentID || discussion.context?.revision != focus.revision {
                        discussion.exchanges = []
                    }
                    let original = preparedInput.context?.originalQuestion ?? query
                    discussion.context = DocumentFollowupContext(sessionID: sessionID, documentID: focus.documentID,
                        revision: focus.revision, exercise: focus.exercise, originalQuestion: original,
                        latestFollowup: query == original ? nil : query, evidenceChunkIDs: Set(prepared.sources.map(\.id)))
                    try await self.state.knowledge.store.saveDocumentFocus(focus, sessionID: sessionID)
                } else { discussion.context = nil; discussion.exchanges = [] }
                try self.checkCurrent(ticket, operationID: operationID)
                discussion.append(.init(user: query, companion: text))
                discussion.pendingClarification = nil; discussion.pendingInput = nil; discussion.mode = .active
                self.state.saveDocumentConversation(discussion, sessionID: sessionID)
                return .answered(.init(text: text, sources: self.sources, context: discussion.context))
            } catch is CancellationError { return .cancelled }
            catch let error as DocumentRetrievalError { return .needsInput(error) }
            catch { return .failed(error) }
        }
        worker = operation
        let outcome = await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
        // Retired generations can report cancellation to their caller but cannot publish or mutate state.
        if generation == ticket {
            lastOutcome = outcome
            switch outcome {
            case .answered: break
            case .needsInput(let error):
                retrievalFailure = error; sources = []; state.currentEmotion = .idle
                var discussion = state.documentConversation(id: sessionID)
                discussion.pendingClarification = error.localizedDescription; discussion.pendingInput = query
                state.saveDocumentConversation(discussion, sessionID: sessionID)
                state.speechBubbleText = error.localizedDescription
            case .failed(let error):
                lastFailure = error as? LocalInferenceError ?? .generationFailed
                sources = []; state.speechBubbleText = error.localizedDescription; state.currentEmotion = .idle
            case .cancelled: sources = []; state.speechBubbleText = "Answer cancelled."; state.currentEmotion = .idle
            }
            if state.currentEmotion == .thinking { state.currentEmotion = .idle }
            isAnswering = false; worker = nil; decoder = nil; dependencies = [:]
            onDocumentOutcome?(outcome)
        }
        if ownsForeground {
            state.finishForegroundOperation(operationID)
            if ownedForegroundID == operationID { ownedForegroundID = nil }
        }
        return outcome
    }

    private func checkCurrent(_ ticket: UUID, operationID: UUID) throws {
        try Task.checkCancellation()
        guard generation == ticket, state.foregroundOperationID == operationID,
              dependencies.allSatisfy({ id, revision in state.knowledge.items.contains { $0.id == id && $0.revision == revision } }) else {
            throw CancellationError()
        }
    }

    public func cancel() {
        if let id = ownedForegroundID { state.finishForegroundOperation(id); ownedForegroundID = nil }
        generation = UUID(); worker?.cancel(); worker = nil
        decoder = nil; selectedSources = []; speechLines = []; dependencies = [:]
        lastFailure = nil; retrievalFailure = nil
        if isAnswering { sources = []; state.currentEmotion = .idle; state.speechBubbleText = "Answer cancelled." }
        isAnswering = false
    }
    func clearSources() { sources = [] }

    private func receive(_ wireLine: String, ticket: UUID) throws {
        guard let operationID = foregroundID else { throw CancellationError() }
        try checkCurrent(ticket, operationID: operationID)
        guard decoder != nil else { throw CancellationError() }
        for line in try decoder!.consume(wireLine) {
            speechLines.append(line.speechBubbleText)
            let ids = Set(sources.map(\.id)).union(line.sourceIDs)
            sources = selectedSources.filter { ids.contains($0.id) }
            state.speechBubbleText = speechLines.joined(separator: "\n")
            state.currentEmotion = line.currentEmotion
        }
    }
    deinit { worker?.cancel() }
}
