import Foundation

/// A small JSON value type keeps provider wire data Sendable without exposing application state.
public enum AssistantJSON: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: AssistantJSON]), array([AssistantJSON]), null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: AssistantJSON].self) { self = .object(v) }
        else { self = .array(try value.decode([AssistantJSON].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }

    var object: [String: AssistantJSON]? { if case .object(let v) = self { return v }; return nil }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var array: [AssistantJSON]? { if case .array(let v) = self { return v }; return nil }
    subscript(_ key: String) -> AssistantJSON? { object?[key] }
    static func encode<T: Encodable>(_ value: T) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
    func jsonString() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
    static func message(_ text: String, role: String = "user") -> Self {
        .object(["role": .string(role), "content": .string(text)])
    }
}

public enum AssistantResponseFormat: Sendable { case conversation, jsonObject }

public enum AgentExecutionMode: Sendable { case interactive, scheduled }

/// Scheduled inference is tool-free even if a caller accidentally supplies a wider tool set.
public enum AgentCapabilityPolicy {
    public static func permits(_ name: KaddoToolName, mode: AgentExecutionMode) -> Bool { mode == .interactive }
}

public struct AssistantRequest: Sendable {
    public var instructions: String
    public var input: [AssistantJSON]
    public var toolsEnabled: Bool
    public var responseFormat: AssistantResponseFormat
    public var executionMode: AgentExecutionMode
    public var allowedTools: Set<KaddoToolName>?
    public func permits(_ name: KaddoToolName) -> Bool { toolsEnabled && AgentCapabilityPolicy.permits(name, mode: executionMode) && (allowedTools?.contains(name) ?? true) }
    var toolSchemas: [AssistantJSON] { toolsEnabled && executionMode == .interactive ? KaddoToolCatalog.schemas(for: allowedTools) : [] }
    public init(instructions: String, input: [AssistantJSON], toolsEnabled: Bool = true, allowedTools: Set<KaddoToolName>? = nil, executionMode: AgentExecutionMode = .interactive, responseFormat: AssistantResponseFormat = .conversation) {
        self.instructions = instructions; self.input = input; self.toolsEnabled = toolsEnabled; self.allowedTools = allowedTools; self.executionMode = executionMode; self.responseFormat = responseFormat
    }
}

public struct AssistantTurn: Sendable {
    public let text: String
    public let calls: [KaddoToolCall]
    /// Includes reasoning items required when continuing a Responses API tool turn.
    public let output: [AssistantJSON]
    public init(text: String, calls: [KaddoToolCall] = [], output: [AssistantJSON] = []) {
        self.text = text; self.calls = calls; self.output = output
    }
}

public protocol AssistantProvider: Sendable {
    var requestBudgeter: AssistantRequestBudgeter { get }
    func respond(to request: AssistantRequest) async throws -> AssistantTurn
}

public extension AssistantProvider {
    var requestBudgeter: AssistantRequestBudgeter { AssistantRequestBudgeter() }
}

public enum AssistantError: Error, LocalizedError, Equatable {
    case missingKey, localModelUnavailable, authentication, rateLimited, unavailableModel, invalidResponse, oversized, requestTooLarge, service, keychain(Int32)
    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add your cloud AI API key in Kaddo → AI settings, or choose local Ollama."
        case .localModelUnavailable: "Choose an installed local Ollama model in Kaddo → AI settings, or configure cloud AI."
        case .authentication: "The cloud AI provider could not authenticate. Check or replace your API key in AI settings."
        case .rateLimited: "The cloud AI provider’s usage or rate limit was reached. Check your API billing or try again later."
        case .unavailableModel: "This cloud AI model is unavailable for your key. Check the model in AI settings."
        case .invalidResponse: "The AI returned an incomplete or invalid response. No unvalidated actions were run."
        case .oversized: "The AI response was too large. Try a smaller request."
        case .requestTooLarge: "This request and its pending actions exceed the model’s context limit. Send a shorter message or start a new chat turn. Completed actions were kept."
        case .service: "Couldn’t reach the AI service. Check your connection and try again. Offline commands still work."
        case .keychain: "macOS Keychain could not access the API key. Try saving it again."
        }
    }
}

public struct OllamaAssistantProvider: AssistantProvider {
    let client: OllamaClient
    let model: String
    public init(client: OllamaClient, model: String) { self.client = client; self.model = model }
    public var requestBudgeter: AssistantRequestBudgeter { AssistantRequestBudgeter(contextCapacity: 16_384, responseReserve: 2_048) }

    public func respond(to request: AssistantRequest) async throws -> AssistantTurn {
        let payload = AssistantJSON.object([
            "conversation": .array(request.input),
            "tools": .array(request.toolSchemas)
        ])
        let system = request.instructions + (request.responseFormat == .jsonObject ? "\nReturn exactly the JSON object requested above, without Markdown. You have no tools." : """
        
        Return exactly one JSON object with text (string) and tool (object or null).
        For a tool, use {"name":"registered_name","arguments":{...}} and empty text.
        Choose at most one tool per response. After receiving its result continue the request.
        For a final answer or clarification use nonempty text and tool:null.
        """)
        var decoder = OllamaAssistantDecoder()
        let collector = OllamaAssistantCollector()
        try await client.generate(.init(model: model, system: system, prompt: try payload.jsonString())) { line in
            try await collector.consume(line)
        }
        decoder = await collector.decoder
        let object = try decoder.finish()
        if request.responseFormat == .jsonObject {
            guard !request.toolsEnabled, object.object != nil else { throw AssistantError.invalidResponse }
            return AssistantTurn(text: try object.jsonString())
        }
        guard let fields = object.object, Set(fields.keys) == ["text", "tool"],
              let text = object["text"]?.string, text.count <= 12_000 else { throw AssistantError.invalidResponse }
        let calls: [KaddoToolCall]
        if let tool = object["tool"], tool != .null {
            guard request.toolsEnabled, let toolFields = tool.object, Set(toolFields.keys) == ["name", "arguments"],
                  let name = tool["name"]?.string,
                  let arguments = tool["arguments"]?.object else { throw AssistantError.invalidResponse }
            let call = try KaddoToolCall(id: UUID().uuidString, name: name, arguments: .object(arguments))
            guard request.permits(call.name) else { throw AssistantError.invalidResponse }
            calls = [call]
        } else { calls = [] }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !calls.isEmpty else {
            throw AssistantError.invalidResponse
        }
        return AssistantTurn(text: text, calls: calls, output: [.message(try object.jsonString(), role: "assistant")])
    }
}

private actor OllamaAssistantCollector {
    var decoder = OllamaAssistantDecoder()
    func consume(_ line: String) throws { try decoder.consume(line) }
}

private struct OllamaAssistantDecoder: Sendable {
    var buffer = ""
    var done = false
    mutating func consume(_ line: String) throws {
        let value = try JSONDecoder().decode(AssistantJSON.self, from: Data(line.utf8))
        guard !done, value["error"] == nil, let fragment = value["response"]?.string,
              case .bool(let completed) = value["done"] else { throw AssistantError.invalidResponse }
        guard buffer.utf8.count + fragment.utf8.count <= 128_000 else { throw AssistantError.oversized }
        buffer += fragment
        done = completed
        if completed, let reason = value["done_reason"]?.string, reason != "stop" { throw AssistantError.invalidResponse }
    }
    func finish() throws -> AssistantJSON {
        guard done else { throw AssistantError.invalidResponse }
        return try JSONDecoder().decode(AssistantJSON.self, from: Data(buffer.utf8))
    }
}
