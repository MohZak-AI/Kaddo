import Foundation

struct DocumentPassageLink: Equatable, Sendable {
    let sourceChunkID: UUID
    let targetChunkID: UUID
    let kind: String
    let sourceText: String
}

enum DocumentPassageLinkBuilder {
    static let version = 2

    static func build(documentID: UUID, chunks: [DocumentChunk]) -> [DocumentPassageLink] {
        let chunks = chunks.filter { $0.documentID == documentID }
        guard !chunks.isEmpty else { return [] }
        var links: [DocumentPassageLink] = []
        var seen = Set<String>()
        var exerciseTargets: [String: DocumentChunk] = [:]
        var missingExerciseTargets = Set<String>()

        func append(source: DocumentChunk, target: DocumentChunk?, kind: String, text: String) {
            guard let target, source.id != target.id else { return }
            let key = "\(source.id):\(target.id):\(kind)"
            guard seen.insert(key).inserted else { return }
            links.append(DocumentPassageLink(sourceChunkID: source.id, targetChunkID: target.id,
                kind: kind, sourceText: String(text.prefix(240))))
        }

        // Reuse the assignment parser, but link only when one target section is resolved.
        for source in chunks {
            for occurrence in DocumentQuestionReference.occurrences(in: source.text) {
                let key = "\(occurrence.reference.kind):\(occurrence.reference.number)"
                if exerciseTargets[key] == nil, !missingExerciseTargets.contains(key) {
                    // Count heading chunks independently of section runs: repeated matching
                    // headings must remain ambiguous even when they share a chunk.
                    let matches = AssignmentContextSearch.sections(for: occurrence.reference, in: chunks)
                    if matches.count == 1, let target = matches[0].first {
                        exerciseTargets[key] = target
                    } else {
                        missingExerciseTargets.insert(key)
                    }
                }
                append(source: source, target: exerciseTargets[key], kind: occurrence.reference.kind,
                       text: String(source.text[occurrence.range]))
            }
        }

        var headingsByIdentifier: [String: [DocumentChunk]] = [:]
        var bareNumberedHeadings: [String: [DocumentChunk]] = [:]
        var headingsByTitle: [String: [DocumentChunk]] = [:]
        for chunk in chunks {
            for line in chunk.text.components(separatedBy: .newlines) {
                guard let heading = StructuredDocumentChunker.passageHeading(line) else { continue }
                headingsByTitle[heading.normalizedTitle, default: []].append(chunk)
                if let identifier = heading.identifier {
                    headingsByIdentifier["\(heading.kind):\(identifier.lowercased())", default: []].append(chunk)
                    if heading.kind == "numbered" {
                        bareNumberedHeadings[identifier.lowercased(), default: []].append(chunk)
                    }
                }
            }
        }

        // Numbered section references resolve only when the document has one matching
        // heading. Duplicate identifiers are intentionally left unlinked.
        let identifierPattern = #"(?i)\b(section|chapter|part)\s+([0-9]+(?:\.[0-9]+)*|[a-z])\b"#
        for source in chunks {
            for match in Self.matches(identifierPattern, in: source.text) {
                guard let kind = match.capture(1, in: source.text)?.lowercased(),
                      let identifier = match.capture(2, in: source.text)?.lowercased() else { continue }
                let exact = headingsByIdentifier["\(kind):\(identifier)"] ?? []
                let targets = exact.isEmpty ? (bareNumberedHeadings[identifier] ?? []) : exact
                append(source: source, target: targets.count == 1 ? targets[0] : nil,
                       kind: kind, text: match.whole(in: source.text))
            }

            // Quoted heading titles make a deterministic exact-title reference without
            // inferring semantic relationships from ordinary prose.
            let titlePattern = #"(?i)\b(?:see|refer(?:\s+to)?|defined\s+in|described\s+in|according\s+to|explained\s+in|in)\s+(?:(?:the\s+)?(?:section|chapter|heading|part)\s+)?[“\"']([^”\"']{3,120})[”\"']"#
            for match in Self.matches(titlePattern, in: source.text) {
                guard let title = match.capture(1, in: source.text) else { continue }
                let normalized = Self.normalize(title)
                let targets = headingsByTitle[normalized] ?? []
                append(source: source, target: targets.count == 1 ? targets[0] : nil,
                       kind: "heading-title", text: match.whole(in: source.text))
            }
        }
        return links
    }

    private static func normalize(_ text: String) -> String {
        StructuredDocumentChunker.normalizeHeadingTitle(text)
    }

    private struct Match {
        let range: Range<String.Index>
        let captures: [Range<String.Index>?]

        func capture(_ index: Int, in text: String) -> String? {
            guard captures.indices.contains(index), let range = captures[index] else { return nil }
            return String(text[range])
        }

        func whole(in text: String) -> String { String(text[range]) }
    }

    private static func matches(_ pattern: String, in text: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            let captures = (0..<result.numberOfRanges).map { index -> Range<String.Index>? in
                let value = result.range(at: index)
                guard value.location != NSNotFound else { return nil }
                return Range(value, in: text)
            }
            return Match(range: range, captures: captures)
        }
    }
}
