import Foundation

// MARK: - Errors

/// Failures specific to typed sync-message handling (beyond raw protobuf decoding).
enum SyncMessageError: Error, LocalizedError {
    /// `EnvelopeIn.decodeMessage()` was called on an end-to-end-encrypted envelope.
    case contentIsEncrypted

    var errorDescription: String? {
        switch self {
        case .contentIsEncrypted:
            return "Sync message is end-to-end encrypted; decrypt it before decoding."
        }
    }
}

// MARK: - CRDTValue

/// A CRDT cell value plus its tagged wire encoding (docs/PROTOCOL.md §5).
///
/// `Message.value` on the wire is ALWAYS a string (`string value = 4` in sync.proto) carrying
/// this prefix scheme — never a native protobuf number or null (PROTOCOL §10 trap 3):
/// - `"0:"` → SQL NULL (decode switches on the first character only, like Actual)
/// - `"N:" + number` → numeric, formatted the way JS `String(number)` does
/// - `"S:" + raw` → string, verbatim, no escaping
enum CRDTValue: Sendable, Equatable {
    case null
    case number(Double)
    case string(String)

    /// The tagged wire string.
    var encoded: String {
        switch self {
        case .null:
            return "0:"
        case .number(let d):
            return "N:" + Self.jsNumberString(d)
        case .string(let s):
            return "S:" + s
        }
    }

    /// Tolerant decode, mirroring Actual's `deserializeValue`: only the FIRST character is
    /// inspected ("0" → null even without a colon). Divergences where Actual would throw:
    /// empty input decodes to `.null`, and an unknown tag falls back to `.string(s)` (raw),
    /// so a single odd message can't abort a whole sync batch.
    static func decode(_ s: String) -> CRDTValue {
        guard let first = s.first else { return .null }
        switch first {
        case "0":
            return .null
        case "N":
            return .number(Double(s.dropFirst(2)) ?? 0)
        case "S":
            return .string(String(s.dropFirst(2)))
        default:
            return .string(s)
        }
    }

    /// SQLite binding for applying this value to the budget database. Whole finite numbers
    /// within the exact-Double range bind as INTEGER (Actual's columns are integer cents /
    /// yyyymmdd dates / bool flags); anything else binds as REAL.
    var sqlValue: SQLValue {
        switch self {
        case .null:
            return .null
        case .number(let d):
            if d.isFinite, d == d.rounded(), abs(d) <= 9_007_199_254_740_991 {
                return .int(Int64(d))
            }
            return .real(d)
        case .string(let s):
            return .text(s)
        }
    }

    /// Format a Double the way JS `String(number)` does for all values Actual actually syncs:
    /// integers render without a decimal point ("-33" not "-33.0"), everything else uses Swift's
    /// shortest round-trip form (matches JS for ordinary decimals like "-33.5", "0.1").
    private static func jsNumberString(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == d.rounded(), abs(d) < 9.2e18 {
            return String(Int64(d))
        }
        return String(d)
    }
}

// MARK: - CRDTMessage

/// One CRDT cell-write: `(dataset, row, column) ← value @ timestamp`.
///
/// `dataset`/`column` are Actual's RAW SQLite identifiers (`transactions.description` for the
/// payee id, `acct`, `isParent`, …) — never the public AQL names (PROTOCOL §10 trap 5).
/// Wire form is proto `Message` (dataset=1, row=2, column=3, value=4 — all strings).
struct CRDTMessage: Sendable {
    var timestamp: String
    var dataset: String
    var row: String
    var column: String
    var value: CRDTValue
}

extension CRDTMessage {
    /// Serialized proto `Message` bytes — the plaintext that gets either placed directly into
    /// `MessageEnvelope.content`, or AES-GCM-encrypted first when E2E is on (PROTOCOL §7.3).
    /// Default (empty) fields are omitted, matching canonical proto3 encoders; `value` is never
    /// empty because the tagged encoding is at least `"0:"`.
    func serializedMessage() -> Data {
        var w = ProtoWriter()
        if !dataset.isEmpty { w.field(1, string: dataset) }
        if !row.isEmpty { w.field(2, string: row) }
        if !column.isEmpty { w.field(3, string: column) }
        let v = value.encoded
        if !v.isEmpty { w.field(4, string: v) }
        return w.data
    }

    /// Decode proto `Message` bytes (already decrypted if the envelope was encrypted); the
    /// timestamp travels in the envelope, not the `Message`, so it is passed alongside.
    init(timestamp: String, parsingMessage data: Data) throws {
        var dataset = ""
        var row = ""
        var column = ""
        var value = ""
        var reader = ProtoReader(data)
        while let (field, v) = reader.next() {
            switch (field, v) {
            case (1, .bytes(let d)):
                dataset = try Self.utf8String(d, field: "Message.dataset")
            case (2, .bytes(let d)):
                row = try Self.utf8String(d, field: "Message.row")
            case (3, .bytes(let d)):
                column = try Self.utf8String(d, field: "Message.column")
            case (4, .bytes(let d)):
                value = try Self.utf8String(d, field: "Message.value")
            default:
                break  // unknown field — skip
            }
        }
        self.init(timestamp: timestamp, dataset: dataset, row: row, column: column,
                  value: CRDTValue.decode(value))
    }

    private static func utf8String(_ data: Data, field: String) throws -> String {
        guard let s = String(data: data, encoding: .utf8) else {
            throw ProtobufDecodeError.invalidUTF8(field: field)
        }
        return s
    }
}

// MARK: - EncryptedData

/// proto `EncryptedData` — the E2E wrapper placed in `MessageEnvelope.content` when
/// `isEncrypted` (docs/PROTOCOL.md §2, §7): `iv=1` (12 bytes), `authTag=2` (16 bytes, kept
/// SEPARATE from the ciphertext — PROTOCOL §10 trap 7), `data=3` (ciphertext only).
struct EncryptedData: Sendable {
    var iv: Data
    var authTag: Data
    var data: Data
}

extension EncryptedData {
    init(parsing raw: Data) throws {
        var iv = Data()
        var authTag = Data()
        var data = Data()
        var reader = ProtoReader(raw)
        while let (field, value) = reader.next() {
            switch (field, value) {
            case (1, .bytes(let d)): iv = d
            case (2, .bytes(let d)): authTag = d
            case (3, .bytes(let d)): data = d
            default: break
            }
        }
        self.init(iv: iv, authTag: authTag, data: data)
    }

    func serialized() -> Data {
        var w = ProtoWriter()
        if !iv.isEmpty { w.field(1, bytes: iv) }
        if !authTag.isEmpty { w.field(2, bytes: authTag) }
        if !data.isEmpty { w.field(3, bytes: data) }
        return w.data
    }
}

// MARK: - EnvelopeOut

/// Outbound proto `MessageEnvelope`: `timestamp=1` (string), `isEncrypted=2` (bool),
/// `content=3` (bytes). `content` is a serialized `Message` — raw when plaintext, or wrapped in
/// `EncryptedData` when `isEncrypted`. The HLC timestamp is NEVER encrypted; the server needs it
/// in plaintext for merkle bucketing/dedup even on E2E files (PROTOCOL §7.3).
struct EnvelopeOut: Sendable {
    var timestamp: String
    var isEncrypted: Bool
    var content: Data
}

extension EnvelopeOut {
    /// Plaintext envelope for one CRDT message.
    init(_ message: CRDTMessage) {
        self.init(timestamp: message.timestamp,
                  isEncrypted: false,
                  content: message.serializedMessage())
    }

    /// Serialized `MessageEnvelope` bytes; proto3 defaults (false / empty) are omitted.
    func serialized() -> Data {
        var w = ProtoWriter()
        if !timestamp.isEmpty { w.field(1, string: timestamp) }
        if isEncrypted { w.field(2, bool: true) }
        if !content.isEmpty { w.field(3, bytes: content) }
        return w.data
    }
}

// MARK: - EnvelopeIn

/// Inbound proto `MessageEnvelope` (same fields as `EnvelopeOut`). When `isEncrypted`, `content`
/// is a serialized `EncryptedData`; decrypt with `E2EKey` and feed the plaintext to
/// `CRDTMessage(timestamp:parsingMessage:)`. Otherwise `content` is a plain `Message`.
struct EnvelopeIn: Sendable {
    var timestamp: String
    var isEncrypted: Bool
    var content: Data
}

extension EnvelopeIn {
    init(parsing data: Data) throws {
        var timestamp = ""
        var isEncrypted = false
        var content = Data()
        var reader = ProtoReader(data)
        while let (field, value) = reader.next() {
            switch (field, value) {
            case (1, .bytes(let d)):
                guard let s = String(data: d, encoding: .utf8) else {
                    throw ProtobufDecodeError.invalidUTF8(field: "MessageEnvelope.timestamp")
                }
                timestamp = s
            case (2, .varint(let v)):
                isEncrypted = v != 0
            case (3, .bytes(let d)):
                content = d
            default:
                break  // unknown field — skip
            }
        }
        self.init(timestamp: timestamp, isEncrypted: isEncrypted, content: content)
    }

    /// Decode `content` as a plaintext `Message`. Throws `SyncMessageError.contentIsEncrypted`
    /// for E2E envelopes — decrypt first (see `EncryptedData` + `E2EKey`), then use
    /// `CRDTMessage(timestamp:parsingMessage:)` with the plaintext.
    func decodeMessage() throws -> CRDTMessage {
        guard !isEncrypted else { throw SyncMessageError.contentIsEncrypted }
        return try CRDTMessage(timestamp: timestamp, parsingMessage: content)
    }
}

// MARK: - SyncRequest

/// proto `SyncRequest`, POSTed raw to `/sync/sync` with `Content-Type: application/actual-sync`
/// (docs/PROTOCOL.md §1–2). Field numbers verbatim from sync.proto — note the GAP at 4:
/// `messages=1` (repeated MessageEnvelope), `fileId=2`, `groupId=3`, **4 reserved**, `keyId=5`,
/// `since=6`. `since` must be non-empty or the server responds 422 `since-required`.
struct SyncRequest: Sendable {
    var messages: [EnvelopeOut]
    var fileID: String
    var groupID: String
    /// The file's current E2E key id — sent whenever the file is encrypted, independent of
    /// whether this batch's messages are themselves encrypted (PROTOCOL §7.4).
    var keyID: String?
    /// HLC timestamp string cursor: "send me everything after this".
    var since: String

    /// Serialized `SyncRequest` bytes (the raw POST body).
    func serialized() -> Data {
        var w = ProtoWriter()
        for message in messages {
            w.field(1, bytes: message.serialized())
        }
        if !fileID.isEmpty { w.field(2, string: fileID) }
        if !groupID.isEmpty { w.field(3, string: groupID) }
        // Field 4 is reserved in sync.proto — never emitted.
        if let keyID, !keyID.isEmpty { w.field(5, string: keyID) }
        if !since.isEmpty { w.field(6, string: since) }
        return w.data
    }
}

// MARK: - SyncResponse

/// proto `SyncResponse`: `messages=1` (repeated MessageEnvelope), `merkle=2` — the merkle is a
/// JSON **string** (`JSON.stringify(trie)` server-side), not a nested proto message; parse it
/// with `MerkleTrie.fromJSON`.
struct SyncResponse: Sendable {
    var merkle: String
    var messages: [EnvelopeIn]
}

extension SyncResponse {
    /// Decode the raw `/sync/sync` response body. Unknown fields are skipped by number.
    init(parsing data: Data) throws {
        var merkle = ""
        var messages: [EnvelopeIn] = []
        var reader = ProtoReader(data)
        while let (field, value) = reader.next() {
            switch (field, value) {
            case (1, .bytes(let d)):
                messages.append(try EnvelopeIn(parsing: d))
            case (2, .bytes(let d)):
                guard let s = String(data: d, encoding: .utf8) else {
                    throw ProtobufDecodeError.invalidUTF8(field: "SyncResponse.merkle")
                }
                merkle = s
            default:
                break  // unknown field — skip
            }
        }
        self.init(merkle: merkle, messages: messages)
    }
}
