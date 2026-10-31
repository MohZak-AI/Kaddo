import Foundation

/// The record backing one SessionFolderView. Extracted text is restored from session knowledge at launch.
@MainActor
public struct SessionFolderRecord: Identifiable {
    public let id: UUID
    public let title: String
    public let documentMemory: DocumentMemoryStore
    public var files: [URL] { documentMemory.fileURLs }

    public init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
        self.documentMemory = DocumentMemoryStore()
    }
}

@MainActor
public struct ScopedDocumentContextRouter {
    private let state: PetApplicationState

    public init(state: PetApplicationState) { self.state = state }

    /// Returns up to five relevant paragraphs, or empty context when none match.
    /// Never falls back to another session when the selected box is empty.
    public func fetchContextForActiveSession(query: String) -> String {
        let matches = try? Self.search(query, in: chunksForActiveSession())
        return (matches ?? []).map(\.chunk.text).joined(separator: "\n\n")
    }

    /// Capture on the main actor before dispatching search to a worker. Only the
    /// selected record's URL array and its own extracted blocks are traversed.
    func chunksForActiveSession() -> [DocumentChunk] {
        guard let record = state.sessionFolders[state.activeSessionID] else { return [] }
        let urls = Set(record.files)
        return record.documentMemory.chunks.filter { chunk in
            guard let url = chunk.sourceURL else { return false }
            return urls.contains(url)
        }
    }

    nonisolated static func search(_ query: String, in chunks: [DocumentChunk]) throws -> [NoteMatch] {
        try KeywordNoteSearch(maximumResults: 5).search(query, in: chunks)
    }
}
