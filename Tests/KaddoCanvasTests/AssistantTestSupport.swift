import Foundation
@testable import KaddoCanvas

actor ScriptedAssistantProvider: AssistantProvider {
    enum Step: Sendable {
        case turn(AssistantTurn), failure(AssistantError), delayed(AssistantTurn)
    }
    private var steps: [Step]
    private(set) var requests: [AssistantRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func respond(to request: AssistantRequest) async throws -> AssistantTurn {
        requests.append(request)
        guard !steps.isEmpty else { throw AssistantError.invalidResponse }
        let step = steps.removeFirst()
        switch step {
        case .turn(let turn): return turn
        case .failure(let error): throw error
        case .delayed(let turn):
            // Deliberately ignore cancellation to exercise coordinator generation checks.
            try? await Task.sleep(for: .milliseconds(100))
            return turn
        }
    }
}

func toolTurn(_ name: KaddoToolName, _ arguments: KaddoToolArguments = .init(), id: String = UUID().uuidString) throws -> AssistantTurn {
    let call = KaddoToolCall(id: id, name: name, arguments: arguments)
    let output = AssistantJSON.object(["type": .string("function_call"), "call_id": .string(id),
        "name": .string(name.rawValue), "arguments": .string(try AssistantJSON.encode(arguments).jsonString()),
        "status": .string("completed")])
    return .init(text: "", calls: [call], output: [output])
}
