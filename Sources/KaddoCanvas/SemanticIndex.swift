import Foundation
import PostgresNIO
import Logging

struct SemanticIndexChunk: Sendable {
    let id: UUID
    let documentID: UUID
    let sessionID: UUID?
    let revision: Int
    let generation: Int
    let model: String
    let text: String
    let vector: [Float]
}

/// Search and synchronization contract for rebuildable semantic storage.
protocol SemanticIndex: Sendable {
    func start() async throws
    func upsert(_ chunks: [SemanticIndexChunk]) async throws
    func search(vector: [Float], model: String, sessionID: UUID?, documentIDs: Set<UUID>?, limit: Int) async throws -> [UUID]
    func delete(documentID: UUID) async throws
}

/// Local pgvector index. Disabled unless KADDO_PGVECTOR=1; SQLite remains authoritative.
actor PostgresSemanticIndex: SemanticIndex {
    private let client: PostgresClient
    private let runner: Task<Void, Never>
    private var ready = false
    private let logger = Logger(label: "kaddo.pgvector")

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard environment["KADDO_PGVECTOR"] == "1" else { return nil }
        let host = environment["KADDO_PGVECTOR_HOST"] ?? "127.0.0.1"
        guard ["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
        var config = PostgresClient.Configuration(
            host: host,
            port: Int(environment["KADDO_PGVECTOR_PORT"] ?? "55432") ?? 55432,
            username: environment["KADDO_PGVECTOR_USER"] ?? "kaddo",
            password: environment["KADDO_PGVECTOR_PASSWORD"] ?? "kaddo-local",
            database: environment["KADDO_PGVECTOR_DATABASE"] ?? "kaddo",
            tls: .disable
        )
        config.options.maximumConnections = 3
        config.options.connectTimeout = .seconds(2)
        let client = PostgresClient(configuration: config)
        self.client = client
        self.runner = Task { await client.run() }
    }

    func start() async throws {
        guard !ready else { return }
        try await client.query("CREATE EXTENSION IF NOT EXISTS vector", logger: logger)
        try await client.query("""
            CREATE TABLE IF NOT EXISTS kaddo_semantic_chunks (
              chunk_id uuid PRIMARY KEY, document_id uuid NOT NULL, session_id uuid,
              source_revision integer NOT NULL, model_identity text NOT NULL,
              embedding vector(768) NOT NULL, indexed_at timestamptz NOT NULL DEFAULT now()
            )
            """, logger: logger)
        try await client.query("CREATE INDEX IF NOT EXISTS kaddo_semantic_chunks_embedding_hnsw ON kaddo_semantic_chunks USING hnsw (embedding vector_cosine_ops)", logger: logger)
        try await client.query("CREATE INDEX IF NOT EXISTS kaddo_semantic_chunks_scope ON kaddo_semantic_chunks (session_id, document_id)", logger: logger)
        try await client.query("ALTER TABLE kaddo_semantic_chunks ADD COLUMN IF NOT EXISTS index_generation integer NOT NULL DEFAULT 1", logger: logger)
        try await client.query("ALTER ROLE CURRENT_USER SET hnsw.iterative_scan = 'relaxed_order'", logger: logger)
        try await client.query("SET hnsw.iterative_scan = relaxed_order", logger: logger)
        ready = true
    }

    func upsert(_ chunks: [SemanticIndexChunk]) async throws {
        try await start()
        let valid = chunks.filter { $0.vector.count == 768 && $0.vector.allSatisfy(\.isFinite) }
        for start in stride(from: 0, to: valid.count, by: 64) {
            let batch = valid[start..<min(start + 64, valid.count)]
            let rows = batch.map { chunk -> String in
                let session = chunk.sessionID.map { "'\($0.uuidString)'" } ?? "NULL"
                let model = "'" + chunk.model.replacingOccurrences(of: "'", with: "''") + "'"
                let vector = "[" + chunk.vector.map { String($0) }.joined(separator: ",") + "]"
                return "('\(chunk.id.uuidString)','\(chunk.documentID.uuidString)',\(session),\(chunk.revision),\(chunk.generation),\(model),'\(vector)'::vector)"
            }.joined(separator: ",")
            let sql = """
                INSERT INTO kaddo_semantic_chunks (chunk_id, document_id, session_id, source_revision, index_generation, model_identity, embedding)
                VALUES \(rows)
                ON CONFLICT (chunk_id) DO UPDATE SET document_id=EXCLUDED.document_id,
                  session_id=EXCLUDED.session_id, source_revision=EXCLUDED.source_revision, index_generation=EXCLUDED.index_generation,
                  model_identity=EXCLUDED.model_identity, embedding=EXCLUDED.embedding, indexed_at=now()
                """
            try await client.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        }
    }

    func search(vector: [Float], model: String, sessionID: UUID?, documentIDs: Set<UUID>?, limit: Int) async throws -> [UUID] {
        try await start()
        guard vector.count == 768, vector.allSatisfy(\.isFinite) else { return [] }
        let queryVector = "[" + vector.map { String($0) }.joined(separator: ",") + "]"
        let rows: PostgresRowSequence
        if let documentIDs {
            guard !documentIDs.isEmpty else { return [] }
            let ids = documentIDs.sorted { $0.uuidString < $1.uuidString }
            let scopedIDs = ids.map { "'\($0.uuidString)'::uuid" }.joined(separator: ",")
            let sql = "SELECT chunk_id FROM kaddo_semantic_chunks WHERE model_identity = '\(model.replacingOccurrences(of: "'", with: "''"))' AND document_id IN (\(scopedIDs)) AND embedding IS NOT NULL ORDER BY embedding <=> '\(queryVector)'::vector LIMIT \(max(1, min(limit, 100)))"
            rows = try await client.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        } else if let sessionID {
            rows = try await client.query("""
                SELECT chunk_id FROM kaddo_semantic_chunks
                WHERE session_id = \(sessionID) AND model_identity = \(model)
                ORDER BY embedding <=> \(queryVector)::vector LIMIT \(max(1, min(limit, 100)))
                """, logger: logger)
        } else {
            rows = try await client.query("""
                SELECT chunk_id FROM kaddo_semantic_chunks WHERE model_identity = \(model)
                ORDER BY embedding <=> \(queryVector)::vector LIMIT \(max(1, min(limit, 100)))
                """, logger: logger)
        }
        var result: [UUID] = []
        for try await (id) in rows.decode((UUID).self) { result.append(id) }
        return result
    }

    func delete(documentID: UUID) async throws {
        try await start()
        try await client.query("DELETE FROM kaddo_semantic_chunks WHERE document_id = \(documentID)", logger: logger)
    }
}
