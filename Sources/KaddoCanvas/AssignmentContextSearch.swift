import Foundation

/// Exercise references select their section and continuation, rather than matching the word "what".
struct AssignmentContextSearch {
    static func search(_ query: String, chunks: [DocumentChunk]) throws -> [NoteMatch] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 2_000 else {
            throw LocalInferenceError.invalidQuery
        }
        if let reference = DocumentQuestionReference.first(in: query) {
            let exactFiles = chunks.filter { query.localizedCaseInsensitiveContains($0.filename) }
            let namedFiles = chunks.filter { chunk in
                let stem = URL(fileURLWithPath: chunk.filename).deletingPathExtension().lastPathComponent
                return stem.count >= 3 && query.localizedCaseInsensitiveContains(stem)
            }
            let scopedChunks = !exactFiles.isEmpty ? exactFiles : !namedFiles.isEmpty ? namedFiles : chunks
            let groups = Dictionary(grouping: scopedChunks, by: \.documentID)
            var sections: [[DocumentChunk]] = []
            for document in groups.values {
                try Task.checkCancellation()
                let section = section(for: reference, in: document.sorted { $0.index < $1.index })
                if !section.isEmpty { sections.append(section) }
            }
            if sections.count > 1 {
                let named = sections.filter { section in
                    guard let name = section.first?.filename else { return false }
                    let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
                    return query.localizedCaseInsensitiveContains(name)
                        || (stem.count >= 3 && query.localizedCaseInsensitiveContains(stem))
                }
                guard named.count == 1 else { throw LocalInferenceError.ambiguousDocumentReference }
                return bounded(named[0])
            }
            if let section = sections.first { return bounded(section) }
            return []
        }
        if query.range(of: #"^(?:please )?(?:summari[sz]e|give (?:me )?a summary|لخص|لخّص)"#,
                       options: [.regularExpression, .caseInsensitive]) != nil {
            return bounded(chunks)
        }
        return try ScopedDocumentContextRouter.search(query, in: chunks)
    }

    static func section(for reference: DocumentQuestionReference, in chunks: [DocumentChunk]) -> [DocumentChunk] {
        sections(for: reference, in: chunks).max { lhs, rhs in
            lhs.reduce(0) { $0 + $1.text.count } < rhs.reduce(0) { $0 + $1.text.count }
        } ?? []
    }

    /// Returns every independently matched section so callers that need an unambiguous
    /// relation can reject duplicate targets without changing direct exercise selection.
    static func sections(for reference: DocumentQuestionReference, in chunks: [DocumentChunk]) -> [[DocumentChunk]] {
        struct HeadingLocation {
            let chunkIndex: Int
            let offset: String.Index
            let reference: DocumentQuestionReference?
        }
        var headings: [HeadingLocation] = []
        for (chunkIndex, chunk) in chunks.enumerated() {
            var lineStart = chunk.text.startIndex
            while lineStart < chunk.text.endIndex {
                let lineEnd = chunk.text[lineStart...].firstIndex(of: "\n") ?? chunk.text.endIndex
                let line = String(chunk.text[lineStart..<lineEnd])
                let passageHeading = StructuredDocumentChunker.passageHeading(line)
                let structuralHeading = passageHeading.flatMap { heading -> DocumentQuestionReference? in
                    guard let identifier = heading.identifier else { return nil }
                    return DocumentQuestionReference(number: identifier, kind: heading.kind)
                }
                if passageHeading != nil {
                    headings.append(HeadingLocation(chunkIndex: chunkIndex, offset: lineStart,
                        reference: structuralHeading))
                }
                for occurrence in DocumentQuestionReference.occurrences(in: line, includeNumberedHeading: true) {
                    let prefix = String(line[..<occurrence.range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if structuralHeading != nil, prefix.isEmpty { continue }
                    guard Self.isHeadingOccurrence(occurrence, in: line) else { continue }
                    let rawPrefix = String(line[..<occurrence.range.lowerBound])
                    let offset = chunk.text.index(lineStart, offsetBy: rawPrefix.count)
                    headings.append(HeadingLocation(chunkIndex: chunkIndex, offset: offset,
                        reference: occurrence.reference))
                }
                guard lineEnd < chunk.text.endIndex else { break }
                lineStart = chunk.text.index(after: lineEnd)
            }
        }

        let exactHeadings = headings.filter {
            $0.reference?.number == reference.number && $0.reference?.kind == reference.kind
        }
        let matchingHeadings: [HeadingLocation]
        if !exactHeadings.isEmpty {
            matchingHeadings = exactHeadings
        } else {
            let numberedFallbacks = headings.filter {
                $0.reference?.number == reference.number && $0.reference?.kind == "numbered"
            }
            // A bare number has no declared type. Use it only when it identifies one heading.
            guard numberedFallbacks.count == 1 else { return [] }
            matchingHeadings = numberedFallbacks
        }

        var matches: [[DocumentChunk]] = []
        for (headingIndex, heading) in headings.enumerated()
        where matchingHeadings.contains(where: { $0.chunkIndex == heading.chunkIndex && $0.offset == heading.offset }) {
            guard let targetReference = heading.reference else { continue }
            let nextBoundary = headings.dropFirst(headingIndex + 1).first { candidate in
                guard let nextReference = candidate.reference else { return true }
                if nextReference.kind == targetReference.kind { return true }
                if targetReference.kind == "numbered", ["question", "problem"].contains(nextReference.kind) { return true }
                return ["section", "chapter", "part", "exercise", "problem"].contains(nextReference.kind)
            }
            var selected: [DocumentChunk] = []
            let finalChunkIndex = nextBoundary?.chunkIndex ?? (chunks.count - 1)
            for chunkIndex in heading.chunkIndex...finalChunkIndex {
                let chunk = chunks[chunkIndex]
                let start = chunkIndex == heading.chunkIndex ? heading.offset : chunk.text.startIndex
                let end = nextBoundary?.chunkIndex == chunkIndex ? nextBoundary!.offset : chunk.text.endIndex
                guard start < end else { continue }
                let text = String(chunk.text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    selected.append(DocumentChunk(id: chunk.id, documentID: chunk.documentID, filename: chunk.filename,
                        index: chunk.index, text: text, sourceURL: chunk.sourceURL, location: chunk.location))
                }
            }
            if !selected.isEmpty { matches.append(selected) }
        }
        return matches
    }

    static func isHeadingOccurrence(
        _ occurrence: (reference: DocumentQuestionReference, range: Range<String.Index>), in line: String
    ) -> Bool {
        let before = String(line[..<occurrence.range.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !before.isEmpty else { return true }
        guard let final = before.last, ".!?".contains(final) else { return false }
        let after = String(line[occurrence.range.upperBound...])
        guard let delimiter = after.first, ":)–—-".contains(delimiter) else { return false }
        let titleStart = after.index(after: after.startIndex)
        let title = after[titleStart...].trimmingCharacters(in: .whitespaces)
        return title.first.map { $0.isUppercase || $0.isNumber || $0 == "(" } ?? false
    }

    static func inlineHeadingStarts(in line: String) -> [String.Index] {
        DocumentQuestionReference.occurrences(in: line, includeNumberedHeading: true)
            .filter { $0.range.lowerBound > line.startIndex && isHeadingOccurrence($0, in: line) }
            .map(\.range.lowerBound)
    }

    private static func bounded(_ chunks: [DocumentChunk]) -> [NoteMatch] {
        var remaining = 6_000
        var result: [NoteMatch] = []
        for chunk in chunks {
            guard result.count < 5 else { break }
            guard !chunk.text.isEmpty, chunk.text.count <= remaining else { continue }
            remaining -= chunk.text.count
            result.append(NoteMatch(chunk: chunk, score: 1))
        }
        return result
    }
}
