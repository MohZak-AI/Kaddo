import Foundation
import PDFKit

public enum DocumentImportError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFile, unreadableFile, invalidDocument, documentTooLarge, noExtractableText
    case memoryLimitReached, importInProgress, invalidConfiguration

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: "Choose a PDF, DOCX, TXT or Markdown file."
        case .unreadableFile: "The document could not be read."
        case .invalidDocument: "The document is damaged, encrypted, or unsupported."
        case .documentTooLarge: "The document exceeds the import limits."
        case .noExtractableText: "No readable text was found. Local text recognition could not read this file."
        case .memoryLimitReached: "Document memory is full. Clear documents before importing more."
        case .importInProgress: "A document is already being imported. Try again when it finishes."
        case .invalidConfiguration: "The document chunk settings are invalid."
        }
    }
}

public struct DocumentExtractionLimits: Sendable {
    public var maxFileBytes = 20 * 1_024 * 1_024
    public var maxXMLBytes = 8 * 1_024 * 1_024
    public var maxTextBytes = 8 * 1_024 * 1_024
    public var maxPDFPages = 2_000

    public init() {}
}

/// Synchronous worker API. Emits Word text runs/breaks or one PDF page at a time.
/// Call off the main actor. The consumer must discard partial output on failure.
public struct DocumentTextExtractor: Sendable {
    public let limits: DocumentExtractionLimits
    public let includeOCR: Bool
    public let includeSourceLocations: Bool

    public init(limits: DocumentExtractionLimits = DocumentExtractionLimits(), includeOCR: Bool = true, includeSourceLocations: Bool = true) {
        self.limits = limits
        self.includeOCR = includeOCR
        self.includeSourceLocations = includeSourceLocations
    }

    public func extract(at url: URL, emit: (String) throws -> Void) throws {
        guard url.isFileURL, ["pdf", "docx"].contains(url.pathExtension.lowercased()) else {
            throw DocumentImportError.unsupportedFile
        }
        guard limits.maxFileBytes > 0, limits.maxFileBytes < Int.max,
              limits.maxXMLBytes > 0, limits.maxTextBytes > 0, limits.maxPDFPages > 0 else {
            throw DocumentImportError.documentTooLarge
        }
        try Task.checkCancellation()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw DocumentImportError.unreadableFile }
            guard let size = values.fileSize, size <= limits.maxFileBytes else {
                throw DocumentImportError.documentTooLarge
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: limits.maxFileBytes + 1) ?? Data()
            guard data.count <= limits.maxFileBytes else { throw DocumentImportError.documentTooLarge }
        } catch let error as DocumentImportError {
            throw error
        } catch {
            throw DocumentImportError.unreadableFile
        }
        var textBytes = 0
        var hasText = false
        func output(_ text: String) throws {
            try Task.checkCancellation()
            let count = text.utf8.count
            guard count <= limits.maxTextBytes - textBytes else {
                throw DocumentImportError.documentTooLarge
            }
            textBytes += count
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasText = true }
            try emit(text)
        }
        if url.pathExtension.lowercased() == "docx" {
            let xml = try WordZIPArchive.documentXML(in: data, maxBytes: limits.maxXMLBytes)
            let images = WordImageReader(archive: data)
            try WordXMLTextReader.read(xml, emit: output, imageText: includeOCR ? { images.text(for: $0) } : nil)
        } else {
            guard data.starts(with: Data("%PDF-".utf8)),
                  let document = PDFDocument(data: data), !document.isEncrypted,
                  document.pageCount > 0 else { throw DocumentImportError.invalidDocument }
            guard document.pageCount <= limits.maxPDFPages else {
                throw DocumentImportError.documentTooLarge
            }
            var ocrPages = 0
            let ocrDeadline = Date().addingTimeInterval(60)
            for index in 0..<document.pageCount {
                try autoreleasepool {
                    try Task.checkCancellation()
                    guard let page = document.page(at: index) else {
                        throw DocumentImportError.invalidDocument
                    }
                    let nativeText = page.string ?? ""
                    if nativeText.filter({ $0.isLetter || $0.isNumber }).count >= 40 {
                        try output((includeSourceLocations ? "[Page \(index + 1)]\n" : "") + nativeText)
                    } else if !includeOCR {
                        try output(nativeText)
                    } else if ocrPages < 80, Date() < ocrDeadline {
                        ocrPages += 1
                        if let image = LocalDocumentOCR.pageImage(page), let result = try? LocalDocumentOCR.recognize(image), !result.text.isEmpty {
                            try output("[Page \(index + 1): local OCR; confidence \(String(format: "%.2f", result.confidence))]\n" + result.text)
                        } else if !nativeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            try output("[Page \(index + 1): local OCR unavailable]\n" + nativeText)
                        }
                    } else {
                        try output("[Page \(index + 1): local OCR limit reached; visual content not read]\n" + nativeText)
                    }
                    try output("\n")
                }
            }
        }
        guard hasText else { throw DocumentImportError.noExtractableText }
    }
}
