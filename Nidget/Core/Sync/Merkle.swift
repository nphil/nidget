import Foundation

// MARK: - MurmurHash3 (x86, 32-bit)

/// MurmurHash3 x86 32-bit — must reproduce Actual's `murmurhash.v3` byte-for-byte
/// (docs/PROTOCOL.md §4.3): standard Appleby constants, **seed 0**, input = UTF-8 bytes of the
/// full 46-char HLC timestamp string (never just the millis — PROTOCOL §10 trap 2).
///
/// Test vector: `"2015-04-24T22:23:42.123Z-1000-0123456789ABCDEF"` → `2838536857`.
enum Murmur3 {
    static func hash(_ bytes: [UInt8], seed: UInt32 = 0) -> UInt32 {
        let c1: UInt32 = 0xcc9e2d51
        let c2: UInt32 = 0x1b873593
        var h1 = seed
        let blockCount = bytes.count / 4

        var i = 0
        for _ in 0..<blockCount {
            var k1 = UInt32(bytes[i])
                | (UInt32(bytes[i + 1]) << 8)
                | (UInt32(bytes[i + 2]) << 16)
                | (UInt32(bytes[i + 3]) << 24)
            i += 4
            k1 = k1 &* c1
            k1 = (k1 << 15) | (k1 >> 17)
            k1 = k1 &* c2
            h1 ^= k1
            h1 = (h1 << 13) | (h1 >> 19)
            h1 = h1 &* 5 &+ 0xe6546b64
        }

        var k1: UInt32 = 0
        let tail = blockCount * 4
        let remainder = bytes.count & 3
        if remainder >= 3 { k1 ^= UInt32(bytes[tail + 2]) << 16 }
        if remainder >= 2 { k1 ^= UInt32(bytes[tail + 1]) << 8 }
        if remainder >= 1 {
            k1 ^= UInt32(bytes[tail])
            k1 = k1 &* c1
            k1 = (k1 << 15) | (k1 >> 17)
            k1 = k1 &* c2
            h1 ^= k1
        }

        h1 ^= UInt32(bytes.count)
        h1 ^= h1 >> 16
        h1 = h1 &* 0x85ebca6b
        h1 ^= h1 >> 13
        h1 = h1 &* 0xc2b2ae35
        h1 ^= h1 >> 16
        return h1
    }
}

// MARK: - MerkleTrie

/// Trinary radix trie used by Actual to detect sync divergence (docs/PROTOCOL.md §4).
///
/// - Key: `floor(millis / 60000)` — minutes since epoch — rendered in **base 3** (digits 0/1/2),
///   one trie level per digit, no leading-zero padding on insert.
/// - Node hash: XOR of `Murmur3.hash(utf8(timestamp.description))` of every timestamp ever
///   inserted at-or-below the node (the root therefore hashes the entire history).
/// - Persistence: value semantics — `inserting`/`pruned` return new tries sharing untouched
///   subtrees (immutable nodes), matching the JS functional-update style. Always use the return
///   value (PROTOCOL §4.4's `build()` caution).
///
/// JSON round-trip is byte-compatible with Actual's `JSON.stringify(trie)`:
/// `{"0":{...},"1":{...},"2":{...},"hash":n}` — numeric child keys first, then `hash`, no
/// whitespace, and `hash` serialized as a **signed** Int32 (JS's XOR coerces through ToInt32, so
/// upstream tries carry negative numbers for hashes with bit 31 set). ASCII-sorted keys
/// ("0" < "1" < "2" < "hash") reproduce JS's own-property enumeration order exactly.
struct MerkleTrie: Sendable {
    private final class Node: Sendable {
        let hash: UInt32
        /// Exactly 3 slots, indexed by base-3 digit.
        let children: [Node?]

        init(hash: UInt32, children: [Node?]) {
            self.hash = hash
            self.children = children
        }

        static var empty: Node { Node(hash: 0, children: [nil, nil, nil]) }
    }

    private let root: Node

    /// The empty trie (`{hash: 0}`).
    init() {
        self.root = Node.empty
    }

    private init(root: Node) {
        self.root = root
    }

    // MARK: JSON

    /// Tolerant parse of Actual's serialized trie. Invalid JSON / non-object input yields the
    /// empty trie — mirroring `deserializeClock`'s `merkle: {}` fallback. A node with no `hash`
    /// key parses as hash 0.
    static func fromJSON(_ s: String) -> MerkleTrie {
        guard !s.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)),
              let dict = obj as? [String: Any] else {
            return MerkleTrie()
        }
        return MerkleTrie(root: node(fromJSONObject: dict))
    }

    private static func node(fromJSONObject dict: [String: Any]) -> Node {
        var hash: UInt32 = 0
        if let n = dict["hash"] as? NSNumber {
            // int32Value preserves the low-32 bit pattern for both signed (JS ToInt32) and
            // unsigned (raw murmur) encodings.
            hash = UInt32(bitPattern: n.int32Value)
        }
        var children: [Node?] = [nil, nil, nil]
        for digit in 0..<3 {
            if let child = dict[String(digit)] as? [String: Any] {
                children[digit] = node(fromJSONObject: child)
            }
        }
        return Node(hash: hash, children: children)
    }

    /// Serialize byte-compatibly with `JSON.stringify` of the JS trie (see type doc).
    func toJSON() -> String {
        let obj = Self.jsonObject(of: root)
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"hash\":0}"
        }
        return s
    }

    private static func jsonObject(of node: Node) -> [String: Any] {
        var dict: [String: Any] = ["hash": Int(Int32(bitPattern: node.hash))]
        for digit in 0..<3 {
            if let child = node.children[digit] {
                dict[String(digit)] = jsonObject(of: child)
            }
        }
        return dict
    }

    // MARK: Insert

    /// A new trie with `ts` folded in: the timestamp's murmur hash is XOR'd into every node along
    /// the base-3(minutes) path, root included (PROTOCOL §4.2).
    func inserting(_ ts: HLCTimestamp) -> MerkleTrie {
        let hash = Murmur3.hash(Array(ts.description.utf8))
        let minutes = ts.millis / 60_000
        let digits = Array(String(minutes, radix: 3).utf8).map { Int($0) - 48 }
        return MerkleTrie(root: Self.insert(root, digits: digits[...], hash: hash))
    }

    private static func insert(_ node: Node?, digits: ArraySlice<Int>, hash: UInt32) -> Node {
        let current = node ?? Node.empty
        let newHash = current.hash ^ hash
        guard let digit = digits.first, (0...2).contains(digit) else {
            return Node(hash: newHash, children: current.children)
        }
        var children = current.children
        children[digit] = insert(children[digit], digits: digits.dropFirst(), hash: hash)
        return Node(hash: newHash, children: children)
    }

    // MARK: Diff

    /// nil when the tries agree (equal root hashes); otherwise the epoch **milliseconds** of the
    /// earliest minute-bucket where they diverge — used as the next sync `since` cursor via
    /// `HLCTimestamp(millis: diff, counter: 0, node: "0")` (PROTOCOL §4.4, §6.4).
    ///
    /// Children are visited in ascending digit order; descent stops as soon as either side is
    /// missing a child, because pruning is lossy — "missing" must not be treated as "empty".
    func diff(_ other: MerkleTrie) -> Int64? {
        if root.hash == other.root.hash { return nil }
        var node1 = root
        var node2 = other.root
        var key = ""
        while true {
            var divergent: Int? = nil
            scan: for digit in 0..<3 {
                switch (node1.children[digit], node2.children[digit]) {
                case (nil, nil):
                    continue
                case (let a?, let b?):
                    if a.hash != b.hash {
                        divergent = digit
                        break scan
                    }
                default:
                    // Present on only one side — a pruned branch; can't localize deeper.
                    break scan
                }
            }
            guard let digit = divergent else { return Self.keyToMillis(key) }
            key += String(digit)
            node1 = node1.children[digit] ?? Node.empty
            node2 = node2.children[digit] ?? Node.empty
        }
    }

    /// Right-pad the base-3 key to 16 digits, parse base 3, convert minutes → millis
    /// (PROTOCOL §4.2 `keyToTimestamp`). The empty key maps to 0.
    private static func keyToMillis(_ key: String) -> Int64 {
        let padded = key.count >= 16 ? key : key + String(repeating: "0", count: 16 - key.count)
        var minutes: Int64 = 0
        for c in padded {
            minutes = minutes * 3 + Int64(c.wholeNumberValue ?? 0)
        }
        return minutes * 60_000
    }

    // MARK: Prune

    /// Keep only the 2 largest (most recent) child digits at every level, recursively
    /// (PROTOCOL §4.4 `prune`, default n=2). Ancestor hashes already fold in the dropped
    /// branches, so the root hash is unchanged — only diff localization precision is lost.
    /// A node whose hash is 0 is returned untouched (JS's `if (!trie.hash) return trie`).
    func pruned() -> MerkleTrie {
        MerkleTrie(root: Self.prune(root))
    }

    private static func prune(_ node: Node, keep: Int = 2) -> Node {
        if node.hash == 0 { return node }
        var present: [Int] = []
        for digit in 0..<3 where node.children[digit] != nil {
            present.append(digit)
        }
        var children: [Node?] = [nil, nil, nil]
        for digit in present.suffix(keep) {
            if let child = node.children[digit] {
                children[digit] = prune(child, keep: keep)
            }
        }
        return Node(hash: node.hash, children: children)
    }
}
