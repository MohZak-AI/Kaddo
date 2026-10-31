import Combine
import Foundation

public struct DocumentChunk: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let documentID: UUID
    public let filename: String
    public let index: Int
    public let text: String
    public let sourceURL: URL?
    public let location: String?

    public init(id: UUID, documentID: UUID, filename: String, index: Int, text: String,
                sourceURL: URL? = nil, location: String? = nil) {
        self.id = id
        self.documentID = documentID
        self.filename = filename
        self.index = index
        self.text = text
        self.sourceURL = sourceURL
        self.location = location
    }
}

/// Session context. App-owned stores persist extracted text before publishing an import.
@MainActor
public final class DocumentMemoryStore: ObservableObject {
    @Published public private(set) var chunks: [DocumentChunk] = []
    @Published public private(set) var isImporting = false
    var activity: PetActivityStore?
    var persistImport: ((URL, String) async throws -> Void)?
    var persistedChunks: ((URL) async throws -> [DocumentChunk])?
    var didImport: ((URL) async -> Void)?
    private var worker: Task<[String], Error>?
    private var generation = UUID()
    private var storedBytes = 0
    private let maxStoredBytes: Int
    private let maxStoredChunks: Int

    public init(maxStoredBytes: Int = 16 * 1_024 * 1_024, maxStoredChunks: Int = 20_000) {
        self.maxStoredBytes = max(0, maxStoredBytes)
        self.maxStoredChunks = max(0, maxStoredChunks)
    }

    /// Import order, with full URLs rather than filenames as the file identity.
    public var fileURLs: [URL] {
        var seen: Set<URL> = []
        return chunks.compactMap(\.sourceURL).filter { seen.insert($0).inserted }
    }

    /// Concurrent imports are rejected to bound peak memory. A failed import is atomic.
    @discardableResult
    public func importDocument(
        at url: URL,
        extractor: DocumentTextExtractor = DocumentTextExtractor(),
        chunker: DocumentTextChunker? = nil
    ) async throws -> Int {
        guard !isImporting else { throw DocumentImportError.importInProgress }
        let chunker = try chunker ?? DocumentTextChunker()
        let ticket = UUID()
        let activityID = activity?.begin(title: "Reading " + url.lastPathComponent)
        var recorded = false
        defer { if !recorded, let activityID { activity?.cancel(activityID) } }
        generation = ticket
        isImporting = true
        let task = Task.detached(priority: .userInitiated) {
            var text = String()
            if ["txt", "md"].contains(url.pathExtension.lowercased()) {
                text = try KnowledgeLibrary.extract(url)
            } else {
                try extractor.extract(at: url) { text.append($0) }
            }
            return try chunker.maxCharacters == 1_600 ? StructuredDocumentChunker.chunks(text) : chunker.paragraphChunks(in: text)
        }
        worker = task
        defer {
            if generation == ticket {
                worker = nil
                isImporting = false
            }
        }
        do {
            var texts = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard generation == ticket else { throw CancellationError() }
            if url.pathExtension.lowercased() == "pdf" {
                let text = await LocalLayoutVision.enrichPDF(at: url, extractedText: texts.joined(separator: "\n\n"))
                if text != texts.joined(separator: "\n\n") {
                    texts = try StructuredDocumentChunker.chunks(text)
                }
            }
            guard !texts.isEmpty else { throw DocumentImportError.noExtractableText }
            let bytes = texts.reduce(0) { $0 + $1.utf8.count }
            let replaced = chunks.filter { $0.sourceURL == url.standardizedFileURL }
            let replacedBytes = replaced.reduce(0) { $0 + $1.text.utf8.count }
            guard bytes <= maxStoredBytes - storedBytes + replacedBytes,
                  texts.count <= maxStoredChunks - chunks.count + replaced.count else {
                throw DocumentImportError.memoryLimitReached
            }
            try await persistImport?(url, texts.joined(separator: "\n\n"))
            try Task.checkCancellation()
            guard generation == ticket else { throw CancellationError() }
            let documentID = DocumentIdentity.id(url.standardizedFileURL.absoluteString)
            var additions = texts.enumerated().map {
                DocumentChunk(id: DocumentIdentity.id("\(documentID):\($0.offset):\($0.element)"), documentID: documentID, filename: url.lastPathComponent,
                              index: $0.offset, text: $0.element, sourceURL: url.standardizedFileURL)
            }
            if let persistedChunks { additions = try await persistedChunks(url) }
            try Task.checkCancellation()
            guard generation == ticket else { throw CancellationError() }
            // Re-importing a saved source replaces its in-memory copy too.
            chunks = chunks.filter { $0.sourceURL != url.standardizedFileURL } + additions
            storedBytes = chunks.reduce(0) { $0 + $1.text.utf8.count }
            if let activityID {
                activity?.finish(activityID, state: .ready,
                                 message: "Read \(url.lastPathComponent): \(additions.count) text blocks.", preview: false)
            }
            recorded = true
            await didImport?(url)
            return additions.count
        } catch {
            if !(error is CancellationError), generation == ticket, let activityID {
                activity?.finish(activityID, state: .blocked, message: error.localizedDescription, preview: false)
                recorded = true
            }
            throw error
        }
    }

    func restore(items: [KnowledgeItem]) throws {
        var restored: [DocumentChunk] = []
        for item in items {
            for (index, text) in try StructuredDocumentChunker.chunks(item.text).enumerated() {
                restored.append(DocumentChunk(id: DocumentIdentity.id("\(item.id):\(index):\(text)"), documentID: item.id, filename: item.title,
                    index: index, text: text, sourceURL: item.sourceURL))
            }
        }
        let bytes = restored.reduce(0) { $0 + $1.text.utf8.count }
        guard bytes <= maxStoredBytes, restored.count <= maxStoredChunks else { throw DocumentImportError.memoryLimitReached }
        chunks = restored; storedBytes = bytes
    }

    func restore(chunks restored: [DocumentChunk]) throws {
        let bytes = restored.reduce(0) { $0 + $1.text.utf8.count }
        guard bytes <= maxStoredBytes, restored.count <= maxStoredChunks else { throw DocumentImportError.memoryLimitReached }
        chunks = restored; storedBytes = bytes
    }

    public func removeDocument(id: UUID) {
        chunks.removeAll { $0.documentID == id }
        storedBytes = chunks.reduce(0) { $0 + $1.text.utf8.count }
    }

    public func clear() {
        generation = UUID()
        worker?.cancel()
        worker = nil
        isImporting = false
        chunks.removeAll(keepingCapacity: false)
        storedBytes = 0
    }

    deinit { worker?.cancel() }
}
