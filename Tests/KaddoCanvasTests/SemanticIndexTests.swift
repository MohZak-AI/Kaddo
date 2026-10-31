import XCTest
@testable import KaddoCanvas

final class SemanticIndexTests: XCTestCase {
    func testLocalPgvectorFilteredSearchAndDelete() async throws {
        guard ProcessInfo.processInfo.environment["KADDO_PGVECTOR"] == "1",
              let index = PostgresSemanticIndex() else {
            throw XCTSkip("Set KADDO_PGVECTOR=1 and start the local Docker service for pgvector integration tests.")
        }
        try await index.start()
        let session = UUID(), otherSession = UUID(), document = UUID()
        var first = Array(repeating: Float(0), count: 768); first[0] = 1
        var second = Array(repeating: Float(0), count: 768); second[1] = 1
        let firstID = UUID(), secondID = UUID()
        try await index.upsert([
            .init(id: firstID, documentID: document, sessionID: session, revision: 1, generation: 1, model: "test-model", text: "first", vector: first),
            .init(id: secondID, documentID: UUID(), sessionID: otherSession, revision: 1, generation: 1, model: "test-model", text: "second", vector: second)
        ])
        let result = try await index.search(vector: first, model: "test-model", sessionID: session, documentIDs: nil, limit: 10)
        XCTAssertEqual(result, [firstID])
        try await index.delete(documentID: document)
        let deleted = try await index.search(vector: first, model: "test-model", sessionID: session, documentIDs: nil, limit: 10)
        XCTAssertTrue(deleted.isEmpty)
    }
}
