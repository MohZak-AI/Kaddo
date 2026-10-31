import XCTest
@testable import KaddoCanvas

final class KeywordNoteSearchTests: XCTestCase {
    func testExactOutranksPartialAndTiesPreserveImportOrder() throws {
        let chunks = [chunk("Orchids weekly"), chunk("Orchid weekly"), chunk("Orchid daily")]
        let result = try KeywordNoteSearch().search("ORCHID", in: chunks)
        XCTAssertEqual(result.map(\.chunk.id), [chunks[1].id, chunks[2].id, chunks[0].id])
        XCTAssertEqual(result.map(\.score), [3, 3, 1])
    }

    func testTermsAreDistinctAndMultipleMatchesRankHigher() throws {
        let chunks = [chunk("orchid orchid orchid"), chunk("orchid watering")]
        let result = try KeywordNoteSearch().search("orchid orchid watering", in: chunks)
        XCTAssertEqual(result.map(\.score), [6, 3])
        XCTAssertEqual(result.first?.chunk.id, chunks[1].id)
    }

    func testUnicodeNormalizationAndEmptyQueries() throws {
        let chunks = [chunk("Café الري نباتات 東京")]
        for query in ["cafe", "الرّي", "نبات", "東京"] {
            XCTAssertEqual(try KeywordNoteSearch().search(query, in: chunks).count, 1, query)
        }
        for query in ["", " \n", "?!", "a", "unrelated"] {
            XCTAssertTrue(try KeywordNoteSearch().search(query, in: chunks).isEmpty)
        }
        XCTAssertThrowsError(try KeywordNoteSearch().search(String(repeating: "x", count: 2_001), in: []))
    }

    func testWholeChunkBudgetAndResultLimit() throws {
        let chunks = [chunk("orchid " + String(repeating: "x", count: 80)),
                      chunk("orchid weekly"), chunk("orchid daily")]
        let result = try KeywordNoteSearch(maximumResults: 1, contextCharacterBudget: 20)
            .search("orchid", in: chunks)
        XCTAssertEqual(result.map(\.chunk), [chunks[1]])
        XCTAssertTrue(try KeywordNoteSearch(contextCharacterBudget: 0).search("orchid", in: chunks).isEmpty)
        XCTAssertTrue(try KeywordNoteSearch(maximumResults: 0).search("orchid", in: chunks).isEmpty)
    }

    private func chunk(_ text: String) -> DocumentChunk {
        DocumentChunk(id: UUID(), documentID: UUID(), filename: "Notes.docx", index: 0, text: text)
    }
}
