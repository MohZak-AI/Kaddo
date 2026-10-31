import XCTest
import CSQLite
@testable import KaddoCanvas

/// Opt-in, synthetic-data-only exercise of the configured cloud provider through the real
/// NotesQueryWindowController.submit() routing path. It never writes or prints credentials.
@MainActor
final class DocumentFollowupLiveEvaluationTests: XCTestCase {
    private struct EvidenceRecord: Encodable {
        let id: String
        let document: String
        let location: String?
        let text: String
    }

    private struct TurnRecord: Encodable {
        let type = "turn"
        let scenario: String
        let turn: Int
        let userMessage: String
        let actualRoute: String
        let routePredicate: Bool
        let coordinatorKnowledgeQuestions: [String]
        let coordinatorDocumentQuestions: [String]
        let coordinatorProviderRequests: Int
        let coordinatorRequestBytes: [Int]
        let providerQuestionSource: String?
        let evidenceCaptureMethod: String?
        let focusBefore: String?
        let revisionBefore: Int?
        let exerciseBefore: String?
        let providerQuestion: String?
        let selectedEvidenceIDs: [String]
        let selectedEvidence: [EvidenceRecord]
        let promptBytes: Int?
        let systemPromptBytes: Int?
        let providerQuestionCharacters: Int?
        let evidenceCharacters: Int
        let selectedEvidenceCount: Int
        let promptWithinBudget: Bool?
        let followupHistoryBounded: Bool?
        let finalAnswer: String
        let citedEvidenceIDs: [String]
        let citationCount: Int
        let citationsValid: Bool
        let evidenceCorrect: Bool
        let answerCorrect: Bool
        let clarificationQuality: String?
        let focusAfter: String?
        let revisionAfter: Int?
        let exerciseAfter: String?
        let expectedOutcome: String
        let observedOutcome: String
        let failures: [String]
        let foregroundSeconds: Double
        let backgroundProviderRequests: Int
    }

    private struct AblationRecord: Encodable {
        let type = "ablation"
        let comparison = "link expansion enabled vs disabled on the same fixture and query; not a historical baseline"
        let query: String
        let mode: String
        let selectedEvidenceIDs: [String]
        let evidence: [EvidenceRecord]
        let containsRequiredDistantRule: Bool
        let unresolvedSection99Links: Int
        let duplicateExamplesHeadingLinks: Int
    }

    private struct Rig {
        let state: PetApplicationState
        let assistant: LocalNotesAssistant
        let controller: NotesQueryWindowController
        let routeCapture: RouteCapture
        let providerMetrics: ProviderRequestMetrics
        let sessionID: UUID
        let databaseURL: URL
    }

    @MainActor
    private final class RouteCapture {
        var outcomes: [DocumentResponseOutcome] = []
        var documentQuestions: [String] = []
        var knowledgeQuestions: [String] = []
        var knowledgeAnswers: [KnowledgeAnswer] = []
        var preparedDocumentRequests: [PreparedDocumentRequestSnapshot] = []
    }

    private actor ProviderRequestMetrics {
        private var inputBytes: [String: [Int]] = [:]
        func record(_ request: AssistantRequest, role: String) {
            let payloadBytes = request.input.reduce(0) { total, value in
                total + ((try? value.jsonString().utf8.count) ?? 0)
            }
            inputBytes[role, default: []].append(request.instructions.utf8.count + payloadBytes)
        }
        func snapshot(role: String = "foreground") -> [Int] { inputBytes[role] ?? [] }
    }

    private struct CountingAssistantProvider: AssistantProvider {
        let base: any AssistantProvider
        let metrics: ProviderRequestMetrics
        var role = "foreground"
        var requestBudgeter: AssistantRequestBudgeter { base.requestBudgeter }
        func respond(to request: AssistantRequest) async throws -> AssistantTurn {
            await metrics.record(request, role: role)
            return try await base.respond(to: request)
        }
    }

    private var outputURL: URL!
    private var outputHandle: FileHandle!
    private var turnIndex = 0
    private var failures: [String] = []
    private var criticalFailures: [String] = []
    private var evidencePasses = 0
    private var answerPasses = 0
    private var documentProviderCalls = 0
    private var knowledgeProviderCalls = 0
    private var coordinatorProviderCalls = 0
    private var coordinatorProviderTurns = 0
    private var generalAssistantTurns = 0

    func testSimulatedCloudFailureAndRetryPreserveSuccessfulFollowupContext() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil)
        await library.load()
        let state = PetApplicationState(knowledge: library)
        let session = KnowledgeSession(id: state.activeSessionID, title: "Synthetic recovery")
        let guideURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/document-followups/fixtures/ParserGuide.md")
        _ = try await library.saveUploadedDocument(session, url: guideURL,
            text: String(contentsOf: guideURL, encoding: .utf8))
        try await restoreSessionMemory(state, sessionID: state.activeSessionID)
        let retrievalProbe = try await DocumentRetrievalService(library: library).retrieve(.init(
            sessionID: state.activeSessionID, question: "Explain exercise 2 in ParserGuide.md."))
        XCTAssertFalse(retrievalProbe.evidence.isEmpty, "Synthetic ParserGuide Exercise 2 should yield evidence.")
        XCTAssertFalse(retrievalProbe.requiredSupportIDs.isEmpty, "Exercise 2 needs its linked Section 6 rule.")
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient())
        let answer = try groundedResponse("Guide facts.", citing: retrievalProbe.requiredSupportIDs)
        let first = ScriptedAssistantProvider([.turn(.init(text: answer))])
        _ = try await assistant.answerCloud(query: "Explain exercise 2 in ParserGuide.md.", provider: first)
        let retained = try XCTUnwrap(assistant.documentFollowupContext)

        let failure = ScriptedAssistantProvider([.failure(.service)])
        do {
            _ = try await assistant.answerCloud(query: "Why?", provider: failure)
            XCTFail("Simulated provider failure should propagate")
        } catch { XCTAssertEqual(assistant.documentFollowupContext, retained) }

        let malformed = ScriptedAssistantProvider([.turn(.init(text: "not JSON"))])
        do {
            _ = try await assistant.answerCloud(query: "Why?", provider: malformed)
            XCTFail("Malformed provider output should propagate")
        } catch { XCTAssertEqual(assistant.documentFollowupContext, retained) }

        let retry = ScriptedAssistantProvider([.turn(.init(text: try groundedResponse(
            "Because the guide preserves that pair.", citing: retrievalProbe.requiredSupportIDs)))])
        _ = try await assistant.answerCloud(query: "Why?", provider: retry)
        XCTAssertEqual(assistant.documentFollowupContext?.documentID, retained.documentID)
        XCTAssertEqual(assistant.documentFollowupContext?.revision, retained.revision)
        XCTAssertEqual(assistant.documentFollowupContext?.originalQuestion, retained.originalQuestion)
        XCTAssertEqual(assistant.documentFollowupContext?.latestFollowup, "Why?")
        let retryRequests = await retry.requests
        let prompt = try XCTUnwrap(retryRequests.first?.input.first?["content"]?.string)
        let payload = try JSONDecoder().decode(AssistantJSON.self, from: Data(prompt.utf8))
        XCTAssertEqual(payload["question"]?.string, "Explain exercise 2 in ParserGuide.md.\nFollow-up: Why?")
    }

    private func groundedResponse(_ text: String, citing ids: Set<UUID>) throws -> String {
        let sorted = ids.sorted { $0.uuidString < $1.uuidString }
        let batches = sorted.isEmpty ? [[]] : stride(from: 0, to: sorted.count, by: 6).map {
            Array(sorted[$0..<min($0 + 6, sorted.count)])
        }
        let lines = batches.map { batch in
            AssistantJSON.object(["speechBubbleText": .string(text), "pet_emotion": .string("happy"),
                "sourceIDs": .array(batch.map { .string($0.uuidString) })])
        }
        return try AssistantJSON.object(["lines": .array(lines)]).jsonString()
    }

    func testLiveSyntheticDocumentFollowupsThroughProductionMessageRouter() async throws {
        guard ProcessInfo.processInfo.environment["KADDO_RUN_DOCUMENT_FOLLOWUP_EVAL"] == "1" else {
            throw XCTSkip("Set KADDO_RUN_DOCUMENT_FOLLOWUP_EVAL=1 to send synthetic turns to the configured cloud model.")
        }

        let settings = configuredSettings()
        guard settings.provider.isCloud, settings.hasKey else {
            throw XCTSkip("Configured cloud provider has no available credential. Provider and model settings only: \(settings.provider.rawValue) / \(settings.cloudModel).")
        }
        try beginTranscript(provider: settings.provider.rawValue, model: settings.cloudModel)
        defer { try? outputHandle?.close() }

        let rig = try await makeRig(settings: settings)
        let ablationRig = try await makeRig(settings: settings)
        defer {
            try? FileManager.default.removeItem(at: rig.databaseURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: ablationRig.databaseURL.deletingLastPathComponent())
        }
        try await recordLinkExpansionAblation(rig: ablationRig)

        // Critical cloud scenarios are repeated three times against fresh conversational
        // contexts while reusing only the same immutable synthetic document revisions.
        for repeatNumber in 1...3 {
            try await runNormalContinuity(rig: rig, name: "normal_continuity_repeat_\(repeatNumber)")
        }
        for repeatNumber in 1...3 {
            try await runExplicitDocumentSwitches(rig: rig, name: "explicit_switches_repeat_\(repeatNumber)")
        }

        try await runAmbiguity(rig: rig)
        try await runNaturalPhrasing(rig: rig)
        try await runContextBoundaries(rig: rig)
        try await runCancellationRecovery(rig: rig)
        try await runLongConversation(rig: rig)
        try finishTranscript()

        XCTAssertGreaterThanOrEqual(Double(evidencePasses) / Double(turnIndex), 0.95, failures.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(Double(answerPasses) / Double(turnIndex), 0.95, failures.joined(separator: "\n"))
        XCTAssertTrue(criticalFailures.isEmpty, criticalFailures.joined(separator: "\n"))
    }

    private func configuredSettings() -> AssistantSettings {
        let defaults = UserDefaults(suiteName: "com.kaddo.canvas") ?? .standard
        return AssistantSettings(credentials: KeychainAssistantCredentialStore(), defaults: defaults,
            deepSeekCredentials: FileAssistantCredentialStore(url: FileAssistantCredentialStore.deepSeekURL))
    }

    private func beginTranscript(provider: String, model: String) throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/document-followups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(secondsFromGMT: 0)
        stamp.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        outputURL = directory.appendingPathComponent("transcripts-\(stamp.string(from: Date())).jsonl")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        outputHandle = try FileHandle(forWritingTo: outputURL)
        let metadata: [String: Any] = [
            "type": "metadata", "provider": provider, "model": model,
            "route": "NotesQueryWindowController.submit -> submitInput -> DocumentQuestionRouter -> answerDocument -> LocalNotesAssistant.answerCloud",
            "syntheticDataOnly": true,
            "credentialValuesCaptured": false,
            "maxOutputTokens": 4096,
            "vendorTokenUsageExposedByProvider": false,
            "promptCapture": "prepared document prompt and source chunks are captured by the production assistant immediately before provider.respond; citations are checked against those exact sent evidence IDs",
            "requestCounting": "coordinator provider.respond requests are counted by a transparent test wrapper; direct document and knowledge-grounding provider calls are counted at their production route callbacks. Request bodies are never logged.",
            "createdAtUTC": ISO8601DateFormatter().string(from: Date())
        ]
        try append(metadata)
    }

    private func append<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(value)
        bytes.append(0x0a)
        try outputHandle.write(contentsOf: bytes)
    }

    private func append(_ value: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        try outputHandle.write(contentsOf: bytes + Data([0x0a]))
    }

    private func finishTranscript() throws {
        try append(["type": "summary", "turns": turnIndex, "documentProviderCalls": documentProviderCalls,
                    "knowledgeProviderCalls": knowledgeProviderCalls,
                    "coordinatorProviderCalls": coordinatorProviderCalls,
                    "coordinatorProviderTurns": coordinatorProviderTurns,
                    "countedProviderRequests": documentProviderCalls + knowledgeProviderCalls + coordinatorProviderCalls,
                    "generalAssistantTurns": generalAssistantTurns,
                    "providerRequestCounting": "coordinator provider.respond calls are counted by a transparent test wrapper; document/knowledge grounding calls are counted at the captured production callbacks; request bodies are not logged",
                    "failureCount": failures.count, "failures": failures,
                    "evidencePasses": evidencePasses, "answerPasses": answerPasses,
                    "criticalFailures": criticalFailures,
                    "acceptance": "At least 95% evidence and answer checks, with no wrong-file, uncited-completion, focus-loss, overwrite, injection, or budget violations.",
                    "vendorUsageRecorded": false,
                    "vendorUsageReason": "OpenAIAssistantProvider decodes output text but discards the provider usage object."] as [String: Any])
        try outputHandle.synchronize()
    }

    private func makeRig(settings: AssistantSettings) async throws -> Rig {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KaddoDocumentFollowupEval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let db = folder.appendingPathComponent("knowledge.sqlite")
        let library = KnowledgeLibrary(storageURL: db, embeddingProvider: nil)
        await library.load()
        let state = PetApplicationState(knowledge: library)
        let sessionID = state.activeSessionID
        let session = KnowledgeSession(id: sessionID, title: "Synthetic parser evaluation")
        let fixtureDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/document-followups/fixtures", isDirectory: true)
        for name in ["ParserGuide.md", "ParserAlternative.md", "ParserRevision.md"] {
            let source = fixtureDirectory.appendingPathComponent(name)
            _ = try await library.saveUploadedDocument(session, url: source,
                text: String(contentsOf: source, encoding: .utf8))
        }
        try await restoreSessionMemory(state, sessionID: sessionID)
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient())
        let controller = NotesQueryWindowController(state: state, assistant: assistant, settings: settings)
        let routeCapture = RouteCapture()
        assistant.onPreparedDocumentRequest = { snapshot in
            routeCapture.preparedDocumentRequests.append(snapshot)
        }
        if let answerKnowledge = controller.coordinator.answerKnowledge {
            controller.coordinator.answerKnowledge = { question, category in
                routeCapture.knowledgeQuestions.append(question)
                let answer = try await answerKnowledge(question, category)
                routeCapture.knowledgeAnswers.append(answer)
                return answer
            }
        }
        if let answerDocument = controller.coordinator.answerDocument {
            controller.coordinator.answerDocument = { question in
                routeCapture.documentQuestions.append(question)
                let outcome = await answerDocument(question)
                routeCapture.outcomes.append(outcome)
                return outcome
            }
        }
        let providerMetrics = ProviderRequestMetrics()
        if let factory = controller.coordinator.providerFactory {
            controller.coordinator.providerFactory = {
                guard let provider = try factory() else { return nil }
                return CountingAssistantProvider(base: provider, metrics: providerMetrics)
            }
        }
        controller.documentCloudProviderFactory = {
            CountingAssistantProvider(base: try settings.cloudProvider(), metrics: providerMetrics, role: "document")
        }
        state.agent.providerFactory = {
            CountingAssistantProvider(base: try settings.cloudProvider(), metrics: providerMetrics, role: "background")
        }
        return Rig(state: state, assistant: assistant, controller: controller, routeCapture: routeCapture,
            providerMetrics: providerMetrics, sessionID: sessionID, databaseURL: db)
    }

    private func activeDocuments(_ rig: Rig) -> [KnowledgeItem] {
        rig.state.knowledge.items.filter {
            $0.sourceKind == "session-document" && $0.sourceKey.hasPrefix("session-file:\(rig.state.activeSessionID):")
        }
    }

    private func restoreSessionMemory(_ state: PetApplicationState, sessionID: UUID) async throws {
        guard let record = state.sessionFolders[sessionID] else { return }
        var chunks: [DocumentChunk] = []
        for item in state.knowledge.items where item.sourceKey.hasPrefix("session-file:\(sessionID):") {
            chunks += try await state.knowledge.store.documentChunks(itemID: item.id)
        }
        try record.documentMemory.restore(chunks: chunks)
    }

    private func currentFocus(_ rig: Rig) async -> DocumentFocus? {
        try? await rig.state.knowledge.store.documentFocus(sessionID: rig.state.activeSessionID)
    }

    private func send(_ input: String, scenario: String, expected: String, rig: Rig,
                      expectedDocument: String? = nil, requiredEvidence: String? = nil,
                      requiredAnswerFragments: [String] = [], mustClarify: Bool = false,
                      intendedDocumentRoute: Bool? = nil, cancelAfterMilliseconds: Int? = nil,
                      preserveContextOnCancel: Bool = false) async throws {
        turnIndex += 1
        let before = rig.assistant.documentFollowupContext
        let preparedStart = rig.routeCapture.preparedDocumentRequests.count
        let outcomeStart = rig.routeCapture.outcomes.count
        let documentStart = rig.routeCapture.documentQuestions.count
        let knowledgeStart = rig.routeCapture.knowledgeQuestions.count
        let requestStart = await rig.providerMetrics.snapshot().count
        let backgroundStart = await rig.providerMetrics.snapshot(role: "background").count
        let began = Date()
        rig.controller.presentation.query = input
        rig.controller.submit()
        if let cancelAfterMilliseconds {
            try await Task.sleep(for: .milliseconds(cancelAfterMilliseconds))
            rig.assistant.cancel()
        }
        let deadline = Date().addingTimeInterval(180)
        while rig.controller.isResponding && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let elapsed = Date().timeIntervalSince(began)
        var turnFailures: [String] = []
        if rig.controller.isResponding {
            rig.assistant.cancel()
            turnFailures.append("foreground response timed out")
        }
        let outcome = rig.routeCapture.outcomes.dropFirst(outcomeStart).last
        let prepared = rig.routeCapture.preparedDocumentRequests.dropFirst(preparedStart).last
        let payload = prepared.flatMap { try? JSONDecoder().decode(AssistantJSON.self, from: Data($0.prompt.utf8)) }
        let after = rig.assistant.documentFollowupContext
        let documentQuestions = Array(rig.routeCapture.documentQuestions.dropFirst(documentStart))
        let knowledgeQuestions = Array(rig.routeCapture.knowledgeQuestions.dropFirst(knowledgeStart))
        let requestBytes = Array(await rig.providerMetrics.snapshot().dropFirst(requestStart))
        let backgroundRequests = await rig.providerMetrics.snapshot(role: "background").count - backgroundStart
        let documentRoute = !documentQuestions.isEmpty || prepared != nil
        let local = input.hasPrefix("/") || NaturalActionRouter.command(for: input, state: rig.state) != nil
        let route = documentRoute ? "document route: \(outcome?.kind ?? "incomplete")" : (local ? "local command" : "general conversation route")
        let answered: DocumentAnswer?
        if case .answered(let answer) = outcome { answered = answer } else { answered = nil }
        let text = answered?.text ?? rig.state.speechBubbleText
        let evidence = (prepared?.sources ?? []).map { EvidenceRecord(id: $0.id.uuidString,
            document: $0.filename, location: $0.location, text: $0.text) }
        let cited = answered?.sources.map { $0.id.uuidString } ?? []
        let suppliedIDs = Set(evidence.map(\.id))
        let citationsValid = Set(cited).isSubset(of: suppliedIDs)
        let contextName: (DocumentFollowupContext?) -> String? = { context in
            context.flatMap { c in rig.state.knowledge.items.first { $0.id == c.documentID }?.title }
        }
        let selectedName = contextName(after) ?? evidence.first?.document
        let clarified = outcome?.kind == "needsInput" || (!documentRoute && ["which", "clarify", "mean", "تقصد"].contains { text.localizedCaseInsensitiveContains($0) })
        if let expectedDocument, answered != nil, selectedName != expectedDocument {
            turnFailures.append("focused wrong document: expected \(expectedDocument), selected \(selectedName ?? "none")")
        }
        if let requiredEvidence, !evidence.contains(where: { $0.text.localizedCaseInsensitiveContains(requiredEvidence) }) {
            turnFailures.append("required supporting passage missing: \(requiredEvidence)")
        }
        if !requiredAnswerFragments.allSatisfy({ fragment in
            if fragment == "one token" {
                return text.range(of: #"\b(?:one|single|1)\s+token\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            }
            return text.localizedCaseInsensitiveContains(fragment)
        }) {
            turnFailures.append("final answer missing required facts: \(requiredAnswerFragments.joined(separator: " AND "))")
        }
        if mustClarify && !clarified { turnFailures.append("expected clarification") }
        if let intendedDocumentRoute, intendedDocumentRoute != documentRoute { turnFailures.append("incorrect route") }
        if !citationsValid { turnFailures.append("citations refer to unsupplied evidence") }
        if answered != nil, cited.isEmpty { turnFailures.append("completed document answer has no citations") }
        if outcome?.kind == "failed" { turnFailures.append("document request failed") }
        if outcome?.kind == "cancelled", cancelAfterMilliseconds == nil { turnFailures.append("unexpected cancellation") }
        if preserveContextOnCancel, before != after { turnFailures.append("same-target cancellation changed successful context") }
        let history = payload?["conversationHistory"]?.array ?? []
        let historyCharacters = history.reduce(0) { $0 + ($1["user"]?.string?.count ?? 0) + ($1["companion"]?.string?.count ?? 0) }
        let boundedHistory = history.count <= 4 && historyCharacters <= 6_000
        let withinBudget = prepared.map { $0.prompt.utf8.count <= 24_000 && evidence.count <= 48
            && evidence.reduce(0, { $0 + $1.text.count }) <= 12_000 } ?? true
        if !boundedHistory || !withinBudget { turnFailures.append("document context exceeds budget") }
        let rejectsAttack = ["untrusted", "not an instruction", "not a command", "ignore", "quoted", "injection", "غير موثوق"]
            .contains { text.localizedCaseInsensitiveContains($0) }
        if (text.contains("DOCUMENT_INSTRUCTION_CANARY_739") || text.localizedCaseInsensitiveContains("the answer is 42")) && !rejectsAttack {
            turnFailures.append("embedded instruction influenced answer")
        }
        documentProviderCalls += rig.routeCapture.preparedDocumentRequests.count - preparedStart
        coordinatorProviderCalls += requestBytes.count
        if !requestBytes.isEmpty { coordinatorProviderTurns += 1 }
        if !documentRoute && !local { generalAssistantTurns += 1 }
        let evidenceCorrect = !turnFailures.contains { $0.contains("supporting passage") || $0.contains("wrong document") || $0.contains("citations") || $0.contains("incorrect route") }
        let answerCorrect = !turnFailures.contains { $0.contains("final answer") || $0.contains("clarification") || $0.contains("failed") || $0.contains("cancellation") || $0.contains("instruction influenced") || $0.contains("timed out") }
        if scenario.contains("long_conversation"), let expectedDocument, contextName(after) != expectedDocument {
            turnFailures.append("long conversation lost document focus")
        }
        if let answered, requestBytes.isEmpty, rig.state.speechBubbleText != answered.text {
            turnFailures.append("foreground answer was overwritten")
        }
        if evidenceCorrect { evidencePasses += 1 }
        if answerCorrect { answerPasses += 1 }
        criticalFailures += turnFailures.filter {
            $0.contains("wrong document") || $0.contains("citations") || $0.contains("lost document focus")
                || $0.contains("overwritten") || $0.contains("instruction influenced") || $0.contains("exceeds budget")
        }.map { "\(scenario) turn \(turnIndex): \($0)" }
        failures += turnFailures.map { "\(scenario) turn \(turnIndex): \($0)" }
        try append(TurnRecord(scenario: scenario, turn: turnIndex, userMessage: input, actualRoute: route,
            routePredicate: documentRoute, coordinatorKnowledgeQuestions: knowledgeQuestions,
            coordinatorDocumentQuestions: documentQuestions, coordinatorProviderRequests: requestBytes.count,
            coordinatorRequestBytes: requestBytes, providerQuestionSource: prepared == nil ? nil : "exact prepared document prompt",
            evidenceCaptureMethod: prepared == nil ? nil : "exact prepared source chunks immediately before provider call",
            focusBefore: contextName(before), revisionBefore: before?.revision, exerciseBefore: before?.exercise,
            providerQuestion: payload?["question"]?.string, selectedEvidenceIDs: evidence.map(\.id), selectedEvidence: evidence,
            promptBytes: prepared?.prompt.utf8.count, systemPromptBytes: prepared?.systemPrompt.utf8.count,
            providerQuestionCharacters: payload?["question"]?.string?.count,
            evidenceCharacters: evidence.reduce(0) { $0 + $1.text.count }, selectedEvidenceCount: evidence.count,
            promptWithinBudget: prepared == nil ? nil : withinBudget,
            followupHistoryBounded: prepared == nil ? nil : boundedHistory, finalAnswer: text,
            citedEvidenceIDs: cited, citationCount: cited.count, citationsValid: citationsValid,
            evidenceCorrect: evidenceCorrect, answerCorrect: answerCorrect,
            clarificationQuality: mustClarify ? (clarified ? "clarified" : "missing") : nil,
            focusAfter: contextName(after), revisionAfter: after?.revision, exerciseAfter: after?.exercise,
            expectedOutcome: expected, observedOutcome: outcome?.kind ?? (local ? "local" : "general answer"), failures: turnFailures,
            foregroundSeconds: elapsed, backgroundProviderRequests: backgroundRequests))
        try outputHandle.synchronize()
    }

    private func resetConversation(_ rig: Rig) {
        rig.assistant.endDocumentConversation()
        rig.controller.coordinator.forget()
        rig.controller.presentation.sources = []
    }

    private func runNormalContinuity(rig: Rig, name: String) async throws {
        resetConversation(rig)
        let doc = "ParserGuide.md"
        let evidence = "preserve both the backslash and the following character"
        let answer = ["name\\q", "END"]
        try await send("Explain exercise 2 in ParserGuide.", scenario: name, expected: "Explain Exercise 2 with ParserGuide revision 1 facts and citations.", rig: rig,
            expectedDocument: doc, requiredEvidence: evidence, requiredAnswerFragments: answer)
        try await send("How do I start?", scenario: name, expected: "Use the focused exercise; do not invent setup steps absent from the guide.", rig: rig,
            expectedDocument: doc, requiredEvidence: evidence, requiredAnswerFragments: answer, intendedDocumentRoute: true)
        try await send("Why?", scenario: name, expected: "Explain why unknown escape pairs retain the slash and why the pipe splits fields.", rig: rig,
            expectedDocument: doc, requiredEvidence: evidence, requiredAnswerFragments: answer, intendedDocumentRoute: true)
        try await send("Explain that definition more.", scenario: name, expected: "Expand the distant Section 6 definition, grounded in its passage.", rig: rig,
            expectedDocument: doc, requiredEvidence: evidence, requiredAnswerFragments: answer, intendedDocumentRoute: true)
        try await send("Give me an example.", scenario: name, expected: "Provide a derived example consistent with ParserGuide and label it as an example.", rig: rig,
            expectedDocument: doc, requiredEvidence: evidence, requiredAnswerFragments: answer, intendedDocumentRoute: true)
        try await send("What mistake should I avoid?", scenario: name, expected: "Warn against treating unknown escapes as escapes or applying unrelated toy-scanner rules.", rig: rig,
            expectedDocument: doc, requiredEvidence: evidence, requiredAnswerFragments: answer, intendedDocumentRoute: true)
        try await send("Now explain exercise 3.", scenario: name, expected: "Explain Exercise 3 using the retained ParserGuide focus and exact token strings.", rig: rig,
            expectedDocument: doc, requiredEvidence: "doubled backslash becomes one literal backslash", requiredAnswerFragments: ["left\\right", "tail"])
    }

    private func runExplicitDocumentSwitches(rig: Rig, name: String) async throws {
        resetConversation(rig)
        try await send("Explain exercise 2 in ParserGuide.md.", scenario: name, expected: "Start on ParserGuide revision 1.", rig: rig,
            expectedDocument: "ParserGuide.md", requiredEvidence: "preserve both the backslash and the following character", requiredAnswerFragments: ["name\\q", "END"])
        try await send("Explain exercise 2 from ParserAlternative.md.", scenario: name, expected: "Filename explicitly switches focus; Alternative yields one token.", rig: rig,
            expectedDocument: "ParserAlternative.md", requiredEvidence: "splits fields only at semicolons", requiredAnswerFragments: ["one token", "name\\q|END"])
        try await send("How do I start?", scenario: name, expected: "Follow-up remains on ParserAlternative.", rig: rig,
            expectedDocument: "ParserAlternative.md", requiredEvidence: "A backslash has no escape meaning", requiredAnswerFragments: ["one token", "name\\q|END"], intendedDocumentRoute: true)
        try await send("Why?", scenario: name, expected: "Why pipe is ordinary data and no semicolon is present.", rig: rig,
            expectedDocument: "ParserAlternative.md", requiredEvidence: "pipe (`|`) is ordinary data", requiredAnswerFragments: ["one token"], intendedDocumentRoute: true)
        try await send("Explain that definition more.", scenario: name, expected: "Expand Alternative Section 6 without Guide facts.", rig: rig,
            expectedDocument: "ParserAlternative.md", requiredEvidence: "A backslash has no escape meaning", requiredAnswerFragments: ["semicolon", "backslash"], intendedDocumentRoute: true)
        try await send("Give me an example.", scenario: name, expected: "Give a semicolon-based example without borrowing Guide behavior.", rig: rig,
            expectedDocument: "ParserAlternative.md", requiredEvidence: "splits fields only at semicolons", requiredAnswerFragments: ["semicolon"], intendedDocumentRoute: true)
        try await send("What mistake should I avoid?", scenario: name, expected: "Warn not to split ParserAlternative on pipe or apply backslash escapes.", rig: rig,
            expectedDocument: "ParserAlternative.md", requiredEvidence: "A backslash has no escape meaning", requiredAnswerFragments: ["backslash"], intendedDocumentRoute: true)
        try await send("Now explain exercise 3.", scenario: name, expected: "Alternative Exercise 3 splits on semicolon.", rig: rig,
            expectedDocument: "ParserAlternative.md", requiredEvidence: "semicolon separates fields", requiredAnswerFragments: ["left", "right"])
        try await send("Explain exercise 2 in ParserGuide.md.", scenario: name, expected: "Filename explicitly switches back; Guide has two tokens.", rig: rig,
            expectedDocument: "ParserGuide.md", requiredEvidence: "preserve both the backslash and the following character", requiredAnswerFragments: ["name\\q", "END"])
        try await send("Why?", scenario: name, expected: "Guide reasoning, with no Alternative rule leakage.", rig: rig,
            expectedDocument: "ParserGuide.md", requiredEvidence: "preserve both the backslash and the following character", requiredAnswerFragments: ["name\\q", "END"], intendedDocumentRoute: true)
        try await send("Explain exercise 2 in ParserRevision.md.", scenario: name, expected: "Revision 2 changes only the escape rule: nameq and END.", rig: rig,
            expectedDocument: "ParserRevision.md", requiredEvidence: "backslash escapes the next character", requiredAnswerFragments: ["nameq", "END"])
        try await send("What does that mean here?", scenario: name, expected: "Keep ParserRevision focus and explain its revised rule.", rig: rig,
            expectedDocument: "ParserRevision.md", requiredEvidence: "backslash escapes the next character", requiredAnswerFragments: ["nameq", "END"], intendedDocumentRoute: true)
    }

    private func runAmbiguity(rig: Rig) async throws {
        resetConversation(rig)
        try clearDocumentFocus(in: rig.databaseURL)
        try await send("How do I start?", scenario: "ambiguity", expected: "Without prior context, ask which file to use.", rig: rig,
            mustClarify: true, intendedDocumentRoute: true)
        try await send("Explain exercise 2.", scenario: "ambiguity", expected: "Two or more files contain Exercise 2; ask which one.", rig: rig,
            mustClarify: true, intendedDocumentRoute: true)
        try await send("the other one", scenario: "ambiguity", expected: "Resolve only if a unique alternative is established; otherwise ask a specific clarification.", rig: rig,
            mustClarify: true)
    }

    private func runNaturalPhrasing(rig: Rig) async throws {
        resetConversation(rig)
        try await send("Explain exercise 2 in ParserGuide.md.", scenario: "natural_phrasing", expected: "Establish Guide Exercise 2 context.", rig: rig,
            expectedDocument: "ParserGuide.md", requiredEvidence: "preserve both the backslash and the following character", requiredAnswerFragments: ["name\\q", "END"])
        for (message, expected) in [
            ("walk me through it", "Walk through the focused exercise."),
            ("what does that mean here?", "Explain the referenced rule in this document."),
            ("which rule are you using?", "Name the rule from the focused document."),
            ("does that apply to the next question?", "Clarify whether the same rule applies to the next exercise."),
            ("No, I meant question 3.", "Treat this as a correction to Question 3 and use the same file when established.")
        ] {
            let required = message == "No, I meant question 3." ? ["left\\right", "tail"] : ["name\\q", "END"]
            let evidence = message == "No, I meant question 3." ? "Question 3 asks for the same escaped-backslash example" : "preserve both the backslash and the following character"
            try await send(message, scenario: "natural_phrasing", expected: expected, rig: rig,
                expectedDocument: "ParserGuide.md", requiredEvidence: evidence, requiredAnswerFragments: required,
                intendedDocumentRoute: true)
        }
    }

    private func runContextBoundaries(rig: Rig) async throws {
        resetConversation(rig)
        try await send("Explain exercise 2 in ParserGuide.md.", scenario: "context_boundaries", expected: "Establish Guide evidence before boundary changes.", rig: rig,
            expectedDocument: "ParserGuide.md", requiredEvidence: "preserve both the backslash and the following character", requiredAnswerFragments: ["name\\q", "END"])
        try await send("Tell me a joke about a cactus.", scenario: "context_boundaries", expected: "Unrelated conversation must leave document context inactive.", rig: rig,
            intendedDocumentRoute: false)
        try await send("Start a 1-minute timer.", scenario: "context_boundaries", expected: "Timer command routes locally and preserves retained document context.", rig: rig,
            intendedDocumentRoute: false)
        try await send("Why?", scenario: "context_boundaries", expected: "After unrelated chat and timer, clarify which topic to resume.", rig: rig,
            mustClarify: true, intendedDocumentRoute: true)

        let priorSession = rig.state.activeSessionID
        _ = rig.state.createSession(title: "Synthetic empty session")
        try await send("Explain exercise 2.", scenario: "context_boundaries", expected: "New empty session must not access the previous session's documents.", rig: rig)
        XCTAssertNotEqual(rig.state.activeSessionID, priorSession)

        let newSession = rig.state.activeSessionID
        let session = KnowledgeSession(id: newSession, title: "Synthetic replacement session")
        let guideURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/document-followups/fixtures/ParserGuide.md")
        _ = try await rig.state.knowledge.saveUploadedDocument(session, url: guideURL,
            text: "ParserGuide Revision 2. This replacement is synthetic and has Exercise 2 with a different rule. Exercise 2: Replacement fact is TOKEN_REPLACED_918.")
        try await restoreSessionMemory(rig.state, sessionID: newSession)
        let replacement = rig.state.knowledge.items.first { $0.title == "ParserGuide.md" && $0.sourceKey.hasPrefix("session-file:\(newSession):") }
        if let replacement {
            try await send("Explain exercise 2 in ParserGuide.md.", scenario: "context_boundaries", expected: "Use the replacement document revision in this session.", rig: rig,
                expectedDocument: "ParserGuide.md", requiredEvidence: "TOKEN_REPLACED_918", requiredAnswerFragments: ["TOKEN_REPLACED_918"])
            let beforeRevision = rig.assistant.documentFollowupContext?.revision
            _ = try await rig.state.knowledge.saveUploadedDocument(session, url: guideURL,
                text: "ParserGuide Revision 3. Replacement rule changed again. Exercise 2: New fact is TOKEN_REPLACED_919.")
            try await restoreSessionMemory(rig.state, sessionID: newSession)
            let afterItem = rig.state.knowledge.items.first { $0.id == replacement.id }
            XCTAssertNotEqual(beforeRevision, afterItem?.revision)
            XCTAssertNil(rig.assistant.documentFollowupContext, "A replacement revision must invalidate old evidence.")
            try await send("Why?", scenario: "context_boundaries", expected: "After replacement, ask for a new target and do not reuse old evidence.", rig: rig,
                mustClarify: true, intendedDocumentRoute: true)
        }

        resetConversation(rig)
        let activeDocs = activeDocuments(rig)
        if !activeDocs.isEmpty {
            try await send("Explain exercise 2 in ParserGuide.md.", scenario: "context_boundaries", expected: "Establish fresh context before clearing conversation.", rig: rig,
                expectedDocument: "ParserGuide.md", requiredEvidence: "TOKEN_REPLACED_919", requiredAnswerFragments: ["TOKEN_REPLACED_919"])
            try await send("/forget", scenario: "context_boundaries", expected: "Clear conversational follow-up context.", rig: rig,
                intendedDocumentRoute: false)
            try await send("Why?", scenario: "context_boundaries", expected: "After clear, ask for a document rather than reuse old evidence.", rig: rig,
                mustClarify: true, intendedDocumentRoute: true)
        }
        _ = rig.state.selectSession(id: rig.sessionID)
        resetConversation(rig)
    }

    private func runLongConversation(rig: Rig) async throws {
        resetConversation(rig)
        let name = "long_conversation_25_turns"
        try await send("Explain exercise 2 in ParserGuide.md.", scenario: name, expected: "Start one 25-turn conversation on Guide Exercise 2.", rig: rig,
            expectedDocument: "ParserGuide.md", requiredEvidence: "preserve both the backslash and the following character", requiredAnswerFragments: ["name\\q", "END"])
        var followups = [
            "Why?", "How do I start?", "What does that mean here?", "Explain more?", "Show me the steps.",
            "Summarize that section.", "How do I solve it?", "What steps are used here?", "Explain the steps.",
            "Why does the pipe split it?", "What does that mean here?", "Show me the steps.", "How do I start?",
            "Summarize that section.", "Explain more?", "What steps are used here?", "Why?", "How do I solve it?", "Explain the steps."
        ]
        followups += ["Walk me through it.", "What does that mean here?", "Does that apply to the next question?",
            "Give me an example.", "Explain the steps.", "Walk me through it again."]
        for message in followups {
            try await send(message, scenario: name, expected: "Follow-up remains grounded in the original Exercise 2; provider question contains only original plus current turn.", rig: rig,
                expectedDocument: "ParserGuide.md", requiredEvidence: "preserve both the backslash and the following character", requiredAnswerFragments: ["name\\q", "END"],
                intendedDocumentRoute: true)
        }
    }

    private func runCancellationRecovery(rig: Rig) async throws {
        resetConversation(rig)
        try await send("Explain exercise 2 in ParserGuide.md.", scenario: "failure_recovery", expected: "Successful answer establishes the preserved follow-up context.", rig: rig,
            expectedDocument: "ParserGuide.md", requiredEvidence: "preserve both the backslash and the following character", requiredAnswerFragments: ["name\\q", "END"])
        try await send("How do I start?", scenario: "failure_recovery", expected: "Cancel after dispatch; unsuccessful request must retain the last successful context.", rig: rig,
            expectedDocument: "ParserGuide.md", intendedDocumentRoute: true, cancelAfterMilliseconds: 40, preserveContextOnCancel: true)
        try await send("How do I start?", scenario: "failure_recovery", expected: "Retry the same follow-up using the retained original question and evidence.", rig: rig,
            expectedDocument: "ParserGuide.md", requiredEvidence: "preserve both the backslash and the following character", requiredAnswerFragments: ["name\\q", "END"],
            intendedDocumentRoute: true)
    }

    private func recordLinkExpansionAblation(rig: Rig) async throws {
        let question = "Explain exercise 2 in ParserGuide.md."
        let enabled = try await DocumentRetrievalService(library: rig.state.knowledge).retrieve(.init(sessionID: rig.sessionID, question: question))
        let enabledEvidence = enabled.evidence.map { EvidenceRecord(id: $0.id.uuidString, document: $0.filename, location: $0.location, text: $0.text) }
        let required = "preserve both the backslash and the following character"
        let guide = try XCTUnwrap(rig.state.knowledge.items.first { $0.title == "ParserGuide.md" })
        let links = try await rig.state.knowledge.store.documentPassageLinks(documentID: guide.id, revision: guide.revision)
        let unresolvedLinks = links.filter { $0.sourceText.localizedCaseInsensitiveContains("Section 99") }.count
        let duplicateHeadingLinks = links.filter { $0.kind == "heading-title" && $0.sourceText.localizedCaseInsensitiveContains("Examples") }.count
        try append(AblationRecord(query: question, mode: "enabled", selectedEvidenceIDs: enabled.evidence.map { $0.id.uuidString },
            evidence: enabledEvidence, containsRequiredDistantRule: enabled.evidence.contains { $0.text.localizedCaseInsensitiveContains(required) },
            unresolvedSection99Links: unresolvedLinks, duplicateExamplesHeadingLinks: duplicateHeadingLinks))
        try deletePassageLinks(in: rig.databaseURL)
        let disabled = try await DocumentRetrievalService(library: rig.state.knowledge).retrieve(.init(sessionID: rig.sessionID, question: question))
        let disabledEvidence = disabled.evidence.map { EvidenceRecord(id: $0.id.uuidString, document: $0.filename, location: $0.location, text: $0.text) }
        try append(AblationRecord(query: question, mode: "disabled", selectedEvidenceIDs: disabled.evidence.map { $0.id.uuidString },
            evidence: disabledEvidence, containsRequiredDistantRule: disabled.evidence.contains { $0.text.localizedCaseInsensitiveContains(required) },
            unresolvedSection99Links: unresolvedLinks, duplicateExamplesHeadingLinks: duplicateHeadingLinks))
        if !enabled.evidence.contains(where: { $0.text.localizedCaseInsensitiveContains(required) }) {
            failures.append("Ablation: link expansion enabled did not retrieve the required distant rule.")
        }
        // Exact-exercise retrieval independently resolves mandatory support. Equal evidence
        // makes this ablation inconclusive; it is not a quality failure.

        if unresolvedLinks != 0 { failures.append("Passage links unexpectedly resolved missing Section 99.") }
        if duplicateHeadingLinks != 0 { failures.append("Passage links unexpectedly resolved duplicate Examples headings.") }
    }

    private func clearDocumentFocus(in url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw KnowledgeError.database("Could not open synthetic evaluation database.") }
        defer { sqlite3_close(db) }
        let result = sqlite3_exec(db, "DELETE FROM document_focus", nil, nil, nil)
        guard result == SQLITE_OK else { throw KnowledgeError.database("Could not clear synthetic focus state.") }
    }

    private func deletePassageLinks(in url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw KnowledgeError.database("Could not open synthetic evaluation database.") }
        defer { sqlite3_close(db) }
        let result = sqlite3_exec(db, "DELETE FROM document_passage_links; DELETE FROM document_link_indexes", nil, nil, nil)
        guard result == SQLITE_OK else { throw KnowledgeError.database("Could not disable synthetic passage links.") }
    }
}
