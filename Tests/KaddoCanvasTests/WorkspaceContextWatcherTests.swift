import AppKit
import Combine
import XCTest
@testable import KaddoCanvas

@MainActor
private final class ActivityHarness {
    var time: TimeInterval = 1_000
    var idle: TimeInterval = 0
    var cursor = CGPoint.zero
    var application: ActiveApplicationContext? = .init(bundleIdentifier: "com.apple.dt.Xcode")

    func advance(_ seconds: TimeInterval) {
        time += seconds
        idle += seconds
    }

    func watcher(
        model: PetApplicationState,
        center: NotificationCenter = NotificationCenter(),
        mapper: ApplicationContextMapper = ApplicationContextMapper(),
        pollingInterval: TimeInterval? = nil
    ) -> WorkspaceContextWatcher {
        WorkspaceContextWatcher(
            model: model,
            mapper: mapper,
            notificationCenter: center,
            frontmostApplication: { self.application },
            activitySample: { WorkspaceActivitySample(cursorPosition: self.cursor, idleSeconds: self.idle) },
            now: { self.time },
            pollingInterval: pollingInterval
        )
    }
}

final class WorkspaceContextWatcherTests: XCTestCase {
    @MainActor
    func testCelebrationInterruptsSleepAndSurvivesFurtherIdlePollingAndWake() {
        let harness = ActivityHarness()
        harness.idle = 700
        let model = PetApplicationState()
        let watcher = harness.watcher(model: model)
        defer { watcher.stop() }
        watcher.start()
        XCTAssertEqual(model.currentEmotion, .sleeping)

        model.currentEmotion = .celebrating
        model.speechBubbleText = "Time's up!"
        for _ in 0..<3 {
            harness.advance(1)
            watcher.refreshActivity()
            XCTAssertEqual(model.currentEmotion, .celebrating)
        }
        harness.idle = 0
        watcher.refreshActivity()
        XCTAssertEqual(model.currentEmotion, .celebrating)
        XCTAssertEqual(model.speechBubbleText, "Time's up!")

        model.currentEmotion = .idle
        harness.advance(600)
        watcher.refreshActivity()
        XCTAssertEqual(model.currentEmotion, .sleeping, "Normal inactivity resumes after the alert")
    }

    @MainActor
    func testDefaultWorkspaceCenterAndNativeActivityProvider() {
        let model = PetApplicationState()
        let watcher = WorkspaceContextWatcher(model: model, pollingInterval: nil)
        defer { watcher.stop() }
        watcher.start()
        XCTAssertEqual(
            model.layoutCategory,
            ApplicationContextMapper().category(for: watcher.activeApplication?.bundleIdentifier)
        )
        let sample = WorkspaceActivitySample.current()
        XCTAssertTrue(sample.idleSeconds.isFinite)
        XCTAssertGreaterThanOrEqual(sample.idleSeconds, 0)
        let started = ProcessInfo.processInfo.systemUptime
        postActivation(NSWorkspace.shared.notificationCenter)
        XCTAssertEqual(watcher.activeApplication, ActiveApplicationContext(NSRunningApplication.current))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.3)
    }

    @MainActor
    func testStartupMapsCurrentAppWithoutOverwritingAwakeEmotion() {
        let harness = ActivityHarness()
        harness.application = .init(bundleIdentifier: " COM.MICROSOFT.vscode\n")
        let model = PetApplicationState(currentEmotion: .thinking)
        let watcher = harness.watcher(model: model)
        defer { watcher.stop() }
        watcher.start()
        XCTAssertEqual(model.layoutCategory, .coding)
        XCTAssertEqual(watcher.activeApplication, harness.application)
        XCTAssertEqual(model.currentEmotion, .thinking)
        XCTAssertTrue(watcher.isRunning)
    }

    @MainActor
    func testNativeActivationMapsAndPublishesWithin300Milliseconds() {
        let harness = ActivityHarness()
        let center = NotificationCenter()
        let native = NSRunningApplication.current
        let mapper = ApplicationContextMapper(
            communicationBundleIdentifiers: Set(native.bundleIdentifier.map { [$0] } ?? [])
        )
        let model = PetApplicationState()
        let watcher = harness.watcher(model: model, center: center, mapper: mapper)
        defer { watcher.stop() }
        watcher.start()
        var categories: [PetLayoutCategory] = []
        let token = model.$layoutCategory.dropFirst().sink { categories.append($0) }
        let started = ProcessInfo.processInfo.systemUptime
        postActivation(center, application: native)
        let expected: PetLayoutCategory = native.bundleIdentifier == nil ? .general : .communication
        XCTAssertEqual(watcher.activeApplication, ActiveApplicationContext(native))
        XCTAssertEqual(model.layoutCategory, expected)
        XCTAssertEqual(categories, [expected])
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.3)
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testBackgroundActivationReachesMainActorWithin300Milliseconds() {
        let harness = ActivityHarness()
        let center = NotificationCenter()
        let model = PetApplicationState()
        let watcher = harness.watcher(model: model, center: center)
        defer { watcher.stop() }
        watcher.start()
        let started = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global().async {
            center.post(
                name: NSWorkspace.didActivateApplicationNotification, object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
            )
        }
        assertWithin300Milliseconds(started: started) {
            watcher.activeApplication == ActiveApplicationContext(NSRunningApplication.current)
        }
        XCTAssertEqual(model.layoutCategory, .general)
    }

    @MainActor
    func testMalformedEventsAndRepeatedStartStopAreHarmless() {
        let harness = ActivityHarness()
        let center = NotificationCenter()
        let model = PetApplicationState()
        let watcher = harness.watcher(model: model, center: center)
        var categories: [PetLayoutCategory] = []
        let token = model.$layoutCategory.dropFirst().sink { categories.append($0) }
        watcher.start()
        watcher.start()
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: "invalid"])
        center.post(name: Notification.Name("unrelated"), object: nil)
        XCTAssertEqual(categories, [.coding])
        XCTAssertEqual(watcher.activeApplication, harness.application)
        watcher.stop()
        watcher.stop()
        harness.advance(700)
        postActivation(center)
        watcher.refreshActivity()
        XCTAssertFalse(watcher.isRunning)
        XCTAssertEqual(model.currentEmotion, .idle)
        XCTAssertEqual(watcher.activeApplication, harness.application)
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testQueuedActivationCannotCrossStopAndRestart() {
        let harness = ActivityHarness()
        let center = NotificationCenter()
        let watcher = harness.watcher(model: PetApplicationState(), center: center)
        defer { watcher.stop() }
        watcher.start()
        let posted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            center.post(
                name: NSWorkspace.didActivateApplicationNotification, object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
            )
            posted.signal()
        }
        XCTAssertEqual(posted.wait(timeout: .now() + 0.3), .success)
        watcher.stop()
        harness.application = .init(bundleIdentifier: "org.example.restarted")
        watcher.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(watcher.activeApplication, harness.application)
    }

    @MainActor
    func testSleepsAt600SecondsAndRestoresPreviousEmotionOnInput() {
        let harness = ActivityHarness()
        let model = PetApplicationState(currentEmotion: .thinking)
        let watcher = harness.watcher(model: model)
        defer { watcher.stop() }
        watcher.start()
        harness.advance(599.9)
        watcher.refreshActivity()
        XCTAssertEqual(model.currentEmotion, .thinking)
        harness.advance(0.1)
        let started = ProcessInfo.processInfo.systemUptime
        watcher.refreshActivity()
        XCTAssertEqual(model.currentEmotion, .sleeping)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.3)
        XCTAssertEqual(model.layoutCategory, .coding)
        harness.idle = 0
        watcher.refreshActivity()
        XCTAssertEqual(model.currentEmotion, .thinking)
    }

    @MainActor
    func testCursorDisplacementWakesAndResetsTheInterval() {
        let harness = ActivityHarness()
        harness.idle = 700
        let model = PetApplicationState()
        let watcher = harness.watcher(model: model)
        defer { watcher.stop() }
        watcher.start()
        XCTAssertEqual(model.currentEmotion, .sleeping)
        harness.cursor = CGPoint(x: -120, y: 400)
        watcher.refreshActivity()
        XCTAssertEqual(model.currentEmotion, .idle)
        harness.advance(599.9)
        watcher.refreshActivity()
        XCTAssertEqual(model.currentEmotion, .idle)
        harness.advance(0.1)
        watcher.refreshActivity()
        XCTAssertEqual(model.currentEmotion, .sleeping)
    }

    @MainActor
    func testKeyboardOrTransientPointerInputPreventsSleepWithUnchangedCursor() {
        let harness = ActivityHarness()
        let model = PetApplicationState()
        let watcher = harness.watcher(model: model)
        defer { watcher.stop() }
        watcher.start()
        for _ in 0..<3 {
            harness.advance(400)
            harness.idle = 1 // Input occurred between samples; pointer has returned to its origin.
            watcher.refreshActivity()
            XCTAssertEqual(model.currentEmotion, .idle)
        }
        harness.advance(599)
        watcher.refreshActivity()
        XCTAssertEqual(model.currentEmotion, .sleeping)
    }

    @MainActor
    func testAppSwitchWakesWithin300MillisecondsAndRestartsInactivity() {
        let harness = ActivityHarness()
        harness.idle = 700
        let center = NotificationCenter()
        let model = PetApplicationState(currentEmotion: .happy)
        let watcher = harness.watcher(model: model, center: center)
        defer { watcher.stop() }
        watcher.start()
        XCTAssertEqual(model.currentEmotion, .sleeping)
        let started = ProcessInfo.processInfo.systemUptime
        postActivation(center)
        XCTAssertEqual(model.currentEmotion, .happy)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.3)
        harness.advance(599)
        watcher.refreshActivity()
        XCTAssertEqual(model.currentEmotion, .happy)
        harness.advance(1)
        watcher.refreshActivity()
        XCTAssertEqual(model.currentEmotion, .sleeping)
    }

    @MainActor
    func testDuplicateActivationDoesNotDelaySleeping() {
        let harness = ActivityHarness()
        harness.application = ActiveApplicationContext(NSRunningApplication.current)
        let center = NotificationCenter()
        let model = PetApplicationState()
        let watcher = harness.watcher(model: model, center: center)
        defer { watcher.stop() }
        watcher.start()
        harness.advance(600)
        postActivation(center)
        XCTAssertEqual(model.currentEmotion, .sleeping)
    }

    @MainActor
    func testRealPollingTimerSleepsAndWakesWithin300Milliseconds() {
        let harness = ActivityHarness()
        let model = PetApplicationState()
        let watcher = harness.watcher(model: model, pollingInterval: 0.1)
        defer { watcher.stop() }
        watcher.start()
        harness.advance(600)
        assertWithin300Milliseconds { model.currentEmotion == .sleeping }
        harness.cursor.x += 1
        assertWithin300Milliseconds { model.currentEmotion == .idle }
        watcher.stop()
        harness.advance(700)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(model.currentEmotion, .idle, "Stopped timer must not mutate the pet")
    }

    @MainActor
    func testReleaseCleansUpWithoutRetainingWatcher() {
        let harness = ActivityHarness()
        let model = PetApplicationState()
        let center = NotificationCenter()
        var watcher: WorkspaceContextWatcher? = harness.watcher(
            model: model, center: center, pollingInterval: 0.01
        )
        let releasedWatcher = { [weak watcher] in watcher }
        watcher?.start()
        watcher = nil
        XCTAssertNil(releasedWatcher())
        harness.advance(700)
        postActivation(center)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(model.currentEmotion, .idle)
        XCTAssertEqual(model.layoutCategory, .coding)
    }

    @MainActor
    func testMissingAppAndInvalidIdleSamplesHaveSafeFallbacks() {
        let harness = ActivityHarness()
        harness.application = nil
        let model = PetApplicationState()
        let watcher = harness.watcher(model: model)
        defer { watcher.stop() }
        watcher.start()
        XCTAssertNil(watcher.activeApplication)
        XCTAssertEqual(model.layoutCategory, .general)
        for invalid in [TimeInterval.nan, .infinity, -1] {
            harness.advance(700)
            harness.idle = invalid
            watcher.refreshActivity()
            XCTAssertEqual(model.currentEmotion, .idle)
        }
    }

    @MainActor
    func testNewerEmotionTakesPrecedenceWhenActivityResumes() {
        let harness = ActivityHarness()
        let model = PetApplicationState(currentEmotion: .thinking)
        let watcher = harness.watcher(model: model)
        defer { watcher.stop() }
        watcher.start()
        harness.advance(600)
        watcher.refreshActivity()
        model.currentEmotion = .happy
        harness.idle = 0
        watcher.refreshActivity()
        XCTAssertEqual(model.currentEmotion, .happy)
    }

    @MainActor
    private func postActivation(
        _ center: NotificationCenter, application: NSRunningApplication = .current
    ) {
        center.post(
            name: NSWorkspace.didActivateApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: application]
        )
    }

    @MainActor
    private func assertWithin300Milliseconds(
        started: TimeInterval = ProcessInfo.processInfo.systemUptime,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        while !condition() && ProcessInfo.processInfo.systemUptime - started < 0.3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        XCTAssertTrue(condition(), "State transition must complete within 300 ms", file: file, line: line)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.3, file: file, line: line)
    }
}
