import CryptoKit
import Foundation

struct DocumentPlanEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case task, assignment, exam, `class` }
    var kind: Kind
    var title: String
    var evidence: String
    var date: String?
    var weekday: Int?
    var time: String?
    var question: String?
    // Assigned by Kaddo after analysis; never trusted as an AI-selected target.
    var id: UUID?
    var allowConflict: Bool?

    var fingerprint: String {
        documentFingerprint([kind.rawValue, title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                             date ?? "", weekday.map(String.init) ?? "", time ?? ""].joined(separator: "|"))
    }
}

struct DocumentAnalysis: Codable, Equatable, Sendable {
    var category: String
    var categoryReason: String?
    var entries: [DocumentPlanEntry]
}

struct DocumentIngestionRecord: Codable, Equatable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable { case pending, processing, needsClarification, complete, failed }
    var id: String // Extracted-content hash, shared across repeated uploads and filenames.
    var documentID: UUID
    var sessionID: UUID
    var filename: String
    var status: Status = .pending
    var analysis: DocumentAnalysis?
    var completedEntries: Set<UUID> = []
    var skippedEntries: Set<UUID>?
    var clarificationAnswers: [String: String]?
    var message: String?
}

struct DocumentEntryProvenance: Codable, Equatable, Sendable {
    var documentID: UUID
    var contentHash: String
    var entryID: UUID
    var plannerID: UUID
    var fingerprint: String
    var evidence: String
}

func documentFingerprint(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

extension DocumentPlanEntry {
    static func parsedDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    func validate(in text: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 300,
              evidence.count >= 3, evidence.count <= 2_000, text.contains(evidence),
              question.map({ !$0.isEmpty && $0.count <= 500 }) ?? true else { throw AssistantError.invalidResponse }
        if let date { guard Self.parsedDate(date) != nil else { throw AssistantError.invalidResponse } }
        if let weekday { guard (1...7).contains(weekday) else { throw AssistantError.invalidResponse } }
        if let time {
            guard time.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil else {
                throw AssistantError.invalidResponse
            }
        }
        if question == nil {
            switch kind {
            case .assignment, .exam: guard date != nil else { throw AssistantError.invalidResponse }
            case .class: guard weekday != nil, time != nil else { throw AssistantError.invalidResponse }
            case .task: break
            }
        }
    }
}
