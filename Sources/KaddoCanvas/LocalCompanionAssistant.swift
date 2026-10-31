import Combine
import Foundation

/// Conversation receives only a personal-details snapshot, never student tools or document data.
@MainActor
public final class LocalCompanionAssistant: ObservableObject {
    public let conversation: any ConversationStore
    var onReply: ((CompanionReply) -> Void)?
    var onExchange: ((ConversationExchange) -> Void)?
    private let profile: () -> UserProfileSnapshot?

    public init(conversation: any ConversationStore = InMemoryConversationStore(),
                profile: @escaping () -> UserProfileSnapshot? = { nil }) {
        self.conversation = conversation
        self.profile = profile
    }

    /// Runs before inference so greetings, support and milestones remain available offline.
    @discardableResult
    public func respondLocally(to input: String) -> Bool {
        guard !input.isEmpty, input.count <= 2_000 else { return false }
        let normalized = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines
            .union(.punctuationCharacters))
        let reply: CompanionReply
        let name = profile()?.name.map { ", \($0)" } ?? ""
        switch normalized {
        case "مرحبا", "مرحباً", "أهلا", "اهلا", "السلام عليكم":
            reply = CompanionReply(text: "أهلًا\(name)! كيف يومك؟", emotion: .happy)
        case "شكرا", "شكرًا", "شكراً":
            reply = CompanionReply(text: "على الرحب والسعة.", emotion: .happy)
        case "hi", "hello", "hey", "hiya", "yo", "heya", "hi kaddo", "hey kaddo", "hello kaddo", "good morning", "good evening":
            reply = CompanionReply(text: "Hey\(name), how’s your day going?", emotion: .happy)
        case "thanks", "thank you", "ty", "thx", "thanks kaddo", "thank you kaddo":
            reply = CompanionReply(text: "You’re welcome.", emotion: .happy)
        case "bye", "goodbye", "see you", "see ya", "good night", "goodnight":
            reply = CompanionReply(text: "See you later. Take care!", emotion: .happy)
        case "how are you", "how are you doing", "how's it going", "how’s it going", "what's up", "what’s up", "you okay":
            reply = CompanionReply(text: "I’m here and ready to help. How are you doing?", emotion: .happy)
        case "i'm tired", "i’m tired", "i am tired", "i'm stressed", "i’m stressed", "i am stressed", "i feel overwhelmed":
            reply = CompanionReply(text: "That sounds like a lot. We can take it one step at a time.")
        case "i did it", "i finished", "i passed", "i passed my exam":
            reply = CompanionReply(text: "Well done! That’s worth celebrating.", emotion: .celebrating)
        default: return false
        }
        publish(reply, user: input)
        return true
    }

    public func forget() { conversation.clear() }

    private func publish(_ reply: CompanionReply, user: String) {
        conversation.append(ConversationExchange(user: user, companion: reply.text))
        onExchange?(ConversationExchange(user: user, companion: reply.text))
        onReply?(reply)
    }

}
