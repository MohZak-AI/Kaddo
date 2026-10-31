import AppKit
import CoreGraphics

public struct WorkspaceActivitySample: Sendable {
    public let cursorPosition: CGPoint
    public let idleSeconds: TimeInterval

    public init(cursorPosition: CGPoint, idleSeconds: TimeInterval) {
        self.cursorPosition = cursorPosition
        self.idleSeconds = idleSeconds
    }

    @MainActor
    public static func current() -> Self {
        Self(
            cursorPosition: NSEvent.mouseLocation,
            idleSeconds: CGEventSource.secondsSinceLastEventType(
                // kCGAnyInputEventType is the SDK's ~0 sentinel; its C macro
                // is unavailable as a named Swift CGEventType case.
                .combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!
            )
        )
    }
}

public struct ActiveApplicationContext: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let name: String?
    public let processIdentifier: pid_t

    public init(bundleIdentifier: String?, name: String? = nil, processIdentifier: pid_t = 0) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.processIdentifier = processIdentifier
    }

    public init(_ application: NSRunningApplication) {
        self.init(
            bundleIdentifier: application.bundleIdentifier,
            name: application.localizedName,
            processIdentifier: application.processIdentifier
        )
    }
}

// NotificationCenter owns its block until removal; this token also cleans up on release.
private final class WorkspaceObservation: @unchecked Sendable {
    let center: NotificationCenter
    let token: NSObjectProtocol
    let timer: Timer?

    init(center: NotificationCenter, token: NSObjectProtocol, timer: Timer?) {
        self.center = center
        self.token = token
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
        center.removeObserver(token)
    }
}

@MainActor
public final class WorkspaceContextWatcher {
    public private(set) var activeApplication: ActiveApplicationContext?
    public var isRunning: Bool { observation != nil }

    private let notificationCenter: NotificationCenter
    private let model: PetApplicationState
    private let mapper: ApplicationContextMapper
    private let frontmostApplication: @MainActor () -> ActiveApplicationContext?
    private let activitySample: @MainActor () -> WorkspaceActivitySample
    private let now: @MainActor () -> TimeInterval
    private let idleThreshold: TimeInterval
    private let pollingInterval: TimeInterval?
    private var observation: WorkspaceObservation?
    private var generation = UUID()
    private var previousCursorPosition: CGPoint?
    private var lastContextActivityTime: TimeInterval?
    private var emotionBeforeSleeping: PetEmotion?

    public init(
        model: PetApplicationState,
        mapper: ApplicationContextMapper = ApplicationContextMapper(),
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        frontmostApplication: @escaping @MainActor () -> ActiveApplicationContext? = {
            NSWorkspace.shared.frontmostApplication.map(ActiveApplicationContext.init)
        },
        activitySample: @escaping @MainActor () -> WorkspaceActivitySample = {
            WorkspaceActivitySample.current()
        },
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        idleThreshold: TimeInterval = 600,
        pollingInterval: TimeInterval? = 0.1
    ) {
        precondition(idleThreshold.isFinite && idleThreshold > 0)
        if let pollingInterval {
            precondition(pollingInterval.isFinite && pollingInterval > 0)
        }
        self.model = model
        self.mapper = mapper
        self.notificationCenter = notificationCenter
        self.frontmostApplication = frontmostApplication
        self.activitySample = activitySample
        self.now = now
        self.idleThreshold = idleThreshold
        self.pollingInterval = pollingInterval
    }

    public func start() {
        guard !isRunning else { return }
        let generation = UUID()
        self.generation = generation
        let token = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            let context = ActiveApplicationContext(application)
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.activate(context, generation: generation) }
            } else {
                Task { @MainActor [weak self] in
                    self?.activate(context, generation: generation)
                }
            }
        }
        let timer = pollingInterval.map { interval in
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshActivity() }
            }
            timer.tolerance = interval / 10
            return timer
        }
        observation = WorkspaceObservation(center: notificationCenter, token: token, timer: timer)
        activeApplication = frontmostApplication()
        model.layoutCategory = mapper.category(for: activeApplication?.bundleIdentifier)
        let sample = activitySample()
        previousCursorPosition = sample.cursorPosition
        lastContextActivityTime = nil
        refreshActivity()
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    public func stop() {
        observation = nil
        generation = UUID()
        previousCursorPosition = nil
    }

    private func activate(_ context: ActiveApplicationContext, generation: UUID) {
        guard isRunning, self.generation == generation else { return }
        if context != activeApplication { lastContextActivityTime = now() }
        activeApplication = context
        let category = mapper.category(for: context.bundleIdentifier)
        if model.layoutCategory != category { model.layoutCategory = category }
        refreshActivity()
    }

    /// Main-actor polling also notices keyboard/click/scroll activity and a pointer that
    /// moves away and back between samples, using the session's last-input interval.
    public func refreshActivity() {
        guard isRunning else { return }
        let sample = activitySample()
        let timestamp = now()
        if sample.cursorPosition != previousCursorPosition { lastContextActivityTime = timestamp }
        previousCursorPosition = sample.cursorPosition
        // Keep native elapsed input time as a duration. Reconstructing and repeatedly
        // merging timestamps can accumulate rounding error at the 600-second boundary.
        let contextIdleSeconds = lastContextActivityTime.map { max(0, timestamp - $0) } ?? .infinity
        let idleSeconds = min(validIdleSeconds(sample.idleSeconds), contextIdleSeconds)

        let isInactive = idleSeconds >= idleThreshold
        if model.isInactive != isInactive { model.isInactive = isInactive }
        if isInactive {
            // A timer alert stays visible until another explicit action changes it.
            if model.currentEmotion != .sleeping && model.currentEmotion != .celebrating {
                emotionBeforeSleeping = model.currentEmotion
                model.currentEmotion = .sleeping
            }
        } else if let previousEmotion = emotionBeforeSleeping {
            // A newer explicit emotion from another feature takes precedence on wake.
            if model.currentEmotion == .sleeping { model.currentEmotion = previousEmotion }
            emotionBeforeSleeping = nil
        }
    }

    private func validIdleSeconds(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite && seconds >= 0 ? seconds : 0
    }
}
