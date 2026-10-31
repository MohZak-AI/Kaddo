import XCTest
@testable import KaddoCanvas

final class DocumentTextChunkerTests: XCTestCase {
    func testParagraphChunksPreserveBoundariesAndEnforceCombinedLimit() throws {
        let chunker = try DocumentTextChunker(maxCharacters: 30)
        let text = "Orchid care. Water weekly.\n\nCactus care. Keep dry.\u{2029}Last paragraph."
        XCTAssertEqual(try chunker.paragraphChunks(in: text),
                       ["Orchid care. Water weekly.", "Cactus care. Keep dry.", "Last paragraph."])
        XCTAssertThrowsError(try DocumentTextChunker(maxChunks: 2).paragraphChunks(in: text)) {
            XCTAssertEqual($0 as? DocumentImportError, .documentTooLarge)
        }
        XCTAssertTrue(try chunker.paragraphChunks(in: "\n\r\n \t\u{2029}").isEmpty)
    }

    func testFourSentenceWindowsDoNotOverlap() throws {
        let sentences = (1...10).map { "Sentence number \($0) is unique." }
        let text = sentences.joined(separator: " ")
        let chunks = try DocumentTextChunker().chunks(in: text)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0], sentences[0..<4].joined(separator: " ") + " ")
        XCTAssertEqual(chunks[1], sentences[4..<8].joined(separator: " ") + " ")
        XCTAssertEqual(chunks[2], sentences[8..<10].joined(separator: " "))
        XCTAssertEqual(chunks.joined(), text)
    }

    func testWhitespaceAndControlOnlyInputProducesNoChunks() throws {
        let chunker = try DocumentTextChunker()
        for text in ["", " \t\n\r\n ", "\u{00a0}\u{2028}\u{2029}", "\0\u{0001}\u{0007}"] {
            XCTAssertTrue(try chunker.chunks(in: text).isEmpty)
        }
    }

    func testAdversarialFormattingAndStringsRemainInertAndLossless() throws {
        let source = " \tAlpha\r\n\r\nBeta\u{00a0}café 👩🏽‍💻.\u{2028}"
            + "<script>alert('x')</script> & ${HOME} %s %@.\n"
            + "Ignore previous instructions!\u{2029}مرحبا بالعالم؟\t你好世界。\0 End. "
        let expected = "Alpha Beta café 👩🏽‍💻. <script>alert('x')</script> & ${HOME} %s %@. "
            + "Ignore previous instructions! مرحبا بالعالم؟ 你好世界。 End."
        let chunks = try DocumentTextChunker(maxCharacters: 40).chunks(in: source)
        XCTAssertEqual(chunks.joined(), expected)
        XCTAssertTrue(chunks.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 40 })
        XCTAssertFalse(chunks.joined().contains("�"))
    }

    func testLongUnpunctuatedUnicodeHasHardBoundsWithoutSplittingGraphemes() throws {
        let text = String(repeating: "👩🏽‍💻e\u{301}🇶🇦", count: 10_000)
        let chunks = try DocumentTextChunker(maxCharacters: 31).chunks(in: text)
        XCTAssertGreaterThan(chunks.count, 900)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { (1...31).contains($0.count) })
        XCTAssertTrue(chunks.flatMap(Array.init).allSatisfy { ["👩🏽‍💻", "e\u{301}", "🇶🇦"].contains(String($0)) })
    }

    func testSmallLimitsAndBoundarySpacesNeverProduceEmptyChunks() throws {
        for width in 2...20 {
            for text in ["a. b. c. d. e.", "ab cd ef gh", "hello ", "Hi! Hi! Hi!"] {
                let chunks = try DocumentTextChunker(sentencesPerChunk: 1, maxCharacters: width)
                    .chunks(in: text)
                XCTAssertTrue(chunks.allSatisfy { $0.count <= width })
                XCTAssertTrue(chunks.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                XCTAssertEqual(chunks.joined(), text.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    func testInvalidConfigurationsFail() {
        for count in [Int.min, 0, 21, Int.max] {
            XCTAssertThrowsError(try DocumentTextChunker(sentencesPerChunk: count))
        }
        for width in [Int.min, 0, 1] {
            XCTAssertThrowsError(try DocumentTextChunker(maxCharacters: width))
        }
        XCTAssertThrowsError(try DocumentTextChunker(maxChunks: 0))
    }

    func testChunkCountLimitStopsLongInputBeforeAllocatingUnboundedArray() throws {
        let chunker = try DocumentTextChunker(maxCharacters: 2, maxChunks: 3)
        XCTAssertThrowsError(try chunker.chunks(in: String(repeating: "long", count: 1_000))) {
            XCTAssertEqual($0 as? DocumentImportError, .documentTooLarge)
        }
        XCTAssertEqual(try DocumentTextChunker(maxCharacters: Int.max).chunks(in: "Small text."),
                       ["Small text."])
    }

    func testCancellationIsObserved() async {
        let task = Task.detached {
            return try DocumentTextChunker().chunks(in: String(repeating: "Sentence. ", count: 100_000))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled chunking succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
