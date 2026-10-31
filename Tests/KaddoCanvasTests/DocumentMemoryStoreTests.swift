import Combine
import XCTest
@testable import KaddoCanvas

final class DocumentMemoryStoreTests: XCTestCase {
    @MainActor
    func testImportsRealDocumentsAndPublishesAtomicChunks() async throws {
        let model = PetApplicationState()
        let store = model.documentMemory
        var publications: [[DocumentChunk]] = []
        let token = store.$chunks.dropFirst().sink { publications.append($0) }
        let count = try await store.importDocument(at: documentFixture("LongNotes.docx"))
        XCTAssertGreaterThan(count, 1)
        XCTAssertTrue(store.chunks.allSatisfy { $0.text.count <= 1_600 })
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(store.chunks.count, count)
        XCTAssertEqual(Set(store.chunks.map(\.id)).count, count)
        XCTAssertEqual(Set(store.chunks.map(\.documentID)).count, 1)
        XCTAssertEqual(store.chunks.map(\.index), Array(0..<count))
        XCTAssertTrue(store.chunks.allSatisfy { $0.filename == "LongNotes.docx" })
        XCTAssertFalse(store.isImporting)
        XCTAssertTrue(DocumentMemoryStore().chunks.isEmpty, "Context must not persist")
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testFailureKeepsExistingContextAndResetsBusyState() async throws {
        let store = DocumentMemoryStore()
        try await store.importDocument(at: documentFixture("FocusNotes.docx"))
        let before = store.chunks
        do {
            try await store.importDocument(at: documentFixture("ExternalEntity.docx"))
            XCTFail("Malicious input imported")
        } catch { XCTAssertEqual(error as? DocumentImportError, .invalidDocument) }
        XCTAssertEqual(store.chunks, before)
        XCTAssertFalse(store.isImporting)
        try await store.importDocument(at: documentFixture("Research.pdf"))
        XCTAssertEqual(Set(store.chunks.map(\.documentID)).count, 2)
        store.removeDocument(id: before[0].documentID)
        XCTAssertTrue(store.chunks.allSatisfy { $0.filename == "Research.pdf" })
        store.clear()
        XCTAssertTrue(store.chunks.isEmpty)
    }

    @MainActor
    func testMemoryBudgetsRejectWholeImport() async {
        for store in [DocumentMemoryStore(maxStoredBytes: 10), DocumentMemoryStore(maxStoredChunks: 0)] {
            do {
                try await store.importDocument(at: documentFixture("FocusNotes.docx"))
                XCTFail("Memory budget was exceeded")
            } catch { XCTAssertEqual(error as? DocumentImportError, .memoryLimitReached) }
            XCTAssertTrue(store.chunks.isEmpty)
            XCTAssertFalse(store.isImporting)
        }
    }

    @MainActor
    func testClearCancelsInFlightImportAndPreventsLateCommit() async throws {
        let store = DocumentMemoryStore()
        let task = Task { try await store.importDocument(at: documentFixture("LongNotes.docx")) }
        for _ in 0..<1_000 {
            if store.isImporting { break }
            await Task.yield()
        }
        XCTAssertTrue(store.isImporting)
        store.clear()
        do { _ = try await task.value; XCTFail("Import survived clear") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(store.chunks.isEmpty)
        XCTAssertFalse(store.isImporting)
        try await store.importDocument(at: documentFixture("Research.pdf"))
        XCTAssertFalse(store.chunks.isEmpty)
    }

    @MainActor
    func testConcurrentImportIsRejectedAndParentCancellationPropagates() async {
        let store = DocumentMemoryStore()
        let task = Task { try await store.importDocument(at: documentFixture("LongNotes.docx")) }
        for _ in 0..<1_000 {
            if store.isImporting { break }
            await Task.yield()
        }
        XCTAssertTrue(store.isImporting)
        do {
            try await store.importDocument(at: documentFixture("Research.pdf"))
            XCTFail("Concurrent import started")
        } catch { XCTAssertEqual(error as? DocumentImportError, .importInProgress) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled import committed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(store.chunks.isEmpty)
        XCTAssertFalse(store.isImporting)
    }

    @MainActor
    func testRepeatedImportClearAndOwnerRelease() async throws {
        var store: DocumentMemoryStore? = DocumentMemoryStore()
        weak var weakStore = store
        for _ in 0..<30 {
            try await store?.importDocument(at: documentFixture("FocusNotes.docx"))
            XCTAssertFalse(store!.chunks.isEmpty)
            store?.clear()
            XCTAssertTrue(store!.chunks.isEmpty)
        }
        store = nil
        XCTAssertNil(weakStore, "Completed workers must not retain the context store")
    }
}
