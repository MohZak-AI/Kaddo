import Foundation
import Darwin

public struct AgentFolderGrant: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let bookmark: Data

    public init(id: UUID = UUID(), name: String, bookmark: Data) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
    }
}

public struct AgentSourceExcerpt: Sendable {
    public let id: UUID
    public let title: String
    public let text: String
    public let url: URL

    public init(id: UUID = UUID(), title: String, text: String, url: URL) {
        self.id = id
        self.title = title
        self.text = text
        self.url = url
    }
}

public enum AgentSourceError: Error, LocalizedError, Equatable, Sendable {
    case invalidGrant, staleGrant, accessDenied, invalidPath, unsupportedType, tooLarge
    case emptyText, unsafeURL, resolutionFailed, invalidResponse, tooManyRedirects

    public var errorDescription: String? {
        switch self {
        case .invalidGrant: "Choose the source folder again."
        case .staleGrant: "The folder permission has expired. Choose the folder again."
        case .accessDenied: "The source is no longer accessible. Choose the folder again."
        case .invalidPath: "The requested file must be inside the approved folder."
        case .unsupportedType: "Only text, Markdown, PDF, Word, or readable web pages are supported."
        case .tooLarge: "The source exceeds the reading limit."
        case .emptyText: "The source contains no readable text."
        case .unsafeURL: "Choose a public HTTPS web page."
        case .resolutionFailed: "The web address could not be resolved safely."
        case .invalidResponse: "The web page could not be read."
        case .tooManyRedirects: "The web page redirected too many times."
        }
    }
}

struct AgentSourceHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

/// Bounded, read-only access to explicitly approved folders and public web pages.
public struct AgentSourceReader: Sendable {
    static let maximumFileBytes = 8 * 1_024 * 1_024
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    static let maximumExcerptCharacters = 6_000
    private static let extensions: Set<String> = ["txt", "md", "pdf", "docx"]
    private let resolveBookmark: @Sendable (Data) throws -> URL
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void
    private let resolveHost: @Sendable (String) async throws -> [String]
    private let requestTimeout: TimeInterval
    private let transport: @Sendable (URL, String, TimeInterval) async throws -> AgentSourceHTTPResponse

    public init() {
        self.init(resolveBookmark: Self.resolve, startAccess: { $0.startAccessingSecurityScopedResource() },
                  stopAccess: { $0.stopAccessingSecurityScopedResource() }, resolveHost: Self.addresses)
    }

    // Seams keep filesystem and address-policy tests independent of OS permission UI and live DNS.
    init(resolveBookmark: @escaping @Sendable (Data) throws -> URL,
         startAccess: @escaping @Sendable (URL) -> Bool = { _ in true },
         stopAccess: @escaping @Sendable (URL) -> Void = { _ in },
         resolveHost: @escaping @Sendable (String) async throws -> [String] = Self.addresses,
         transport: @escaping @Sendable (URL, String, TimeInterval) async throws -> AgentSourceHTTPResponse = Self.curl, requestTimeout: TimeInterval = 20) {
        self.resolveBookmark = resolveBookmark
        self.startAccess = startAccess
        self.stopAccess = stopAccess
        self.resolveHost = resolveHost
        self.transport = transport
        self.requestTimeout = requestTimeout
    }

    public static func createGrant(url: URL) async throws -> AgentFolderGrant {
        try await SourceOperationDeadline.run(seconds: 5) {
            try await Task.detached { try grant(url: url) }.value
        }
    }
    public static func grant(url: URL) throws -> AgentFolderGrant {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AgentSourceError.invalidGrant
        }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
        return AgentFolderGrant(name: url.lastPathComponent, bookmark: bookmark)
    }

    public func list(grant: AgentFolderGrant, query: String? = nil) async throws -> [String] {
        try Task.checkCancellation()
        let root = try await SourceOperationDeadline.run(seconds: 5) { try approvedRoot(grant) }
        defer { withExtendedLifetime(root) {} }
        let descriptor = try Self.openDirectory(root.physicalPath)
        defer { Darwin.close(descriptor) }
        var scanned = 0, characterCount = 0
        var results: [String] = []
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func scan(_ parent: Int32, prefix: String, depth: Int) throws {
            guard depth < 64, scanned < 1_000, results.count < 100 else { return }
            guard let directory = fdopendir(dup(parent)) else { throw AgentSourceError.accessDenied }
            defer { closedir(directory) }
            while let entry = readdir(directory), scanned < 1_000, results.count < 100 {
                try Task.checkCancellation()
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                guard name != ".", name != ".." else { continue }
                scanned += 1
                guard !name.hasPrefix(".") else { continue }
                let child = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { continue }
                defer { Darwin.close(child) }
                var info = stat()
                guard fstat(child, &info) == 0 else { continue }
                let path = prefix + name
                if (info.st_mode & S_IFMT) == S_IFDIR {
                    guard !["app", "bundle", "framework", "pkg", "pages", "numbers", "key"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else { continue }
                    try scan(child, prefix: path + "/", depth: depth + 1)
                } else if (info.st_mode & S_IFMT) == S_IFREG,
                          Self.extensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()),
                          query.isEmpty || path.localizedCaseInsensitiveContains(query) {
                    guard characterCount + path.count + 1 <= Self.maximumExcerptCharacters else { continue }
                    results.append(path); characterCount += path.count + 1
                }
            }
        }
        try scan(descriptor, prefix: "", depth: 0)
        return results.sorted()
    }

    public func read(grant: AgentFolderGrant, relativePath: String) async throws -> AgentSourceExcerpt {
        try Task.checkCancellation()
        let root = try await SourceOperationDeadline.run(seconds: 5) { try approvedRoot(grant) }
        defer { withExtendedLifetime(root) {} }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AgentSourceError.invalidPath
        }
        let url = root.canonicalURL.appendingPathComponent(relativePath).standardizedFileURL
        guard Self.isInside(url, root: root.canonicalURL) else { throw AgentSourceError.invalidPath }
        guard Self.extensions.contains(url.pathExtension.lowercased()) else { throw AgentSourceError.unsupportedType }
        var descriptor = try Self.openDirectory(root.physicalPath)
        for (index, component) in components.enumerated() {
            let directoryFlag: Int32 = index == components.count - 1 ? 0 : O_DIRECTORY
            let next = openat(descriptor, String(component), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | directoryFlag)
            Darwin.close(descriptor)
            guard next >= 0 else { throw AgentSourceError.invalidPath }
            descriptor = next
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw AgentSourceError.accessDenied }
        guard info.st_size >= 0, info.st_size <= Self.maximumFileBytes else { throw AgentSourceError.tooLarge }
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes else { throw AgentSourceError.tooLarge }
        try Task.checkCancellation()
        var text = ""
        if ["pdf", "docx"].contains(url.pathExtension.lowercased()) {
            var limits = DocumentExtractionLimits()
            limits.maxFileBytes = Self.maximumFileBytes
            // The extractor receives an immutable snapshot of the descriptor we validated,
            // never a pathname the source owner could replace after validation.
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("KaddoSource-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: staging) }
            let snapshot = staging.appendingPathComponent("source." + url.pathExtension.lowercased())
            try data.write(to: snapshot, options: .atomic)
            do {
                try DocumentTextExtractor(limits: limits).extract(at: snapshot) { fragment in
                    try Task.checkCancellation()
                    text += fragment.prefix(Self.maximumExcerptCharacters - text.count)
                    if text.count == Self.maximumExcerptCharacters { throw ExcerptComplete.done }
                }
            } catch ExcerptComplete.done { /* Enough source text has been extracted. */ }
        } else {
            guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                throw AgentSourceError.unsupportedType
            }
            text = String(decoded.prefix(Self.maximumExcerptCharacters))
        }
        try Task.checkCancellation()
        return try Self.excerpt(text, title: url.lastPathComponent, url: url)
    }

    public func fetch(url: URL) async throws -> AgentSourceExcerpt {
        try Task.checkCancellation()
        let deadline = Date().addingTimeInterval(requestTimeout)
        var current = url
        for redirects in 0...3 {
            try Task.checkCancellation()
            let addressURL = current
            let addresses = try await SourceOperationDeadline.run(seconds: deadline.timeIntervalSinceNow) {
                try await validatedAddresses(addressURL)
            }
            guard Date() < deadline else { throw URLError(.timedOut) }
            let remaining = deadline.timeIntervalSinceNow
            let response = try await SourceOperationDeadline.run(seconds: remaining) {
                try await transport(addressURL, addresses[0], remaining)
            }
            try Task.checkCancellation()
            guard Date() < deadline else { throw URLError(.timedOut) }
            if [301, 302, 303, 307, 308].contains(response.status) {
                guard redirects < 3 else { throw AgentSourceError.tooManyRedirects }
                guard let location = response.headers["location"],
                      let destination = URL(string: location, relativeTo: current)?.absoluteURL else {
                    throw AgentSourceError.invalidResponse
                }
                current = destination
                continue
            }
            guard (200..<300).contains(response.status) else { throw AgentSourceError.invalidResponse }
            let mime = response.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard ["text/html", "text/plain", "text/markdown"].contains(mime) else {
                throw AgentSourceError.unsupportedType
            }
            let data = response.body
            guard data.count <= Self.maximumResponseBytes else { throw AgentSourceError.tooLarge }
            guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw AgentSourceError.emptyText
            }
            let text = mime == "text/html" ? Self.readableHTML(decoded) : decoded
            return try Self.excerpt(text, title: current.host ?? current.lastPathComponent, url: current)
        }
        throw AgentSourceError.tooManyRedirects
    }

    /// Walk every absolute path component without following links, then keep the directory FD.
    private static func openDirectory(_ physicalPath: String) throws -> Int32 {
        let components = physicalPath.split(separator: "/").map(String.init)
        var descriptor = Darwin.open("/", components.isEmpty ? O_RDONLY | O_DIRECTORY | O_CLOEXEC : O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentSourceError.accessDenied }
        for (index, component) in components.enumerated() {
            let access: Int32 = index == components.count - 1 ? O_RDONLY : O_EVTONLY
            let next = openat(descriptor, component, access | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(descriptor)
            guard next >= 0 else { throw AgentSourceError.invalidPath }
            descriptor = next
        }
        return descriptor
    }

    private enum ExcerptComplete: Error { case done }

    private static func excerpt(_ text: String, title: String, url: URL) throws -> AgentSourceExcerpt {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumExcerptCharacters))
        guard !text.isEmpty else { throw AgentSourceError.emptyText }
        return AgentSourceExcerpt(title: title, text: text, url: url)
    }

    private static func resolve(_ data: Data) throws -> URL {
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch { throw AgentSourceError.invalidGrant }
        guard !stale else { throw AgentSourceError.staleGrant }
        return url
    }

    private func approvedRoot(_ grant: AgentFolderGrant) throws -> SourceRootLease {
        let scoped = try resolveBookmark(grant.bookmark)
        guard scoped.isFileURL, startAccess(scoped) else { throw AgentSourceError.accessDenied }
        do {
            // Retain the physical spelling here: Foundation can shorten /private/var to /var,
            // which is a symlink. Never resolve this path again after validation.
            guard let resolved = realpath(scoped.path, nil) else { throw AgentSourceError.accessDenied }
            let physicalPath = String(cString: resolved)
            free(resolved)
            let root = scoped.resolvingSymlinksInPath().standardizedFileURL
            guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw AgentSourceError.accessDenied
            }
            return SourceRootLease(scopedURL: scoped, canonicalURL: root, physicalPath: physicalPath, stopAccess: stopAccess)
        } catch {
            stopAccess(scoped)
            throw AgentSourceError.accessDenied
        }
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        url.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") && url.path != root.path
    }

    func validateURL(_ url: URL) async throws {
        _ = try await validatedAddresses(url)
    }

    private func validatedAddresses(_ url: URL) async throws -> [String] {
        let host = try Self.publicHTTPSHost(url)
        let addresses = try await resolveHost(host)
        try Task.checkCancellation()
        guard !addresses.isEmpty, addresses.allSatisfy(Self.isPublicAddress) else {
            throw AgentSourceError.unsafeURL
        }
        return addresses
    }

    static func publicHTTPSHost(_ url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, var host = parts.host?.lowercased(),
              !host.isEmpty, !host.contains("%") else { throw AgentSourceError.unsafeURL }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host != "localhost", !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
              !host.hasSuffix(".home"), !host.hasSuffix(".lan") else { throw AgentSourceError.unsafeURL }
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) {
            guard isPublicAddress(host) else { throw AgentSourceError.unsafeURL }
        } else {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count > 1, labels.allSatisfy({ label in
                !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                    && label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            }), labels.last?.allSatisfy({ $0.isNumber }) == false else { throw AgentSourceError.unsafeURL }
        }
        return host
    }

    static func isPublicAddress(_ address: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            let a = Int(bytes[0]), b = Int(bytes[1]), c = Int(bytes[2])
            return !(a == 0 || a == 10 || a == 127 || a >= 224
                || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254)
                || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                || (a == 192 && b == 0 && (c == 0 || c == 2))
                || (a == 192 && b == 88 && c == 99) || (a == 198 && (b == 18 || b == 19))
                || (a == 198 && b == 51 && c == 100) || (a == 203 && b == 0 && c == 113))
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, address, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        // Only native global unicast; exclude special-use, transition and documentation ranges.
        return bytes[0] & 0xe0 == 0x20
            && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] < 2)
            && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8)
            && !(bytes[0] == 0x20 && bytes[1] == 0x02)
            && !(bytes[0] == 0x3f && bytes[1] & 0xf0 == 0xf0)
    }

    static func addresses(_ host: String) async throws -> [String] {
        try Task.checkCancellation()
        let addresses = try await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else {
                throw AgentSourceError.resolutionFailed
            }
            defer { freeaddrinfo(first) }
            var addresses: [String] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let item = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &buffer,
                                  socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
                    throw AgentSourceError.resolutionFailed
                }
                addresses.append(String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
                cursor = item.pointee.ai_next
            }
            return addresses
        }.value
        try Task.checkCancellation()
        return addresses
    }

    static func readableHTML(_ html: String) -> String {
        // Scan once: regex tag stripping can backtrack quadratically on malformed pages.
        let bytes = Array(html.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(min(bytes.count, maximumResponseBytes))
        var index = 0
        var suppressed: String?
        func matches(_ token: String, at offset: Int) -> Bool {
            let pattern = Array(token.utf8)
            guard offset + pattern.count <= bytes.count else { return false }
            for position in pattern.indices {
                let byte = bytes[offset + position]
                let lower = (65...90).contains(byte) ? byte + 32 : byte
                if lower != pattern[position] { return false }
            }
            return true
        }
        while index < bytes.count {
            if let name = suppressed {
                let end = index + 2 + name.utf8.count
                if matches("</" + name, at: index), end < bytes.count,
                   [9, 10, 12, 13, 32, 47, 62].contains(bytes[end]) { suppressed = nil }
                else { index += 1; continue }
            }
            guard bytes[index] == 60 else { output.append(bytes[index]); index += 1; continue }
            if matches("<!--", at: index) {
                index += 4
                while index < bytes.count, !matches("-->", at: index) { index += 1 }
                index = min(bytes.count, index + 3)
                output.append(32)
                continue
            }
            index += 1
            let closing = index < bytes.count && bytes[index] == 47
            if closing { index += 1 }
            let nameStart = index
            while index < bytes.count, (65...90).contains(bytes[index]) || (97...122).contains(bytes[index])
                || (48...57).contains(bytes[index]) || [45, 58, 95].contains(bytes[index]) { index += 1 }
            let name = String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased()
            var quote: UInt8?
            while index < bytes.count {
                let byte = bytes[index]
                if let active = quote { if byte == active { quote = nil } }
                else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { break }
                index += 1
            }
            guard index < bytes.count else { break }
            index += 1
            if !closing, name == "script" || name == "style" { suppressed = name }
            output.append(32)
        }
        var text = String(decoding: output, as: UTF8.self)
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        if let regex = try? NSRegularExpression(pattern: "&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[a-zA-Z]+);") {
            let source = text as NSString
            var decoded = ""
            var cursor = 0
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
                guard let match else { return }
                decoded += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let key = source.substring(with: match.range(at: 1))
                var replacement = entities[key]
                if key.hasPrefix("#") {
                    let hex = key.lowercased().hasPrefix("#x")
                    if let value = UInt32(key.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                       let scalar = UnicodeScalar(value), value == 9 || value == 10 || value >= 32 {
                        replacement = String(scalar)
                    }
                }
                decoded += replacement ?? source.substring(with: match.range)
                cursor = NSMaxRange(match.range)
            }
            decoded += source.substring(from: cursor)
            text = decoded
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Keeps security scope alive through reads, and closes it even if a timed-out resolver returns late.
private final class SourceRootLease: @unchecked Sendable {
    let scopedURL: URL
    let canonicalURL: URL
    let physicalPath: String
    private let stopAccess: @Sendable (URL) -> Void
    init(scopedURL: URL, canonicalURL: URL, physicalPath: String, stopAccess: @escaping @Sendable (URL) -> Void) {
        self.scopedURL = scopedURL; self.canonicalURL = canonicalURL
        self.physicalPath = physicalPath; self.stopAccess = stopAccess
    }
    deinit { stopAccess(scopedURL) }
}

/// A fresh curl process pins the validated address while TLS still verifies the URL hostname.
/// No shell, curlrc, proxy, cookie jar, credentials, or automatic redirect is involved.
private final class SourceCurlProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    func run(url: URL, address: String, timeout: TimeInterval) throws -> AgentSourceHTTPResponse {
        let host = try AgentSourceReader.publicHTTPSHost(url)
        guard AgentSourceReader.isPublicAddress(address) else { throw AgentSourceError.unsafeURL }
        let transportHost = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host ?? host
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var arguments = ["--disable", "--silent", "--show-error", "--noproxy", "*", "--proto", "=https",
                         "--request", "GET", "--connect-timeout", String(timeout), "--max-time", String(timeout),
                         "--max-filesize", String(AgentSourceReader.maximumResponseBytes), "--compressed",
                         "--header", "Accept: text/html, text/plain, text/markdown", "--dump-header", "-"]
        if !host.contains(":") {
            let pinned = address.contains(":") ? "[\(address)]" : address
            arguments += ["--resolve", "\(host):443:\(pinned)"]
            if transportHost.lowercased() != host {
                arguments += ["--resolve", "\(transportHost):443:\(pinned)"]
            }
        }
        arguments += ["--url", url.absoluteString]
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "CURL_HOME": "/var/empty"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        self.process = process
        do { try process.run() } catch { lock.unlock(); throw AgentSourceError.invalidResponse }
        lock.unlock()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? pipe.fileHandleForReading.close()
            lock.lock()
            self.process = nil
            lock.unlock()
        }
        var pending = Data()
        var headerBytes = 0
        var headers: [String: String]?
        var status = 0
        var body = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
            lock.lock()
            let stopped = cancelled
            lock.unlock()
            if stopped { throw CancellationError() }
            if headers == nil {
                pending.append(chunk)
                while let boundary = pending.range(of: Data([13, 10, 13, 10])) {
                    headerBytes += boundary.upperBound
                    guard headerBytes <= 65_536 else { throw AgentSourceError.tooLarge }
                    let lines = String(decoding: pending[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                    guard let first = lines.first, first.hasPrefix("HTTP/"),
                          let code = Int(first.split(separator: " ").dropFirst().first ?? "") else {
                        throw AgentSourceError.invalidResponse
                    }
                    pending.removeSubrange(..<boundary.upperBound)
                    if (100..<200).contains(code), code != 101 { continue }
                    status = code
                    var fields: [String: String] = [:]
                    for line in lines.dropFirst() {
                        guard let separator = line.firstIndex(of: ":") else { continue }
                        fields[String(line[..<separator]).lowercased()] = line[line.index(after: separator)...]
                            .trimmingCharacters(in: .whitespaces)
                    }
                    headers = fields
                    if [301, 302, 303, 307, 308].contains(status) {
                        return AgentSourceHTTPResponse(status: status, headers: fields, body: Data())
                    }
                    if let size = fields["content-length"].flatMap(Int.init), size > AgentSourceReader.maximumResponseBytes {
                        throw AgentSourceError.tooLarge
                    }
                    break
                }
                if headers == nil {
                    guard pending.count <= 65_536 - headerBytes else { throw AgentSourceError.tooLarge }
                    continue
                }
                body.append(pending)
                pending.removeAll()
            } else {
                body.append(chunk)
            }
            guard body.count <= AgentSourceReader.maximumResponseBytes else { throw AgentSourceError.tooLarge }
        }
        process.waitUntilExit()
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped { throw CancellationError() }
        guard process.terminationStatus == 0, let headers else {
            if process.terminationStatus == 63 { throw AgentSourceError.tooLarge }
            if process.terminationStatus == 28 { throw URLError(.timedOut) }
            throw AgentSourceError.invalidResponse
        }
        return AgentSourceHTTPResponse(status: status, headers: headers, body: body)
    }
}

extension AgentSourceReader {
    static func curl(url: URL, address: String, timeout: TimeInterval) async throws -> AgentSourceHTTPResponse {
        try Task.checkCancellation()
        let runner = SourceCurlProcess()
        return try await withTaskCancellationHandler {
            let response = try await Task.detached { try runner.run(url: url, address: address, timeout: timeout) }.value
            try Task.checkCancellation()
            return response
        } onCancel: {
            runner.cancel()
        }
    }
}

/// A detached blocking system resolver may finish later; cancellation and timeout never await it.
private final class SourceOperationDeadline<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var tasks: [Task<Void, Never>] = []

    private func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    private func attach(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        if result != nil { lock.unlock(); tasks.forEach { $0.cancel() } }
        else { self.tasks = tasks; lock.unlock() }
    }
    private func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation, tasks = self.tasks
        self.continuation = nil; self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
    static func run(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard seconds > 0 else { throw URLError(.timedOut) }
        let state = SourceOperationDeadline()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                let work = Task {
                    do { state.finish(.success(try await operation())) }
                    catch { state.finish(.failure(error)) }
                }
                let timer = Task {
                    do { try await Task.sleep(for: .seconds(seconds)) }
                    catch { return }
                    state.finish(.failure(URLError(.timedOut)))
                }
                state.attach([work, timer])
            }
        } onCancel: { state.finish(.failure(CancellationError())) }
    }
}
