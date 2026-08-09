import Foundation
import Compression

// MARK: - Errors

/// Failures raised while reading a budget zip (docs/PROTOCOL.md §8.1: `db.sqlite` +
/// `metadata.json`, stored or deflated).
enum ZipArchiveError: Error, LocalizedError {
    /// No valid End Of Central Directory record found.
    case notAnArchive
    /// Structurally invalid archive (context in the associated value).
    case corrupt(String)
    /// An entry uses a compression method other than 0 (stored) or 8 (deflate).
    case unsupportedCompressionMethod(Int)
    /// Zip64 archives (any 0xFFFFFFFF size/offset marker) are not supported.
    case zip64Unsupported

    var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return "The downloaded budget file is not a valid zip archive."
        case .corrupt(let what):
            return "The budget zip archive is corrupt (\(what))."
        case .unsupportedCompressionMethod(let method):
            return "The budget zip uses an unsupported compression method (\(method))."
        case .zip64Unsupported:
            return "Zip64 archives are not supported."
        }
    }
}

// MARK: - ZipArchive

/// Minimal zip codec for Actual budget files.
///
/// Reading (`entries`): scans the last 64 KB for the End Of Central Directory signature
/// (`0x06054b50`, validating the comment length), walks the central directory (`0x02014b50`),
/// resolves each entry's data through its local header (`0x04034b50` — sizes are taken from the
/// central directory, since streamed local headers may carry zeros + a data descriptor), and
/// supports methods 0 (stored) and 8 (deflate — `COMPRESSION_ZLIB` in the Compression framework
/// is raw DEFLATE, exactly what zip stores). Directory entries are skipped. Zip64 is rejected.
///
/// Writing (`archive`): produces a valid stored-method (no compression) zip with correct CRC-32
/// values, suitable for `/sync/upload-user-file`. Entries are emitted in sorted-name order for
/// deterministic output.
enum ZipArchive {
    // MARK: Reading

    /// Parse `data` as a zip archive and return every file entry as `[path: contents]`.
    static func entries(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ZipArchiveError.notAnArchive }

        // --- End Of Central Directory: scan backward over the last 64 KB (max comment) + 22.
        var eocdOffset: Int? = nil
        let scanStart = max(0, bytes.count - 22 - 0xFFFF)
        var i = bytes.count - 22
        while i >= scanStart {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                let commentLength = u16(bytes, i + 20)
                if i + 22 + commentLength <= bytes.count {
                    eocdOffset = i
                    break
                }
            }
            i -= 1
        }
        guard let eocd = eocdOffset else { throw ZipArchiveError.notAnArchive }

        let totalEntries = u16(bytes, eocd + 10)
        let cdSize = Int(u32(bytes, eocd + 12))
        let cdOffset = Int(u32(bytes, eocd + 16))
        guard cdOffset + cdSize <= bytes.count else {
            throw ZipArchiveError.corrupt("central directory out of bounds")
        }

        // --- Central directory walk.
        var result: [String: Data] = [:]
        var p = cdOffset
        for _ in 0..<totalEntries {
            guard p + 46 <= bytes.count, u32(bytes, p) == 0x02014b50 else {
                throw ZipArchiveError.corrupt("central directory entry signature")
            }
            let method = u16(bytes, p + 10)
            let compressedSize = Int(u32(bytes, p + 20))
            let uncompressedSize = Int(u32(bytes, p + 24))
            let nameLength = u16(bytes, p + 28)
            let extraLength = u16(bytes, p + 30)
            let commentLength = u16(bytes, p + 32)
            let localHeaderOffset = Int(u32(bytes, p + 42))
            guard p + 46 + nameLength <= bytes.count else {
                throw ZipArchiveError.corrupt("central directory entry name")
            }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            p += 46 + nameLength + extraLength + commentLength

            if name.hasSuffix("/") { continue }  // directory entry

            let zip64Marker = Int(UInt32.max)
            guard compressedSize != zip64Marker,
                  uncompressedSize != zip64Marker,
                  localHeaderOffset != zip64Marker else {
                throw ZipArchiveError.zip64Unsupported
            }

            // --- Local header → start of entry data.
            guard localHeaderOffset + 30 <= bytes.count,
                  u32(bytes, localHeaderOffset) == 0x04034b50 else {
                throw ZipArchiveError.corrupt("local header for '\(name)'")
            }
            let localNameLength = u16(bytes, localHeaderOffset + 26)
            let localExtraLength = u16(bytes, localHeaderOffset + 28)
            let dataStart = localHeaderOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= bytes.count else {
                throw ZipArchiveError.corrupt("entry data for '\(name)' out of bounds")
            }
            let compressed = Array(bytes[dataStart..<(dataStart + compressedSize)])

            switch method {
            case 0:  // stored
                result[name] = Data(compressed)
            case 8:  // deflate
                result[name] = try inflateRaw(compressed, uncompressedSize: uncompressedSize)
            default:
                throw ZipArchiveError.unsupportedCompressionMethod(method)
            }
        }
        return result
    }

    /// Raw-DEFLATE decompress via the Compression framework (`COMPRESSION_ZLIB` operates on raw
    /// deflate streams — no zlib header — which is precisely zip's method-8 payload).
    private static func inflateRaw(_ compressed: [UInt8], uncompressedSize: Int) throws -> Data {
        if uncompressedSize <= 0 { return Data() }
        guard !compressed.isEmpty else {
            throw ZipArchiveError.corrupt("empty deflate stream")
        }
        var destination = [UInt8](repeating: 0, count: uncompressedSize)
        let written = compressed.withUnsafeBufferPointer { source -> Int in
            guard let sourceBase = source.baseAddress else { return 0 }
            return destination.withUnsafeMutableBufferPointer { dest -> Int in
                guard let destBase = dest.baseAddress else { return 0 }
                return compression_decode_buffer(destBase, dest.count,
                                                 sourceBase, source.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written == uncompressedSize else {
            throw ZipArchiveError.corrupt("deflate stream did not decode to the expected size")
        }
        return Data(destination)
    }

    // MARK: Writing

    /// Build a stored-method (uncompressed) zip containing `entries`, with correct CRC-32s —
    /// the upload counterpart of `entries(_:)` for `/sync/upload-user-file`. Entry contents are
    /// assumed < 4 GB each (sizes are clamped to UInt32; budget files are a few MB).
    static func archive(_ entries: [String: Data]) -> Data {
        var out = Data()
        var central = Data()
        let names = entries.keys.sorted()

        for name in names {
            guard let content = entries[name] else { continue }
            let nameBytes = Array(name.utf8)
            let crc = crc32(content)
            let size = UInt32(clamping: content.count)
            let offset = UInt32(clamping: out.count)

            // Local file header (30 bytes + name), signature 0x04034b50.
            out.append(contentsOf: le32(0x04034b50))
            out.append(contentsOf: le16(20))       // version needed to extract (2.0)
            out.append(contentsOf: le16(0x0800))   // general purpose flags: UTF-8 names
            out.append(contentsOf: le16(0))        // method 0 = stored
            out.append(contentsOf: le16(0))        // DOS mod time (00:00:00)
            out.append(contentsOf: le16(0x0021))   // DOS mod date (1980-01-01)
            out.append(contentsOf: le32(crc))
            out.append(contentsOf: le32(size))     // compressed size (== uncompressed for stored)
            out.append(contentsOf: le32(size))     // uncompressed size
            out.append(contentsOf: le16(UInt16(clamping: nameBytes.count)))
            out.append(contentsOf: le16(0))        // extra field length
            out.append(contentsOf: nameBytes)
            out.append(content)

            // Central directory entry (46 bytes + name), signature 0x02014b50.
            central.append(contentsOf: le32(0x02014b50))
            central.append(contentsOf: le16(20))     // version made by
            central.append(contentsOf: le16(20))     // version needed to extract
            central.append(contentsOf: le16(0x0800)) // flags: UTF-8 names
            central.append(contentsOf: le16(0))      // method 0 = stored
            central.append(contentsOf: le16(0))      // DOS mod time
            central.append(contentsOf: le16(0x0021)) // DOS mod date
            central.append(contentsOf: le32(crc))
            central.append(contentsOf: le32(size))   // compressed size
            central.append(contentsOf: le32(size))   // uncompressed size
            central.append(contentsOf: le16(UInt16(clamping: nameBytes.count)))
            central.append(contentsOf: le16(0))      // extra field length
            central.append(contentsOf: le16(0))      // comment length
            central.append(contentsOf: le16(0))      // disk number start
            central.append(contentsOf: le16(0))      // internal attributes
            central.append(contentsOf: le32(0))      // external attributes
            central.append(contentsOf: le32(offset)) // local header offset
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = UInt32(clamping: out.count)
        let centralSize = UInt32(clamping: central.count)
        let entryCount = UInt16(clamping: names.count)
        out.append(central)

        // End Of Central Directory record (22 bytes), signature 0x06054b50.
        out.append(contentsOf: le32(0x06054b50))
        out.append(contentsOf: le16(0))              // disk number
        out.append(contentsOf: le16(0))              // disk with central directory
        out.append(contentsOf: le16(entryCount))     // entries on this disk
        out.append(contentsOf: le16(entryCount))     // total entries
        out.append(contentsOf: le32(centralSize))
        out.append(contentsOf: le32(centralOffset))
        out.append(contentsOf: le16(0))              // comment length
        return out
    }

    // MARK: CRC-32

    /// Standard zip CRC-32 (polynomial 0xEDB88320, init/xorout 0xFFFFFFFF).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    // MARK: Little-endian helpers

    private static func u16(_ bytes: [UInt8], _ i: Int) -> Int {
        Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ i: Int) -> UInt32 {
        UInt32(bytes[i])
            | (UInt32(bytes[i + 1]) << 8)
            | (UInt32(bytes[i + 2]) << 16)
            | (UInt32(bytes[i + 3]) << 24)
    }

    private static func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8(v >> 8)]
    }

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }
}
