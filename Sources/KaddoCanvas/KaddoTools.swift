import Foundation

public enum KaddoToolName: String, CaseIterable, Codable, Sendable {
    case new, plan, reply, ask, forget, profile, today, planner, task, assignment, exam, tasks
    case done, focus, timer, `break`, pause, resume, stop, status, sound, notifications, remove
    case remind, reminders, `class`, schedule, note, notes, card, cards, quiz, reveal, next, session
    case search_knowledge, save_knowledge, update_knowledge, delete_knowledge
    case organize_knowledge, summarize_session
    case read_url, list_source_files, read_source_file, read_source
    case skip, cancel, help, read_state, resize_timer, select_session, add_document
}

public struct KaddoToolArguments: Codable, Equatable, Sendable {
    public var url: String?
    public var path: String?
    public var title: String?
    public var category: String?
    public var text: String?
    public var minutes: Int?
    public var id: UUID?
    public var collection: String?
    public var date: String?
    public var seconds: Int?
    public var day: String?
    public var time: String?
    public var answer: String?
    public var enabled: Bool?

    public init(text: String? = nil, minutes: Int? = nil, id: UUID? = nil, collection: String? = nil,
                date: String? = nil, seconds: Int? = nil, day: String? = nil, time: String? = nil,
                answer: String? = nil, enabled: Bool? = nil, title: String? = nil, category: String? = nil, url: String? = nil, path: String? = nil) {
        self.url = url; self.path = path
        self.title = title; self.category = category
        self.text = text; self.minutes = minutes; self.id = id; self.collection = collection
        self.date = date; self.seconds = seconds; self.day = day; self.time = time
        self.answer = answer; self.enabled = enabled
    }
}

public struct KaddoToolCall: Equatable, Sendable {
    public let id: String
    public let name: KaddoToolName
    public let arguments: KaddoToolArguments

    public init(id: String = UUID().uuidString, name: KaddoToolName, arguments: KaddoToolArguments = .init()) {
        self.id = id; self.name = name; self.arguments = arguments
    }

    public init(id: String, name: String, arguments: AssistantJSON) throws {
        guard let name = KaddoToolName(rawValue: name), let object = arguments.object,
              let definition = KaddoToolCatalog.definitions.first(where: { $0.name == name }),
              Set(object.keys).isSubset(of: Set(definition.fields.keys)) else { throw AssistantError.invalidResponse }
        for (key, value) in object where value != .null {
            switch definition.fields[key] {
            case "integer":
                guard case .number(let n) = value, n.isFinite, n.rounded() == n else { throw AssistantError.invalidResponse }
            case "boolean": guard case .bool = value else { throw AssistantError.invalidResponse }
            default:
                guard let string = value.string, string.count <= 2_000 else { throw AssistantError.invalidResponse }
            }
        }
        guard let decoded = try? JSONDecoder().decode(KaddoToolArguments.self, from: JSONEncoder().encode(arguments)) else {
            throw AssistantError.invalidResponse
        }
        self.init(id: id, name: name, arguments: decoded)
    }

    var isReadOnly: Bool {
        switch name {
        case .read_url, .list_source_files, .read_source_file, .read_source, .search_knowledge, .read_state, .today, .planner, .tasks, .status, .reminders, .schedule, .notes, .cards, .help, .ask: true
        case .profile: arguments.text == nil || arguments.text?.isEmpty == true
        default: false
        }
    }

    var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return name.rawValue + ":" + String(decoding: (try? encoder.encode(arguments)) ?? Data(), as: UTF8.self)
    }
}

public struct KaddoToolResult: Encodable, Sendable {
    public enum Status: String, Encodable, Sendable { case success, failure, needsInput }
    public let status: Status
    public let message: String
    public var data: AssistantJSON?
    public init(_ status: Status, _ message: String, data: AssistantJSON? = nil) {
        self.status = status; self.message = message; self.data = data
    }
}

public enum KaddoToolCatalog {
    struct Definition: Sendable {
        let name: KaddoToolName
        let description: String
        let fields: [String: String]
        init(_ name: KaddoToolName, _ description: String, _ fields: [String: String] = [:]) {
            self.name = name; self.description = description; self.fields = fields
        }
    }
    static let definitions: [Definition] = [
        .init(.read_source, "Answer from an approved source by id. A folder reads up to five supported files; a web source reads its saved URL. Results display separately. text is the question.", ["id": "string", "text": "string"]),
        .init(.read_url, "Read a public HTTPS link and display a separate grounded answer. Supply the user's question in text. Page contents never enter this conversation.", ["url": "string", "text": "string"]),
        .init(.list_source_files, "Show/search supported files in an approved folder by source id. Results are displayed separately. text optionally filters filenames.", ["id": "string", "text": "string"]),
        .init(.read_source_file, "Read a relative file in an approved folder and display a separate grounded answer. path must remain inside the folder. text is the question.", ["id": "string", "path": "string", "text": "string"]),
        .init(.search_knowledge, "Answer a question from saved knowledge using a separate grounded answer. No excerpts are returned to this conversation. Optional category is an exact category name; default is chat filter.", ["text": "string", "category": "string"]),
        .init(.organize_knowledge, "Organize a saved file or note by stable id into the best fitting category. May create a category. Session ownership is preserved when moving a file. Read knowledge metadata first.", ["id": "string", "category": "string"]),
        .init(.summarize_session, "Summarize the selected session (or supplied session id) into General knowledge. Uses retained session conversation and uploaded file excerpts, and replaces its previous summary. No summary text is returned to the action loop.", ["id": "string"]),
        .init(.save_knowledge, "Save a knowledge note ONLY on the user's explicit request to remember or save. category must be an existing exact category name; clarify if ambiguous.", ["title": "string", "text": "string", "category": "string"]),
        .init(.update_knowledge, "Edit an existing manual knowledge note ONLY on explicit request with its known stable id. Never edit managed planner/profile records.", ["id": "string", "title": "string", "text": "string"]),
        .init(.delete_knowledge, "Delete a manual or imported knowledge item ONLY on explicit request with a known stable id. Managed records must be edited at their source.", ["id": "string"]),
        .init(.new, "Start guided task setup. Optional text is the task title.", ["text": "string"]),
        .init(.plan, "Start guided planning for today."),
        .init(.reply, "Answer the pending planning or profile question ONLY when the message answers it. Normalize dates to YYYY-MM-DD and durations to minutes. Never treat unrelated chat as an answer.", ["text": "string"]),
        .init(.ask, "Answer a question using imported documents in the selected session. Use ONLY when the user refers to document content. Prefer this last in mixed requests.", ["text": "string"]),
        .init(.forget, "Clear chat memory and unresolved assistant clarifications, preserving planner data."),
        .init(.profile, "Read profile, edit a field, continue questions, or clear. text: null, edit name|birthday|subjects|goal|interests|focus, continue, or clear.", ["text": "string"]),
        .init(.today, "Read today's tasks and classes."), .init(.planner, "Read student overview."),
        .init(.task, "Save a task for today with text as its title.", ["text": "string"]),
        .init(.assignment, "Save an assignment deadline. date is today, tomorrow, or YYYY-MM-DD.", ["text": "string", "date": "string"]),
        .init(.exam, "Save an exam deadline. date is today, tomorrow, or YYYY-MM-DD.", ["text": "string", "date": "string"]),
        .init(.tasks, "Read tasks."),
        .init(.done, "Complete a task by stable id; read_state tasks first if needed.", ["id": "string"]),
        .init(.focus, "Start the saved timer for a task by stable id.", ["id": "string"]),
        .init(.timer, "Start study countdown, 1–720 minutes. null minutes uses preferred duration. text is optional title.", ["minutes": "integer", "text": "string"]),
        .init(.break, "Start break countdown, 1–720 minutes; null uses 5.", ["minutes": "integer"]),
        .init(.pause, "Pause the running countdown."), .init(.resume, "Resume the paused countdown."),
        .init(.stop, "Stop the active countdown."), .init(.status, "Read timer and pending question."),
        .init(.sound, "Set alert sounds.", ["enabled": "boolean"]),
        .init(.notifications, "Set macOS notifications. Enabling invokes normal system permission.", ["enabled": "boolean"]),
        .init(.remove, "Remove one item by stable id. collection: tasks, classes, notes, cards, or reminders. Read the collection first; clarify ambiguous targets.", ["collection": "string", "id": "string"]),
        .init(.remind, "Save reminder in 1–604800 seconds with text as its message.", ["seconds": "integer", "text": "string"]),
        .init(.reminders, "Read pending reminders."),
        .init(.class, "Save weekly class. day: Mon–Sun, time: HH:MM 24 hour, text: title.", ["day": "string", "time": "string", "text": "string"]),
        .init(.schedule, "Read weekly timetable."),
        .init(.note, "Save a quick note only when asked to save one.", ["text": "string"]), .init(.notes, "Read quick notes."),
        .init(.card, "Save revision flashcard. text is question, answer is answer.", ["text": "string", "answer": "string"]),
        .init(.cards, "Read revision cards."), .init(.quiz, "Begin revision quiz."),
        .init(.reveal, "Reveal current revision answer."), .init(.next, "Show next revision question."),
        .init(.session, "Create and select a new document session with text as title.", ["text": "string"]),
        .init(.skip, "Skip pending optional question."), .init(.cancel, "Cancel guided planning or pending profile question."),
        .init(.help, "Read all supported Kaddo features."),
        .init(.read_state, "Read relevant data with stable ids. collection: tasks, classes, notes, cards, reminders, profile, sessions, timer, or knowledge (metadata only, no excerpts). Fetch only what the request needs.", ["collection": "string"]),
        .init(.resize_timer, "Replace the current countdown with a new full duration, preserving paused state. Only on an explicit change request.", ["minutes": "integer"]),
        .init(.select_session, "Select an existing document session by stable UUID id or exact title. Put human-readable session names in title, never id. With neither, ask which session to open.", ["id": "string", "title": "string", "text": "string"]),
        .init(.add_document, "Open the native document picker for the user to choose a PDF, DOCX, TXT or Markdown file.")
    ]
    static var schemas: [AssistantJSON] { schemas(for: nil) }
    static func schemas(for allowed: Set<KaddoToolName>?) -> [AssistantJSON] {
        definitions.filter { allowed?.contains($0.name) ?? true }.map { definition in
            let properties = definition.fields.mapValues { type in
                AssistantJSON.object(["type": .array([.string(type), .string("null")])])
            }
            return .object([
                "type": .string("function"), "name": .string(definition.name.rawValue),
                "description": .string(definition.description), "strict": .bool(true),
                "parameters": .object(["type": .string("object"), "properties": .object(properties),
                    "required": .array(definition.fields.keys.sorted().map(AssistantJSON.string)),
                    "additionalProperties": .bool(false)])
            ])
        }
    }
}

/// Uses the same validated operations as slash commands. No generated shell or command execution.
@MainActor
final class KaddoToolExecutor {
    let state: PetApplicationState
    var openDocument: (() -> Void)?
    init(state: PetApplicationState) { self.state = state }

    func execute(_ call: KaddoToolCall) -> KaddoToolResult {
        let a = call.arguments
        let student = state.student
        if call.name == .read_state {
            guard let collection = a.collection else { return .init(.needsInput, "Which collection should I read?") }
            do { return .init(.success, "Current \(collection)", data: try read(collection)) }
            catch { return .init(.failure, "Unknown collection. Choose tasks, classes, notes, cards, reminders, profile, sessions, or timer.") }
        }
        if call.name == .resize_timer {
            guard let minutes = a.minutes else { return .init(.needsInput, "How many minutes should the timer be?") }
            return student.performOperation { student.resizeTimer(minutes: minutes) }
        }
        if call.name == .select_session {
            let id: UUID
            if let supplied = a.id {
                guard state.sessionFolders[supplied] != nil else { return .init(.needsInput, SessionNavigation.choices(state, prefix: "That session no longer exists. Which session should I open?")) }
                id = supplied
            } else if let title = a.title ?? a.text, !SessionNavigation.clean(title).isEmpty {
                let matches = SessionNavigation.matching(title, state: state)
                guard matches.count == 1 else {
                    return .init(.needsInput, SessionNavigation.choices(state, prefix: matches.isEmpty
                        ? "I couldn’t find a session named \(SessionNavigation.clean(title)). Which session should I open?"
                        : "More than one session has that name. Which one should I open?"))
                }
                id = matches[0].id
            } else {
                return .init(.needsInput, SessionNavigation.choices(state))
            }
            let wasActive = id == state.activeSessionID
            guard state.selectSession(id: id) else { return .init(.failure, "That document session no longer exists.") }
            return .init(.success, wasActive ? "You’re already in \(state.sessionFolders[id]!.title)." : "Switched to \(state.sessionFolders[id]!.title).")
        }
        if call.name == .add_document {
            guard let openDocument else { return .init(.failure, "Open + → Add document to choose a PDF, DOCX, TXT or Markdown file.") }
            openDocument()
            return .init(.success, "Document picker opened. The user must choose a file; no file has been imported yet.")
        }
        let argument: String
        switch call.name {
        case .new, .profile: argument = a.text ?? ""
        case .task, .note, .session, .reply, .ask:
            guard let text = nonempty(a.text) else { return .init(.needsInput, question(for: call.name)) }
            argument = text
        case .assignment, .exam:
            guard let title = nonempty(a.text), let date = nonempty(a.date) else {
                return .init(.needsInput, "What is the title and deadline?")
            }
            argument = date + " " + title
        case .timer, .break:
            if let minutes = a.minutes, !(1...720).contains(minutes) { return .init(.failure, "Choose 1–720 minutes.") }
            argument = String(a.minutes ?? (call.name == .break ? 5 : student.defaultFocusMinutes))
                + (nonempty(a.text).map { " " + $0 } ?? "")
        case .done, .focus:
            guard let id = a.id, let index = student.tasks.firstIndex(where: { $0.id == id }) else {
                return .init(.needsInput, call.name == .focus ? "Which task would you like to work on? Tell me its name or number." : "Which task would you like to mark complete? Tell me its name or number.")
            }
            argument = String(index + 1)
        case .remove:
            guard let collection = a.collection, let id = a.id,
                  let index = ids(for: collection)?.firstIndex(of: id) else {
                return .init(.needsInput, "Which item should I remove? Tell me its name or number.")
            }
            let singular = ["tasks": "task", "classes": "class", "notes": "note", "cards": "card", "reminders": "reminder"]
            argument = "\(singular[collection]!) \(index + 1)"
        case .remind:
            guard let seconds = a.seconds, (1...604_800).contains(seconds), let text = nonempty(a.text) else {
                return .init(.needsInput, "When should I remind you, and what should the reminder say? Use a delay up to seven days.")
            }
            argument = "\(seconds)s \(text)"
        case .class:
            guard let day = nonempty(a.day), let time = nonempty(a.time), let text = nonempty(a.text) else {
                return .init(.needsInput, "What day, time, and title should the class have?")
            }
            argument = "\(day) \(time) \(text)"
        case .card:
            guard let text = nonempty(a.text), let answer = nonempty(a.answer) else {
                return .init(.needsInput, "What question and answer should I put on the flashcard?")
            }
            // The legacy shortcut uses a pipe separator; preserve typed card contents directly.
            return student.performOperation { student.addRevisionCard(question: text, answer: answer) }
        case .sound, .notifications:
            guard let enabled = a.enabled else { return .init(.needsInput, "Would you like it on or off?") }
            argument = enabled ? "on" : "off"
        default: argument = ""
        }
        guard argument.count <= 1_950 else { return .init(.failure, "Keep action details under 1,950 characters.") }
        return student.performCommand("/" + call.name.rawValue + (argument.isEmpty ? "" : " " + argument))
    }

    private func nonempty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
    private func question(for name: KaddoToolName) -> String {
        switch name {
        case .task: "What task should I add?"
        case .note: "What would you like me to save in the note?"
        case .session: "What should I call the document session?"
        case .ask: "What would you like to know from your documents?"
        default: "What is your answer to the current question?"
        }
    }
    private func ids(for collection: String) -> [UUID]? {
        switch collection {
        case "tasks": state.student.tasks.map(\.id)
        case "classes": state.student.classes.sorted { ($0.weekday, $0.time, $0.title) < ($1.weekday, $1.time, $1.title) }.map(\.id)
        case "notes": state.student.notes.map(\.id)
        case "cards": state.student.cards.map(\.id)
        case "reminders": state.student.reminders.filter { !$0.delivered }.sorted { $0.date < $1.date }.map(\.id)
        default: nil
        }
    }
    private func read(_ collection: String) throws -> AssistantJSON {
        switch collection {
        case "knowledge": .array(state.knowledge.items.map { item in .object([
            "id": .string(item.id.uuidString), "title": .string(item.title),
            "category": .string(state.knowledge.categories.first(where: { category in category.id == item.categoryID })?.name ?? ""),
            "kind": .string(item.sourceKind), "managed": .bool(item.sourceKey.hasPrefix("sync:"))]) })
        case "tasks": try .encode(state.student.tasks)
        case "classes": try .encode(state.student.classes.sorted { ($0.weekday, $0.time, $0.title) < ($1.weekday, $1.time, $1.title) })
        case "notes": try .encode(state.student.notes)
        case "cards": try .encode(state.student.cards)
        case "reminders": try .encode(state.student.reminders.filter { !$0.delivered }.sorted { $0.date < $1.date })
        case "profile": try .encode(state.student.profile?.snapshot)
        case "sessions": .array(state.sessionFolders.values.sorted { $0.title < $1.title }.map {
            .object(["id": .string($0.id.uuidString), "title": .string($0.title), "selected": .bool($0.id == state.activeSessionID)])
        })
        case "timer": .object(["title": state.student.timer.map { .string($0.title) } ?? .null,
            "remainingSeconds": state.student.timer.map { .number(Double($0.remaining)) } ?? .null,
            "status": state.student.timer.map { .string($0.status.rawValue) } ?? .null])
        default: throw AssistantError.invalidResponse
        }
    }
}
