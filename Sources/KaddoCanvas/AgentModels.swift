import Foundation

public struct AgentMemorySuggestion: Codable, Identifiable, Equatable, Sendable {
    public init(id: UUID = UUID(), fact: String, quote: String, createdAt: Date, replacesID: UUID? = nil) {
        self.id = id; self.fact = fact; self.quote = quote; self.createdAt = createdAt; self.replacesID = replacesID
    }
    public var id = UUID()
    public var fact: String
    public var quote: String
    public var createdAt: Date
    public var replacesID: UUID?
}

public struct AgentMemoryProvenance: Codable, Equatable, Sendable {
    public var itemID: UUID
    public var source: String
    public var quote: String
    public var acceptedAt: Date
}

public struct AgentSource: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case web, folder }
    public var id = UUID()
    public var name: String
    public var kind: Kind
    public var url: URL?
    public var grant: AgentFolderGrant?
}

public struct AgentWorkflow: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var instructions: String
    public var sourceIDs: Set<UUID> = []
    public static let builtIns = [
        Self(name: "Daily briefing", instructions: "Brief me on today's tasks, upcoming classes and deadlines. Suggest priorities. Use selected sources when relevant. Do not change anything."),
        Self(name: "Study planning", instructions: "Help me choose a practical study plan from my tasks, available time and preferences. Suggest manageable steps. Ask before saving a plan or starting a timer.")
    ]
}

public struct AgentSchedule: Codable, Equatable, Sendable {
    public enum Frequency: String, Codable, CaseIterable, Sendable { case daily, weekly, interval }
    public var frequency: Frequency = .daily
    public var hour = 8
    public var minute = 0
    public var weekday = 2
    public var intervalMinutes = 30
    public var isValid: Bool {
        (0...23).contains(hour) && (0...59).contains(minute) && (1...7).contains(weekday)
            && (30...10_080).contains(intervalMinutes)
    }
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard isValid else { return nil }
        if frequency == .interval { return date.addingTimeInterval(Double(intervalMinutes) * 60) }
        var match = DateComponents(hour: hour, minute: minute, second: 0)
        if frequency == .weekly { match.weekday = weekday }
        return calendar.nextDate(after: date, matching: match, matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first, direction: .forward)
    }
    /// Find the latest due slot after a wake, so missed occurrences coalesce into one.
    public func latestDue(at date: Date, firstDue: Date, calendar: Calendar = .current) -> Date {
        if frequency == .interval {
            let interval = Double(intervalMinutes) * 60
            return firstDue.addingTimeInterval(floor(max(0, date.timeIntervalSince(firstDue)) / interval) * interval)
        }
        var match = DateComponents(hour: hour, minute: minute, second: 0)
        if frequency == .weekly { match.weekday = weekday }
        return calendar.nextDate(after: date.addingTimeInterval(1), matching: match, matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first, direction: .backward) ?? firstDue
    }
    public func occurrenceKey(at date: Date, calendar: Calendar = .current) -> String {
        if frequency == .interval { return String(Int(date.timeIntervalSince1970)) }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)-\(hour):\(minute)"
    }
}

public struct AgentRoutine: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var workflowID: UUID
    public var schedule: AgentSchedule
    public var monitoring = false
    public var enabled = true
    public var nextRun: Date
    public var timeZoneID: String
    public var lastOccurrence: String?
    public var lastFingerprint: String?
}

public struct AgentRoutineRun: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var routineID: UUID
    public var occurrence: String
    public var date: Date
    public var status: String
    public var summary: String
}

public struct AgentPlatformData: Codable, Sendable {
    public init() {}
    public var suggestions: [AgentMemorySuggestion] = []
    public var dismissedQuotes: [String] = []
    public var memories: [AgentMemoryProvenance] = []
    public var sources: [AgentSource] = []
    public var workflows: [AgentWorkflow] = AgentWorkflow.builtIns
    public var routines: [AgentRoutine] = []
    public var runs: [AgentRoutineRun] = []
}
