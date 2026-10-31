import Foundation
import Testing

@Suite("Scope 3 · Offline document retrieval")
@MainActor
struct DocumentTests {
    @Test("DOCX extracts paragraphs, entities, tabs, breaks, Unicode and tables")
    func wordExtraction() async throws {
        let engine = try MVPFactory.documents()
        let document = try await engine.importDocument(at: fixture("FocusNotes.docx"))
        let text = document.chunks.map(\.text).joined(separator: "\n")
        #expect(text.contains("Orchid research uses a 25-minute focus interval."))
        #expect(text.contains("Alpha & Beta\tcafé 🐈\nNext line"))
        #expect(text.contains("Table cells contain project context."))
        #expect(!text.contains("<w:"))
        #expect(document.filename == "FocusNotes.docx")
        #expect(document.chunks.allSatisfy { $0.documentID == document.id && $0.page == nil })
        #expect(engine.documents.count == 1)
    }

    @Test("Searchable PDF preserves page provenance")
    func pdfExtraction() async throws {
        let engine = try MVPFactory.documents()
        let document = try await engine.importDocument(at: fixture("Research.pdf"))
        #expect(document.chunks.contains { $0.page == 1 && $0.text.contains("Orchid research") })
        #expect(document.chunks.contains { $0.page == 2 && $0.text.contains("Cactus research") })
        #expect(document.chunks.allSatisfy { $0.filename == "Research.pdf" })
    }

    @Test("Rejects unsupported, damaged, missing-part, and textless files", arguments: [
        ("Unsupported.txt", EngineError.unsupportedFile),
        ("Corrupt.docx", .invalidDocument), ("Corrupt.pdf", .invalidDocument),
        ("MissingDocument.docx", .invalidDocument),
        ("Empty.docx", .noExtractableText), ("ImageOnly.pdf", .noExtractableText),
        ("ExternalEntity.docx", .invalidDocument)
    ])
    func invalidDocuments(filename: String, error: EngineError) async throws {
        let engine = try MVPFactory.documents()
        let url = try fixture(filename)
        await #expect(throws: error) { try await engine.importDocument(at: url) }
        #expect(engine.documents.isEmpty)
    }

    @Test("Rejects oversized input and decompressed text before indexing")
    func sizeLimits() async throws {
        var limits = DocumentLimits()
        limits.maxFileBytes = 10
        let smallInputEngine = try MVPFactory.documents(limits: limits)
        let url = try fixture("FocusNotes.docx")
        await #expect(throws: EngineError.documentTooLarge) {
            try await smallInputEngine.importDocument(at: url)
        }
        limits.maxFileBytes = 10 * 1_024 * 1_024
        limits.maxExtractedCharacters = 100
        let smallTextEngine = try MVPFactory.documents(limits: limits)
        await #expect(throws: EngineError.documentTooLarge) {
            try await smallTextEngine.importDocument(at: url)
        }
    }

    @Test("Chunking is bounded, overlapping and lossless for Unicode text")
    func chunking() async throws {
        var limits = DocumentLimits()
        limits.chunkCharacters = 160
        limits.overlapCharacters = 32
        let engine = try MVPFactory.documents(limits: limits)
        let document = try await engine.importDocument(at: fixture("LongNotes.docx"))
        let chunks = document.chunks
        #expect(chunks.count > 10)
        #expect(chunks.allSatisfy { !$0.text.isEmpty && $0.text.count <= 160 })
        #expect(Set(chunks.map(\.id)).count == chunks.count)
        var rebuilt = try #require(chunks.first?.text)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(String(previous.text.suffix(32)) == String(next.text.prefix(32)))
            rebuilt += String(next.text.dropFirst(32))
        }
        let expected = try String(contentsOf: fixture("LongNotes.txt"), encoding: .utf8)
        #expect(rebuilt.trimmingCharacters(in: .whitespacesAndNewlines)
                == expected.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(!rebuilt.contains("�"))
    }

    @Test("Invalid chunk overlap fails configuration")
    func invalidChunking() {
        var limits = DocumentLimits()
        limits.chunkCharacters = 100
        limits.overlapCharacters = 100
        #expect(throws: EngineError.invalidConfiguration) { try MVPFactory.documents(limits: limits) }
    }

    @Test("Lexical retrieval ignores case and punctuation, ranks matches, and budgets context")
    func retrieval() async throws {
        let engine = try MVPFactory.documents()
        _ = try await engine.importDocument(at: fixture("Research.pdf"))
        _ = try await engine.importDocument(at: fixture("FocusNotes.docx"))
        let matches = try engine.retrieve(question: "ORCHID, research?", limit: 2, characterBudget: 500)
        #expect(!matches.isEmpty)
        #expect(matches.count <= 2)
        #expect(matches.allSatisfy { $0.text.localizedCaseInsensitiveContains("orchid") })
        #expect(matches.map(\.text.count).reduce(0, +) <= 500)
        let precise = try engine.retrieve(question: "cactus dry soil", limit: 1, characterBudget: 500)
        #expect(precise.first?.filename == "Research.pdf")
        #expect(precise.first?.page == 2)
        #expect(try engine.retrieve(question: "zzzxxyy", limit: 3, characterBudget: 500).isEmpty)
        #expect(try engine.retrieve(question: "  ?  ", limit: 3, characterBudget: 500).isEmpty)
    }

    @Test("A failed import keeps existing context; explicit removal clears it")
    func lifetime() async throws {
        let engine = try MVPFactory.documents()
        let document = try await engine.importDocument(at: fixture("FocusNotes.docx"))
        let corrupt = try fixture("Corrupt.docx")
        await #expect(throws: EngineError.invalidDocument) {
            try await engine.importDocument(at: corrupt)
        }
        #expect(engine.documents.count == 1)
        // Context must be RAM-only even while another instance still has it.
        let independentEngine = try MVPFactory.documents()
        #expect(independentEngine.documents.isEmpty)
        engine.removeDocument(id: document.id)
        #expect(engine.documents.isEmpty)
        #expect(try engine.retrieve(question: "Orchid", limit: 3, characterBudget: 500).isEmpty)
        _ = try await engine.importDocument(at: fixture("Research.pdf"))
        engine.clear()
        #expect(engine.documents.isEmpty)
        let secondEngine = try MVPFactory.documents()
        #expect(secondEngine.documents.isEmpty)
    }
}
