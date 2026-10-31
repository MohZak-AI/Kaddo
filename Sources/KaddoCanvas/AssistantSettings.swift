import Combine
import Foundation
import Security

@MainActor
public protocol AssistantCredentialStore: AnyObject {
    func read() throws -> String?
    func save(_ key: String) throws
    func remove() throws
}

@MainActor
public final class KeychainAssistantCredentialStore: AssistantCredentialStore {
    private let service: String
    public init(service: String = "com.kaddo.openai") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "personal-api-key"]
    }
    public func read() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw AssistantError.keychain(status) }
        return key
    }
    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw AssistantError.keychain(status) }
        } else if update != errSecSuccess { throw AssistantError.keychain(update) }
    }
    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AssistantError.keychain(status) }
    }
}

/// Local credential storage for temporary DeepSeek keys; never stored in the project.
@MainActor
public final class FileAssistantCredentialStore: AssistantCredentialStore {
    private let url: URL
    public init(url: URL) { self.url = url }
    static var deepSeekURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kaddo/Credentials/deepseek-api-key")
    }
    public func read() throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public func save(_ key: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data(key.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// Used by tests and ephemeral previews; production uses Keychain.
@MainActor
public final class MemoryAssistantCredentialStore: AssistantCredentialStore {
    private var key: String?
    public init(key: String? = nil) { self.key = key }
    public func read() throws -> String? { key }
    public func save(_ key: String) throws { self.key = key }
    public func remove() throws { key = nil }
}

@MainActor
public final class AssistantSettings: ObservableObject {
    public enum Provider: String, CaseIterable, Sendable {
        case openAI, deepSeek, ollama
        public var isCloud: Bool { self != .ollama }
        public var cloudName: String { self == .deepSeek ? "DeepSeek" : "OpenAI" }
    }
    @Published public var provider: Provider {
        didSet {
            testTask?.cancel(); testGeneration = UUID(); isTesting = false
            cloudModel = defaults?.string(forKey: modelPreferenceKey) ?? (provider == .deepSeek ? "deepseek-flash" : "gpt-6.1-sol")
            refreshCredentialStatus()
            persist()
        }
    }
    @Published public var cloudModel: String { didSet { persist() } }
    public var cloudName: String { provider.cloudName }
    public var credentialLocation: String { provider == .deepSeek ? "a local file on this Mac" : "macOS Keychain" }
    private var modelPreferenceKey: String { provider == .deepSeek ? "assistant.deepSeekModel" : "assistant.cloudModel" }
    private var activeCredentials: any AssistantCredentialStore { provider == .deepSeek ? deepSeekCredentials : credentials }
    @Published public private(set) var status = "Add a personal API key to enable OpenAI."
    @Published public private(set) var hasKey = false
    @Published public private(set) var isTesting = false
    private let deepSeekCredentials: any AssistantCredentialStore
    private let credentials: any AssistantCredentialStore
    private let defaults: UserDefaults?
    private var testTask: Task<Void, Never>?
    private var testGeneration = UUID()

    public init(credentials: any AssistantCredentialStore = MemoryAssistantCredentialStore(),
                defaults: UserDefaults? = nil, deepSeekCredentials: any AssistantCredentialStore = MemoryAssistantCredentialStore()) {
        self.deepSeekCredentials = deepSeekCredentials
        self.credentials = credentials; self.defaults = defaults
        let selected = defaults?.string(forKey: "assistant.provider").flatMap(Provider.init(rawValue:)) ?? .ollama
        provider = selected
        cloudModel = defaults?.string(forKey: selected == .deepSeek ? "assistant.deepSeekModel" : "assistant.cloudModel")
            ?? (selected == .deepSeek ? "deepseek-flash" : "gpt-6.1-sol")
        refreshCredentialStatus()
    }

    private func refreshCredentialStatus() {
        do {
            hasKey = try activeCredentials.read()?.isEmpty == false
            status = hasKey ? "\(cloudName) key saved in \(credentialLocation)." : "Add a personal API key to enable \(cloudName)."
        } catch { status = error.localizedDescription }
    }

    static func live() -> AssistantSettings {
        AssistantSettings(credentials: KeychainAssistantCredentialStore(), defaults: .standard,
            deepSeekCredentials: FileAssistantCredentialStore(url: FileAssistantCredentialStore.deepSeekURL))
    }

    private func persist() {
        defaults?.set(provider.rawValue, forKey: "assistant.provider")
        defaults?.set(cloudModel, forKey: modelPreferenceKey)
    }

    public func saveKey(_ value: String) {
        testTask?.cancel(); testGeneration = UUID(); isTesting = false
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
            status = "Enter an API key without spaces."; return
        }
        do {
            try activeCredentials.save(key)
            if provider == .ollama { provider = .openAI }
            hasKey = true
            status = "Key saved in \(credentialLocation). \(cloudName) is selected. API usage is billed to your account."
        } catch { status = error.localizedDescription }
    }

    public func removeKey() {
        testTask?.cancel(); testGeneration = UUID(); isTesting = false
        do { try activeCredentials.remove(); hasKey = false; status = "\(cloudName) key removed. Choose Ollama to use local AI." }
        catch { status = error.localizedDescription }
    }

    func cloudProvider(session: URLSession? = nil) throws -> OpenAIAssistantProvider {
        guard let key = try activeCredentials.read(), !key.isEmpty else { throw AssistantError.missingKey }
        return OpenAIAssistantProvider(apiKey: key, model: cloudModel, session: session,
            service: provider == .deepSeek ? .deepSeek : .openAI)
    }

    public func testConnection(provider: (any AssistantProvider)? = nil) {
        testTask?.cancel(); isTesting = true
        let ticket = UUID(); testGeneration = ticket
        testTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.testGeneration == ticket { self.isTesting = false } }
            do {
                let provider = try provider ?? self.cloudProvider()
                _ = try await provider.respond(to: AssistantRequest(instructions: "Reply with OK.",
                    input: [.message("Connection test")], toolsEnabled: false))
                try Task.checkCancellation()
                guard self.testGeneration == ticket else { return }
                self.status = "Connected to \(cloudName) · \(self.cloudModel)"
            } catch {
                if !Task.isCancelled, self.testGeneration == ticket { self.status = error.localizedDescription }
            }
        }
    }
}
