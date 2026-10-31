import Foundation

public struct ConversationExchange: Equatable, Codable, Sendable {
    public let id: UUID
    public let user: String
    public let companion: String

    public init(id: UUID = UUID(), user: String, companion: String) {
        self.id = id; self.user = user; self.companion = companion
    }

    private enum CodingKeys: String, CodingKey { case id, user, companion }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        user = try values.decode(String.self, forKey: .user)
        companion = try values.decode(String.self, forKey: .companion)
    }

    public var characterCount: Int { user.count + companion.count }
}

public struct CompactedConversationContext: Codable, Equatable, Sendable {
    public var summary: String
    public var coveredExchangeIDs: [UUID]
    public var lastCoveredExchangeID: UUID?
    public var exchanges: [ConversationExchange]
    public init(summary: String = "", coveredExchangeIDs: [UUID] = [], lastCoveredExchangeID: UUID? = nil,
                exchanges: [ConversationExchange] = []) {
        self.summary = summary; self.coveredExchangeIDs = coveredExchangeIDs
        self.lastCoveredExchangeID = lastCoveredExchangeID; self.exchanges = exchanges
    }
}

/// Replace this boundary to add persistence later. Only completed casual chat belongs here.
@MainActor
public protocol ConversationStore: AnyObject {
    var exchanges: [ConversationExchange] { get }
    var summary: String { get }
    var coveredExchangeIDs: [UUID] { get }
    var lastCoveredExchangeID: UUID? { get }
    var needsCompaction: Bool { get }
    func exchangesToCompact(preserving newest: Int) -> [ConversationExchange]
    func restore(_ context: CompactedConversationContext)
    func append(_ exchange: ConversationExchange)
    func compact(summary: String, covering exchangeIDs: [UUID])
    func clear()
}

@MainActor
public final class InMemoryConversationStore: ConversationStore {
    public private(set) var exchanges: [ConversationExchange] = []
    public private(set) var summary = ""
    public private(set) var coveredExchangeIDs: [UUID] = []
    public private(set) var lastCoveredExchangeID: UUID?
    public init() {}

    public func restore(_ context: CompactedConversationContext) {
        summary = context.summary; coveredExchangeIDs = context.coveredExchangeIDs
        lastCoveredExchangeID = context.lastCoveredExchangeID
        exchanges = context.exchanges
        trim()
    }

    public func append(_ exchange: ConversationExchange) {
        exchanges.append(exchange)
        trim()
    }

    public func compact(summary: String, covering exchangeIDs: [UUID]) {
        guard !summary.isEmpty else { return }
        self.summary = summary
        coveredExchangeIDs = Array(LinkedHashUUIDs(coveredExchangeIDs + exchangeIDs).values.suffix(80))
        lastCoveredExchangeID = exchangeIDs.last ?? lastCoveredExchangeID
        let covered = Set(exchangeIDs)
        exchanges.removeAll { covered.contains($0.id) }
        trim()
    }

    public var needsCompaction: Bool {
        exchanges.count > 8 || exchanges.reduce(0, { $0 + $1.characterCount }) > 24_000
    }

    public func exchangesToCompact(preserving newest: Int = 4) -> [ConversationExchange] {
        Array(exchanges.dropLast(min(newest, exchanges.count)))
    }

    public func clear() { exchanges.removeAll(); summary = ""; coveredExchangeIDs.removeAll(); lastCoveredExchangeID = nil }

    private func trim() {
        while exchanges.count > 80 || exchanges.reduce(0, { $0 + $1.characterCount }) > 48_000 {
            exchanges.removeFirst()
        }
    }
}

private struct LinkedHashUUIDs {
    let values: [UUID]
    init(_ values: [UUID]) {
        var seen = Set<UUID>(); self.values = values.filter { seen.insert($0).inserted }
    }
}
