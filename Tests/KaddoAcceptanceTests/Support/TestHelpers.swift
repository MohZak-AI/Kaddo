import Foundation
import Testing

func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

// URLSession adds diagnostic userInfo to URLError. Compare the error code,
// rather than NSError equality, which includes that nondeterministic metadata.
@MainActor
func expectURLError(_ code: URLError.Code, operation: @MainActor () async throws -> Void) async throws {
    do {
        try await operation()
        Issue.record("Expected URLError code \(code.rawValue), but the operation succeeded")
    } catch let error as URLError {
        #expect(error.code == code)
    } catch {
        throw error
    }
}

@MainActor
final class TestClock {
    private(set) var time: TimeInterval = 0
    func advance(_ seconds: TimeInterval) { time += seconds }
}

@MainActor
final class ManualTicker: FocusTicker {
    private final class Subscription: TimerSubscription {
        let tick: @MainActor () -> Void
        var isCancelled = false
        init(tick: @escaping @MainActor () -> Void) { self.tick = tick }
        func cancel() { isCancelled = true }
    }

    private var subscriptions: [Subscription] = []
    var activeSubscriptionCount: Int { subscriptions.filter { !$0.isCancelled }.count }

    func subscribe(_ tick: @escaping @MainActor () -> Void) -> any TimerSubscription {
        let subscription = Subscription(tick: tick)
        subscriptions.append(subscription)
        return subscription
    }

    func fire() {
        for subscription in subscriptions where !subscription.isCancelled {
            subscription.tick()
        }
    }
}

@MainActor
final class IsolatedDefaults {
    let suiteName = "Kaddo.Tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suiteName) }
}
