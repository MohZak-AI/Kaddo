import Foundation

public enum PetLayoutCategory: String, CaseIterable, Sendable {
    case coding, communication, general
}

/// Exact normalized bundle matching avoids classifying lookalike/prefix identifiers.
public final class ApplicationContextMapper: Sendable {
    private let codingBundleIdentifiers: Set<String>
    private let communicationBundleIdentifiers: Set<String>

    /// Coding takes precedence if a configuration includes an identifier in both sets.
    public init(
        codingBundleIdentifiers: Set<String> = [
            "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.jetbrains.intellij"
        ],
        communicationBundleIdentifiers: Set<String> = [
            "com.tinyspeck.slackmacgap", "com.hnc.Discord"
        ]
    ) {
        self.codingBundleIdentifiers = Set(codingBundleIdentifiers.compactMap(Self.normalize))
        self.communicationBundleIdentifiers = Set(
            communicationBundleIdentifiers.compactMap(Self.normalize)
        )
    }

    public static func normalize(_ bundleIdentifier: String?) -> String? {
        guard let value = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        return value
    }

    public func category(for bundleIdentifier: String?) -> PetLayoutCategory {
        guard let identifier = Self.normalize(bundleIdentifier) else { return .general }
        if codingBundleIdentifiers.contains(identifier) { return .coding }
        if communicationBundleIdentifiers.contains(identifier) { return .communication }
        return .general
    }
}
