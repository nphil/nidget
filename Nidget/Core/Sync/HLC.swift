import Foundation

// MARK: - HLC errors

/// Failures raised by `HLCClock`, mirroring Actual's `ClockDriftError` / `OverflowError`
/// (docs/PROTOCOL.md §3.3–3.5).
enum HLCError: Error, LocalizedError, Equatable {
    /// Logical time ran more than 5 minutes ahead of the wall clock.
    case clockDrift(aheadMillis: Int64)
    /// More than 0xFFFF events were stamped inside a single logical millisecond.
    case counterOverflow

    var errorDescription: String? {
        switch self {
        case .clockDrift(let ahead):
            return "Sync clock drifted \(ahead) ms ahead of the device clock (max 300000 ms). Check the device date & time."
        case .counterOverflow:
            return "Sync clock counter overflowed (more than 65535 events in one millisecond)."
        }
    }
}

// MARK: - HLCTimestamp

/// Hybrid Logical Clock timestamp — the ordering primitive of Actual's CRDT sync.
///
/// String format (docs/PROTOCOL.md §3.1; 46 characters when the node id is the usual 16 chars):
///
///     2015-04-24T22:23:42.123Z-1000-0123456789ABCDEF
///     └─ ISO8601 UTC millis ─┘ └ctr┘ └── node (16) ──┘
///
/// - millis: `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` — UTC, always exactly 3 fraction digits, always `Z`.
/// - counter: 4 **uppercase** hex digits, zero-padded (`002A`).
/// - node: client id, left-zero-padded to 16 characters (lowercase hex from `makeClientId`).
///
/// The zero-padding is correctness-critical, not cosmetic: plain lexicographic ordering of these
/// strings IS the protocol's chronological + tie-break order — `messages_crdt` lookups, the
/// apply-sort, and merkle bucketing all rely on it (PROTOCOL §10 trap 1).
struct HLCTimestamp: Comparable, Sendable, CustomStringConvertible {
    /// 0xFFFF — counters above this overflow (PROTOCOL §3.5).
    static let maxCounter = 0xFFFF
    /// Node ids longer than 16 characters are rejected on parse (PROTOCOL §3.1).
    static let maxNodeLength = 16
    /// 5 minutes, in milliseconds (PROTOCOL §3.5).
    static let maxDriftMillis: Int64 = 5 * 60 * 1000

    /// `1970-01-01T00:00:00.000Z-0000-0000000000000000` (Actual's `Timestamp.zero`).
    static let zero = HLCTimestamp(millis: 0, counter: 0, node: "0000000000000000")

    /// Milliseconds since the Unix epoch (UTC).
    let millis: Int64
    /// Logical counter, `0...0xFFFF`.
    let counter: Int
    /// Client id — up to 16 characters, left-zero-padded to 16 when rendered.
    let node: String

    init(millis: Int64, counter: Int, node: String) {
        self.millis = millis
        self.counter = counter
        self.node = node
    }

    /// Fixed formatter for the seconds portion: en_US_POSIX + UTC + Gregorian, per the protocol's
    /// fixed `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` shape. The millisecond fraction is appended manually
    /// rather than via `SSS` because ICU *truncates* fractional seconds when formatting — binary
    /// floating point can make exactly 123 ms render as `.122` through a `SSS` pattern. Splitting
    /// integer seconds (exact in Double) from integer millis avoids that class of bug entirely.
    /// DateFormatter is documented thread-safe for formatting since iOS 7.
    nonisolated(unsafe) private static let secondsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// The exact wire string (see type doc). Lexicographic order of these strings matches
    /// `(millis, counter, node)` order by construction.
    var description: String {
        var secs = millis / 1000
        var ms = millis % 1000
        if ms < 0 {  // defensive floor-division for pre-epoch values; unreachable via parse/clock
            ms += 1000
            secs -= 1
        }
        let datePart = Self.secondsFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(secs)))
        return datePart
            + "." + Self.leftPad(String(ms), to: 3)
            + "Z-" + Self.leftPad(String(counter, radix: 16, uppercase: true), to: 4)
            + "-" + Self.leftPad(node, to: 16)
    }

    /// Parse the 5-dash-segment form (PROTOCOL §3.1): the ISO date itself contains two dashes, so
    /// splitting the whole string on `-` yields exactly 5 parts; the first three re-join into the
    /// ISO date string. Returns nil for anything malformed (negative millis, counter > 0xFFFF,
    /// node longer than 16 chars, non-canonical ISO shape).
    static func parse(_ s: String) -> HLCTimestamp? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return nil }
        let iso = parts[0...2].joined(separator: "-")
        guard let millis = millis(fromISO: iso), millis >= 0 else { return nil }
        guard let counter = Int(parts[3], radix: 16), (0...maxCounter).contains(counter) else { return nil }
        let node = String(parts[4])
        guard node.count <= maxNodeLength else { return nil }
        return HLCTimestamp(millis: millis, counter: counter, node: node)
    }

    /// Strict parse of `yyyy-MM-ddTHH:mm:ss.SSSZ`. Seconds go through the fixed formatter;
    /// millis are parsed as a plain 3-digit integer so no floating-point rounding can occur.
    private static func millis(fromISO iso: String) -> Int64? {
        guard iso.hasSuffix("Z"), let dot = iso.lastIndex(of: ".") else { return nil }
        let secondsPart = String(iso[..<dot])
        let frac = iso[iso.index(after: dot)...].dropLast()  // strip trailing "Z"
        guard frac.count == 3,
              frac.allSatisfy({ $0.isASCII && $0.isNumber }),
              let ms = Int64(frac) else { return nil }
        guard let date = secondsFormatter.date(from: secondsPart) else { return nil }
        return Int64(date.timeIntervalSince1970.rounded()) * 1000 + ms
    }

    /// Left-pad with zeros to `length`; keep the LAST `length` chars if longer — matches JS's
    /// `('0000' + x).slice(-4)` idiom exactly.
    private static func leftPad(_ s: String, to length: Int) -> String {
        if s.count == length { return s }
        if s.count > length { return String(s.suffix(length)) }
        return String(repeating: "0", count: length - s.count) + s
    }

    static func == (lhs: HLCTimestamp, rhs: HLCTimestamp) -> Bool {
        lhs.millis == rhs.millis && lhs.counter == rhs.counter && lhs.node == rhs.node
    }

    /// Matches lexicographic order of `description` (millis, then counter, then node).
    static func < (lhs: HLCTimestamp, rhs: HLCTimestamp) -> Bool {
        if lhs.millis != rhs.millis { return lhs.millis < rhs.millis }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.node < rhs.node
    }
}

// MARK: - HLCClock

/// Mutable hybrid logical clock implementing Actual's `send`/`recv` rules (PROTOCOL §3.3–3.4).
///
/// Not internally synchronized — per the architecture it is only ever used from behind the
/// `SyncEngine` actor. `current` is settable so the engine can restore persisted clock state
/// (`messages_clock` → `deserializeClock`) after opening a budget file.
final class HLCClock {
    private let now: () -> Int64

    /// The clock's latest timestamp. Logical millis never move backward.
    var current: HLCTimestamp

    init(node: String, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.now = now
        self.current = HLCTimestamp(millis: 0, counter: 0, node: node)
    }

    /// Fresh client/node id matching Actual's `makeClientId()` (PROTOCOL §3.2): a UUIDv4 with
    /// dashes stripped, keeping the LAST 16 hex characters — exactly 16 lowercase hex chars.
    static func makeClientId() -> String {
        let hex = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return String(hex.suffix(16))
    }

    /// Stamp a locally-generated message. Wall clock wins when it has advanced; otherwise the
    /// counter bumps so multiple sends inside one millisecond stay totally ordered.
    /// - Throws: `HLCError.clockDrift` if logical time is > 5 min ahead of the wall clock,
    ///   `HLCError.counterOverflow` if the counter would exceed 0xFFFF.
    func send() throws -> HLCTimestamp {
        let phys = now()
        let lOld = current.millis
        let lNew = max(lOld, phys)
        let cNew = lNew == lOld ? current.counter + 1 : 0
        if lNew - phys > HLCTimestamp.maxDriftMillis {
            throw HLCError.clockDrift(aheadMillis: lNew - phys)
        }
        if cNew > HLCTimestamp.maxCounter {
            throw HLCError.counterOverflow
        }
        current = HLCTimestamp(millis: lNew, counter: cNew, node: current.node)
        return current
    }

    /// Merge a remote timestamp into the local clock — called for every incoming message BEFORE
    /// it is applied, so future `send()`s are causally after everything received (PROTOCOL §3.4).
    func recv(_ remote: HLCTimestamp) throws {
        let phys = now()
        if remote.millis - phys > HLCTimestamp.maxDriftMillis {
            throw HLCError.clockDrift(aheadMillis: remote.millis - phys)
        }
        let lOld = current.millis
        let cOld = current.counter
        let lNew = max(max(lOld, phys), remote.millis)
        let cNew: Int
        if lNew == lOld && lNew == remote.millis {
            cNew = max(cOld, remote.counter) + 1
        } else if lNew == lOld {
            cNew = cOld + 1
        } else if lNew == remote.millis {
            cNew = remote.counter + 1
        } else {
            cNew = 0
        }
        if lNew - phys > HLCTimestamp.maxDriftMillis {
            throw HLCError.clockDrift(aheadMillis: lNew - phys)
        }
        if cNew > HLCTimestamp.maxCounter {
            throw HLCError.counterOverflow
        }
        current = HLCTimestamp(millis: lNew, counter: cNew, node: current.node)
    }
}
