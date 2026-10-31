import SwiftUI

/// A selectable drop box backed by a single entry in the session record map.
public struct SessionFolderView: View {
    @ObservedObject private var state: PetApplicationState
    private let sessionID: UUID

    public init(state: PetApplicationState, sessionID: UUID) {
        self.state = state
        self.sessionID = sessionID
    }

    public var body: some View {
        if let record = state.sessionFolders[sessionID] {
            SessionFolderContents(state: state, record: record, memory: record.documentMemory)
        }
    }
}

private struct SessionFolderContents: View {
    @ObservedObject var state: PetApplicationState
    let record: SessionFolderRecord
    @ObservedObject var memory: DocumentMemoryStore

    var body: some View {
        Button {
            state.selectSession(id: record.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(record.title, systemImage: state.activeSessionID == record.id
                      ? "folder.fill" : "folder")
                Text(memory.isImporting ? "Reading…" : "\(record.files.count) files · Drop PDF, DOCX, TXT or MD")
                    .font(.caption)
                ForEach(record.files.prefix(2), id: \.self) { url in
                    Text(url.lastPathComponent).font(.caption).lineLimit(1)
                }
            }
            .frame(width: 190, alignment: .leading)
            .padding(10)
            .background(state.activeSessionID == record.id
                        ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                state.activeSessionID == record.id ? Color.accentColor : Color.secondary.opacity(0.3)
            ))
        }
        .buttonStyle(SessionFolderButtonStyle())
        .accessibilityLabel("\(record.title), \(record.files.count) files")
        .accessibilityAddTraits(state.activeSessionID == record.id ? .isSelected : [])
        .onDrop(of: DocumentDropTypes.supported, isTargeted: nil) { providers in
            // Capture the destination before asynchronous provider URL resolution.
            DocumentDropHandler.receive(providers, onURL: { url in
                state.ingestion.enqueue([url], sessionID: record.id)
            }, onFailure: {
                guard state.activeSessionID == record.id else { return }
                state.speechBubbleText = "Drop a PDF, DOCX, TXT or Markdown file."
            })
        }
    }
}

private struct SessionFolderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
