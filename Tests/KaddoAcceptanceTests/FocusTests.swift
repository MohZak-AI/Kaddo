import Foundation
import Testing

@Suite("Scope 4 · Focus loop and persistence")
@MainActor
struct FocusTests {
    @Test("A timer subscription drives progress without calling refresh from the UI")
    func backgroundSubscription() throws {
        let storage = try IsolatedDefaults()
        defer { storage.cleanUp() }
        let clock = TestClock()
        let ticker = ManualTicker()
        let engine = try MVPFactory.focus(now: { clock.time }, defaults: storage.defaults, ticker: ticker)
        engine.setAttention(.focused)
        try engine.start(duration: 100)
        #expect(ticker.activeSubscriptionCount == 1)
        clock.advance(25)
        ticker.fire()
        #expect(engine.remainingSeconds == 75)
        engine.cancel()
        #expect(ticker.activeSubscriptionCount == 0)
        try engine.start(duration: 100)
        #expect(ticker.activeSubscriptionCount == 1)
        clock.advance(100)
        ticker.fire()
        #expect(engine.progress.completedSessions == 1)
        #expect(ticker.activeSubscriptionCount == 0)
    }

    @Test("Starts a session without granting rewards early")
    func initialSession() throws {
        let storage = try IsolatedDefaults()
        defer { storage.cleanUp() }
        let clock = TestClock()
        let engine = try MVPFactory.focus(now: { clock.time }, defaults: storage.defaults)
        #expect(engine.progress == PetProgress())
        #expect(!engine.isRunning)
        engine.setAttention(.focused)
        try engine.start(duration: 1_500)
        #expect(engine.isRunning)
        #expect(engine.remainingSeconds == 1_500)
        clock.advance(60)
        engine.refresh()
        #expect(engine.remainingSeconds == 1_440)
        #expect(engine.progress.experience == 0)
        #expect(engine.progress.coins == 0)
    }

    @Test("Unfocused states pause time and rewards", arguments: [
        AttentionMode.distracted, .idle, .sleeping
    ])
    func pauses(mode: AttentionMode) throws {
        let storage = try IsolatedDefaults()
        defer { storage.cleanUp() }
        let clock = TestClock()
        let engine = try MVPFactory.focus(now: { clock.time }, defaults: storage.defaults)
        engine.setAttention(.focused)
        try engine.start(duration: 100)
        clock.advance(20)
        engine.setAttention(mode)
        clock.advance(1_000)
        engine.refresh()
        #expect(engine.remainingSeconds == 80)
        #expect(engine.progress.completedSessions == 0)
        engine.setAttention(.focused)
        clock.advance(80)
        engine.refresh()
        #expect(engine.progress.completedSessions == 1)
    }

    @Test("Starting while distracted does not earn time until focus resumes")
    func startsPaused() throws {
        let storage = try IsolatedDefaults()
        defer { storage.cleanUp() }
        let clock = TestClock()
        let engine = try MVPFactory.focus(now: { clock.time }, defaults: storage.defaults)
        engine.setAttention(.distracted)
        try engine.start(duration: 100)
        clock.advance(1_000)
        engine.setAttention(.focused)
        #expect(engine.remainingSeconds == 100)
        #expect(engine.progress.completedSessions == 0)
        clock.advance(25)
        engine.refresh()
        #expect(engine.remainingSeconds == 75)
    }

    @Test("Completion grants exactly one reward, including delayed background ticks")
    func completesExactlyOnce() throws {
        let storage = try IsolatedDefaults()
        defer { storage.cleanUp() }
        let clock = TestClock()
        let engine = try MVPFactory.focus(now: { clock.time }, defaults: storage.defaults)
        engine.setAttention(.focused)
        try engine.start(duration: 100)
        // Simulate coalesced timer callbacks, not one decrement per callback.
        clock.advance(1_000)
        engine.refresh()
        #expect(engine.remainingSeconds == 0)
        #expect(!engine.isRunning)
        #expect(engine.progress.experience == 25)
        #expect(engine.progress.coins == 5)
        #expect(engine.progress.completedSessions == 1)
        engine.refresh()
        clock.advance(1_000)
        engine.refresh()
        #expect(engine.progress.completedSessions == 1)
        #expect(engine.progress.experience == 25)
    }

    @Test("System sleep excludes the suspended interval and wake requires fresh attention")
    func systemSleep() throws {
        let storage = try IsolatedDefaults()
        defer { storage.cleanUp() }
        let clock = TestClock()
        let engine = try MVPFactory.focus(now: { clock.time }, defaults: storage.defaults)
        engine.setAttention(.focused)
        try engine.start(duration: 100)
        clock.advance(20)
        engine.systemWillSleep()
        clock.advance(3_600)
        engine.systemDidWake()
        #expect(engine.remainingSeconds == 80)
        #expect(engine.progress.completedSessions == 0)
        clock.advance(10)
        engine.refresh()
        #expect(engine.remainingSeconds == 80)
        engine.setAttention(.focused)
        clock.advance(30)
        engine.refresh()
        #expect(engine.remainingSeconds == 50)
    }

    @Test("Repeated sleep and wake notifications do not double-count or resume early")
    func duplicatePowerEvents() throws {
        let storage = try IsolatedDefaults()
        defer { storage.cleanUp() }
        let clock = TestClock()
        let engine = try MVPFactory.focus(now: { clock.time }, defaults: storage.defaults)
        engine.setAttention(.focused)
        try engine.start(duration: 100)
        clock.advance(10)
        engine.systemWillSleep()
        clock.advance(20)
        engine.systemWillSleep()
        clock.advance(20)
        engine.systemDidWake()
        engine.systemDidWake()
        #expect(engine.remainingSeconds == 90)
        #expect(engine.progress.experience == 0)
    }

    @Test("Cancel discards partial work and a replacement session starts clean")
    func cancellation() throws {
        let storage = try IsolatedDefaults()
        defer { storage.cleanUp() }
        let clock = TestClock()
        let engine = try MVPFactory.focus(now: { clock.time }, defaults: storage.defaults)
        engine.setAttention(.focused)
        try engine.start(duration: 100)
        clock.advance(50)
        engine.cancel()
        #expect(!engine.isRunning)
        #expect(engine.progress.completedSessions == 0)
        try engine.start(duration: 100)
        clock.advance(50)
        engine.refresh()
        #expect(engine.remainingSeconds == 50)
        #expect(engine.progress.coins == 0)
    }

    @Test("An active session cannot be silently replaced")
    func doubleStart() throws {
        let storage = try IsolatedDefaults()
        defer { storage.cleanUp() }
        let clock = TestClock()
        let engine = try MVPFactory.focus(now: { clock.time }, defaults: storage.defaults)
        engine.setAttention(.focused)
        try engine.start(duration: 100)
        #expect(throws: EngineError.alreadyRunning) { try engine.start(duration: 200) }
        #expect(engine.remainingSeconds == 100)
    }

    @Test("Rejects non-positive or non-finite durations", arguments: [
        0.0, -1.0, Double.infinity, Double.nan
    ])
    func invalidDuration(duration: TimeInterval) throws {
        let storage = try IsolatedDefaults()
        defer { storage.cleanUp() }
        let engine = try MVPFactory.focus(now: { 0 }, defaults: storage.defaults)
        #expect(throws: EngineError.invalidDuration) { try engine.start(duration: duration) }
        #expect(!engine.isRunning)
    }

    @Test("Rewards, currency and selected customization survive reconstruction")
    func persistence() throws {
        let storage = try IsolatedDefaults()
        defer { storage.cleanUp() }
        let clock = TestClock()
        let engine = try MVPFactory.focus(now: { clock.time }, defaults: storage.defaults)
        engine.setAttention(.focused)
        for _ in 0..<2 {
            try engine.start(duration: 100)
            clock.advance(100)
            engine.refresh()
        }
        try engine.purchase(customization: "blue-scarf")
        try engine.select(customization: "blue-scarf")
        // No explicit save: completed rewards and purchases must persist promptly.
        let restored = try MVPFactory.focus(now: { clock.time }, defaults: storage.defaults)
        #expect(restored.progress == engine.progress)
        #expect(restored.progress.experience == 50)
        #expect(restored.progress.coins == 0)
        #expect(restored.progress.ownedCustomizations.contains("blue-scarf"))
        #expect(restored.progress.selectedCustomization == "blue-scarf")
        #expect(!restored.isRunning)
    }

    @Test("A partially completed session earns nothing while the app is closed")
    func noOfflineRewards() throws {
        let storage = try IsolatedDefaults()
        defer { storage.cleanUp() }
        let clock = TestClock()
        let engine = try MVPFactory.focus(now: { clock.time }, defaults: storage.defaults)
        engine.setAttention(.focused)
        try engine.start(duration: 100)
        clock.advance(50)
        engine.refresh()
        try engine.save()
        clock.advance(10_000)
        let restored = try MVPFactory.focus(now: { clock.time }, defaults: storage.defaults)
        #expect(!restored.isRunning)
        #expect(restored.progress == PetProgress())
    }

    @Test("Unavailable and unaffordable customizations preserve the balance")
    func purchaseValidation() throws {
        let storage = try IsolatedDefaults()
        defer { storage.cleanUp() }
        let engine = try MVPFactory.focus(now: { 0 }, defaults: storage.defaults)
        #expect(throws: EngineError.insufficientCoins) { try engine.purchase(customization: "blue-scarf") }
        #expect(throws: EngineError.unknownCustomization) { try engine.purchase(customization: "missing") }
        #expect(throws: EngineError.unknownCustomization) { try engine.select(customization: "blue-scarf") }
        #expect(engine.progress == PetProgress())
    }

    @Test("A duplicate purchase is idempotent")
    func duplicatePurchase() throws {
        let storage = try IsolatedDefaults()
        defer { storage.cleanUp() }
        let clock = TestClock()
        let engine = try MVPFactory.focus(now: { clock.time }, defaults: storage.defaults)
        engine.setAttention(.focused)
        for _ in 0..<3 {
            try engine.start(duration: 1)
            clock.advance(1)
            engine.refresh()
        }
        try engine.purchase(customization: "blue-scarf")
        try engine.purchase(customization: "blue-scarf")
        #expect(engine.progress.coins == 5)
    }

    @Test("The economy uses the injected reward policy")
    func configurableRewards() throws {
        let storage = try IsolatedDefaults()
        defer { storage.cleanUp() }
        let clock = TestClock()
        let policy = FocusPolicy(sessionExperience: 40, sessionCoins: 7, customizationPrices: [:])
        let engine = try MVPFactory.focus(now: { clock.time }, defaults: storage.defaults, policy: policy)
        engine.setAttention(.focused)
        try engine.start(duration: 10)
        clock.advance(10)
        engine.refresh()
        #expect(engine.progress.experience == 40)
        #expect(engine.progress.coins == 7)
    }
}
