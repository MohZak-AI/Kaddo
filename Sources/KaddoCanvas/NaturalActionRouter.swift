import Foundation

/// Only complete, explicit requests execute offline. Everything else uses contextual AI.
@MainActor
enum NaturalActionRouter {
    static func command(for input: String, state: PetApplicationState) -> String? {
        if let command = SessionNavigation.command(input) { return command }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = #"^(?:(?:please|can you|could you|i want to|i need to)\s+)?"#
        func capture(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
        if let values = capture(prefix + #"(?:make (?:that|it)|change (?:that|it|the timer) to) (\d+) (?:minutes?|mins?)[.!?]?$"#) {
            return "/resize_timer " + values[0]
        }
        if state.student.isLocalInputPending {
            if capture(prefix + #"(?:skip|skip this|skip this question)[.!?]?$"#) != nil { return "/skip" }
            if capture(prefix + #"(?:cancel|never mind|nevermind|not now|maybe later)[.!?]?$"#) != nil { return "/cancel" }
        }
        // Preserve explicit titles as data before looking for actions inside them.
        let writes: [(String, String)] = [
            (#"(?:add|create|save|make) (?:a )?task(?: called| titled)?\s+(.+)$"#, "/task"),
            (#"(?:add|save|write) (?:a )?(?:quick )?note(?: called| saying)?\s+(.+)$"#, "/note"),
            (#"(?:create|add) (?:a )?(?:new )?(?:session|folder)(?: called| named)?\s+(.+)$"#, "/session")
        ]
        for (pattern, command) in writes {
            if let values = capture(prefix + pattern),
               !values[0].lowercased().contains(" and "), !values[0].lowercased().contains(" then ") {
                return command + " " + values[0]
            }
        }
        if let v = capture(prefix + #"(?:start|set) (?:a |the |my )?(?:(\d+)[ -]*(?:minutes?|mins?)[ -]*)?(?:study )?(?:timer|countdown|study block)(?: for (\d+) (?:minutes?|mins?))?[.!?]?$"#) {
            guard v.filter({ !$0.isEmpty }).count <= 1 else { return nil }
            return "/timer" + (v.first(where: { !$0.isEmpty }).map { " " + $0 } ?? "")
        }
        if let v = capture(prefix + #"(?:start|take|set) (?:a |the |my )?(?:(\d+)[ -]*(?:minutes?|mins?)[ -]*)?break[.!?]?$"#) {
            return "/break" + (v[0].isEmpty ? "" : " " + v[0])
        }
        if let v = capture(prefix + #"(pause|resume|stop)(?: (?:my |the )?(?:timer|countdown)| it)?[.!?]?$"#) {
            return "/" + v[0].lowercased()
        }
        if let v = capture(prefix + #"remind me in (\d+)\s*(seconds?|minutes?|hours?|[smh]) to (.+)$"#),
           !v[2].lowercased().contains(" and ") {
            let unit = v[1].lowercased().hasPrefix("h") ? "h" : v[1].lowercased().hasPrefix("m") ? "m" : "s"
            return "/remind \(v[0])\(unit) \(v[2])"
        }
        if let v = capture(prefix + #"(?:focus on|work on|start focusing on) task (\d+)[.!?]?$"#) { return "/focus " + v[0] }
        if let v = capture(prefix + #"mark task (\d+) (?:done|complete|completed)[.!?]?$"#) { return "/done " + v[0] }
        if let v = capture(prefix + #"(?:remove|delete) (task|class|note|card|reminder) (\d+)[.!?]?$"#) {
            return "/remove " + v[0].lowercased() + " " + v[1]
        }
        if let v = capture(prefix + #"(?:add|save|create) (?:an? )?(assignment|exam) (.+?) (?:due|on) (today|tomorrow|\d{4}-\d{2}-\d{2})[.!?]?$"#) {
            return "/\(v[0].lowercased()) \(v[2]) \(v[1])"
        }
        if let v = capture(prefix + #"(?:add|save|create) (?:a )?class (Mon\w*|Tue\w*|Wed\w*|Thu\w*|Fri\w*|Sat\w*|Sun\w*) (\d{2}:\d{2}) (.+)$"#) {
            return "/class \(v[0].prefix(3)) \(v[1]) \(v[2])"
        }
        if let v = capture(prefix + #"(?:add|save|create|make) (?:a )?(?:revision card|flashcard) (.+\|.+)$"#) {
            return "/card " + v[0]
        }
        let reads = ["tasks": "tasks", "my tasks": "tasks", "my tasks today": "tasks", "notes": "notes", "my notes": "notes", "cards": "cards", "my flashcards": "cards", "reminders": "reminders", "my reminders": "reminders", "my class schedule": "schedule", "my schedule": "schedule", "my profile": "profile", "timer status": "status"]
        if let v = capture(prefix + #"(?:show|list|read|check) (.+?)[.!?]?$"#), let command = reads[v[0].lowercased()] { return "/" + command }
        if capture(prefix + #"(?:plan|organize) (?:my )?(?:day|today)[.!?]?$"#) != nil { return "/plan" }
        if capture(prefix + #"(?:forget|clear) (?:our |my |the )?(?:chat|conversation|chat history)[.!?]?$"#) != nil { return "/forget" }
        if let v = capture(prefix + #"(?:turn|set) (sounds?|notifications) (on|off)[.!?]?$"#) {
            return "/\(v[0].lowercased().hasPrefix("sound") ? "sound" : "notifications") \(v[1].lowercased())"
        }
        if capture(prefix + #"(?:summarize|summarise) (?:my |the |this )?(?:document|documents|pdf|uploaded notes)[.!?]?$"#) != nil { return "/ask " + text }
        if capture(prefix + #"(?:save|add|write) (?:a )?(?:quick )?note[.!?]?$"#) != nil { return "/note" }
        if capture(prefix + #"(?:create|add|make) (?:a )?task[.!?]?$"#) != nil { return "/task" }
        if capture(prefix + #"(?:create|add) (?:a )?(?:new )?session[.!?]?$"#) != nil { return "/session" }
        if capture(prefix + #"(?:remind me|(?:add|set) (?:a )?reminder)[.!?]?$"#) != nil { return "/remind" }
        if capture(prefix + #"(?:make|create|add) (?:a )?flashcard[.!?]?$"#) != nil { return "/card" }
        if capture(prefix + #"(?:focus on|work on) (?:a |my )?task[.!?]?$"#) != nil { return "/focus" }
        return nil
    }

    static func looksLikeStatement(_ input: String) -> Bool {
        input.lowercased().range(of: #"\b(hello|hi|hey|thanks|tired|stressed|nice|cool|okay|ok|yes|no|sure|great|how|what|why|tell|explain|i feel|i am feeling|i don.t|don.t|do not|never)\b"#, options: .regularExpression) == nil
    }

    static func looksLikeGuidedAnswer(_ input: String, planner: StudentPlanner) -> Bool {
        guard planner.isLocalInputPending, input.count <= 200, !input.contains("?"), !input.contains("؟"), looksLikeStatement(input) else { return false }
        let text = input.lowercased()
        if let field = planner.pendingProfileField {
            switch field {
            case .name:
                return text.hasPrefix("my name is ") || text.hasPrefix("call me ")
                    || (input.split(whereSeparator: \.isWhitespace).count == 1 && !text.hasPrefix("i "))
            case .birthday: return UserBirthday.parse(input) != nil
            case .focus: return text.range(of: #"^\d+\s*(?:m|mins?|minutes?)?$"#, options: .regularExpression) != nil
            default: return false
            }
        }
        // Only structured task answers can be recognized without understanding freeform intent.
        let question = planner.pendingPrompt ?? ""
        if question.hasPrefix("When is it due?") {
            return ["today", "tomorrow"].contains(text) || text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        }
        if question.hasPrefix("How many minutes") { return Int(text) != nil }
        return false
    }
}
