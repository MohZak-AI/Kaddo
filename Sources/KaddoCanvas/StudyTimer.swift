import Foundation

/// A wall-clock countdown: run-loop delays never make a study block run longer.
public struct StudyTimer: Equatable, Sendable {
    public enum Status: String, Sendable { case running, paused, completed }
    public let title: String
    public let isBreak: Bool
    public let duration: Int
    public private(set) var remaining: Int
    public private(set) var status: Status = .running
    private var deadline: Date
    private var announced: Set<Int> = []

    public init(title: String, seconds: Int, now: Date, isBreak: Bool = false) {
        precondition(seconds > 0)
        self.title = title
        self.isBreak = isBreak
        duration = seconds
        remaining = seconds
        deadline = now.addingTimeInterval(TimeInterval(seconds))
    }

    public mutating func advance(to now: Date) -> String? {
        guard status == .running else { return nil }
        let previous = remaining
        remaining = max(0, Int(ceil(deadline.timeIntervalSince(now))))
        // Announce only the most urgent crossed checkpoint after sleep or a delayed tick.
        let checkpoints = Set([duration / 2, 300, 30, 0]).filter { $0 < duration }
        let crossed = checkpoints.filter { previous > $0 && remaining <= $0 && !announced.contains($0) }
        announced.formUnion(crossed)
        if remaining == 0 { status = .completed }
        guard let checkpoint = crossed.min() else { return nil }
        let halfway = checkpoint == duration / 2 ? "Halfway through \(title)! " : ""
        switch checkpoint {
        case 0: return "Time’s up! \(title) is finished. nice work showing up :) use /done <task number> or /break 5."
        case 30: return halfway + "30 seconds left on \(title). wrap up that thought, buddy :)"
        case 300: return halfway + "5 minutes left on \(title). you’re nearly there, buddy!"
        default: return "Halfway through \(title)! you’ve got this :)"
        }
    }

    public mutating func pause(at now: Date) -> String? {
        let alert = advance(to: now)
        if status == .running { status = .paused }
        return alert
    }

    public mutating func resume(at now: Date) {
        guard status == .paused else { return }
        deadline = now.addingTimeInterval(TimeInterval(remaining))
        status = .running
    }

    public var clockText: String { String(format: "%02d:%02d", remaining / 60, remaining % 60) }
}
