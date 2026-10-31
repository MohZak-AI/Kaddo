import SwiftUI

/// Observes goal completion independently of any goal-session window.
public struct FloatingPetWindowView: View {
    @ObservedObject private var model: PetApplicationState
    @State private var previousSecondsRemaining = 0
    private let dragController: WindowDragController
    private let onAskNotes: @MainActor () -> Void
    private let presentation: PetChatPresentationState
    private let preferences: CompanionPreferences
    private let animationsEnabled: Bool

    public init(model: PetApplicationState, dragController: WindowDragController,
                presentation: PetChatPresentationState = PetChatPresentationState(),
                preferences: CompanionPreferences = CompanionPreferences(),
                animationsEnabled: Bool = true,
                onAskNotes: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.dragController = dragController
        self.onAskNotes = onAskNotes
        self.presentation = presentation
        self.preferences = preferences
        self.animationsEnabled = animationsEnabled
    }

    public var body: some View {
        PetCanvasView(model: model, dragController: dragController, presentation: presentation,
                      preferences: preferences, animationsEnabled: animationsEnabled, onAskNotes: onAskNotes)
            .onReceive(model.$goalTimerSecondsRemaining) { secondsRemaining in
                let previous = previousSecondsRemaining
                previousSecondsRemaining = secondsRemaining
                // Ignore the initial zero and repeated zero publications.
                guard previous > 0, secondsRemaining == 0, !model.goalTimerIsStudentManaged else { return }
                model.currentEmotion = .celebrating
                model.speechBubbleText =
                    "Time's up! Goal complete? Let's check the files if you're stuck!"
            }
    }
}
