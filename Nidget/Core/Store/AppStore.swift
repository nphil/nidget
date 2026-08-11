import Foundation
import Observation
import os

// MARK: - DatabaseQueue
//
// The single serialization point for the (non-Sendable) `BudgetDatabase` (ARCHITECTURE §7).
// Owned by AppStore, shared with SyncEngine; every DB touch routes through `read`/`write`.
// The split is semantic (reads vs. mutations) — both funnel through this one actor either way.

actor DatabaseQueue {
    let db: BudgetDatabase

    init(db: BudgetDatabase) {
        self.db = db
    }

    func read<T: Sendable>(_ body: @Sendable (BudgetDatabase) throws -> T) async throws -> T {
        try body(db)
    }

    func write<T: Sendable>(_ body: @Sendable (BudgetDatabase) throws -> T) async throws -> T {
        try body(db)
    }
}

// MARK: - UI-facing value types (ARCHITECTURE §9)

/// Everything needed to create/update a transaction from the UI. `newPayeeName` is set when the
/// user typed a payee that doesn't exist yet — AppStore resolves it into `payeeID` (creating the
/// payee if needed) before building CRDT messages.
struct TransactionDraft: Sendable {
    var accountID: String
    var amount: Money
    var date: BudgetDay
    var payeeID: String?
    var newPayeeName: String?
    var categoryID: String?
    var notes: String?
    var cleared: Bool = true
}

enum SyncStatus: Equatable {
    case idle(lastSync: Date?)
    case syncing
    case offline(pending: Int)
    case error(String)
}

/// Quick Add payee lookup: `prefix` is what the user has typed so far (empty → top recents).
struct PayeeSuggestionQuery: Sendable {
    var prefix: String
    var limit: Int = 8
}

struct PayeeSuggestion: Sendable, Identifiable {
    var id: String { payeeID ?? name }
    var payeeID: String?
    var name: String
    /// The payee's most-frequent category over the recent window — Quick Add's auto-category.
    var categoryID: String?
    /// Amount of the payee's most recent transaction.
    var lastAmount: Money?
}

/// One month of envelope-budget state, built by `BudgetCalculator.snapshot`.
struct MonthBudgetSnapshot: Sendable {
    var month: BudgetMonth
    var toBudget: Money
    var income: Money
    var totalBudgeted: Money
    var totalSpent: Money
    /// Grouped and ordered exactly like `AppStore.categoryGroups`.
    var rows: [BudgetRowSnapshot]
}

struct BudgetRowSnapshot: Sendable, Identifiable {
    /// Category id.
    var id: String
    var name: String
    var groupID: String
    var budgeted: Money
    /// NEGATIVE outflow for the month.
    var spent: Money
    var balance: Money
    var carryover: Bool
    var isIncome: Bool
}

// MARK: - AppStoreError

/// Store-level failures surfaced during setup flows (connect / file selection).
enum AppStoreError: Error, LocalizedError {
    case notConnected
    case documentsUnavailable
    case e2ePasswordRequired
    case wrongE2EPassword
    case encryptedFileUnreadable
    case budgetMissingFromArchive

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to an Actual server. Add your server in Settings."
        case .documentsUnavailable:
            return "Couldn't access this device's storage for the budget file."
        case .e2ePasswordRequired:
            return "This budget file is end-to-end encrypted. Enter its encryption password."
        case .wrongE2EPassword:
            return "That end-to-end encryption password is incorrect."
        case .encryptedFileUnreadable:
            return "The encrypted budget file couldn't be unlocked. Try again."
        case .budgetMissingFromArchive:
            return "The downloaded budget archive doesn't contain a database."
        }
    }
}

// MARK: - AppStore
//
// THE UI-facing source of truth (ARCHITECTURE §9). Views talk only to this (plus ThemeManager /
// DashboardModel / pure helpers); SQLValue and CRDT types never cross this boundary. All state
// updates happen on the MainActor; all DB work happens behind DatabaseQueue; all sync work
// behind SyncEngine.

@MainActor @Observable
final class AppStore {

    // MARK: - Lifecycle

    enum SetupState: Equatable {
        case loading
        case needsServer
        case needsFilePick([RemoteFile])
        case syncingFirstTime
        case ready
        case error(String)
    }

    static let shared = AppStore()

    private(set) var setup: SetupState = .loading

    // MARK: - Published data

    private(set) var accounts: [Account] = []
    private(set) var categoryGroups: [CategoryGroup] = []
    private(set) var payees: [Payee] = []
    private(set) var budgetName: String = ""

    /// The month the Budget tab is looking at; navigation triggers a snapshot recompute.
    var currentMonth: BudgetMonth = .current {
        didSet {
            guard oldValue != currentMonth else { return }
            Task { await self.refreshMonthSnapshot() }
        }
    }

    private(set) var monthSnapshot: MonthBudgetSnapshot?
    private(set) var syncStatus: SyncStatus = .idle(lastSync: nil)
    private(set) var lastError: AppError?

    /// Blurs every AmountText app-wide. Session-scoped; the launch default comes from
    /// `Preferences.privacyModeDefault`.
    var privacyMode: Bool = false

    func clearError() {
        lastError = nil
    }

    // MARK: - Engines & caches (never exposed to views)

    private var api: ActualAPI?
    private var dbQueue: DatabaseQueue?
    private var engine: SyncEngine?
    private var cachedFiles: [RemoteFile] = []
    private var payeeNameByID: [String: String] = [:]
    private var categoryNameByID: [String: String] = [:]
    /// Debounce handle for the background embedding reindex (docs/AI.md §3).
    private var reindexDebounceTask: Task<Void, Never>?
    /// Guards `autoCategorizeNewArrivals()` against overlapping runs (docs/AI.md §3).
    private var isAutoCategorizing = false
    /// Transaction ids already tried by `autoCategorizeNewArrivals()` this session, so a
    /// low-confidence pick isn't re-embedded on every sync.
    private var autoCategorizeAttemptedIDs: Set<String> = []

    private static let log = Logger(subsystem: "app.nidget", category: "store")
    private static let aiLog = Logger(subsystem: "app.nidget", category: "ai")

    private enum KeychainKey {
        static let serverURL = "actual.serverURL"
        static let password = "actual.password"
        static let token = "actual.token"
        static let fileID = "actual.fileID"
        static let groupID = "actual.groupID"
        static let e2ePassword = "actual.e2ePassword"
    }

    private enum DefaultsKey {
        static let budgetName = "nidget.budget.name"
        static let e2eKeyID = "nidget.e2e.keyID"
        static let e2eSalt = "nidget.e2e.salt"
        static let lastSync = "nidget.sync.lastSyncDate"
    }

    private init() {}

    // MARK: - Bootstrap

    /// Called once from NidgetApp's `.task`. Flow (ARCHITECTURE §9):
    /// - no stored server credentials → `.needsServer`;
    /// - a previously-downloaded budget file exists → open it, `.ready`, background sync;
    /// - credentials but no local file → list remote files → `.needsFilePick`.
    func bootstrap() async {
        setup = .loading
        CurrencyFormatter.currencyCode = Preferences.shared.currencyCode
        privacyMode = Preferences.shared.privacyModeDefault
        if let last = UserDefaults.standard.object(forKey: DefaultsKey.lastSync) as? Date {
            syncStatus = .idle(lastSync: last)
        }

        guard let serverString = KeychainStore.get(KeychainKey.serverURL),
              let serverURL = URL(string: serverString) else {
            setup = .needsServer
            return
        }
        let api = ActualAPI(baseURL: serverURL)
        self.api = api

        if let fileID = KeychainStore.get(KeychainKey.fileID),
           let dbURL = Self.budgetFileURL(fileID: fileID),
           FileManager.default.fileExists(atPath: dbURL.path(percentEncoded: false)) {
            do {
                try openLocalBudget(fileID: fileID, at: dbURL, api: api)
                await refreshAll()
                setup = .ready
                Task { await self.syncNow() }
                return
            } catch {
                Self.log.error("Opening the local budget failed; falling back to file pick")
                dbQueue = nil
                engine = nil
            }
        }

        do {
            let token = try await validToken(api: api)
            let files = try await api.listFiles(token: token).filter { !$0.deleted }
            cachedFiles = files
            setup = .needsFilePick(files)
        } catch AppStoreError.notConnected {
            setup = .needsServer
        } catch {
            setup = .error(Self.friendlyMessage(for: error, fallback: "Couldn't reach the Actual server."))
        }
    }

    /// Opens an already-downloaded budget file and wires up the sync engine. E2E state (key id +
    /// salt in UserDefaults, password in the Keychain) is restored when present so encrypted
    /// files keep syncing offline-first without a network round trip.
    private func openLocalBudget(fileID: String, at url: URL, api: ActualAPI) throws {
        let database = try BudgetDatabase(fileURL: url)
        let queue = DatabaseQueue(db: database)
        let groupID = KeychainStore.get(KeychainKey.groupID) ?? ""
        dbQueue = queue
        engine = SyncEngine(api: api,
                            dbQueue: queue,
                            fileID: fileID,
                            groupID: groupID,
                            tokenProvider: { KeychainStore.get(KeychainKey.token) },
                            e2eKey: Self.storedE2EKey())
        budgetName = UserDefaults.standard.string(forKey: DefaultsKey.budgetName) ?? ""
    }

    private static func storedE2EKey() -> E2EKey? {
        guard let keyID = UserDefaults.standard.string(forKey: DefaultsKey.e2eKeyID),
              let salt = UserDefaults.standard.string(forKey: DefaultsKey.e2eSalt),
              let password = KeychainStore.get(KeychainKey.e2ePassword) else {
            return nil
        }
        return try? E2EKey(password: password, saltBase64: salt, keyID: keyID)
    }

    /// Returns a working session token: the stored one when the server still accepts it, else a
    /// fresh login with the stored password (persisted for the next call).
    private func validToken(api: ActualAPI) async throws -> String {
        if let token = KeychainStore.get(KeychainKey.token), !token.isEmpty {
            if (try? await api.validateToken(token)) == true {
                return token
            }
        }
        guard let password = KeychainStore.get(KeychainKey.password), !password.isEmpty else {
            throw AppStoreError.notConnected
        }
        let token = try await api.login(password: password)
        KeychainStore.set(token, key: KeychainKey.token)
        return token
    }

    // MARK: - Connect & file selection

    /// Onboarding step 1: log in, persist credentials, list budget files → `.needsFilePick`.
    /// Throws so the connect screen can show the failure inline.
    func connect(serverURL: URL, password: String) async throws {
        let api = ActualAPI(baseURL: serverURL)
        let token = try await api.login(password: password)
        self.api = api
        KeychainStore.set(serverURL.absoluteString, key: KeychainKey.serverURL)
        KeychainStore.set(password, key: KeychainKey.password)
        KeychainStore.set(token, key: KeychainKey.token)

        let files = try await api.listFiles(token: token).filter { !$0.deleted }
        cachedFiles = files
        setup = .needsFilePick(files)
    }

    /// Onboarding step 2: download the budget zip, (decrypt if E2E,) extract `db.sqlite` into
    /// Documents, open it, wire the sync engine, run the first delta sync → `.ready`.
    func selectFile(_ file: RemoteFile, e2ePassword: String?) async throws {
        guard let api else { throw AppStoreError.notConnected }
        setup = .syncingFirstTime
        do {
            let token = try await validToken(api: api)

            // E2E key: derive from the provided (or stored) password + the server's key salt,
            // verified against the server's test ciphertext before anything is downloaded.
            var e2eKey: E2EKey?
            if file.encryptKeyID != nil {
                let typed = e2ePassword?.trimmingCharacters(in: .whitespacesAndNewlines)
                let password = (typed?.isEmpty == false ? typed : nil)
                    ?? KeychainStore.get(KeychainKey.e2ePassword)
                guard let password else { throw AppStoreError.e2ePasswordRequired }
                guard let keyInfo = try await api.fetchKeyInfo(token: token, fileID: file.fileID) else {
                    throw AppStoreError.encryptedFileUnreadable
                }
                let key = try E2EKey(password: password,
                                     saltBase64: keyInfo.saltBase64,
                                     keyID: keyInfo.keyID)
                guard Self.validate(key: key, testContentJSON: keyInfo.testContentJSON) else {
                    throw AppStoreError.wrongE2EPassword
                }
                e2eKey = key
                KeychainStore.set(password, key: KeychainKey.e2ePassword)
                UserDefaults.standard.set(keyInfo.keyID, forKey: DefaultsKey.e2eKeyID)
                UserDefaults.standard.set(keyInfo.saltBase64, forKey: DefaultsKey.e2eSalt)
            }

            let raw = try await api.downloadFile(token: token, fileID: file.fileID)
            let zipData = try await decryptedZipData(raw, fileID: file.fileID, key: e2eKey, token: token)

            let entries = try ZipArchive.entries(zipData)
            guard let sqlite = Self.entry(named: "db.sqlite", in: entries) else {
                throw AppStoreError.budgetMissingFromArchive
            }
            guard let dbURL = Self.budgetFileURL(fileID: file.fileID) else {
                throw AppStoreError.documentsUnavailable
            }
            try Self.replaceBudgetFile(at: dbURL, with: sqlite)

            let database = try BudgetDatabase(fileURL: dbURL)
            let queue = DatabaseQueue(db: database)
            let groupID = file.groupID ?? ""
            let engine = SyncEngine(api: api,
                                    dbQueue: queue,
                                    fileID: file.fileID,
                                    groupID: groupID,
                                    tokenProvider: { KeychainStore.get(KeychainKey.token) },
                                    e2eKey: e2eKey)

            // A freshly-downloaded db.sqlite still carries the UPLOADING client's HLC node id
            // in messages_clock (PROTOCOL §8.2 — metadata.json's resetClock flag exists to make
            // importers re-mint). Mint our own before any timestamp is created, so two clients
            // never share a node id. Reopening an existing local file (bootstrap) must NOT reset.
            try await engine.resetNodeID()

            self.dbQueue = queue
            self.engine = engine

            KeychainStore.set(file.fileID, key: KeychainKey.fileID)
            KeychainStore.set(groupID, key: KeychainKey.groupID)
            budgetName = file.name
            UserDefaults.standard.set(file.name, forKey: DefaultsKey.budgetName)

            // First delta sync: catch up on anything newer than the downloaded snapshot. The
            // snapshot itself is complete and usable, so a hiccup here degrades to a sync-status
            // message instead of failing the whole flow.
            do {
                _ = try await engine.fullSync()
                let now = Date()
                UserDefaults.standard.set(now, forKey: DefaultsKey.lastSync)
                syncStatus = .idle(lastSync: now)
            } catch {
                Self.log.notice("First sync after download failed; continuing with the snapshot")
                syncStatus = .error(Self.friendlyMessage(for: error, fallback: "First sync failed."))
            }

            await refreshAll()
            setup = .ready
        } catch {
            setup = .needsFilePick(cachedFiles)
            throw error
        }
    }

    // MARK: - Disconnect

    /// Settings escape hatch: closes and deletes the local budget, wipes every credential.
    func disconnectAndWipe() async {
        if let dbQueue {
            _ = try? await dbQueue.write { db -> Void in db.close() }
        }
        engine = nil
        dbQueue = nil
        api = nil

        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
           let contents = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for url in contents where url.lastPathComponent.hasPrefix("budget-") {
                try? fm.removeItem(at: url)
            }
        }

        // The semantic index is derived from budget data — it lives beside the budget file
        // (Documents/nidget-ai.sqlite) and must be wiped with it. Routed through the actor
        // so the file is closed before deletion (WAL siblings included). Any pending reindex
        // is cancelled and the suggestion service forgets its ledger snapshot.
        reindexDebounceTask?.cancel()
        reindexDebounceTask = nil
        await EmbeddingIndex.shared.deleteDatabaseFile()
        CategorySuggestionService.shared.reset()
        autoCategorizeAttemptedIDs.removeAll()

        for key in [KeychainKey.serverURL, KeychainKey.password, KeychainKey.token,
                    KeychainKey.fileID, KeychainKey.groupID, KeychainKey.e2ePassword] {
            KeychainStore.delete(key)
        }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: DefaultsKey.budgetName)
        defaults.removeObject(forKey: DefaultsKey.e2eKeyID)
        defaults.removeObject(forKey: DefaultsKey.e2eSalt)
        defaults.removeObject(forKey: DefaultsKey.lastSync)

        accounts = []
        categoryGroups = []
        payees = []
        payeeNameByID = [:]
        categoryNameByID = [:]
        monthSnapshot = nil
        budgetName = ""
        cachedFiles = []
        currentMonth = .current
        syncStatus = .idle(lastSync: nil)
        lastError = nil
        setup = .needsServer
    }

    // MARK: - Refresh

    private struct RefreshData: Sendable {
        var accounts: [Account]
        var balances: [String: Money]
        var groups: [CategoryGroup]
        var payees: [Payee]
        var payeeNames: [String: String]
    }

    /// Reloads all published data from the budget file: accounts (with balances), category
    /// groups, payees, the month snapshot, and re-asserts the currency code. Called after
    /// bootstrap, sync, and every mutation.
    func refreshAll() async {
        guard let dbQueue else { return }
        CurrencyFormatter.currencyCode = Preferences.shared.currencyCode
        do {
            let data = try await dbQueue.read { db -> RefreshData in
                RefreshData(accounts: try db.accounts(includeClosed: true),
                            balances: try db.accountBalances(),
                            groups: try db.categoryGroups(),
                            payees: try db.payees(),
                            payeeNames: try db.payeeNames())
            }

            var accounts = data.accounts
            for index in accounts.indices {
                accounts[index].balance = data.balances[accounts[index].id] ?? .zero
            }

            var categoryNames: [String: String] = [:]
            for group in data.groups {
                for category in group.categories {
                    categoryNames[category.id] = category.name
                }
            }

            self.accounts = accounts
            self.categoryGroups = data.groups
            self.payees = data.payees
            self.payeeNameByID = data.payeeNames
            self.categoryNameByID = categoryNames

            await refreshMonthSnapshot()

            // AI upkeep: the ledger snapshot behind category suggestions is now stale, and
            // the semantic index may be missing freshly synced/imported rows. Both are no-ops
            // when no embedding model is configured.
            CategorySuggestionService.shared.noteDataChanged()
            scheduleEmbeddingReindex()
        } catch {
            Self.log.error("refreshAll failed: \(error.localizedDescription, privacy: .public)")
            lastError = AppError(message: "Couldn't read the budget file",
                                 detail: error.localizedDescription)
        }
    }

    private struct MonthSourceData: Sendable {
        var cells: [BudgetCell]
        var spent: [String: Money]
        var income: Money
    }

    /// Rebuilds `monthSnapshot` for `currentMonth` by chaining `BudgetCalculator` forward from
    /// 24 months back (the ARCHITECTURE cap — months before the file's data are cheap zero
    /// snapshots), so carryover balances and To Budget accumulate exactly like Actual.
    private func refreshMonthSnapshot() async {
        guard let dbQueue else {
            monthSnapshot = nil
            return
        }
        let target = currentMonth
        let groups = categoryGroups
        var carry: MonthCarry?
        var result: MonthBudgetSnapshot?
        var month = target.advanced(by: -24)

        while month <= target {
            let m = month
            guard let source = try? await dbQueue.read({ db -> MonthSourceData in
                MonthSourceData(cells: try db.budgetCells(month: m),
                                spent: try db.spentByCategory(month: m),
                                income: try db.incomeTotal(month: m))
            }) else {
                month = month.next
                continue
            }
            let snap = BudgetCalculator.snapshot(month: m,
                                                 cells: source.cells,
                                                 spent: source.spent,
                                                 income: source.income,
                                                 groups: groups,
                                                 previous: carry)
            carry = BudgetCalculator.carry(from: snap)
            if m == target {
                result = snap
            }
            month = month.next
        }

        // Don't clobber a newer navigation's snapshot with a stale computation.
        if currentMonth == target {
            monthSnapshot = result
        }
    }

    // MARK: - Reads

    func transactions(_ q: TransactionQuery) async -> [Transaction] {
        guard let dbQueue else { return [] }
        return (try? await dbQueue.read({ db -> [Transaction] in try db.transactions(q) })) ?? []
    }

    func recentTransactions(limit: Int) async -> [Transaction] {
        let query = TransactionQuery(limit: max(1, limit))
        return await transactions(query)
    }

    /// Cached payee-name lookup (resolves merged payees); "" for nil/unknown ids.
    func payeeName(_ id: String?) -> String {
        guard let id else { return "" }
        return payeeNameByID[id] ?? ""
    }

    /// Cached category-name lookup; "" for nil/unknown ids.
    func categoryName(_ id: String?) -> String {
        guard let id else { return "" }
        return categoryNameByID[id] ?? ""
    }

    /// The month's outflow per category as POSITIVE magnitudes, largest first — chart-ready.
    func spendingByCategory(month: BudgetMonth) async -> [(name: String, categoryID: String, amount: Money)] {
        guard let dbQueue else { return [] }
        let spent = (try? await dbQueue.read({ db -> [String: Money] in
            try db.spentByCategory(month: month)
        })) ?? [:]
        return spent
            .map { id, outflow in
                let name = categoryNameByID[id] ?? "Uncategorized"
                return (name: name, categoryID: id, amount: outflow.magnitude)
            }
            .filter { $0.amount.cents > 0 }
            .sorted { $0.amount.cents > $1.amount.cents }
    }

    func netWorthSeries(monthsBack: Int) async -> [(BudgetMonth, Money)] {
        guard let dbQueue else { return [] }
        return (try? await dbQueue.read({ db -> [(BudgetMonth, Money)] in
            try db.netWorthSeries(monthsBack: monthsBack)
        })) ?? []
    }

    func monthlySpendSeries(monthsBack: Int) async -> [(BudgetMonth, Money)] {
        guard let dbQueue else { return [] }
        return (try? await dbQueue.read({ db -> [(BudgetMonth, Money)] in
            try db.monthlySpendSeries(monthsBack: monthsBack)
        })) ?? []
    }

    func dailySpend(month: BudgetMonth) async -> [Int: Money] {
        guard let dbQueue else { return [:] }
        return (try? await dbQueue.read({ db -> [Int: Money] in
            try db.dailySpend(month: month)
        })) ?? [:]
    }

    // MARK: - Quick Add suggestions

    /// Ranks payees by frequency + recency over the last ~90 days of transactions (one indexed
    /// query through DatabaseQueue, aggregated here), each carrying its most-common category and
    /// last amount. Empty prefix → top recents; a non-empty prefix also surfaces inactive payees
    /// whose names match (prefix matches rank above mid-word matches). Transfer payees are
    /// excluded — picking one from Quick Add would masquerade as a transfer leg.
    func suggestions(for query: PayeeSuggestionQuery) async -> [PayeeSuggestion] {
        guard let dbQueue else { return [] }

        let recentQuery = TransactionQuery(months: BudgetMonth.current.advanced(by: -3)...BudgetMonth.current,
                                           limit: 2000)
        let recent = (try? await dbQueue.read({ db -> [Transaction] in
            try db.transactions(recentQuery)
        })) ?? []

        struct PayeeActivity {
            var count = 0
            var lastDate: BudgetDay?
            var lastAmount: Money?
            var categoryCounts: [String: Int] = [:]
        }
        let cutoff = BudgetDay.today.addingDays(-90)
        var activity: [String: PayeeActivity] = [:]
        for transaction in recent {
            guard let payeeID = transaction.payeeID,
                  transaction.transferID == nil,
                  transaction.date >= cutoff else { continue }
            var entry = activity[payeeID] ?? PayeeActivity()
            entry.count += 1
            if entry.lastDate == nil {  // rows arrive newest-first
                entry.lastDate = transaction.date
                entry.lastAmount = transaction.amount
            }
            if let categoryID = transaction.categoryID {
                entry.categoryCounts[categoryID, default: 0] += 1
            }
            activity[payeeID] = entry
        }

        let prefix = query.prefix.trimmingCharacters(in: .whitespaces)
        let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        var ranked: [(suggestion: PayeeSuggestion, anchored: Bool, score: Double)] = []
        for payee in payees where payee.transferAccountID == nil && !payee.name.isEmpty
                                  && !Self.isSyntheticPayee(payee.name) {
            let entry = activity[payee.id]
            let anchored: Bool
            if prefix.isEmpty {
                guard entry != nil else { continue }  // top recents only
                anchored = true
            } else if payee.name.range(of: prefix, options: matchOptions.union(.anchored)) != nil {
                anchored = true
            } else if payee.name.range(of: prefix, options: matchOptions) != nil {
                anchored = false
            } else {
                continue
            }

            var score = 0.0
            if let entry {
                score = Double(entry.count) + Self.recencyBoost(entry.lastDate)
            }
            let topCategory = entry?.categoryCounts.max { $0.value < $1.value }?.key
            ranked.append((suggestion: PayeeSuggestion(payeeID: payee.id,
                                                       name: payee.name,
                                                       categoryID: topCategory,
                                                       lastAmount: entry?.lastAmount),
                           anchored: anchored,
                           score: score))
        }

        ranked.sort { lhs, rhs in
            if lhs.anchored != rhs.anchored { return lhs.anchored }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.suggestion.name.localizedCaseInsensitiveCompare(rhs.suggestion.name) == .orderedAscending
        }
        return ranked.prefix(max(1, query.limit)).map { $0.suggestion }
    }

    /// Payees Actual creates for its own bookkeeping rather than for anything you actually paid.
    /// "Starting Balance" is the one that matters: every account gets an opening-balance
    /// transaction against it, so it ranks high on recency and lands in the Quick Add chips, where
    /// it is never the right answer. Actual marks those rows with `starting_balance_flag` rather
    /// than marking the payee, and Nidget's Transaction model does not carry that column yet, so
    /// this matches on the name Actual uses.
    private static func isSyntheticPayee(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.compare("Starting Balance", options: .caseInsensitive) == .orderedSame
            || trimmed.compare("Starting Balances", options: .caseInsensitive) == .orderedSame
    }

    /// 0…4 ranking bonus, decaying linearly over 90 days of inactivity.
    private static func recencyBoost(_ day: BudgetDay?) -> Double {
        guard let day else { return 0 }
        let days = Calendar.current.dateComponents([.day], from: day.date, to: Date()).day ?? 90
        let clamped = min(max(days, 0), 90)
        return Double(90 - clamped) / 90.0 * 4.0
    }

    // MARK: - Mutations
    //
    // Shared shape: build raw-column cell writes via Mutations, mint one HLC timestamp per write
    // from the engine, enqueue (the engine applies locally FIRST, then debounce-syncs), then
    // optimistically refresh published state. Failures land in `lastError`.

    func addTransaction(_ draft: TransactionDraft) async {
        var draft = draft
        var writes: [Mutations.CellWrite] = []
        resolvePayee(for: &draft, appending: &writes)
        writes += Mutations.addTransaction(draft: draft)
        await perform(writes, failureMessage: "Couldn't save the transaction")
    }

    func updateTransaction(id: String, _ draft: TransactionDraft) async {
        var draft = draft
        var writes: [Mutations.CellWrite] = []
        resolvePayee(for: &draft, appending: &writes)
        writes += Mutations.updateTransaction(id: id, draft: draft)
        await perform(writes, failureMessage: "Couldn't update the transaction")
    }

    func deleteTransaction(id: String) async {
        await perform(Mutations.deleteTransaction(id: id),
                      failureMessage: "Couldn't delete the transaction")
    }

    func setCleared(id: String, cleared: Bool) async {
        await perform(Mutations.setCleared(id: id, cleared: cleared),
                      failureMessage: "Couldn't update the transaction")
    }

    /// Locks (or unlocks) a batch of transactions as reconciled in one enqueue — reconciliation
    /// confirms many rows at once, so this performs a single write batch rather than N calls.
    func setReconciled(ids: [String], reconciled: Bool) async {
        await perform(ids.flatMap { Mutations.setReconciled(id: $0, reconciled: reconciled) },
                      failureMessage: "Couldn't reconcile the transactions")
    }

    func setBudgetAmount(month: BudgetMonth, categoryID: String, amount: Money) async {
        await perform(Mutations.setBudget(month: month, categoryID: categoryID, amount: amount),
                      failureMessage: "Couldn't update the budget")
    }

    /// Moves budgeted money between categories for a month; nil means "To Budget" on that side
    /// (To Budget is derived, so only the named categories' cells change).
    func moveBudget(month: BudgetMonth, from: String?, to: String?, amount: Money) async {
        guard from != nil || to != nil, from != to, amount != .zero else { return }
        guard let dbQueue else {
            lastError = AppError(message: "Couldn't move money", detail: "No budget file is open.")
            return
        }
        let cells = (try? await dbQueue.read({ db -> [BudgetCell] in
            try db.budgetCells(month: month)
        })) ?? []
        var budgeted: [String: Money] = [:]
        for cell in cells {
            budgeted[cell.categoryID] = cell.budgeted
        }

        var writes: [Mutations.CellWrite] = []
        if let from {
            let newAmount = (budgeted[from] ?? .zero) - amount
            writes += Mutations.setBudget(month: month, categoryID: from, amount: newAmount)
        }
        if let to {
            let newAmount = (budgeted[to] ?? .zero) + amount
            writes += Mutations.setBudget(month: month, categoryID: to, amount: newAmount)
        }
        await perform(writes, failureMessage: "Couldn't move money")
    }

    /// Creates a category inside `groupID`. Returns its id, or nil when the name is blank, the
    /// group is unknown, or the write failed (`lastError` is set in that case).
    ///
    /// A new category sorts after everything already in its group; `isIncome` is inherited from
    /// the group so an income group never gains a spending category.
    @discardableResult
    func createCategory(name: String, groupID: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let group = categoryGroups.first(where: { $0.id == groupID }) else {
            lastError = AppError(message: "Couldn't create the category",
                                 detail: "That category group no longer exists.")
            return nil
        }
        if let existing = group.categories.first(where: {
            $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return existing.id   // already there — reuse rather than mint a confusing duplicate
        }
        let id = Mutations.newID()
        let sortOrder = (group.categories.map(\.sortOrder).max() ?? 0) + 1
        let ok = await perform(Mutations.createCategory(id: id,
                                                        name: trimmed,
                                                        groupID: groupID,
                                                        isIncome: group.isIncome,
                                                        sortOrder: sortOrder),
                               failureMessage: "Couldn't create the category")
        return ok ? id : nil
    }

    /// Creates a spending (or income) category group. Returns its id, or nil on blank name/failure.
    @discardableResult
    func createCategoryGroup(name: String, isIncome: Bool = false) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = categoryGroups.first(where: {
            $0.isIncome == isIncome &&
                $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return existing.id
        }
        let id = Mutations.newID()
        let sortOrder = (categoryGroups.filter { $0.isIncome == isIncome }
            .map(\.sortOrder).max() ?? 0) + 1
        let ok = await perform(Mutations.createCategoryGroup(id: id,
                                                             name: trimmed,
                                                             isIncome: isIncome,
                                                             sortOrder: sortOrder),
                               failureMessage: "Couldn't create the group")
        return ok ? id : nil
    }

    /// Renames a category or a category group.
    func renameCategory(id: String, to name: String, isGroup: Bool) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform(Mutations.rename(dataset: isGroup ? "category_groups" : "categories",
                                       id: id, name: trimmed),
                      failureMessage: "Couldn't rename")
    }

    /// Hides or unhides a category or a category group. Hidden categories/groups keep syncing
    /// and keep every historical transaction pointed at them — `BudgetDatabase.categoryGroups()`
    /// still returns them (with `hidden: true`) so ManageCategoriesView can list and un-hide
    /// them; only `BudgetView`'s own display filters (`visibleGroups`/`visibleCategories`) hide
    /// them from the everyday budgeting surface.
    func setCategoryHidden(id: String, hidden: Bool, isGroup: Bool) async {
        await perform(Mutations.hideCategory(id: id, hidden: hidden, isGroup: isGroup),
                      failureMessage: "Couldn't update the category")
    }

    /// Moves a category into a different group. Refused (via `lastError`, no write sent) when
    /// the category or the target group can't be found, or when the move would cross the
    /// income/spending boundary — Actual keeps income and spending categories in separate group
    /// families, so a category's `is_income` must always agree with its containing group's.
    func moveCategory(id: String, toGroup groupID: String) async {
        guard let category = categoryGroups.flatMap(\.categories).first(where: { $0.id == id }) else {
            lastError = AppError(message: "Couldn't move the category",
                                 detail: "That category no longer exists.")
            return
        }
        guard let targetGroup = categoryGroups.first(where: { $0.id == groupID }) else {
            lastError = AppError(message: "Couldn't move the category",
                                 detail: "That category group no longer exists.")
            return
        }
        guard targetGroup.isIncome == category.isIncome else {
            lastError = AppError(message: "Couldn't move the category",
                                 detail: "Income categories and spending categories can't share a group.")
            return
        }
        await perform(Mutations.moveCategory(id: id, toGroup: groupID),
                      failureMessage: "Couldn't move the category")
    }

    /// Batch-reorders every category in `groupID` to match `orderedIDs`, writing `sort_order`
    /// 1...n in ONE enqueued batch — drag-to-reorder shouldn't create N separate sync round-trips
    /// or N flickers of a partially-reordered list.
    func reorderCategories(inGroup groupID: String, orderedIDs: [String]) async {
        var writes: [Mutations.CellWrite] = []
        for (index, id) in orderedIDs.enumerated() {
            writes += Mutations.setSortOrder(dataset: "categories", id: id, sortOrder: Double(index + 1))
        }
        await perform(writes, failureMessage: "Couldn't reorder categories")
    }

    /// Batch-reorders category groups of one income-ness (`isIncome` documents intent for
    /// callers; the writes themselves are keyed purely by id) to match `orderedIDs`, same
    /// one-batch shape as `reorderCategories`.
    func reorderGroups(orderedIDs: [String], isIncome: Bool) async {
        var writes: [Mutations.CellWrite] = []
        for (index, id) in orderedIDs.enumerated() {
            writes += Mutations.setSortOrder(dataset: "category_groups", id: id, sortOrder: Double(index + 1))
        }
        await perform(writes, failureMessage: "Couldn't reorder groups")
    }

    /// Deletes a category. Every non-tombstoned, non-split-parent transaction currently pointing
    /// at it (`BudgetDatabase.transactions(_:)` already excludes tombstoned/parent rows) is first
    /// re-pointed to `newCategoryID`, or cleared to NULL when nil ("leave uncategorized") — fetched
    /// via paged `TransactionQuery(categoryID:)` reads (the query's own default `limit` is only
    /// 100, so a category with more transactions than one page needs the loop below), then all
    /// the reassignment writes plus the category's own tombstone write are sent as ONE enqueued
    /// batch. Budget cells (`zero_budgets`) for a tombstoned category are NOT touched here: once
    /// the category is gone, `spentByCategory`/`budgetCells` can no longer resolve its id through
    /// `category_mapping`, so BudgetCalculator simply never sees those cells again — nothing to
    /// clean up.
    func deleteCategory(id: String, reassignTo newCategoryID: String?) async {
        guard let dbQueue else {
            lastError = AppError(message: "Couldn't delete the category", detail: "No budget file is open.")
            return
        }
        let pageSize = 500
        var writes: [Mutations.CellWrite] = []
        var offset = 0
        while true {
            let currentOffset = offset   // shadowed before capture — see refreshMonthSnapshot's `m`
            let page = (try? await dbQueue.read({ db -> [Transaction] in
                try db.transactions(TransactionQuery(categoryID: id, months: nil,
                                                     limit: pageSize, offset: currentOffset))
            })) ?? []
            guard !page.isEmpty else { break }
            let newValue: CRDTValue = newCategoryID.map { .string($0) } ?? .null
            for transaction in page {
                writes += Mutations.updateFields(dataset: "transactions", id: transaction.id,
                                                 fields: [(column: "category", value: newValue)])
            }
            offset += page.count
            if page.count < pageSize { break }
        }
        writes += Mutations.deleteCategory(id: id)
        await perform(writes, failureMessage: "Couldn't delete the category")
    }

    /// Deletes a category group — but only once every category that was ever in it is gone.
    /// `categoryGroups` already excludes tombstoned categories (`BudgetDatabase.categoryGroups()`
    /// filters `tombstone = 0`), so an empty `group.categories` here means exactly "every
    /// category that lived here is tombstoned or was moved out". Otherwise sets `lastError`
    /// explaining to move or delete its categories first, rather than tombstoning a group that
    /// still has live children (which would orphan them on decode).
    func deleteCategoryGroup(id: String) async {
        guard let group = categoryGroups.first(where: { $0.id == id }) else {
            lastError = AppError(message: "Couldn't delete the group",
                                 detail: "That category group no longer exists.")
            return
        }
        guard group.categories.isEmpty else {
            lastError = AppError(message: "Couldn't delete the group",
                                 detail: "Move or delete its categories first.")
            return
        }
        await perform(Mutations.deleteCategoryGroup(id: id), failureMessage: "Couldn't delete the group")
    }

    /// Returns the id the payee ends up with: an existing payee on a case-insensitive name
    /// match (no duplicate is minted), else a freshly created one.
    func createPayee(name: String) async -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = existingPayee(named: trimmed) {
            return existing.id
        }
        let id = Mutations.newID()
        await perform(Mutations.createPayee(id: id, name: trimmed),
                      failureMessage: "Couldn't create the payee")
        return id
    }

    /// Resolves `draft.newPayeeName` into `draft.payeeID`: reuse an existing payee by
    /// case-insensitive name, else append createPayee writes for a fresh id.
    private func resolvePayee(for draft: inout TransactionDraft,
                              appending writes: inout [Mutations.CellWrite]) {
        guard draft.payeeID == nil, let rawName = draft.newPayeeName else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let existing = existingPayee(named: name) {
            draft.payeeID = existing.id
        } else {
            let id = Mutations.newID()
            writes += Mutations.createPayee(id: id, name: name)
            draft.payeeID = id
        }
    }

    private func existingPayee(named name: String) -> Payee? {
        guard !name.isEmpty else { return nil }
        return payees.first { payee in
            payee.transferAccountID == nil &&
                payee.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    /// Shared mutation tail — see the Mutations MARK note.
    ///
    /// Returns whether the write landed. Callers that mint an id (categories, groups) must use
    /// this result rather than inspecting `lastError`, which persists until the user dismisses it
    /// and therefore says nothing about *this* call.
    @discardableResult
    private func perform(_ writes: [Mutations.CellWrite], failureMessage: String) async -> Bool {
        guard !writes.isEmpty else { return true }
        guard let engine else {
            lastError = AppError(message: failureMessage, detail: "No budget file is open.")
            return false
        }
        do {
            let timestamps = try await engine.nextTimestamps(count: writes.count)
            let messages = Mutations.messages(writes, timestamps: timestamps)
            guard await engine.enqueue(messages) else {
                lastError = AppError(message: failureMessage,
                                     detail: "The change couldn't be written to the budget file.")
                return false
            }
            await refreshAll()
            return true
        } catch {
            lastError = AppError(message: failureMessage, detail: error.localizedDescription)
            return false
        }
    }

    // MARK: - Sync

    func syncNow() async {
        guard let engine else { return }
        if case .syncing = syncStatus { return }
        syncStatus = .syncing
        do {
            let outcome = try await engine.fullSync()
            let now = Date()
            UserDefaults.standard.set(now, forKey: DefaultsKey.lastSync)
            syncStatus = .idle(lastSync: now)
            await refreshAll()
            // Trigger point for docs/AI.md §3's auto-categorize pass: a sync that actually
            // brought in transaction changes is the one signal that's true "no matter who
            // imported them" — bank imports now happen server-side, so this is the only hook
            // left. `isAutoCategorizing` (checked inside) stops overlapping runs: syncStatus is
            // already back to `.idle` by the time this call starts, so a second `syncNow()`
            // could otherwise slip in and fire a concurrent pass while this one is still going.
            if outcome.changedDatasets.contains("transactions") {
                await autoCategorizeNewArrivals()
            }
        } catch {
            let pending = await pendingCount()
            if Self.isOffline(error) {
                syncStatus = .offline(pending: pending)
            } else {
                syncStatus = .error(Self.friendlyMessage(for: error, fallback: "Sync failed."))
                // Partial success: decryptable messages were applied before the engine threw.
                if let syncError = error as? SyncError,
                   case .encryptedMessagesWithoutKey = syncError {
                    await refreshAll()
                }
            }
        }
    }

    private func pendingCount() async -> Int {
        guard let dbQueue else { return 0 }
        return (try? await dbQueue.read({ db -> Int in try db.pendingMessages().count })) ?? 0
    }

    private static func isOffline(_ error: Error) -> Bool {
        if let syncError = error as? SyncError, case .offline = syncError {
            return true
        }
        if let apiError = error as? ActualAPIError, case .offline = apiError {
            return true
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .timedOut, .dataNotAllowed,
                 .internationalRoamingOff:
                return true
            default:
                return false
            }
        }
        return false
    }

    // MARK: - Auto-categorize new arrivals (docs/AI.md §3)

    /// Suggests categories for freshly synced bank transactions, no matter which client did the
    /// importing — bank imports happen server-side now (Actual's own bank sync), so a completed
    /// sync that changed `transactions` is the only signal AppStore has that new rows might need
    /// a category. Candidates: transactions from the last 45 days that are bank-imported
    /// (`importedID != nil`), not yet categorized, not a transfer, and not a split parent —
    /// `TransactionQuery(onlyUncategorized: true)` already excludes transfers, split parents, and
    /// off-budget accounts, so only the import/date/session filters happen here. Capped at 50
    /// candidates per run; each is tried at most once per app session
    /// (`autoCategorizeAttemptedIDs`) so a low-confidence transaction isn't re-embedded on every
    /// sync. Only picks with confidence ≥ 0.75 are applied, as one batched write, mirroring
    /// `deleteCategory`'s batching. Silent: no `lastError`, no toast — this is a background
    /// convenience, not a user-initiated action.
    private func autoCategorizeNewArrivals() async {
        guard Preferences.shared.aiAutoCategorize,
              CategorySuggestionService.shared.embeddingReady,
              !isAutoCategorizing,
              let dbQueue, let engine else { return }
        isAutoCategorizing = true
        defer { isAutoCategorizing = false }

        // Cap how much LLM refinement this batch may do. The llama path gates itself on "the
        // model is already loaded", which is almost never true mid-sync; Apple's on-device model
        // has no load step, so without a cap refinement would fire on every weak transaction in
        // a 50-row batch. Eight keeps a sync quick and the phone cool. Interactive suggestions
        // are unbudgeted (docs/AI.md §6).
        CategorySuggestionService.shared.resetRefinementBudget(8)
        defer { CategorySuggestionService.shared.endRefinementBudget() }

        let cutoff = BudgetDay.today.addingDays(-45)
        let months = cutoff.month...BudgetMonth.current
        let pageSize = 200
        var candidates: [Transaction] = []
        var offset = 0
        while candidates.count < 50 {
            let page = (try? await dbQueue.read({ db -> [Transaction] in
                try db.transactions(TransactionQuery(months: months, onlyUncategorized: true,
                                                     limit: pageSize, offset: offset))
            })) ?? []
            guard !page.isEmpty else { break }
            for transaction in page where transaction.date >= cutoff
                && transaction.importedID != nil
                && !autoCategorizeAttemptedIDs.contains(transaction.id) {
                candidates.append(transaction)
                if candidates.count >= 50 { break }
            }
            offset += page.count
            if page.count < pageSize { break }
        }
        guard !candidates.isEmpty else { return }

        var writes: [Mutations.CellWrite] = []
        var applied = 0
        for transaction in candidates {
            autoCategorizeAttemptedIDs.insert(transaction.id)
            let suggestion = await CategorySuggestionService.shared
                .suggest(payee: payeeName(transaction.payeeID), notes: transaction.notes, limit: 1)
                .first
            guard let suggestion, suggestion.confidence >= 0.75 else { continue }
            writes += Mutations.updateFields(dataset: "transactions", id: transaction.id,
                                             fields: [(column: "category", value: .string(suggestion.categoryID))])
            applied += 1
        }
        guard !writes.isEmpty else { return }
        guard let timestamps = try? await engine.nextTimestamps(count: writes.count),
              timestamps.count == writes.count,
              await engine.enqueue(Mutations.messages(writes, timestamps: timestamps)) else { return }
        await refreshAll()
        Self.aiLog.info("Auto-categorized \(applied) newly synced transaction(s)")
    }

    // MARK: - Semantic index upkeep (docs/AI.md §3)

    /// Debounce-kicks a background reindex of the transaction embedding index so semantic
    /// features track fresh data after sync/import/mutations. No-op when no budget is open
    /// or no embedding model is configured; the blocking llama work runs on the
    /// EmbeddingIndex/Engine actors, never the main thread.
    private func scheduleEmbeddingReindex() {
        guard dbQueue != nil, AIModelManager.shared.embeddingModelID != nil else { return }
        reindexDebounceTask?.cancel()
        reindexDebounceTask = Task.detached(priority: .low) { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled else { return }
            await self.rebuildEmbeddingIndex()
        }
    }

    /// Pages the whole ledger through the existing read API into `EmbeddingIndex.reindex`
    /// input (id, "payee — notes" text, category). The index's incremental hashing keeps
    /// repeat runs cheap; only changed rows are re-embedded.
    private func rebuildEmbeddingIndex() async {
        guard dbQueue != nil,
              let modelID = AIModelManager.shared.embeddingModelID,
              ModelDownloadManager.shared.isReady(modelID) else { return }
        var input: [(id: String, text: String, categoryID: String?)] = []
        let pageSize = 500
        var offset = 0
        while true {
            let page = await transactions(TransactionQuery(limit: pageSize, offset: offset))
            guard !Task.isCancelled else { return }
            for transaction in page {
                input.append((id: transaction.id,
                              text: EmbeddingIndex.embeddedText(payee: payeeName(transaction.payeeID),
                                                                notes: transaction.notes),
                              categoryID: transaction.categoryID))
            }
            if page.count < pageSize { break }
            offset += page.count
        }
        guard !input.isEmpty else { return }
        await EmbeddingIndex.shared.reindex(transactions: input, modelID: modelID)
        // The index's category cache was just rebuilt from this input; the suggestion
        // service's ledger snapshot should follow on next use.
        CategorySuggestionService.shared.noteDataChanged()
    }

    // MARK: - E2E helpers

    /// Whole-file decryption (PROTOCOL §8.3): an E2E budget's download body is one AES-GCM blob
    /// whose iv/authTag live in the server's file info (`encryptMeta`) — metadata the ActualAPI
    /// contract doesn't expose, so it's fetched directly here. Plain zips ("PK" magic) pass
    /// straight through.
    private func decryptedZipData(_ raw: Data, fileID: String,
                                  key: E2EKey?, token: String) async throws -> Data {
        if Self.looksLikeZip(raw) { return raw }
        // Not encrypted but not a zip either → fall through so ZipArchive reports the corruption.
        guard key != nil else { return raw }
        guard let key,
              let serverString = KeychainStore.get(KeychainKey.serverURL),
              let serverURL = URL(string: serverString),
              let meta = try await Self.fetchEncryptMeta(serverURL: serverURL,
                                                         token: token,
                                                         fileID: fileID) else {
            throw AppStoreError.encryptedFileUnreadable
        }
        return try key.decrypt(iv: meta.iv, authTag: meta.authTag, data: raw)
    }

    private struct EncryptMeta {
        var iv: Data
        var authTag: Data
    }

    /// `GET /sync/get-user-file-info` (PROTOCOL §1) — only the encryptMeta iv/authTag are read.
    private static func fetchEncryptMeta(serverURL: URL, token: String,
                                         fileID: String) async throws -> EncryptMeta? {
        let url = serverURL.appendingPathComponent("sync").appendingPathComponent("get-user-file-info")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.setValue(fileID, forHTTPHeaderField: "X-ACTUAL-FILE-ID")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["status"] as? String) == "ok",
              let payload = root["data"] as? [String: Any] else {
            return nil
        }
        var metaObject = payload["encryptMeta"] as? [String: Any]
        if metaObject == nil, let string = payload["encryptMeta"] as? String {
            metaObject = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any]
        }
        guard let metaObject,
              let iv = (metaObject["iv"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let authTag = (metaObject["authTag"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            return nil
        }
        return EncryptMeta(iv: iv, authTag: authTag)
    }

    /// Verifies a derived key against the server's stored `test` ciphertext (PROTOCOL §7.3) —
    /// a GCM auth failure means a wrong password. True when there's nothing usable to test.
    private static func validate(key: E2EKey, testContentJSON: String?) -> Bool {
        guard let json = testContentJSON,
              let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let value = (root["value"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let meta = root["meta"] as? [String: Any],
              let iv = (meta["iv"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let authTag = (meta["authTag"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            return true
        }
        return (try? key.decrypt(iv: iv, authTag: authTag, data: value)) != nil
    }

    // MARK: - Files & misc helpers

    private static func looksLikeZip(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B
    }

    /// Finds a zip entry at the root or under one shared subdirectory (PROTOCOL §8.1 allows both).
    private static func entry(named name: String, in entries: [String: Data]) -> Data? {
        if let exact = entries[name] { return exact }
        return entries.first { $0.key.hasSuffix("/" + name) }?.value
    }

    /// Documents/budget-<fileID>.sqlite. fileIDs are server-validated to [A-Za-z0-9_-]
    /// (PROTOCOL §1); sanitized here anyway before touching the filesystem.
    private static func budgetFileURL(fileID: String) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let safe = fileID.filter { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
        guard !safe.isEmpty else { return nil }
        return docs.appendingPathComponent("budget-\(safe).sqlite")
    }

    /// Replaces the local budget file (and stale -wal/-shm siblings), applies after-first-unlock
    /// file protection, and excludes it from backups (it can always be re-downloaded).
    private static func replaceBudgetFile(at url: URL, with data: Data) throws {
        let fm = FileManager.default
        let basePath = url.path(percentEncoded: false)
        for suffix in ["", "-wal", "-shm"] {
            let path = basePath + suffix
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }
        try data.write(to: url, options: [.atomic])
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                              ofItemAtPath: basePath)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private static func friendlyMessage(for error: Error, fallback: String) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        let description = error.localizedDescription
        return description.isEmpty ? fallback : description
    }
}
