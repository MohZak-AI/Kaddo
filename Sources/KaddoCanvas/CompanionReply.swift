import Foundation

public struct CompanionReply: Equatable, Sendable {
    public let text: String
    public let emotion: PetEmotion
    public init(text: String, emotion: PetEmotion = .idle) {
        self.text = text; self.emotion = emotion
    }
}
