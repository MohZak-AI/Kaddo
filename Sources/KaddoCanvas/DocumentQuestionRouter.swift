import Foundation

/// A reference is conversational context, not extracted document text or a saved chat answer.
struct DocumentQuestionReference: Equatable, Sendable {
    let number: String
    let kind: String

    private static let labeled = #"(?<![\p{L}\p{N}])(?:exercise|ex\.?|question|q\.?|problem|section|chapter|part|التمرين|تمرين|السؤال|سؤال|المسألة|مسألة|الفصل|القسم|الباب)(?![\p{L}])\s*[-:#.]?\s*([0-9٠-٩۰-۹]{1,3}(?:\.[0-9٠-٩۰-۹]{1,3})*|[a-z])(?![\p{L}\p{N}])"#
    private static let numbered = #"^\s*\(?([0-9٠-٩۰-۹]{1,3})[.)]\s+"#

    static func first(in text: String) -> Self? { occurrences(in: text).first?.reference }

    static func occurrences(in text: String, includeNumberedHeading: Bool = false) -> [(reference: Self, range: Range<String.Index>)] {
        let patterns = includeNumberedHeading ? [labeled, numbered] : [labeled]
        return patterns.flatMap { pattern -> [(reference: Self, range: Range<String.Index>)] in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                guard let full = Range(match.range, in: text), let digits = Range(match.range(at: 1), in: text) else { return nil }
                let number = String(text[digits]).map { character -> String in
                    if character == "." { return "." }
                    return character.wholeNumberValue.map(String.init) ?? String(character).lowercased()
                }.joined()
                let numericParts = number.split(separator: ".")
                guard !numericParts.isEmpty,
                      numericParts.allSatisfy({ Int($0).map { $0 > 0 } ?? (numericParts.count == 1 && $0.count == 1 && $0.allSatisfy(\.isLetter)) }) else { return nil }
                if includeNumberedHeading, pattern == labeled {
                    // Package names such as lab8.ex1 are references, never exercise headings.
                    if full.lowerBound > text.startIndex, text[text.index(before: full.lowerBound)] == "." { return nil }
                    let before = text[..<full.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                    let after = text[full.upperBound...].trimmingCharacters(in: .whitespaces)
                    let markdownHeading = before.range(of: #"(?:^|\n)\s*(?:#{1,6}\s*|\*\*|__)$"#, options: .regularExpression) != nil
                    let boundary = before.isEmpty || markdownHeading || before.last.map { ".;:!?\n".contains($0) } == true
                    let titled = after.first.map { ":.)–—-".contains($0) } == true
                    guard boundary || titled else { return nil }
                }
                let label = text[full].lowercased()
                let kind = label.hasPrefix("ex") || label.contains("تمرين") ? "exercise"
                    : label.hasPrefix("problem") || label.contains("مسألة") ? "problem"
                    : label.hasPrefix("section") || label.contains("قسم") ? "section"
                    : label.hasPrefix("chapter") || label.contains("فصل") ? "chapter"
                    : label.hasPrefix("part") || label.contains("باب") ? "part" : "question"
                return (Self(number: number, kind: kind), full)
            }
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}

enum DocumentQuestionRouter {
    static func shouldRoute(_ input: String, hasDocuments: Bool, previousQuestion: String?, filenames: [String]) -> Bool {
        guard hasDocuments else { return false }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Creating planner items remains the command router's responsibility.
        if text.range(of: #"^(?:please )?(?:add|save|create|make|remind|start|pause|stop)\b"#,
                      options: .regularExpression) != nil { return false }
        if DocumentQuestionReference.first(in: text) != nil || DocumentRetrievalService.isOverview(text) { return true }
        let document = #"\b(?:my|this|the|uploaded|attached)\s+(?:assignment|document|file|pdf|worksheet|homework)\b|(?:الواجب|الملف|المرفق)"#
        let question = #"\b(?:what|which|how|why|explain|summari[sz]e|solve|answer|help|requirements?)\b|[?؟]|(?:اشرح|وضح|حل|ماذا|ما المطلوب)"#
        if matches(document, text), matches(question, text) { return true }
        if explicitlyNamesDocument(text, filenames: filenames) { return true }
        if isAmbiguousReference(text) { return true }
        if isFollowup(text) { return true }
        guard previousQuestion != nil else { return false }
        return isFollowup(text) || filenames.contains { name in
            text.localizedCaseInsensitiveContains(name)
                || (URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.count >= 3
                    && text.localizedCaseInsensitiveContains(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent))
        }
    }

    static func explicitlyNamesDocument(_ input: String, filenames: [String]) -> Bool {
        filenames.contains { name in
            let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            return input.localizedCaseInsensitiveContains(name)
                || (stem.count >= 3 && input.localizedCaseInsensitiveContains(stem))
        }
    }

    /// A filename selects a document. An exercise reference selects new section evidence,
    /// while it may still rely on the current document focus to resolve duplicate numbers.
    static func explicitlyNamesDocumentOrExercise(_ input: String, filenames: [String]) -> Bool {
        DocumentQuestionReference.first(in: input) != nil || explicitlyNamesDocument(input, filenames: filenames)
    }

    static func groundedQuery(_ input: String, previousQuestion: String?, filenames: [String]) -> String {
        if filenames.contains(where: { name in
            let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            return input.localizedCaseInsensitiveContains(name) || (stem.count >= 3 && input.localizedCaseInsensitiveContains(stem))
        }) { return input }
        guard let previousQuestion, DocumentQuestionReference.first(in: input) == nil,
              isFollowup(input) || filenames.contains(where: { name in
                  let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
                  return input.localizedCaseInsensitiveContains(name)
                      || (stem.count >= 3 && input.localizedCaseInsensitiveContains(stem))
              }) else { return input }
        let combined = previousQuestion + "\nFollow-up: " + input
        return combined.count <= 2_000 ? combined : input
    }

    static func isAmbiguousReference(_ text: String) -> Bool {
        matches(#"^(?:(?:no|actually)[,،]?\s*)?(?:the other one|other one|another one|the other (?:file|document)|الآخر|الثاني)[?!.،]*$"#, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isExplicitResume(_ text: String) -> Bool {
        matches(#"^(?:continue|resume|back to|go back to|let.s return to|نكمل|نرجع|ارجع|تابع)\b"#, text)
    }

    static func isFollowup(_ text: String) -> Bool {
        if isExplicitResume(text) { return true }
        if matches(#"^(?:show me (?:the )?steps|(?:which|what) rule (?:are|were) you using|what (?:mistake|pitfall)s? should i avoid|why does .+|no[,،]? (?:i meant|the)|(?:اشرح|وضح|وريني|أرني)\s+(?:الخطوات|القاعدة|ذلك|هذا)|(?:أي|اي|ما هي)\s+قاعدة|كيف أتجنب|لا[،,]? أقصد)"#, text) { return true }
        if matches(#"^(?:(?:please|can you|could you)\s+)?summari[sz]e\s+(?:this|that)(?:\s+(?:document|file|assignment|worksheet|homework|section|part))?\b"#, text) { return true }
        if matches(#"^(?:what|which|how many)\s+(?:attributes?|classes?|methods?|functions?|parameters?|formulas?|variables?|givens?|inputs?|outputs?|steps?|changes?|requirements?|deliverables?)\b|^(?:what|how)\s+.*\b(?:here|this part|that part|this step|that step)\b"#, text) { return true }
        return matches(#"^(?:(?:please|can you|could you)\s+)?(?:why[?!.]?$|how (?:do|should|can) i (?:start|begin|solve (?:it|this)|answer (?:it|this))\b|how did you\b|what (?:does that mean|about part|does part\s*\(?[a-z0-9])|(?:explain|show|tell me) (?:more|that|it|the steps)|(?:solve|answer|help me with) (?:it|that)|part(?:\s+|\()[a-z0-9](?:\)|\b)|and (?:part|question)|(?:walk|talk) me through (?:it|this|that|the (?:exercise|question|rule|steps))|give me (?:an? )?example(?: of (?:it|that|this))?|does that apply to (?:the )?(?:next|following) (?:question|exercise|part)|what does that mean here|what about (?:the )?(?:next|following) (?:question|exercise|part)|(?:اشرح أكثر|وضح أكثر|كيف أبدأ|لماذا|الجزء))"#, text)
    }

    static func isExerciseFollowup(_ text: String) -> Bool {
        guard DocumentQuestionReference.first(in: text) != nil else { return false }
        return matches(#"^(?:what about|and|now|next|then|instead|ماذا عن|وماذا عن|والتمرين)\s+"#, text)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression.union(.caseInsensitive)) != nil
    }
}
