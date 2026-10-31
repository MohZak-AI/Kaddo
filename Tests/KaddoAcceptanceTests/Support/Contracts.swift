import AppKit
import Foundation

// Test-owned acceptance contracts. Move/adapt these at the production boundary
// when implementing the MVP; there is intentionally no app implementation yet.
enum AttentionMode: String, Codable, Sendable {
    case focused, distracted, idle, sleeping
}

struct ForegroundApp: Equatable, Sendable {
    let bundleID: String
    let name: String
}

struct AttentionConfiguration: Sendable {
    var focusedBundleIDs: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.jetbrains.intellij"
    ]
    var distractedBundleIDs: Set<String> = ["com.tinyspeck.slackmacgap", "com.hnc.Discord"]
    var idleThreshold: TimeInterval = 600
}

@MainActor
protocol AttentionEngine: AnyObject {
    var mode: AttentionMode { get }
    var foregroundApp: ForegroundApp? { get }
    func start()
    func stop()
    func refreshIdleState()
}

struct SpriteMask: Sendable {
    let width: Int
    let height: Int
    // Top-left origin, row-major. Zero is click-through; any visible alpha hits.
    let alpha: [UInt8]
    let scale: Double
}

@MainActor
protocol OverlayDriver: AnyObject {
    var window: NSWindow { get }
    var onFilesDropped: (([URL]) -> Void)? { get set }
    func isInteractive(at localPoint: NSPoint) -> Bool
    func updatePointer(globalPoint: NSPoint)
    func movePet(by delta: NSSize)
    func replaceSprite(with mask: SpriteMask) throws
    func setFileDragActive(_ active: Bool)
    func acceptDrop(urls: [URL], at localPoint: NSPoint) -> Bool
}

enum EngineError: Error, Equatable {
    case invalidConfiguration
    case unsupportedFile
    case invalidDocument
    case documentTooLarge
    case noExtractableText
    case noRelevantContext
    case serviceUnavailable
    case modelUnavailable
    case httpStatus(Int)
    case malformedResponse
    case invalidDuration
    case alreadyRunning
    case insufficientCoins
    case unknownCustomization
    case corruptedSave
}

struct DocumentLimits: Sendable {
    var maxFileBytes = 10 * 1_024 * 1_024
    var maxExtractedCharacters = 200_000
    var chunkCharacters = 400
    var overlapCharacters = 80
}

struct DocumentChunk: Equatable, Sendable {
    let id: String
    let documentID: String
    let filename: String
    let text: String
    let page: Int?
}

struct ImportedDocument: Sendable {
    let id: String
    let filename: String
    let chunks: [DocumentChunk]
}

@MainActor
protocol DocumentEngine: AnyObject {
    var documents: [ImportedDocument] { get }
    func importDocument(at url: URL) async throws -> ImportedDocument
    func retrieve(question: String, limit: Int, characterBudget: Int) throws -> [DocumentChunk]
    func removeDocument(id: String)
    func clear()
}

struct OllamaConfiguration: Sendable {
    var baseURL = URL(string: "http://127.0.0.1:11434")!
    var model = "llama3.1:8b"
    var timeout: TimeInterval = 120
    var contextCharacterBudget = 4_000
}

struct GroundedAnswer: Sendable {
    let text: String
    let sources: [DocumentChunk]
}

@MainActor
protocol LocalAssistant {
    func answer(question: String, context: [DocumentChunk]) async throws -> GroundedAnswer
}

struct PetProgress: Codable, Equatable, Sendable {
    var experience = 0
    var coins = 0
    var completedSessions = 0
    var selectedCustomization = "default"
    var ownedCustomizations: Set<String> = ["default"]
}

struct FocusPolicy: Sendable {
    // Test economy, configurable rather than a fixed product decision.
    var sessionExperience = 25
    var sessionCoins = 5
    var customizationPrices = ["blue-scarf": 10]
}

@MainActor
protocol TimerSubscription: AnyObject {
    func cancel()
}

@MainActor
protocol FocusTicker: AnyObject {
    func subscribe(_ tick: @escaping @MainActor () -> Void) -> any TimerSubscription
}

@MainActor
protocol FocusEngine: AnyObject {
    var progress: PetProgress { get }
    var remainingSeconds: TimeInterval { get }
    var isRunning: Bool { get }
    // The caller supplies event timestamps through the injected monotonic clock.
    func start(duration: TimeInterval) throws
    func setAttention(_ mode: AttentionMode)
    func refresh()
    func systemWillSleep()
    func systemDidWake()
    func cancel()
    func purchase(customization: String) throws
    func select(customization: String) throws
    func save() throws
}
