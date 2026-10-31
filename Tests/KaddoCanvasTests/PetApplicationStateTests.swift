import Combine
import XCTest
@testable import KaddoCanvas

final class PetApplicationStateTests: XCTestCase {
    @MainActor
    func testAllSharedPropertiesPublishSynchronously() {
        let model = PetApplicationState()
        var emotions: [PetEmotion] = []
        var speech: [String] = []
        var tasks: [PetTask?] = []
        let tokens = [
            model.$currentEmotion.dropFirst().sink { emotions.append($0) },
            model.$speechBubbleText.dropFirst().sink { speech.append($0) },
            model.$activeTask.dropFirst().sink { tasks.append($0) }
        ]
        let task = PetTask(title: "Read the canvas specification")
        model.currentEmotion = .thinking
        model.speechBubbleText = "Working on it."
        model.activeTask = task
        model.activeTask?.title = "Review the canvas"
        model.activeTask = nil
        XCTAssertEqual(emotions, [.thinking])
        XCTAssertEqual(speech, ["Working on it."])
        XCTAssertEqual(tasks, [task, PetTask(id: task.id, title: "Review the canvas"), nil])
        XCTAssertEqual(model.currentEmotion, .thinking)
        XCTAssertEqual(model.speechBubbleText, "Working on it.")
        XCTAssertNil(model.activeTask)
        withExtendedLifetime(tokens) {}
    }
}
