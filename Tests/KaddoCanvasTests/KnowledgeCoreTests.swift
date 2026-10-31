import XCTest
import CSQLite
@testable import KaddoCanvas

final class KnowledgeCoreTests: XCTestCase {
    func testPersistenceDedupeCategoriesAndDelete() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("knowledge.sqlite")
        let store = KnowledgeStore(storageURL: url)
        let category = try await store.addCategory(name: "Research")
        let item = try await store.upsert(title: "Notes", text: "A rare quasar glows brightly.", categoryID: category.id)
        let duplicate = try await store.upsert(title: "Other filename", text: item.text, categoryID: category.id)
        XCTAssertEqual(item.id, duplicate.id)
        let reopened = KnowledgeStore(storageURL: url)
        let items = try await reopened.items()
        XCTAssertEqual(items, [item])
        let categories = try await reopened.categories()
        XCTAssertTrue(categories.contains(category))
        let matches = try await reopened.search(query: "quasar")
        XCTAssertEqual(matches.first?.itemID, item.id)
        try await reopened.deleteItem(id: item.id)
        let after = try await reopened.search(query: "quasar")
        XCTAssertTrue(after.isEmpty)
    }
    func testKeywordFilteringSafeFTSAndUnrelatedQuery() async throws {
        let store = KnowledgeStore()
        _ = try await store.upsert(title: "Astronomy", text: "The quasar is bright.", categoryID: KnowledgeCategory.study.id)
        _ = try await store.upsert(title: "Work", text: "The invoice is overdue.", categoryID: KnowledgeCategory.work.id)
        let unrelated = try await store.search(query: "What is the volcano temperature?")
        XCTAssertTrue(unrelated.isEmpty)
        let injection = try await store.search(query: #"quasar" OR * NEAR( --"#)
        XCTAssertEqual(injection.count, 1)
        let filtered = try await store.search(query: "quasar invoice", categoryID: KnowledgeCategory.work.id)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.title, "Work")
    }
    func testParagraphChunksVectorValidationAndStaleGeneration() async throws {
        let store = KnowledgeStore()
        let item = try await store.upsert(title: "Two facts", text: "Quasars shine.\n\nInvoices expire.", categoryID: KnowledgeCategory.general.id)
        let pending = try await store.pendingDocuments()
        XCTAssertEqual(pending[0].chunks.count, 2)
        let indexed = try await store.setEmbeddings(itemID: item.id, revision: item.revision, identity: "model:a", vectors: [[1,0], [0,1]])
        XCTAssertTrue(indexed)
        let semantic = try await store.search(query: "galaxies", vector: [1,0], identity: "model:a")
        XCTAssertEqual(semantic.map(\.text), ["Quasars shine."])
        let incompatible = try await store.search(query: "galaxies", vector: [1,0], identity: "model:b")
        XCTAssertTrue(incompatible.isEmpty)
        let updated = try await store.upsert(title: "New fact", text: "Suns are stars.", categoryID: item.categoryID, id: item.id)
        XCTAssertEqual(updated.revision, 2)
        let stale = try await store.setEmbeddings(itemID: item.id, revision: item.revision, identity: "model:a", vectors: [[1,0], [0,1]])
        XCTAssertFalse(stale)
        try await store.deleteItem(id: item.id)
        let deleted = try await store.setEmbeddings(itemID: item.id, revision: updated.revision, identity: "model:a", vectors: [[1,0]])
        XCTAssertFalse(deleted)
    }
    func testEmbeddingBatchesPersistAndResumeOnlyMissingChunks() async throws {
        let store = KnowledgeStore()
        let item = try await store.upsert(title: "Two chunks", text: "First passage.\n\nSecond passage.", categoryID: KnowledgeCategory.general.id)
        let initialPending = try await store.pendingDocuments()
        let pending = try XCTUnwrap(initialPending.first)
        XCTAssertEqual(pending.chunks.count, 2)
        _ = try await store.reconcileEmbeddingProfile(identity: "model:a", dimensions: 2)
        let firstSaved = try await store.setEmbeddingBatch(itemID: item.id, revision: item.revision, identity: "model:a",
            chunkIDs: [pending.chunkIDs[0]], vectors: [[1, 0]])
        XCTAssertTrue(firstSaved)
        let resumedPending = try await store.pendingDocuments()
        let resumed = try XCTUnwrap(resumedPending.first)
        XCTAssertEqual(resumed.chunkIDs, [pending.chunkIDs[1]])
        XCTAssertEqual(resumed.chunks, ["Second passage."])
        let unfinished = try await store.finishEmbedding(itemID: item.id, revision: item.revision)
        XCTAssertFalse(unfinished)
        let secondSaved = try await store.setEmbeddingBatch(itemID: item.id, revision: item.revision, identity: "model:a",
            chunkIDs: resumed.chunkIDs, vectors: [[0, 1]])
        XCTAssertTrue(secondSaved)
        let finished = try await store.finishEmbedding(itemID: item.id, revision: item.revision)
        XCTAssertTrue(finished)
        let after = try await store.pendingDocuments()
        XCTAssertTrue(after.isEmpty)
    }
    func testModelAndDimensionChangesInvalidateOtherItems() async throws {
        let store = KnowledgeStore()
        let a = try await store.upsert(title: "One", text: "First fact.", categoryID: KnowledgeCategory.general.id)
        let b = try await store.upsert(title: "Two", text: "Second fact.", categoryID: KnowledgeCategory.general.id)
        _ = try await store.setEmbeddings(itemID: a.id, revision: 1, identity: "digest:a", vectors: [[1,0]])
        _ = try await store.setEmbeddings(itemID: b.id, revision: 1, identity: "digest:a", vectors: [[1,0,0]])
        let items = try await store.items()
        XCTAssertEqual(items.first { $0.id == a.id }?.indexingStatus, .pending)
        try await store.prepareEmbeddingIdentity("digest:b")
        let pending = try await store.pendingDocuments()
        XCTAssertEqual(pending.count, 2)
        do {
            _ = try await store.setEmbeddings(itemID: a.id, revision: 1, identity: "digest:b", vectors: [[0,0]])
            XCTFail("Zero vector accepted")
        } catch { XCTAssertEqual(error as? KnowledgeError, .invalidEmbedding) }
    }
    func testSourceReconcilePreservesMovesAndManualItemsAndIsAtomic() async throws {
        let store = KnowledgeStore()
        _ = try await store.upsert(title: "Manual", text: "Manual private fact.", categoryID: KnowledgeCategory.general.id)
        try await store.reconcile(sources: [.init(sourceKey: "profile:name", title: "Profile", text: "Name is Ada", categoryName: "Personal", kind: "profile")])
        let synced = try await store.items().first { $0.sourceKind == "profile" }!
        try await store.moveItem(id: synced.id, categoryID: KnowledgeCategory.work.id)
        try await store.reconcile(sources: [.init(sourceKey: "profile:name", title: "Profile", text: "Name is Grace", categoryName: "Personal", kind: "profile")])
        let changed = try await store.items().first { $0.sourceKind == "profile" }!
        XCTAssertEqual(changed.id, synced.id)
        XCTAssertEqual(changed.categoryID, KnowledgeCategory.work.id)
        do {
            try await store.reconcile(sources: [.init(sourceKey: "bad", title: "", text: "invalid", kind: "profile")])
            XCTFail("Invalid sync accepted")
        } catch { }
        let preserved = try await store.items()
        XCTAssertEqual(preserved.count, 2)
        try await store.reconcile(sources: [])
        let manual = try await store.items()
        XCTAssertEqual(manual.count, 1)
        XCTAssertEqual(manual.first?.title, "Manual")
    }
    func testCorruptAndFutureDatabasesArePreserved() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("bad.sqlite")
        let bytes = Data("not a sqlite database".utf8)
        try bytes.write(to: url)
        do { try await KnowledgeStore(storageURL: url).load(); XCTFail("Corruption accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let futureURL = folder.appendingPathComponent("future.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(futureURL.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let before = try Data(contentsOf: futureURL)
        do { try await KnowledgeStore(storageURL: futureURL).load(); XCTFail("Future schema accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: futureURL), before)
    }
    @MainActor func testLibrarySavesOfflineAndImportsOnlyValidTextAtomically() async throws {
        let library = KnowledgeLibrary(embeddingProvider: nil)
        await library.load()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let valid = folder.appendingPathComponent("notes.md")
        try Data("The cobalt artifact belongs to Ada.".utf8).write(to: valid)
        let imported = await library.importDocument(at: valid)
        XCTAssertTrue(imported)
        let duplicate = await library.importDocument(at: valid)
        XCTAssertTrue(duplicate)
        XCTAssertEqual(library.items.count, 1)
        let invalid = folder.appendingPathComponent("bad.txt")
        try Data([0xff, 0xfe, 0]).write(to: invalid)
        let failed = await library.importDocument(at: invalid)
        XCTAssertFalse(failed)
        XCTAssertEqual(library.items.count, 1)
        let result = await library.search(query: "cobalt")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(library.items.first?.indexingStatus, .pending)
    }
}

private actor RetryKnowledgeEmbedding: KnowledgeEmbeddingProvider {
    nonisolated let identity = "test:model"
    var available = false
    func enable() { available = true }
    func embeddings(for texts: [String]) throws -> [[Float]] {
        guard available else { throw LocalInferenceError.serviceUnavailable }
        return texts.map { _ in [1,0] }
    }
}

private actor GatedKnowledgeEmbedding: KnowledgeEmbeddingProvider {
    nonisolated let identity = "test:gate"
    private var started = false
    private var gate: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { gate?.resume(); gate = nil }
    func embeddings(for texts: [String]) async -> [[Float]] {
        if !started {
            started = true
            observer?.resume(); observer = nil
            await withCheckedContinuation { gate = $0 }
        }
        return texts.map { _ in [1,0] }
    }
}

extension KnowledgeCoreTests {
    @MainActor func testRetryUnavailableProviderAndDeletedIndexTaskCannotResurrectItem() async throws {
        let retryProvider = RetryKnowledgeEmbedding()
        let retryLibrary = KnowledgeLibrary(embeddingProvider: retryProvider)
        _ = await retryLibrary.addNote(title: "Retry", text: "A cobalt telescope.")
        await retryLibrary.waitForIndexing()
        XCTAssertEqual(retryLibrary.items.first?.indexingStatus, .failed)
        let offline = await retryLibrary.search(query: "cobalt")
        XCTAssertEqual(offline.count, 1)
        await retryProvider.enable()
        await retryLibrary.retryIndexing()
        await retryLibrary.waitForIndexing()
        XCTAssertEqual(retryLibrary.items.first?.indexingStatus, .indexed)
        XCTAssertNil(retryLibrary.error)

        let gated = GatedKnowledgeEmbedding()
        let library = KnowledgeLibrary(embeddingProvider: gated)
        _ = await library.addNote(title: "Delete during indexing", text: "A transient telescope.")
        await gated.waitUntilStarted()
        let itemID = try XCTUnwrap(library.items.first?.id)
        _ = await library.deleteItem(id: itemID)
        await gated.release()
        await library.waitForIndexing()
        XCTAssertTrue(library.items.isEmpty)
        let stored = try await library.store.items()
        XCTAssertTrue(stored.isEmpty)
    }
    func testCalibratedSemanticThresholdAndContextBudget() async throws {
        let store = KnowledgeStore()
        for index in 0..<8 {
            let item = try await store.upsert(title: "Fact \(index)", text: String(repeating: "cobalt ", count: 220) + "\(index)", categoryID: KnowledgeCategory.general.id)
            _ = try await store.setEmbeddings(itemID: item.id, revision: 1, identity: "test", vectors: [[0.5,0.8660254]])
        }
        let matches = try await store.search(query: "paraphrase", vector: [1,0], identity: "test")
        XCTAssertFalse(matches.isEmpty) // cosine .5 matches the calibrated .45 threshold.
        XCTAssertLessThanOrEqual(matches.count, 5)
        XCTAssertLessThanOrEqual(matches.reduce(0) { $0 + $1.text.count }, 6_000)
        let unrelated = try await store.search(query: "unrelated", vector: [-1,0], identity: "test")
        XCTAssertTrue(unrelated.isEmpty)
    }
    func testCapacityFailureLeavesExistingContentIntact() async throws {
        let store = KnowledgeStore()
        let item = try await store.upsert(title: "Original", text: "Original text stays intact.", categoryID: KnowledgeCategory.general.id)
        let tooManyParagraphs = String(repeating: "Fact.\n", count: KnowledgeStore.maximumChunks + 1)
        do {
            _ = try await store.upsert(title: "Too large", text: tooManyParagraphs, categoryID: item.categoryID, id: item.id)
            XCTFail("Excessive chunks accepted")
        } catch { }
        let saved = try await store.items()
        XCTAssertEqual(saved, [item])
        let matches = try await store.search(query: "Original")
        XCTAssertEqual(matches.first?.itemID, item.id)
    }
}

private actor ChangingKnowledgeEmbedding: KnowledgeEmbeddingProvider {
    nonisolated let identity = "test:changing"
    private var digest = "a"
    private var dimensions = 2
    private var unavailable = false
    private var documentCalls = 0
    func configure(digest: String, dimensions: Int, unavailable: Bool = false) {
        self.digest = digest; self.dimensions = dimensions; self.unavailable = unavailable
    }
    func modelIdentity() -> String { identity + ":" + digest }
    func embeddings(for texts: [String]) throws -> [[Float]] {
        guard !unavailable else { throw LocalInferenceError.serviceUnavailable }
        documentCalls += texts.filter { $0.contains("peppermint") }.count
        return texts.map { _ in [1] + Array(repeating: Float(0), count: dimensions - 1) }
    }
    func indexedDocumentCalls() -> Int { documentCalls }
}

extension KnowledgeCoreTests {
    @MainActor func testQueryModelIdentityChangeRebuildsAndNextQueryUsesNewIndex() async throws {
        let provider = ChangingKnowledgeEmbedding()
        let library = KnowledgeLibrary(embeddingProvider: provider)
        _ = await library.addNote(title: "Preference", text: "I drink peppermint tea.")
        await library.waitForIndexing()
        let originalRevision = library.revision
        let before = await library.search(query: "beverage")
        XCTAssertEqual(before.count, 1)
        await provider.configure(digest: "b", dimensions: 2)
        let detecting = await library.search(query: "beverage")
        XCTAssertTrue(detecting.isEmpty) // No lexical match; old model vectors cannot be returned.
        await library.waitForIndexing()
        XCTAssertEqual(library.revision, originalRevision)
        XCTAssertEqual(library.items.first?.indexingStatus, .indexed)
        let after = await library.search(query: "beverage")
        XCTAssertEqual(after.count, 1)
        let oldVectors = try await library.store.search(query: "beverage", vector: [1,0], identity: "test:changing:a")
        XCTAssertTrue(oldVectors.isEmpty)
    }
    @MainActor func testQuerySameIdentityDimensionChangeRebuildsAndKeepsSourceRevision() async throws {
        let provider = ChangingKnowledgeEmbedding()
        let library = KnowledgeLibrary(embeddingProvider: provider)
        _ = await library.addNote(title: "Preference", text: "I drink peppermint tea.")
        await library.waitForIndexing()
        let revision = library.revision
        await provider.configure(digest: "a", dimensions: 3)
        let detecting = await library.search(query: "beverage")
        XCTAssertTrue(detecting.isEmpty)
        await library.waitForIndexing()
        let after = await library.search(query: "beverage")
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(library.revision, revision)
        let oldVectors = try await library.store.search(query: "beverage", vector: [1,0], identity: "test:changing:a")
        XCTAssertTrue(oldVectors.isEmpty)
    }
    @MainActor func testRetryProbesFullyIndexedSameIdentityDimensionChange() async throws {
        let provider = ChangingKnowledgeEmbedding()
        let library = KnowledgeLibrary(embeddingProvider: provider)
        _ = await library.addNote(title: "Preference", text: "I drink peppermint tea.")
        await library.waitForIndexing()
        await provider.configure(digest: "a", dimensions: 4)
        await library.retryIndexing()
        await library.waitForIndexing()
        XCTAssertNil(library.error)
        let matches = try await library.store.search(query: "beverage", vector: [1,0,0,0], identity: "test:changing:a")
        XCTAssertEqual(matches.count, 1)
        let calls = await provider.indexedDocumentCalls()
        XCTAssertGreaterThanOrEqual(calls, 3) // Initial document, dimension probe, rebuilt document.
    }
    @MainActor func testTransientQueryAndRetryFailuresPreserveIndexedVectors() async throws {
        let provider = ChangingKnowledgeEmbedding()
        let library = KnowledgeLibrary(embeddingProvider: provider)
        _ = await library.addNote(title: "Preference", text: "I drink peppermint tea.")
        await library.waitForIndexing()
        await provider.configure(digest: "a", dimensions: 2, unavailable: true)
        let fallback = await library.search(query: "peppermint")
        XCTAssertEqual(fallback.count, 1)
        await library.retryIndexing()
        await library.waitForIndexing()
        XCTAssertEqual(library.items.first?.indexingStatus, .indexed)
        let stored = try await library.store.search(query: "beverage", vector: [1,0], identity: "test:changing:a")
        XCTAssertEqual(stored.count, 1)
        await provider.configure(digest: "a", dimensions: 2)
        let recovered = await library.search(query: "beverage")
        XCTAssertEqual(recovered.count, 1)
    }
}

extension KnowledgeCoreTests {
    func testTwoHundredSourcesReconcileStablyWithoutLosingMovesOrManualDedupe() async throws {
        let store = KnowledgeStore()
        let sources = (0..<200).map { index in
            KnowledgeSourceRecord(sourceKey: "planner:\(index)", title: "Task \(index)",
                text: "Study topic \(index). " + String(repeating: "Keep this detailed context. ", count: 30),
                categoryName: "Study", kind: "planner")
        }
        try await store.reconcile(sources: sources)
        let first = try await store.items()
        let moved = try XCTUnwrap(first.first)
        try await store.moveItem(id: moved.id, categoryID: KnowledgeCategory.work.id)
        try await store.reconcile(sources: sources)
        let second = try await store.items()
        XCTAssertEqual(second.count, 200)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: first.map { ($0.sourceKey, $0.id) }),
                       Dictionary(uniqueKeysWithValues: second.map { ($0.sourceKey, $0.id) }))
        XCTAssertTrue(second.allSatisfy { $0.revision == 1 })
        XCTAssertEqual(second.first { $0.id == moved.id }?.categoryID, KnowledgeCategory.work.id)
        let note = try await store.upsert(title: "Manual", text: "An independently saved fact.", categoryID: KnowledgeCategory.general.id)
        let duplicate = try await store.upsert(title: "Copied", text: note.text, categoryID: note.categoryID)
        XCTAssertEqual(note.id, duplicate.id)
        try await store.reconcile(sources: Array(sources.dropFirst(100)))
        let retained = try await store.items()
        XCTAssertEqual(retained.count, 101)
        XCTAssertTrue(retained.contains { $0.id == note.id })
    }
    func testSeparateConnectionsRejectVectorsForEditedRevisionWithoutChangingProfile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("knowledge.sqlite")
        let writer = KnowledgeStore(storageURL: url)
        let indexer = KnowledgeStore(storageURL: url)
        let original = try await writer.upsert(title: "Original", text: "Old text.", categoryID: KnowledgeCategory.general.id)
        try await indexer.load()
        let changed = try await writer.upsert(title: "Updated", text: "New text.", categoryID: original.categoryID, id: original.id)
        let stale = try await indexer.setEmbeddings(itemID: original.id, revision: original.revision,
                                                   identity: "stale:model", vectors: [[1,0]])
        XCTAssertFalse(stale)
        let pending = try await indexer.pendingDocuments()
        XCTAssertEqual(pending.first?.revision, changed.revision)
        XCTAssertEqual(pending.first?.chunks, ["New text."])
        let accepted = try await indexer.setEmbeddings(itemID: changed.id, revision: changed.revision,
                                                      identity: "current:model", vectors: [[0,1]])
        XCTAssertTrue(accepted)
        let current = try await writer.search(query: "paraphrase", vector: [0,1], identity: "current:model")
        XCTAssertEqual(current.first?.text, "New text.")
        let old = try await writer.search(query: "paraphrase", vector: [1,0], identity: "stale:model")
        XCTAssertTrue(old.isEmpty)
    }
}
