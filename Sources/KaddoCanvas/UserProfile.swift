import Foundation

public enum ProfileField: String, Codable, CaseIterable, Sendable {
    case name, birthday, subjects, goal, interests, focus

    var question: String {
        switch self {
        case .name: return "Hey, I’m Kaddo What should I call you?"
        case .birthday: return "When’s your birthday? Just the month and day, like March 12 or 03-12 — no year needed"
        case .subjects: return "What subjects or courses are you studying?"
        case .goal: return "What’s one goal you’re working toward right now?"
        case .interests: return "What do you enjoy outside studying?"
        case .focus: return "How many minutes feels right for a study block? Choose 1–720, like 25 minutes."
        }
    }

    var inputHint: String {
        switch self {
        case .name: return "Your name, or /skip…"
        case .birthday: return "March 12 or 03-12, or /skip…"
        case .subjects: return "Your subjects, or /skip…"
        case .goal: return "Your current goal, or /skip…"
        case .interests: return "Your interests, or /skip…"
        case .focus: return "Study minutes, or /skip…"
        }
    }
}

/// A birthday deliberately has no birth year or time zone.
public struct UserBirthday: Codable, Equatable, Sendable {
    public let month: Int
    public let day: Int

    public init?(month: Int, day: Int) {
        let calendar = Calendar(identifier: .gregorian)
        guard (1...12).contains(month), let date = calendar.date(from: DateComponents(year: 2000, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: date), days.contains(day) else { return nil }
        self.month = month
        self.day = day
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let month = try values.decode(Int.self, forKey: .month)
        let day = try values.decode(Int.self, forKey: .day)
        guard let birthday = Self(month: month, day: day) else {
            throw DecodingError.dataCorruptedError(forKey: .day, in: values, debugDescription: "Invalid birthday")
        }
        self = birthday
    }

    static func parse(_ text: String) -> Self? {
        let numeric = text.split(separator: "-", omittingEmptySubsequences: false)
        if numeric.count == 2, numeric.allSatisfy({ (1...2).contains($0.count) }),
           let month = Int(numeric[0]), let day = Int(numeric[1]) {
            return Self(month: month, day: day)
        }
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 2 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for month in 1...12 {
            let names = [formatter.monthSymbols[month - 1].lowercased(),
                         formatter.shortMonthSymbols[month - 1].lowercased()]
            if names.contains(words[0]), let day = Int(words[1]) { return Self(month: month, day: day) }
            if names.contains(words[1]), let day = Int(words[0]) { return Self(month: month, day: day) }
        }
        return nil
    }

    func occurs(on date: Date, timeZone: TimeZone = .current) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        var celebrationDay = day
        if month == 2, day == 29,
           let year = components.year,
           let february = calendar.date(from: DateComponents(year: year, month: 2, day: 1)),
           calendar.range(of: .day, in: .month, for: february)?.count == 28 {
            celebrationDay = 28
        }
        return components.month == month && components.day == celebrationDay
    }

    var displayText: String { String(format: "%02d-%02d", month, day) }
}

public struct UserProfile: Codable, Equatable, Sendable {
    public internal(set) var name: String?
    public internal(set) var birthday: UserBirthday?
    public internal(set) var subjects: String?
    public internal(set) var goal: String?
    public internal(set) var interests: String?
    public internal(set) var focusMinutes: Int?
    public internal(set) var skippedFields: Set<ProfileField> = []
    public internal(set) var lastQuestionDate: Date?
    public internal(set) var lastBirthdayCelebration: Date?

    public init() {}

    func value(for field: ProfileField) -> String? {
        switch field {
        case .name: return name
        case .birthday: return birthday?.displayText
        case .subjects: return subjects
        case .goal: return goal
        case .interests: return interests
        case .focus: return focusMinutes.map { "\($0) minutes" }
        }
    }

    var nextField: ProfileField? {
        ProfileField.allCases.first { value(for: $0) == nil && !skippedFields.contains($0) }
    }

    public var snapshot: UserProfileSnapshot {
        UserProfileSnapshot(name: name, birthday: birthday, subjects: subjects,
                            goal: goal, interests: interests, focusMinutes: focusMinutes)
    }
}

/// Only volunteered personal details cross the conversation boundary, never planner state.
public struct UserProfileSnapshot: Encodable, Equatable, Sendable {
    public let name: String?
    public let birthday: UserBirthday?
    public let subjects: String?
    public let goal: String?
    public let interests: String?
    public let focusMinutes: Int?
}
