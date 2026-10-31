import Foundation
import CryptoKit
import CSQLite

// The connection never escapes KnowledgeStore's actor; the wrapper permits safe cleanup.
private final class KnowledgeDatabase: @unchecked Sendable {
    let handle: OpaquePointer
    init(path: String) throws {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            if let pointer { sqlite3_close(pointer) }
            throw KnowledgeError.database(message)
        }
        handle = pointer
        sqlite3_busy_timeout(handle, 3_000)
    }
    deinit { sqlite3_close(handle) }
}

private enum KnowledgeSQLValue {
    case text(String), integer(Int), real(Double), data(Data), null
}

public actor KnowledgeStore {
    public static let maximumChunks = 20_000
    public static var productionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kaddo/Knowledge/knowledge.sqlite")
    }
    private static let itemColumns = "id,title,text,category,source_key,kind,COALESCE(url,''),hash,revision,updated,status"
    private let storageURL: URL?
    private var database: KnowledgeDatabase?
    public init(storageURL: URL? = nil) { self.storageURL = storageURL }

    public func load() throws { try open() }

    private func open() throws {
        guard database == nil else { return }
        if let storageURL {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let connection = try KnowledgeDatabase(path: storageURL?.path ?? ":memory:")
        database = connection
        do {
            // quick_check validates existing files before any schema writes; corrupt files are preserved.
            let check = try rows("PRAGMA quick_check")
            guard check.first?.first == "ok" else { throw KnowledgeError.database("Database integrity check failed") }
            let version = Int(try rows("PRAGMA user_version").first?.first ?? "0") ?? 0
            guard version <= 6 else { throw KnowledgeError.database("This library requires a newer version of Kaddo") }
            try execute("PRAGMA foreign_keys=ON")
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS categories(id TEXT PRIMARY KEY,name TEXT NOT NULL UNIQUE COLLATE NOCASE)")
                try execute("CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY,title TEXT NOT NULL,text TEXT NOT NULL,category TEXT NOT NULL REFERENCES categories(id),source_key TEXT NOT NULL UNIQUE,kind TEXT NOT NULL,url TEXT,hash TEXT NOT NULL,revision INTEGER NOT NULL,updated REAL NOT NULL,status TEXT NOT NULL,managed INTEGER NOT NULL DEFAULT 0)")
                try execute("CREATE INDEX IF NOT EXISTS items_hash_category ON items(hash,category,source_key)")
                try execute("CREATE INDEX IF NOT EXISTS items_managed_source ON items(managed,source_key)")
                try execute("CREATE TABLE IF NOT EXISTS chunks(id TEXT PRIMARY KEY,item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,ordinal INTEGER NOT NULL,text TEXT NOT NULL,vector BLOB,UNIQUE(item_id,ordinal))")
                try execute("CREATE VIRTUAL TABLE IF NOT EXISTS chunk_search USING fts5(chunk_id UNINDEXED,text,tokenize='unicode61')")
                try execute("CREATE TABLE IF NOT EXISTS embedding_profile(id INTEGER PRIMARY KEY CHECK(id=1),identity TEXT NOT NULL,dimensions INTEGER NOT NULL)")
                for category in KnowledgeCategory.builtIns {
                    try execute("INSERT OR IGNORE INTO categories(id,name) VALUES(?,?)", [.text(category.id.uuidString), .text(category.name)])
                }
                try execute("CREATE TABLE IF NOT EXISTS agent_state(id INTEGER PRIMARY KEY CHECK(id=1),json TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS knowledge_sessions(id TEXT PRIMARY KEY,json TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS document_ingestion(id TEXT PRIMARY KEY,json TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS document_indexes(item_id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,revision INTEGER NOT NULL,version INTEGER NOT NULL,text TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS document_focus(session_id TEXT PRIMARY KEY,json TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS document_link_indexes(item_id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,revision INTEGER NOT NULL,version INTEGER NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS document_passage_links(document_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,revision INTEGER NOT NULL,source_chunk_id TEXT NOT NULL,target_chunk_id TEXT NOT NULL,kind TEXT NOT NULL,source_text TEXT NOT NULL,UNIQUE(document_id,revision,source_chunk_id,target_chunk_id,kind))")
                try execute("CREATE INDEX IF NOT EXISTS document_passage_links_source ON document_passage_links(document_id,revision,source_chunk_id)")
                try execute("PRAGMA user_version=6")
            }
        } catch { database = nil; throw error }
    }

    func ingestionRecords() throws -> [DocumentIngestionRecord] {
        try open()
        return try rows("SELECT json FROM document_ingestion ORDER BY rowid").map {
            try JSONDecoder().decode(DocumentIngestionRecord.self, from: Data($0[0].utf8))
        }
    }

    func saveIngestion(_ record: DocumentIngestionRecord) throws {
        try open()
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        try execute("INSERT INTO document_ingestion(id,json) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
                    [.text(record.id), .text(json)])
    }

    // Document text and its pending work commit together, so a restart cannot orphan an upload.
    func saveUploadedDocument(session: KnowledgeSession, url: URL, retainedURL: URL, text: String) throws -> DocumentIngestionRecord {
        try saveSession(session)
        return try transaction {
            let key = "session-file:\(session.id):\(url.standardizedFileURL.absoluteString)"
            let old = try existingItem(sourceKey: key)
            var count = try chunkCount()
            let item = try save(title: url.lastPathComponent, text: text,
                                categoryID: old?.categoryID ?? KnowledgeCategory.general.id,
                                sourceKey: key, kind: "session-document", url: retainedURL.standardizedFileURL,
                                id: nil, managed: false, chunkCount: &count)
            if let record = try ingestionRecords().first(where: { $0.id == item.contentHash }) { return record }
            let record = DocumentIngestionRecord(id: item.contentHash, documentID: item.id,
                                                  sessionID: session.id, filename: item.title)
            try saveIngestion(record)
            return record
        }
    }

    public func agentData() throws -> AgentPlatformData {
        try open()
        guard let json = try rows("SELECT json FROM agent_state WHERE id=1").first?.first else { return AgentPlatformData() }
        return try JSONDecoder().decode(AgentPlatformData.self, from: Data(json.utf8))
    }

    public func sessions() throws -> [KnowledgeSession] {
        try open()
        return try rows("SELECT json FROM knowledge_sessions ORDER BY rowid").map {
            try JSONDecoder().decode(KnowledgeSession.self, from: Data($0[0].utf8))
        }
    }

    public func saveSession(_ session: KnowledgeSession) throws {
        try open()
        let json = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        try transaction {
            // Session ownership is stable even if the agent later moves a file's category.
            let existing = try categories()
            if !existing.contains(where: { $0.id == session.id }) {
                let base = "Session · " + String(session.title.prefix(40))
                var name = base
                var suffix = 2
                while existing.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    name = "\(base) (\(suffix))"; suffix += 1
                }
                try execute("INSERT INTO categories(id,name) VALUES(?,?)", [.text(session.id.uuidString), .text(name)])
            }
            try execute("INSERT INTO knowledge_sessions(id,json) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
                        [.text(session.id.uuidString), .text(json)])
        }
    }
    public func saveAgentData(_ value: AgentPlatformData) throws {
        try open()
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        do {
            try execute("INSERT INTO agent_state(id,json) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json", [.text(json)])
        } catch {
            // A moved/replaced database can leave SQLite's handle permanently read-only.
            // Retry reopens and integrity-checks the original path. Active transactions own rollback.
            if let database, sqlite3_get_autocommit(database.handle) != 0 { self.database = nil }
            throw error
        }
    }
    /// Fact, provenance and removal of the pending suggestion commit together.
    public func acceptMemory(_ suggestion: AgentMemorySuggestion, fact: String, now: Date, platformState: AgentPlatformData? = nil) throws {
        try open()
        try transaction {
            var data = try agentData()
            guard data.suggestions.contains(where: { $0.id == suggestion.id }) else { throw KnowledgeError.invalidInput }
            if let target = suggestion.replacesID {
                guard data.memories.contains(where: { $0.itemID == target }),
                      try existingItem(id: target) != nil else { throw KnowledgeError.invalidInput }
            }
            if let platformState { data = platformState }
            var count = try chunkCount()
            let id = suggestion.replacesID ?? suggestion.id
            let item = try save(title: String(fact.prefix(80)), text: fact, categoryID: KnowledgeCategory.personal.id,
                                sourceKey: "memory:" + id.uuidString, kind: "note", url: nil, id: id, managed: false, chunkCount: &count)
            data.memories.removeAll { $0.itemID == item.id }
            data.memories.append(.init(itemID: item.id, source: "User-reviewed conversation", quote: suggestion.quote, acceptedAt: now))
            data.suggestions.removeAll { $0.id == suggestion.id }
            try saveAgentData(data)
        }
    }

    public func categories() throws -> [KnowledgeCategory] {
        try open()
        return try rows("SELECT id,name FROM categories ORDER BY name").compactMap {
            guard let id = UUID(uuidString: $0[0]) else { return nil }
            return KnowledgeCategory(id: id, name: $0[1])
        }
    }
    @discardableResult public func addCategory(name: String) throws -> KnowledgeCategory {
        try open()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw KnowledgeError.invalidInput }
        if let existing = try categories().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return existing }
        let category = KnowledgeCategory(id: UUID(), name: name)
        try execute("INSERT INTO categories(id,name) VALUES(?,?)", [.text(category.id.uuidString), .text(name)])
        return category
    }
    public func items() throws -> [KnowledgeItem] {
        try open()
        return try rows("SELECT \(Self.itemColumns) FROM items ORDER BY updated DESC,id").compactMap(Self.item)
    }
    private func existingItem(id: UUID? = nil, sourceKey: String? = nil) throws -> KnowledgeItem? {
        var predicates: [String] = []
        var values: [KnowledgeSQLValue] = []
        if let id { predicates.append("id=?"); values.append(.text(id.uuidString)) }
        if let sourceKey { predicates.append("source_key=?"); values.append(.text(sourceKey)) }
        guard !predicates.isEmpty else { return nil }
        return try rows("SELECT \(Self.itemColumns) FROM items WHERE " + predicates.joined(separator: " OR ")
            + " ORDER BY updated DESC,id LIMIT 1", values).first.flatMap(Self.item)
    }
    private func chunkCount() throws -> Int {
        Int(try rows("SELECT COUNT(*) FROM chunks").first?.first ?? "0") ?? 0
    }
    private static func item(_ row: [String]) -> KnowledgeItem? {
        guard let id = UUID(uuidString: row[0]), let category = UUID(uuidString: row[3]),
              let revision = Int(row[8]), let time = Double(row[9]),
              let status = KnowledgeIndexingStatus(rawValue: row[10]) else { return nil }
        return KnowledgeItem(id: id, title: row[1], text: row[2], categoryID: category,
                             sourceKey: row[4], sourceKind: row[5], sourceURL: row[6].isEmpty ? nil : URL(string: row[6]),
                             contentHash: row[7], revision: revision, updatedAt: Date(timeIntervalSince1970: time), indexingStatus: status)
    }
    @discardableResult public func upsert(title: String, text: String, categoryID: UUID,
                                         sourceKey: String? = nil, sourceKind: String = "note", sourceURL: URL? = nil,
                                         id: UUID? = nil) throws -> KnowledgeItem {
        try open()
        return try transaction {
            var count = try chunkCount()
            return try save(title: title, text: text, categoryID: categoryID,
                sourceKey: sourceKey, kind: sourceKind, url: sourceURL, id: id, managed: false, chunkCount: &count)
        }
    }
    private func save(title: String, text: String, categoryID: UUID, sourceKey: String?,
                      kind: String, url: URL?, id: UUID?, managed: Bool, chunkCount: inout Int) throws -> KnowledgeItem {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 500, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 8 * 1_024 * 1_024,
              try !rows("SELECT 1 FROM categories WHERE id=?", [.text(categoryID.uuidString)]).isEmpty else { throw KnowledgeError.invalidInput }
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let existing = try existingItem(id: id, sourceKey: sourceKey)
        if existing == nil, sourceKey == nil,
           let duplicate = try rows("SELECT \(Self.itemColumns) FROM items WHERE hash=? AND category=? AND substr(source_key,1,5) != 'sync:' ORDER BY updated DESC,id LIMIT 1",
                                    [.text(hash), .text(categoryID.uuidString)]).first.flatMap(Self.item) { return duplicate }
        if let existing, existing.contentHash == hash, existing.title == title,
           existing.categoryID == categoryID, existing.sourceKind == kind, existing.sourceURL == url { return existing }
        let chunks = try kind == "session-document" ? StructuredDocumentChunker.chunks(text) : DocumentTextChunker().paragraphChunks(in: text)
        guard !chunks.isEmpty else { throw KnowledgeError.invalidInput }
        let itemID = existing?.id ?? id ?? UUID()
        let previousCount = Int(try rows("SELECT COUNT(*) FROM chunks WHERE item_id=?", [.text(itemID.uuidString)]).first?.first ?? "0") ?? 0
        guard chunks.count <= Self.maximumChunks - (chunkCount - previousCount) else { throw KnowledgeError.capacityReached }
        chunkCount += chunks.count - previousCount
        let key = existing?.sourceKey ?? sourceKey ?? "manual:\(itemID.uuidString)"
        let revision = (existing?.revision ?? 0) + 1
        let item = KnowledgeItem(id: itemID, title: title, text: text, categoryID: categoryID, sourceKey: key,
                                 sourceKind: kind, sourceURL: url, contentHash: hash, revision: revision,
                                 updatedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970), indexingStatus: .pending)
        try removeChunks(itemID)
        try execute("INSERT INTO items(id,title,text,category,source_key,kind,url,hash,revision,updated,status,managed) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,text=excluded.text,category=excluded.category,kind=excluded.kind,url=excluded.url,hash=excluded.hash,revision=excluded.revision,updated=excluded.updated,status=excluded.status", [
            .text(itemID.uuidString), .text(title), .text(text), .text(categoryID.uuidString), .text(key), .text(kind),
            url.map { .text($0.absoluteString) } ?? .null, .text(hash), .integer(revision), .real(item.updatedAt.timeIntervalSince1970), .text("pending"), .integer(managed ? 1 : 0)])
        for (ordinal, chunk) in chunks.enumerated() {
            let chunkID = DocumentIdentity.id("\(itemID):\(ordinal):\(chunk)").uuidString
            try execute("INSERT INTO chunks(id,item_id,ordinal,text) VALUES(?,?,?,?)", [.text(chunkID), .text(itemID.uuidString), .integer(ordinal), .text(chunk)])
            try execute("INSERT INTO chunk_search(chunk_id,text) VALUES(?,?)", [.text(chunkID), .text(chunk)])
        }
        if kind == "session-document" {
            try execute("INSERT OR REPLACE INTO document_indexes(item_id,revision,version,text) VALUES(?,?,?,?)",
                        [.text(itemID.uuidString), .integer(revision), .integer(StructuredDocumentChunker.version), .text(text)])
            try replaceDocumentPassageLinks(itemID: itemID, revision: revision)
        }
        return item
    }
    private func removeChunks(_ id: UUID) throws {
        try execute("DELETE FROM document_passage_links WHERE document_id=?", [.text(id.uuidString)])
        try execute("DELETE FROM document_link_indexes WHERE item_id=?", [.text(id.uuidString)])
        try execute("DELETE FROM chunk_search WHERE chunk_id IN (SELECT id FROM chunks WHERE item_id=?)", [.text(id.uuidString)])
        try execute("DELETE FROM chunks WHERE item_id=?", [.text(id.uuidString)])
    }
    public func deleteItem(id: UUID) throws {
        try open()
        try transaction { try removeChunks(id); try execute("DELETE FROM items WHERE id=?", [.text(id.uuidString)]) }
    }
    public func moveItem(id: UUID, categoryID: UUID) throws {
        try open()
        guard try categories().contains(where: { $0.id == categoryID }) else { throw KnowledgeError.invalidInput }
        try execute("UPDATE items SET category=?,updated=? WHERE id=?", [.text(categoryID.uuidString), .real(Date().timeIntervalSince1970), .text(id.uuidString)])
    }
    public func reconcile(sources: [KnowledgeSourceRecord]) throws {
        try open()
        guard Set(sources.map(\.sourceKey)).count == sources.count, sources.allSatisfy({ !$0.sourceKey.isEmpty }) else { throw KnowledgeError.invalidInput }
        try transaction {
            let desired = Set(sources.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { "sync:" + $0.sourceKey })
            for row in try rows("SELECT id,source_key FROM items WHERE managed=1") where !desired.contains(row[1]) {
                if let id = UUID(uuidString: row[0]) { try removeChunks(id); try execute("DELETE FROM items WHERE id=?", [.text(row[0])]) }
            }
            var count = try chunkCount()
            for source in sources where !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try Task.checkCancellation()
                let key = "sync:" + source.sourceKey
                let existingCategory = try rows("SELECT category FROM items WHERE source_key=?", [.text(key)]).first?.first
                    .flatMap(UUID.init(uuidString:))
                let categoryID = try existingCategory ?? addCategory(name: source.categoryName).id
                _ = try save(title: source.title, text: source.text, categoryID: categoryID, sourceKey: key,
                             kind: source.kind, url: nil, id: nil, managed: true, chunkCount: &count)
            }
        }
    }
    public func pendingDocuments() throws -> [KnowledgeIndexingDocument] {
        try open()
        return try items().filter { $0.indexingStatus != .indexed }.map { item in
            KnowledgeIndexingDocument(itemID: item.id, revision: item.revision,
                chunks: try rows("SELECT text FROM chunks WHERE item_id=? AND vector IS NULL ORDER BY ordinal", [.text(item.id.uuidString)]).map { $0[0] },
                chunkIDs: try rows("SELECT id FROM chunks WHERE item_id=? AND vector IS NULL ORDER BY ordinal", [.text(item.id.uuidString)]).compactMap { UUID(uuidString: $0[0]) })
        }
    }
    @discardableResult public func setEmbeddingBatch(itemID: UUID, revision: Int, identity: String,
                                                      chunkIDs: [UUID], vectors: [[Float]]) throws -> Bool {
        try open()
        guard !chunkIDs.isEmpty, chunkIDs.count == vectors.count else { return false }
        let dimension = try validateKnowledgeVectors(vectors, count: chunkIDs.count)
        return try transaction {
            guard try rows("SELECT 1 FROM items WHERE id=? AND revision=? AND status!='indexed'",
                           [.text(itemID.uuidString), .integer(revision)]).first != nil,
                  let profile = try rows("SELECT identity,dimensions FROM embedding_profile WHERE id=1").first,
                  profile[0] == identity, Int(profile[1]) == dimension else { return false }
            let expected = Set(chunkIDs.map(\.uuidString))
            let current = try rows("SELECT id FROM chunks WHERE item_id=? AND vector IS NULL AND id IN (" + chunkIDs.map { _ in "?" }.joined(separator: ",") + ")",
                [.text(itemID.uuidString)] + chunkIDs.map { .text($0.uuidString) })
            guard Set(current.map { $0[0] }) == expected else { return false }
            for (id, vector) in zip(chunkIDs, vectors) {
                try execute("UPDATE chunks SET vector=? WHERE item_id=? AND id=? AND vector IS NULL",
                    [.data(try JSONEncoder().encode(vector)), .text(itemID.uuidString), .text(id.uuidString)])
            }
            return true
        }
    }
    @discardableResult public func finishEmbedding(itemID: UUID, revision: Int) throws -> Bool {
        try open()
        return try transaction {
            guard try rows("SELECT 1 FROM items WHERE id=? AND revision=? AND status!='indexed'",
                           [.text(itemID.uuidString), .integer(revision)]).first != nil,
                  try rows("SELECT 1 FROM chunks WHERE item_id=? AND vector IS NULL LIMIT 1", [.text(itemID.uuidString)]).isEmpty else { return false }
            try execute("UPDATE items SET status='indexed' WHERE id=? AND revision=?", [.text(itemID.uuidString), .integer(revision)])
            return true
        }
    }
    public func markFailed(itemID: UUID, revision: Int) throws {
        try open()
        try execute("UPDATE items SET status='failed' WHERE id=? AND revision=? AND status!='indexed'", [.text(itemID.uuidString), .integer(revision)])
    }
    /// A changed identity invalidates all vectors in one transaction before any new comparison.
    public func prepareEmbeddingIdentity(_ identity: String) throws {
        try open()
        try Task.checkCancellation()
        if let profile = try rows("SELECT identity FROM embedding_profile WHERE id=1").first, profile[0] != identity {
            try transaction {
                try execute("UPDATE chunks SET vector=NULL")
                try execute("UPDATE items SET status='pending'")
                try execute("DELETE FROM embedding_profile")
            }
        }
    }
    /// Reconciles only a successfully observed model/vector pair. Inference failures do not
    /// call this method, so temporary outages cannot discard a working semantic index.
    @discardableResult public func reconcileEmbeddingProfile(identity: String, dimensions: Int) throws -> Bool {
        try open()
        try Task.checkCancellation()
        guard !identity.isEmpty, (1...8_192).contains(dimensions) else { throw KnowledgeError.invalidEmbedding }
        return try transaction {
            let profile = try rows("SELECT identity,dimensions FROM embedding_profile WHERE id=1").first
            let invalidated = profile.map { $0[0] != identity || Int($0[1]) != dimensions } ?? false
            if invalidated {
                try execute("UPDATE chunks SET vector=NULL")
                try execute("UPDATE items SET status='pending'")
            }
            try execute("INSERT OR REPLACE INTO embedding_profile(id,identity,dimensions) VALUES(1,?,?)",
                        [.text(identity), .integer(dimensions)])
            return invalidated
        }
    }
    public func embeddingProbeText() throws -> String? {
        try open()
        return try rows("SELECT text FROM chunks ORDER BY item_id,ordinal LIMIT 1").first?.first
    }
    func semanticIndexChunks(after cursor: String?, limit: Int = 64) throws -> [SemanticIndexChunk] {
        try open()
        guard let model = try rows("SELECT identity FROM embedding_profile WHERE id=1").first?.first else { return [] }
        let sql = """
            SELECT c.id,c.item_id,i.revision,i.source_key,c.text,hex(c.vector)
            FROM chunks c JOIN items i ON i.id=c.item_id
            WHERE c.vector IS NOT NULL AND i.status='indexed' AND (? IS NULL OR c.id > ?)
            ORDER BY c.id LIMIT ?
            """
        return try rows(sql, [cursor.map(KnowledgeSQLValue.text) ?? .null,
                              cursor.map(KnowledgeSQLValue.text) ?? .null,
                              .integer(max(1, min(limit, 256)))]) .compactMap { row in
            guard row.count == 6, let chunkID = UUID(uuidString: row[0]),
                  let documentID = UUID(uuidString: row[1]), let revision = Int(row[2]),
                  let bytes = Self.decodeHex(row[5]), let vector = try? JSONDecoder().decode([Float].self, from: bytes) else { return nil }
            return SemanticIndexChunk(id: chunkID, documentID: documentID,
                sessionID: Self.sessionID(from: row[3]), revision: revision,
                generation: StructuredDocumentChunker.version, model: model, text: row[4], vector: vector)
        }
    }
    private static func decodeHex(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(); data.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let value = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(value); index = next
        }
        return data
    }
    private static func sessionID(from sourceKey: String) -> UUID? {
        let prefix = "session-file:"
        guard sourceKey.hasPrefix(prefix), let boundary = sourceKey.dropFirst(prefix.count).firstIndex(of: ":") else { return nil }
        return UUID(uuidString: String(sourceKey.dropFirst(prefix.count)[..<boundary]))
    }
    @discardableResult public func setEmbeddings(itemID: UUID, revision: Int, identity: String,
                                               vectors: [[Float]], requireCurrentProfile: Bool = false, expectedChunkIDs: [UUID]? = nil) throws -> Bool {
        try open()
        try Task.checkCancellation()
        return try transaction {
            // Acquire the write reservation before reading generation or chunk IDs. Another
            // connection cannot replace text between these guards and the vector writes.
            let currentRevision = try rows("SELECT revision FROM items WHERE id=?", [.text(itemID.uuidString)]).first?.first
            guard currentRevision.flatMap(Int.init) == revision else { return false }
            let chunks = try rows("SELECT id FROM chunks WHERE item_id=? ORDER BY ordinal", [.text(itemID.uuidString)])
            if let expectedChunkIDs, chunks.map({ $0[0] }) != expectedChunkIDs.map(\.uuidString) { return false }
            let dimension = try validateKnowledgeVectors(vectors, count: chunks.count)
            let profile = try rows("SELECT identity,dimensions FROM embedding_profile WHERE id=1").first
            if requireCurrentProfile,
               profile == nil || profile?[0] != identity || Int(profile?[1] ?? "") != dimension { return false }
            if let profile, profile[0] != identity || Int(profile[1]) != dimension {
                try execute("UPDATE chunks SET vector=NULL")
                try execute("UPDATE items SET status='pending'")
            }
            try execute("INSERT OR REPLACE INTO embedding_profile(id,identity,dimensions) VALUES(1,?,?)", [.text(identity), .integer(dimension)])
            for (chunk, vector) in zip(chunks, vectors) {
                try execute("UPDATE chunks SET vector=? WHERE id=?", [.data(try JSONEncoder().encode(vector)), .text(chunk[0])])
            }
            try execute("UPDATE items SET status='indexed' WHERE id=? AND revision=?", [.text(itemID.uuidString), .integer(revision)])
            return true
        }
    }
    func documentFocus(sessionID: UUID) throws -> DocumentFocus? {
        try open()
        guard let json = try rows("SELECT json FROM document_focus WHERE session_id=?", [.text(sessionID.uuidString)]).first?.first,
              let focus = try? JSONDecoder().decode(DocumentFocus.self, from: Data(json.utf8)) else { return nil }
        guard try existingItem(id: focus.documentID) != nil else {
            try execute("DELETE FROM document_focus WHERE session_id=?", [.text(sessionID.uuidString)])
            return nil
        }
        return focus
    }
    func saveDocumentFocus(_ focus: DocumentFocus, sessionID: UUID) throws {
        try open()
        let json = String(decoding: try JSONEncoder().encode(focus), as: UTF8.self)
        try execute("INSERT OR REPLACE INTO document_focus(session_id,json) VALUES(?,?)", [.text(sessionID.uuidString), .text(json)])
    }
    func latestDocument(in ids: Set<UUID>) throws -> UUID? {
        try open()
        // rowid tracks upload creation; moving a category does not change it.
        return try rows("SELECT id FROM items ORDER BY rowid DESC").compactMap { UUID(uuidString: $0[0]) }.first { ids.contains($0) }
    }
    func documentsNeedingStructure(retryUnavailable: Bool = false) throws -> [KnowledgeItem] {
        try open()
        let current = Dictionary(uniqueKeysWithValues: try rows("SELECT item_id,revision FROM document_indexes WHERE version=?", [.integer(StructuredDocumentChunker.version)]).map { ($0[0], Int($0[1])) })
        let unavailable = retryUnavailable ? Set(try rows("SELECT item_id FROM document_indexes WHERE text LIKE '%[Extraction note:%'").map { $0[0] }) : []
        return try items().filter { $0.sourceKind == "session-document" && (current[$0.id.uuidString] != $0.revision || unavailable.contains($0.id.uuidString)) }
    }
    /// Build before the transaction. A crash keeps either the old usable index or the complete replacement.
    @discardableResult func rebuildDocumentIndex(itemID: UUID, revision: Int, text: String) throws -> Bool {
        try open()
        let chunks = try StructuredDocumentChunker.chunks(text)
        guard !chunks.isEmpty else { throw KnowledgeError.invalidInput }
        return try transaction {
            guard let item = try existingItem(id: itemID), item.revision == revision else { return false }
            if let current = try rows("SELECT text FROM document_indexes WHERE item_id=? AND revision=? AND version=?",
                [.text(itemID.uuidString), .integer(revision), .integer(StructuredDocumentChunker.version)]).first?.first, current == text { return false }
            let previous = Int(try rows("SELECT COUNT(*) FROM chunks WHERE item_id=?", [.text(itemID.uuidString)]).first?.first ?? "0") ?? 0
            guard try chunkCount() - previous + chunks.count <= Self.maximumChunks else { throw KnowledgeError.capacityReached }
            try Task.checkCancellation()
            try removeChunks(itemID)
            for (ordinal, text) in chunks.enumerated() {
                let id = DocumentIdentity.id("\(itemID):\(ordinal):\(text)").uuidString
                try execute("INSERT INTO chunks(id,item_id,ordinal,text) VALUES(?,?,?,?)", [.text(id), .text(itemID.uuidString), .integer(ordinal), .text(text)])
                try execute("INSERT INTO chunk_search(chunk_id,text) VALUES(?,?)", [.text(id), .text(text)])
            }
            try execute("UPDATE items SET status='pending' WHERE id=?", [.text(itemID.uuidString)])
            try execute("INSERT OR REPLACE INTO document_indexes(item_id,revision,version,text) VALUES(?,?,?,?)",
                        [.text(itemID.uuidString), .integer(revision), .integer(StructuredDocumentChunker.version), .text(text)])
            try replaceDocumentPassageLinks(itemID: itemID, revision: revision)
            return true
        }
    }

    func documentsNeedingPassageLinks() throws -> [KnowledgeItem] {
        try open()
        let indexed = Dictionary(uniqueKeysWithValues: try rows("SELECT item_id,revision FROM document_link_indexes WHERE version=?", [.integer(DocumentPassageLinkBuilder.version)])
            .map { ($0[0], Int($0[1]) ?? -1) })
        return try items().filter { $0.sourceKind == "session-document" && indexed[$0.id.uuidString] != $0.revision }
    }

    @discardableResult func rebuildDocumentPassageLinks(itemID: UUID, revision: Int) throws -> Bool {
        try open()
        return try transaction {
            guard let item = try existingItem(id: itemID), item.sourceKind == "session-document", item.revision == revision else {
                return false
            }
            try replaceDocumentPassageLinks(itemID: itemID, revision: revision)
            return true
        }
    }

    private func replaceDocumentPassageLinks(itemID: UUID, revision: Int) throws {
        guard let item = try existingItem(id: itemID), item.sourceKind == "session-document", item.revision == revision else { return }
        let rows = try rows("SELECT id,ordinal,text FROM chunks WHERE item_id=? ORDER BY ordinal", [.text(itemID.uuidString)])
        var location: String?
        let chunks = rows.compactMap { row -> DocumentChunk? in
            guard let id = UUID(uuidString: row[0]), let ordinal = Int(row[1]) else { return nil }
            location = StructuredDocumentChunker.location(row[2], previous: location)
            return DocumentChunk(id: id, documentID: itemID, filename: item.title, index: ordinal,
                text: row[2], sourceURL: item.sourceURL, location: location)
        }
        let links = DocumentPassageLinkBuilder.build(documentID: itemID, chunks: chunks)
        try execute("DELETE FROM document_passage_links WHERE document_id=?", [.text(itemID.uuidString)])
        for link in links {
            try execute("INSERT INTO document_passage_links(document_id,revision,source_chunk_id,target_chunk_id,kind,source_text) VALUES(?,?,?,?,?,?)",
                [.text(itemID.uuidString), .integer(revision), .text(link.sourceChunkID.uuidString),
                 .text(link.targetChunkID.uuidString), .text(link.kind), .text(link.sourceText)])
        }
        try execute("INSERT OR REPLACE INTO document_link_indexes(item_id,revision,version) VALUES(?,?,?)",
            [.text(itemID.uuidString), .integer(revision), .integer(DocumentPassageLinkBuilder.version)])
    }

    func linkedDocumentChunks(documentID: UUID, revision: Int, sourceChunkIDs: [UUID], maximumResults: Int = 8) throws -> [DocumentChunk] {
        try open()
        guard maximumResults > 0, !sourceChunkIDs.isEmpty,
              let item = try existingItem(id: documentID), item.sourceKind == "session-document", item.revision == revision,
              let index = try rows("SELECT revision FROM document_link_indexes WHERE item_id=? AND version=?",
                [.text(documentID.uuidString), .integer(DocumentPassageLinkBuilder.version)]).first?.first,
              Int(index) == revision else { return [] }
        let currentChunks = try documentChunks(itemID: documentID)
        let chunksByID = Dictionary(uniqueKeysWithValues: currentChunks.map { ($0.id, $0) })
        var result: [DocumentChunk] = []
        var seen = Set<UUID>()
        for sourceID in sourceChunkIDs {
            guard result.count < maximumResults, chunksByID[sourceID] != nil else { continue }
            let targets = try rows("SELECT target_chunk_id FROM document_passage_links WHERE document_id=? AND revision=? AND source_chunk_id=? ORDER BY rowid LIMIT ?",
                [.text(documentID.uuidString), .integer(revision), .text(sourceID.uuidString), .integer(maximumResults - result.count)])
            for target in targets {
                guard let id = UUID(uuidString: target[0]), seen.insert(id).inserted, let chunk = chunksByID[id] else { continue }
                result.append(chunk)
            }
        }
        return result
    }

    func documentPassageLinks(documentID: UUID, revision: Int) throws -> [DocumentPassageLink] {
        try open()
        return try rows("SELECT source_chunk_id,target_chunk_id,kind,source_text FROM document_passage_links WHERE document_id=? AND revision=? ORDER BY rowid",
            [.text(documentID.uuidString), .integer(revision)]).compactMap { row in
                guard let source = UUID(uuidString: row[0]), let target = UUID(uuidString: row[1]) else { return nil }
                return DocumentPassageLink(sourceChunkID: source, targetChunkID: target, kind: row[2], sourceText: row[3])
            }
    }

    func relatedDocumentChunks(seedChunkIDs: [UUID], documentIDs: Set<UUID>, excludedChunkIDs: Set<UUID>,
                               candidateChunkIDs: Set<UUID>? = nil, minimumSimilarity: Double = 0.65,
                               maximumResults: Int = 4, characterBudget: Int = 3_200) throws -> [RelatedDocumentMatch] {
        try open()
        guard !seedChunkIDs.isEmpty, !documentIDs.isEmpty, maximumResults > 0,
              let profile = try rows("SELECT identity,dimensions FROM embedding_profile WHERE id=1").first,
              let dimensions = Int(profile[1]) else { return [] }
        if let candidateChunkIDs, candidateChunkIDs.isEmpty { return [] }

        let scopedIDs = documentIDs.sorted { $0.uuidString < $1.uuidString }
        let seedIDs = Array(Set(seedChunkIDs)).sorted { $0.uuidString < $1.uuidString }
        let seedQuery = "SELECT id,vector FROM chunks WHERE item_id IN (" +
            scopedIDs.map { _ in "?" }.joined(separator: ",") + ") AND id IN (" +
            seedIDs.map { _ in "?" }.joined(separator: ",") + ") AND vector IS NOT NULL"
        var seedBindings = scopedIDs.map { KnowledgeSQLValue.text($0.uuidString) }
        seedBindings += seedIDs.map { KnowledgeSQLValue.text($0.uuidString) }
        var seedVectors: [(UUID, [Float])] = []
        try each(seedQuery, seedBindings) { statement in
            guard let rawID = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: rawID)),
                  let bytes = sqlite3_column_blob(statement, 1) else { return }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            guard let vector = try? JSONDecoder().decode([Float].self, from: data), vector.count == dimensions,
                  vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else { return }
            seedVectors.append((id, vector))
        }
        guard !seedVectors.isEmpty else { return [] }

        var excluded = excludedChunkIDs
        excluded.formUnion(seedIDs)
        let excludedIDs = excluded.sorted { $0.uuidString < $1.uuidString }
        var candidateSQL = "SELECT c.id,c.item_id,c.ordinal,c.text,c.vector FROM chunks c " +
            "JOIN items i ON i.id=c.item_id WHERE i.kind='session-document' AND c.item_id IN (" +
            scopedIDs.map { _ in "?" }.joined(separator: ",") + ") AND c.vector IS NOT NULL"
        var candidateBindings = scopedIDs.map { KnowledgeSQLValue.text($0.uuidString) }
        if !excludedIDs.isEmpty {
            candidateSQL += " AND c.id NOT IN (" + excludedIDs.map { _ in "?" }.joined(separator: ",") + ")"
            candidateBindings += excludedIDs.map { .text($0.uuidString) }
        }
        if let candidateChunkIDs {
            let ids = candidateChunkIDs.sorted { $0.uuidString < $1.uuidString }
            candidateSQL += " AND c.id IN (" + ids.map { _ in "?" }.joined(separator: ",") + ")"
            candidateBindings += ids.map { .text($0.uuidString) }
        }

        let itemsByID = Dictionary(uniqueKeysWithValues: try items().filter { documentIDs.contains($0.id) }.map { ($0.id, $0) })
        var ranked: [(RelatedDocumentMatch, Int)] = []
        var remaining = min(3_200, max(0, characterBudget))
        try each(candidateSQL, candidateBindings) { statement in
            try Task.checkCancellation()
            guard let rawID = sqlite3_column_text(statement, 0), let chunkID = UUID(uuidString: String(cString: rawID)),
                  let rawItemID = sqlite3_column_text(statement, 1), let itemID = UUID(uuidString: String(cString: rawItemID)),
                  let item = itemsByID[itemID], let rawText = sqlite3_column_text(statement, 3),
                  let bytes = sqlite3_column_blob(statement, 4) else { return }
            let text = String(cString: rawText)
            guard !text.isEmpty, text.count <= remaining else { return }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 4)))
            guard let vector = try? JSONDecoder().decode([Float].self, from: data), vector.count == dimensions,
                  vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else { return }
            var best: (UUID, Double)?
            for (seedID, seedVector) in seedVectors {
                let similarity = Self.cosine(seedVector, vector)
                if best == nil || similarity > best!.1 { best = (seedID, similarity) }
            }
            guard let best, best.1 >= minimumSimilarity else { return }
            let index = Int(sqlite3_column_int(statement, 2))
            let chunk = DocumentChunk(id: chunkID, documentID: itemID, filename: item.title, index: index,
                text: text, sourceURL: item.sourceURL, location: StructuredDocumentChunker.location(text))
            ranked.append((RelatedDocumentMatch(chunk: chunk, seedChunkID: best.0, similarity: best.1), text.count))
        }
        ranked.sort {
            if $0.0.similarity != $1.0.similarity { return $0.0.similarity > $1.0.similarity }
            return $0.0.chunk.id.uuidString < $1.0.chunk.id.uuidString
        }
        var result: [RelatedDocumentMatch] = []
        for (match, length) in ranked where result.count < min(4, maximumResults) && length <= remaining {
            result.append(match)
            remaining -= length
        }
        return result
    }

    func documentVectorSeeds(chunkIDs: [UUID], documentIDs: Set<UUID>) throws
        -> (identity: String, dimensions: Int, vectors: [UUID: [Float]])? {
        try open()
        guard !chunkIDs.isEmpty, !documentIDs.isEmpty,
              let profile = try rows("SELECT identity,dimensions FROM embedding_profile WHERE id=1").first,
              let dimensions = Int(profile[1]) else { return nil }
        let scopedIDs = documentIDs.sorted { $0.uuidString < $1.uuidString }
        let seedIDs = Array(Set(chunkIDs)).sorted { $0.uuidString < $1.uuidString }
        let sql = "SELECT c.id,c.vector FROM chunks c JOIN items i ON i.id=c.item_id " +
            "WHERE i.kind='session-document' AND c.item_id IN (" + scopedIDs.map { _ in "?" }.joined(separator: ",") +
            ") AND c.id IN (" + seedIDs.map { _ in "?" }.joined(separator: ",") + ") AND c.vector IS NOT NULL"
        var bindings = scopedIDs.map { KnowledgeSQLValue.text($0.uuidString) }
        bindings += seedIDs.map { KnowledgeSQLValue.text($0.uuidString) }
        var vectors: [UUID: [Float]] = [:]
        try each(sql, bindings) { statement in
            guard let rawID = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: rawID)),
                  let bytes = sqlite3_column_blob(statement, 1) else { return }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            guard let vector = try? JSONDecoder().decode([Float].self, from: data), vector.count == dimensions,
                  vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else { return }
            vectors[id] = vector
        }
        return vectors.isEmpty ? nil : (profile[0], dimensions, vectors)
    }

    func documentChunks(itemID: UUID) throws -> [DocumentChunk] {
        try open()
        guard let item = try existingItem(id: itemID) else { return [] }
        var location: String?
        return try rows("SELECT id,ordinal,text FROM chunks WHERE item_id=? ORDER BY ordinal", [.text(itemID.uuidString)]).compactMap { row in
            guard let id = UUID(uuidString: row[0]), let ordinal = Int(row[1]) else { return nil }
            location = StructuredDocumentChunker.location(row[2], previous: location)
            return DocumentChunk(id: id, documentID: item.id, filename: item.title, index: ordinal,
                                 text: row[2], sourceURL: item.sourceURL, location: location)
        }
    }
    public func search(query: String, categoryID: UUID? = nil, vector: [Float]? = nil,
                       identity: String? = nil, semanticThreshold: Double = 0.45, documentIDs: Set<UUID>? = nil,
                       semanticCandidates: [UUID]? = nil,
                       maximumResults: Int = 5, characterBudget: Int = 6_000) throws -> [KnowledgeMatch] {
        try open()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 2_000 else { return [] }
        let itemsByID = Dictionary(uniqueKeysWithValues: try items().map { ($0.id, $0) })
        let stopwords: Set<String> = ["a", "an", "the", "is", "are", "was", "were", "be", "been", "being", "what", "which", "who", "when", "where", "why", "how", "do", "does", "did", "can", "could", "would", "should", "will", "shall", "to", "of", "in", "on", "at", "for", "from", "and", "or", "it", "its", "i", "me", "my", "you", "your", "we", "our", "tell", "please", "about", "with", "this", "that", "these", "those", "have", "has", "had", "not", "ما", "ماذا", "من", "متى", "اين", "أين", "كيف", "لماذا", "هل", "هو", "هي", "في", "على", "عن", "الى", "إلى", "و", "او", "أو", "هذا", "هذه", "التي", "الذي", "لي", "انا", "أنا"]
        let tokens = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { !stopwords.contains(String($0)) }.prefix(40)
        var scores: [String: Double] = [:]
        var semanticScores: [String: Double] = [:]
        if let semanticCandidates {
            for (rank, id) in semanticCandidates.enumerated() { semanticScores[id.uuidString] = 1 / Double(60 + rank + 1) }
        }
        if !tokens.isEmpty {
            // Only generated quoted tokens enter FTS syntax; user operators never execute.
            let expression = tokens.map { "\"" + $0 + "\"" }.joined(separator: " OR ")
            var bindings: [KnowledgeSQLValue] = [.text(expression)]
            var filter = ""
            if let categoryID { filter = " AND chunk_id IN (SELECT chunks.id FROM chunks JOIN items ON items.id=chunks.item_id WHERE items.category=?)"; bindings.append(.text(categoryID.uuidString)) }
            if let documentIDs {
                guard !documentIDs.isEmpty else { return [] }
                filter += " AND chunk_id IN (SELECT id FROM chunks WHERE item_id IN (" + documentIDs.map { _ in "?" }.joined(separator: ",") + "))"
                bindings += documentIDs.sorted { $0.uuidString < $1.uuidString }.map { .text($0.uuidString) }
            }
            for (rank, row) in try rows("SELECT chunk_id FROM chunk_search WHERE chunk_search MATCH ?" + filter + " ORDER BY bm25(chunk_search) LIMIT 100", bindings).enumerated() {
                scores[row[0]] = 1 / Double(60 + rank + 1)
            }
        }
        var candidates: [KnowledgeMatch] = []
        let profile = try rows("SELECT identity,dimensions FROM embedding_profile WHERE id=1").first
        let canCompare = vector.map { candidate in candidate.allSatisfy(\.isFinite) && candidate.contains(where: { $0 != 0 }) && profile?.first == identity && profile?.last == String(candidate.count) } ?? false
        if semanticCandidates != nil {
            for (rank, entry) in semanticScores.sorted(by: { $0.value > $1.value }).enumerated() {
                scores[entry.key, default: 0] += 1 / Double(60 + rank + 1)
            }
        }
        var sql = "SELECT id,item_id,text,vector FROM chunks"
        var candidateBindings: [KnowledgeSQLValue] = []
        let useRankedCandidateSet = semanticCandidates != nil || vector == nil
        if useRankedCandidateSet {
            let ids = scores.keys.sorted()
            guard !ids.isEmpty else { return [] }
            sql += " WHERE id IN (" + ids.map { _ in "?" }.joined(separator: ",") + ")"
            candidateBindings = ids.map { .text($0) }
        } else {
            sql += " ORDER BY item_id,ordinal LIMIT \(Self.maximumChunks)"
        }
        try each(sql, candidateBindings) { statement in
            try Task.checkCancellation()
            let chunkID = String(cString: sqlite3_column_text(statement, 0))
            guard let itemID = UUID(uuidString: String(cString: sqlite3_column_text(statement, 1))),
                  let item = itemsByID[itemID], (categoryID == nil || item.categoryID == categoryID),
                  documentIDs?.contains(itemID) ?? true else { return }
            var score = scores[chunkID]

            if semanticCandidates == nil, canCompare, let vector, let bytes = sqlite3_column_blob(statement, 3) {
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 3)))
                if let stored = try? JSONDecoder().decode([Float].self, from: data), stored.count == vector.count {
                    let cosine = Self.cosine(vector, stored)
                    if cosine >= semanticThreshold { semanticScores[chunkID] = cosine; score = score ?? 0 }
                }
            }
            guard let score, let id = UUID(uuidString: chunkID) else { return }
            candidates.append(KnowledgeMatch(id: id, itemID: itemID, title: item.title, categoryID: item.categoryID,
                sourceKey: item.sourceKey, sourceKind: item.sourceKind, sourceURL: item.sourceURL,
                text: String(cString: sqlite3_column_text(statement, 2)), score: score))
        }
        let semanticRanks = semanticScores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        if semanticCandidates == nil {
            for (rank, entry) in semanticRanks.prefix(100).enumerated() {
                scores[entry.key, default: 0] += 1 / Double(60 + rank + 1)
            }
        }
        candidates = candidates.compactMap { match in
            guard let score = scores[match.id.uuidString] else { return nil }
            return KnowledgeMatch(id: match.id, itemID: match.itemID, title: match.title, categoryID: match.categoryID,
                sourceKey: match.sourceKey, sourceKind: match.sourceKind, sourceURL: match.sourceURL, text: match.text, score: score)
        }
        var length = 0
        return candidates.sorted { $0.score == $1.score ? $0.id.uuidString < $1.id.uuidString : $0.score > $1.score }.filter {
            guard length + $0.text.count <= characterBudget else { return false }
            length += $0.text.count; return true
        }.prefix(max(0, min(100, maximumResults))).map { $0 }
    }
    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot = 0.0, aa = 0.0, bb = 0.0
        for (x, y) in zip(a, b) { let x = Double(x), y = Double(y); dot += x * y; aa += x * x; bb += y * y }
        guard aa > 0, bb > 0 else { return -1 }
        return dot / (aa.squareRoot() * bb.squareRoot())
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func execute(_ sql: String, _ values: [KnowledgeSQLValue] = []) throws {
        try each(sql, values) { _ in }
    }
    private func rows(_ sql: String, _ values: [KnowledgeSQLValue] = []) throws -> [[String]] {
        var result: [[String]] = []
        try each(sql, values) { statement in
            result.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_type(statement, index) == SQLITE_FLOAT
                    ? String(sqlite3_column_double(statement, index))
                    : (sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "")
            })
        }
        return result
    }
    private func each(_ sql: String, _ values: [KnowledgeSQLValue] = [], body: (OpaquePointer) throws -> Void) throws {
        guard let database else { throw KnowledgeError.database("Not open") }
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(database.handle, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else {
            throw KnowledgeError.database(String(cString: sqlite3_errmsg(database.handle)))
        }
        defer { sqlite3_finalize(pointer) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(pointer, index, text, -1, transient)
            case .integer(let value): result = sqlite3_bind_int64(pointer, index, sqlite3_int64(value))
            case .real(let value): result = sqlite3_bind_double(pointer, index, value)
            case .data(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(pointer, index, $0.baseAddress, Int32($0.count), transient) }
            case .null: result = sqlite3_bind_null(pointer, index)
            }
            guard result == SQLITE_OK else { throw KnowledgeError.database("Could not bind database value") }
        }
        while true {
            let result = sqlite3_step(pointer)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw KnowledgeError.database(String(cString: sqlite3_errmsg(database.handle))) }
            try body(pointer)
        }
    }
}
