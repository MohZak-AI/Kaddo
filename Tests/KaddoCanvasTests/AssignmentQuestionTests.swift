import AppKit
import XCTest
@testable import KaddoCanvas

final class AssignmentQuestionTests: XCTestCase {
    private func chunk(_ text: String, index: Int = 0, document: UUID = UUID(), filename: String = "Assignment.docx") -> DocumentChunk {
        .init(id: UUID(), documentID: document, filename: filename, index: index, text: text)
    }

    func testAbbreviatedAndArabicReferencesRecognizeTheSameNumber() {
        for text in ["what does ex1?", "EX. 1", "exercise 1", "question 1", "Q1", "problem 1", "اشرح التمرين ١", "السؤال ۱"] {
            XCTAssertEqual(DocumentQuestionReference.first(in: text)?.number, "1", text)
            XCTAssertTrue(DocumentQuestionRouter.shouldRoute(text, hasDocuments: true, previousQuestion: nil, filenames: []))
        }
        XCTAssertNil(DocumentQuestionReference.first(in: "complex1"))
        XCTAssertNil(DocumentQuestionReference.first(in: "ex1abc"))
        XCTAssertFalse(DocumentQuestionRouter.shouldRoute("what does ex1?", hasDocuments: false, previousQuestion: nil, filenames: []))
    }

    func testUnrelatedChatAndPlannerRequestsStaySeparateFromAssignments() {
        for text in ["hello", "what is the capital of France?", "how do timers work?", "add a task Finish ex1", "save a note about question 1"] {
            XCTAssertFalse(DocumentQuestionRouter.shouldRoute(text, hasDocuments: true, previousQuestion: nil, filenames: []), text)
        }
        for text in ["how do I start?", "what about part b?", "which classes should I change?", "what attributes are required?", "explain more", "can you solve it?", "part(b)", "اشرح أكثر"] {
            XCTAssertTrue(DocumentQuestionRouter.shouldRoute(text, hasDocuments: true, previousQuestion: "what does ex1?", filenames: []), text)
        }
        for text in ["why is the sky blue?", "particles are interesting", "how do I make pancakes?"] {
            XCTAssertFalse(DocumentQuestionRouter.shouldRoute(text, hasDocuments: true, previousQuestion: "what does ex1?", filenames: []), text)
        }
    }

    func testExerciseSectionIncludesItsProblemAndStopsBeforeExerciseTwoAndTen() throws {
        let id = UUID()
        let chunks = [chunk("Exercise 1", document: id),
                      chunk("Find the derivative of f(x) = x^2 + 3x.", index: 1, document: id),
                      chunk("(b) Evaluate it at x = 2.", index: 2, document: id),
                      chunk("Exercise 2", index: 3, document: id),
                      chunk("Find the triangle area.", index: 4, document: id),
                      chunk("Exercise 10: a different question.", index: 5, document: id)]
        let matches = try AssignmentContextSearch.search("what does ex1?", chunks: chunks)
        XCTAssertEqual(matches.map(\.chunk.text), Array(chunks.prefix(3)).map(\.text))
        XCTAssertEqual(matches.map(\.chunk.id), Array(chunks.prefix(3)).map(\.id))
    }

    func testSubquestionsAndCrossReferencesDoNotTruncateTheExercise() throws {
        let id = UUID()
        let chunks = [chunk("Exercise 1: Probability.", document: id),
                      chunk("Use your result from Exercise 2 to explain the sample.", index: 1, document: id),
                      chunk("Question 1: Find the mean.", index: 2, document: id),
                      chunk("Question 2: Find the variance.", index: 3, document: id),
                      chunk("Exercise 2: Other work.", index: 4, document: id)]
        let matches = try AssignmentContextSearch.search("ex1", chunks: chunks)
        XCTAssertEqual(matches.count, 4)
        XCTAssertTrue(matches.last!.chunk.text.contains("variance"))
    }

    func testInlineAndNumberedHeadingsAndMissingReferenceReturnsNoEvidence() throws {
        let inline = chunk("Exercise 1: Differentiate x squared. Exercise 2: Integrate x cubed.")
        let result = try AssignmentContextSearch.search("ex1", chunks: [inline])
        XCTAssertTrue(result[0].chunk.text.contains("Differentiate"))
        XCTAssertFalse(result[0].chunk.text.contains("Integrate"))
        let id = UUID()
        let numbered = [chunk("1. Differentiate x squared.", document: id), chunk("2) Integrate x cubed.", index: 1, document: id)]
        XCTAssertEqual(try AssignmentContextSearch.search("ex1", chunks: numbered).count, 1)
        XCTAssertTrue(try AssignmentContextSearch.search("ex3", chunks: numbered).isEmpty)
        XCTAssertTrue(try AssignmentContextSearch.search("ex1", chunks: []).isEmpty)
    }

    func testDuplicateExerciseNumbersNeedAFilename() throws {
        let one = chunk("Exercise 1: Differentiate.", filename: "Calculus.docx")
        let two = chunk("Exercise 1: Translate.", filename: "French.docx")
        XCTAssertThrowsError(try AssignmentContextSearch.search("what does ex1?", chunks: [one, two])) {
            XCTAssertEqual($0 as? LocalInferenceError, .ambiguousDocumentReference)
        }
        XCTAssertEqual(try AssignmentContextSearch.search("ex1 in Calculus.docx", chunks: [one, two]).map(\.chunk.id), [one.id])
    }

    func testAnExplicitFilenameCannotSelectAnotherFilesExercise() throws {
        let calculus = chunk("Exercise 1: Differentiate.", filename: "Calculus.docx")
        let french = chunk("Write a short dialogue in French.", filename: "French.docx")
        let matches = try AssignmentContextSearch.search("ex1 in French.docx", chunks: [calculus, french])
        XCTAssertTrue(matches.isEmpty)
        XCTAssertFalse(matches.map(\.chunk.text).joined().contains("Differentiate"))
    }

    func testBudgetAndLongAssignmentsStillFindTheRequestedLaterSection() throws {
        let id = UUID()
        var chunks = (0..<20).map { chunk("Introduction " + String(repeating: "a", count: 1500), index: $0, document: id) }
        chunks.append(chunk("Exercise 1", index: 20, document: id))
        chunks += (21..<30).map { chunk("Relevant details " + String(repeating: "b", count: 1500), index: $0, document: id) }
        let result = try AssignmentContextSearch.search("ex1", chunks: chunks)
        XCTAssertEqual(result.first?.chunk.text, "Exercise 1")
        XCTAssertLessThanOrEqual(result.count, 5)
        XCTAssertLessThanOrEqual(result.reduce(0) { $0 + $1.chunk.text.count }, 6000)
    }

    func testNewDocumentQuestionsDoNotReuseTheOldExercise() {
        XCTAssertEqual(DocumentQuestionRouter.groundedQuery("summarize my document", previousQuestion: "ex1", filenames: []), "summarize my document")
        XCTAssertEqual(DocumentQuestionRouter.groundedQuery("what is ex2?", previousQuestion: "ex1", filenames: []), "what is ex2?")
        XCTAssertEqual(DocumentQuestionRouter.groundedQuery("how do I start?", previousQuestion: "ex1", filenames: []), "ex1\nFollow-up: how do I start?")
    }

    @MainActor
    func testExactReportedQuestionBypassesGeneralChatAndAnswersImportedAssignment() async throws {
        _ = NSApplication.shared
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("AssignmentExercises.docx"))
        let source = try XCTUnwrap(state.documentMemory.chunks.first { $0.text.contains("f(x)") })
        let line = try speechObject("Exercise 1 asks you to find the derivative, evaluate it at x = 2, and explain the slope.", ids: [source.id])
        let http = Phase4HTTPHarness(json: try inferenceRecord("{\"lines\":[\(line)]}", done: true))
        defer { http.cleanUp() }
        let notes = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let controller = NotesQueryWindowController(state: state, assistant: notes, settings: AssistantSettings())
        defer { controller.close() }
        controller.presentation.modelName = "local:test"
        controller.coordinator.providerFactory = { XCTFail("Assignment reference must not become a general chat question"); throw AssistantError.service }
        func send(_ text: String) async throws {
            controller.presentation.query = text; controller.submit()
            try await Task.sleep(for: .milliseconds(20))
            for _ in 0..<150 {
                if !controller.isResponding { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Assignment answer timed out")
        }
        try await send("what does ex1?")
        XCTAssertTrue(state.speechBubbleText.contains("find the derivative"))
        XCTAssertEqual(controller.presentation.sources.map(\.id), [source.id])
        XCTAssertTrue(controller.coordinator.conversation.exchanges.isEmpty)
        try await send("how do I start?")
        let requests = http.requests.filter { $0.url?.path == "/api/generate" }
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            let body = try JSONDecoder().decode(AssistantJSON.self, from: request.body)
            XCTAssertEqual(body["system"]?.string, OfflinePromptBuilder.systemPrompt)
            let prompt = try XCTUnwrap(body["prompt"]?.string)
            XCTAssertTrue(prompt.contains("f(x) = x^2 + 3x"))
            XCTAssertFalse(prompt.contains("triangle"))
        }
        let second = try JSONDecoder().decode(AssistantJSON.self, from: requests[1].body)
        XCTAssertTrue(second["prompt"]!.string!.contains("what does ex1?"))
        try await send("hello")
        XCTAssertEqual(notes.lastDocumentQuestion, "what does ex1?")
        XCTAssertTrue(notes.sources.isEmpty)
    }

    @MainActor
    func testBroadQuestionUsesDocumentOverviewInNativeComposer() async throws {
        _ = NSApplication.shared
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("AssignmentExercises.docx"))
        let source = try XCTUnwrap(state.documentMemory.chunks.first { $0.text.contains("f(x)") })
        let line = try speechObject("Complete both exercises: differentiate the function and calculate the triangle area.", ids: [source.id])
        let http = Phase4HTTPHarness(json: try inferenceRecord("{\"lines\":[\(line)]}", done: true))
        defer { http.cleanUp() }
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        let controller = NotesQueryWindowController(state: state, assistant: assistant, settings: AssistantSettings())
        defer { controller.close() }
        controller.presentation.modelName = "local:test"
        controller.coordinator.providerFactory = { XCTFail("Broad lab questions must use the document retrieval path"); throw AssistantError.service }
        controller.presentation.query = "what should I do?"
        controller.submit()
        for _ in 0..<200 {
            if !controller.isResponding { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isResponding)
        XCTAssertTrue(state.speechBubbleText.contains("Complete both exercises"))
        let request = try XCTUnwrap(http.requests.first { $0.url?.path == "/api/generate" })
        let body = try JSONDecoder().decode(AssistantJSON.self, from: request.body)
        let prompt = try XCTUnwrap(body["prompt"]?.string)
        XCTAssertTrue(prompt.contains("f(x) = x^2 + 3x"))
        XCTAssertTrue(prompt.contains("triangle"))
        XCTAssertEqual(controller.presentation.sources.map(\.id), [source.id])
        controller.presentation.query = "explain ex99"
        controller.submit()
        for _ in 0..<200 {
            if !controller.isResponding { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(state.speechBubbleText.contains("exercise 99"))
        XCTAssertFalse(state.speechBubbleText.contains("could not finish"))
        XCTAssertNotNil(assistant.retrievalFailure)
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/api/generate" }.count, 1)
    }

    @MainActor
    func testCloudExerciseQuestionReceivesTheProblemWithoutActionTools() async throws {
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("AssignmentExercises.docx"))
        let source = try XCTUnwrap(state.documentMemory.chunks.first { $0.text.contains("f(x)") })
        let line = try speechObject("The derivative is 2x + 3; evaluating at x = 2 gives 7.", ids: [source.id])
        let provider = ScriptedAssistantProvider([.turn(.init(text: "{\"lines\":[\(line)]}"))])
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost); defer { http.cleanUp() }
        let notes = LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session))
        _ = try await notes.answerCloud(query: "solve ex1", provider: provider)
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests[0].toolsEnabled)
        let text = try XCTUnwrap(requests[0].input[0]["content"]?.string)
        XCTAssertTrue(text.contains("f(x) = x^2 + 3x"))
        XCTAssertFalse(text.contains("triangle"))
        XCTAssertTrue(notes.sources.contains { $0.id == source.id })
        state.createSession(title: "Empty")
        XCTAssertNil(notes.lastDocumentQuestion)
        do { _ = try await notes.answerCloud(query: "what does ex1?", provider: provider); XCTFail("An empty session must not reuse the old assignment") }
        catch { XCTAssertEqual(notes.lastOutcome?.kind, "needsInput")
            XCTAssertTrue(error is DocumentRetrievalError) }
        let after = await provider.requests
        XCTAssertEqual(after.count, 1)
    }
}
