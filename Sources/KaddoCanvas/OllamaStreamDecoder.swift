import Foundation

public struct PetSpeechLine: Decodable, Equatable, Sendable {
    public let speechBubbleText: String
    public let currentEmotion: PetEmotion
    public let sourceIDs: [UUID]

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: PayloadKey.self)
        let keys = Set(values.allKeys.map(\.stringValue))
        // Keep compatibility with answers produced using the earlier prompt contract.
        let emotionKey = keys.contains("pet_emotion") ? "pet_emotion" : "currentEmotion"
        guard keys == ["speechBubbleText", emotionKey, "sourceIDs"] else {
            throw LocalInferenceError.malformedResponse
        }
        let text = try values.decode(String.self, forKey: PayloadKey("speechBubbleText"))
        let emotion = try values.decode(String.self, forKey: PayloadKey(emotionKey))
        let ids = try values.decode([UUID].self, forKey: PayloadKey("sourceIDs"))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 500, text.rangeOfCharacter(from: .controlCharacters) == nil,
              text.rangeOfCharacter(from: .newlines) == nil,
              let emotion = PetEmotion(rawValue: emotion), ids.count <= 6,
              Set(ids).count == ids.count else { throw LocalInferenceError.malformedResponse }
        speechBubbleText = text
        currentEmotion = emotion
        sourceIDs = ids
    }
}

private struct PayloadKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Ollama's NDJSON records contain fragments of a second JSON document.
/// Only completed, decoded objects from that document become visible speech.
/// A single optional Markdown fence is removed outside the JSON, even when split
/// across records. Fences within speech strings remain ordinary text.
public struct OllamaStreamDecoder: Sendable {
    private enum Stage {
        case prefix, openingFence, element, object, separator, closing, complete
        case closingFence, fencedComplete
    }
    private var stage = Stage.prefix
    private let prefix = Array("{\"lines\":[".utf8)
    private var prefixIndex = 0
    private var quoted = false
    private var escaped = false
    private var depth = 0
    private var object = Data()
    private var generatedBytes = 0
    private var count = 0
    private var afterComma = false
    private var fenced = false
    private var fenceHeader = Data()
    private var closingBackticks = 0
    private let allowedSourceIDs: Set<UUID>
    private let requiredSourceIDs: Set<UUID>
    private var citedSourceIDs = Set<UUID>()
    public private(set) var isFinished = false

    public init(sourceIDs: Set<UUID>) {
        allowedSourceIDs = sourceIDs
        requiredSourceIDs = []
    }

    init(sourceIDs: Set<UUID>, requiredSourceIDs: Set<UUID>) {
        allowedSourceIDs = sourceIDs
        self.requiredSourceIDs = requiredSourceIDs
    }

    public mutating func consume(_ wireLine: String) throws -> [PetSpeechLine] {
        guard !isFinished else { throw LocalInferenceError.malformedResponse }
        do {
            let record = try JSONDecoder().decode(Record.self, from: Data(wireLine.utf8))
            if record.error != nil { throw LocalInferenceError.generationFailed }
            guard let fragment = record.response, let done = record.done else {
                throw LocalInferenceError.malformedResponse
            }
            var lines: [PetSpeechLine] = []
            for byte in fragment.utf8 {
                generatedBytes += 1
                guard generatedBytes <= 64 * 1_024 else { throw LocalInferenceError.responseTooLarge }
                if let line = try consume(byte: byte) { lines.append(line) }
            }
            if done {
                let complete = fenced ? stage == .fencedComplete : stage == .complete
                guard complete, count > 0,
                      record.done_reason == nil || record.done_reason == "stop" else {
                    throw LocalInferenceError.malformedResponse
                }
                if !requiredSourceIDs.isSubset(of: citedSourceIDs) {
                    throw LocalInferenceError.malformedResponse
                }
                isFinished = true
            }
            return lines
        } catch let error as LocalInferenceError { throw error }
        catch { throw LocalInferenceError.malformedResponse }
    }

    public func finish() throws {
        guard isFinished else { throw LocalInferenceError.malformedResponse }
    }

    private mutating func consume(byte: UInt8) throws -> PetSpeechLine? {
        let whitespace = [UInt8(9), 10, 13, 32].contains(byte)
        switch stage {
        case .prefix:
            if whitespace && !quoted { return nil }
            if prefixIndex == 0, byte == 96, !fenced {
                fenced = true
                fenceHeader = Data([byte])
                stage = .openingFence
                return nil
            }
            guard byte == prefix[prefixIndex] else { throw LocalInferenceError.malformedResponse }
            if byte == 34 { quoted.toggle() }
            prefixIndex += 1
            if prefixIndex == prefix.count { stage = .element }
        case .openingFence:
            if byte == 10 {
                let header = String(decoding: fenceHeader, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard header == "```" || header == "```json" else {
                    throw LocalInferenceError.malformedResponse
                }
                stage = .prefix
            } else {
                guard fenceHeader.count < 16 else { throw LocalInferenceError.malformedResponse }
                fenceHeader.append(byte)
            }
        case .element:
            if whitespace { return nil }
            if byte == 93 && !afterComma { stage = .closing; return nil }
            guard byte == 123 else { throw LocalInferenceError.malformedResponse }
            stage = .object
            object = Data([byte])
            depth = 1
            quoted = false
            escaped = false
        case .object:
            object.append(byte)
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else {
                if byte == 34 { quoted = true }
                else if byte == 123 { depth += 1 }
                else if byte == 125 { depth -= 1 }
            }
            if depth == 0 {
                let line = try JSONDecoder().decode(PetSpeechLine.self, from: object)
                guard Set(line.sourceIDs).isSubset(of: allowedSourceIDs), count < 8 else {
                    throw LocalInferenceError.malformedResponse
                }
                count += 1
                citedSourceIDs.formUnion(line.sourceIDs)
                stage = .separator
                object.removeAll(keepingCapacity: true)
                return line
            }
        case .separator:
            if whitespace { return nil }
            if byte == 44 { stage = .element; afterComma = true }
            else if byte == 93 { stage = .closing }
            else { throw LocalInferenceError.malformedResponse }
        case .closing:
            if whitespace { return nil }
            guard byte == 125 else { throw LocalInferenceError.malformedResponse }
            stage = .complete
        case .complete:
            if fenced, byte == 96 {
                closingBackticks = 1
                stage = .closingFence
                return nil
            }
            guard whitespace else { throw LocalInferenceError.malformedResponse }
        case .closingFence:
            guard byte == 96 else { throw LocalInferenceError.malformedResponse }
            closingBackticks += 1
            if closingBackticks == 3 { stage = .fencedComplete }
        case .fencedComplete:
            guard whitespace else { throw LocalInferenceError.malformedResponse }
        }
        return nil
    }

    private struct Record: Decodable {
        let response: String?
        let done: Bool?
        let error: String?
        let done_reason: String?
    }

}
