import Combine
import Foundation

public enum PetActivityState: String, CaseIterable, Sendable {
    case idle, running, needsInput, ready, blocked

    public var label: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .needsInput: "Needs input"
        case .ready: "Ready"
        case .blocked: "Blocked"
        }
    }

    var priority: Int {
        switch self {
        case .needsInput: 4
        case .blocked: 3
        case .ready: 2
        case .running: 1
        case .idle: 0
        }
    }
}

/// A result snapshot is independent of the live answer and its document session.
public struct PetActivityItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var message: String
    public var state: PetActivityState
    public var date: Date
    public var unread: Bool
    public var sources: [DocumentChunk]
}

/// RAM-only activity. Operation IDs are capabilities: a retired ID cannot finish again.
@MainActor
public final class PetActivityStore: ObservableObject {
    @Published public private(set) var items: [PetActivityItem] = []
    @Published public private(set) var preview: PetActivityItem?
    @Published public private(set) var selected: PetActivityItem?
    @Published public var showsTray = false
    @Published public private(set) var hasRunning = false
    private var running: [UUID: String] = [:]
    private var questions: [UUID: String] = [:]
    private var previewQueue: [UUID] = []
    private var remainingPreview: TimeInterval = 6
    private var previousTick: TimeInterval?
    private var overlayVisible = true
    private var previewsEnabled = true
    static let capacity = 20

    public init() {}

    public var unreadCount: Int { items.filter(\.unread).count }
    public var state: PetActivityState {
        if !questions.isEmpty { return .needsInput }
        let unreadState = items.filter(\.unread).map(\.state).max { $0.priority < $1.priority }
        return [unreadState ?? .idle, hasRunning ? .running : .idle]
            .max { $0.priority < $1.priority } ?? .idle
    }

    @discardableResult
    public func begin(title: String) -> UUID {
        let id = UUID()
        running[id] = title; hasRunning = true
        insert(.init(id: id, title: title, message: "Working…", state: .running,
                     date: Date(), unread: false, sources: []))
        return id
    }

    public func update(_ id: UUID, message: String) {
        guard running[id] != nil, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].message = String(message.prefix(12_000))
    }

    public func finish(_ id: UUID, state: PetActivityState, message: String,
                       sources: [DocumentChunk] = [], preview: Bool = true) {
        guard let title = running.removeValue(forKey: id) else { return }
        hasRunning = !running.isEmpty
        items.removeAll { $0.id == id }
        insert(.init(id: id, title: title, message: String(message.prefix(12_000)), state: state,
                     date: Date(), unread: true, sources: sources))
        if preview { enqueue(id) }
    }

    public func cancel(_ id: UUID) {
        running.removeValue(forKey: id); hasRunning = !running.isEmpty
        items.removeAll { $0.id == id }
        previewQueue.removeAll { $0 == id }
        if preview?.id == id { dismissPreview() }
    }

    @discardableResult
    public func record(title: String, message: String, state: PetActivityState = .ready,
                       preview: Bool = false, sources: [DocumentChunk] = []) -> UUID {
        let id = UUID()
        insert(.init(id: id, title: title, message: String(message.prefix(12_000)), state: state,
                     date: Date(), unread: true, sources: sources))
        if preview { enqueue(id) }
        return id
    }

    public func setQuestion(_ id: UUID, message: String?) {
        guard questions[id] != message else { return }
        questions[id] = message
        if let message {
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].message = message; items[index].unread = true
                items[index].state = .needsInput; items[index].date = Date()
            } else {
                insert(.init(id: id, title: "Kaddo has a question", message: message,
                             state: .needsInput, date: Date(), unread: true, sources: []))
            }
        } else if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].state = .ready; items[index].unread = false
        }
        // Also publish when a question outlives its bounded tray entry.
        objectWillChange.send()
    }

    public func open(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].unread = false
        selected = items[index]
        showsTray = false
        previewQueue.removeAll { $0 == id }
        dismissPreview()
    }

    public func returnToLive() { selected = nil }
    public func dismissPreview() { preview = nil; remainingPreview = 6; previousTick = nil }

    public func configure(visible: Bool, previewsEnabled: Bool) {
        overlayVisible = visible; self.previewsEnabled = previewsEnabled
        if !visible || !previewsEnabled {
            previewQueue.removeAll(); dismissPreview()
        }
        if !visible { selected = nil; showsTray = false }
    }

    /// Driven by the native pointer loop. Busy UI queues previews; hover pauses their clock.
    public func tick(now: TimeInterval, busy: Bool, hovered: Bool) {
        guard overlayVisible, previewsEnabled else { return }
        let delta = previousTick.map { max(0, now - $0) } ?? 0
        previousTick = now
        if preview != nil {
            if !hovered && !busy { remainingPreview -= delta }
            if remainingPreview <= 0 { preview = nil; remainingPreview = 6 }
        }
        guard preview == nil, !busy, selected == nil, !showsTray else { return }
        while !previewQueue.isEmpty {
            let id = previewQueue.removeFirst()
            guard let item = items.first(where: { $0.id == id && $0.unread }) else { continue }
            preview = item; remainingPreview = 6
            break
        }
    }

    public func clear() {
        running.removeAll(); questions.removeAll(); previewQueue.removeAll()
        items = []; selected = nil; hasRunning = false; showsTray = false; dismissPreview()
    }

    private func enqueue(_ id: UUID) {
        guard overlayVisible, previewsEnabled else { return }
        previewQueue.append(id)
    }

    private func insert(_ item: PetActivityItem) {
        items.insert(item, at: 0)
        if items.count > Self.capacity { items.removeLast(items.count - Self.capacity) }
        let retained = Set(items.map(\.id))
        previewQueue.removeAll { !retained.contains($0) }
    }
}
