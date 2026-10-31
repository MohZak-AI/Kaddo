import CZlib
import Foundation

/// Reads only the main Word part; never extracts archive paths onto disk.
/// ZIP64, encryption and methods other than stored/raw DEFLATE are rejected.
enum WordZIPArchive {
    private struct Entry {
        let flags: Int
        let method: Int
        let crc: UInt32
        let compressed: Int
        let expanded: Int
        let offset: Int
    }

    static func documentXML(in data: Data, maxBytes: Int) throws -> Data {
        try part("word/document.xml", in: data, maxBytes: maxBytes)
    }

    static func part(_ path: String, in data: Data, maxBytes: Int) throws -> Data {
        guard data.count >= 22 else { throw DocumentImportError.invalidDocument }
        func number(_ offset: Int, _ width: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - width else {
                throw DocumentImportError.invalidDocument
            }
            return (0..<width).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        let end = try stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1)
            .first { position in
                try number(position, 4) == 0x06054b50
                    && position + 22 + number(position + 20, 2) == data.count
            }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else {
            throw DocumentImportError.invalidDocument
        }
        let count = try number(end + 10, 2)
        let directorySize = try number(end + 12, 4)
        let directory = try number(end + 16, 4)
        guard count > 0, count < 65_535, try number(end + 8, 2) == count,
              directory <= end, directorySize == end - directory else {
            throw DocumentImportError.invalidDocument
        }
        var position = directory
        var selected: Entry?
        for _ in 0..<count {
            try Task.checkCancellation()
            guard position <= end - 46, try number(position, 4) == 0x02014b50 else {
                throw DocumentImportError.invalidDocument
            }
            let nameSize = try number(position + 28, 2)
            let extraSize = try number(position + 30, 2)
            let commentSize = try number(position + 32, 2)
            let next = position + 46 + nameSize + extraSize + commentSize
            guard next <= end, try number(position + 34, 2) == 0 else {
                throw DocumentImportError.invalidDocument
            }
            let name = data.subdata(in: position + 46..<position + 46 + nameSize)
            if name == Data(path.utf8) {
                guard selected == nil else { throw DocumentImportError.invalidDocument }
                selected = try Entry(
                    flags: number(position + 8, 2), method: number(position + 10, 2),
                    crc: UInt32(number(position + 16, 4)), compressed: number(position + 20, 4),
                    expanded: number(position + 24, 4), offset: number(position + 42, 4)
                )
            }
            position = next
        }
        guard position == end, let entry = selected,
              entry.flags & 0x41 == 0, [0, 8].contains(entry.method),
              entry.offset <= directory - 30,
              try number(entry.offset, 4) == 0x04034b50,
              try number(entry.offset + 6, 2) == entry.flags,
              try number(entry.offset + 8, 2) == entry.method else {
            throw DocumentImportError.invalidDocument
        }
        guard entry.expanded <= maxBytes else { throw DocumentImportError.documentTooLarge }
        if entry.flags & 8 == 0 {
            guard try number(entry.offset + 14, 4) == Int(entry.crc),
                  try number(entry.offset + 18, 4) == entry.compressed,
                  try number(entry.offset + 22, 4) == entry.expanded else {
                throw DocumentImportError.invalidDocument
            }
        }
        let nameSize = try number(entry.offset + 26, 2)
        let extraSize = try number(entry.offset + 28, 2)
        let start = entry.offset + 30 + nameSize + extraSize
        guard start <= directory, entry.compressed <= directory - start,
              data.subdata(in: entry.offset + 30..<entry.offset + 30 + nameSize)
                == Data(path.utf8) else {
            throw DocumentImportError.invalidDocument
        }
        let compressed = data.subdata(in: start..<start + entry.compressed)
        let xml: Data
        if entry.method == 0 {
            guard compressed.count <= maxBytes else { throw DocumentImportError.documentTooLarge }
            xml = compressed
        } else {
            xml = try inflateXML(compressed, maxBytes: min(maxBytes, entry.expanded))
        }
        let checksum = xml.withUnsafeBytes { bytes in
            crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
        }
        guard xml.count == entry.expanded, UInt32(checksum) == entry.crc else {
            throw DocumentImportError.invalidDocument
        }
        return xml
    }

    private static func inflateXML(_ data: Data, maxBytes: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw DocumentImportError.invalidDocument
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 32_768)
            while true {
                try Task.checkCancellation()
                let status = buffer.withUnsafeMutableBytes { output in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                guard produced <= maxBytes - result.count else {
                    throw DocumentImportError.documentTooLarge
                }
                result.append(contentsOf: buffer.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw DocumentImportError.invalidDocument }
                    return result
                }
                guard status == Z_OK, produced > 0 else { throw DocumentImportError.invalidDocument }
            }
        }
    }
}
