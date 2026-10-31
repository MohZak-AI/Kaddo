import AppKit
import Testing

@Suite("Scope 2 · Workspace attention")
@MainActor
struct AttentionTests {
    @Test("Classifies the frontmost app immediately on start", arguments: [
        ("com.apple.dt.Xcode", AttentionMode.focused),
        ("com.microsoft.VSCode", .focused),
        ("com.tinyspeck.slackmacgap", .distracted),
        ("com.hnc.Discord", .distracted),
        ("com.apple.Safari", .idle)
    ])
    func classification(bundleID: String, expected: AttentionMode) throws {
        let engine = try MVPFactory.attention(
            notificationCenter: NotificationCenter(), idleSeconds: { 0 },
            frontmostApp: { ForegroundApp(bundleID: bundleID, name: "Test app") }
        )
        defer { engine.stop() }
        engine.start()
        #expect(engine.mode == expected)
        #expect(engine.foregroundApp?.bundleID == bundleID)
    }

    @Test("Inactivity switches at the ten-minute boundary and recovers")
    func inactivity() throws {
        var idle: TimeInterval = 599.9
        let engine = try MVPFactory.attention(
            notificationCenter: NotificationCenter(), idleSeconds: { idle },
            frontmostApp: { ForegroundApp(bundleID: "com.apple.dt.Xcode", name: "Xcode") }
        )
        defer { engine.stop() }
        engine.start()
        #expect(engine.mode == .focused)
        idle = 600
        engine.refreshIdleState()
        #expect(engine.mode == .sleeping)
        idle = 0
        engine.refreshIdleState()
        #expect(engine.mode == .focused)
    }

    @Test("Consumes NSWorkspace activation notifications with native app payload")
    func workspaceNotification() throws {
        let center = NotificationCenter()
        let nativeApp = NSRunningApplication.current
        var configuration = AttentionConfiguration()
        if let bundleID = nativeApp.bundleIdentifier {
            configuration.distractedBundleIDs.insert(bundleID)
        }
        let engine = try MVPFactory.attention(
            configuration: configuration, notificationCenter: center, idleSeconds: { 0 },
            frontmostApp: { ForegroundApp(bundleID: "com.apple.dt.Xcode", name: "Xcode") }
        )
        defer { engine.stop() }
        engine.start()
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: nativeApp])
        #expect(engine.mode == (nativeApp.bundleIdentifier == nil ? .idle : .distracted))
        #expect(engine.foregroundApp?.bundleID == nativeApp.bundleIdentifier)
    }

    @Test("Ignores malformed notifications and stops observing on stop")
    func observerLifecycle() throws {
        let center = NotificationCenter()
        let engine = try MVPFactory.attention(
            notificationCenter: center, idleSeconds: { 0 },
            frontmostApp: { ForegroundApp(bundleID: "com.apple.dt.Xcode", name: "Xcode") }
        )
        engine.start()
        engine.start()
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(engine.mode == .focused)
        engine.stop()
        engine.stop()
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        #expect(engine.foregroundApp?.bundleID == "com.apple.dt.Xcode")
    }

    @Test("A sleeping user remains sleeping during an app activation")
    func inactivityHasPriority() throws {
        let center = NotificationCenter()
        let engine = try MVPFactory.attention(
            notificationCenter: center, idleSeconds: { 700 }, frontmostApp: { nil }
        )
        defer { engine.stop() }
        engine.start()
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        #expect(engine.mode == .sleeping)
    }

    @Test("Missing frontmost app is an idle state")
    func noFrontmostApp() throws {
        let engine = try MVPFactory.attention(
            notificationCenter: NotificationCenter(), idleSeconds: { 0 }, frontmostApp: { nil }
        )
        defer { engine.stop() }
        engine.start()
        #expect(engine.mode == .idle)
        #expect(engine.foregroundApp == nil)
    }
}
