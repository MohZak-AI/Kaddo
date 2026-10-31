import Foundation

/// Document dialogue is retained separately from the conversation that can request actions.
public struct DocumentConversationState: Codable, Equatable, Sendable {
    enum Mode: String, Codable { case active, retained }
    var context: DocumentFollowupContext?
    var exchanges: [ConversationExchange] = []
    var pendingClarification: String?
    var pendingInput: String?
    var detourQuestion: String?
    var mode: Mode = .active
    var needsReanchor = false

    mutating func append(_ exchange: ConversationExchange) {
        exchanges.append(exchange)
        while exchanges.count > 4 || exchanges.reduce(0, { $0 + $1.characterCount }) > 6_000 {
            exchanges.removeFirst()
        }
    }
}

struct DocumentAnswer {
    let text: String
    let sources: [DocumentChunk]
    let context: DocumentFollowupContext?
}

enum DocumentResponseOutcome {
    case answered(DocumentAnswer)
    case needsInput(DocumentRetrievalError)
    case failed(Error)
    case cancelled

    var kind: String {
        switch self {
        case .answered: "answered"
        case .needsInput: "needsInput"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }

    func answerOrThrow() throws -> DocumentAnswer {
        switch self {
        case .answered(let answer): return answer
        case .needsInput(let error): throw error
        case .failed(let error): throw error
        case .cancelled: throw CancellationError()
        }
    }
}
