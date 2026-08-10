import Foundation
import CryptoKit
import os

// MARK: - EmbeddingIndex
//
// Semantic memory over transactions (docs/AI.md §3): an actor owning its own local-only
// SQLite file — `nidget-ai.sqlite`, stored beside the budget file in Documents and never
// synced to the Actual server. Embedding-call patterns (asymmetric nomic/BGE prefixes,
// dot product over L2-normalized vectors) follow HomeBoy's EmbeddingService; the blocking
// llama work itself runs on `AIModelManager.Engine`, never here and never on the main thread.
//
// Schema:
//   tx_embeddings(tx_id TEXT PK, model_id TEXT, text_hash TEXT, vector BLOB)  -- LE Float32
//   meta(key TEXT PK, value TEXT)                                             -- model marker
//
// Reindexing is incremental: only rows whose SHA256(text + model id) changed are re-embedded,
// in batches of 32 with `Task.yield()` between batches, publishing (done, total) progress via
// `AIModelManager.setIndexingProgress`. The whole table is wiped when the embedding model
// changes. Vectors are additionally cached in memory for brute-force cosine `nearest(to:)`.

actor EmbeddingIndex {
    static let shared = EmbeddingIndex()

    private static let log = Logger(subsystem: "app.nidget", category: "ai")

    private var db: SQLiteDB?
    private var cache: [CacheEntry] = []   // in-memory vectors for brute-force cosine
    private var cacheLoaded = false
    private var reindexToken = 0           // latest reindex wins; stale loops abort

    private struct CacheEntry {
        var txID: String
        var vector: [Float]
        var categoryID: String?
    }

    // MARK: - Location

    /// Documents/nidget-ai.sqlite — beside the budget file (mirrors `AppStore.budgetFileURL`).
    static func databaseURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("nidget-ai.sqlite")
    }

    /// Canonical embedded text for a transaction: "<payee name> — <notes>", skipping
    /// empty parts, lowercased (docs/AI.md §3).
    static func embeddedText(payee: String?, notes: String?) -> String {
        [payee, notes]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
            .lowercased()
    }

    // MARK: - Reindex

    /// Incrementally (re)embed `transactions` with the model identified by `modelID`.
    /// Only rows whose text hash changed are re-embedded; rows for vanished transactions
    /// are deleted; everything is wiped first when `modelID` differs from the indexed one.
    /// Quietly does nothing when the embedder can't load (no model installed).
    func reindex(transactions: [(id: String, text: String, categoryID: String?)],
                 modelID: String) async {
        reindexToken += 1
        let token = reindexToken
        guard !modelID.isEmpty else { return }

        let database: SQLiteDB
        do {
            database = try openDatabase()
        } catch {
            Self.log.notice("Embedding index unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }

        do {
            // Wipe-and-rebuild when the embedding model changed.
            var indexedModel: String?
            if case .some(.text(let stored)) = try database.scalar(
                "SELECT value FROM meta WHERE key = 'embedding_model'", []) {
                indexedModel = stored
            }
            if indexedModel != modelID {
                try database.exec("DELETE FROM tx_embeddings")
                try database.run(
                    "INSERT OR REPLACE INTO meta (key, value) VALUES ('embedding_model', ?)",
                    [.text(modelID)])
                cache = []
                cacheLoaded = true
            }

            // Existing rows (tx_id → text_hash) for the incremental diff.
            var existing: [String: String] = [:]
            for row in try database.query("SELECT tx_id, text_hash FROM tx_embeddings", []) {
                if let id = row.string("tx_id"), let hash = row.string("text_hash") {
                    existing[id] = hash
                }
            }

            // Drop rows for transactions that no longer exist (or lost their text).
            let currentIDs = Set(transactions.filter { !$0.text.isEmpty }.map { $0.id })
            let stale = existing.keys.filter { !currentIDs.contains($0) }
            if !stale.isEmpty {
                try database.transaction {
                    for id in stale {
                        try database.run("DELETE FROM tx_embeddings WHERE tx_id = ?", [.text(id)])
                    }
                }
                for id in stale { existing[id] = nil }
            }

            // Work list: rows whose SHA256(text + model id) changed.
            var work: [(id: String, text: String, hash: String)] = []
            for tx in transactions where !tx.text.isEmpty {
                let hash = Self.textHash(tx.text, modelID: modelID)
                if existing[tx.id] != hash { work.append((tx.id, tx.text, hash)) }
            }

            let categoryByID = Dictionary(transactions.map { ($0.id, $0.categoryID) },
                                          uniquingKeysWith: { first, _ in first })
            let total = work.count
            if total == 0 {
                try loadCache(categories: categoryByID)
                await AIModelManager.shared.setIndexingProgress(nil)
                return
            }

            await AIModelManager.shared.setIndexingProgress(AIIndexingProgress(done: 0, total: total))

            let engine = AIModelManager.shared.embedder
            var done = 0
            var batchStart = 0
            while batchStart < work.count {
                guard token == reindexToken, !Task.isCancelled else {
                    await AIModelManager.shared.setIndexingProgress(nil)
                    return
                }
                let batch = Array(work[batchStart..<min(batchStart + 32, work.count)])
                let vectors = await engine.embedBatch(batch.map { $0.text }, isQuery: false)
                guard vectors.contains(where: { $0 != nil }) else {
                    // Embedder unavailable (no model installed / failed to load) — stop quietly.
                    Self.log.info("Reindex stopped: embedder unavailable")
                    await AIModelManager.shared.setIndexingProgress(nil)
                    return
                }
                try database.transaction {
                    for (item, vector) in zip(batch, vectors) {
                        guard let vector else { continue }
                        try database.run(
                            """
                            INSERT OR REPLACE INTO tx_embeddings (tx_id, model_id, text_hash, vector)
                            VALUES (?, ?, ?, ?)
                            """,
                            [.text(item.id), .text(modelID), .text(item.hash),
                             .blob(Self.blob(from: vector))])
                    }
                }
                done += batch.count
                batchStart += 32
                await AIModelManager.shared.setIndexingProgress(
                    AIIndexingProgress(done: done, total: total))
                await Task.yield()
            }

            try loadCache(categories: categoryByID)
            await AIModelManager.shared.setIndexingProgress(nil)
            Self.log.debug("Reindex finished: \(done) embedded, \(self.cache.count) cached")
        } catch {
            Self.log.notice("Reindex failed: \(error.localizedDescription, privacy: .public)")
            await AIModelManager.shared.setIndexingProgress(nil)
        }
    }

    // MARK: - Queries

    /// Brute-force cosine nearest neighbours over the in-memory vector cache. Vectors are
    /// L2-normalized by the bridge, so a dot product IS the cosine similarity. Empty when
    /// no embedding model is available or nothing is indexed.
    func nearest(to text: String, limit: Int) async -> [(txID: String, similarity: Float)] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        ensureCacheLoaded()
        guard !cache.isEmpty else { return [] }
        guard let query = await AIModelManager.shared.embedder.embed(trimmed, isQuery: true) else {
            return []
        }
        var scored: [(txID: String, similarity: Float)] = []
        scored.reserveCapacity(cache.count)
        for entry in cache {
            scored.append((entry.txID, Self.dot(query, entry.vector)))
        }
        scored.sort { $0.similarity > $1.similarity }
        return Array(scored.prefix(limit))
    }

    /// Like `nearest(to:limit:)` but restricted to transactions with a known category —
    /// the kNN input for category suggestions. Category ids live only in the in-memory
    /// cache (populated by the latest `reindex` input), never in the SQLite file.
    func nearestCategorized(to text: String, limit: Int) async
        -> [(txID: String, categoryID: String, similarity: Float)] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        ensureCacheLoaded()
        let candidates = cache.filter { $0.categoryID != nil }
        guard !candidates.isEmpty else { return [] }
        guard let query = await AIModelManager.shared.embedder.embed(trimmed, isQuery: true) else {
            return []
        }
        var scored: [(txID: String, categoryID: String, similarity: Float)] = []
        scored.reserveCapacity(candidates.count)
        for entry in candidates {
            guard let categoryID = entry.categoryID else { continue }
            scored.append((entry.txID, categoryID, Self.dot(query, entry.vector)))
        }
        scored.sort { $0.similarity > $1.similarity }
        return Array(scored.prefix(limit))
    }

    /// Number of transactions currently indexed (for the "N of M indexed" line).
    func indexedCount() async -> Int {
        guard let database = try? openDatabase(),
              let value = try? database.scalar("SELECT COUNT(*) FROM tx_embeddings", []),
              case .some(.int(let count)) = value else { return 0 }
        return Int(count)
    }

    // MARK: - Teardown

    /// Closes and removes `nidget-ai.sqlite` (with its WAL siblings) and clears the cache.
    /// Called from `AppStore.disconnectAndWipe()`.
    func deleteDatabaseFile() {
        reindexToken += 1   // abort any in-flight reindex at its next batch boundary
        db?.close()
        db = nil
        cache = []
        cacheLoaded = false
        guard let url = Self.databaseURL() else { return }
        let fm = FileManager.default
        let base = url.path(percentEncoded: false)
        for suffix in ["", "-wal", "-shm"] {
            let path = base + suffix
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Internals

    private func openDatabase() throws -> SQLiteDB {
        if let db { return db }
        guard let url = Self.databaseURL() else {
            throw DBError.openFailed("Documents directory unavailable")
        }
        let database = try SQLiteDB(path: url.path(percentEncoded: false))
        try database.exec(
            """
            CREATE TABLE IF NOT EXISTS tx_embeddings (
              tx_id TEXT PRIMARY KEY,
              model_id TEXT NOT NULL,
              text_hash TEXT NOT NULL,
              vector BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            """)
        // Local-only derived data: protect like the budget file, never back it up.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path(percentEncoded: false))
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
        db = database
        return database
    }

    private func ensureCacheLoaded() {
        guard !cacheLoaded else { return }
        do {
            try loadCache(categories: [:])
        } catch {
            Self.log.notice("Embedding cache load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// (Re)build the in-memory vector cache from SQLite, attaching category ids from the
    /// most recent reindex input where known.
    private func loadCache(categories: [String: String?]) throws {
        let database = try openDatabase()
        var entries: [CacheEntry] = []
        for row in try database.query("SELECT tx_id, vector FROM tx_embeddings", []) {
            guard let id = row.string("tx_id"), let data = row.data("vector") else { continue }
            let vector = Self.vector(from: data)
            guard !vector.isEmpty else { continue }
            entries.append(CacheEntry(txID: id, vector: vector, categoryID: categories[id] ?? nil))
        }
        cache = entries
        cacheLoaded = true
    }

    // MARK: - Vector encoding (little-endian Float32 BLOBs) & math

    private static func blob(from vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func vector(from data: Data) -> [Float] {
        let count = data.count / 4
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let bits = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                out[i] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return out
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var s: Float = 0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }

    private static func textHash(_ text: String, modelID: String) -> String {
        let digest = SHA256.hash(data: Data((text + "|" + modelID).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
