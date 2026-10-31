import Foundation

private final class WordXMLDelegate: NSObject, XMLParserDelegate {
    private let emit: (String) throws -> Void
    var imageText: ((String) -> String)?
    private var textDepth = 0
    private(set) var failure: Error?
    private(set) var hasDocument = false
    private var elementDepth = 0
    private static let namespaces = [
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        "http://purl.oclc.org/ooxml/wordprocessingml/main"
    ]

    init(emit: @escaping (String) throws -> Void) { self.emit = emit }

    private func output(_ text: String, parser: XMLParser) {
        guard failure == nil else { return }
        do { try emit(text) } catch {
            failure = error
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        elementDepth += 1
        guard elementDepth <= 256 else {
            failure = DocumentImportError.invalidDocument
            parser.abortParsing()
            return
        }
        if name == "blip", let id = attributes.first(where: { $0.key.hasSuffix(":embed") })?.value, let imageText {
            output("\n" + imageText(id) + "\n", parser: parser)
        } else if name == "imagedata", let id = attributes.first(where: { $0.key.hasSuffix(":id") })?.value, let imageText {
            output("\n" + imageText(id) + "\n", parser: parser)
        }
        guard Self.namespaces.contains(namespaceURI ?? "") else { return }
        if name == "document", elementDepth == 1 { hasDocument = true }
        if name == "t" { textDepth += 1 }
        if name == "tab" { output("\t", parser: parser) }
        if name == "br" || name == "cr" { output("\n", parser: parser) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        defer { elementDepth -= 1 }
        guard Self.namespaces.contains(namespaceURI ?? "") else { return }
        if name == "t" { textDepth -= 1 }
        if name == "p" || name == "tr" { output("\n", parser: parser) }
        if name == "tc" { output("\t", parser: parser) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textDepth > 0 { output(string, parser: parser) }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if textDepth > 0, let text = String(data: data, encoding: .utf8) {
            output(text, parser: parser)
        }
    }
}

enum WordXMLTextReader {
    static func read(_ data: Data, emit: (String) throws -> Void, imageText: ((String) -> String)? = nil) throws {
        // Reject DTDs before parsing, including UTF-16 encodings, to prevent entity
        // expansion as well as network/file entity resolution. Word needs no DTD.
        let encoding: String.Encoding
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0x3c, 0, 0x3f, 0]) {
            encoding = .utf16LittleEndian
        } else if data.starts(with: [0xfe, 0xff]) || data.starts(with: [0, 0x3c, 0, 0x3f]) {
            encoding = .utf16BigEndian
        } else {
            encoding = .utf8
        }
        guard let text = String(data: data, encoding: encoding), !text.contains("\0"),
              !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else {
            throw DocumentImportError.invalidDocument
        }
        // Reject declarations that ask XMLParser to reinterpret the bytes using
        // an encoding other than the UTF-8/UTF-16 encoding inspected above.
        if let declarationEnd = text.range(of: "?>"), text.contains("<?xml") {
            let declaration = String(text[..<declarationEnd.upperBound])
            let pattern = #"encoding\s*=\s*["']([^"']+)["']"#
            if let match = declaration.range(of: pattern, options: .regularExpression) {
                let attribute = declaration[match]
                let encodingName = attribute.split(whereSeparator: { $0 == "\"" || $0 == "'" })
                    .dropFirst().first?.uppercased()
                guard ["UTF-8", "UTF-16", "UTF-16LE", "UTF-16BE"].contains(encodingName ?? "") else {
                    throw DocumentImportError.invalidDocument
                }
            }
        }
        try withoutActuallyEscaping(emit) { callback in
            let delegate = WordXMLDelegate(emit: callback)
            delegate.imageText = imageText
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            parser.delegate = delegate
            let success = parser.parse()
            if let failure = delegate.failure { throw failure }
            guard success, delegate.hasDocument else { throw DocumentImportError.invalidDocument }
        }
    }
}
