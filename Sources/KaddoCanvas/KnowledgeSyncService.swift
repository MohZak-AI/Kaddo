import Combine
import Foundation

/// Captures immutable committed snapshots; one drain prevents older writes winning a race.
@MainActor
final class KnowledgeSyncService {
    private let planner: StudentPlanner
    private let library: KnowledgeLibrary
    private var observation: AnyCancellable?
    private var task: Task<Void, Never>?
    private var pending: [KnowledgeSourceRecord]?
    private var lastSnapshot: String?
    private var started = false
    private var initialization: Task<Void, Never>?

    init(planner: StudentPlanner, library: KnowledgeLibrary) {
        self.planner = planner; self.library = library
        observation = planner.successfulCommits.sink { [weak self] in self?.enqueue() }
    }
    func start() async {
        if initialization == nil {
            initialization = Task { [weak self] in
                guard let self else { return }
                await self.library.load()
                self.started = true
                self.enqueue()
                await self.waitForDrain()
            }
        }
        await initialization?.value
        await waitForDrain()
    }
    func wait() async {
        await initialization?.value
        await waitForDrain()
    }
    private func waitForDrain() async { while let task { await task.value } }
    private func enqueue() {
        guard started, planner.canSynchronizeKnowledge else { return }
        let records = snapshot()
        let signature = records.map { [$0.sourceKey, $0.title, $0.text, $0.categoryName, $0.kind].joined(separator: "\u{1f}") }.joined(separator: "\u{1e}")
        guard signature != lastSnapshot else { return }
        lastSnapshot = signature; pending = records
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while let records = self.pending {
                self.pending = nil
                if !(await self.library.synchronize(sources: records)) { self.lastSnapshot = nil }
            }
            self.task = nil
        }
    }
    private func snapshot() -> [KnowledgeSourceRecord] {
        var result: [KnowledgeSourceRecord] = []
        if let profile = planner.profile {
            for field in ProfileField.allCases {
                if let value = profile.value(for: field) {
                    result.append(.init(sourceKey: "profile:\(field.rawValue)", title: "My \(field.rawValue)", text: "Profile \(field.rawValue): \(value)", categoryName: "Personal", kind: "profile"))
                }
            }
        }
        let iso = ISO8601DateFormatter()
        for value in planner.tasks {
            result.append(.init(sourceKey: "task:\(value.id)", title: value.title, text: "\(value.kind): \(value.title)\nSubject: \(value.subject)\nStatus: \(value.completed ? "completed" : "pending")\nStudy duration: \(value.minutes) minutes\nDue: \(value.due.map(iso.string(from:)) ?? "not set")", categoryName: "Study", kind: "task"))
        }
        for value in planner.classes {
            result.append(.init(sourceKey: "class:\(value.id)", title: value.title, text: "Class: \(value.title)\nWeekday (Sunday=1): \(value.weekday)\nTime: \(value.time)", categoryName: "Study", kind: "class"))
        }
        for value in planner.notes {
            result.append(.init(sourceKey: "note:\(value.id)", title: String(value.text.prefix(80)), text: "Quick note: \(value.text)\nCreated: \(iso.string(from: value.created))", kind: "planner-note"))
        }
        for value in planner.cards {
            result.append(.init(sourceKey: "card:\(value.id)", title: value.question, text: "Revision question: \(value.question)\nAnswer: \(value.answer)", categoryName: "Study", kind: "card"))
        }
        for value in planner.reminders {
            result.append(.init(sourceKey: "reminder:\(value.id)", title: value.title, text: "Reminder: \(value.title)\nDate: \(iso.string(from: value.date))\nStatus: \(value.delivered ? "delivered" : "pending")", categoryName: "Study", kind: "reminder"))
        }
        return result.sorted { $0.sourceKey < $1.sourceKey }
    }
}
