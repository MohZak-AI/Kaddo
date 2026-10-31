import CZlib
import XCTest
@testable import KaddoCanvas

func documentFixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("KaddoAcceptanceTests/Fixtures/\(name)")
}

final class DocumentTextExtractorTests: XCTestCase {
    func testWordStreamsTextAndPreservesEntitiesUnicodeAndStructure() throws {
        var fragments: [String] = []
        try DocumentTextExtractor().extract(at: documentFixture("FocusNotes.docx")) {
            fragments.append($0)
        }
        let text = fragments.joined()
        XCTAssertGreaterThan(fragments.count, 5)
        XCTAssertTrue(text.contains("Alpha & Beta\tcafé 🐈\nNext line"))
        XCTAssertTrue(text.contains("Table cells contain project context."))
        XCTAssertFalse(text.contains("<w:"))
    }

    func testPDFStreamsBothPages() throws {
        var fragments: [String] = []
        try DocumentTextExtractor().extract(at: documentFixture("Research.pdf")) {
            fragments.append($0)
        }
        XCTAssertTrue(fragments.joined().contains("Orchid research"))
        XCTAssertTrue(fragments.joined().contains("Cactus research"))
        XCTAssertEqual(fragments.count, 4)
    }

    func testDamagedUnsupportedAndTextlessFilesFail() {
        let cases: [(String, DocumentImportError)] = [
            ("Unsupported.txt", .unsupportedFile), ("Corrupt.docx", .invalidDocument),
            ("Corrupt.pdf", .invalidDocument), ("MissingDocument.docx", .invalidDocument),
            ("ExternalEntity.docx", .invalidDocument), ("Empty.docx", .noExtractableText),
            ("ImageOnly.pdf", .noExtractableText), ("absent.pdf", .unreadableFile)
        ]
        for (name, expected) in cases {
            XCTAssertThrowsError(try DocumentTextExtractor().extract(at: documentFixture(name)) { _ in }) {
                XCTAssertEqual($0 as? DocumentImportError, expected, name)
            }
        }
    }

    func testFileXMLTextAndPageLimits() {
        for keyPath in [\DocumentExtractionLimits.maxFileBytes, \.maxXMLBytes, \.maxTextBytes] {
            var limits = DocumentExtractionLimits()
            limits[keyPath: keyPath] = 10
            XCTAssertThrowsError(try DocumentTextExtractor(limits: limits)
                .extract(at: documentFixture("FocusNotes.docx")) { _ in }) {
                XCTAssertEqual($0 as? DocumentImportError, .documentTooLarge)
            }
        }
        var limits = DocumentExtractionLimits()
        limits.maxPDFPages = 1
        XCTAssertThrowsError(try DocumentTextExtractor(limits: limits)
            .extract(at: documentFixture("Research.pdf")) { _ in }) {
            XCTAssertEqual($0 as? DocumentImportError, .documentTooLarge)
        }
    }

    func testConsumerFailureStopsStreaming() {
        enum Stop: Error { case requested }
        var calls = 0
        XCTAssertThrowsError(try DocumentTextExtractor().extract(at: documentFixture("FocusNotes.docx")) { _ in
            calls += 1
            throw Stop.requested
        }) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(calls, 1)
    }

    func testXMLRejectsDTDsAndDeepNestingIncludingUTF16() {
        let malicious = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>"
            + "<!DOCTYPE x [<!ENTITY a 'expanded'>]><x>&a;</x>"
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            let bom: [UInt8] = encoding == .utf16LittleEndian ? [0xff, 0xfe] : [0xfe, 0xff]
            let data = Data(bom) + malicious.data(using: encoding)!
            XCTAssertThrowsError(try WordXMLTextReader.read(data) { _ in XCTFail("DTD emitted text") })
        }
        let nested = String(repeating: "<a>", count: 300) + String(repeating: "</a>", count: 300)
        XCTAssertThrowsError(try WordXMLTextReader.read(Data(nested.utf8)) { _ in })
    }

    func testTruncatedZIPsNeverReadPastBounds() throws {
        let archive = try Data(contentsOf: documentFixture("FocusNotes.docx"))
        for length in stride(from: 0, to: archive.count, by: 7) {
            XCTAssertThrowsError(try WordZIPArchive.documentXML(in: Data(archive.prefix(length)),
                                                              maxBytes: 8_192))
        }
        let central = archive.range(of: Data([0x50, 0x4b, 0x01, 0x02]), options: .backwards)!
        var corrupt = archive
        corrupt[central.lowerBound + 16] ^= 0xff // Main part CRC.
        XCTAssertThrowsError(try WordZIPArchive.documentXML(in: corrupt, maxBytes: 8_192))
    }

    func testStoredZIPAndAlternateNamespacePrefix() throws {
        let xml = Data(("<d:document xmlns:d=\"http://purl.oclc.org/ooxml/wordprocessingml/main\">"
            + "<d:body><d:p><d:r><d:t><![CDATA[Alpha & β]]></d:t></d:r></d:p></d:body>"
            + "</d:document>").utf8)
        let archive = storedWordArchive(xml)
        let extracted = try WordZIPArchive.documentXML(in: archive, maxBytes: 8_192)
        XCTAssertEqual(extracted, xml)
        var text = ""
        try WordXMLTextReader.read(extracted) { text += $0 }
        XCTAssertEqual(text, "Alpha & β\n")
    }

    func testZIPHeaderMutationsAreRejected() throws {
        let archive = storedWordArchive(Data("<document/>".utf8))
        let central = archive.range(of: Data([0x50, 0x4b, 0x01, 0x02]))!.lowerBound
        let end = archive.count - 22
        // Encryption, unsupported method, mismatched names, oversized sizes,
        // impossible offsets, and multidisk/ZIP64-like directory fields.
        let changes: [(Int, UInt8)] = [
            (6, 1), (8, 99), (26, 255), (30, 0),
            (central + 8, 1), (central + 10, 99), (central + 24, 255),
            (central + 42, 255), (end + 4, 1), (end + 10, 255), (end + 16, 255)
        ]
        for (offset, byte) in changes {
            var corrupt = archive
            corrupt[offset] = byte
            XCTAssertThrowsError(try WordZIPArchive.documentXML(in: corrupt, maxBytes: 128), "offset \(offset)")
        }
    }

    func testInflationCannotTrustFalsifiedSmallExpandedSize() throws {
        var archive = try Data(contentsOf: documentFixture("LongNotes.docx"))
        let central = archive.range(of: Data([0x50, 0x4b, 0x01, 0x02]), options: .backwards)!.lowerBound
        let local = (0..<4).reduce(0) { $0 | Int(archive[central + 42 + $1]) << ($1 * 8) }
        for offset in [central + 24, local + 22] {
            archive.replaceSubrange(offset..<offset + 4, with: [16, 0, 0, 0])
        }
        XCTAssertThrowsError(try WordZIPArchive.documentXML(in: archive, maxBytes: 8_192)) {
            XCTAssertEqual($0 as? DocumentImportError, .documentTooLarge)
        }
    }

    func testUTF32AndReinterpretedEncodingCannotBypassDTDChecks() {
        let text = "<?xml version=\"1.0\" encoding=\"UTF-32\"?>"
            + "<!DOCTYPE x [<!ENTITY a 'expanded'>]><x>&a;</x>"
        for encoding in [String.Encoding.utf32LittleEndian, .utf32BigEndian] {
            let bom: [UInt8] = encoding == .utf32LittleEndian ? [0xff, 0xfe, 0, 0] : [0, 0, 0xfe, 0xff]
            XCTAssertThrowsError(try WordXMLTextReader.read(Data(bom) + text.data(using: encoding)!) { _ in
                XCTFail("UTF32 emitted uninspected text")
            })
        }
        let utf7 = "<?xml version=\"1.0\" encoding=\"UTF-7\"?><x>+ADw-!DOCTYPE</x>"
        XCTAssertThrowsError(try WordXMLTextReader.read(Data(utf7.utf8)) { _ in })
    }
}

private func storedWordArchive(_ xml: Data) -> Data {
    let name = Data("word/document.xml".utf8)
    let checksum = xml.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
    var result = Data()
    func append(_ value: Int, width: Int) {
        for shift in 0..<width { result.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
    }
    append(0x04034b50, width: 4)
    for value in [20, 0, 0, 0, 0] { append(value, width: 2) }
    append(Int(checksum), width: 4)
    append(xml.count, width: 4); append(xml.count, width: 4)
    append(name.count, width: 2); append(0, width: 2)
    result.append(name); result.append(xml)
    let directory = result.count
    append(0x02014b50, width: 4)
    for value in [20, 20, 0, 0, 0, 0] { append(value, width: 2) }
    append(Int(checksum), width: 4)
    append(xml.count, width: 4); append(xml.count, width: 4)
    for value in [name.count, 0, 0, 0, 0] { append(value, width: 2) }
    append(0, width: 4); append(0, width: 4)
    result.append(name)
    let directorySize = result.count - directory
    append(0x06054b50, width: 4)
    for value in [0, 0, 1, 1] { append(value, width: 2) }
    append(directorySize, width: 4); append(directory, width: 4); append(0, width: 2)
    return result
}
