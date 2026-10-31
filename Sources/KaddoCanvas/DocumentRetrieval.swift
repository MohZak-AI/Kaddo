import CryptoKit
import Foundation

/// Identities are reproducible across imports, index rebuilds and app restarts.
enum DocumentIdentity {
    static func id(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct DocumentFocus: Codable, Equatable, Sendable {
    let documentID: UUID
    let revision: Int
    var exercise: String?
}

enum DocumentQueryIntent: Sendable { case overview, exercise, search }
enum DocumentCoverage: Sendable { case complete, partial, missing }
public enum DocumentEvidenceRole: Equatable, Sendable {
    case primary
    case explicitReference
    case semanticSupport(seedChunkID: UUID, similarity: Double)
}
struct DocumentRetrievalRequest: Sendable {
    let sessionID: UUID
    let question: String
    var characterBudget = 12_000
    var preferredDocumentID: UUID? = nil
    var preferredRevision: Int? = nil
    var preferredExercise: String? = nil
    var allowsSavedFocus = false
    var contextChunkIDs: [UUID] = []
}
struct DocumentRetrievalResult: Sendable {
    let intent: DocumentQueryIntent
    let focus: DocumentFocus?
    let evidence: [DocumentChunk]
    let coverage: DocumentCoverage
    let limitations: [String]
    var documentCoverage: [String: DocumentCoverage] = [:]
    var evidenceRoles: [UUID: DocumentEvidenceRole] = [:]
    var requiredSupportIDs: Set<UUID> = []
    var matches: [NoteMatch] { evidence.map { NoteMatch(chunk: $0, score: 1) } }
}

enum DocumentRetrievalError: LocalizedError {
    case chooseDocument([String]), missingExercise(String, String), missingReference(String, String, String)
    case resumeDiscussion(String)
    case noSessionDocuments, unavailableDocument, noEvidence(String), missingFollowupContext, missingRequiredSupport
    var errorDescription: String? {
        switch self {
        case .resumeDiscussion(let message): message
        case .chooseDocument(let names): "Which document do you mean: " + names.joined(separator: ", ") + "?"
        case .missingExercise(let number, let name): "I couldn’t find exercise \(number) in \(name). Which exercise or heading do you mean?"
        case .missingReference(let kind, let number, let name): "I couldn’t find \(kind) \(number) in \(name). Which section or heading do you mean?"
        case .noEvidence(let name): "I couldn’t find a relevant passage in \(name). Which section or phrase should I look for?"
        case .missingFollowupContext: "Which document or section are you referring to? Ask about a document first, or name the section you mean."
        case .noSessionDocuments: "This session has no uploaded documents. Upload a document here to ask about it."
        case .unavailableDocument: "That document isn’t in this session. Name the document and ask to search other sessions if you want me to look there."
        case .missingRequiredSupport: "I couldn’t include the linked rule passage needed for an exact answer. Which section or document should I use?"
        }
    }
}

/// Retrieval-only structure. Original saved content and planner provenance are never rewritten.
enum StructuredDocumentChunker {
    static let version = 3

    struct PassageHeading {
        let kind: String
        let identifier: String?
        let title: String
        let normalizedTitle: String
    }

    static func normalizeHeadingTitle(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    static func passageHeading(_ line: String) -> PassageHeading? {
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let isMarkdown = value.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil
        let isBold = value.range(of: #"^\s*(?:\*\*.+\*\*|__.+__)\s*$"#, options: .regularExpression) != nil
        value = value.replacingOccurrences(of: #"^#{1,6}\s*|\*\*|__|`"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let occurrence = DocumentQuestionReference.occurrences(in: value, includeNumberedHeading: true)
            .first(where: { $0.range.lowerBound == value.startIndex && AssignmentContextSearch.isHeadingOccurrence($0, in: value) }) {
            let parsedTitle = String(value[occurrence.range.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " :.)—–-\t"))
            let title = parsedTitle.isEmpty ? value : parsedTitle
            let isBareNumbered = occurrence.reference.kind == "question"
                && value.range(of: #"^\(?[0-9٠-٩۰-۹]{1,3}[.)]\s+"#, options: .regularExpression) != nil
            return PassageHeading(kind: isBareNumbered ? "numbered" : occurrence.reference.kind,
                identifier: occurrence.reference.number,
                title: title, normalizedTitle: normalizeHeadingTitle(title))
        }

        let numberedPattern = #"^([0-9]+(?:\.[0-9]+)*)[.)]?\s+(.+)$"#
        if let captures = firstMatchCaptures(numberedPattern, in: value),
           captures.count == 2, let identifier = captures[0], let title = captures[1] {
            return PassageHeading(kind: "numbered", identifier: identifier, title: title,
                normalizedTitle: normalizeHeadingTitle(title))
        }

        guard isMarkdown || isBold else { return nil }
        return PassageHeading(kind: "title", identifier: nil, title: value,
            normalizedTitle: normalizeHeadingTitle(value))
    }

    static func chunks(_ text: String) throws -> [String] {
        var result: [String] = []
        var buffer = ""
        func flush() { if !buffer.isEmpty { result.append(buffer); buffer = "" } }
        for line in text.components(separatedBy: .newlines) {
            try Task.checkCancellation()
            for part in inlineHeadingParts(in: line) {
                let value = part.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else {
                    if !buffer.isEmpty, !buffer.hasSuffix("\n\n") { buffer += "\n" }
                    continue
                }
                if isStructuralHeading(value) || value.hasPrefix("[Page ") || value.hasPrefix("[Image ") { flush() }
                var rest = part[...]
                var charactersLeft = part.count
                while !rest.isEmpty {
                    if !buffer.isEmpty, buffer.count + charactersLeft + 1 > 1_600 { flush() }
                    let room = 1_600 - buffer.count - (buffer.isEmpty ? 0 : 1)
                    let piece = String(rest.prefix(room))
                    if !buffer.isEmpty { buffer += "\n" }
                    buffer += piece
                    rest.removeFirst(piece.count)
                    charactersLeft -= piece.count
                    if buffer.count >= 1_200 { flush() }
                }
                guard result.count <= KnowledgeStore.maximumChunks else { throw DocumentImportError.documentTooLarge }
            }
            guard result.count <= KnowledgeStore.maximumChunks else { throw DocumentImportError.documentTooLarge }
        }
        flush()
        guard result.count <= KnowledgeStore.maximumChunks else { throw DocumentImportError.documentTooLarge }
        return result
    }
    private static func inlineHeadingParts(in line: String) -> [String] {
        let starts = Array(Set(AssignmentContextSearch.inlineHeadingStarts(in: line))).sorted()
        guard !starts.isEmpty else { return [line] }
        var parts: [String] = []
        var start = line.startIndex
        for end in starts {
            parts.append(String(line[start..<end]))
            start = end
        }
        parts.append(String(line[start...]))
        return parts
    }
    static func heading(_ line: String) -> DocumentQuestionReference? {
        guard let heading = passageHeading(line), ["exercise", "question", "problem", "section", "chapter", "part", "numbered"].contains(heading.kind),
              let identifier = heading.identifier else { return nil }
        return DocumentQuestionReference(number: identifier, kind: heading.kind == "numbered" ? "question" : heading.kind)
    }
    static func isStructuralHeading(_ line: String) -> Bool {
        passageHeading(line) != nil
    }

    private static func firstMatchCaptures(_ pattern: String, in text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }
    static func location(_ text: String, previous: String? = nil) -> String? {
        let lines = text.components(separatedBy: .newlines)
        if let marker = lines.first(where: { $0.hasPrefix("[Image ") || $0.hasPrefix("[Page ") }) {
            return marker
        }
        if let reference = lines.compactMap({ heading($0) }).first { return "\(reference.kind.capitalized) \(reference.number)" }
        return previous
    }
}

/// All candidate selection, ranking and evidence assembly happens on this Mac.
@MainActor
final class DocumentRetrievalService {
    private let library: KnowledgeLibrary
    init(library: KnowledgeLibrary) { self.library = library }

    nonisolated static func isOverview(_ question: String) -> Bool {
        question.range(of: #"summari[sz]e|summary|overview|requirements?|deliverables?|what.*(?:should|need|have to|supposed to).*do|what.*(?:assignment|lab).*about|ما المطلوب|لخص|لخّص"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
    }
    nonisolated static func allowsOtherSessions(_ question: String) -> Bool {
        question.range(of: #"(?:other|all|across)\s+(?:my\s+)?sessions|all (?:my )?(?:documents|uploads)|other chats"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    nonisolated static func explicitlyRequestsMultipleDocuments(_ question: String) -> Bool {
        question.range(of: #"\b(?:compare|contrast)\b|\b(?:all|across|between|each of|both)\b.*\b(?:documents?|files?|assignments?|uploads?)\b|\b(?:documents?|files?|assignments?|uploads?)\b.*\b(?:across|between)\b"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    func retrieve(_ request: DocumentRetrievalRequest) async throws -> DocumentRetrievalResult {
        let question = request.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 2_000 else { throw LocalInferenceError.invalidQuery }
        let snapshot = Dictionary(uniqueKeysWithValues: library.items.filter { $0.sourceKind == "session-document" }.map { ($0.id, $0.revision) })
        let all = library.items.filter { $0.sourceKind == "session-document" }
        let documents = all.filter { Self.allowsOtherSessions(question) || $0.sourceKey.hasPrefix("session-file:\(request.sessionID):") }
        guard !documents.isEmpty else { throw DocumentRetrievalError.noSessionDocuments }
        let named = documents.filter { item in
            let stem = URL(fileURLWithPath: item.title).deletingPathExtension().lastPathComponent
            return Self.explicitlyNames(question, title: item.title, stem: stem)
        }
        if named.isEmpty, all.contains(where: { item in
            !documents.contains(where: { $0.id == item.id }) && question.localizedCaseInsensitiveContains(item.title)
        }) { throw DocumentRetrievalError.unavailableDocument }
        let saved = try await library.store.documentFocus(sessionID: request.sessionID)
        let followup = DocumentQuestionRouter.isFollowup(question)
        let persistedFocusIsAvailable = request.allowsSavedFocus && saved.map { focus in
            documents.contains(where: { $0.id == focus.documentID })
        } == true
        let unscopedExerciseWithoutFocus = !request.allowsSavedFocus
            && DocumentQuestionReference.first(in: question) != nil
        let hasReference = DocumentQuestionReference.first(in: question) != nil
        let explicitlyAcrossDocuments = Self.explicitlyRequestsMultipleDocuments(question)
            || Self.allowsOtherSessions(question)
        if named.isEmpty, request.preferredDocumentID == nil,
           unscopedExerciseWithoutFocus
            || (!followup && (explicitlyAcrossDocuments || !hasReference || !persistedFocusIsAvailable)) {
            return try await retrieveAcrossSessionDocuments(request, documents: documents,
                overview: Self.isOverview(question))
        }
        let item: KnowledgeItem
        if named.count == 1 { item = named[0] }
        else if named.count > 1 { throw DocumentRetrievalError.chooseDocument(named.map(\.title)) }
        else if let preferred = request.preferredDocumentID,
                let focused = documents.first(where: { $0.id == preferred }) { item = focused }
        else if request.preferredDocumentID != nil { throw DocumentRetrievalError.missingFollowupContext }
        else if request.allowsSavedFocus, let saved,
                let focused = documents.first(where: { $0.id == saved.documentID }) { item = focused }
        else if followup { throw DocumentRetrievalError.missingFollowupContext }
        else {
            // Upload order, independent of category moves and planner updates.
            let newest = try await library.store.latestDocument(in: Set(documents.map(\.id)))
            if let newest, let latest = documents.first(where: { $0.id == newest }) { item = latest }
            else if documents.count == 1 { item = documents[0] }
            else { throw DocumentRetrievalError.chooseDocument(documents.map(\.title).sorted()) }
        }
        if let preferred = request.preferredDocumentID, item.id == preferred,
           let expectedRevision = request.preferredRevision, item.revision != expectedRevision {
            throw DocumentRetrievalError.missingFollowupContext
        }
        let chunks = try await library.store.documentChunks(itemID: item.id)
        let reference = DocumentQuestionReference.first(in: question)
        let overview = Self.isOverview(question)
        let retainedExercise = named.isEmpty && request.preferredDocumentID == item.id
            ? request.preferredExercise
            : (named.isEmpty && saved?.documentID == item.id && saved?.revision == item.revision && followup
                ? saved?.exercise : nil)
        let exercise = reference.map { "\($0.kind) \($0.number)" } ?? (overview ? nil : retainedExercise)
        var candidates: [DocumentChunk]
        let intent: DocumentQueryIntent
        if let exercise, let target = DocumentQuestionReference.first(in: exercise) {
            intent = ["exercise", "question", "problem"].contains(target.kind) ? .exercise : .search
            candidates = AssignmentContextSearch.section(for: target, in: chunks)
            guard !candidates.isEmpty else {
                if ["exercise", "question", "problem"].contains(target.kind) {
                    throw DocumentRetrievalError.missingExercise(target.number, item.title)
                }
                throw DocumentRetrievalError.missingReference(target.kind, target.number, item.title)
            }
            if candidates.contains(where: { $0.text.range(of: "starter|diagram|above|previous|refactor", options: [.regularExpression, .caseInsensitive]) != nil }),
               let firstExercise = chunks.firstIndex(where: { chunk in
                   chunk.text.components(separatedBy: .newlines).contains { StructuredDocumentChunker.heading($0)?.kind == "exercise" }
               }) {
                let shared = chunks.prefix(firstExercise).filter {
                    $0.text.contains("[Image ") || $0.text.range(of: "class |givens?|formula", options: [.regularExpression, .caseInsensitive]) != nil
                }.suffix(2)
                candidates = Array(shared) + candidates
            }
        } else if overview {
            intent = .overview; candidates = chunks
        } else {
            intent = .search
            let hits = await library.search(query: question, documentIDs: [item.id], maximumResults: 24, characterBudget: 38_400)
            try Task.checkCancellation()
            let positions = hits.compactMap { hit in chunks.firstIndex(where: { $0.id == hit.id }) }
            var expanded = Set<Int>()
            var ranked: [DocumentChunk] = []
            for position in positions {
                // Rank whole surrounding sections before weaker hits; deduplicate overlapping windows.
                var lower = position, upper = position
                while lower > 0, position - lower < 3, chunks[lower - 1].location == chunks[position].location { lower -= 1 }
                while upper + 1 < chunks.count, upper - position < 3, chunks[upper + 1].location == chunks[position].location { upper += 1 }
                for index in max(0, lower - 1)...min(chunks.count - 1, upper + 1) where expanded.insert(index).inserted {
                    ranked.append(chunks[index])
                }
            }
            candidates = ranked
            // One local widening pass for a weak fragment; never change the selected document.
            if candidates.reduce(0, { $0 + $1.text.count }) < 400, !candidates.isEmpty { candidates = chunks }
        }
        let requiredSupport = try requiredLinkedSupport(for: exercise == nil ? [] : candidates,
            question: question, allChunks: chunks, filename: item.title)
        var prioritized = candidates
        var seenEvidence = Set(prioritized.map(\.id))
        let retained = overview ? [] : request.contextChunkIDs.compactMap { id in
            chunks.first(where: { $0.id == id && $0.documentID == item.id })
        }
        for chunk in retained where seenEvidence.insert(chunk.id).inserted { prioritized.append(chunk) }
        let linkedTargets = overview ? [] : try await library.store.linkedDocumentChunks(documentID: item.id, revision: item.revision,
            sourceChunkIDs: prioritized.map(\.id), maximumResults: 8)
        let linked = Self.expandLinkedSections(linkedTargets + requiredSupport.chunks, in: chunks)
        for chunk in linked where seenEvidence.insert(chunk.id).inserted { prioritized.append(chunk) }
        let localEvidence = Self.assemble(prioritized, budget: request.characterBudget, overview: overview, preserveOrder: true)
        let semantic = overview ? [] : await semanticSupport(primary: candidates + retained, linked: linked,
            documentIDs: Set(documents.map(\.id)), alreadyIncluded: prioritized,
            characterBudget: max(0, request.characterBudget - localEvidence.reduce(0) { $0 + $1.text.count }),
            blockBudget: max(0, 48 - localEvidence.count))
        for match in semantic where seenEvidence.insert(match.chunk.id).inserted { prioritized.append(match.chunk) }
        try Task.checkCancellation()
        guard (localEvidence + semantic.map(\.chunk)).allSatisfy({ chunk in library.items.contains { $0.id == chunk.documentID && $0.revision == snapshot[chunk.documentID] } }) else { throw CancellationError() }
        let assembled = Self.assemble(prioritized, budget: request.characterBudget, overview: overview,
            preserveOrder: !linked.isEmpty || !retained.isEmpty || !semantic.isEmpty)
        let roles = Self.evidenceRoles(assembled, primary: candidates + retained, linked: linked, semantic: semantic)
        var limitations: [String] = []
        let complete = linked.isEmpty && retained.isEmpty && semantic.isEmpty
            && assembled.reduce(0, { $0 + $1.text.count }) >= prioritized.reduce(0, { $0 + $1.text.count })
        if let note = chunks.flatMap({ $0.text.components(separatedBy: .newlines) }).first(where: { $0.hasPrefix("[Extraction note:") }) {
            limitations.append(note)
        }
        if !complete { limitations.append("Only part of the document context fits; identify the section needed for more detail.") }
        if !semantic.isEmpty { limitations.append("Semantically related passages provide background and do not establish this assignment’s requirements.") }
        if assembled.contains(where: { $0.text.contains("[Image ") || $0.text.contains("[Page ") && $0.text.contains("OCR") }) {
            limitations.append("Image text was read locally using OCR. Text recognition cannot establish every diagram relationship; do not infer unreadable labels or arrows.")
        }
        let focus = DocumentFocus(documentID: item.id, revision: item.revision, exercise: exercise)
        var documentCoverage: [String: DocumentCoverage] = [:]
        for document in documents where assembled.contains(where: { $0.documentID == document.id }) {
            documentCoverage[document.title] = document.id == item.id
                ? (complete ? .complete : .partial) : .partial
        }
        return DocumentRetrievalResult(intent: intent, focus: focus, evidence: assembled,
            coverage: assembled.isEmpty ? .missing : complete ? .complete : .partial, limitations: limitations,
            documentCoverage: documentCoverage, evidenceRoles: roles,
            requiredSupportIDs: requiredSupport.citationIDs)
    }

    private func requiredLinkedSupport(for exerciseChunks: [DocumentChunk], question: String,
                                       allChunks: [DocumentChunk], filename: String)
        throws -> (chunks: [DocumentChunk], citationIDs: Set<UUID>) {
        guard !exerciseChunks.isEmpty,
              Self.requiresExactAnswer(question, exerciseText: exerciseChunks.map(\.text).joined(separator: "\n")) else {
            return ([], [])
        }
        var seen = Set<String>()
        var references: [DocumentQuestionReference] = []
        for chunk in exerciseChunks {
            for occurrence in DocumentQuestionReference.occurrences(in: chunk.text)
            where ["section", "chapter", "part"].contains(occurrence.reference.kind) {
                let key = "\(occurrence.reference.kind):\(occurrence.reference.number)"
                if seen.insert(key).inserted { references.append(occurrence.reference) }
            }
        }
        var targets: [DocumentChunk] = []
        for reference in references {
            let matches = AssignmentContextSearch.sections(for: reference, in: allChunks)
            guard matches.count == 1, let target = matches.first else {
                throw DocumentRetrievalError.missingReference(reference.kind, reference.number, filename)
            }
            targets.append(contentsOf: target)
        }
        // Exact linked-rule answers must cite the exercise wording and every chunk
        // carrying the uniquely resolved rule passage.
        return (targets, Set(exerciseChunks.map(\.id)).union(targets.map(\.id)))
    }

    nonisolated private static func requiresExactAnswer(_ question: String, exerciseText: String) -> Bool {
        let exactTerms = #"\b(?:exact(?:ly)?|token(?:s)?|output|result|value(?:s)?|conclusion|yield(?:s|ed)?)\b"#
        return question.range(of: exactTerms, options: [.regularExpression, .caseInsensitive]) != nil
            || exerciseText.range(of: exactTerms, options: [.regularExpression, .caseInsensitive]) != nil
    }

    nonisolated private static func explicitlyNames(_ question: String, title: String, stem: String) -> Bool {
        if question.localizedCaseInsensitiveContains(title) { return true }
        guard stem.count >= 3 else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: stem)
        let pattern = #"(?:\bin|\bfrom|\bfile|\bdocument|"|')\s*[“”"']?"# + escaped + #"\b[”"']?"#
        return question.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func retrieveAcrossSessionDocuments(_ request: DocumentRetrievalRequest, documents: [KnowledgeItem],
                                                overview: Bool) async throws -> DocumentRetrievalResult {
        let reference = DocumentQuestionReference.first(in: request.question)
        var perDocument: [(KnowledgeItem, [DocumentChunk])] = []
        var requiredSupportChunks: [DocumentChunk] = []
        var requiredCitationIDs = Set<UUID>()
        if reference == nil, !overview {
            let hits = await library.search(query: request.question, documentIDs: Set(documents.map(\.id)),
                maximumResults: 48, characterBudget: max(request.characterBudget * 3, 19_200))
            let itemsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
            var grouped: [UUID: [DocumentChunk]] = [:]
            var rankedEvidence: [DocumentChunk] = []
            for (rank, hit) in hits.enumerated() {
                guard let item = itemsByID[hit.itemID] else { continue }
                let chunk = DocumentChunk(id: hit.id, documentID: hit.itemID, filename: item.title, index: rank,
                    text: hit.text, sourceURL: hit.sourceURL, location: StructuredDocumentChunker.location(hit.text))
                grouped[hit.itemID, default: []].append(chunk)
                rankedEvidence.append(chunk)
            }
            perDocument = documents.compactMap { item in grouped[item.id].map { (item, $0) } }
            if perDocument.count > 1,
               !Self.explicitlyRequestsMultipleDocuments(request.question),
               !Self.allowsOtherSessions(request.question) {
                throw DocumentRetrievalError.chooseDocument(perDocument.map { $0.0.title }.sorted())
            }
            let linked = try await linkedSupport(for: perDocument)
            let localEvidence = Self.assemble(rankedEvidence + linked.chunks, budget: request.characterBudget,
                overview: false, preserveOrder: true)
            let semantic = await semanticSupport(primary: rankedEvidence, linked: linked.chunks,
                documentIDs: Set(documents.map(\.id)), alreadyIncluded: rankedEvidence + linked.chunks,
                characterBudget: max(0, request.characterBudget - localEvidence.reduce(0) { $0 + $1.text.count }),
                blockBudget: max(0, 48 - localEvidence.count))
            let selected = Self.assemble(rankedEvidence + linked.chunks + semantic.map(\.chunk), budget: request.characterBudget,
                overview: false, preserveOrder: !linked.chunks.isEmpty || !semantic.isEmpty)
            let roles = Self.evidenceRoles(selected, primary: rankedEvidence, linked: linked.chunks, semantic: semantic)
            var coverage: [String: DocumentCoverage] = [:]
            for item in documents where selected.contains(where: { $0.documentID == item.id }) {
                coverage[item.title] = .partial
            }
            let focusItem = perDocument.count == 1 ? rankedEvidence.first.flatMap { itemsByID[$0.documentID] } : nil
            let focus = focusItem.map { DocumentFocus(documentID: $0.id, revision: $0.revision, exercise: nil) }
            guard documents.allSatisfy({ item in library.items.contains { $0.id == item.id && $0.revision == item.revision } }) else { throw CancellationError() }
            return DocumentRetrievalResult(intent: .search, focus: focus, evidence: selected,
                coverage: selected.isEmpty ? .missing : .partial,
                limitations: ["Relevant passages are ranked across this session’s documents; ask about a file or section for fuller coverage."] +
                    (semantic.isEmpty ? [] : ["Semantically related passages provide background and do not establish this assignment’s requirements."]),
                documentCoverage: coverage, evidenceRoles: roles)
        }
        for item in documents {
            let chunks = try await library.store.documentChunks(itemID: item.id)
            let selected: [DocumentChunk]
            if let reference {
                selected = AssignmentContextSearch.section(for: reference, in: chunks)
            } else if overview {
                selected = chunks
            } else {
                let hits = await library.search(query: request.question, documentIDs: [item.id], maximumResults: 12, characterBudget: 19_200)
                let ids = Set(hits.map(\.id))
                selected = chunks.filter { ids.contains($0.id) }
            }
            if !selected.isEmpty {
                let support = try requiredLinkedSupport(for: reference == nil ? [] : selected,
                    question: request.question, allChunks: chunks, filename: item.title)
                requiredSupportChunks += support.chunks
                requiredCitationIDs.formUnion(support.citationIDs)
                perDocument.append((item, selected))
            }
        }
        if let reference, perDocument.isEmpty {
            if ["exercise", "question", "problem"].contains(reference.kind) {
                throw DocumentRetrievalError.missingExercise(reference.number, "these session documents")
            }
            throw DocumentRetrievalError.missingReference(reference.kind, reference.number, "these session documents")
        }
        if reference != nil, perDocument.count > 1,
           !Self.explicitlyRequestsMultipleDocuments(request.question),
           !Self.allowsOtherSessions(request.question) {
            throw DocumentRetrievalError.chooseDocument(perDocument.map { $0.0.title }.sorted())
        }
        let linked = overview ? (chunks: [DocumentChunk](), documentIDs: Set<UUID>())
            : try await linkedSupport(for: perDocument)
        var allEvidence: [DocumentChunk] = []
        for (item, chunks) in perDocument {
            for chunk in chunks {
                allEvidence.append(DocumentChunk(id: chunk.id, documentID: chunk.documentID, filename: item.title,
                    index: allEvidence.count, text: chunk.text, sourceURL: chunk.sourceURL, location: chunk.location))
            }
        }
        for chunk in linked.chunks {
            allEvidence.append(DocumentChunk(id: chunk.id, documentID: chunk.documentID, filename: chunk.filename,
                index: allEvidence.count, text: chunk.text, sourceURL: chunk.sourceURL, location: chunk.location))
        }
        allEvidence.append(contentsOf: requiredSupportChunks)
        let primary = perDocument.flatMap(\.1)
        let localEvidence = Self.assemble(allEvidence, budget: request.characterBudget, overview: overview, preserveOrder: true)
        let semantic = overview ? [] : await semanticSupport(primary: primary, linked: linked.chunks + requiredSupportChunks,
            documentIDs: Set(documents.map(\.id)), alreadyIncluded: allEvidence,
            characterBudget: max(0, request.characterBudget - localEvidence.reduce(0) { $0 + $1.text.count }),
            blockBudget: max(0, 48 - localEvidence.count))
        let selected = Self.assemble(allEvidence + semantic.map(\.chunk), budget: request.characterBudget, overview: overview,
            preserveOrder: !linked.chunks.isEmpty || !semantic.isEmpty)
        let roles = Self.evidenceRoles(selected, primary: primary, linked: linked.chunks + requiredSupportChunks, semantic: semantic)
        var coverage: [String: DocumentCoverage] = [:]
        for item in documents where selected.contains(where: { $0.documentID == item.id }) {
            let chunks = perDocument.first(where: { $0.0.id == item.id })?.1 ?? []
            let included = selected.contains { $0.documentID == item.id }
            coverage[item.title] = included && !chunks.isEmpty && !linked.documentIDs.contains(item.id)
                && selected.filter({ $0.documentID == item.id }).reduce(0, { $0 + $1.text.count }) >= chunks.reduce(0, { $0 + $1.text.count })
                ? .complete : included ? .partial : .missing
        }
        let focusItem = perDocument.count == 1 ? perDocument.first?.0 : nil
        let focus = focusItem.map { DocumentFocus(documentID: $0.id, revision: $0.revision,
            exercise: reference.map { "\($0.kind) \($0.number)" }) }
        let limitations = coverage.values.contains(where: { $0 != .complete })
            ? ["Some session documents did not fit in the available context. Ask about a file or section for more detail."] : []
        let finalLimitations = limitations + (semantic.isEmpty ? [] : ["Semantically related passages provide background and do not establish this assignment’s requirements."])
        guard documents.allSatisfy({ item in library.items.contains { $0.id == item.id && $0.revision == item.revision } }) else { throw CancellationError() }
        let referenceIntent: DocumentQueryIntent? = reference.map {
            ["exercise", "question", "problem"].contains($0.kind) ? .exercise : .search
        }
        return DocumentRetrievalResult(intent: referenceIntent ?? (overview ? .overview : .search),
            focus: focus, evidence: selected, coverage: selected.isEmpty ? .missing : coverage.values.allSatisfy({ $0 == .complete }) ? .complete : .partial,
            limitations: finalLimitations, documentCoverage: coverage, evidenceRoles: roles,
            requiredSupportIDs: requiredCitationIDs)
    }

    private func linkedSupport(for groups: [(KnowledgeItem, [DocumentChunk])]) async throws
        -> (chunks: [DocumentChunk], documentIDs: Set<UUID>) {
        var remainingTargets = 8
        var chunks: [DocumentChunk] = []
        var documentIDs = Set<UUID>()
        var seen = Set<UUID>()
        let orderedGroups = groups.sorted {
            ($0.1.map(\.index).min() ?? Int.max) < ($1.1.map(\.index).min() ?? Int.max)
        }
        for (item, seeds) in orderedGroups where remainingTargets > 0 {
            try Task.checkCancellation()
            let targets = try await library.store.linkedDocumentChunks(documentID: item.id, revision: item.revision,
                sourceChunkIDs: seeds.map(\.id), maximumResults: remainingTargets)
            guard !targets.isEmpty else { continue }
            remainingTargets -= targets.count
            documentIDs.insert(item.id)
            let documentChunks = try await library.store.documentChunks(itemID: item.id)
            for chunk in Self.expandLinkedSections(targets, in: documentChunks) where seen.insert(chunk.id).inserted {
                chunks.append(chunk)
            }
        }
        return (chunks, documentIDs)
    }

    private func semanticSupport(primary: [DocumentChunk], linked: [DocumentChunk], documentIDs: Set<UUID>,
                                 alreadyIncluded: [DocumentChunk], characterBudget: Int,
                                 blockBudget: Int) async -> [RelatedDocumentMatch] {
        guard characterBudget > 0, blockBudget > 0, !primary.isEmpty else { return [] }
        var seeds: [UUID] = []
        for chunk in primary.prefix(2) where !seeds.contains(chunk.id) { seeds.append(chunk.id) }
        for chunk in linked.prefix(2) where !seeds.contains(chunk.id) { seeds.append(chunk.id) }
        if seeds.count < 4 {
            for chunk in primary.dropFirst(min(2, primary.count)) where !seeds.contains(chunk.id) {
                seeds.append(chunk.id)
                if seeds.count == 4 { break }
            }
        }
        let excludedIDs = Set(alreadyIncluded.map(\.id))
        let excludedText = Set(alreadyIncluded.map { Self.normalizedEvidenceText($0.text) })
        let matches = await library.relatedDocumentChunks(seedChunkIDs: seeds, documentIDs: documentIDs,
            excludedChunkIDs: excludedIDs, maximumResults: min(4, blockBudget), characterBudget: min(3_200, characterBudget))
        var seenText = excludedText
        return matches.filter { seenText.insert(Self.normalizedEvidenceText($0.chunk.text)).inserted }
    }

    nonisolated private static func normalizedEvidenceText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    nonisolated private static func evidenceRoles(_ evidence: [DocumentChunk], primary: [DocumentChunk],
                                                  linked: [DocumentChunk], semantic: [RelatedDocumentMatch])
        -> [UUID: DocumentEvidenceRole] {
        let primaryIDs = Set(primary.map(\.id))
        let linkedIDs = Set(linked.map(\.id)).subtracting(primaryIDs)
        let semanticByID = Dictionary(uniqueKeysWithValues: semantic.map { ($0.chunk.id, $0) })
        var roles: [UUID: DocumentEvidenceRole] = [:]
        for chunk in evidence {
            if primaryIDs.contains(chunk.id) { roles[chunk.id] = .primary }
            else if linkedIDs.contains(chunk.id) { roles[chunk.id] = .explicitReference }
            else if let match = semanticByID[chunk.id] {
                roles[chunk.id] = .semanticSupport(seedChunkID: match.seedChunkID, similarity: match.similarity)
            }
        }
        return roles
    }

    nonisolated static func assemble(_ chunks: [DocumentChunk], budget: Int, overview: Bool, preserveOrder: Bool = false) -> [DocumentChunk] {
        var remaining = max(0, budget)
        var selected: [DocumentChunk] = []
        // Overviews reserve coverage for each section instead of exhausting the budget at the beginning.
        var ordered: [DocumentChunk]
        if overview, chunks.reduce(0, { $0 + $1.text.count }) > budget {
            let headings = chunks.filter { $0.text.components(separatedBy: .newlines).contains { StructuredDocumentChunker.heading($0) != nil } }
            let ids = Set(headings.map(\.id))
            let sectionBudget = max(80, min(600, budget / max(1, headings.count + 1)))
            let introductions = Array(chunks.prefix(1))
            ordered = (introductions + headings).map { chunk in
                DocumentChunk(id: chunk.id, documentID: chunk.documentID, filename: chunk.filename, index: chunk.index,
                    text: String(chunk.text.prefix(sectionBudget)), sourceURL: chunk.sourceURL, location: chunk.location)
            } + chunks.filter { !ids.contains($0.id) && $0.id != chunks.first?.id }
        } else { ordered = chunks }
        var seen = Set<UUID>()
        var seenText = Set<String>()
        for chunk in ordered {
            guard selected.count < 48, remaining > 0 else { break }
            guard seen.insert(chunk.id).inserted else { continue }
            guard chunk.text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            guard chunk.text.count <= remaining else { continue }
            guard seenText.insert(normalizedEvidenceText(chunk.text)).inserted else { continue }
            selected.append(chunk); remaining -= chunk.text.count
        }
        return preserveOrder ? selected : selected.sorted { $0.index < $1.index }
    }

    nonisolated private static func expandLinkedSections(_ targets: [DocumentChunk], in chunks: [DocumentChunk]) -> [DocumentChunk] {
        let continuationLimit = 3
        var expanded: [DocumentChunk] = []
        var seen = Set<UUID>()
        for target in targets {
            guard let position = chunks.firstIndex(where: { $0.id == target.id }) else { continue }
            let firstLine = target.text.components(separatedBy: .newlines).first ?? ""
            let reference = StructuredDocumentChunker.heading(firstLine)
            let section: [DocumentChunk]
            if let reference {
                let resolved = AssignmentContextSearch.sections(for: reference, in: chunks)
                section = resolved.first(where: { $0.first?.id == target.id }) ?? [target]
            } else {
                var bounded = [target]
                for continuation in chunks.dropFirst(position + 1) {
                    if continuation.text.components(separatedBy: .newlines).contains(where: StructuredDocumentChunker.isStructuralHeading) {
                        break
                    }
                    bounded.append(continuation)
                    if bounded.count >= continuationLimit + 1 { break }
                }
                section = bounded
            }
            for chunk in section where seen.insert(chunk.id).inserted { expanded.append(chunk) }
        }
        return expanded
    }
}
