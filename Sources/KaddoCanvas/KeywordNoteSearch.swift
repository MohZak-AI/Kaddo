import Foundation

public struct NoteMatch: Equatable, Sendable {
    public let chunk: DocumentChunk
    public let score: Int
}

/// Small, deterministic RAM search; each query term contributes once per chunk.
public struct KeywordNoteSearch: Sendable {
    public let maximumResults: Int
    public let contextCharacterBudget: Int

    public init(maximumResults: Int = 6, contextCharacterBudget: Int = 6_000) {
        self.maximumResults = max(0, maximumResults)
        self.contextCharacterBudget = max(0, contextCharacterBudget)
    }

    public func search(_ query: String, in chunks: [DocumentChunk]) throws -> [NoteMatch] {
        guard query.count <= 2_000 else { throw LocalInferenceError.invalidQuery }
        let terms = Array(Set(Self.words(query).filter { $0.count >= 2 })).sorted().prefix(32)
        guard !terms.isEmpty else { return [] }
        var ranked: [(position: Int, match: NoteMatch)] = []
        for (position, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let words = Set(Self.words(chunk.text))
            let score = terms.reduce(0) { score, term in
                if words.contains(term) { return score + 3 }
                return score + (words.contains { $0.contains(term) } ? 1 : 0)
            }
            if score > 0 { ranked.append((position, NoteMatch(chunk: chunk, score: score))) }
        }
        ranked.sort {
            $0.match.score == $1.match.score
                ? $0.position < $1.position : $0.match.score > $1.match.score
        }
        var remaining = contextCharacterBudget
        var selected: [NoteMatch] = []
        for entry in ranked {
            guard selected.count < maximumResults else { break }
            let count = entry.match.chunk.text.count
            guard count <= remaining else { continue }
            selected.append(entry.match)
            remaining -= count
        }
        return selected
    }

    private static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
        let unmarked = String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            !CharacterSet.nonBaseCharacters.contains($0)
        }))
        return unmarked.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
