import AppKit
import CSQLite
import CZlib
import XCTest
@testable import KaddoCanvas

@MainActor
final class DocumentRetrievalTests: XCTestCase {
    private func upload(_ library: KnowledgeLibrary, session: UUID, name: String, text: String) async throws -> KnowledgeItem {
        _ = try await library.saveUploadedDocument(.init(id: session, title: "Test session"),
            url: URL(fileURLWithPath: "/tmp/" + name), text: text)
        return try XCTUnwrap(library.items.first { $0.title == name && $0.sourceKey.contains(session.uuidString) })
    }
    private let lab = """
    Object oriented programming lab
    Submit the completed source code and a screenshot.
    Exercise 1: Implement inheritance
    Create class Vehicle with a virtual display method.
    class Vehicle {
        public: virtual void display();
    };
    Your outcome should be :
    }
    }
    Define subclass Car and override display to print the model.
    Exercise 2: Test polymorphism
    Call display through a Vehicle pointer and explain dynamic dispatch.
    """
    func testOverviewRetrievesRequirementsAndBothExercisesRatherThanOutcomeFragment() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let session = UUID()
        _ = try await upload(library, session: session, name: "OOP.docx", text: lab)
        let result = try await DocumentRetrievalService(library: library).retrieve(.init(sessionID: session, question: "what should I do?"))
        let text = result.evidence.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("Submit the completed"))
        XCTAssertTrue(text.contains("Define subclass Car"))
        XCTAssertTrue(text.contains("Test polymorphism"))
        XCTAssertEqual(result.coverage, .complete)
        XCTAssertLessThan(result.evidence.count, 8)
        XCTAssertTrue(result.evidence.allSatisfy { $0.text.count <= 1_600 })
    }
    func testNumberedExerciseIncludesCodeAndContinuationButNotNextExercise() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let session = UUID()
        _ = try await upload(library, session: session, name: "OOP.docx", text: lab)
        let result = try await DocumentRetrievalService(library: library).retrieve(.init(sessionID: session, question: "explain ex1"))
        let text = result.evidence.map(\.text).joined()
        XCTAssertTrue(text.contains("virtual void display"))
        XCTAssertTrue(text.contains("Define subclass Car"))
        XCTAssertFalse(text.contains("Test polymorphism"))
        XCTAssertEqual(result.evidence.first?.location, "Exercise 1")
        do {
            _ = try await DocumentRetrievalService(library: library).retrieve(.init(sessionID: session, question: "explain ex9"))
            XCTFail("Missing exercises must not receive opening paragraphs")
        } catch { XCTAssertTrue(error.localizedDescription.contains("exercise 9")) }
    }
    func testSessionOwnershipSurvivesFilingAndExplicitCrossSessionAccess() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let first = UUID(), other = UUID()
        let item = try await upload(library, session: first, name: "OOP.docx", text: lab)
        _ = await library.moveItem(id: item.id, categoryID: KnowledgeCategory.work.id)
        _ = try await upload(library, session: other, name: "French.docx", text: "Exercise 1: Translate bonjour.")
        let service = DocumentRetrievalService(library: library)
        let result = try await service.retrieve(.init(sessionID: first, question: "ex1"))
        XCTAssertEqual(Set(result.evidence.map(\.documentID)), [item.id])
        do {
            _ = try await service.retrieve(.init(sessionID: first, question: "ex1 in French.docx"))
            XCTFail("Should require explicit cross-session intent")
        } catch { XCTAssertTrue(error.localizedDescription.contains("isn’t in this session")) }
        let cross = try await service.retrieve(.init(sessionID: first, question: "search other sessions for ex1 in French.docx"))
        XCTAssertTrue(cross.evidence.map(\.text).joined().contains("bonjour"))
    }
    func testAmbiguousStandaloneSearchClarifiesAndExplicitComparisonUsesMultipleDocuments() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let session = UUID()
        let first = try await upload(library, session: session, name: "Photosynthesis.docx",
            text: "Photosynthesis uses chlorophyll to absorb light energy in the leaf.")
        let second = try await upload(library, session: session, name: "Cellular-energy.docx",
            text: "Photosynthesis stores captured sunlight as chemical energy.")
        do {
            _ = try await DocumentRetrievalService(library: library).retrieve(.init(
                sessionID: session, question: "photosynthesis"))
            XCTFail("An unscoped search with relevant passages in both documents must ask which document first.")
        } catch let error as DocumentRetrievalError {
            guard case .chooseDocument(let names) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(Set(names), ["Photosynthesis.docx", "Cellular-energy.docx"])
        }

        let result = try await DocumentRetrievalService(library: library).retrieve(.init(
            sessionID: session, question: "Compare how photosynthesis uses sunlight and chemical energy across these documents"))
        XCTAssertEqual(Set(result.evidence.map(\.documentID)), [first.id, second.id])
        XCTAssertEqual(Set(result.documentCoverage.keys), ["Photosynthesis.docx", "Cellular-energy.docx"])
        XCTAssertEqual(result.coverage, .partial)
    }
    func testPersistedUploadKeepsAnAppOwnedOriginalForReprocessing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = documentFixture("FocusNotes.docx")
        let library = KnowledgeLibrary(storageURL: folder.appendingPathComponent("knowledge.sqlite"), embeddingProvider: nil)
        await library.load()
        let session = UUID()
        _ = try await library.saveUploadedDocument(.init(id: session, title: "Test"), url: url, text: "Saved document text")
        let item = try XCTUnwrap(library.items.first)
        let retained = try XCTUnwrap(item.sourceURL)
        XCTAssertTrue(retained.path.hasPrefix(folder.appendingPathComponent("Originals").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertTrue(item.sourceKey.contains(url.standardizedFileURL.absoluteString))
    }
    func testLatestUploadThenExplicitFocusAndFollowupPersistAcrossRestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("knowledge.sqlite")
        let library = KnowledgeLibrary(storageURL: url, embeddingProvider: nil); await library.load()
        let session = UUID()
        let older = try await upload(library, session: session, name: "OOP.docx", text: lab)
        let latest = try await upload(library, session: session, name: "Math.docx", text: "Exercise 1: Differentiate.\nExercise 2: Integrate.")
        let service = DocumentRetrievalService(library: library)
        do {
            _ = try await service.retrieve(.init(sessionID: session, question: "explain ex1"))
            XCTFail("Duplicate exercise numbers without a focus should require document selection.")
        } catch let error as DocumentRetrievalError {
            guard case .chooseDocument(let names) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(Set(names), ["Math.docx", "OOP.docx"])
        }
        let initial = try await service.retrieve(.init(sessionID: session, question: "explain ex1 in Math.docx"))
        XCTAssertEqual(initial.focus?.documentID, latest.id)
        let prior = try await library.store.documentFocus(sessionID: session)
        let explicit = try await service.retrieve(.init(sessionID: session, question: "explain ex1 in OOP.docx"))
        let unchanged = try await library.store.documentFocus(sessionID: session)
        XCTAssertEqual(prior, unchanged, "Preparing retrieval must not commit conversation focus")
        try await library.store.saveDocumentFocus(try XCTUnwrap(explicit.focus), sessionID: session)
        let reopened = KnowledgeLibrary(storageURL: url, embeddingProvider: nil); await reopened.load()
        let continued = try await DocumentRetrievalService(library: reopened).retrieve(.init(
            sessionID: session, question: "how do I start?", allowsSavedFocus: true))
        XCTAssertEqual(continued.focus?.documentID, older.id)
        XCTAssertEqual(continued.evidence.map(\.id), explicit.evidence.map(\.id))
        XCTAssertFalse(continued.evidence.map(\.text).joined().contains("Test polymorphism"))
        _ = await reopened.deleteItem(id: older.id)
        let focus = try await reopened.store.documentFocus(sessionID: session)
        XCTAssertNil(focus)
    }
    func testLocalHybridSearchExpandsMatchingContextAndFiltersBeforeCandidateLimit() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let session = UUID()
        let item = try await upload(library, session: session, name: "OOP.docx", text: lab)
        for index in 0..<105 {
            _ = await library.addNote(title: "Distractor \(index)", text: "virtual display")
        }
        let result = try await DocumentRetrievalService(library: library).retrieve(.init(sessionID: session, question: "virtual display"))
        XCTAssertEqual(Set(result.evidence.map(\.documentID)), [item.id])
        XCTAssertTrue(result.evidence.map(\.text).joined().contains("Define subclass Car"))
        let unrelated = try await library.store.search(query: "volcano", documentIDs: [item.id])
        XCTAssertTrue(unrelated.isEmpty, "Explicit scope must not turn unrelated chunks into positive hits")
    }
    func testExerciseRetrievalFollowsExplicitSectionLinkForDistantSupport() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let session = UUID()
        let item = try await upload(library, session: session, name: "Parser.docx", text: """
        Exercise 1: Implement a parser using the tokenizer defined in Section 4.
        Your parser must report malformed input.
        Section 2: Error handling
        Return a useful error for invalid input.
        Section 3: Output format
        The result should preserve the original token positions.
        Section 4: Tokenizer
        \(String(repeating: "Tokenizer setup details cover quoted strings and escape handling. ", count: 30))
        The tokenizer groups quoted text and escaped delimiters into a single token.
        Exercise 2: Test the parser with valid input.
        """)

        let chunks = try await library.store.documentChunks(itemID: item.id)
        let targetHeading = try XCTUnwrap(chunks.first { $0.text.contains("Section 4: Tokenizer") })
        let linkedSupport = try XCTUnwrap(chunks.first { $0.text.contains("groups quoted text and escaped delimiters") })
        XCTAssertNotEqual(targetHeading.id, linkedSupport.id)
        let result = try await DocumentRetrievalService(library: library).retrieve(.init(
            sessionID: session, question: "explain ex1"))
        let evidence = result.evidence.map(\.text).joined(separator: "\n")
        XCTAssertTrue(evidence.contains("Implement a parser"))
        XCTAssertTrue(evidence.contains("groups quoted text and escaped delimiters"))
        XCTAssertEqual(result.evidence.first?.location, "Exercise 1")
        XCTAssertEqual(Set(result.evidence.map(\.documentID)), [item.id])
        let links = try await library.store.documentPassageLinks(documentID: item.id, revision: item.revision)
        XCTAssertTrue(links.contains { $0.kind == "section" && $0.sourceText.localizedCaseInsensitiveContains("Section 4") })

        let exact = try await DocumentRetrievalService(library: library).retrieve(.init(
            sessionID: session, question: "What exact token output should exercise 1 produce?"))
        let exercisePassage = try XCTUnwrap(chunks.first { $0.text.contains("Implement a parser") })
        XCTAssertTrue(exact.requiredSupportIDs.contains(exercisePassage.id))
        XCTAssertTrue(exact.requiredSupportIDs.contains(linkedSupport.id))
        XCTAssertTrue(Set(exact.evidence.map(\.id)).isSuperset(of: exact.requiredSupportIDs))
    }

    func testFollowupRejectsPreferredDocumentRevisionThatHasBeenReplaced() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil)
        await library.load()
        let session = UUID()
        let original = try await upload(library, session: session, name: "Revision.docx", text: """
        Exercise 1: Use the rule in Section 2 to tokenize input.
        Section 2: Original rule
        Preserve every delimiter.
        """)
        let originalChunks = try await library.store.documentChunks(itemID: original.id)
        let oldEvidenceIDs = Set(originalChunks.map(\.id))

        let replacement = try await upload(library, session: session, name: "Revision.docx", text: """
        Exercise 1: Use the rule in Section 2 to tokenize input.
        Section 2: Replacement rule
        Remove every delimiter.
        """)
        XCTAssertEqual(replacement.id, original.id)
        XCTAssertGreaterThan(replacement.revision, original.revision)
        do {
            _ = try await DocumentRetrievalService(library: library).retrieve(.init(
                sessionID: session, question: "Why?", preferredDocumentID: original.id,
                preferredRevision: original.revision, preferredExercise: "exercise 1",
                contextChunkIDs: Array(oldEvidenceIDs)))
            XCTFail("A follow-up against a replaced revision must not retrieve evidence.")
        } catch let error as DocumentRetrievalError {
            guard case .missingFollowupContext = error else {
                return XCTFail("Expected stale follow-up context to be rejected, got \(error)")
            }
        }
    }
    func testInlineExerciseReferenceLinksAfterChunkingSeparatesTheTargets() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let session = UUID()
        let item = try await upload(library, session: session, name: "Inline.docx",
            text: "Exercise 1: Start the method. See Exercise 2 for the helper. Exercise 2: The helper preserves token order.")
        let chunks = try await library.store.documentChunks(itemID: item.id)
        XCTAssertEqual(chunks.count, 2)
        let exerciseOne = try XCTUnwrap(chunks.first { $0.text.contains("Exercise 1:") })
        let links = try await library.store.documentPassageLinks(documentID: item.id, revision: item.revision)
        XCTAssertTrue(links.contains { $0.sourceChunkID == exerciseOne.id && $0.sourceText.contains("Exercise 2") })

        let result = try await DocumentRetrievalService(library: library).retrieve(.init(
            sessionID: session, question: "explain ex1 in Inline.docx"))
        XCTAssertTrue(result.evidence.map(\.text).joined(separator: "\n").contains("helper preserves token order"))
    }
    func testMarkdownExerciseLinkExpandsBeyondThreeContinuationChunks() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let session = UUID()
        let filler = (0..<6).map { "Supporting details \($0): " + String(repeating: "validated token detail ", count: 48) }
            .joined(separator: "\n")
        let item = try await upload(library, session: session, name: "Marked.docx", text: """
        Exercise 1: Use the helper defined in Exercise 2.
        # Exercise 2: Helper definition
        \(filler)
        The helper definition preserves the original token order after normalization.
        Exercise 3: Stop the linked section here.
        """)
        let chunks = try await library.store.documentChunks(itemID: item.id)
        let exerciseTwo = try XCTUnwrap(chunks.first { $0.text.contains("# Exercise 2:") })
        let support = try XCTUnwrap(chunks.first { $0.text.contains("preserves the original token order") })
        XCTAssertNotEqual(exerciseTwo.id, support.id)

        let result = try await DocumentRetrievalService(library: library).retrieve(.init(
            sessionID: session, question: "explain ex1 in Marked.docx"))
        XCTAssertTrue(result.evidence.map(\.text).joined(separator: "\n").contains("preserves the original token order"))
    }
    func testPassageLinksSkipAmbiguousSectionTargetsAndStayWithinDocument() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let session = UUID()
        let ambiguous = try await upload(library, session: session, name: "Ambiguous.docx", text: """
        Exercise 1: Use the concept described in Section 4.
        Section 4: First definition
        First version.
        Section 4: Second definition
        Second version.
        """)
        let other = try await upload(library, session: session, name: "Other.docx", text: """
        Section 4: External definition
        This definition belongs to another upload.
        """)
        let links = try await library.store.documentPassageLinks(documentID: ambiguous.id, revision: ambiguous.revision)
        XCTAssertFalse(links.contains { $0.kind == "section" })
        let selected = try await library.store.linkedDocumentChunks(documentID: ambiguous.id, revision: ambiguous.revision,
            sourceChunkIDs: (try await library.store.documentChunks(itemID: ambiguous.id)).map(\.id))
        XCTAssertTrue(selected.isEmpty)
        XCTAssertNotEqual(ambiguous.id, other.id)

        let missingLocalTarget = try await upload(library, session: session, name: "Local-only.docx",
            text: "Exercise 1: See Section 9 for the rule.")
        _ = try await upload(library, session: session, name: "External.docx", text: "Section 9: Rule\nExternal-only support.")
        let localLinks = try await library.store.documentPassageLinks(documentID: missingLocalTarget.id,
            revision: missingLocalTarget.revision)
        XCTAssertTrue(localLinks.isEmpty)

        let duplicateQuestion = try await upload(library, session: session, name: "Duplicate-question.docx", text: """
        Exercise 1: Use the supporting explanation in Question 7.
        Question 7: First explanation.
        Question 7: Second explanation.
        """)
        let duplicateQuestionLinks = try await library.store.documentPassageLinks(documentID: duplicateQuestion.id,
            revision: duplicateQuestion.revision)
        XCTAssertFalse(duplicateQuestionLinks.contains { $0.kind == "question" })
    }
    func testArabicExerciseReferenceLinksAndCycleTraversalStopsAfterOneHop() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let session = UUID()
        let arabic = try await upload(library, session: session, name: "Arabic.docx", text: """
        التمرين ١: استخدم القاعدة الموضحة في التمرين ٢.
        التمرين ٢: قاعدة التحليل اللغوي.
        تُستخدم هذه القاعدة لتقسيم النص إلى رموز.
        """)
        let arabicLinks = try await library.store.documentPassageLinks(documentID: arabic.id, revision: arabic.revision)
        XCTAssertTrue(arabicLinks.contains { $0.kind == "exercise" && $0.sourceText.contains("التمرين ٢") })
        let arabicAnswer = try await DocumentRetrievalService(library: library).retrieve(.init(
            sessionID: session, question: "اشرح التمرين ١ في Arabic.docx"))
        XCTAssertTrue(arabicAnswer.evidence.map(\.text).joined().contains("تقسيم النص إلى رموز"),
                      arabicAnswer.evidence.map(\.text).joined(separator: "\n---\n"))

        let cyclic = try await upload(library, session: session, name: "Cycle.docx", text: """
        Exercise 1: See Exercise 2 for the helper.
        Exercise 2: See Exercise 1 and Section 3 for the rule.
        Exercise 3: End the helper section.
        Section 3: Second-hop rule
        This definition is reachable only from the linked helper.
        """)
        let result = try await DocumentRetrievalService(library: library).retrieve(.init(
            sessionID: session, question: "explain ex1 in Cycle.docx"))
        let evidence = result.evidence.map(\.text).joined(separator: "\n")
        XCTAssertTrue(evidence.contains("See Exercise 2 for the helper"))
        XCTAssertTrue(evidence.contains("See Exercise 1 and Section 3 for the rule"))
        XCTAssertFalse(evidence.contains("reachable only from the linked helper"),
                       "A target’s outgoing links must not be traversed recursively")
        let cycleChunks = try await library.store.documentChunks(itemID: cyclic.id)
        let exerciseOne = try XCTUnwrap(cycleChunks.first { $0.text.contains("Exercise 1:") })
        let directTargets = try await library.store.linkedDocumentChunks(documentID: cyclic.id,
            revision: cyclic.revision, sourceChunkIDs: [exerciseOne.id])
        XCTAssertEqual(directTargets.count, 1)
    }
    func testCrossDocumentRetrievalExpandsLinksWithinEachDocument() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let session = UUID()
        let alpha = try await upload(library, session: session, name: "Alpha.docx", text: """
        Exercise 1: Searchseed alpha parser uses Section 2.
        Section 2: Alpha definition
        Alpha-only support passage.
        """)
        let beta = try await upload(library, session: session, name: "Beta.docx", text: """
        Exercise 1: Searchseed beta parser uses Section 2.
        Section 2: Beta definition
        Beta-only support passage.
        """)
        let service = DocumentRetrievalService(library: library)
        let search = try await service.retrieve(.init(sessionID: session,
            question: "Compare searchseed parser across these documents"))
        let searchText = search.evidence.map(\.text).joined(separator: "\n")
        XCTAssertTrue(searchText.contains("Alpha-only support passage"))
        XCTAssertTrue(searchText.contains("Beta-only support passage"))
        XCTAssertEqual(Set(search.evidence.map(\.documentID)), [alpha.id, beta.id])

        let exercise = try await service.retrieve(.init(sessionID: session,
            question: "Compare exercise 1 across these documents"))
        let evidenceByDocument = Dictionary(grouping: exercise.evidence, by: \.documentID)
        XCTAssertTrue(evidenceByDocument[alpha.id]?.map(\.text).joined().contains("Alpha-only support passage") == true)
        XCTAssertTrue(evidenceByDocument[beta.id]?.map(\.text).joined().contains("Beta-only support passage") == true)
        XCTAssertFalse(evidenceByDocument[alpha.id]?.map(\.text).joined().contains("Beta-only support passage") ?? true)
        XCTAssertFalse(evidenceByDocument[beta.id]?.map(\.text).joined().contains("Alpha-only support passage") ?? true)
        XCTAssertEqual(exercise.coverage, .partial, "Linked retrieval must not imply complete document coverage")
    }
    func testPassageIndexLinksToNumberedHeadingRecognizedByExerciseParser() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let session = UUID()
        let item = try await upload(library, session: session, name: "Numbered.docx", text: """
        Exercise 1: Use the helper in Exercise 2.
        2. Helper routine
        Preserve the input order while splitting tokens.
        """)
        let chunks = try await library.store.documentChunks(itemID: item.id)
        let target = try XCTUnwrap(chunks.first { $0.text.contains("2. Helper routine") })
        let links = try await library.store.documentPassageLinks(documentID: item.id, revision: item.revision)
        XCTAssertTrue(links.contains { $0.kind == "exercise" && $0.targetChunkID == target.id })

        let result = try await DocumentRetrievalService(library: library).retrieve(.init(
            sessionID: session, question: "explain ex1 in Numbered.docx"))
        XCTAssertTrue(result.evidence.map(\.text).joined().contains("Preserve the input order"))
    }
    func testPassageLinkExpansionIsBoundedToEightTargets() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let session = UUID()
        let references = (1...12).map { "Section \($0)" }.joined(separator: ", ")
        let text = "Exercise 1: Follow the rules in \(references).\n" +
            (1...12).map { "Section \($0): Rule \($0)\nDefinition \($0)." }.joined(separator: "\n")
        let item = try await upload(library, session: session, name: "Bounded.docx", text: text)
        let chunks = try await library.store.documentChunks(itemID: item.id)
        let source = try XCTUnwrap(chunks.first { $0.text.contains("Exercise 1:") })
        let linked = try await library.store.linkedDocumentChunks(documentID: item.id, revision: item.revision,
            sourceChunkIDs: [source.id], maximumResults: 8)
        XCTAssertEqual(linked.count, 8)
        XCTAssertEqual(Set(linked.map(\.id)).count, linked.count)
        XCTAssertTrue(linked.allSatisfy { $0.documentID == item.id })
    }

    func testTypedLocalReferencesDistinguishKindsAndUseUnambiguousNumberedFallback() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let session = UUID()
        let item = try await upload(library, session: session, name: "Reference-kinds.docx", text: """
        Exercise 1: Use Section 2, Chapter 2, and Section 3.
        Section 2: Section-specific definition
        Chapter 2: Chapter-specific definition
        3. Numbered fallback definition
        Exercise 4: See Section 1 only if a section target exists.
        Exercise 5: See Section 5 only if the numbered target is unique.
        5. First numbered fallback
        5. Second numbered fallback
        """)
        let chunks = try await library.store.documentChunks(itemID: item.id)
        let source = try XCTUnwrap(chunks.first { $0.text.contains("Exercise 1:") })
        let sourceFour = try XCTUnwrap(chunks.first { $0.text.contains("Exercise 4:") })
        let sourceFive = try XCTUnwrap(chunks.first { $0.text.contains("Exercise 5:") })
        let section = try XCTUnwrap(chunks.first { $0.text.contains("Section 2:") })
        let chapter = try XCTUnwrap(chunks.first { $0.text.contains("Chapter 2:") })
        let fallback = try XCTUnwrap(chunks.first { $0.text.contains("3. Numbered fallback") })
        let links = try await library.store.documentPassageLinks(documentID: item.id, revision: item.revision)
        XCTAssertTrue(links.contains { $0.sourceChunkID == source.id && $0.targetChunkID == section.id && $0.kind == "section" })
        XCTAssertTrue(links.contains { $0.sourceChunkID == source.id && $0.targetChunkID == chapter.id && $0.kind == "chapter" })
        XCTAssertTrue(links.contains { $0.sourceChunkID == source.id && $0.targetChunkID == fallback.id && $0.kind == "section" })
        XCTAssertFalse(links.contains { $0.sourceChunkID == sourceFour.id && $0.kind == "section" })
        XCTAssertFalse(links.contains { $0.sourceChunkID == sourceFive.id && $0.kind == "section" })
        XCTAssertTrue(AssignmentContextSearch.sections(for: .init(number: "1", kind: "section"), in: chunks).isEmpty)
        XCTAssertTrue(AssignmentContextSearch.sections(for: .init(number: "5", kind: "section"), in: chunks).isEmpty)

        let result = try await DocumentRetrievalService(library: library).retrieve(.init(
            sessionID: session, question: "explain ex1 in Reference-kinds.docx"))
        let text = result.evidence.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("Section-specific definition"))
        XCTAssertTrue(text.contains("Chapter-specific definition"))
        XCTAssertTrue(text.contains("Numbered fallback definition"))
        XCTAssertEqual(result.evidenceRoles[section.id], .explicitReference)
        XCTAssertEqual(result.evidenceRoles[chapter.id], .explicitReference)
    }

    func testQuotedMarkdownAndBoldHeadingReferencesResolveExactly() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let session = UUID()
        let item = try await upload(library, session: session, name: "Headings.docx", text: """
        Exercise 1: Apply the idea in “Key idea” and the rule in 'Bold idea'.
        ## Key idea
        Keep the parse tree immutable.
        **Bold idea**
        Preserve escaped delimiters.
        """)
        let links = try await library.store.documentPassageLinks(documentID: item.id, revision: item.revision)
        XCTAssertEqual(links.filter { $0.kind == "heading-title" }.count, 2)
        let result = try await DocumentRetrievalService(library: library).retrieve(.init(
            sessionID: session, question: "explain ex1 in Headings.docx"))
        XCTAssertTrue(result.evidence.map(\.text).joined().contains("Keep the parse tree immutable"))
        XCTAssertTrue(result.evidence.map(\.text).joined().contains("Preserve escaped delimiters"))
    }

    func testSemanticSupportRunsAfterLocalLinksAndStaysWithinTheSession() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let session = UUID(), otherSession = UUID()
        let main = try await upload(library, session: session, name: "Main.docx", text: """
        Exercise 1: Explain inheritance using the terminology in Section 4.
        Section 4: Terminology
        Inheritance lets a class reuse behavior from a parent class.
        """)
        let support = try await upload(library, session: session, name: "Support.docx",
            text: "Polymorphism background: related behavior can vary by concrete type.")
        let supportCopy = try await upload(library, session: session, name: "Support-copy.docx",
            text: "Polymorphism background: related behavior can vary by concrete type.")
        let weak = try await upload(library, session: session, name: "Weak.docx",
            text: "A weakly related passage stays below the configured similarity threshold.")
        let outside = try await upload(library, session: otherSession, name: "Outside.docx",
            text: "This matching passage belongs to a different session.")

        for (item, vector) in [(main, [Float(1), 0]), (support, [Float(0.8), 0.6]),
                               (supportCopy, [Float(0.8), 0.6]),
                               (weak, [Float(0.6), 0.8]), (outside, [Float(1), 0])] {
            let chunks = try await library.store.documentChunks(itemID: item.id)
            let saved = try await library.store.setEmbeddings(itemID: item.id, revision: item.revision,
                identity: "synthetic-related-v1", vectors: chunks.map { _ in vector })
            XCTAssertTrue(saved)
        }

        let result = try await DocumentRetrievalService(library: library).retrieve(.init(
            sessionID: session, question: "explain ex1 in Main.docx"))
        let included = Set(result.evidence.map(\.documentID))
        XCTAssertTrue(result.evidence.map(\.text).joined().contains("Inheritance lets a class"))
        XCTAssertTrue(result.evidence.map(\.text).joined().contains("Polymorphism background"))
        XCTAssertFalse(result.evidence.map(\.text).joined().contains("below the configured similarity"))
        XCTAssertFalse(included.contains(outside.id))
        XCTAssertEqual(result.focus?.documentID, main.id)
        XCTAssertEqual(result.coverage, .partial)
        XCTAssertEqual(result.documentCoverage["Main.docx"], .partial)
        let duplicateSupportIDs: Set<UUID> = [support.id, supportCopy.id]
        let supportChunk = try XCTUnwrap(result.evidence.first { duplicateSupportIDs.contains($0.documentID) })
        XCTAssertEqual(result.evidence.filter { duplicateSupportIDs.contains($0.documentID) }.count, 1)
        XCTAssertEqual(result.documentCoverage[supportChunk.filename], .partial)
        let semanticCount = result.evidenceRoles.values.filter {
            if case .semanticSupport = $0 { return true }
            return false
        }.count
        XCTAssertLessThanOrEqual(semanticCount, 4)
        let localTargetIndex = try XCTUnwrap(result.evidence.firstIndex { $0.text.contains("Terminology") })
        let semanticSupportIndex = try XCTUnwrap(result.evidence.firstIndex { duplicateSupportIDs.contains($0.documentID) })
        XCTAssertLessThan(localTargetIndex, semanticSupportIndex)
        guard case .semanticSupport(let seedID, let similarity) = result.evidenceRoles[supportChunk.id] else {
            return XCTFail("Related passage should retain its semantic provenance")
        }
        XCTAssertTrue(result.evidence.contains { $0.id == seedID })
        XCTAssertEqual(similarity, 0.8, accuracy: 0.0001)
    }

    func testEvidenceAssemblyDeduplicatesNormalizedTextInPriorityOrder() {
        let documentID = UUID()
        let primary = DocumentChunk(id: UUID(), documentID: documentID, filename: "Main.docx", index: 0,
            text: "Parent-class behavior supports reuse.", sourceURL: nil, location: nil)
        let duplicate = DocumentChunk(id: UUID(), documentID: UUID(), filename: "Support.docx", index: 1,
            text: "parent class behavior supports reuse!", sourceURL: nil, location: nil)
        let later = DocumentChunk(id: UUID(), documentID: documentID, filename: "Main.docx", index: 2,
            text: "A distinct example explains polymorphism.", sourceURL: nil, location: nil)

        let selected = DocumentRetrievalService.assemble([primary, duplicate, later], budget: 12_000,
            overview: false, preserveOrder: true)
        XCTAssertEqual(selected.map(\.id), [primary.id, later.id])
    }

    func testPassageLinkIndexRebuildsForLegacyLibrariesAndRevisions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("knowledge.sqlite")
        let session = UUID()
        let library = KnowledgeLibrary(storageURL: url, embeddingProvider: nil); await library.load()
        let original = try await upload(library, session: session, name: "Links.docx", text: """
        Exercise 1: Follow the parser rule in Section 2.
        Section 2: Parser rule
        Preserve escaped delimiters.
        """)
        let originalLinks = try await library.store.documentPassageLinks(documentID: original.id, revision: original.revision)
        XCTAssertFalse(originalLinks.isEmpty)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM document_passage_links; DELETE FROM document_link_indexes; PRAGMA user_version=5", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let reopened = KnowledgeLibrary(storageURL: url, embeddingProvider: nil); await reopened.load()
        let restored = try await reopened.store.documentPassageLinks(documentID: original.id, revision: original.revision)
        XCTAssertEqual(restored, originalLinks)

        let updated = try await upload(reopened, session: session, name: "Links.docx", text: """
        Exercise 1: Use no external rules.
        Section 2: Parser rule
        Preserve escaped delimiters.
        """)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertGreaterThan(updated.revision, original.revision)
        let updatedLinks = try await reopened.store.documentPassageLinks(documentID: updated.id, revision: updated.revision)
        XCTAssertTrue(updatedLinks.isEmpty)
        let updatedChunks = try await reopened.store.documentChunks(itemID: updated.id)
        let staleTargets = try await reopened.store.linkedDocumentChunks(documentID: updated.id, revision: original.revision,
            sourceChunkIDs: updatedChunks.map(\.id))
        XCTAssertTrue(staleTargets.isEmpty)
    }
    func testIndexRebuildKeepsSourceAndPlannerAndRejectsStaleVectors() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
        let item = try await upload(library, session: UUID(), name: "OOP.docx", text: lab)
        let before = try await library.store.pendingDocuments().first { $0.itemID == item.id }!
        let records = try await library.store.ingestionRecords()
        let committed = try await library.store.rebuildDocumentIndex(itemID: item.id, revision: item.revision,
            text: lab.replacingOccurrences(of: "Vehicle", with: "Transport"))
        XCTAssertTrue(committed)
        let after = try await library.store.items().first { $0.id == item.id }!
        XCTAssertEqual(after.contentHash, item.contentHash)
        XCTAssertEqual(after.revision, item.revision)
        XCTAssertEqual(after.text, item.text)
        let afterRecords = try await library.store.ingestionRecords()
        XCTAssertEqual(records, afterRecords)
        let stale = try await library.store.setEmbeddings(itemID: item.id, revision: item.revision, identity: "test", vectors: before.chunks.map { _ in [Float(1), 0] }, expectedChunkIDs: before.chunkIDs)
        XCTAssertFalse(stale)
        let rejected = try await library.store.rebuildDocumentIndex(itemID: item.id, revision: item.revision - 1, text: "stale")
        XCTAssertFalse(rejected)
    }
    func testLegacyIndexUpgradePreservesOriginalContentAndDoesNotReimportPlanner() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("knowledge.sqlite")
        let original = KnowledgeLibrary(storageURL: url, embeddingProvider: nil); await original.load()
        let item = try await upload(original, session: UUID(), name: "MissingOriginal.docx", text: lab)
        let records = try await original.store.ingestionRecords()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM document_indexes; PRAGMA user_version=4", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let reopened = KnowledgeLibrary(storageURL: url, embeddingProvider: nil); await reopened.load()
        let after = try XCTUnwrap(reopened.items.first { $0.id == item.id })
        XCTAssertEqual(after.text, item.text)
        XCTAssertEqual(after.contentHash, item.contentHash)
        XCTAssertEqual(after.revision, item.revision)
        let pending = try await reopened.store.documentsNeedingStructure()
        XCTAssertTrue(pending.isEmpty)
        let afterRecords = try await reopened.store.ingestionRecords()
        XCTAssertEqual(records, afterRecords)
        let chunks = try await reopened.store.documentChunks(itemID: item.id)
        XCTAssertTrue(chunks.map(\.text).joined().contains("Original source unavailable"))
        let restarted = KnowledgeLibrary(storageURL: url, embeddingProvider: nil); await restarted.load()
        let stable = try await restarted.store.documentChunks(itemID: item.id)
        XCTAssertEqual(stable.map(\.id), chunks.map(\.id))
    }
    func testPackageNamesAndContentsListsDoNotReplaceTheExercise() throws {
        let text = "Create packages lab8.ex1 and lab8.ex2. Copy into lab8.ex1.\nExercise 1\nExercise 2\nIntroduction\nExercise 1: Refactor\n" + String(repeating: "Update CourseAdmin and assign professors. ", count: 10) + "\nExercise 2: Other work"
        let id = UUID()
        let chunks = try StructuredDocumentChunker.chunks(text).enumerated().map {
            DocumentChunk(id: UUID(), documentID: id, filename: "Lab", index: $0.offset, text: $0.element)
        }
        let section = AssignmentContextSearch.section(for: DocumentQuestionReference.first(in: "ex1")!, in: chunks)
        XCTAssertTrue(section.map(\.text).joined().contains("Update CourseAdmin"))
        XCTAssertFalse(section.map(\.text).joined().contains("Other work"))
    }
    func testMarkdownExercisesAndVeryLongLinesKeepBoundedContext() throws {
        let text = "# Lab\n## Exercise 1\nDefine a subclass.\n## Exercise 2\nOther work"
        let id = UUID()
        let chunks = try StructuredDocumentChunker.chunks(text).enumerated().map {
            DocumentChunk(id: UUID(), documentID: id, filename: "Lab.md", index: $0.offset, text: $0.element)
        }
        let section = AssignmentContextSearch.section(for: DocumentQuestionReference.first(in: "ex1")!, in: chunks)
        XCTAssertTrue(section.map(\.text).joined().contains("Define a subclass"))
        XCTAssertFalse(section.map(\.text).joined().contains("Other work"))
        let long = try StructuredDocumentChunker.chunks(String(repeating: "x", count: 160_000))
        XCTAssertEqual(long.count, 100)
        XCTAssertTrue(long.allSatisfy { $0.count <= 1_600 })
    }
    func testLongOverviewIncludesLaterExerciseHeadings() throws {
        let text = (1...20).map { "Exercise \($0): Requirement \($0)\n" + String(repeating: "Detailed instructions. ", count: 100) }.joined(separator: "\n")
        let itemID = UUID()
        let chunks = try StructuredDocumentChunker.chunks(text).enumerated().map {
            DocumentChunk(id: UUID(), documentID: itemID, filename: "Long", index: $0.offset, text: $0.element)
        }
        let evidence = DocumentRetrievalService.assemble(chunks, budget: 8_000, overview: true)
        let joined = evidence.map(\.text).joined()
        for number in 1...20 { XCTAssertTrue(joined.contains("Exercise \(number):")) }
        XCTAssertLessThanOrEqual(evidence.reduce(0) { $0 + $1.text.count }, 8_000)
    }
    func testSuppliedLabsLocallyWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["KADDO_VERIFY_LOCAL_LABS"] == "1" else {
            throw XCTSkip("Opt-in local validation; private uploads are never fixtures or sent to a cloud provider.")
        }
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        for name in ["Lab5_StudentVersion-Instructions(1).docx", "Lab8_OOP_Lab_InheritancePart2StudentVersion (25).docx"] {
            let source = downloads.appendingPathComponent(name)
            let text = try KnowledgeLibrary.extract(source)
            XCTAssertTrue(text.contains("[Image "), "Embedded images must be represented in extracted context")
            let library = KnowledgeLibrary(embeddingProvider: nil); await library.load()
            let session = UUID()
            _ = try await library.saveUploadedDocument(.init(id: session, title: "Local verification"), url: source, text: text)
            let service = DocumentRetrievalService(library: library)
            let overview = try await service.retrieve(.init(sessionID: session, question: "what should I do?"))
            XCTAssertGreaterThan(overview.evidence.map(\.text).joined().count, 1_000)
            XCTAssertEqual(overview.coverage, .complete)
            let exercise = try await service.retrieve(.init(sessionID: session, question: "explain ex1"))
            XCTAssertGreaterThan(exercise.evidence.map(\.text).joined().count, 150)
            XCTAssertFalse(exercise.evidence.map(\.text).joined().contains("Exercise 2:"))
            print("Local lab verification: \(name), \(overview.evidence.count) context blocks, \(text.count) extracted characters.")
        }
    }
    func testScannedPDFAndDOCXEmbeddedImageAreReadLocally() throws {
        let image = NSImage(size: NSSize(width: 1200, height: 300))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 300).fill()
        ("Implement inheritance with Vehicle and Car" as NSString).draw(at: NSPoint(x: 30, y: 140), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let cg = try XCTUnwrap(LocalDocumentOCR.image(try XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: pdf))
        var bounds = CGRect(x: 0, y: 0, width: 1200, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.draw(cg, in: bounds); context.endPDFPage(); context.closePDF()
        let pdfURL = folder.appendingPathComponent("Scanned.pdf")
        try (pdf as Data).write(to: pdfURL)
        let pdfText = try KnowledgeLibrary.extract(pdfURL)
        XCTAssertTrue(pdfText.contains("Vehicle"))
        XCTAssertTrue(pdfText.contains("[Page 1: local OCR; confidence"))
        let xml = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body><w:p><w:r><w:t>Exercise 1: Follow this diagram</w:t></w:r></w:p><w:p><a:blip r:embed="rId1"/></w:p></w:body></w:document>"#
        let rels = #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Target="media/image.png"/></Relationships>"#
        let parts = [("word/document.xml", Data(xml.utf8)), ("word/_rels/document.xml.rels", Data(rels.utf8)), ("word/media/image.png", png)]
        let docURL = folder.appendingPathComponent("Diagram.docx")
        try retrievalTestArchive(parts).write(to: docURL)
        let docText = try KnowledgeLibrary.extract(docURL)
        XCTAssertTrue(docText.contains("Exercise 1"))
        XCTAssertTrue(docText.contains("Vehicle"))
        XCTAssertTrue(docText.contains("[Image 1: local OCR; confidence"))
        let brokenParts = [("word/document.xml", Data(xml.utf8)), ("word/_rels/document.xml.rels", Data(rels.utf8)), ("word/media/image.png", Data([1, 2, 3]))]
        try retrievalTestArchive(brokenParts).write(to: docURL)
        let partial = try KnowledgeLibrary.extract(docURL)
        XCTAssertTrue(partial.contains("Exercise 1"))
        XCTAssertTrue(partial.contains("diagram needs visual interpretation"))
        var limits = DocumentExtractionLimits(); limits.maxXMLBytes = 10
        XCTAssertThrowsError(try DocumentTextExtractor(limits: limits).extract(at: docURL) { _ in })
    }

    func testLocalOCRReadsRenderedTextAndPreservesImagePosition() throws {
        let width = 1200, height = 300
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        ("Vehicle inherits Transport" as NSString).draw(at: NSPoint(x: 40, y: 140), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let data = try XCTUnwrap(image.tiffRepresentation)
        let cg = try XCTUnwrap(LocalDocumentOCR.image(data))
        let recognized = try LocalDocumentOCR.recognize(cg)
        XCTAssertTrue(recognized.text.contains("Vehicle"))
        XCTAssertGreaterThan(recognized.confidence, 0)
        var text = ""
        let xml = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body><w:p><w:r><w:t>Exercise 1</w:t></w:r></w:p><w:p><a:blip r:embed="rId4"/></w:p><w:p><w:r><w:t>Exercise 2</w:t></w:r></w:p></w:body></w:document>"#
        try WordXMLTextReader.read(Data(xml.utf8), emit: { text += $0 }, imageText: { id in
            XCTAssertEqual(id, "rId4")
            return "[Image 1: local OCR; confidence 0.9]\n" + recognized.text
        })
        let one = try StructuredDocumentChunker.chunks(text)
        let id = UUID()
        let chunks = one.enumerated().map { DocumentChunk(id: UUID(), documentID: id, filename: "Test", index: $0.offset, text: $0.element) }
        let section = AssignmentContextSearch.section(for: DocumentQuestionReference.first(in: "ex1")!, in: chunks)
        XCTAssertTrue(section.map(\.text).joined().contains("Vehicle"))
        XCTAssertFalse(section.map(\.text).joined().contains("Exercise 2"))
    }
}

/// Tiny stored ZIP fixture writer; private documents are never copied into fixtures.
private func retrievalTestArchive(_ parts: [(String, Data)]) -> Data {
    var result = Data()
    var entries: [(Data, Data, Int, Int)] = []
    func append(_ value: Int, _ width: Int) {
        for shift in 0..<width { result.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
    }
    for (path, data) in parts {
        let name = Data(path.utf8), offset = result.count
        let crc = data.withUnsafeBytes { Int(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
        entries.append((name, data, crc, offset))
        append(0x04034b50, 4)
        for value in [20, 0, 0, 0, 0] { append(value, 2) }
        append(crc, 4); append(data.count, 4); append(data.count, 4)
        append(name.count, 2); append(0, 2)
        result.append(name); result.append(data)
    }
    let start = result.count
    for (name, data, crc, offset) in entries {
        append(0x02014b50, 4)
        for value in [20, 20, 0, 0, 0, 0] { append(value, 2) }
        append(crc, 4); append(data.count, 4); append(data.count, 4)
        for value in [name.count, 0, 0, 0, 0] { append(value, 2) }
        append(0, 4); append(offset, 4); result.append(name)
    }
    let size = result.count - start
    append(0x06054b50, 4)
    for value in [0, 0, entries.count, entries.count] { append(value, 2) }
    append(size, 4); append(start, 4); append(0, 2)
    return result
}
