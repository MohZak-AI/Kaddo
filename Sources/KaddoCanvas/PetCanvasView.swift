import AppKit
import SwiftUI

public struct PetCanvasView: View {
    public static let size = NSSize(width: 360, height: 300)

    @StateObject private var model: PetApplicationState
    @ObservedObject private var presentation: PetChatPresentationState
    @ObservedObject private var activity: PetActivityStore
    @ObservedObject private var preferences: CompanionPreferences
    @ObservedObject private var student: StudentPlanner
    @GestureState private var isDragging = false
    @State private var isBobbing = false
    @State private var tapCount = 0
    @State private var dragDirection: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    private let dragController: WindowDragController
    private let animationsEnabled: Bool
    private let onAskNotes: @MainActor () -> Void

    public init(model: PetApplicationState, dragController: WindowDragController,
                presentation: PetChatPresentationState = PetChatPresentationState(),
                preferences: CompanionPreferences = CompanionPreferences(),
                animationsEnabled: Bool = true,
                onAskNotes: @escaping @MainActor () -> Void = {}) {
        _model = StateObject(wrappedValue: model)
        self.dragController = dragController
        self.presentation = presentation
        self.preferences = preferences
        self.activity = model.activity
        self.student = model.student
        self.animationsEnabled = animationsEnabled
        self.onAskNotes = onAskNotes
    }

    public var body: some View {
        VStack(spacing: 8) {
            PetSpeechView(model: model, presentation: presentation, activity: activity,
                          animationsEnabled: animationsEnabled && presentation.overlayVisible, onOpenChat: onAskNotes)
                .opacity(showsSpeech ? 1 : 0)
                .offset(y: showsSpeech || !motionEnabled ? 0 : PetMotion.replyTravel)
                .allowsHitTesting(showsSpeech)
                .accessibilityHidden(!showsSpeech)
                .animation(PetMotion.visibility(showing: showsSpeech, enabled: motionEnabled),
                           value: showsSpeech)
            // Keep controls inside the layout bounds so SwiftUI can hit-test them.
            HStack(alignment: .top, spacing: 4) {
                windowControls
                companionAnchor
                Color.clear.frame(width: 60, height: 28).allowsHitTesting(false)
            }
                .contextMenu {
                    Button("Show chat", action: onAskNotes)
                    Button("Activity") { presentation.expand(); activity.showsTray = true }
                    Button("Hide companion") { presentation.hideOverlayAction?() }
                    Button(preferences.mode == .mini ? "Flame mode" : "Mini mode") { presentation.miniAction?() }
                    Button("Recover position") { presentation.recoverAction?() }
                    Button("Companion settings…") { presentation.settingsAction?() }
                }
        }
        .frame(width: preferences.canvasSize.width, height: preferences.canvasSize.height, alignment: .bottom)
        .onChange(of: isDragging) { dragging in
            presentation.isDragging = dragging
            if !dragging { dragController.end() }
        }
        .onChange(of: motionEnabled) { enabled in
            if !enabled { isBobbing = false }
        }
        .onDrop(of: DocumentDropTypes.supported, isTargeted: nil) { providers in
            let sessionID = model.activeSessionID
            return DocumentDropHandler.receive(providers, onURL: { url in
                model.ingestion.enqueue([url], sessionID: sessionID)
            }, onFailure: {
                model.student.dismissPersonalQuestion()
                model.speechBubbleText = "Drop a PDF, DOCX, TXT or Markdown file."
            })
        }
    }

    private var motionEnabled: Bool { animationsEnabled && !reducedMotion && presentation.overlayVisible }
    private var windowControls: some View {
        HStack(spacing: 4) {
            CompanionWindowButton(symbol: "xmark", label: "Close companion",
                help: "Hide Kaddo. Restore from the Kaddo menu bar menu. ⌘W") {
                    presentation.hideOverlayAction?()
                }.frame(width: 28, height: 28)
            CompanionWindowButton(
                symbol: preferences.mode == .mini ? "arrow.up.left.and.arrow.down.right" : "minus",
                label: preferences.mode == .mini ? "Restore companion" : "Minimize companion",
                help: preferences.mode == .mini ? "Restore flame mode. ⌘M" : "Minimize to compact mode. ⌘M") {
                    presentation.miniAction?()
                }.frame(width: 28, height: 28)
        }
        .font(.system(size: 11, weight: .semibold))
        .buttonStyle(PetPressButtonStyle())
        .foregroundStyle(.primary)
        .petSurface(.control, in: Capsule())
    }
    private var showsSpeech: Bool { presentation.isExpanded || activity.preview != nil }
    private var underlyingEmotion: PetEmotion {
        if activity.hasRunning { return .thinking }
        if model.isInactive { return .sleeping }
        if let timer = student.timer, timer.status == .paused || (timer.isBreak && timer.status == .running) {
            return .sleeping
        }
        return model.currentEmotion == .celebrating ? .idle : model.currentEmotion
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                presentation.isDragging = true
                dragDirection = value.translation.width < 0 ? -1 : 1
                let pointer = NSEvent.mouseLocation
                dragController.begin(at: pointer)
                dragController.update(to: pointer)
            }
            .onEnded { _ in presentation.isDragging = false; dragController.end() }
    }

    @ViewBuilder private var companionAnchor: some View {
        if preferences.mode == .mini {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").foregroundStyle(PetChatStyle.muted)
                    .help("Drag to move Kaddo").gesture(dragGesture)
                    .accessibilityLabel("Move companion")
                Button(action: onAskNotes) { Image(systemName: "square.and.pencil") }
                    .buttonStyle(PetPressButtonStyle()).accessibilityLabel("Open Kaddo chat")
                CompanionActivityButton(activity: activity, presentation: presentation, usesSurface: false)
            }
            .font(.system(size: 13)).padding(8)
            .frame(width: preferences.anchorSize.width, height: preferences.anchorSize.height)
            .petSurface(.control, in: Capsule())
            .foregroundStyle(.primary)
        } else {
            ZStack(alignment: .bottom) {
                PetSpriteView(emotion: model.currentEmotion == .celebrating ? .celebrating : underlyingEmotion,
                              animationsEnabled: animationsEnabled && presentation.overlayVisible,
                              displaySize: preferences.size, underlyingEmotion: underlyingEmotion,
                              celebrationID: model.celebrationID, celebrationStartedAt: model.celebrationStartedAt)
                    .scaleEffect(motionEnabled && presentation.isHovered && !isDragging ? 1.03 : 1,
                                 anchor: UnitPoint(x: PetAnimationDefinition.flame.anchor.x,
                                                   y: PetAnimationDefinition.flame.anchor.y))
                    .rotationEffect(.degrees(motionEnabled && isDragging ? dragDirection * 4 : 0), anchor: .bottom)
                    .offset(y: motionEnabled && isBobbing ? -3 : 0)
                    .animation(motionEnabled ? .easeOut(duration: 0.15) : nil, value: presentation.isHovered)
                    .animation(motionEnabled ? .easeOut(duration: 0.15) : nil, value: isDragging)
                    .gesture(dragGesture)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onAskNotes() })
                    .simultaneousGesture(TapGesture().onEnded {
                        guard motionEnabled else { return }
                        tapCount += 1
                    })
                    .task(id: tapCount) {
                        guard tapCount > 0, motionEnabled else { return }
                        withAnimation(.easeOut(duration: PetMotion.tapHalfDuration)) { isBobbing = true }
                        do { try await Task.sleep(for: .seconds(PetMotion.tapHalfDuration)) }
                        catch { isBobbing = false; return }
                        withAnimation(.easeIn(duration: PetMotion.tapHalfDuration)) { isBobbing = false }
                    }
                    .help("Hover for chat. Double-click to type. Drag to move.")
                    .accessibilityAction(named: "Open chat") { onAskNotes() }
                    .padding(6)
                Image(systemName: activity.state.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(activity.state.color).frame(width: 20, height: 20)
                    .petSurface(.control, in: Circle())
                    .accessibilityLabel("Kaddo status: \(activity.state.label)")
                    .offset(x: preferences.size / 2 - 4, y: -preferences.size + 12)
                CompanionActivityButton(activity: activity, presentation: presentation)
                    .offset(x: preferences.size / 2 + 28, y: -8)
                if let timer = student.timer, timer.status != .completed {
                    Text(timer.clockText + (timer.status == .paused ? " Ⅱ" : ""))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(6).petSurface(.reply, in: Capsule())
                        .foregroundStyle(PetChatStyle.muted)
                        .accessibilityLabel("Study timer, \(timer.clockText), \(timer.status.rawValue)")
                        .offset(x: -preferences.size / 2 - 26, y: -8)
                }
            }.frame(width: preferences.anchorSize.width, height: preferences.anchorSize.height)
        }
    }

}

private struct PetSpeechView: View {
    @ObservedObject var model: PetApplicationState
    @ObservedObject var presentation: PetChatPresentationState
    @ObservedObject var activity: PetActivityStore
    let animationsEnabled: Bool
    let onOpenChat: @MainActor () -> Void
    @State private var sourcesExpanded = false
    @State private var textMeasurement = PetReplyTextMeasurement()
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    private var snapshot: PetActivityItem? { activity.preview ?? activity.selected }
    private var text: String { snapshot?.message ?? model.speechBubbleText }
    private var sources: [DocumentChunk] { snapshot?.sources ?? presentation.sources }
    private var showsSpeech: Bool { !text.isEmpty && text != "Ready when you are." }

    private var bubbleHeight: CGFloat {
        let textHeight = textMeasurement.height(for: text)
        let sourceHeight: CGFloat = sources.isEmpty ? 0
            : 28 + (sourcesExpanded ? CGFloat(sources.count) * 22 : 0)
        let taskHeight: CGFloat = snapshot == nil && model.activeTask != nil ? 30 : 0
        let retryHeight: CGFloat = snapshot == nil && presentation.retryTitle != nil ? 28 : 0
        let snapshotHeight: CGFloat = snapshot == nil ? 0 : 32
        return min(180, max(44, ceil(textHeight) + sourceHeight + taskHeight + retryHeight + snapshotHeight + 24))
    }

    var body: some View {
        if showsSpeech || model.activeTask != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if showsSpeech {
                        Text(text).font(.system(size: 14))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    if snapshot != nil {
                        HStack {
                            Text(snapshot?.title ?? "").foregroundStyle(PetChatStyle.muted)
                            Spacer()
                            Button("Current answer") { activity.returnToLive(); activity.dismissPreview() }
                        }.font(.system(size: 11))
                    }
                    if snapshot == nil, let task = model.activeTask {
                        Text(task.title).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(PetChatStyle.muted)
                    }
                    if !sources.isEmpty {
                        DisclosureGroup("Sources", isExpanded: Binding(
                            get: { sourcesExpanded },
                            set: { expanded in
                                withAnimation(PetMotion.disclosure(reducedMotion: reducedMotion || !animationsEnabled)) {
                                    sourcesExpanded = expanded
                                }
                            }
                        )) {
                            ForEach(sources) { source in
                                Text("\(source.filename) · \(source.location ?? "block \(source.index + 1)")")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .font(.system(size: 11)).tint(PetChatStyle.muted)
                        .foregroundStyle(PetChatStyle.muted)
                    }
                    if snapshot == nil, let title = presentation.retryTitle {
                        Button(title) { presentation.retryAction?() }
                            .font(.system(size: 11)).buttonStyle(PetPressButtonStyle()).foregroundStyle(.primary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(PetChatStyle.controlFill, in: Capsule())
                    }
                }
                .padding(12)
            }
            .frame(width: PetChatStyle.width, height: bubbleHeight)
            .foregroundStyle(.primary)
            .petSurface(.reply, in: RoundedRectangle(cornerRadius: 16))
            .simultaneousGesture(TapGesture().onEnded {
                if let preview = activity.preview { onOpenChat(); activity.open(preview.id) }
            })
            .onChange(of: sources) { _ in sourcesExpanded = false }
        }
    }
}

/// A scrolling reply stops growing at 180 pt. Once full, appended stream text cannot
/// change its height; avoid laying out the entire accumulated answer on every token.
@MainActor
final class PetReplyTextMeasurement {
    static let maximumHeight: CGFloat = 156
    private var previousText: String?
    private var cachedHeight: CGFloat = 0
    private let measure: (String) -> CGFloat

    init(measure: @escaping (String) -> CGFloat = { text in
        (text as NSString).boundingRect(
            with: NSSize(width: 328, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 14)]).height
    }) {
        self.measure = measure
    }

    func height(for text: String) -> CGFloat {
        guard text != previousText else { return cachedHeight }
        let appendsToFullReply = cachedHeight == Self.maximumHeight
            && previousText.map { text.hasPrefix($0) } == true
        if !appendsToFullReply {
            cachedHeight = text.isEmpty ? 0 : min(Self.maximumHeight, ceil(measure(text)))
        }
        previousText = text
        return cachedHeight
    }
}
