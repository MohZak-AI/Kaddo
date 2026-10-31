import Foundation
import NaturalLanguage

/// A forward-only sentence window. Each character belongs to exactly one chunk.
/// Whitespace is normalized once; chunk boundaries retain spaces for lossless joining.
public struct DocumentTextChunker: Sendable {
    public let sentencesPerChunk: Int
    public let maxCharacters: Int
    public let maxChunks: Int

    public init(sentencesPerChunk: Int = 4, maxCharacters: Int = 1_600,
                maxChunks: Int = 20_000) throws {
        guard (1...20).contains(sentencesPerChunk), maxCharacters >= 2, maxChunks > 0 else {
            throw DocumentImportError.invalidConfiguration
        }
        self.sentencesPerChunk = sentencesPerChunk
        self.maxCharacters = maxCharacters
        self.maxChunks = maxChunks
    }

    public func chunks(in text: String) throws -> [String] {
        let normalized = try Self.normalize(text)
        guard !normalized.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = normalized
        var result: [String] = []
        var start = normalized.startIndex
        var sentences = 0
        var exceededLimit = false

        func appendWindow(endingAt end: String.Index) {
            while start < end {
                guard result.count < maxChunks else {
                    exceededLimit = true
                    return
                }
                var boundary = normalized.index(start, offsetBy: maxCharacters, limitedBy: end) ?? end
                // Avoid a final chunk that consists only of a boundary space.
                if boundary < end, normalized[boundary] == " ",
                   normalized.index(after: boundary) == end {
                    boundary = normalized.index(before: boundary)
                }
                result.append(String(normalized[start..<boundary]))
                start = boundary
            }
        }

        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            sentences += 1
            if sentences == sentencesPerChunk {
                var end = range.upperBound
                if end < normalized.endIndex, normalized[end] == " " {
                    end = normalized.index(after: end)
                }
                appendWindow(endingAt: end)
                sentences = 0
            }
            return !Task.isCancelled && !exceededLimit
        }
        try Task.checkCancellation()
        appendWindow(endingAt: normalized.endIndex)
        guard !exceededLimit else { throw DocumentImportError.documentTooLarge }
        return result
    }

    /// Keep unrelated paragraphs out of a matching block; long paragraphs retain
    /// the same sentence and character bounds as ordinary sentence windows.
    public func paragraphChunks(in text: String) throws -> [String] {
        var result: [String] = []
        var failure: Error?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: .byParagraphs) { paragraph, _, _, stop in
            do {
                try Task.checkCancellation()
                let additions = try chunks(in: paragraph ?? "")
                guard additions.count <= maxChunks - result.count else {
                    throw DocumentImportError.documentTooLarge
                }
                result.append(contentsOf: additions)
            } catch {
                failure = error
                stop = true
            }
        }
        if let failure { throw failure }
        try Task.checkCancellation()
        return result
    }

    private static func normalize(_ text: String) throws -> String {
        var result = String()
        result.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for (index, character) in text.enumerated() {
            if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
            } else if !character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
                if pendingSpace { result.append(" ") }
                result.append(character)
                pendingSpace = false
            }
        }
        return result
    }
}
