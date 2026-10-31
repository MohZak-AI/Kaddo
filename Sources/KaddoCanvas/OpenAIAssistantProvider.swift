import Foundation

/// Direct personal-key integration; credentials never enter prompts or persisted conversations.
public final class OpenAIAssistantProvider: AssistantProvider {
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let redirects = RejectOpenAIRedirects()
    public enum Service: Sendable {
        case openAI, deepSeek
        var endpoint: URL {
            switch self {
            case .openAI: URL(string: "https://api.openai.com/v1/responses")!
            case .deepSeek: URL(string: "https://api.deepseek.com/responses")!
            }
        }
    }
    private let service: Service

    public init(apiKey: String, model: String = "gpt-6.1-sol", session: URLSession? = nil, service: Service = .openAI) {
        self.service = service
        self.apiKey = apiKey; self.model = model
        self.session = session ?? URLSession(configuration: OllamaClient.configuration())
    }

    public func respond(to request: AssistantRequest) async throws -> AssistantTurn {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantError.missingKey }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantError.unavailableModel }
        var fields: [String: AssistantJSON] = [
            "model": .string(model), "instructions": .string(request.instructions),
            "input": .array(request.input), "store": .bool(false), "stream": .bool(false),
            "reasoning": .object(["effort": .string("low")]),
            "max_output_tokens": .number(4_096), "parallel_tool_calls": .bool(false),
            "tools": .array(request.toolSchemas)
        ]
        if service == .deepSeek {
            // DeepSeek ignores Responses storage/parallel flags; ask for sequential tool use explicitly.
            fields.removeValue(forKey: "store")
            fields.removeValue(forKey: "parallel_tool_calls")
            fields["reasoning"] = .object(["effort": .string("none")])
            fields["instructions"] = .string(request.instructions + "\nCall at most one tool per response.")
        }
        if request.responseFormat == .jsonObject {
            // JSON mode also requires an explicit JSON instruction, even when the caller supplies a schema.
            let instructions = fields["instructions"]?.string ?? request.instructions
            fields["instructions"] = .string(instructions + "\nReturn exactly one valid JSON object, without Markdown.")
            fields["text"] = .object(["format": .object(["type": .string("json_object")])])
        }
        let body = AssistantJSON.object(fields)
        var http = URLRequest(url: service.endpoint, timeoutInterval: 120)
        http.httpMethod = "POST"
        http.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = try JSONEncoder().encode(body)
        do {
            let (bytes, response) = try await session.bytes(for: http, delegate: redirects)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw AssistantError.service }
            switch response.statusCode {
            case 200: break
            case 401, 403: throw AssistantError.authentication
            case 404: throw AssistantError.unavailableModel
            case 429: throw AssistantError.rateLimited
            default: throw AssistantError.service
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 2 * 1_024 * 1_024 else { throw AssistantError.oversized }
                data.append(byte)
            }
            try Task.checkCancellation()
            let turn = try Self.decode(data, toolsEnabled: request.toolsEnabled)
            guard turn.calls.allSatisfy({ request.permits($0.name) }) else { throw AssistantError.invalidResponse }
            return turn
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw AssistantError.service
        }
    }

    static func decode(_ data: Data, toolsEnabled: Bool) throws -> AssistantTurn {
        guard let root = try? JSONDecoder().decode(AssistantJSON.self, from: data),
              root["status"]?.string == "completed", root["error"] == nil || root["error"] == .null,
              let output = root["output"]?.array else { throw AssistantError.invalidResponse }
        var text: [String] = []
        var calls: [KaddoToolCall] = []
        for item in output {
            switch item["type"]?.string {
            case "message":
                guard let content = item["content"]?.array else { throw AssistantError.invalidResponse }
                for block in content {
                    if block["type"]?.string == "output_text", let value = block["text"]?.string { text.append(value) }
                    else if block["type"]?.string == "refusal", let value = block["refusal"]?.string { text.append(value) }
                    else { throw AssistantError.invalidResponse }
                }
            case "function_call":
                guard toolsEnabled, item["status"]?.string == "completed",
                      let id = item["call_id"]?.string, !id.isEmpty,
                      let name = item["name"]?.string, let arguments = item["arguments"]?.string,
                      let json = try? JSONDecoder().decode(AssistantJSON.self, from: Data(arguments.utf8)) else {
                    throw AssistantError.invalidResponse
                }
                calls.append(try KaddoToolCall(id: id, name: name, arguments: json))
            case "reasoning": break
            default: throw AssistantError.invalidResponse
            }
        }
        let answer = text.joined(separator: "\n\n")
        guard answer.count <= 12_000, calls.count <= 1,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !calls.isEmpty else {
            throw AssistantError.invalidResponse
        }
        return AssistantTurn(text: answer, calls: calls, output: output)
    }
}

private final class RejectOpenAIRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
