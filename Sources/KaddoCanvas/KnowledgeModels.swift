import Foundation

public struct KnowledgeSession: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public var exchanges: [ConversationExchange]
    public var documentConversation: DocumentConversationState?
    public var conversationContext: CompactedConversationContext?
    public init(id: UUID, title: String, exchanges: [ConversationExchange] = [],
                conversationContext: CompactedConversationContext? = nil, documentConversation: DocumentConversationState? = nil) {
        self.id = id; self.title = title; self.exchanges = exchanges; self.conversationContext = conversationContext
        self.documentConversation = documentConversation
    }
}

public enum KnowledgeIndexingStatus: String, Codable, Sendable {
    case pending, indexed, failed
}

public enum LocalVectorizationState: String, Sendable {
    case indexing, ready, unavailable

    public var message: String {
        switch self {
        case .indexing: "Creating search vectors on this Mac…"
        case .ready: "Search vectors are ready on this Mac."
        case .unavailable: "Local vector search is unavailable. Text search still works. Say ‘retry indexing’ to try again."
        }
    }
}

public struct KnowledgeCategory: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let name: String
    public static let personal = Self(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, name: "Personal")
    public static let work = Self(id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!, name: "Work")
    public static let study = Self(id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!, name: "Study")
    public static let general = Self(id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!, name: "General")
    public static let builtIns = [personal, work, study, general]
}

public struct KnowledgeItem: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let title: String
    public let text: String
    public let categoryID: UUID
    public let sourceKey: String
    public let sourceKind: String
    public let sourceURL: URL?
    public let contentHash: String
    public let revision: Int
    public let updatedAt: Date
    public let indexingStatus: KnowledgeIndexingStatus
    public var isEditable: Bool { sourceKind == "note" }
}

public struct KnowledgeSourceRecord: Sendable {
    public let sourceKey: String
    public let title: String
    public let text: String
    public let categoryName: String
    public let kind: String
    public init(sourceKey: String, title: String, text: String,
                categoryName: String = "General", kind: String) {
        self.sourceKey = sourceKey; self.title = title; self.text = text
        self.categoryName = categoryName; self.kind = kind
    }
}

public struct KnowledgeMatch: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var chunkID: UUID { id }
    public let itemID: UUID
    public let title: String
    public let categoryID: UUID
    public let sourceKey: String
    public let sourceKind: String
    public let sourceURL: URL?
    public let text: String
    public let score: Double
}

struct RelatedDocumentMatch: Sendable {
    let chunk: DocumentChunk
    let seedChunkID: UUID
    let similarity: Double
}

public struct KnowledgeIndexingDocument: Sendable {
    public let itemID: UUID
    public let revision: Int
    public let chunks: [String]
    public var chunkIDs: [UUID] = []
}

public enum KnowledgeError: Error, LocalizedError, Sendable, Equatable {
    case database(String), invalidInput, capacityReached, incompatibleEmbedding, invalidEmbedding
    public var errorDescription: String? {
        switch self {
        case .database(let detail): "Knowledge library could not be opened or saved: \(detail)"
        case .invalidInput: "Enter a title, readable text, and an existing category."
        case .capacityReached: "The knowledge library has reached its 20,000 text chunk limit."
        case .incompatibleEmbedding: "The embedding model changed. Retry indexing the library."
        case .invalidEmbedding: "The embedding model returned invalid vectors."
        }
    }
}

public protocol KnowledgeEmbeddingProvider: Sendable {
    var identity: String { get }
    func modelIdentity() async throws -> String
    func embeddings(for texts: [String]) async throws -> [[Float]]
}

public extension KnowledgeEmbeddingProvider {
    func modelIdentity() async throws -> String { identity }
}

func validateKnowledgeVectors(_ vectors: [[Float]], count: Int) throws -> Int {
    guard vectors.count == count, let dimension = vectors.first?.count,
          (1...8_192).contains(dimension), vectors.allSatisfy({ vector in
              vector.count == dimension && vector.allSatisfy(\.isFinite)
                  && vector.contains(where: { $0 != 0 })
          }) else { throw KnowledgeError.invalidEmbedding }
    return dimension
}
