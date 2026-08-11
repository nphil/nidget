import Foundation
import os

// MARK: - CategorySuggestion

/// One category pick for a transaction, with how sure the suggester is and where the pick
/// came from: the categorized-history vote (`knn`) or the LLM refinement pass (`llm`).
struct CategorySuggestion: Sendable, Equatable {
    enum Source: Sendable {
        case knn
        case llm
    }

    var categoryID: String
    var confidence: Double
    var source: Source
}

// MARK: - CategorySuggestionService
//
// On-device category suggestions (docs/AI.md §3). The fast path is a weighted kNN vote over
// the transaction embedding index: embed "payee — notes", take the K=12 nearest transactions
// that already have a category, and let each vote with weight similarity² times a recency
// multiplier (1.0 today fading to 0.5 at 18 months). Confidence is the winner's share of the
// total weight. When the vote is weak (top share < 0.55) and a generation backend can answer, a
// compact LLM prompt picks between the top candidates; a reply that isn't a real category
// name is discarded and the kNN answer stands. Refinement goes through `AIModelManager.generate`,
// so it lands on whichever backend is in play, with the budget rule in `refinedCategoryID`
// keeping batch runs bounded.
//
// The vote needs each neighbour's category and date, which the index deliberately doesn't
// persist — so the service keeps a ledger snapshot ([tx id: Transaction]) built by paging
// `AppStore.transactions(_:)` (the only id-agnostic read the DB layer offers). The snapshot
// doubles as the id → row lookup hybrid search uses to render semantic hits. It goes stale
// whenever store data changes or a reindex finishes (`noteDataChanged()`, called by AppStore)
// and rebuilds lazily on next use.
//
// Everything degrades to nothing: no embedding model → empty results, no generation model →
// kNN only. Never logs transaction text or prompts above .debug (ARCHITECTURE §4 + AI.md §5).

@MainActor
final class CategorySuggestionService {
    static let shared = CategorySuggestionService()

    private static let log = Logger(subsystem: "app.nidget", category: "ai")

    /// K nearest categorized transactions that vote (docs/AI.md §3).
    private static let k = 12
    /// kNN top share below which the LLM refinement pass runs.
    private static let llmRefinementThreshold = 0.55
    /// ~18 months in days: the span over which a voter's recency multiplier fades 1.0 → 0.5.
    private static let recencyHorizonDays = 548.0

    private init() {}

    // MARK: - Availability

    /// True when an embedding model is selected and its file is on disk — the cheap gate
    /// every AI surface checks before doing any work. Reads observable AIModelManager and
    /// ModelDownloadManager state, so views using it in `body` re-evaluate when the
    /// selection changes or a download finishes.
    var embeddingReady: Bool {
        guard let id = AIModelManager.shared.embeddingModelID else { return false }
        return ModelDownloadManager.shared.state(for: id) == .ready
    }

    // MARK: - Suggestions

    /// Top category picks for a transaction described by `payee` (+ optional `notes`),
    /// strongest first. Empty when no embedding model is ready, nothing categorized is
    /// indexed yet, or the text is blank.
    func suggest(payee: String, notes: String? = nil, limit: Int = 3) async -> [CategorySuggestion] {
        let text = EmbeddingIndex.embeddedText(payee: payee, notes: notes)
        let capped = max(1, limit)
        guard !text.isEmpty, embeddingReady else { return [] }

        let eligible = eligibleCategories()
        guard !eligible.isEmpty else { return [] }
        let eligibleIDs = Set(eligible.map(\.id))

        let ledger = await transactionMap()
        guard !ledger.isEmpty else { return [] }

        // Over-fetch neighbours: only categorized rows vote and the index mixes in
        // uncategorized ones. K itself stays 12.
        let neighbours = await EmbeddingIndex.shared.nearest(to: text, limit: 48)
        guard !neighbours.isEmpty else { return [] }

        var weightByCategory: [String: Double] = [:]
        var voters = 0
        for hit in neighbours {
            if voters >= Self.k { break }
            guard hit.similarity > 0,
                  let transaction = ledger[hit.txID],
                  let categoryID = transaction.categoryID,
                  eligibleIDs.contains(categoryID) else { continue }
            let similarity = Double(hit.similarity)
            weightByCategory[categoryID, default: 0] +=
                similarity * similarity * Self.recencyMultiplier(for: transaction.date)
            voters += 1
        }
        let total = weightByCategory.values.reduce(0, +)
        guard total > 0 else { return [] }

        let ranked = weightByCategory
            .map { (categoryID: $0.key, confidence: $0.value / total) }
            .sorted {
                $0.confidence != $1.confidence ? $0.confidence > $1.confidence
                                               : $0.categoryID < $1.categoryID
            }
        var suggestions: [CategorySuggestion] = ranked.prefix(capped).map {
            CategorySuggestion(categoryID: $0.categoryID, confidence: $0.confidence, source: .knn)
        }

        // LLM refinement for weak votes only. kNN stays the answer whenever the generation
        // model is absent, unloaded, silent, or hallucinating (docs/AI.md §3).
        if let top = suggestions.first, top.confidence < Self.llmRefinementThreshold {
            let shortlist = Array(ranked.prefix(3))
            if let refined = await refinedCategoryID(text: text, candidates: shortlist) {
                var reordered = [CategorySuggestion(categoryID: refined,
                                                    confidence: top.confidence,
                                                    source: .llm)]
                reordered += suggestions.filter { $0.categoryID != refined }
                suggestions = Array(reordered.prefix(capped))
            }
        }
        return suggestions
    }

    /// 1.0 for a transaction from today fading linearly to 0.5 at 18 months old (docs/AI.md
    /// §3) — old habits still vote, recent ones vote louder.
    private static func recencyMultiplier(for day: BudgetDay) -> Double {
        let days = Calendar.current.dateComponents([.day], from: day.date, to: Date()).day ?? 0
        let fraction = min(max(Double(days), 0), recencyHorizonDays) / recencyHorizonDays
        return 1.0 - 0.5 * fraction
    }

    /// Categories a suggestion may point at: real, visible ones. Hidden categories and
    /// hidden groups keep their history but are never suggested.
    private func eligibleCategories() -> [Category] {
        AppStore.shared.categoryGroups
            .filter { !$0.hidden }
            .flatMap { $0.categories.filter { !$0.hidden } }
    }

    // MARK: - LLM refinement

    /// Asks the generation model to pick between weak kNN candidates. Returns a real category
    /// id, or nil (no engine, empty reply, or a hallucinated name — the caller keeps the kNN
    /// answer).
    ///
    /// Two different gates, because the two backends cost different things:
    ///
    /// - llama.cpp: only when the model is ALREADY loaded. That guard exists so refinement never
    ///   triggers a cold model load in the middle of a sync; suggestion latency and memory
    ///   pressure have to stay predictable. Unchanged from before.
    /// - Apple's on-device model: there is no load step, so it is always "ready" and that guard
    ///   has nothing to bite on. Left alone it would fire on every weak transaction, and
    ///   `AppStore.autoCategorizeNewArrivals` walks up to 50 per sync. So the batch path spends
    ///   from a budget (`resetRefinementBudget(_:)`) and stops refining once it runs out.
    ///   Interactive suggestions (Quick Add, one at a time, the user is watching) have no budget
    ///   set and are never limited.
    private func refinedCategoryID(text: String,
                                   candidates: [(categoryID: String, confidence: Double)]) async -> String? {
        let manager = AIModelManager.shared
        if manager.activeGenerationEngine == .apple {
            guard spendRefinementBudget() else { return nil }
        } else {
            guard manager.generationModelID != nil else { return nil }
            guard await manager.generator.isLoaded else { return nil }
        }

        let store = AppStore.shared
        let categories = eligibleCategories()
        guard !categories.isEmpty else { return nil }
        let candidateNames = candidates
            .map { store.categoryName($0.categoryID) }
            .filter { !$0.isEmpty }
        guard !candidateNames.isEmpty else { return nil }

        let system = "You label bank transactions with budget categories. "
            + "Answer with exactly one category name from the provided list and nothing else."
        let user = """
        Categories: \(categories.map(\.name).joined(separator: ", "))
        Transaction: \(text)
        Closest so far: \(candidateNames.joined(separator: ", "))
        Category:
        """
        // A miss on Apple's model may only fall through to llama when llama is already in
        // memory. Otherwise the fallback would cold-load the very model the rule above is
        // trying to keep out of a sync.
        let fallbackIsFree = await manager.generator.isLoaded
        guard let reply = await manager.generate(system: system, user: user,
                                                 maxTokens: 24, temperature: 0.1, topK: 10,
                                                 allowLlamaFallback: fallbackIsFree),
              !reply.isEmpty else { return nil }
        let matched = Self.categoryID(matching: reply, in: categories)
        Self.log.debug("LLM refinement \(matched != nil ? "matched a category" : "was discarded", privacy: .public)")
        return matched
    }

    // MARK: - Batch refinement budget

    /// How many Apple-model refinements the current batch may still run. nil = no batch is
    /// running, so nothing is limited (the interactive Quick Add path). Plain stored state is
    /// enough to be race-free here: the whole service is `@MainActor`, so the check and the
    /// decrement happen in one hop with no interleaving await between them.
    private var batchRefinementBudget: Int?

    /// Opens a batch and caps how many Apple refinements it may spend. Called by
    /// `AppStore.autoCategorizeNewArrivals` before it starts walking new transactions.
    func resetRefinementBudget(_ limit: Int) {
        batchRefinementBudget = max(0, limit)
    }

    /// Closes the batch: back to unlimited for interactive suggestions.
    func endRefinementBudget() {
        batchRefinementBudget = nil
    }

    /// Takes one refinement from the budget. True when there is no budget (interactive) or one
    /// was left; false once the batch has spent its allowance.
    private func spendRefinementBudget() -> Bool {
        guard let remaining = batchRefinementBudget else { return true }
        guard remaining > 0 else { return false }
        batchRefinementBudget = remaining - 1
        return true
    }

    /// Case-insensitive match of an LLM reply to a real category: first line only, quotes
    /// and stray punctuation stripped. nil = hallucinated name.
    private static func categoryID(matching reply: String, in categories: [Category]) -> String? {
        let firstLine = reply.split(separator: "\n", omittingEmptySubsequences: true).first
            .map(String.init) ?? reply
        let cleaned = firstLine.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`.!,:;")))
        guard !cleaned.isEmpty else { return nil }
        return categories.first {
            $0.name.compare(cleaned, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }?.id
    }

    // MARK: - Ledger snapshot cache

    private var ledgerByID: [String: Transaction] = [:]
    private var builtGeneration = 0        // 0 = never built
    private var dataGeneration = 1         // bumped by noteDataChanged()
    private var inFlightBuild: Task<[String: Transaction], Never>?
    private var inFlightGeneration = 0

    /// Marks the cached ledger snapshot stale — called by AppStore whenever published data
    /// changes (refreshAll) and after a reindex finishes. Cheap; the rebuild happens lazily
    /// on the next suggestion or semantic search that needs it.
    func noteDataChanged() {
        dataGeneration &+= 1
    }

    /// Forgets everything (the budget was wiped).
    func reset() {
        inFlightBuild?.cancel()
        inFlightBuild = nil
        ledgerByID = [:]
        builtGeneration = 0
        dataGeneration &+= 1
    }

    /// Full transaction rows for `ids`, in the same order and de-duplicated, from the cached
    /// ledger snapshot. Hybrid search uses this to render semantic hits — the DB layer has no
    /// id-list query, so the snapshot stands in for one.
    func transactions(matching ids: [String]) async -> [Transaction] {
        guard !ids.isEmpty else { return [] }
        let ledger = await transactionMap()
        var seen = Set<String>()
        var rows: [Transaction] = []
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            if let transaction = ledger[id] {
                rows.append(transaction)
            }
        }
        return rows
    }

    /// The current ledger snapshot, rebuilt (paged, 500 rows per read through the existing
    /// AppStore API) when stale. Generation counters make a mid-build invalidation trigger
    /// another rebuild instead of caching stale data; concurrent callers share one build.
    private func transactionMap() async -> [String: Transaction] {
        if builtGeneration == dataGeneration { return ledgerByID }
        if let inFlightBuild, inFlightGeneration == dataGeneration {
            return await inFlightBuild.value
        }
        let target = dataGeneration
        let build = Task { () -> [String: Transaction] in
            var map: [String: Transaction] = [:]
            let pageSize = 500
            var offset = 0
            while true {
                let page = await AppStore.shared.transactions(
                    TransactionQuery(limit: pageSize, offset: offset))
                for transaction in page {
                    map[transaction.id] = transaction
                }
                if page.count < pageSize { break }
                offset += page.count
            }
            return map
        }
        inFlightBuild = build
        inFlightGeneration = target
        let map = await build.value
        if inFlightGeneration == target {
            inFlightBuild = nil
            ledgerByID = map
            builtGeneration = target
        }
        return map
    }
}
