import Combine
import Foundation

private final class PlannerTicker: @unchecked Sendable {
    let timer: Timer
    init(_ timer: Timer) { self.timer = timer }
    deinit { timer.invalidate() }
}

public struct StudentTask: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var subject: String = ""
    public var due: Date?
    public var minutes: Int = 25
    public var kind: String = "task"
    public var completed = false
}

public struct StudentClass: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var weekday: Int
    public var time: String
}

public struct StudentNote: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var text: String
    public var created = Date()
}

public struct RevisionCard: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var question: String
    public var answer: String
}

public struct StudentReminder: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var date: Date
    public var delivered = false
}

struct StudentPlannerData: Codable {
    var tasks: [StudentTask] = []
    var classes: [StudentClass] = []
    var notes: [StudentNote] = []
    var cards: [RevisionCard] = []
    var reminders: [StudentReminder] = []
    var documentReceipts: [String: DocumentEntryProvenance]?
    var lastCheckIn: Date?
    var profile: UserProfile?
}

public enum PlannerCompanionEvent: Sendable {
    case message(text: String, emotion: PetEmotion)
    case alert(text: String, emotion: PetEmotion)
}

/// Local student tools remain usable with no documents, model, or network connection.
@MainActor
public final class StudentPlanner: ObservableObject {
    @Published private(set) var data = StudentPlannerData()
    @Published public private(set) var timer: StudyTimer?
    @Published public private(set) var pendingPrompt: String?
    @Published public private(set) var storageError: String?
    @Published public var soundsEnabled = true
    @Published public private(set) var quizIndex: Int?
    @Published public private(set) var answerRevealed = false
    public let successfulCommits = PassthroughSubject<Void, Never>()
    private var operationDepth = 0
    private var commitPending = false
    public var canSynchronizeKnowledge: Bool { !loadFailed }
    public let companionEvents = PassthroughSubject<PlannerCompanionEvent, Never>()
    private(set) var isDeliveringAlert = false
    var onMessage: ((String, PetEmotion) -> Void)?
    var beforeMessage: (() -> Void)?
    var onAlert: ((String) -> Void)?
    var onTimerChange: ((Int, String?) -> Void)?
    var newSession: ((String) -> Void)?
    var notificationAction: ((Bool) -> Void)?
    var notificationRequest: ((Bool) async -> KaddoToolResult)?
    var canPresentCheckIn: (() -> Bool)?
    private let storageURL: URL?
    private let now: () -> Date
    private var ticker: PlannerTicker?
    private var draft: StudentTask?
    private enum Step { case dailyTasks, title, subject, due, minutes, profile(ProfileField) }
    private var step: Step?
    private var lastInteraction: Date?
    private var operationFailure: String?
    private var lastOutput = ""
    private static let conversationQuietInterval: TimeInterval = 60

    public static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kaddo/StudentPlanner.json")
    }

    public init(storageURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.storageURL = storageURL
        self.now = now
        if let storageURL, FileManager.default.fileExists(atPath: storageURL.path) {
            do { data = try JSONDecoder().decode(StudentPlannerData.self, from: Data(contentsOf: storageURL)) }
            catch { storageError = "Couldn’t read your planner. The saved file has been kept. \(error.localizedDescription)" }
        }
    }

    public var tasks: [StudentTask] { data.tasks }
    public var classes: [StudentClass] { data.classes }
    public var notes: [StudentNote] { data.notes }
    public var cards: [RevisionCard] { data.cards }
    public var reminders: [StudentReminder] { data.reminders }
    public var isLocalInputPending: Bool { step != nil }
    public var profile: UserProfile? { data.profile }
    public var defaultFocusMinutes: Int {
        guard let minutes = profile?.focusMinutes, (1...720).contains(minutes) else { return 25 }
        return minutes
    }
    public var pendingProfileField: ProfileField? {
        if case let .profile(field) = step { return field }
        return nil
    }
    public var currentCard: RevisionCard? {
        guard let quizIndex, data.cards.indices.contains(quizIndex) else { return nil }
        return data.cards[quizIndex]
    }

    private var canOfferCheckIn: Bool {
        step == nil && (timer == nil || timer?.status == .completed)
            && canPresentCheckIn?() != false
            && lastInteraction.map({ now().timeIntervalSince($0) >= Self.conversationQuietInterval }) != false
    }

    public func start() {
        guard ticker == nil else { return }
        let ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker.tolerance = 0.05
        self.ticker = PlannerTicker(ticker)
        RunLoop.main.add(ticker, forMode: .common)
        if !checkInIfNeeded(), canOfferCheckIn {
            let greeting = profile?.name.map { "Welcome back, \($0)!" } ?? "Welcome back!"
            say(todaySummary() + "\n\n\(greeting) Type /plan to plan today, or /help for commands.", emotion: .happy)
        }
        tick()
    }

    public func stop() { ticker = nil }

    @discardableResult
    public func checkInIfNeeded() -> Bool {
        let calendar = Calendar.current
        guard canOfferCheckIn else { return false }
        let profile = data.profile ?? UserProfile()
        if profile.lastQuestionDate.map({ calendar.isDate($0, inSameDayAs: now()) }) != true,
           let field = profile.nextField {
            beginProfileQuestion(field)
            return true
        }
        if data.lastCheckIn.map({ calendar.isDate($0, inSameDayAs: now()) }) != true {
            beginDailyPlan()
            return true
        }
        if birthdayGreeting != nil {
            say(todaySummary(), emotion: .happy)
            return true
        }
        return false
    }

    func say(_ text: String, emotion: PetEmotion = .idle) {
        beforeMessage?()
        var reply = text
        if pendingProfileField != nil, let pendingPrompt, !reply.contains(pendingPrompt) {
            reply += "\n\n" + pendingPrompt + "\n" + profileAnswerHint
        }
        var emotion = emotion
        if let greeting = birthdayGreeting {
            data.profile?.lastBirthdayCelebration = now()
            save()
            reply = greeting + "\n\n" + reply
            emotion = .celebrating
        }
        lastOutput = reply + (storageError.map { "\n\n\($0)" } ?? "")
        onMessage?(lastOutput, emotion)
        companionEvents.send(isDeliveringAlert ? .alert(text: lastOutput, emotion: emotion)
                             : .message(text: lastOutput, emotion: emotion))
    }

    public func beginDailyPlan(acknowledgment: String? = nil) {
        data.lastCheckIn = now()
        save()
        draft = nil
        step = .dailyTasks
        pendingPrompt = "What are your tasks for today?"
        let greeting = profile?.name.map { "\($0), let’s" } ?? "let’s"
        let introduction = acknowledgment.map { $0 + "\n\n" } ?? ""
        say(introduction + todaySummary() + "\n\n\(greeting) make today a little lighter What are your tasks for today? Answer naturally or use /reply <answer>, separating tasks with semicolons or new lines, or /skip.", emotion: .thinking)
    }

    public func tick() {
        if var countdown = timer {
            let message = countdown.advance(to: now())
            if countdown != timer { timer = countdown; syncTimer() }
            if let message { alert(message, emotion: timerEmotion(countdown)) }
        }
        let due = data.reminders.filter { !$0.delivered && $0.date <= now() }
        if !due.isEmpty {
            for reminder in due {
                if let index = data.reminders.firstIndex(where: { $0.id == reminder.id }) {
                    data.reminders[index].delivered = true
                }
            }
            save()
            alert(due.map { "Reminder: \($0.title)" }.joined(separator: "\n"))
        }
        if ticker != nil || data.lastCheckIn != nil || data.profile?.lastQuestionDate != nil {
            checkInIfNeeded()
        }
    }

    public func startTimer(minutes: Int, title: String, isBreak: Bool = false) {
        guard (1...720).contains(minutes) else { reject("Choose between 1 and 720 minutes."); return }
        guard timer == nil || timer?.status == .completed else {
            reject("A timer already exists. Use /pause, /resume, or /stop before starting another.")
            return
        }
        timer = StudyTimer(title: title, seconds: minutes * 60, now: now(), isBreak: isBreak)
        syncTimer()
        say("\(title) · \(minutes) minutes. I’ll alert you halfway, at 5 minutes, at 30 seconds, and when time’s up. Checkpoints before the start are skipped.", emotion: isBreak ? .sleeping : .thinking)
    }

    public func pauseTimer() {
        guard var countdown = timer, countdown.status == .running else { reject("No running timer to pause."); return }
        let message = countdown.pause(at: now())
        timer = countdown
        syncTimer()
        if let message { alert(message, emotion: timerEmotion(countdown)) }
        if countdown.status == .paused { say("Paused with \(countdown.clockText) left. Use /resume when ready.", emotion: .sleeping) }
    }

    public func resumeTimer() {
        guard var countdown = timer, countdown.status == .paused else { reject("No paused timer. Try /timer 25."); return }
        countdown.resume(at: now())
        timer = countdown
        syncTimer()
        say("Resumed \(countdown.title). You have \(countdown.clockText) left.", emotion: countdown.isBreak ? .sleeping : .thinking)
    }

    public func stopTimer() {
        guard timer != nil else { reject("No active timer. Try /timer 25."); return }
        timer = nil
        syncTimer()
        say("Timer stopped. Your tasks are still in your planner.")
    }

    private func syncTimer() {
        onTimerChange?(timer?.remaining ?? 0, timer?.title)
    }

    private func timerEmotion(_ countdown: StudyTimer) -> PetEmotion {
        countdown.status == .completed ? .celebrating : (countdown.remaining <= 30 ? .thinking : .happy)
    }

    private func alert(_ message: String, emotion: PetEmotion = .happy) {
        // Let a reminder or timer milestone remain visible before offering a daily question.
        lastInteraction = now()
        isDeliveringAlert = true
        defer { isDeliveringAlert = false }
        say(message, emotion: emotion)
        onAlert?(message)
    }

    public func toggleTask(_ id: UUID) {
        guard let index = data.tasks.firstIndex(where: { $0.id == id }) else { return }
        data.tasks[index].completed.toggle()
        save()
    }

    public func focusTask(_ task: StudentTask) { startTimer(minutes: task.minutes, title: task.title) }

    public func removeTask(_ id: UUID) { data.tasks.removeAll { $0.id == id }; save() }
    public func removeClass(_ id: UUID) { data.classes.removeAll { $0.id == id }; save() }
    public func removeNote(_ id: UUID) { data.notes.removeAll { $0.id == id }; save() }
    public func removeCard(_ id: UUID) {
        data.cards.removeAll { $0.id == id }; quizIndex = nil; answerRevealed = false; save()
    }
    public func removeReminder(_ id: UUID) { data.reminders.removeAll { $0.id == id }; save() }

    public func todaySummary() -> String {
        let open = data.tasks.enumerated().filter { !$0.element.completed }
        let today = Calendar.current.startOfDay(for: now())
        let due = open.filter { $0.element.due.map { $0 < today } ?? false }.count
        let lines = open.prefix(8).map { index, task in
            "\(index + 1). \(task.title)\(task.subject.isEmpty ? "" : " · \(task.subject)")\(task.due.map { " · due \(dateText($0))" } ?? "")"
        }
        let weekday = Calendar.current.component(.weekday, from: now())
        let lessons = data.classes.filter { $0.weekday == weekday }.sorted { $0.time < $1.time }
        return (["Today · \(open.count) open task(s)\(due > 0 ? " · \(due) overdue" : "")"]
            + (lines.isEmpty ? ["Your list is clear. Add a task with /new."] : lines)
            + lessons.map { "Class \($0.time) · \($0.title)" }).joined(separator: "\n")
    }

    func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    func performCommand(_ input: String) -> KaddoToolResult {
        performOperation { _ = handle(input) }
    }

    func performOperation(_ operation: () -> Void) -> KaddoToolResult {
        let previous = data
        let previousStep = step
        let previousDraft = draft
        let previousPrompt = pendingPrompt
        operationFailure = nil
        lastOutput = ""
        operationDepth += 1
        operation()
        operationDepth -= 1
        if let failure = operationFailure {
            if storageError != nil {
                data = previous; step = previousStep; draft = previousDraft; pendingPrompt = previousPrompt
            }
            commitPending = false
            return .init(.failure, failure)
        }
        if commitPending, operationDepth == 0 { commitPending = false; successfulCommits.send() }
        return .init(.success, lastOutput.isEmpty ? "Done." : lastOutput)
    }

    private func reject(_ text: String) {
        operationFailure = text
        say(text)
    }

    func resizeTimer(minutes: Int) {
        guard (1...720).contains(minutes) else { reject("Choose 1–720 minutes."); return }
        guard let current = timer, current.status != .completed else { reject("There is no active timer to change."); return }
        var replacement = StudyTimer(title: current.title, seconds: minutes * 60, now: now(), isBreak: current.isBreak)
        if current.status == .paused { _ = replacement.pause(at: now()) }
        timer = replacement
        syncTimer()
        say("Changed \(current.title) to \(minutes) minutes · \(replacement.status.rawValue).", emotion: .thinking)
    }

    func addRevisionCard(question: String, answer: String) {
        data.cards.append(RevisionCard(question: question, answer: answer)); save()
        say("Revision card saved. You have \(data.cards.count) card(s).", emotion: .happy)
    }

    var assistantPendingQuestion: String? { pendingPrompt }

    /// Planner changes and import receipts share the same atomic JSON write.
    func applyDocumentEntry(_ entry: DocumentPlanEntry, record: DocumentIngestionRecord) -> KaddoToolResult {
        guard let entryID = entry.id else { return .init(.failure, "Missing document entry identity.") }
        let key = record.id + ":" + entryID.uuidString
        if data.documentReceipts?[key] != nil { return .init(.success, "Already saved.") }
        let due = entry.date.flatMap(DocumentPlanEntry.parsedDate)
        let normalized = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var existingID = data.documentReceipts?.values.first { $0.fingerprint == entry.fingerprint }?.plannerID
        if entry.kind == .class {
            if let same = data.classes.first(where: {
                $0.title.lowercased() == normalized && $0.weekday == entry.weekday && $0.time == entry.time
            }) { existingID = same.id }
            if existingID == nil, entry.allowConflict != true, data.classes.contains(where: {
                ($0.title.lowercased() == normalized && $0.weekday == entry.weekday)
                    || ($0.weekday == entry.weekday && $0.time == entry.time)
            }) { return .init(.needsInput, "\(entry.title) conflicts with a saved class. Keep this as an additional class? Reply yes or skip.") }
        } else {
            if let same = data.tasks.first(where: {
                $0.title.lowercased() == normalized && $0.due == due && $0.kind == entry.kind.rawValue
            }) { existingID = same.id }
            if existingID == nil, entry.allowConflict != true,
               data.tasks.contains(where: { $0.title.lowercased() == normalized && $0.due != due }) {
                return .init(.needsInput, "\(entry.title) has a different saved deadline. Keep this as an additional task? Reply yes or skip.")
            }
        }
        return performOperation {
            let plannerID = existingID ?? UUID()
            if existingID == nil {
                if entry.kind == .class, let weekday = entry.weekday, let time = entry.time {
                    self.data.classes.append(StudentClass(id: plannerID, title: entry.title, weekday: weekday, time: time))
                } else {
                    self.data.tasks.append(StudentTask(id: plannerID, title: entry.title,
                        subject: record.analysis?.category ?? "", due: due, kind: entry.kind.rawValue))
                }
            }
            if self.data.documentReceipts == nil { self.data.documentReceipts = [:] }
            self.data.documentReceipts?[key] = .init(documentID: record.documentID, contentHash: record.id,
                entryID: entryID, plannerID: plannerID, fingerprint: entry.fingerprint, evidence: entry.evidence)
            self.save()
        }
    }

    private func save() {
        guard let storageURL else { didCommit(); return }
        // Do not replace a saved file that failed decoding; keep it recoverable.
        guard !FileManager.default.fileExists(atPath: storageURL.path) || !loadFailed else {
            operationFailure = storageError; return
        }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(data).write(to: storageURL, options: .atomic)
            storageError = nil
            didCommit()
        } catch {
            storageError = "Couldn’t save planner changes: \(error.localizedDescription)"
            operationFailure = storageError
        }
    }

    private func didCommit() {
        if operationDepth > 0 { commitPending = true } else { successfulCommits.send() }
    }

    private var loadFailed: Bool { storageError?.hasPrefix("Couldn’t read") == true }

}

public struct StudentCommand: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let usage: String
    public let detail: String

    public static let all: [StudentCommand] = [
        .init(name: "/new", usage: "/new", detail: "Add a task with guided questions"),
        .init(name: "/plan", usage: "/plan", detail: "Plan your day together"),
        .init(name: "/reply", usage: "/reply <answer>", detail: "Answer the current guided question"),
        .init(name: "/ask", usage: "/ask <question>", detail: "Query documents in the selected session with the selected AI provider"),
        .init(name: "/forget", usage: "/forget", detail: "Clear this app session’s casual conversation memory"),
        .init(name: "/profile", usage: "/profile", detail: "Review personal details; edit <field>, continue, or clear"),
        .init(name: "/today", usage: "/today", detail: "See tasks and today’s classes"),
        .init(name: "/planner", usage: "/planner", detail: "Read your student overview"),
        .init(name: "/task", usage: "/task Read chapter 3", detail: "Quickly add a task for today"),
        .init(name: "/assignment", usage: "/assignment 2026-11-02 Biology lab report", detail: "Save an assignment deadline"),
        .init(name: "/exam", usage: "/exam 2026-11-05 Calculus midterm", detail: "Add an exam to prepare for"),
        .init(name: "/tasks", usage: "/tasks", detail: "List tasks and their numbers"),
        .init(name: "/done", usage: "/done 1", detail: "Complete a numbered task"),
        .init(name: "/focus", usage: "/focus 1", detail: "Start the timer for a numbered task"),
        .init(name: "/timer", usage: "/timer 25 Essay draft", detail: "Start a countdown in minutes"),
        .init(name: "/break", usage: "/break 5", detail: "Start a break countdown"),
        .init(name: "/pause", usage: "/pause", detail: "Pause the countdown"),
        .init(name: "/resume", usage: "/resume", detail: "Resume the countdown"),
        .init(name: "/stop", usage: "/stop", detail: "Stop and clear the countdown"),
        .init(name: "/status", usage: "/status", detail: "Check timer progress and planning question"),
        .init(name: "/sound", usage: "/sound on", detail: "Turn alert sounds on or off"),
        .init(name: "/notifications", usage: "/notifications on", detail: "Enable or disable macOS alert banners"),
        .init(name: "/remove", usage: "/remove task 1", detail: "Remove a numbered task, class, note, card, or reminder"),
        .init(name: "/remind", usage: "/remind 10m Pack your lab book", detail: "Reminder in seconds, minutes, or hours"),
        .init(name: "/reminders", usage: "/reminders", detail: "List pending reminders"),
        .init(name: "/class", usage: "/class Mon 09:00 Chemistry · Room 12", detail: "Add a weekly class"),
        .init(name: "/schedule", usage: "/schedule", detail: "See the weekly timetable"),
        .init(name: "/note", usage: "/note Ask tutor about chapter 4", detail: "Save a quick note"),
        .init(name: "/notes", usage: "/notes", detail: "Read saved quick notes"),
        .init(name: "/card", usage: "/card What is mitosis? | Cell division", detail: "Create a revision flashcard"),
        .init(name: "/cards", usage: "/cards", detail: "List saved revision cards"),
        .init(name: "/quiz", usage: "/quiz", detail: "Practice your revision cards"),
        .init(name: "/reveal", usage: "/reveal", detail: "Reveal the current card’s answer"),
        .init(name: "/next", usage: "/next", detail: "Move to the next revision card"),
        .init(name: "/session", usage: "/session Biology", detail: "Create a separate folder for course documents"),
        .init(name: "/skip", usage: "/skip", detail: "Skip an optional planning question"),
        .init(name: "/cancel", usage: "/cancel", detail: "Cancel guided planning"),
        .init(name: "/help", usage: "/help", detail: "Browse all commands")
    ]

    public static func matching(_ input: String) -> [StudentCommand] {
        let prefix = input.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? "/"
        return all.filter { $0.name.hasPrefix(prefix) }
    }
}

extension StudentPlanner {
    /// Personal questions alone accept plain answers; task planning remains command-only.
    @discardableResult
    public func answerPersonalQuestion(_ input: String) -> Bool {
        guard let field = pendingProfileField, !input.hasPrefix("/") else { return false }
        noteUserInteraction()
        answerProfile(input.trimmingCharacters(in: .whitespacesAndNewlines), field: field)
        return true
    }

    func noteUserInteraction() { lastInteraction = now() }

    /// Commands handled outside the planner use this too, so hidden prompts cannot capture chat.
    func prepareForCommand(_ command: String) {
        if !["/reply", "/skip", "/cancel", "/status"].contains(command) {
            dismissPersonalQuestion()
        }
    }

    func dismissPersonalQuestion() {
        guard pendingProfileField != nil else { return }
        data.profile?.lastQuestionDate = now()
        save()
        step = nil
        pendingPrompt = nil
    }

    private var profileAnswerHint: String {
        "You can answer here or use /reply <answer>. /skip skips this detail; /cancel leaves it for another day."
    }

    private var birthdayGreeting: String? {
        guard let profile, let birthday = profile.birthday, birthday.occurs(on: now()),
              profile.lastBirthdayCelebration.map({ Calendar.current.isDate($0, inSameDayAs: now()) }) != true else {
            return nil
        }
        let name = profile.name.map { ", \($0)" } ?? ""
        return "Happy birthday\(name)! I hope you have a lovely day."
    }

    private func beginProfileQuestion(_ field: ProfileField) {
        if data.profile == nil { data.profile = UserProfile() }
        data.profile?.lastQuestionDate = now()
        save()
        draft = nil
        step = .profile(field)
        pendingPrompt = field.question
        say(field.question + "\n" + profileAnswerHint + "\nPersonal details save on this Mac. Relevant details may be used by your selected AI provider.", emotion: .thinking)
    }

    private func handleProfileCommand(_ argument: String) {
        let parts = argument.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.isEmpty {
            let lines = ProfileField.allCases.map { field in
                let value = profile?.value(for: field)
                    ?? (profile?.skippedFields.contains(field) == true ? "Skipped" : "Not shared")
                return "\(field.rawValue.capitalized): \(value)"
            }
            say("Your profile · saved on this Mac\n" + lines.joined(separator: "\n")
                + "\n\nUse /profile edit <field> (name, birthday, subjects, goal, interests, focus), /profile continue, or /profile clear.")
        } else if parts == ["clear"] {
            data.profile = UserProfile()
            data.profile?.lastQuestionDate = now()
            save()
            say("Personal details cleared I’ll leave introductions until tomorrow. Use /profile continue whenever you want.")
        } else if parts == ["continue"] {
            guard let field = (profile ?? UserProfile()).nextField else {
                say("We’re all caught up Use /profile edit <field> to change or revisit any detail.")
                return
            }
            beginProfileQuestion(field)
        } else if parts.count == 2, parts[0] == "edit", let field = ProfileField(rawValue: parts[1]) {
            beginProfileQuestion(field)
        } else {
            reject("Use /profile, /profile continue, /profile clear, or /profile edit <field>: name, birthday, subjects, goal, interests, focus.")
        }
    }

    private func answerProfile(_ text: String, field: ProfileField) {
        if text == "/skip" {
            data.profile?.skippedFields.insert(field)
        } else {
            // Foundation's controlCharacters also includes joiners used in valid emoji names.
            let hasLineOrControl = text.unicodeScalars.contains {
                [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
            }
            guard !text.isEmpty, text.count <= 200, !hasLineOrControl else {
                reject("Keep this detail to one line of 1–200 characters, or use /skip.")
                return
            }
            switch field {
            case .name:
                var name = text
                for prefix in ["my name is ", "call me ", "i’m ", "i'm "] where name.lowercased().hasPrefix(prefix) {
                    name = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
                guard !name.isEmpty, name.count <= 80 else {
                    reject("What should I call you? Choose a name up to 80 characters, or use /skip.")
                    return
                }
                data.profile?.name = name
            case .birthday:
                guard let birthday = UserBirthday.parse(text) else {
                    reject("I couldn’t read that birthday. Try March 12 or 03-12, without a year, or use /skip.")
                    return
                }
                data.profile?.birthday = birthday
            case .subjects: data.profile?.subjects = text
            case .goal: data.profile?.goal = text
            case .interests: data.profile?.interests = text
            case .focus:
                let value = text.lowercased().replacingOccurrences(of: #"\s*(minutes?|mins?)$"#,
                    with: "", options: .regularExpression)
                guard let minutes = parseMinutes(value) else {
                    reject("Choose a whole number from 1–720 minutes, or use /skip.")
                    return
                }
                data.profile?.focusMinutes = minutes
            }
            data.profile?.skippedFields.remove(field)
        }
        save()
        step = nil
        pendingPrompt = nil
        let acknowledgment: String
        if text == "/skip" { acknowledgment = "No worries, we’ll skip that detail" }
        else if field == .name { acknowledgment = "Nice to meet you, \(profile?.name ?? text)" }
        else { acknowledgment = "Got it, I’ll remember that" }
        if data.lastCheckIn.map({ Calendar.current.isDate($0, inSameDayAs: now()) }) != true,
           timer == nil || timer?.status == .completed {
            beginDailyPlan(acknowledgment: acknowledgment)
        } else {
            say(acknowledgment + "\nUse /plan to plan today, or /profile continue to share more.", emotion: .happy)
        }
    }

    @discardableResult
    public func handle(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return false }
        guard text.count <= 2_000 else { reject("Keep your command to 2,000 characters"); return true }
        let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let command = String(parts[0]).lowercased()
        let argument = parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        noteUserInteraction()
        prepareForCommand(command)
        switch command {
        case "/profile": handleProfileCommand(argument)
        case "/new":
            step = .title; draft = StudentTask(title: "", minutes: defaultFocusMinutes)
            if argument.isEmpty { ask("What task would you like to work on?") }
            else { answerPrompt(argument) }
        case "/reply":
            guard step != nil else { reject("No planning question yet. Start with /new or /plan, then use /reply <answer>"); return true }
            guard !argument.isEmpty else { reject("I’m listening use /reply <answer> for the current question, or /cancel."); return true }
            answerPrompt(argument)
        case "/plan": beginDailyPlan()
        case "/cancel":
            let personal = pendingProfileField != nil
            dismissPersonalQuestion()
            step = nil; draft = nil; pendingPrompt = nil
            say(personal ? "No worries, we can get to know each other another day Use /profile continue whenever you’re ready."
                : "no worries, planning cancelled use /new or /plan whenever you’re ready.")
        case "/skip":
            if step == nil { reject("There isn’t a planning question to skip. Try /plan.") }
            else { answerPrompt("/skip") }
        case "/today": say(todaySummary())
        case "/planner":
            say(todaySummary() + "\n\n\(data.classes.count) weekly classes · \(data.notes.count) quick notes · \(data.cards.count) revision cards\nUse /schedule, /notes, /quiz, or /reminders. Use /help for all commands.")
        case "/help":
            say("Kaddo features · ask naturally or use a shortcut\n\n" + StudentCommand.all.map { "\($0.usage) — \($0.detail)" }.joined(separator: "\n")
                + "\n\nChat, ask general questions, or request a feature naturally. Relevant replies answer guided questions; unrelated chat keeps them open. Slash commands remain shortcuts. Ask about your documents naturally or use /ask; /cancel leaves a question. /forget clears only this session’s casual chat; /profile clear erases saved personal details. General chat uses the cloud AI provider with your personal key or selected local Ollama. Cloud document questions send relevant selected-session excerpts. Common actions, commands, and greetings work offline. Timers and reminders alert while Kaddo is running; countdowns include time asleep. Planner items and your optional profile save locally; timers do not survive quitting.")
        case "/task":
            guard !argument.isEmpty else { reject("Use /task Read chapter 3, or /new for guided setup."); return true }
            data.tasks.append(StudentTask(title: argument, due: Calendar.current.startOfDay(for: now()), minutes: defaultFocusMinutes))
            save(); say("nice, saved it! Added: \(argument). Use /tasks to see its number, then /focus <number>.", emotion: .happy)
        case "/assignment", "/exam":
            let values = argument.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard values.count == 2, let date = parseDate(String(values[0])) else {
                reject("Use \(command) YYYY-MM-DD Title. You can also use today or tomorrow instead of a date."); return true
            }
            let title = String(values[1])
            data.tasks.append(StudentTask(title: title, due: date, minutes: defaultFocusMinutes, kind: command == "/exam" ? "exam" : "assignment"))
            save(); say("Saved \(command == "/exam" ? "exam" : "assignment"): \(title) · \(dateText(date)). Add revision steps with /new.", emotion: .happy)
        case "/tasks":
            say(data.tasks.isEmpty ? "No tasks yet. What would you like to do? Try /new." : data.tasks.enumerated().map {
                "\($0.offset + 1). \($0.element.completed ? "✓" : "○") \($0.element.title) · \($0.element.minutes) min\($0.element.due.map { " · due \(dateText($0))" } ?? "")"
            }.joined(separator: "\n"))
        case "/done", "/focus":
            guard let number = Int(argument), data.tasks.indices.contains(number - 1) else {
                reject("Use \(command) followed by a task number from /tasks, for example \(command) 1."); return true
            }
            let task = data.tasks[number - 1]
            if command == "/focus" {
                if task.completed { reject("That task is complete. Choose an open task from /tasks.") }
                else { focusTask(task) }
            } else {
                data.tasks[number - 1].completed = true; save()
                say("Finished: \(task.title)! What’s next? Try /tasks or take /break 5.", emotion: .celebrating)
            }
        case "/timer", "/break":
            let values = argument.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let minutes = values.first.map { parseMinutes(String($0)) } ?? (command == "/break" ? 5 : defaultFocusMinutes)
            guard let minutes else { reject("Use \(command) <minutes>, for example \(command) 25. Choose 1–720 minutes."); return true }
            startTimer(minutes: minutes, title: values.count > 1 ? String(values[1]) : (command == "/break" ? "Break" : "Study block"), isBreak: command == "/break")
        case "/pause": pauseTimer()
        case "/resume": resumeTimer()
        case "/stop": stopTimer()
        case "/status":
            let status = timer.map { "\($0.title) · \($0.clockText) remaining · \($0.status.rawValue)" } ?? "No timer running. Try /timer 25."
            let hint = pendingProfileField != nil ? profileAnswerHint
                : "Use /reply <answer>, /skip, or /cancel. Relevant replies answer this question; unrelated chat keeps it open"
            say(status + (pendingPrompt.map { "\n\n\(pendingProfileField != nil ? "Personal" : "Planning") question: \($0)\n\(hint)" } ?? ""))
        case "/sound":
            guard ["on", "off"].contains(argument.lowercased()) else { reject("Use /sound on or /sound off."); return true }
            soundsEnabled = argument.lowercased() == "on"
            say("Alert sounds \(soundsEnabled ? "on" : "off"). Text alerts remain enabled.")
        case "/notifications":
            guard ["on", "off"].contains(argument.lowercased()) else { reject("Use /notifications on or /notifications off."); return true }
            if let notificationAction {
                let enabled = argument.lowercased() == "on"
                if enabled { say("Requested macOS notification permission. The system will report whether banners are enabled.") }
                notificationAction(enabled)
            } else { reject("Run the packaged Kaddo.app to enable macOS banners. Text alerts still work here.") }
        case "/remove": removeItem(argument)
        case "/remind":
            let values = argument.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard values.count == 2, let seconds = parseInterval(String(values[0])) else {
                reject("Use /remind 10m Drink water (s = seconds, m = minutes, h = hours; up to 7 days)."); return true
            }
            let reminder = StudentReminder(title: String(values[1]), date: now().addingTimeInterval(TimeInterval(seconds)))
            data.reminders.append(reminder); save()
            say("I’ll remind you: \(reminder.title) · \(reminder.date.formatted(date: .abbreviated, time: .shortened)). Keep Kaddo running for alerts.", emotion: .happy)
        case "/reminders":
            say(pendingReminders.isEmpty ? "No pending reminders. Try /remind 10m Drink water." : pendingReminders.enumerated().map {
                "\($0.offset + 1). \($0.element.title) · \($0.element.date.formatted(date: .abbreviated, time: .shortened))"
            }.joined(separator: "\n"))
        case "/class": addClass(argument)
        case "/schedule":
            say(scheduledClasses.isEmpty ? "No classes yet. Try /class Mon 09:00 Chemistry." : scheduledClasses.enumerated().map {
                "\($0.offset + 1). \(Calendar.current.shortWeekdaySymbols[$0.element.weekday - 1]) \($0.element.time) · \($0.element.title)"
            }.joined(separator: "\n"))
        case "/note":
            guard !argument.isEmpty else { reject("Use /note followed by something you want to remember."); return true }
            data.notes.append(StudentNote(text: argument)); save(); say("Note saved. Read it with /notes.", emotion: .happy)
        case "/notes":
            say(data.notes.isEmpty ? "No quick notes yet. Try /note Ask tutor about chapter 4." : data.notes.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n"))
        case "/card":
            let sides = argument.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard sides.count == 2, sides.allSatisfy({ !$0.isEmpty }) else {
                reject("Use /card Question | Answer. Then try /quiz."); return true
            }
            data.cards.append(RevisionCard(question: sides[0], answer: sides[1])); save()
            say("Revision card saved. You have \(data.cards.count) card(s). Try /quiz.", emotion: .happy)
        case "/cards":
            say(data.cards.isEmpty ? "No revision cards yet. Try /card Question | Answer." : data.cards.enumerated().map {
                "\($0.offset + 1). \($0.element.question)"
            }.joined(separator: "\n"))
        case "/quiz", "/next":
            guard !data.cards.isEmpty else { reject("Add a revision card first: /card Question | Answer."); return true }
            quizIndex = command == "/quiz" ? 0 : ((quizIndex ?? -1) + 1) % data.cards.count
            answerRevealed = false
            say("Card \(quizIndex! + 1)/\(data.cards.count): \(currentCard!.question)\nThink it through, then /reveal. Use /next to continue.", emotion: .thinking)
        case "/reveal":
            guard let currentCard else { reject("Start a revision round with /quiz."); return true }
            answerRevealed = true; say("\(currentCard.question)\n\n\(currentCard.answer)\n\nUse /next for another card.", emotion: .happy)
        case "/session":
            guard !argument.isEmpty else { reject("Use /session Biology to create a course document folder."); return true }
            newSession?(argument); say("Created the \(argument) document session. Add PDF or Word notes using +.", emotion: .happy)
        default: reject("Unknown command: \(command). Type /help to see available commands. Your planner hasn’t changed.")
        }
        return true
    }

    private func ask(_ question: String) { pendingPrompt = question; say(question + "\nAnswer naturally or use /reply <answer>. /skip skips optional questions; /cancel leaves planning.", emotion: .thinking) }

    private func answerPrompt(_ text: String) {
        switch step {
        case .profile(let field): answerProfile(text, field: field)
        case .dailyTasks:
            if text != "/skip" {
                let titles = text.components(separatedBy: CharacterSet(charactersIn: ";\n"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                guard !titles.isEmpty else { ask("What are your tasks for today? Separate them with semicolons."); return }
                for title in titles {
                    data.tasks.append(StudentTask(title: title, due: Calendar.current.startOfDay(for: now()), minutes: defaultFocusMinutes))
                }
                save()
            }
            step = nil; pendingPrompt = nil
            say(todaySummary() + "\n\nWhich one comes first? Use /focus <task number>, or /new to add details.")
        case .title:
            guard text != "/skip" else { ask("What is the task? A title is needed; use /cancel to leave."); return }
            draft?.title = text; step = .subject
            ask("Which subject or course is this for? Type /skip if it doesn’t need one.")
        case .subject:
            draft?.subject = text == "/skip" ? "" : text; step = .due
            ask("When is it due? Use today, tomorrow, or YYYY-MM-DD. Type /skip for no deadline.")
        case .due:
            if text == "/skip" { draft?.due = nil }
            else if let date = parseDate(text) { draft?.due = date }
            else { operationFailure = "Invalid deadline."; ask("I couldn’t read that date. Use today, tomorrow, or YYYY-MM-DD, or /skip."); return }
            step = .minutes; ask("How many minutes would you like to work on it? Choose 1–720, or /skip for \(defaultFocusMinutes).")
        case .minutes:
            guard let minutes = text == "/skip" ? defaultFocusMinutes : parseMinutes(text) else {
                operationFailure = "Invalid focus duration."
                ask("Choose a whole number from 1–720 minutes, or /skip for \(defaultFocusMinutes)."); return
            }
            guard var task = draft else { return }
            task.minutes = minutes; data.tasks.append(task); save()
            draft = nil; step = nil; pendingPrompt = nil
            say("nice, one thing lined up Added: \(task.title) · \(minutes) min. Ready to begin? Use /focus \(data.tasks.count).", emotion: .happy)
        case nil: break
        }
    }

    private func parseMinutes(_ text: String) -> Int? {
        let value = text.lowercased().hasSuffix("m") ? String(text.dropLast()) : text
        guard let minutes = Int(value), (1...720).contains(minutes) else { return nil }
        return minutes
    }

    private func parseInterval(_ text: String) -> Int? {
        let multipliers: [Character: Int] = ["s": 1, "m": 60, "h": 3600]
        guard let suffix = text.lowercased().last, let multiplier = multipliers[suffix],
              let value = Int(text.dropLast()), value > 0, value <= 604800 / multiplier else { return nil }
        return value * multiplier
    }

    private func parseDate(_ text: String) -> Date? {
        let calendar = Calendar.current
        if text.lowercased() == "today" { return calendar.startOfDay(for: now()) }
        if text.lowercased() == "tomorrow" { return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now())) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    private func addClass(_ argument: String) {
        let parts = argument.split(maxSplits: 2, whereSeparator: \.isWhitespace).map(String.init)
        let weekdays = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
        guard parts.count == 3, let weekday = weekdays[String(parts[0].lowercased().prefix(3))] else {
            reject("Use /class Mon 09:00 Chemistry · Room 12 (24-hour time)."); return
        }
        let time = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard time.count == 2, time[0].count == 2, time[1].count == 2,
              let hour = Int(time[0]), let minute = Int(time[1]), (0...23).contains(hour), (0...59).contains(minute) else {
            reject("Use a 24-hour class time such as 09:00 or 14:30."); return
        }
        data.classes.append(StudentClass(title: parts[2], weekday: weekday, time: parts[1])); save()
        say("Class saved: \(parts[0]) \(parts[1]) · \(parts[2]). Check /schedule.", emotion: .happy)
    }

    private func removeItem(_ argument: String) {
        let parts = argument.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let number = Int(parts[1]), number > 0 else {
            reject("Use /remove task 1, /remove class 1, /remove note 1, /remove card 1, or /remove reminder 1. List that collection first to see its numbers."); return
        }
        let index = number - 1
        switch parts[0].lowercased() {
        case "task" where data.tasks.indices.contains(index): removeTask(data.tasks[index].id)
        case "class" where scheduledClasses.indices.contains(index): removeClass(scheduledClasses[index].id)
        case "note" where data.notes.indices.contains(index): removeNote(data.notes[index].id)
        case "card" where data.cards.indices.contains(index): removeCard(data.cards[index].id)
        case "reminder" where pendingReminders.indices.contains(index): removeReminder(pendingReminders[index].id)
        default: reject("That item number wasn’t found. Check /tasks, /schedule, /notes, /cards, or /reminders."); return
        }
        say("Removed \(parts[0]) \(number).")
    }

    private var scheduledClasses: [StudentClass] {
        data.classes.sorted { ($0.weekday, $0.time, $0.title) < ($1.weekday, $1.time, $1.title) }
    }

    private var pendingReminders: [StudentReminder] {
        data.reminders.filter { !$0.delivered }.sorted { $0.date < $1.date }
    }
}
