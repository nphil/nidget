import Foundation

// MARK: - Errors

/// Failures raised while decoding proto3-encoded sync payloads into typed messages
/// (used by SyncMessages.swift; `ProtoReader` itself signals malformed input by ending iteration).
enum ProtobufDecodeError: Error, LocalizedError {
    /// A wire string field did not contain valid UTF-8.
    case invalidUTF8(field: String)
    /// Structurally invalid payload (context in the associated value).
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8(let field):
            return "Sync payload field '\(field)' is not valid UTF-8."
        case .malformed(let what):
            return "Malformed sync payload: \(what)."
        }
    }
}

// MARK: - ProtoValue

/// One decoded scalar from the wire.
///
/// - `varint`: wire type 0 (int32/int64/uint/bool/enum).
/// - `bytes`: wire type 2 payload (string/bytes/embedded message), OR the raw little-endian
///   8 bytes of wire type 1 (fixed64/double) / 4 bytes of wire type 5 (fixed32/float). Actual's
///   `sync.proto` uses no fixed-width fields, so those only appear for unknown fields being
///   skipped — they are surfaced (rather than swallowed) so callers stay tag-driven.
enum ProtoValue {
    case varint(UInt64)
    case bytes(Data)
}

// MARK: - ProtoWriter

/// Minimal proto3 encoder — exactly what `sync.proto` needs (docs/PROTOCOL.md §2).
///
/// Wire format: each field is a varint tag `(fieldNumber << 3) | wireType`, then the payload.
/// - string/bytes → wire type 2: tag, varint byte-length, raw bytes.
/// - bool → wire type 0: tag, varint 0/1.
///
/// The writer emits whatever it is told; proto3 default-value omission (empty string, false) is
/// the *caller's* job (SyncMessages.swift skips defaults to match canonical encoders).
struct ProtoWriter {
    /// The encoded message so far.
    var data = Data()

    init() {}

    /// Append a length-delimited string field (wire type 2), UTF-8 encoded.
    mutating func field(_ n: Int, string: String) {
        field(n, bytes: Data(string.utf8))
    }

    /// Append a length-delimited bytes field (wire type 2). Also used for embedded messages
    /// (e.g. each repeated `MessageEnvelope` inside a `SyncRequest`).
    mutating func field(_ n: Int, bytes: Data) {
        appendVarint(UInt64(n) << 3 | 2)
        appendVarint(UInt64(bytes.count))
        data.append(bytes)
    }

    /// Append a bool field as a varint (wire type 0).
    mutating func field(_ n: Int, bool: Bool) {
        appendVarint(UInt64(n) << 3)
        appendVarint(bool ? 1 : 0)
    }

    private mutating func appendVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v))
    }
}

// MARK: - ProtoReader

/// Streaming reader over one message's fields.
///
/// Iterate with `next()` and switch on the field **number** — never on position. Unknown fields
/// must simply be ignored by the caller; the reader itself already consumed their payload
/// correctly for wire types 0, 1, 2, and 5, so iteration continues cleanly past them. This
/// matters concretely: `SyncRequest` has a reserved gap at field 4 (PROTOCOL §10 trap 4), and
/// future server versions may add fields anywhere.
///
/// `next()` returns nil at end-of-data, and also on malformed input (truncated varint, length
/// running past the buffer, field number 0, or the deprecated group wire types 3/4) — iteration
/// simply ends, matching the contract's non-throwing signature.
struct ProtoReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    /// The next `(fieldNumber, value)` pair, or nil when exhausted/malformed.
    mutating func next() -> (field: Int, value: ProtoValue)? {
        guard index < bytes.count, let tag = readVarint() else { return nil }
        let field = Int(tag >> 3)
        let wireType = tag & 0x7
        guard field > 0 else { return nil }
        switch wireType {
        case 0:  // varint
            guard let v = readVarint() else { return nil }
            return (field, .varint(v))
        case 1:  // fixed64 — surfaced raw so unknown fields skip correctly
            guard let d = readBytes(8) else { return nil }
            return (field, .bytes(d))
        case 2:  // length-delimited
            guard let length = readVarint(),
                  length <= UInt64(bytes.count - index),
                  let d = readBytes(Int(length)) else { return nil }
            return (field, .bytes(d))
        case 5:  // fixed32 — surfaced raw so unknown fields skip correctly
            guard let d = readBytes(4) else { return nil }
            return (field, .bytes(d))
        default:  // wire types 3/4 (groups) are deprecated and never valid here
            return nil
        }
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if shift >= 64 { return nil }  // > 10 bytes: malformed
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil  // truncated
    }

    private mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, index <= bytes.count - count, count <= bytes.count else { return nil }
        let d = Data(bytes[index..<(index + count)])
        index += count
        return d
    }
}
