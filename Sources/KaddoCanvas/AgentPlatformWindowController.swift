import AppKit
import SwiftUI

@MainActor
public final class AgentPlatformWindowController: NSWindowController, NSWindowDelegate {
    private let presentation: PetChatPresentationState?
    public init(platform: AgentPlatform, presentation: PetChatPresentationState? = nil) {
        self.presentation = presentation
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Kaddo · Personal agent"
        window.minSize = NSSize(width: 680, height: 500)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AgentPlatformView(platform: platform))
        super.init(window: window)
        window.delegate = self
        window.center()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(platform:)") }
    public func present() {
        presentation?.isSettingsOpen = true
        showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    public func windowWillClose(_ notification: Notification) { presentation?.isSettingsOpen = false }
}

public struct AgentPlatformView: View {
    @ObservedObject var platform: AgentPlatform
    @ObservedObject private var library: KnowledgeLibrary
    @State private var workflow: AgentWorkflow?
    @State private var scheduledWorkflow: AgentWorkflow?
    @State private var webAddress = ""
    public init(platform: AgentPlatform) { self.platform = platform; self.library = platform.library }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your personal agent").font(.title2).fontWeight(.semibold)
                Text("Choose what Kaddo remembers, reads, and checks for you.").foregroundStyle(.secondary)
            }
            TabView {
                memories.tabItem { Label("Memories", systemImage: "brain") }
                sources.tabItem { Label("Sources", systemImage: "folder") }
                workflows.tabItem { Label("Prompts", systemImage: "text.bubble") }
                routines.tabItem { Label("Routines", systemImage: "clock") }
            }
            if let error = platform.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text(platform.usesCloud() ? "Cloud AI is selected. Relevant excerpts are sent to your selected provider when answering or running a routine. Chat stays temporary." : "Ollama is selected. Excerpts and inference stay local. Chat stays temporary.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).background(Color(nsColor: .windowBackgroundColor))
        .disabled(!platform.loaded)
        .task { await platform.load() }
        .sheet(item: $workflow) { item in WorkflowEditor(platform: platform, workflow: item) }
        .sheet(item: $scheduledWorkflow) { item in RoutineEditor(platform: platform, workflow: item) }
    }
    private var memories: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Suggestions").font(.headline)
                Text("Kaddo suggests durable details from your own words. Nothing is remembered until you save it.").foregroundStyle(.secondary)
                if platform.data.suggestions.isEmpty { Text("No suggestions to review.").foregroundStyle(.secondary) }
                ForEach(platform.data.suggestions) { suggestion in
                    MemoryReviewRow(platform: platform, suggestion: suggestion)
                }
                Divider()
                Text("Accepted memories").font(.headline)
                ForEach(library.items.filter { item in platform.data.memories.contains { $0.itemID == item.id } }) { item in
                    AcceptedMemoryRow(platform: platform, item: item)
                }
                if platform.data.memories.isEmpty { Text("Accepted preferences and projects will appear here.").foregroundStyle(.secondary) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var sources: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Approved sources").font(.headline)
                Text("Folder access is read-only. Kaddo reads supported files when requested; reading does not import them into Knowledge Library.").foregroundStyle(.secondary)
                HStack {
                    Button("Choose folder…") { chooseFolder() }.disabled(platform.isChoosingFolder)
                    if platform.isChoosingFolder {
                        ProgressView().controlSize(.small)
                        Text("Saving read-only folder permission…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("https://example.com/page", text: $webAddress).textFieldStyle(.roundedBorder).accessibilityLabel("Public HTTPS source URL")
                    Button("Add web page") {
                        if let url = URL(string: webAddress) { Task { await platform.addWeb(url); if platform.error == nil { webAddress = "" } } }
                    }.disabled(URL(string: webAddress)?.scheme?.lowercased() != "https")
                }
                ForEach(platform.data.sources) { source in
                    HStack(alignment: .top) {
                        Image(systemName: source.kind == .folder ? "folder" : "globe").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name).fontWeight(.medium)
                            Text(source.url?.absoluteString ?? "Read-only folder · TXT, Markdown, PDF, Word").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("Source ID: " + source.id.uuidString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Remove access", role: .destructive) { Task { await platform.revokeSource(source.id) } }
                    }.padding(.vertical, 8)
                }
                if platform.data.sources.isEmpty { Text("Choose a folder or add a public web page to get started.").foregroundStyle(.secondary) }
            }.padding(16)
        }
    }
    private var workflows: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Reusable prompts").font(.headline)
                    Spacer()
                    Button("New prompt") { workflow = .init(name: "", instructions: "") }
                }
                Text("Run a prompt in chat, or schedule a read-only briefing. You can edit the built-in prompts.").foregroundStyle(.secondary)
                ForEach(platform.data.workflows) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.name).font(.headline)
                        Text(item.instructions).foregroundStyle(.secondary).lineLimit(3)
                        HStack {
                            Button("Run") { platform.runWorkflow(item) }
                            Button("Edit") { workflow = item }
                            Button("Duplicate") { Task { await platform.duplicateWorkflow(item) } }
                            Button("Schedule…") { scheduledWorkflow = item }
                            Spacer()
                            Button("Delete", role: .destructive) { Task { await platform.deleteWorkflow(item.id) } }
                        }
                    }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(16)
        }
    }
    private var routines: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Scheduled briefings").font(.headline)
                Text("Routines run while Kaddo is open. They summarize and suggest; they cannot change your tasks, memories, or settings.").foregroundStyle(.secondary)
                if platform.data.routines.isEmpty { Text("Use Schedule on a saved prompt to create a routine.").foregroundStyle(.secondary) }
                ForEach(platform.data.routines) { routine in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(platform.data.workflows.first { $0.id == routine.workflowID }?.name ?? "Missing prompt").fontWeight(.medium)
                            Text("\(routine.schedule.frequency.rawValue.capitalized) · Next: \(routine.nextRun.formatted())" + (routine.monitoring ? " · Changes only" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { Task { await platform.removeRoutine(routine.id) } }
                    }
                }
                Divider()
                HStack {
                    Text("Recent runs").font(.headline)
                    if platform.isRunning { ProgressView().controlSize(.small).accessibilityLabel("Running routine") }
                }
                ForEach(platform.data.runs.prefix(20)) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(run.status.capitalized).fontWeight(.medium)
                            Text(run.date.formatted()).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if ["failed", "interrupted"].contains(run.status) {
                                Button("Retry") { Task { await platform.retry(run) } }.disabled(platform.isRunning)
                            }
                        }
                        Text(run.summary).textSelection(.enabled)
                    }.padding(.vertical, 8)
                }
            }.padding(16)
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Allow read access"
        if panel.runModal() == .OK, let url = panel.url { Task { await platform.addFolder(url) } }
    }
}

private struct MemoryReviewRow: View {
    @ObservedObject var platform: AgentPlatform
    let suggestion: AgentMemorySuggestion
    @State private var fact = ""
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Suggested memory", text: $fact).textFieldStyle(.roundedBorder).accessibilityLabel("Edit suggested memory")
            Text("From your words: “\(suggestion.quote)” · \(suggestion.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let id = suggestion.replacesID, let old = platform.library.items.first(where: { $0.id == id }) {
                Text("Replaces: " + old.text).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(suggestion.replacesID == nil ? "Save memory" : "Save correction") {
                    busy = true; Task { await platform.accept(suggestion, fact: fact); busy = false }
                }.disabled(busy || fact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fact.count > 500)
                Text("Edit the text above before saving.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { Task { await platform.dismiss(suggestion) } }.disabled(busy)
            }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { fact = suggestion.fact }
    }
}
private struct AcceptedMemoryRow: View {
    @ObservedObject var platform: AgentPlatform
    let item: KnowledgeItem
    @State private var editing = false
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editing { TextField("Memory", text: $text).textFieldStyle(.roundedBorder).accessibilityLabel("Edit accepted memory") }
            else { Text(item.text).textSelection(.enabled) }
            if let provenance = platform.data.memories.first(where: { $0.itemID == item.id }) {
                Text(provenance.source + " · " + provenance.acceptedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(editing ? "Save" : "Edit") {
                    if editing { Task { await platform.updateMemory(item.id, text: text); editing = false } }
                    else { text = item.text; editing = true }
                }.disabled(editing && (text.isEmpty || text.count > 500))
                if editing { Button("Cancel") { editing = false } }
                Spacer()
                Button("Delete", role: .destructive) { Task { await platform.deleteMemory(item.id) } }
            }
        }.padding(.vertical, 8)
    }
}
private struct WorkflowEditor: View {
    @ObservedObject var platform: AgentPlatform
    @State var workflow: AgentWorkflow
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reusable prompt").font(.title2)
            TextField("Name", text: $workflow.name).textFieldStyle(.roundedBorder).accessibilityLabel("Prompt name")
            Text("Instructions").font(.headline)
            TextEditor(text: $workflow.instructions).frame(minHeight: 100).accessibilityLabel("Prompt instructions")
            Text("Selected sources").font(.headline)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(platform.data.sources) { source in
                        Toggle(source.name, isOn: Binding(get: { workflow.sourceIDs.contains(source.id) }, set: { enabled in
                            if enabled { workflow.sourceIDs.insert(source.id) } else { workflow.sourceIDs.remove(source.id) }
                        }))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 120)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { Task { await platform.saveWorkflow(workflow); if platform.error == nil { dismiss() } } }
                    .keyboardShortcut(.defaultAction).disabled(workflow.name.isEmpty || workflow.instructions.isEmpty || workflow.instructions.count > 2_000)
            }
            if let error = platform.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(24).frame(width: 520)
    }
}
private struct RoutineEditor: View {
    @ObservedObject var platform: AgentPlatform
    let workflow: AgentWorkflow
    @State private var schedule = AgentSchedule()
    @State private var monitoring = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Schedule “\(workflow.name)”").font(.title2)
            Picker("Repeat", selection: $schedule.frequency) {
                ForEach(AgentSchedule.Frequency.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            if schedule.frequency == .interval {
                Stepper("Every \(schedule.intervalMinutes) minutes", value: $schedule.intervalMinutes, in: 30...10_080, step: 30)
            } else {
                HStack {
                    Stepper("Hour: \(schedule.hour)", value: $schedule.hour, in: 0...23)
                    Stepper("Minute: \(schedule.minute)", value: $schedule.minute, in: 0...59)
                }
                if schedule.frequency == .weekly {
                    Picker("Day", selection: $schedule.weekday) {
                        ForEach(1...7, id: \.self) { day in Text(Calendar.current.weekdaySymbols[day - 1]).tag(day) }
                    }
                }
            }
            Toggle("Monitoring: report only when sources change", isOn: $monitoring)
            Text("Uses this Mac’s local time. Runs while Kaddo is open, with at most one catch-up after sleep. Scheduled work is read-only.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create routine") {
                    Task { await platform.schedule(workflow, schedule: schedule, monitoring: monitoring); if platform.error == nil { dismiss() } }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
    }
}
