# Nidget — Architecture & Contracts

Nidget is a native iOS companion app for [Actual Budget](https://actualbudget.org). It speaks
Actual's CRDT sync protocol directly (no JS bridge), works fully offline, and adds a
retirement-planning module. Bank imports happen server-side, through your Actual server's own
bank sync. This document is the **binding contract** for all
implementation work: exact type signatures, file ownership, and conventions. If code disagrees with
this document, the code is wrong (or this document must be amended deliberately — never silently).

## 1. Product pillars

1. **Fast daily capture.** Logging a transaction is ≤3 interactions from anywhere: Quick Add is
   reachable from every tab, opens straight into an amount keypad, and learns payee→category pairs.
2. **A dashboard that fits on one screen.** No scrolling. A 2-column grid of user-chosen widgets
   (1x1 / 2x1 / 2x2 spans) with drag-to-rearrange edit mode.
3. **Offline-first.** The budget file is a local SQLite database. Every mutation is applied locally
   and enqueued as CRDT messages; sync happens opportunistically. Airplane mode loses nothing.
4. **Themes with a personality.** 40 curated themes (20 light / 20 dark). A theme changes color,
   typography (font design), card construction, corner geometry, background treatment, shadows,
   chrome style, icon weight, spacing density, chart rendering, and motion character — not just tint.
5. **Distinct identity.** Numbers are the heroes: large numerals with `contentTransition(.numericText())`,
   monospaced digits where alignment matters, generous type scale. Never looks like a stock Form app,
   while still honoring HIG.

## 2. Tech decisions (fixed)

- **iOS 26.0 minimum**, iPhone only (`TARGETED_DEVICE_FAMILY = 1`). Use iOS 26 APIs freely
  (Liquid Glass `glassEffect`, `Tab`/`TabView` new API, `NavigationStack`, Swift Charts,
  `@Observable`). No `#available` checks needed for ≤26 APIs.
- **Swift language mode 5** (build setting `SWIFT_VERSION = 5.0`) with async/await and actors.
  Do not rely on Swift 6 strict-concurrency semantics.
- **Zero third-party dependencies.** SQLite via the C API (`import SQLite3`), protobuf via a
  hand-rolled minimal codec, zip via `Compression` framework, crypto via `CryptoKit`.
- **Observation framework** (`@Observable`), not Combine/ObservableObject.
- **State architecture:** one `@MainActor @Observable` `AppStore` as source of truth for UI-facing
  state; engines (`SyncEngine`, DB) live off the main actor. Views talk only to `AppStore`,
  `ThemeManager`, `DashboardModel`, and pure helpers.
- **No force unwraps** (`!`) outside of provably-static cases (e.g. `URL(string: "https://…")!` of a
  literal). No `try!`, no `fatalError` in reachable paths.
- **Every file compiles independently of file order** — no `fileprivate` cross-file tricks.

## 3. Repository layout & ownership

```
Nidget.xcodeproj/            hand-written, uses filesystem-synchronized groups
Support/Info.plist           explicit plist (ATS, FaceID string, launch screen)
Nidget/
  App/                       NidgetApp, RootView (tab shell), AppLockScreen, Onboarding/
  DesignSystem/
    Theme.swift              [WRITTEN — do not modify] theme model + font roles + env key
    ThemeManager.swift       [WRITTEN — do not modify] selection, persistence, modifiers
    ThemeCatalog+Light.swift 20 light themes
    ThemeCatalog+Dark.swift  20 dark themes
    Components/              ThemedCard, AmountText, ProgressRing, Sparkline, NidgetButton,
                             ChipPicker, EmptyStateView, SectionHeader, Keypad, GaugeArc
    Haptics.swift, Backdrop.swift (renders BackdropStyle)
  Core/
    Models/Models.swift      [WRITTEN] domain structs
    Models/Money.swift       [WRITTEN] Int64-cents money + formatter
    Models/BudgetDates.swift [WRITTEN] BudgetDay (yyyymmdd) / BudgetMonth (yyyymm)
    Database/SQLiteDB.swift  thin sqlite3 wrapper
    Database/BudgetDatabase.swift  typed queries over the Actual budget file
    Database/Schema.swift    DDL for local tables (crdt tables, local metadata)
    Sync/HLC.swift Merkle.swift Protobuf.swift SyncMessages.swift
    Sync/ActualAPI.swift SyncEngine.swift ZipArchive.swift E2ECrypto.swift
    Store/AppStore.swift Mutations.swift BudgetCalculator.swift
    Store/Preferences.swift KeychainStore.swift
    Retirement/RetirementPlan.swift MonteCarlo.swift
  Features/
    Dashboard/  Budget/  Transactions/  Accounts/  Reports/  Retirement/  Settings/
  Platform/AppShortcuts.swift PrivacyInfo.xcprivacy
docs/ARCHITECTURE.md (this) docs/PROTOCOL.md (wire-protocol reference)
```

Files marked `[WRITTEN]` already exist — **read them before implementing anything** and treat their
declarations as immutable API.

## 4. Concurrency & error conventions

- `AppStore`, `ThemeManager`, `DashboardModel`, all Views: `@MainActor`.
- `SyncEngine` is an `actor`. `BudgetDatabase` is a `final class` used from a single
  `DatabaseQueue` actor owned by AppStore — see §7. SQLite is opened with `SQLITE_OPEN_FULLMUTEX`.
- Domain model structs are `Sendable`.
- Errors: one enum per subsystem (`ActualAPIError`, `SyncError`, `DBError`),
  all `LocalizedError` with human-readable `errorDescription`. UI surfaces errors as a themed
  toast/banner via `AppStore.lastError`, never `print`.
- Logging: `import os`; `static let log = Logger(subsystem: "app.nidget", category: "<area>")`.
  Never log amounts, payees, tokens, or URLs-with-credentials.

## 5. Theme system (already written — usage rules)

Read `DesignSystem/Theme.swift` + `ThemeManager.swift`. Rules for ALL view code:

- Get the theme via `@Environment(\.theme) private var theme`.
- **Never** use raw `Color(...)`, `.blue`, `.primary`, hardcoded fonts, or hardcoded corner radii in
  feature views. Colors come from `theme.palette`, fonts from `theme.font(.role)`, spacing from
  `theme.layout`, radii/card construction via `.themedCard()` / `theme.shape`.
- Screens wrap content in `.themedScreen()` (renders the theme's backdrop). Cards use
  `.themedCard()` (or `.themedCard(padding:)`).
- Positive money = `theme.palette.positive`, negative = `theme.palette.negative` — via
  `AmountText` wherever an amount is displayed.
- Animations: use `theme.motion.spring` / `.snappy` / `.emphasis`, never ad-hoc `.easeInOut`.
  Gate decorative motion on `@Environment(\.accessibilityReduceMotion)`.
- SF Symbols: `.symbolVariant(theme.icons.fill ? .fill : .none)` and
  `.fontWeight(theme.icons.weight)` for primary iconography.
- Charts use `theme.palette.chart[i % chart.count]` and `theme.chart` styling knobs.

## 6. Shared component contracts (DesignSystem/Components — exact signatures)

```swift
// AmountText.swift — the canonical way to render money
struct AmountText: View {
  init(_ amount: Money, style: AmountStyle = .body, colorized: Bool = true,
       showSign: Bool = false, redacted: Bool = false)
}
enum AmountStyle { case hero, display, title, body, caption }  // maps to theme font roles

// ThemedCard is a modifier, provided by ThemeManager.swift: .themedCard(padding:)
// SectionHeader.swift
struct SectionHeader: View { init(_ title: String, trailing: (() -> AnyView)? = nil) }
// Applies theme.typography.labelCase + tracking; NOT a List section header.

// NidgetButton.swift
enum NidgetButtonRole { case primary, secondary, subtle, destructive }
struct NidgetButton: View { init(_ title: String, systemImage: String? = nil,
    role: NidgetButtonRole = .primary, action: @escaping () -> Void) }
// Capsule or rounded-rect per theme.shape; primary = accent fill + onAccent label;
// includes pressed-state scale (0.96, theme.motion.snappy) + Haptics.tap() on press.

// ProgressRing.swift
struct ProgressRing: View { init(progress: Double, lineWidth: CGFloat = 8,
    tint: Color? = nil, showsOverflow: Bool = true) }  // >1.0 renders overflow lap in negative color

// Sparkline.swift — tiny filled line chart for widgets (pure Path, not Swift Charts)
struct Sparkline: View { init(values: [Double], tint: Color? = nil, fillGradient: Bool = true) }

// GaugeArc.swift — 270° gauge for savings rate / FI progress
struct GaugeArc: View { init(progress: Double, label: String, detail: String? = nil) }

// ChipPicker.swift — horizontal scrolling chips (month picker, filters)
struct ChipPicker<T: Hashable>: View { init(items: [T], selection: Binding<T>,
    label: @escaping (T) -> String) }

// Keypad.swift — custom amount keypad used by QuickAdd
struct AmountKeypad: View { init(amount: Binding<Money>, allowsSign: Bool = true) }
// Digit buttons sized ≥64pt, uses theme.palette.fill keys, Haptics.tick() per key.

// EmptyStateView.swift
struct EmptyStateView: View { init(systemImage: String, title: String, message: String,
    actionTitle: String? = nil, action: (() -> Void)? = nil) }

// Haptics.swift
enum Haptics { static func tap(); static func tick(); static func success(); static func warning() }

// Backdrop.swift
struct Backdrop: View { init(style: BackdropStyle) }  // full-bleed background for .themedScreen()
// Also in Backdrop.swift:
enum NoiseTexture { static var tiled: some View }  // cached tiled noise image (generated once via
// UIGraphicsImageRenderer: ~1500 random 1pt alpha dots on 160x160, Image(uiImage:).resizable(resizingMode: .tile))
```

```swift
// ThemeCatalog (split across ThemeCatalog+Light.swift / ThemeCatalog+Dark.swift)
// One file declares:
enum ThemeCatalog {
  static let defaultLightID: String   // in +Light
  static let defaultDarkID: String    // in +Dark (declare BOTH statics + all/theme(id:) in +Light,
                                      // with defaultDarkID referencing a dark theme id string literal)
  static let light: [Theme]           // exactly 20, in +Light
  static let dark: [Theme]            // exactly 20, in +Dark
  static var all: [Theme]             // light + dark
  static func theme(id: String) -> Theme?
}
```

## 7. Database contracts (Core/Database)

```swift
// SQLiteDB.swift — minimal wrapper over sqlite3 C API
final class SQLiteDB {
  init(path: String) throws                      // opens RW|CREATE|FULLMUTEX, WAL mode, foreign keys off
  func exec(_ sql: String) throws
  func run(_ sql: String, _ params: [SQLValue]) throws
  func query(_ sql: String, _ params: [SQLValue]) throws -> [SQLRow]
  func scalar(_ sql: String, _ params: [SQLValue]) throws -> SQLValue?
  func transaction<T>(_ body: () throws -> T) throws -> T
  var lastInsertRowID: Int64 { get }
  func close()
}
enum SQLValue: Sendable, Equatable { case null, int(Int64), real(Double), text(String), blob(Data) }
struct SQLRow { subscript(_ column: String) -> SQLValue? ; func string(_: String) -> String?
  func int(_: String) -> Int64? ; func double(_: String) -> Double? ; func data(_: String) -> Data? }
```

```swift
// BudgetDatabase.swift — typed access to an Actual budget sqlite file.
// NOT an actor; must only be touched from DatabaseQueue (below). Reads column names from
// docs/PROTOCOL.md §8 (e.g. transactions.description holds the payee id; amounts are Int cents;
// dates are Int yyyymmdd; soft deletes via tombstone = 1).
final class BudgetDatabase {
  init(fileURL: URL) throws                       // opens + runs Schema.ensureLocalTables
  // reads
  func accounts(includeClosed: Bool) throws -> [Account]
  func accountBalances() throws -> [String: Money]          // account id → cleared+pending balance
  func categoryGroups() throws -> [CategoryGroup]           // with nested sorted categories
  func payees() throws -> [Payee]
  func payeeNames() throws -> [String: String]              // id → name
  func transactions(_ q: TransactionQuery) throws -> [Transaction]
  func transactionCount(_ q: TransactionQuery) throws -> Int
  func budgetCells(month: BudgetMonth) throws -> [BudgetCell]
  func spentByCategory(month: BudgetMonth) throws -> [String: Money]
  func incomeTotal(month: BudgetMonth) throws -> Money
  func monthlySpendSeries(monthsBack: Int) throws -> [(BudgetMonth, Money)]
  func dailySpend(month: BudgetMonth) throws -> [Int: Money] // day-of-month → outflow
  func netWorthSeries(monthsBack: Int) throws -> [(BudgetMonth, Money)]
  func existingImportedIDs(accountID: String) throws -> Set<String>
  // CRDT plumbing (used by SyncEngine + Mutations)
  func apply(_ message: CRDTMessage, insertOnly: Bool) throws -> Bool  // true if it won LWW & mutated data
  func haveTimestamp(_ ts: String) throws -> Bool
  func messagesSince(_ ts: String) throws -> [CRDTMessage]
  func clockState() throws -> (clock: String, merkle: String)?   // from messages_clock
  func saveClockState(clock: String, merkle: String) throws
  func close()
}
struct TransactionQuery: Sendable {
  var accountID: String? = nil; var categoryID: String? = nil; var payeeID: String? = nil
  var search: String? = nil        // matches payee name / notes
  var months: ClosedRange<BudgetMonth>? = nil
  var onlyUncategorized = false; var limit = 100; var offset = 0
}
```

`DatabaseQueue` (in AppStore.swift) is a tiny actor: `actor DatabaseQueue { let db: BudgetDatabase;
func read<T: Sendable>(_ body: @Sendable (BudgetDatabase) throws -> T) async throws -> T; func
write<T: Sendable>(_:) ... }` — all DB touches route through it.

`Schema.swift` provides `enum Schema { static func ensureLocalTables(_ db: SQLiteDB) throws }`
creating (IF NOT EXISTS) `messages_crdt`, `messages_clock` per docs/PROTOCOL.md §6.

## 8. Sync contracts (Core/Sync) — implement per docs/PROTOCOL.md

```swift
// HLC.swift
struct HLCTimestamp: Comparable, Sendable, CustomStringConvertible {
  let millis: Int64; let counter: Int; let node: String   // 16-hex node id
  var description: String   // ISO8601(millis, 3-fraction 'Z') + "-" + %04X counter + "-" + node
  static func parse(_ s: String) -> HLCTimestamp?
}
final class HLCClock {          // used behind SyncEngine actor only
  init(node: String, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) })
  func send() throws -> HLCTimestamp
  func recv(_ remote: HLCTimestamp) throws
  var current: HLCTimestamp
}

// Merkle.swift — trie keyed by base-3(minutes), murmur3-x86-32 hashes XOR-combined (PROTOCOL §4)
struct MerkleTrie: Sendable {
  static func fromJSON(_ s: String) -> MerkleTrie
  func toJSON() -> String
  func inserting(_ ts: HLCTimestamp) -> MerkleTrie
  func diff(_ other: MerkleTrie) -> Int64?     // millis of divergence minute, nil if equal
  func pruned() -> MerkleTrie
}

// Protobuf.swift — minimal wire codec (varint, length-delimited); only what sync.proto needs
struct ProtoWriter { mutating func field(_ n: Int, string: String); mutating func field(_ n: Int, bytes: Data)
  mutating func field(_ n: Int, bool: Bool); var data: Data }
struct ProtoReader { init(_ data: Data); mutating func next() -> (field: Int, value: ProtoValue)? }
enum ProtoValue { case varint(UInt64), bytes(Data) }

// SyncMessages.swift — typed mirror of sync.proto (field numbers from PROTOCOL §2)
struct CRDTMessage: Sendable { var timestamp: String; var dataset: String; var row: String
  var column: String; var value: CRDTValue }
enum CRDTValue: Sendable, Equatable { case null, number(Double), string(String)
  var encoded: String { get }                        // "0:" / "N:…" / "S:…"
  static func decode(_ s: String) -> CRDTValue
  var sqlValue: SQLValue { get } }
struct SyncRequest { var messages: [EnvelopeOut]; var fileID: String; var groupID: String
  var keyID: String?; var since: String; func serialized() -> Data }
struct SyncResponse { var merkle: String; var messages: [EnvelopeIn]
  init(parsing: Data) throws }

// ActualAPI.swift — URLSession client. All endpoints/headers per PROTOCOL §1.
actor ActualAPI {
  init(baseURL: URL, session: URLSession = .shared)
  func login(password: String) async throws -> String          // token
  func validateToken(_ token: String) async throws -> Bool
  func listFiles(token: String) async throws -> [RemoteFile]   // RemoteFile: fileID, groupID, name, encryptKeyID?, deleted
  func downloadFile(token: String, fileID: String) async throws -> Data   // raw zip
  func fetchKeyInfo(token: String, fileID: String) async throws -> KeyInfo?  // salt/testContent for E2E
  func sync(token: String, request: SyncRequest) async throws -> SyncResponse
}

// ZipArchive.swift — read-only zip (stored + deflate via Compression framework)
enum ZipArchive { static func entries(_ data: Data) throws -> [String: Data] }

// E2ECrypto.swift — AES-256-GCM message decrypt/encrypt per PROTOCOL §7
struct E2EKey { init(password: String, saltBase64: String, keyID: String) throws
  func decrypt(iv: Data, authTag: Data, data: Data) throws -> Data
  func encrypt(_ plaintext: Data) throws -> (iv: Data, authTag: Data, data: Data) }

// SyncEngine.swift
actor SyncEngine {
  init(api: ActualAPI, dbQueue: DatabaseQueue, fileID: String, groupID: String,
       tokenProvider: @escaping @Sendable () -> String?, e2eKey: E2EKey?)
  func fullSync() async throws -> SyncOutcome    // push pending + pull, merkle-verify, retry-once on divergence
  func enqueue(_ messages: [CRDTMessage]) async  // from Mutations; applies locally FIRST via dbQueue, persists to pending queue, then triggers debounced sync
  var isSyncing: Bool { get }
}
struct SyncOutcome: Sendable { var pushed: Int; var pulled: Int; var changedDatasets: Set<String> }
```

Pending-outbox: messages the server hasn't confirmed live in a local table
`local_pending_messages(timestamp TEXT PK, content BLOB)` (Schema.swift). On successful sync they
are deleted. Offline `fullSync()` throws `.offline` and everything stays queued. **Every mutation
is applied to the local DB synchronously before any network** — offline is the default path, sync
is opportunistic.

## 9. AppStore contract (Core/Store/AppStore.swift) — THE UI-facing API

```swift
@MainActor @Observable final class AppStore {
  // lifecycle
  enum SetupState: Equatable { case loading, needsServer, needsFilePick([RemoteFile]), syncingFirstTime, ready, error(String) }
  private(set) var setup: SetupState
  static let shared = AppStore()
  func bootstrap() async                                   // called from NidgetApp .task
  func connect(serverURL: URL, password: String) async throws   // login, store creds, list files
  func selectFile(_ file: RemoteFile, e2ePassword: String?) async throws  // download, open, first sync
  func disconnectAndWipe() async                           // wipes DB + keychain (Settings)

  // published data (refreshed by refreshAll() after sync/mutations)
  private(set) var accounts: [Account]                     // sorted, with .balance populated
  private(set) var categoryGroups: [CategoryGroup]
  private(set) var payees: [Payee]
  private(set) var budgetName: String
  var currentMonth: BudgetMonth                            // navigable; didSet refreshes snapshot
  private(set) var monthSnapshot: MonthBudgetSnapshot?     // for currentMonth
  private(set) var syncStatus: SyncStatus
  private(set) var lastError: AppError?                    // toast; call clearError()
  var privacyMode: Bool                                    // blurs all amounts (AmountText redacted)

  // reads (async — route through DatabaseQueue)
  func transactions(_ q: TransactionQuery) async -> [Transaction]
  func recentTransactions(limit: Int) async -> [Transaction]
  func payeeName(_ id: String?) -> String                  // cached map; "" if nil
  func categoryName(_ id: String?) -> String
  func spendingByCategory(month: BudgetMonth) async -> [(name: String, categoryID: String, amount: Money)]
  func netWorthSeries(monthsBack: Int) async -> [(BudgetMonth, Money)]
  func monthlySpendSeries(monthsBack: Int) async -> [(BudgetMonth, Money)]
  func dailySpend(month: BudgetMonth) async -> [Int: Money]
  func suggestions(for query: PayeeSuggestionQuery) async -> [PayeeSuggestion] // Quick Add intelligence

  // mutations (each: build CRDT messages via Mutations.swift → SyncEngine.enqueue → refreshAll)
  func addTransaction(_ draft: TransactionDraft) async
  func updateTransaction(id: String, _ draft: TransactionDraft) async
  func deleteTransaction(id: String) async
  func setCleared(id: String, cleared: Bool) async
  func setBudgetAmount(month: BudgetMonth, categoryID: String, amount: Money) async
  func moveBudget(month: BudgetMonth, from: String?, to: String?, amount: Money) async // nil = To Budget
  func createPayee(name: String) async -> String           // returns new id
  func syncNow() async                                     // auto-categorizes new bank arrivals after a
                                                             // successful sync that changed transactions
}
struct TransactionDraft: Sendable { var accountID: String; var amount: Money; var date: BudgetDay
  var payeeID: String?; var newPayeeName: String?; var categoryID: String?; var notes: String?
  var cleared: Bool = true }
enum SyncStatus: Equatable { case idle(lastSync: Date?), syncing, offline(pending: Int), error(String) }
struct PayeeSuggestion: Sendable, Identifiable { var id: String { payeeID ?? name }
  var payeeID: String?; var name: String; var categoryID: String?; var lastAmount: Money? }
struct MonthBudgetSnapshot: Sendable {  // built by BudgetCalculator
  var month: BudgetMonth; var toBudget: Money; var income: Money; var totalBudgeted: Money
  var totalSpent: Money; var rows: [BudgetRowSnapshot]     // grouped, ordered like categoryGroups
}
struct BudgetRowSnapshot: Sendable, Identifiable { var id: String  // category id
  var name: String; var groupID: String; var budgeted: Money; var spent: Money; var balance: Money
  var carryover: Bool; var isIncome: Bool }
```

`Mutations.swift`: `enum Mutations` with pure static funcs producing `[CRDTMessage]` for each
operation (`addTransaction`, `updateFields`, `softDelete`, `setBudget`, `createPayee`, …) using
`HLC` timestamps obtained from SyncEngine (`await engine.nextTimestamps(count:)` — add that method).
Budget cell rows in `zero_budgets` use the row-id convention from PROTOCOL §8 (`<month>-<categoryID>`).

`BudgetCalculator.swift`: `enum BudgetCalculator { static func snapshot(month:, cells:, spent:,
income:, groups:, previous: MonthCarry?) -> MonthBudgetSnapshot }` implementing envelope math with
carryover semantics (PROTOCOL §8 + Actual docs: negative balances reset next month unless carryover
flag; To Budget = available income − budgeted, cumulative).

`Preferences.swift`: `@MainActor @Observable final class Preferences` (UserDefaults-backed):
`dashboardLayoutJSON: String`, `currencyCode: String` (didSet must also update
`CurrencyFormatter.currencyCode`), `biometricLock: Bool`, `privacyModeDefault: Bool`,
`retirementConfigJSON: String`, `defaultAccountID: String?`, plus `static let shared`.
NOTE: theme selection is NOT here — `ThemeManager` (already written) owns its own persistence.

`KeychainStore.swift`: `enum KeychainStore { static func set(_ value: String, key: String);
static func get(_ key: String) -> String?; static func delete(_ key: String) }` — keys:
`actual.serverURL`, `actual.password`, `actual.token`, `actual.fileID`, `actual.groupID`,
`actual.e2ePassword`. kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly.

## 10. SimpleFIN

In-app SimpleFIN was removed 2026-08-10 — the Actual server's own bank sync is the import path
now. The wire spec stays documented in `docs/PROTOCOL.md` §9 for a possible future standalone
mode.

## 11. Retirement module (pure math + config)

```swift
struct RetirementConfig: Codable, Sendable {   // persisted via Preferences.retirementConfigJSON
  var currentAge: Int = 35; var retireAge: Int = 60; var lifeExpectancy: Int = 95
  var linkedAccountIDs: [String] = []          // investment accounts (usually off-budget)
  var extraAssets: Money = .zero               // assets not in Actual
  var monthlyContribution: Money = .zero
  var expectedReturnPct: Double = 7.0; var returnStdDevPct: Double = 15.0
  var inflationPct: Double = 3.0; var withdrawalRatePct: Double = 4.0
  var annualSpendingOverride: Money? = nil     // nil ⇒ derive from last-12-mo budget outflow
}
struct RetirementSnapshot: Sendable {
  var invested: Money; var fiNumber: Money; var progress: Double        // invested / fiNumber
  var annualSpending: Money; var projectedRetireAge: Double?            // when deterministic path crosses FI
  var coastFIREAge: Double?; var deterministic: [YearPoint]             // real (inflation-adjusted) growth
  var percentileBands: MonteCarloBands                                  // p10/p25/p50/p75/p90 paths
  var successProbability: Double                                        // MC: money lasts to lifeExpectancy
}
struct YearPoint: Sendable, Identifiable { var id: Int { year }; var year: Int; var age: Double; var value: Money }
struct MonteCarloBands: Sendable { var years: [Int]; var p10: [Money]; var p25: [Money]; var p50: [Money]
  var p75: [Money]; var p90: [Money] }
enum RetirementPlanner {
  static func snapshot(config: RetirementConfig, investedNow: Money, annualSpendingFromBudget: Money,
                       runs: Int) -> RetirementSnapshot   // seeded deterministic RNG for stable UI
}
```
MonteCarlo.swift: `struct SeededGenerator: RandomNumberGenerator` (SplitMix64) + normal sampling
(Box–Muller); simulate annual real returns N(µ−inflation, σ), accumulation to retireAge then
withdrawals of annualSpending; compute bands + success probability. Must run < 50ms for 1,000 runs
off-main (`Task.detached(priority: .userInitiated)`).

## 12. Dashboard contracts (Features/Dashboard)

```swift
enum WidgetKind: String, Codable, CaseIterable, Identifiable {
  case toBudget, netWorth, spendingRing, accountsList, recentActivity, cashFlow,
       savingsRate, fiProgress, monthProgress, spendHeatmap, quickAdd, topCategories
  var id: String { rawValue }
  var displayName: String  ; var systemImage: String
  var allowedSpans: [WidgetSpan] ; var defaultSpan: WidgetSpan
}
enum WidgetSpan: String, Codable { case s1x1, s2x1, s2x2 ; var cols: Int ; var rows: Int }
struct DashboardItem: Codable, Identifiable, Equatable { var id: UUID; var kind: WidgetKind; var span: WidgetSpan }

@MainActor @Observable final class DashboardModel {
  var items: [DashboardItem]              // persisted to Preferences.dashboardLayoutJSON on change
  var isEditing: Bool
  static let defaultLayout: [DashboardItem]
  func move(from: IndexSet, to: Int); func remove(_ id: UUID)
  func add(_ kind: WidgetKind); func cycleSpan(_ id: UUID)
  var unusedKinds: [WidgetKind] { get }
}
```

Layout algorithm (DashboardGrid.swift): first-fit packing of spans into a 2-column grid; the grid
**fills the available height** — rows get `(availableHeight − spacing) / rowCount` where rowCount is
derived from total occupied cells (max 4 rows; if content exceeds capacity the ADD flow prevents it:
`DashboardModel.canAdd(kind)` checks capacity of 8 cells). NO ScrollView anywhere on the dashboard.
Edit mode: long-press → jiggle (±0.6° rotation wobble, respect reduceMotion), drag to reorder
(custom drag with matchedGeometryEffect), − badge to remove, tap-span badge to cycle size, "+"
opens `WidgetGallerySheet` (grid of previews rendered small with `.allowsHitTesting(false)`).
Each widget is a self-contained view `struct <Kind>Widget: View { let span: WidgetSpan }` reading
AppStore from environment; every widget must render meaningful content at 1x1 where allowed, richer
at larger spans, and deep-link (`Button`/`NavigationLink` via `AppRouter` below) into its feature.

## 13. Navigation & app shell

```swift
// RootView.swift owns the tab bar + global overlays
enum AppTab: String, CaseIterable { case dashboard, budget, transactions, retire, settings }
@MainActor @Observable final class AppRouter {
  var tab: AppTab
  var transactionsPath: NavigationPath ; var budgetPath: NavigationPath ; var settingsPath: NavigationPath
  var quickAddPresented: Bool          // global sheet, reachable from every tab
  func openAccount(_ id: String); func openReports(); func openTransactions(filter: TransactionQuery)
}
```
RootView: `TabView` with the 5 tabs (iOS 26 `Tab` API), `.tint(theme.palette.accent)`,
`.tabBarMinimizeBehavior(.onScrollDown)`; the **Quick Add tab bar accessory** rides the tab bar
via `.tabViewBottomAccessory { }` — a full-width row (accent `plus.circle` + "Add transaction",
min height 44, `Haptics.tap`) that opens the `router.quickAddPresented` sheet with
`.presentationDetents([.height(560), .large])`. It draws no background of its own: the accessory
slot already renders the bar's glass, so a second `.glassEffect()` inside it would double the
material. The system insets scrollable content for the accessory, so unlike the old floating
button it can never cover a list row. The modifier stays applied on every screen and the content
is `EmptyView` outside dashboard/budget/transactions or while that tab has anything pushed
(`AppRouter.isAtRoot(of:)`) — emptying the content rather than dropping the modifier keeps the
TabView's identity, and therefore the tab stacks' state, stable across pushes and pops.
Also hosts: sync status pill (top, appears during sync / offline with pending count), error toast,
privacy-mode blur when app resigns active (`scenePhase`), `AppLockScreen` gate when
`Preferences.biometricLock` (LocalAuthentication, `.faceID`; locks on background, 8s grace).
Onboarding (`App/Onboarding/`): 3 screens — welcome/identity → server connect (URL+password,
Tailscale hint, connection test with animated states) → file pick + optional E2E password → done
(confetti-free; use symbol effect). Reuses `AppStore.connect/selectFile`.

## 14. Screen specs (Features/*)

**Budget** (`BudgetView`): month controls in the navigation bar (chevron nav flanking a tappable
month title that opens `MonthPickerSheet`, inline title mode, no "Budget" text title, so the List
sits directly under the bar); hero row: To Budget
amount (AmountText .display, green/red); grouped category rows: name, budgeted (tap → inline
`BudgetAmountEditor` sheet w/ keypad), spent (tap → filtered transactions), balance pill (colorized,
carryover indicator). Swipe actions: move money (opens `MoveMoneySheet`: from/to category pickers +
keypad). Progress bar per category (spent/budgeted) using theme accent gradient. Income group
collapsed by default. Each group header carries a trailing "+" that creates a category in that
group; whole GROUPS are created in `ManageCategoriesView`, not from this list.

**Manage Categories** (`ManageCategoriesView`, pushed from Budget's toolbar): every group and
category including hidden ones, one Section per group, per-`ForEach` `.onMove` reordering, and
context menus for rename / hide / move / delete. With `EditButton` on, naming becomes first-class:
tapping any group header or category row opens its rename sheet, each group gains an inline "Add
category" row, and the list ends with "New group".

**Transactions** (`TransactionsView`): searchable list (`.searchable`), grouped by day
(SectionHeader with relative dates), rows: payee, category chip, notes line, AmountText, cleared
dot (tap toggles w/ spring). Filters: a trailing-toolbar Menu (account Picker + uncategorized
Toggle); deep-linked category/payee/month filters show a clearable chip above the List. Swipe:
delete / edit / toggle cleared. Infinite scroll paging (100/page). Tap row → `TransactionDetailView`
(editable form reusing QuickAdd pieces). Pull-to-refresh triggers `syncNow`.

**QuickAdd** (`QuickAddView`) — the crown jewel, ≤3 actions: opens with keypad focused, big
AmountText hero that ticks with `.numericText()`; sign toggle (expense default); payee field with
live `suggestions()` (recent/frequent, shows last amount + auto-category); category auto-fills from
suggestion (changeable via chip row of top-6 categories + "all" sheet); account defaults to
`Preferences.defaultAccountID`; date defaults today (chip row: Today/Yesterday/picker); Save =
NidgetButton primary full-width → `Haptics.success` + checkmark symbol-effect overlay → dismiss.
Landscape of the whole flow must be possible thumb-only.

**Accounts** (`AccountsView` pushed from dashboard/settings + `AccountDetailView`): net worth hero
w/ Sparkline, sections For Budget / Off Budget / Closed (collapsed), rows: name, cleared balance.
Detail: balance hero, running-balance toggle, filtered transaction list reusing components,
reconcile affordance (marks cleared→reconciled).

**Reports** (`ReportsView` pushed via router): segmented (Spending / Net Worth / Cash Flow /
Sankey-less category trends). Swift Charts styled per `theme.chart` (bar corner radii, area
gradients, no hardcoded colors), month-range ChipPicker, tap-to-select with annotation callout.

**Retirement** (`RetirementView` tab): FI progress hero (GaugeArc + AmountText invested vs FI
number), projection chart (deterministic line + MC bands as layered opacity areas, Swift Charts),
success probability stat, coast-FIRE callout, "what if" quick sliders (retire age, monthly
contribution, return) that live-update with `theme.motion.spring`, `AssumptionsSheet` for full
`RetirementConfig` editing incl. linked-accounts multi-pick. All charts respect privacyMode.

**Settings** (`SettingsView`): server card (status, budget name, sync now, disconnect),
Appearance (theme gallery link, appearance mode picker, app icon note), Dashboard (edit layout
button → switches tab + enables edit), Security (FaceID toggle, privacy mode), Currency picker,
About. `ThemeGalleryView`: 2-col grid of live miniature previews (mini dashboard mock rendered with
each theme's tokens), sectioned Light/Dark, tap = apply + `Haptics.success`; current selection ring.

## 15. Quality bar

- Every screen handles: loading, empty (EmptyStateView with personality), error, privacyMode.
- Every list row is ≥44pt tap target; hero numbers use `contentTransition(.numericText())`.
- `.sensoryFeedback` / Haptics on: save, sync complete, budget zero-out, theme apply, widget add.
- No English-locale assumptions in formatting (use FormatStyle APIs); currency from Preferences.
- Accessibility: Dynamic Type up to XL must not break dashboard (widgets clamp with `minimumScaleFactor`),
  all interactive elements labeled, reduceMotion honored, contrast ≥4.5:1 for text in every theme.
- App Intents (`Platform/AppShortcuts.swift`): `AddTransactionIntent` (amount, payee, category?,
  account?) callable from Siri/Shortcuts writing through AppStore; `OpenQuickAddIntent`.

## 16. Feature wiring (BINDING for all Feature/* and App/* code)

**Environment injection** (done once in `NidgetApp`/`RootView`; feature views only consume):
```swift
// NidgetApp: .environment(AppStore.shared) .environment(ThemeManager.shared)
//            .environment(Preferences.shared) .environment(router)   // router: @State in NidgetApp
// RootView additionally: .environment(\.theme, themeManager.active)
//                        .environment(\.privacyMode, store.privacyMode)
// Feature views consume: @Environment(AppStore.self) private var store
//                        @Environment(AppRouter.self) private var router
//                        @Environment(\.theme) private var theme
```

**AppRouter (App/AppRouter.swift, owned by the shell agent) — exact API:**
```swift
enum AppTab: String, CaseIterable { case dashboard, budget, transactions, retire, settings }
enum Route: Hashable {
  case accounts, account(String), reports, transactionDetail(String),
       themeGallery, securitySettings, retirementAssumptions
}
@MainActor @Observable final class AppRouter {
  var tab: AppTab = .dashboard
  var dashboardPath = NavigationPath(); var budgetPath = NavigationPath()
  var transactionsPath = NavigationPath(); var retirePath = NavigationPath()
  var settingsPath = NavigationPath()
  var quickAddPresented = false
  var pendingTransactionFilter: TransactionQuery?   // consumed by TransactionsView .task(id:)
  func push(_ route: Route)                         // appends to the CURRENT tab's path
  func isAtRoot(of tab: AppTab) -> Bool             // that tab's path is empty (gates the Quick Add accessory)
  func openAccount(_ id: String)                    // push(.account(id))
  func openReports()                                // push(.reports)
  func openTransactions(filter: TransactionQuery)   // set pendingTransactionFilter, tab = .transactions
}
```
Every tab's top view owns `NavigationStack(path: $router.<tab>Path)` (via `@Bindable var router`)
and applies `.withRouteDestinations()` — a modifier declared in AppRouter.swift whose
`navigationDestination(for: Route.self)` maps: `.accounts → AccountsView()`,
`.account(id) → AccountDetailView(accountID: id)`, `.reports → ReportsView()`,
`.transactionDetail(id) → TransactionDetailView(transactionID: id)`,
`.themeGallery → ThemeGalleryView()`,
`.securitySettings → SecuritySettingsView()`, `.retirementAssumptions → AssumptionsSheet()`.
Those view names + init signatures are therefore BINDING on their owning agents.
`QuickAddView()` takes no arguments and is presented as a sheet by RootView.

**Stashy lessons in force (docs/LESSONS_FROM_STASHY.md):** static backdrop/decoration layers keyed
with a stable `.id(theme.id)`; never write per-frame geometry into `@State` on scroll paths; every
`.task(id:)` guards state writes with `!Task.isCancelled`; optimistic edits carry a per-id sequence
token checked before rollback/commit.
