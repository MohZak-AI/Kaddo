import XCTest
@testable import KaddoCanvas

func inferenceRecord(_ fragment: String, done: Bool = false, reason: String? = nil) throws -> String {
    var fields: [String: Any] = ["response": fragment, "done": done]
    if let reason { fields["done_reason"] = reason }
    return String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
}

func speechObject(_ text: String, emotion: String = "happy", ids: [UUID] = []) throws -> String {
    let object: [String: Any] = ["speechBubbleText": text, "pet_emotion": emotion,
                               "sourceIDs": ids.map(\.uuidString)]
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

final class OllamaStreamDecoderTests: XCTestCase {
    func testEveryCharacterFragmentIncludesEscapesUnicodeAndMultipleLines() throws {
        let source = UUID()
        let first = try speechObject("الري أسبوعياً 🌱 \"quoted\" \\ {brace}", ids: [source])
        let second = try speechObject("東京 café", emotion: "idle")
        let json = " { \"lines\" : [\(first),\(second)] } \n"
        var decoder = OllamaStreamDecoder(sourceIDs: [source])
        var received: [PetSpeechLine] = []
        for character in json {
            received += try decoder.consume(inferenceRecord(String(character)))
        }
        XCTAssertEqual(received.map(\.speechBubbleText), ["الري أسبوعياً 🌱 \"quoted\" \\ {brace}", "東京 café"])
        XCTAssertEqual(received.map(\.currentEmotion), [.happy, .idle])
        XCTAssertEqual(received[0].sourceIDs, [source])
        XCTAssertFalse(decoder.isFinished)
        _ = try decoder.consume(inferenceRecord("", done: true, reason: "stop"))
        try decoder.finish()
        XCTAssertTrue(decoder.isFinished)
        XCTAssertThrowsError(try decoder.consume(inferenceRecord("", done: true)))
    }

    func testPublishesCompletedObjectBeforeEnvelopeAndDone() throws {
        var decoder = OllamaStreamDecoder(sourceIDs: [])
        XCTAssertTrue(try decoder.consume(inferenceRecord("{\"lines\":[{\"speechBubbleText\":\"hel")).isEmpty)
        let lines = try decoder.consume(inferenceRecord("lo\",\"currentEmotion\":\"happy\",\"sourceIDs\":[]}"))
        XCTAssertEqual(lines.map(\.speechBubbleText), ["hello"])
        XCTAssertThrowsError(try decoder.finish())
        _ = try decoder.consume(inferenceRecord("]}", done: true))
        try decoder.finish()
    }

    func testRejectsWrongStructureUnknownKeysEmotionsAndSources() throws {
        let valid = try speechObject("Water weekly")
        let invalidObjects = [
            "{\"lines\":[]}",
            "{\"lines\":[\(valid),]}", "{\"lines\":[\(valid)],\"extra\":true}",
            "{\"li nes\":[\(valid)]}", "{\"lines\":[\(valid)]} trailing",
            "{\"lines\":[{\"speechBubbleText\":\"hello\",\"currentEmotion\":\"angry\",\"sourceIDs\":[]}]}",
            "{\"lines\":[{\"speechBubbleText\":\"hello\",\"currentEmotion\":\"idle\",\"sourceIDs\":[],\"extra\":0}]}",
            "{\"lines\":[{\"speechBubbleText\":\"hello\",\"currentEmotion\":\"idle\"}]}",
            "{\"lines\":[\(try speechObject(" "))]}",
            "{\"lines\":[\(try speechObject("one\ntwo"))]}",
            "{\"lines\":[\(try speechObject("x", ids: [UUID()]))]}",
            "{\"lines\":[\(try speechObject(String(repeating: "x", count: 501)))]}"
        ]
        for object in invalidObjects {
            var decoder = OllamaStreamDecoder(sourceIDs: [])
            XCTAssertThrowsError(try decoder.consume(inferenceRecord(object, done: true)), object)
        }
    }

    func testFragmentedFencesAndPetEmotionNeverLeakFormatting() throws {
        let source = UUID()
        let text = "東京 🌱 says \"hello\"; keep ```json inside speech."
        let line = try speechObject(text, emotion: "celebrating", ids: [source])
        for header in ["```json\r\n", "```\n"] {
            let json = " \n" + header + "{\"lines\":[\(line)]}\n``` \r\n"
            var decoder = OllamaStreamDecoder(sourceIDs: [source])
            var received: [PetSpeechLine] = []
            for character in json {
                received += try decoder.consume(inferenceRecord(String(character)))
            }
            XCTAssertEqual(received.map(\.speechBubbleText), [text])
            XCTAssertEqual(received.map(\.currentEmotion), [.celebrating])
            XCTAssertEqual(received.first?.sourceIDs, [source])
            _ = try decoder.consume(inferenceRecord("", done: true))
            try decoder.finish()
        }
    }

    func testSingleFullResponseAndLegacyEmotionCompatibility() throws {
        let legacy = #"{"speechBubbleText":"Earlier answer","currentEmotion":"happy","sourceIDs":[]}"#
        var decoder = OllamaStreamDecoder(sourceIDs: [])
        let lines = try decoder.consume(inferenceRecord("{\"lines\":[\(legacy)]}", done: true))
        XCTAssertEqual(lines.map(\.speechBubbleText), ["Earlier answer"])
        XCTAssertEqual(lines.map(\.currentEmotion), [.happy])
        try decoder.finish()
    }

    func testExactAnswerMustCiteEveryRequiredLinkedPassage() throws {
        let required = UUID()
        let optional = UUID()
        let unsupported = try speechObject("Exact output", ids: [optional])
        var missing = OllamaStreamDecoder(sourceIDs: [required, optional], requiredSourceIDs: [required])
        XCTAssertThrowsError(try missing.consume(inferenceRecord("{\"lines\":[\(unsupported)]}", done: true)))

        let supported = try speechObject("Exact output", ids: [required])
        var complete = OllamaStreamDecoder(sourceIDs: [required, optional], requiredSourceIDs: [required])
        _ = try complete.consume(inferenceRecord("{\"lines\":[\(supported)]}", done: true))
        try complete.finish()

        let refusal = try speechObject("I can’t give an exact answer from these passages.", emotion: "idle", ids: [required])
        var declined = OllamaStreamDecoder(sourceIDs: [required, optional], requiredSourceIDs: [required])
        _ = try declined.consume(inferenceRecord("{\"lines\":[\(refusal)]}", done: true))
        try declined.finish()

        let uncitedIdleAnswer = try speechObject("The exact output is TOKEN.", emotion: "idle")
        var evasive = OllamaStreamDecoder(sourceIDs: [required, optional], requiredSourceIDs: [required])
        XCTAssertThrowsError(try evasive.consume(inferenceRecord("{\"lines\":[\(uncitedIdleAnswer)]}", done: true)))
    }

    func testRejectsAmbiguousEmotionAndIncompleteOrExtraneousFormatting() throws {
        let valid = "{\"lines\":[\(try speechObject("Answer", emotion: "celebrating"))]}"
        let ambiguous = #"{"lines":[{"speechBubbleText":"Answer","pet_emotion":"celebrating","currentEmotion":"idle","sourceIDs":[]}]}"#
        let unknown = #"{"lines":[{"speechBubbleText":"Answer","pet_emotion":"angry","sourceIDs":[]}]}"#
        for fragment in [ambiguous, unknown, "```json\n" + valid,
                         "```json\n" + valid + "\n``", "```swift\n" + valid + "\n```",
                         "```json\n" + valid + "\n``` trailing",
                         "Here is the answer: " + valid, "```json\n```json\n" + valid + "\n```"] {
            var decoder = OllamaStreamDecoder(sourceIDs: [])
            XCTAssertThrowsError(try decoder.consume(inferenceRecord(fragment, done: true)), fragment)
        }
    }

    func testTruncatedMissingDoneErrorAndResourceLimits() throws {
        let line = try speechObject("Hello")
        for record in ["not json", "{}", "{\"error\":\"failed\"}",
                       try inferenceRecord("{\"lines\":[\(line)]", done: true),
                       try inferenceRecord("{\"lines\":[\(line)]}", done: true, reason: "length"),
                       try inferenceRecord("{\"lines\":[" + Array(repeating: line, count: 9).joined(separator: ",") + "]}", done: true)] {
            var decoder = OllamaStreamDecoder(sourceIDs: [])
            XCTAssertThrowsError(try decoder.consume(record))
        }
        var unfinished = OllamaStreamDecoder(sourceIDs: [])
        _ = try unfinished.consume(inferenceRecord("{\"lines\":[\(line)]}"))
        XCTAssertThrowsError(try unfinished.finish())
        var oversized = OllamaStreamDecoder(sourceIDs: [])
        XCTAssertThrowsError(try oversized.consume(inferenceRecord(String(repeating: " ", count: 65_537)))) {
            XCTAssertEqual($0 as? LocalInferenceError, .responseTooLarge)
        }
    }
}
