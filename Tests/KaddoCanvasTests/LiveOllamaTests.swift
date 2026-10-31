import AppKit
import XCTest
@testable import KaddoCanvas

/// Opt-in acceptance against an installed local model; ordinary tests stay offline.
final class LiveOllamaTests: XCTestCase {
    @MainActor
    func testRealModelExplainsUploadedAssignmentReference() async throws {
        guard let model = ProcessInfo.processInfo.environment["KADDO_LIVE_MODEL"], !model.isEmpty else {
            throw XCTSkip("Set KADDO_LIVE_MODEL to an installed local model to check the assignment flow.")
        }
        _ = NSApplication.shared
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("AssignmentExercises.docx"))
        let assistant = LocalNotesAssistant(state: state, client: try OllamaClient())
        let controller = NotesQueryWindowController(state: state, assistant: assistant, settings: AssistantSettings())
        defer { controller.close() }
        controller.presentation.modelName = model
        controller.presentation.query = "what does ex1?"
        controller.submit()
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<6_000 {
            if !controller.isResponding { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertFalse(controller.isResponding)
        XCTAssertNil(assistant.lastFailure, state.speechBubbleText)
        XCTAssertFalse(controller.presentation.sources.isEmpty, state.speechBubbleText)
        XCTAssertTrue(controller.presentation.sources.allSatisfy { $0.filename == "AssignmentExercises.docx" })
        let answer = state.speechBubbleText.lowercased()
        XCTAssertTrue(["derivative", "differentiat", "slope"].contains(where: answer.contains), state.speechBubbleText)
        XCTAssertTrue(controller.coordinator.conversation.exchanges.isEmpty)
        print("Live assignment question: what does ex1?; answer: \(state.speechBubbleText); sources: \(controller.presentation.sources.count)")
    }

    @MainActor
    func testRealModelAnswersImportedPDFAndUpdatesPetState() async throws {
        guard let model = ProcessInfo.processInfo.environment["KADDO_LIVE_MODEL"], !model.isEmpty else {
            throw XCTSkip("Set KADDO_LIVE_MODEL to an installed local Ollama model to run live inference.")
        }
        let state = PetApplicationState()
        try await state.documentMemory.importDocument(at: documentFixture("Research.pdf"))
        let client = try OllamaClient()
        let installed = try await client.localModelNames()
        XCTAssertTrue(installed.contains(model))
        let assistant = LocalNotesAssistant(state: state, client: client)
        await assistant.answer(query: "How often should I water orchids?", model: model)
        XCTAssertFalse(assistant.isAnswering)
        XCTAssertTrue([PetEmotion.happy, .celebrating].contains(state.currentEmotion), state.speechBubbleText)
        XCTAssertFalse(assistant.sources.isEmpty, state.speechBubbleText)
        let speech = state.speechBubbleText.lowercased()
        XCTAssertTrue(["week", "seven days", "7 days"].contains(where: speech.contains), state.speechBubbleText)
        XCTAssertTrue(assistant.sources.allSatisfy { $0.filename == "Research.pdf" })
        print("Live local model: \(model); speech: \(state.speechBubbleText); emotion: \(state.currentEmotion); sources: \(assistant.sources.count)")
    }
}
