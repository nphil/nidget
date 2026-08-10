import Foundation
import os

// MARK: - SyncOutcome

/// Result of one `SyncEngine.fullSync()` round trip (ARCHITECTURE §8).
struct SyncOutcome: Sendable {
    /// Messages sent to the server (initial batch + merkle-retry batch).
    var pushed: Int
    /// Messages received from the server (decoded envelopes, both rounds).
    var pulled: Int
    /// Datasets whose domain rows actually changed from applied incoming messages — the signal
    /// AppStore uses to decide what to refresh.
    var changedDatasets: Set<String>
}

// MARK: - SyncError

/// Failures from the sync engine (ARCHITECTURE §4: one error enum per subsystem).
enum SyncError: Error, LocalizedError, Equatable {
    /// Network unavailable — everything stays queued in the pending outbox; AppStore shows the
    /// pending count.
    case offline
    /// No token available from the token provider (not logged in / keychain wiped).
    case notAuthenticated
    /// The hybrid logical clock refused a timestamp (drift > 5 min or counter overflow —
    /// PROTOCOL §3.3–3.5; Actual re-throws these as `SyncError('clock-drift')`).
    case clock(HLCError)
    /// The server sent E2E-encrypted messages but no key is loaded (or decryption failed).
    /// Local state for everything decryptable was still applied and persisted before throwing.
    case encryptedMessagesWithoutKey(count: Int)

    var errorDescription: String? {
        switch self {
        case .offline:
            return "You're offline. Changes are saved on this device and will sync automatically."
        case .notAuthenticated:
            return "Not signed in to the sync server. Reconnect in Settings."
        case .clock(let error):
            return error.errorDescription
        case .encryptedMessagesWithoutKey(let count):
            return "\(count) synced change\(count == 1 ? "" : "s") couldn't be decrypted. Enter your end-to-end encryption password in Settings."
        }
    }
}

// MARK: - SyncEngine

/// The CRDT sync engine (ARCHITECTURE §8, flow per docs/PROTOCOL.md §6).
///
/// Responsibilities:
/// - Owns the hybrid logical clock (`HLCClock`) and the local merkle trie, restored from the
///   budget file's `messages_clock` row (PROTOCOL §3.7 / §6.1) on first use.
/// - `nextTimestamps` mints `send()` timestamps for Mutations.
/// - `enqueue` applies local mutations to the DB immediately (offline is the default path —
///   ARCHITECTURE §8 pending-outbox note), records them in `messages_crdt` + merkle, stores
///   them in the `local_pending_messages` outbox, then triggers a debounced sync.
/// - `fullSync` runs the §6.4 round trip: push pending, apply the response, merkle-verify,
///   retry once from the divergence point.
/// - Every applied batch — domain rows, `messages_crdt`, the outbox change, and the
///   `messages_clock` clock+merkle row — commits in ONE SQLite transaction (§6.1 / §6.3 step 5),
///   and the in-memory merkle is updated only after the commit succeeds (§6.3 step 6), so a
///   crash mid-batch can never strand a message outside the outbox or the persisted trie.
/// - `resetNodeID` re-mints this client's HLC node id after a fresh server download (§8.2's
///   `resetClock` signal) so two clients never share a node id.
///
/// Cursor persistence: Actual keeps `lastSyncedTimestamp` in its *prefs* store, NOT inside the
/// `messages_clock` JSON — `serializeClock` (PROTOCOL §3.7) fixes that JSON to exactly
/// `{timestamp, merkle}`, and `BudgetDatabase.saveClockState(clock:merkle:)` mirrors that shape
/// with no extra slot. Nidget therefore mirrors Actual's prefs approach with a UserDefaults key
/// namespaced by fileID (`nidget.sync.lastSyncedTimestamp.<fileID>`).
actor SyncEngine {
    private static let log = Logger(subsystem: "app.nidget", category: "sync")

    private let api: ActualAPI
    private let dbQueue: DatabaseQueue
    private let fileID: String
    private let groupID: String
    private let tokenProvider: @Sendable () -> String?
    private let e2eKey: E2EKey?

    /// Loaded/created lazily by `ensureState()` — the contract init is synchronous while all
    /// DB access is async via DatabaseQueue, so the "load clock state on init" step runs on
    /// first use instead (same observable behavior: state is ready before any timestamp is
    /// minted or any message is applied).
    private var clock: HLCClock?
    private var merkle: MerkleTrie = MerkleTrie.fromJSON("{}")

    private(set) var isSyncing = false
    private var inFlightSync: Task<SyncOutcome, Error>?
    private var debounceTask: Task<Void, Never>?

    init(api: ActualAPI, dbQueue: DatabaseQueue, fileID: String, groupID: String,
         tokenProvider: @escaping @Sendable () -> String?, e2eKey: E2EKey?) {
        self.api = api
        self.dbQueue = dbQueue
        self.fileID = fileID
        self.groupID = groupID
        self.tokenProvider = tokenProvider
        self.e2eKey = e2eKey
    }

    deinit {
        debounceTask?.cancel()
        inFlightSync?.cancel()
    }

    // MARK: - Timestamps for Mutations

    /// Mints `count` fresh HLC `send()` timestamps (PROTOCOL §3.3), in order. They are NOT
    /// inserted into the merkle here — that happens when the finished messages are enqueued
    /// (mirroring Actual, where only `applyMessages` folds timestamps into the trie, §6.3).
    func nextTimestamps(_ count: Int) async throws -> [String] {
        guard count > 0 else { return [] }
        let clock = try await ensureState()
        var stamps: [String] = []
        stamps.reserveCapacity(count)
        for _ in 0..<count {
            stamps.append(try clock.send().description)
        }
        return stamps
    }

    /// Labeled convenience — ARCHITECTURE §9 shows call sites as `engine.nextTimestamps(count:)`.
    func nextTimestamps(count: Int) async throws -> [String] {
        try await nextTimestamps(count)
    }

    // MARK: - Node identity

    /// Re-mints this client's HLC node id, keeping the restored logical time and merkle.
    /// Must be called once right after a fresh server download, BEFORE any timestamp is minted:
    /// the downloaded `db.sqlite` still carries the uploading client's `messages_clock` row, and
    /// two clients sharing a node id can mint identical 46-char timestamps whose edits dedupe
    /// each other away (PROTOCOL §3.2 / §8.2 — `metadata.json`'s `resetClock` flag exists
    /// precisely to make importers re-mint). Reopening an existing local file must NOT call
    /// this — that path keeps the node id it already owns.
    func resetNodeID() async throws {
        let clock = try await ensureState()
        let current = clock.current
        clock.current = HLCTimestamp(millis: current.millis,
                                     counter: current.counter,
                                     node: HLCClock.makeClientId())
        let clockString = clock.current.description
        let merkleJSON = merkle.toJSON()
        try await dbQueue.write { db -> Void in
            try db.saveClockState(clock: clockString, merkle: merkleJSON)
        }
    }

    // MARK: - Local mutations

    /// Applies locally-created messages (from Mutations) per PROTOCOL §6.3: domain apply + append
    /// to `messages_crdt` (LWW), insert into the merkle, store into the pending outbox, and
    /// persist clock + merkle — ALL inside one SQLite transaction (§6.3 step 5), so a crash can
    /// never leave a message applied but missing from the outbox or the persisted trie.
    /// Everything local happens before any network — offline loses nothing (ARCHITECTURE §8).
    ///
    /// Returns false when the batch could not be committed — nothing was applied or queued, the
    /// failure is logged, and AppStore surfaces it via `lastError`. The debounced sync fires
    /// only on success.
    @discardableResult
    func enqueue(_ messages: [CRDTMessage]) async -> Bool {
        guard !messages.isEmpty else { return true }
        do {
            let clock = try await ensureState()
            let clockString = clock.current.description
            let newTrie = try await dbQueue.write { db -> MerkleTrie in
                try db.transaction {
                    var new: [String] = []
                    for message in messages {
                        // Exact-duplicate timestamps are dropped by the apply without re-entering
                        // messages_crdt (§6.3 step 2) — track "actually new" here so the merkle
                        // never XORs the same hash twice (double-insert would REMOVE it).
                        if try db.haveTimestamp(message.timestamp) { continue }
                        _ = try db.applyInTransaction(message, insertOnly: false)
                        new.append(message.timestamp)
                    }
                    try db.enqueuePendingInTransaction(messages)
                    // Fold into the trie PERSISTED in this same transaction (not a pre-await
                    // snapshot): batches that interleave on this actor each accumulate on top
                    // of the other's committed state instead of clobbering it.
                    let persisted = (try db.clockState())?.merkle ?? "{}"
                    let trie = Self.inserting(new, into: MerkleTrie.fromJSON(persisted))
                    try db.saveClockState(clock: clockString, merkle: trie.toJSON())
                    return trie
                }
            }
            merkle = newTrie  // §6.3 step 6: in-memory state only after the commit succeeded
            scheduleDebouncedSync()
            return true
        } catch {
            Self.log.error("enqueue failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Full sync

    /// One full §6.4 sync round trip. Reentrancy-safe: concurrent callers join the in-flight
    /// sync and receive its outcome instead of starting a second one.
    @discardableResult
    func fullSync() async throws -> SyncOutcome {
        if let existing = inFlightSync {
            return try await existing.value
        }
        isSyncing = true
        let task = Task {
            try await self.performFullSync()
        }
        inFlightSync = task
        do {
            let outcome = try await task.value
            inFlightSync = nil
            isSyncing = false
            return outcome
        } catch {
            inFlightSync = nil
            isSyncing = false
            throw error
        }
    }

    private func performFullSync() async throws -> SyncOutcome {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw SyncError.notAuthenticated
        }
        let clock = try await ensureState()

        // §6.4: since = last successful cursor, else a synthetic timestamp 5 minutes before now
        // (a never-synced client asks only for a short recent window — the initial full state
        // came from the zip download, not from replaying messages since epoch).
        let since = storedLastSyncedTimestamp()
            ?? HLCTimestamp(millis: Self.nowMillis() - 5 * 60 * 1000, counter: 0, node: "0").description

        // Push the offline outbox: everything the server has not yet acknowledged
        // (ARCHITECTURE §8 pending-outbox).
        let pending = try await dbQueue.read { db -> [CRDTMessage] in
            try db.pendingMessages()
        }

        var round = try await syncRound(token: token, since: since, outbound: pending, clock: clock)
        var pushed = round.pushed
        var pulled = round.pulled
        var changed = round.changedDatasets
        var undecryptable = round.undecryptable
        var fullyConverged = false

        if undecryptable == 0 {
            // §6.4 merkle verification: compare our trie against the server's. On divergence,
            // re-sync ONCE from the divergence minute (Actual loops up to 10/100 times; Nidget
            // retries once per fullSync and lets the next sync continue the repair).
            if let diffMillis = merkle.diff(round.serverMerkle) {
                let retrySince = HLCTimestamp(millis: diffMillis, counter: 0, node: "0").description
                // Retry outbound per §6.4: everything in messages_crdt after the new cursor
                // (not just the outbox) so the server can fill any hole on its side too.
                let retryOutbound = try await dbQueue.read { db -> [CRDTMessage] in
                    try db.messagesSince(retrySince)
                }
                round = try await syncRound(token: token, since: retrySince,
                                            outbound: retryOutbound, clock: clock)
                pushed += round.pushed
                pulled += round.pulled
                changed.formUnion(round.changedDatasets)
                undecryptable += round.undecryptable
                if undecryptable == 0 {
                    if merkle.diff(round.serverMerkle) == nil {
                        fullyConverged = true
                    } else {
                        Self.log.warning("merkle still divergent after one retry; next sync will continue the repair")
                    }
                }
            } else {
                fullyConverged = true
            }
        }

        // Clock + merkle were persisted inside each round's atomic batch (§6.3 step 5) — no
        // separate persist here, so a crash can never split data from bookkeeping.

        // §6.4: only a fully-converged sync advances the lastSyncedTimestamp cursor.
        if fullyConverged {
            storeLastSyncedTimestamp(clock.current.description)
        }
        if undecryptable > 0 {
            // Everything decryptable was applied and persisted; surface the gap so AppStore can
            // prompt for the E2E password (skip-and-collect per task spec — the merkle retry is
            // skipped because it cannot succeed while messages are undecryptable).
            throw SyncError.encryptedMessagesWithoutKey(count: undecryptable)
        }
        Self.log.info("sync complete: pushed \(pushed) pulled \(pulled) changedDatasets \(changed.count)")
        return SyncOutcome(pushed: pushed, pulled: pulled, changedDatasets: changed)
    }

    // MARK: - One request/response round

    private struct RoundResult {
        var serverMerkle: MerkleTrie
        var pushed: Int
        var pulled: Int
        var changedDatasets: Set<String>
        var undecryptable: Int
    }

    private struct AppliedBatch: Sendable {
        var merkle: MerkleTrie
        var changedDatasets: Set<String>
    }

    private func syncRound(token: String, since: String, outbound: [CRDTMessage],
                           clock: HLCClock) async throws -> RoundResult {
        // Encode outbound envelopes (PROTOCOL §2 MessageEnvelope). With an E2E key, the content
        // is the AES-256-GCM-encrypted protobuf Message wrapped in EncryptedData; the envelope
        // timestamp always stays plaintext (§7.3 — the server needs it for merkle bookkeeping).
        var envelopes: [EnvelopeOut] = []
        envelopes.reserveCapacity(outbound.count)
        for message in outbound {
            if let key = e2eKey {
                let sealed = try key.encrypt(message.serializedMessage())
                let wrapped = EncryptedData(iv: sealed.iv, authTag: sealed.authTag,
                                            data: sealed.data)
                envelopes.append(EnvelopeOut(timestamp: message.timestamp,
                                             isEncrypted: true,
                                             content: wrapped.serialized()))
            } else {
                envelopes.append(EnvelopeOut(message))
            }
        }

        // §7.4: keyId always carries the file's current encryption key id when one is loaded.
        let request = SyncRequest(messages: envelopes, fileID: fileID, groupID: groupID,
                                  keyID: e2eKey?.keyID, since: since)

        let response: SyncResponse
        do {
            response = try await api.sync(token: token, request: request)
        } catch ActualAPIError.offline {
            throw SyncError.offline
        }

        // Decode inbound envelopes: EncryptedData-unwrap + decrypt when isEncrypted (§7.3),
        // then protobuf Message decode (§2) with the §5 tagged-value scheme.
        var incoming: [CRDTMessage] = []
        var undecryptable = 0
        incoming.reserveCapacity(response.messages.count)
        for envelope in response.messages {
            let message: CRDTMessage?
            if envelope.isEncrypted {
                guard let key = e2eKey else {
                    undecryptable += 1  // skip + collect: no key loaded for this file
                    continue
                }
                do {
                    let encrypted = try EncryptedData(parsing: envelope.content)
                    let body = try key.decrypt(iv: encrypted.iv, authTag: encrypted.authTag,
                                               data: encrypted.data)
                    message = try? CRDTMessage(timestamp: envelope.timestamp, parsingMessage: body)
                } catch {
                    undecryptable += 1  // wrong key / corrupted payload
                    continue
                }
            } else {
                message = try? envelope.decodeMessage()
            }
            // Require the addressing fields — a message that can't name its cell is undecodable
            // (proto3 omits empty strings, so absent fields surface as "").
            if let message, !message.dataset.isEmpty, !message.row.isEmpty, !message.column.isEmpty {
                incoming.append(message)
            } else {
                Self.log.error("dropping undecodable sync message envelope")
            }
        }

        // §6.3 step 3: apply in ascending timestamp order (plain string sort — the HLC string
        // format is lexicographically chronological, PROTOCOL §10 trap 1).
        incoming.sort { $0.timestamp < $1.timestamp }

        // §3.4: recv() every incoming timestamp BEFORE applying, so future send()s are causally
        // after everything received. Clock drift/overflow becomes SyncError.clock.
        do {
            for message in incoming {
                if let ts = HLCTimestamp.parse(message.timestamp) {
                    try clock.recv(ts)
                }
            }
        } catch let error as HLCError {
            throw SyncError.clock(error)
        }

        // §6.3 step 5: apply the whole batch in ONE SQLite transaction — domain rows +
        // messages_crdt (§6.2 insert-or-update LWW inside applyInTransaction), the outbox ack
        // (a successful POST means the server stored our batch — clear those rows), and the
        // clock+merkle persist. The merkle folds into the trie persisted in this same
        // transaction, so batches that interleave on this actor accumulate instead of
        // clobbering each other.
        let sentTimestamps = outbound.map(\.timestamp)
        let clockString = clock.current.description
        let batch = try await dbQueue.write { db -> AppliedBatch in
            try db.transaction {
                var newTimestamps: [String] = []
                var changedDatasets: Set<String> = []
                for message in incoming {
                    let isNew = !(try db.haveTimestamp(message.timestamp))
                    let changedDomain = try db.applyInTransaction(message, insertOnly: false)
                    if isNew { newTimestamps.append(message.timestamp) }
                    if changedDomain { changedDatasets.insert(message.dataset) }
                }
                try db.clearPendingInTransaction(sentTimestamps)
                let persisted = (try db.clockState())?.merkle ?? "{}"
                let trie = Self.inserting(newTimestamps, into: MerkleTrie.fromJSON(persisted))
                try db.saveClockState(clock: clockString, merkle: trie.toJSON())
                return AppliedBatch(merkle: trie, changedDatasets: changedDatasets)
            }
        }
        merkle = batch.merkle  // §6.3 step 6: in-memory state only after the commit succeeded

        return RoundResult(serverMerkle: MerkleTrie.fromJSON(response.merkle),
                           pushed: outbound.count,
                           pulled: incoming.count,
                           changedDatasets: batch.changedDatasets,
                           undecryptable: undecryptable)
    }

    // MARK: - Clock & merkle state

    private struct ClockSnapshot: Sendable {
        var clock: String
        var merkle: String
    }

    /// Restores the clock + merkle from `messages_clock` (PROTOCOL §3.7 / §6.1) on first use;
    /// when the file has none, mints a fresh node id (`makeClientId`, §3.2) with an empty
    /// merkle and persists immediately. Safe against actor-reentrant callers: the cached clock
    /// is re-checked after every await.
    private func ensureState() async throws -> HLCClock {
        if let clock { return clock }
        let persisted = try await dbQueue.read { db -> ClockSnapshot? in
            guard let state = try db.clockState() else { return nil }
            return ClockSnapshot(clock: state.clock, merkle: state.merkle)
        }
        if let clock { return clock }  // an interleaved caller finished loading first
        if let persisted, let ts = HLCTimestamp.parse(persisted.clock) {
            let restored = HLCClock(node: ts.node)
            restored.current = ts
            clock = restored
            merkle = MerkleTrie.fromJSON(persisted.merkle)
            return restored
        }
        let fresh = HLCClock(node: HLCClock.makeClientId())
        clock = fresh
        merkle = MerkleTrie.fromJSON("{}")
        let clockString = fresh.current.description
        try await dbQueue.write { db -> Void in
            try db.saveClockState(clock: clockString, merkle: "{}")
        }
        return fresh
    }

    /// Pure fold of freshly-recorded timestamps into a merkle trie, pruning once per batch —
    /// mirroring `applyMessages`' reduce-style `merkle.insert` + single `merkle.prune`
    /// (PROTOCOL §4.4: always use insert's return value; prune keeps the 2 most recent
    /// children per level). Static + pure so the atomic batch closures can call it off the
    /// actor; callers assign the result to `merkle` only after their transaction commits.
    private static func inserting(_ timestamps: [String], into trie: MerkleTrie) -> MerkleTrie {
        guard !timestamps.isEmpty else { return trie }
        var result = trie
        for string in timestamps {
            if let ts = HLCTimestamp.parse(string) {
                result = result.inserting(ts)
            }
        }
        return result.pruned()
    }

    // MARK: - Last-synced cursor (see type doc for the storage rationale)

    private var lastSyncedDefaultsKey: String {
        "nidget.sync.lastSyncedTimestamp.\(fileID)"
    }

    private func storedLastSyncedTimestamp() -> String? {
        guard let stored = UserDefaults.standard.string(forKey: lastSyncedDefaultsKey),
              HLCTimestamp.parse(stored) != nil else {
            return nil
        }
        return stored
    }

    private func storeLastSyncedTimestamp(_ timestamp: String) {
        UserDefaults.standard.set(timestamp, forKey: lastSyncedDefaultsKey)
    }

    // MARK: - Debounced sync

    /// Coalesced fire-and-forget sync: each enqueue restarts a 1.5 s timer; when it elapses
    /// without another mutation, one fullSync runs. Failures here are logged only — the outbox
    /// keeps everything until a sync succeeds.
    private func scheduleDebouncedSync() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return  // cancelled — a newer mutation restarted the timer
            }
            guard let self else { return }
            do {
                _ = try await self.fullSync()
            } catch {
                SyncEngine.log.info("debounced sync deferred: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    private static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
