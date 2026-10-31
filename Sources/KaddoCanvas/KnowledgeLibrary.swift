import Foundation
import Combine
import CryptoKit

@MainActor
public final class KnowledgeLibrary: ObservableObject {
    @Published public private(set) var items: [KnowledgeItem] = []
    @Published public private(set) var categories: [KnowledgeCategory] = KnowledgeCategory.builtIns
    @Published public private(set) var isIndexing = false
    @Published public private(set) var status = ""
    @Published public private(set) var error: String?
    @Published public private(set) var revision = 0
    public let store: KnowledgeStore
    private let embeddingProvider: (any KnowledgeEmbeddingProvider)?
    private let semanticIndex: (any SemanticIndex)?
    private let storageURL: URL?
    private var indexingTask: Task<Void, Never>?
    private var indexingGeneration = 0
    private var loaded = false

    /// nil storageURL is explicitly ephemeral. App wiring passes KnowledgeStore.productionURL.
    /// Pass nil embeddingProvider for a keyword-only library.
    public init(storageURL: URL? = nil,
                embeddingProvider: (any KnowledgeEmbeddingProvider)? = try? OllamaEmbeddingProvider()) {
        self.store = KnowledgeStore(storageURL: storageURL)
        self.embeddingProvider = embeddingProvider
        self.semanticIndex = PostgresSemanticIndex()
        self.storageURL = storageURL
    }
    public func load() async {
        guard !loaded else { return }
        do {
            try await store.load()
            loaded = true
            try await refresh()
            if let semanticIndex {
                do { try await semanticIndex.start(); status = "Local pgvector search is ready." }
                catch { status = "PostgreSQL unavailable; keyword search remains ready. \(error.localizedDescription)" }
            }
            await rebuildDocumentStructures()
            await rebuildDocumentPassageLinks()
            await syncSemanticIndex()
            startIndexing()
        } catch { record(error) }
    }
    @discardableResult public func addNote(title: String, text: String, categoryID: UUID = KnowledgeCategory.general.id) async -> Bool {
        await mutate { _ = try await self.store.upsert(title: title, text: text, categoryID: categoryID) }
    }
    @discardableResult public func saveSession(_ session: KnowledgeSession) async -> Bool {
        do {
            try await store.saveSession(session)
            categories = try await store.categories()
            error = nil
            return true
        } catch { record(error); return false }
    }
    func saveUploadedDocument(_ session: KnowledgeSession, url: URL, text: String) async throws -> DocumentIngestionRecord {
        let retainedURL = try storageURL.map { try Self.retainOriginal(url, root: $0.deletingLastPathComponent()) }
            ?? url.standardizedFileURL
        let record = try await store.saveUploadedDocument(session: session, url: url, retainedURL: retainedURL, text: text)
        try await refresh()
        if let item = items.first(where: { $0.sourceKey == "session-file:\(session.id):\(url.standardizedFileURL.absoluteString)" }) {
            try await store.saveDocumentFocus(.init(documentID: item.id, revision: item.revision), sessionID: session.id)
        }
        revision += 1
        startIndexing()
        return record
    }

    @discardableResult public func saveSessionDocument(_ session: KnowledgeSession, url: URL, text: String) async -> Bool {
        guard await saveSession(session) else { return false }
        let key = "session-file:\(session.id):\(url.standardizedFileURL.absoluteString)"
        let categoryID = items.first(where: { $0.sourceKey == key })?.categoryID ?? session.id
        return await mutate {
            _ = try await self.store.upsert(title: url.lastPathComponent, text: text, categoryID: categoryID,
                sourceKey: key,
                sourceKind: "session-document", sourceURL: url.standardizedFileURL)
        }
    }
    @discardableResult public func saveSessionSummary(_ session: KnowledgeSession, text: String) async -> Bool {
        await mutate {
            _ = try await self.store.upsert(title: "Session summary · " + String(session.title.prefix(200)),
                text: text, categoryID: KnowledgeCategory.general.id,
                sourceKey: "session-summary:\(session.id)", sourceKind: "session-summary")
        }
    }
    @discardableResult public func updateNote(id: UUID, title: String, text: String) async -> Bool {
        guard let item = items.first(where: { $0.id == id }), item.isEditable else { return false }
        return await mutate { _ = try await self.store.upsert(title: title, text: text, categoryID: item.categoryID,
                                                     sourceKey: item.sourceKey, sourceKind: item.sourceKind, id: id) }
    }
    @discardableResult public func importDocument(at url: URL, categoryID: UUID = KnowledgeCategory.general.id) async -> Bool {
        do {
            // Extraction fully completes off the UI actor before any database mutation.
            let extraction = Task.detached(priority: .utility) { try Self.extract(url) }
            let text = try await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
            try Task.checkCancellation()
            return await mutate { _ = try await self.store.upsert(title: url.deletingPathExtension().lastPathComponent,
                text: text, categoryID: categoryID, sourceKind: url.pathExtension.lowercased(), sourceURL: url) }
        } catch { record(error); return false }
    }
    @discardableResult public func deleteItem(id: UUID) async -> Bool {
        let deleted = await mutate { try await self.store.deleteItem(id: id) }
        if deleted, let semanticIndex { try? await semanticIndex.delete(documentID: id) }
        return deleted
    }
    @discardableResult public func moveItem(id: UUID, categoryID: UUID) async -> Bool {
        await mutate { try await self.store.moveItem(id: id, categoryID: categoryID) }
    }
    @discardableResult public func addCategory(name: String) async -> KnowledgeCategory? {
        do {
            let result = try await store.addCategory(name: name)
            try await refresh(); revision += 1; error = nil
            return result
        } catch { record(error); return nil }
    }
    @discardableResult public func synchronize(sources: [KnowledgeSourceRecord]) async -> Bool {
        await mutate { try await self.store.reconcile(sources: sources) }
    }
    @discardableResult func acceptMemory(_ suggestion: AgentMemorySuggestion, fact: String, now: Date, platformState: AgentPlatformData? = nil) async -> Bool {
        await mutate { try await self.store.acceptMemory(suggestion, fact: fact, now: now, platformState: platformState) }
    }
    public func search(query: String, categoryID: UUID? = nil, documentIDs: Set<UUID>? = nil, maximumResults: Int = 5, characterBudget: Int = 6_000) async -> [KnowledgeMatch] {
        let snapshot = revision
        let scopedRevisions = Dictionary(uniqueKeysWithValues: items.filter { documentIDs?.contains($0.id) == true }.map { ($0.id, $0.revision) })
        func scopeIsCurrent() -> Bool {
            if documentIDs == nil { return snapshot == revision }
            return scopedRevisions.allSatisfy { id, version in items.contains { $0.id == id && $0.revision == version } }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_000 else { return [] }
        var vector: [Float]?
        var identity: String?
        if let embeddingProvider, trimmed.count <= 1_600 {
            do {
                let before = try await embeddingProvider.modelIdentity()
                let vectors = try await embeddingProvider.embeddings(for: [trimmed])
                _ = try validateKnowledgeVectors(vectors, count: 1)
                let after = try await embeddingProvider.modelIdentity()
                guard before == after else { throw KnowledgeError.incompatibleEmbedding }
                identity = after; vector = vectors[0]
            } catch is CancellationError { return [] }
            catch { /* Saved text remains searchable while local inference is unavailable. */ }
        }
        guard scopeIsCurrent(), !Task.isCancelled else { return [] }
        do {
            if let identity, let observedVector = vector,
               try await store.reconcileEmbeddingProfile(identity: identity, dimensions: observedVector.count) {
                // Incompatible vectors are already removed atomically. Publish pending rows
                // and replace the old index job before it can write results from that model.
                cancelIndexing()
                try await refresh()
                startIndexing()
                vector = nil // The detecting query uses keyword fallback while rebuilding.
            }
            guard scopeIsCurrent(), !Task.isCancelled else { return [] }
            var semanticCandidates: [UUID]?
            if let semanticIndex, let vector, let identity {
                do { semanticCandidates = try await semanticIndex.search(vector: vector, model: identity,
                    sessionID: nil, documentIDs: documentIDs, limit: 100) }
                catch { semanticCandidates = nil }
            }
            let matches = try await store.search(query: trimmed, categoryID: categoryID,
                vector: semanticIndex == nil ? vector : nil, identity: identity, documentIDs: documentIDs,
                semanticCandidates: semanticCandidates, maximumResults: maximumResults, characterBudget: characterBudget)
            return scopeIsCurrent() && !Task.isCancelled ? matches : []
        } catch { return [] }
    }

    func relatedDocumentChunks(seedChunkIDs: [UUID], documentIDs: Set<UUID>, excludedChunkIDs: Set<UUID>,
                               maximumResults: Int = 4, characterBudget: Int = 3_200) async -> [RelatedDocumentMatch] {
        guard !Task.isCancelled, !documentIDs.isEmpty, !seedChunkIDs.isEmpty else { return [] }
        var candidates: Set<UUID>?
        if let semanticIndex,
           let inputs = try? await store.documentVectorSeeds(chunkIDs: seedChunkIDs, documentIDs: documentIDs),
           inputs.dimensions == 768 {
            do {
                var indexedIDs = Set<UUID>()
                for seedID in seedChunkIDs where !Task.isCancelled {
                    guard let vector = inputs.vectors[seedID] else { continue }
                    indexedIDs.formUnion(try await semanticIndex.search(vector: vector, model: inputs.identity,
                        sessionID: nil, documentIDs: documentIDs, limit: 100))
                }
                candidates = indexedIDs
            } catch is CancellationError {
                return []
            } catch {
                candidates = nil
            }
        }
        guard !Task.isCancelled else { return [] }
        do {
            return try await store.relatedDocumentChunks(seedChunkIDs: seedChunkIDs, documentIDs: documentIDs,
                excludedChunkIDs: excludedChunkIDs, candidateChunkIDs: candidates,
                maximumResults: maximumResults, characterBudget: characterBudget)
        } catch { return [] }
    }

    private func rebuildDocumentStructures(force: Bool = false) async {
        do {
            let documents = try await store.documentsNeedingStructure(retryUnavailable: force)
            for item in documents {
                try Task.checkCancellation()
                status = "Improving document search locally…"
                let task = Task.detached(priority: .utility) {
                    // Reuse saved text if the original upload is no longer available.
                    if let url = item.sourceURL, FileManager.default.isReadableFile(atPath: url.path) {
                        var native = ""
                        if ["pdf", "docx"].contains(url.pathExtension.lowercased()) {
                            try? DocumentTextExtractor(includeOCR: false, includeSourceLocations: false).extract(at: url) { native += $0 }
                        } else { native = (try? Self.extract(url)) ?? "" }
                        func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                        // The URL may now point at a different file. Never silently substitute its contents.
                        if normalized(native) == normalized(item.text), let text = try? Self.extract(url) { return text }
                        return item.text + "\n[Extraction note: Original file changed or could not be verified; using saved text without re-reading images.]"
                    }
                    return item.text + "\n[Extraction note: Original source unavailable; using saved text. Visual content may be missing.]"
                }
                var text = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
                if let url = item.sourceURL, url.pathExtension.lowercased() == "pdf" {
                    text = await LocalLayoutVision.enrichPDF(at: url, extractedText: text)
                }
                _ = try await store.rebuildDocumentIndex(itemID: item.id, revision: item.revision, text: text)
            }
            try await refresh()
        } catch { record(error) }
    }
    private func rebuildDocumentPassageLinks() async {
        do {
            for item in try await store.documentsNeedingPassageLinks() {
                try Task.checkCancellation()
                _ = try await store.rebuildDocumentPassageLinks(itemID: item.id, revision: item.revision)
            }
        } catch { record(error) }
    }
    public func retryIndexing() async {
        cancelIndexing()
        await rebuildDocumentStructures(force: true)
        await rebuildDocumentPassageLinks()
        await syncSemanticIndex()
        startIndexing()
    }
    private func syncSemanticIndex() async {
        guard let semanticIndex else { return }
        do {
            try await semanticIndex.start()
            var cursor: String?
            while true {
                let batch = try await store.semanticIndexChunks(after: cursor)
                guard !batch.isEmpty else { break }
                try await semanticIndex.upsert(batch)
                cursor = batch.last?.id.uuidString
                if batch.count < 64 { break }
            }
        } catch {
            status = "Keyword search remains ready; local pgvector sync will retry later. \(error.localizedDescription)"
        }
    }
    public func waitForIndexing() async {
        // Filing and planner sync can replace the indexing job while an upload is waiting.
        while let job = indexingTask {
            let generation = indexingGeneration
            await job.value
            if Task.isCancelled || generation == indexingGeneration { return }
        }
    }
    public func localVectorizationState(for itemID: UUID? = nil) -> LocalVectorizationState {
        let documents = itemID.map { id in items.filter { $0.id == id } } ?? items
        if !documents.isEmpty, documents.allSatisfy({ $0.indexingStatus == .indexed }) { return .ready }
        if isIndexing { return .indexing }
        return .unavailable
    }
    public var localVectorizationSummary: String {
        "Vectors stay on this Mac using local Ollama. " + localVectorizationState().message
    }
    public func cancelIndexing() {
        indexingGeneration += 1
        indexingTask?.cancel(); indexingTask = nil; isIndexing = false
    }
    public func startIndexing() {
        cancelIndexing()
        guard let embeddingProvider else {
            status = "Keyword search is ready. Semantic indexing is unavailable."
            return
        }
        let generation = indexingGeneration
        isIndexing = true
        status = "Indexing knowledge locally…"
        indexingTask = Task { [weak self] in
            guard let self else { return }
            var documentFailure: String?
            do {
                let identity = try await embeddingProvider.modelIdentity()
                try Task.checkCancellation()
                // A fully indexed library still needs a probe: the dimensions can change
                // under the same model identity, leaving no pending documents to reveal it.
                if try await self.store.pendingDocuments().isEmpty,
                   let probe = try await self.store.embeddingProbeText() {
                    let vectors = try await embeddingProvider.embeddings(for: [probe])
                    let dimensions = try validateKnowledgeVectors(vectors, count: 1)
                    guard try await embeddingProvider.modelIdentity() == identity else { throw KnowledgeError.incompatibleEmbedding }
                    try Task.checkCancellation()
                    guard generation == self.indexingGeneration else { return }
                    if try await self.store.reconcileEmbeddingProfile(identity: identity, dimensions: dimensions) {
                        try await self.refresh()
                    }
                }
                // Repeat when a dimension change invalidates a previously indexed item.
                var pass = 0
                while pass < 2 {
                    pass += 1
                    let pending = try await self.store.pendingDocuments()
                    guard !pending.isEmpty else { break }
                    for document in pending {
                        try Task.checkCancellation()
                        do {
                            guard let item = self.items.first(where: { $0.id == document.itemID }) else { continue }
                            if let semanticIndex {
                                do { try await semanticIndex.delete(documentID: document.itemID) }
                                catch { self.status = "SQLite indexing continues; pgvector will sync later. \(error.localizedDescription)" }
                            }
                            if document.chunks.isEmpty {
                                _ = try await self.store.finishEmbedding(itemID: document.itemID, revision: document.revision)
                                continue
                            }
                            let sessionID = Self.sessionID(from: item.sourceKey)
                            for offset in stride(from: 0, to: document.chunks.count, by: 32) {
                                let batch = Array(document.chunks[offset..<min(offset + 32, document.chunks.count)])
                                let result = try await embeddingProvider.embeddings(for: batch)
                                let dimensions = try validateKnowledgeVectors(result, count: batch.count)
                                guard try await embeddingProvider.modelIdentity() == identity else { throw KnowledgeError.incompatibleEmbedding }
                                guard generation == self.indexingGeneration else { return }
                                if try await self.store.reconcileEmbeddingProfile(identity: identity, dimensions: dimensions) {
                                    try await self.refresh()
                                }
                                let ids = Array(document.chunkIDs[offset..<min(offset + 32, document.chunkIDs.count)])
                                guard try await self.store.setEmbeddingBatch(itemID: document.itemID,
                                    revision: document.revision, identity: identity, chunkIDs: ids, vectors: result) else {
                                    throw KnowledgeError.incompatibleEmbedding
                                }
                                if let semanticIndex {
                                    let chunks = zip(ids, zip(batch, result)).map { id, pair in
                                        SemanticIndexChunk(id: id, documentID: document.itemID, sessionID: sessionID,
                                            revision: document.revision, generation: StructuredDocumentChunker.version,
                                            model: identity, text: pair.0, vector: pair.1)
                                    }
                                    do { try await semanticIndex.upsert(chunks) }
                                    catch { self.status = "SQLite indexing continues; pgvector will sync later. \(error.localizedDescription)" }
                                }
                                try Task.checkCancellation()
                            }
                            _ = try await self.store.finishEmbedding(itemID: document.itemID, revision: document.revision)
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            try await self.store.markFailed(itemID: document.itemID, revision: document.revision)
                            if documentFailure == nil { documentFailure = error.localizedDescription }
                            continue
                        }
                    }
                    if documentFailure != nil { break }
                }
                guard generation == self.indexingGeneration else { return }
                let hasPending = try await !self.store.pendingDocuments().isEmpty
                try await self.refresh()
                if let documentFailure {
                    self.status = "Other documents indexed. Some need retry: \(documentFailure)"
                    self.error = documentFailure
                } else if hasPending {
                    self.status = "Some documents still need local indexing."
                } else {
                    self.status = "Knowledge search is ready."
                    self.error = nil
                }
            } catch is CancellationError { }
            catch {
                guard generation == self.indexingGeneration else { return }
                try? await self.refresh()
                self.error = error.localizedDescription
                self.status = "Text saved. Keyword search is ready; retry semantic indexing when Ollama is available."
            }
            if generation == self.indexingGeneration { self.isIndexing = false; self.indexingTask = nil }
        }
    }
    private func mutate(_ operation: () async throws -> Void) async -> Bool {
        cancelIndexing()
        do {
            try await operation()
            try await refresh()
            revision += 1 // Publish source changes before new background vectors are computed.
            error = nil
            startIndexing()
            return true
        } catch { record(error); return false }
    }
    private func refresh() async throws {
        items = try await store.items()
        categories = try await store.categories()
    }
    private func record(_ error: Error) {
        self.error = error.localizedDescription
        status = error.localizedDescription
    }
    nonisolated private static func sessionID(from sourceKey: String) -> UUID? {
        guard sourceKey.hasPrefix("session-file:"), let boundary = sourceKey.dropFirst("session-file:".count).firstIndex(of: ":") else { return nil }
        return UUID(uuidString: String(sourceKey.dropFirst("session-file:".count)[..<boundary]))
    }
    nonisolated private static func retainOriginal(_ url: URL, root: URL) throws -> URL {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return url.standardizedFileURL }
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 20 * 1_024 * 1_024 else {
            throw DocumentImportError.documentTooLarge
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= 20 * 1_024 * 1_024 else { throw DocumentImportError.documentTooLarge }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(digest).appendingPathExtension(url.pathExtension.lowercased())
        if !FileManager.default.fileExists(atPath: target.path) { try data.write(to: target, options: .atomic) }
        return target
    }
    nonisolated static func extract(_ url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" || ext == "docx" {
            var text = ""
            try DocumentTextExtractor().extract(at: url) { text.append($0) }
            return text
        }
        guard ext == "txt" || ext == "md" else { throw DocumentImportError.unsupportedFile }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw DocumentImportError.unreadableFile }
        let limit = 8 * 1_024 * 1_024
        guard let size = values.fileSize, size <= 20 * 1_024 * 1_024, size <= limit else { throw DocumentImportError.documentTooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        try Task.checkCancellation()
        guard data.count <= limit else { throw DocumentImportError.documentTooLarge }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw DocumentImportError.invalidDocument }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DocumentImportError.noExtractableText }
        return text
    }
}
