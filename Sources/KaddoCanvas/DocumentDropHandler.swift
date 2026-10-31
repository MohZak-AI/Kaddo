import AppKit
import UniformTypeIdentifiers

public enum DocumentDropTypes {
    public static let word = UTType(importedAs: "org.openxmlformats.wordprocessingml.document",
                                    conformingTo: .zip)
    // Finder transports document paths as file URLs; validate the resolved extension too.
    public static let supported: [UTType] = [.pdf, word, .plainText, .fileURL]

    public static func accepts(_ url: URL) -> Bool {
        url.isFileURL && ["pdf", "docx", "txt", "md"].contains(url.pathExtension.lowercased())
    }
}

@MainActor
enum DocumentDropHandler {
    static func receive(
        _ providers: [NSItemProvider],
        onURL: @escaping @MainActor @Sendable (URL) -> Void,
        onFailure: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        let candidates = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !candidates.isEmpty else { return false }
        // Begin loading inside onDrop; NSItemProvider grants access in this scope.
        for provider in candidates {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let value = item as? URL {
                    url = value
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? String {
                    url = URL(string: value)
                } else {
                    url = nil
                }
                Task { @MainActor in
                    guard let url, DocumentDropTypes.accepts(url) else {
                        onFailure()
                        return
                    }
                    onURL(url)
                }
            }
        }
        return true
    }
}
