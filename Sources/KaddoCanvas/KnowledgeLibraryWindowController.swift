import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class KnowledgeLibraryWindowController: NSWindowController {
    public init(library: KnowledgeLibrary, ingestion: DocumentIngestionService? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Knowledge Library"
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: KnowledgeLibraryView(library: library, ingestion: ingestion))
        super.init(window: window)
        window.center()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public func present() { showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
}

public struct KnowledgeLibraryView: View {
    @ObservedObject var library: KnowledgeLibrary
    private let ingestion: DocumentIngestionService?
    @State private var categoryID: UUID?
    @State private var selectedID: UUID?
    @State private var search = ""
    @State private var categoryName = ""
    @State private var title = ""
    @State private var text = ""
    @State private var creating = false
    @State private var busy = false
    @State private var operationError: String?
    @State private var matches: Set<UUID>?
    @State private var showDelete = false
    public init(library: KnowledgeLibrary, ingestion: DocumentIngestionService? = nil) { self.library = library; self.ingestion = ingestion }
    private var selected: KnowledgeItem? { library.items.first { $0.id == selectedID } }
    private var visible: [KnowledgeItem] {
        library.items.filter { (categoryID == nil || $0.categoryID == categoryID) && (matches == nil || matches!.contains($0.id)) }
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search saved knowledge", text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search saved knowledge")
                Button("New note") { selectedID = nil; title = ""; text = ""; creating = true }
                Button("Import…", action: importFiles).disabled(busy)
            }.padding(16)
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    Button("All categories") { categoryID = nil }.buttonStyle(.plain)
                        .fontWeight(categoryID == nil ? .semibold : .regular)
                    ForEach(library.categories) { category in
                        Button(category.name) { categoryID = category.id }.buttonStyle(.plain)
                            .fontWeight(categoryID == category.id ? .semibold : .regular)
                    }
                    Divider()
                    TextField("New category", text: $categoryName).accessibilityLabel("New category name")
                    Button("Add category") {
                        Task { if await library.addCategory(name: categoryName) != nil { categoryName = "" } }
                    }.disabled(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }.padding(16).frame(minWidth: 150, idealWidth: 170, maxWidth: 220)
                VStack(alignment: .leading, spacing: 0) {
                    if visible.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(search.isEmpty ? "Your saved knowledge belongs here" : "No matching knowledge").font(.headline)
                            Text(search.isEmpty ? "Create a note or import PDF, Word, UTF-8 text or Markdown. Your planner and optional profile appear automatically after a successful save." : "Try different keywords or select All categories.")
                                .foregroundStyle(.secondary)
                        }.padding(24)
                        Spacer()
                    } else {
                        List(visible, selection: $selectedID) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).lineLimit(2)
                                Text(item.sourceKey.hasPrefix("sync:") ? "Managed · \(item.sourceKind)" : item.sourceKind.uppercased())
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4).tag(item.id)
                        }
                    }
                }.frame(minWidth: 200, idealWidth: 260)
                VStack(alignment: .leading, spacing: 12) {
                    if creating || selected != nil {
                        if creating || selected?.isEditable == true {
                            TextField("Note title", text: $title).font(.headline).accessibilityLabel("Knowledge note title")
                            TextEditor(text: $text).font(.body).accessibilityLabel("Knowledge note text")
                            HStack {
                                Button("Save") { save() }.keyboardShortcut("s", modifiers: .command)
                                    .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                if creating { Button("Cancel") { creating = false }.keyboardShortcut(.cancelAction) }
                            }
                        } else if let selected {
                            Text(selected.title).font(.headline)
                            ScrollView { Text(selected.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                        if let selected {
                            Picker("Category", selection: Binding(get: { selected.categoryID }, set: { category in
                                Task { if !(await library.moveItem(id: selected.id, categoryID: category)) { operationError = library.error ?? "Couldn’t move item." } }
                            })) { ForEach(library.categories) { Text($0.name).tag($0.id) } }
                            Text("Item ID: \(selected.id.uuidString)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if selected.sourceKey.hasPrefix("sync:") {
                                Text("Managed by your planner or profile. Edit or remove it with the existing planner controls or chat.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("Delete…", role: .destructive) { showDelete = true }.disabled(busy)
                            }
                            if let url = selected.sourceURL {
                                Text("Imported from \(url.lastPathComponent). Extracted text remains available if the original moves.").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("New notes save to \(library.categories.first { $0.id == categoryID }?.name ?? "General").").font(.caption).foregroundStyle(.secondary)
                        }
                    } else { Text("Select a saved item to read its text and source.").foregroundStyle(.secondary); Spacer() }
                }.padding(16).frame(minWidth: 280, maxWidth: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if library.isIndexing || busy { ProgressView().controlSize(.small).accessibilityLabel("Indexing or saving knowledge") }
                    Text(library.status.isEmpty ? "Loading knowledge…" : library.status).font(.caption)
                    Text("\(library.items.filter { $0.indexingStatus == .indexed }.count)/\(library.items.count) items indexed").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry indexing") { Task { await library.retryIndexing() } }.disabled(library.isIndexing)
                }
                if let error = operationError ?? library.error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
                Text("Session uploads and recent conversation are saved locally. Kaddo automatically files uploads and updates session summaries in General. With cloud AI selected, file excerpts and conversation are sent to your selected provider for these tasks and knowledge answers. Embeddings stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
        .task { await library.load() }
        .task(id: search + (categoryID?.uuidString ?? "all") + String(library.revision)) {
            if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { matches = nil; return }
            let result = await library.search(query: search, categoryID: categoryID)
            if !Task.isCancelled { matches = Set(result.map(\.itemID)) }
        }
        .onChange(of: selectedID) { _ in
            if selectedID != nil { creating = false }
            operationError = nil
            if !creating { title = selected?.title ?? ""; text = selected?.text ?? "" }
        }
        .onChange(of: library.revision) { _ in
            if let selectedID, !library.items.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        }
        .alert("Delete this knowledge item?", isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard let selected else { return }
                Task { if !(await library.deleteItem(id: selected.id)) { operationError = library.error ?? "Couldn’t delete item." } }
            }
        } message: { Text("The saved extracted text will be removed from the library.") }
    }
    private func save() {
        busy = true; operationError = nil
        Task {
            let ok: Bool
            if creating { ok = await library.addNote(title: title, text: text, categoryID: categoryID ?? KnowledgeCategory.general.id) }
            else if let selected { ok = await library.updateNote(id: selected.id, title: title, text: text) }
            else { ok = false }
            busy = false
            if ok { creating = false } else { operationError = library.error ?? "Couldn’t save note." }
        }
    }
    private func importFiles() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .plainText, UTType(filenameExtension: "docx")!, UTType(filenameExtension: "md")!]
        let category = categoryID ?? KnowledgeCategory.general.id
        busy = true; operationError = nil
        panel.begin { response in
            guard response == .OK else { busy = false; return }
            let urls = panel.urls
            if let ingestion { ingestion.enqueue(urls); busy = false; return }
            Task { @MainActor in
                for url in urls {
                    if !(await library.importDocument(at: url, categoryID: category)) { operationError = library.error ?? "Couldn’t import \(url.lastPathComponent)."; break }
                }
                busy = false
            }
        }
    }
}
