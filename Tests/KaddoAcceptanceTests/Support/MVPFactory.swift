import AppKit
import Foundation

struct PendingImplementation: Error, CustomStringConvertible {
    let scope: String
    var description: String { "MVP pending: \(scope). Wire this factory to the real engine." }
}

// The only integration seam to replace when implementing the MVP. These throws
// make the test-first state executable and RED, without fake engine behavior.
@MainActor
enum MVPFactory {
    static func overlay(mask: SpriteMask) throws -> any OverlayDriver {
        throw PendingImplementation(scope: "native overlay")
    }

    static func attention(
        configuration: AttentionConfiguration = .init(),
        notificationCenter: NotificationCenter,
        idleSeconds: @escaping () -> TimeInterval,
        frontmostApp: @escaping () -> ForegroundApp?
    ) throws -> any AttentionEngine {
        throw PendingImplementation(scope: "workspace attention")
    }

    static func documents(limits: DocumentLimits = .init()) throws -> any DocumentEngine {
        throw PendingImplementation(scope: "offline document retrieval")
    }

    static func assistant(
        configuration: OllamaConfiguration = .init(),
        session: URLSession
    ) throws -> any LocalAssistant {
        throw PendingImplementation(scope: "local Ollama synthesis")
    }

    static func focus(
        now: @escaping () -> TimeInterval,
        defaults: UserDefaults,
        policy: FocusPolicy = .init(),
        ticker: any FocusTicker = ManualTicker()
    ) throws -> any FocusEngine {
        throw PendingImplementation(scope: "focus loop and persistence")
    }
}
