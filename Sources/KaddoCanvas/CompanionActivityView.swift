import SwiftUI

extension PetActivityState {
    var symbol: String {
        switch self {
        case .idle: "circle"
        case .running: "ellipsis"
        case .needsInput: "questionmark"
        case .ready: "checkmark"
        case .blocked: "exclamationmark"
        }
    }
    var color: Color {
        switch self {
        case .idle: PetChatStyle.muted
        case .running: .cyan
        case .needsInput: .yellow
        case .ready: .green
        case .blocked: .orange
        }
    }
}

struct CompanionActivityButton: View {
    @ObservedObject var activity: PetActivityStore
    @ObservedObject var presentation: PetChatPresentationState
    var usesSurface = true

    var body: some View {
        Button {
            presentation.expand()
            activity.showsTray.toggle()
        } label: {
            if usesSurface {
                activityLabel.petSurface(.control, in: Capsule(), interactive: true)
            } else {
                activityLabel
            }
        }
        .buttonStyle(PetPressButtonStyle())
        .accessibilityLabel("Activity, \(activity.unreadCount) unread. \(activity.state.label)")
        .help("Activity · \(activity.state.label)")
        .popover(isPresented: $activity.showsTray, arrowEdge: .top) {
            CompanionActivityTray(activity: activity, presentation: presentation)
        }
    }

    private var activityLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "bell")
            if activity.unreadCount > 0 { Text("\(activity.unreadCount)").monospacedDigit() }
        }
        .font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
        .padding(8)
        .foregroundStyle(.primary)
    }
}

private struct CompanionActivityTray: View {
    @ObservedObject var activity: PetActivityStore
    @ObservedObject var presentation: PetChatPresentationState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { activity.showsTray = false } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close activity")
            }
            if activity.items.isEmpty {
                Text("Your answers and study updates will appear here.")
                    .font(.system(size: 13)).foregroundStyle(PetChatStyle.muted)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(activity.items) { item in
                            Button {
                                activity.open(item.id)
                                presentation.expand()
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: item.state.symbol)
                                        .foregroundStyle(item.state.color).frame(width: 16)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(item.title).fontWeight(.medium)
                                            Spacer()
                                            if item.unread { Circle().fill(PetChatStyle.blue).frame(width: 6, height: 6) }
                                        }
                                        Text(item.message).lineLimit(2).foregroundStyle(PetChatStyle.muted)
                                        HStack {
                                            Text(item.state.label)
                                            Spacer()
                                            Text(item.date, style: .time)
                                        }.font(.system(size: 10)).foregroundStyle(PetChatStyle.muted)
                                    }
                                }.font(.system(size: 12)).padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(PetChatStyle.controlFill, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(PetPressButtonStyle())
                        }
                    }
                }.frame(height: min(360, CGFloat(activity.items.count) * 96))
            }
        }
        .padding(16).frame(width: 320)
        .foregroundStyle(.primary)
    }
}
