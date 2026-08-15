import Foundation
import Observation
import os

// MARK: - YearsAnchor

/// Transient scroll target handed from a glance tile to YearsView, which consumes it once and
/// clears it, so two tiles can push the same screen without ambiguity.
enum YearsAnchor: Hashable {
    case downPayment
}

// MARK: - HouseholdPlaceRunway

/// One destination with its runway worked out. Computed off the main actor beside the
/// projection so the Places screen and the glance tile never do this math while drawing.
struct HouseholdPlaceRunway: Sendable, Equatable, Identifiable {
    var destination: Destination
    var runway: DestinationRunway

    var id: String { destination.id }
}

// MARK: - HouseholdPlanModel
//
// The household plan's state machine, lifted from the pre-redesign Household Plan screen so the
// glance and the drill-ins (Years, Debt, Places) share one plan through the environment.
//
// Where the numbers come from: Retiron (the self-hosted planner) holds the named scenarios.
// `load()` draws the cached scenario first so something is on screen straight away, then asks
// Retiron for the current list and the active scenario, mapping the chosen one into
// `HouseholdPlanConfig` through `RetironProfileMapper`. The last scenario is cached in
// `Preferences.retironProfileCacheJSON`, so the plan still draws when Retiron is asleep; edits
// are written to that cache first and pushed to Retiron after (600 ms debounced), never the
// other way round, which means a failed save costs the owner nothing.
//
// Compute pattern is PersonalPlanModel's: `recomputeKey` is the owning view's `.task(id:)` key,
// a first plan renders immediately and every later change waits 250 ms before recomputing, and
// cancellation guards keep a stale run from landing on a newer one. The projection, the debt
// simulation, and the destination runways all come out of the one detached task.
//
// Wiring contract for the owning view:
//   .task { await model.load() }              // and .refreshable { await model.load() }
//   .task(id: model.recomputeKey) { await model.recompute() }
// Animations moved to the view layer: the model sets state plainly and views attach
// `.animation(_:value:)` where they want motion.

@MainActor @Observable
final class HouseholdPlanModel {

    private static let log = Logger(subsystem: "app.nidget", category: "retiron")

    /// Keychain keys for the Retiron link. AppStore keeps its own private copies of these two
    /// strings; they are the contract in ARCHITECTURE, part 9, not something either file invents.
    private static let serverURLKey = "retiron.serverURL"
    private static let tokenKey = "retiron.token"

    private let preferences: Preferences

    /// The scenario being shown, exactly as Retiron stores it. Single source of truth: the
    /// config and the debt accounts are both read out of this, and every edit writes back into
    /// it. The owning view keys the projection on it via `.task(id:)`.
    private(set) var profile: RetironProfileData?
    private(set) var scenarioNames: [String] = []
    private(set) var selectedName: String?

    /// Bumped every time the scenario on screen changes, whether it arrived from Retiron
    /// (`adopt`) or from an edit here (`commit`). Cheaper to compare than the whole profile, and
    /// it is what `recomputeKey` carries.
    private(set) var revision = 0

    private(set) var plan: HouseholdPlanResult?
    /// Destination runways for the plan above, computed in the same detached pass.
    private(set) var runways: [HouseholdPlaceRunway] = []

    private(set) var isLoading = false
    private(set) var isRecomputing = false
    private(set) var loadError: String?
    /// Set when an edit reached this phone but not Retiron. The plan still shows; this is the
    /// honest note beside it.
    private(set) var saveError: String?
    /// True only while a debounced push to Retiron is actually on the wire.
    private(set) var isSaving = false
    /// Last successful round trip with Retiron (load or save), for the footer's "Updated" line.
    private(set) var lastSynced: Date?

    /// The debounced push of an edited scenario back to Retiron.
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The key the plan on screen was computed from, so a repeat pass can be skipped.
    @ObservationIgnored private var lastComputedKey: RecomputeKey?

    /// Scroll target for YearsView, set by a glance tile and consumed (cleared) on arrival.
    var pendingYearsAnchor: YearsAnchor?

    init(preferences: Preferences = .shared) {
        self.preferences = preferences
    }

    // MARK: Derived state

    var isConnected: Bool {
        preferences.retironEnabled && KeychainStore.get(Self.serverURLKey) != nil
    }

    /// Any activity worth a spinner: the initial or refresh load, a push on the wire, or the
    /// projection catching up with an edit.
    var isSyncing: Bool { isLoading || isSaving || isRecomputing }

    /// Everything the projection depends on, in one comparable value. The owning view uses it as
    /// its `.task(id:)` key, so a personal withdrawal-rate change reruns the household math the
    /// same way an edited scenario does.
    struct RecomputeKey: Equatable {
        var revision: Int
        var fiMultiple: Double
    }

    var recomputeKey: RecomputeKey {
        RecomputeKey(revision: revision, fiMultiple: personalFIMultiple)
    }

    private var api: RetironAPI? {
        guard preferences.retironEnabled,
              let host = KeychainStore.get(Self.serverURLKey),
              let url = URL(string: host) else { return nil }
        return RetironAPI(baseURL: url, token: KeychainStore.get(Self.tokenKey) ?? "")
    }

    // MARK: Sync state

    /// The single source of truth for every sync surface (hero spinner, scenario captions,
    /// notice cards, footer plumbing card). No surface reads the raw flags directly, so no two
    /// surfaces can ever disagree.
    enum SyncState: Equatable {
        case notConnected
        case syncing
        case live(updated: Date)
        case cached(loadError: String?)
        case localEdits(saveError: String)
    }

    var syncState: SyncState {
        guard isConnected else { return .notConnected }
        if isSyncing { return .syncing }
        if let saveError { return .localEdits(saveError: saveError) }
        if let loadError { return .cached(loadError: loadError) }
        if let lastSynced { return .live(updated: lastSynced) }
        // Connected but nothing has come back yet this session: the cache is what's showing.
        return .cached(loadError: nil)
    }

    // MARK: Loading from Retiron

    /// Draws the cached scenario first so something is on screen straight away, then asks
    /// Retiron for the current list and the active scenario.
    func load() async {
        if profile == nil, let cached = RetironProfileData(jsonString: preferences.retironProfileCacheJSON) {
            profile = cached
            revision += 1
            let cachedName = preferences.retironActiveProfileName
            selectedName = cachedName.isEmpty ? nil : cachedName
            // The scenario chips come back with the cached plan, so the row does not appear
            // empty and then pop into place when Retiron answers.
            if scenarioNames.isEmpty {
                scenarioNames = Self.decodedNames(preferences.retironScenarioNames)
            }
        }
        guard let api else { return }
        isLoading = true
        // Every exit clears the flag, including the cancellation guards below, so a view that
        // goes away mid-load cannot leave the spinner running forever.
        defer { isLoading = false }
        do {
            let list = try await api.profiles()
            guard !Task.isCancelled else { return }
            scenarioNames = list.profiles.map(\.name)
            preferences.retironScenarioNames = Self.encodedNames(scenarioNames)
            // A remembered name Retiron no longer knows 404s on fetch, and worse, the next
            // edit's save would upsert it straight back into existence. Forget it and follow
            // Retiron.
            if let remembered = selectedName, !scenarioNames.contains(remembered) {
                selectedName = nil
                preferences.retironActiveProfileName = ""
            }
            let target = selectedName ?? list.active ?? list.profiles.first?.name
            if let target {
                let fetched = try await api.profile(named: target)
                guard !Task.isCancelled else { return }
                adopt(fetched)
            }
            loadError = nil
            lastSynced = Date()
        } catch {
            guard !Task.isCancelled else { return }
            Self.log.error("Retiron plan load failed: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    /// The scenario-name cache is a JSON array so a name containing any separator character
    /// still survives the round trip.
    private static func encodedNames(_ names: [String]) -> String {
        guard let data = try? JSONEncoder().encode(names) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodedNames(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return names
    }

    /// Switches scenario: fetch it, show it, and tell Retiron it is the active one.
    func select(_ name: String) {
        guard !name.isEmpty, name != selectedName, let api else { return }
        Haptics.tick()
        // `selectedName` is the name `scheduleSave` writes under, so it must never run ahead of
        // the data in `profile`. `adopt` sets it once the right scenario is actually in hand;
        // until then the chips stay put and the sync spinner carries the feedback.
        isLoading = true
        Task { [self] in
            // Same reason as `load`: the cancellation guards below must not be able to leave the
            // spinner running.
            defer { isLoading = false }
            do {
                let fetched = try await api.profile(named: name)
                guard !Task.isCancelled else { return }
                adopt(fetched)
                try await api.setActive(name)
                guard !Task.isCancelled else { return }
                loadError = nil
                lastSynced = Date()
            } catch {
                guard !Task.isCancelled else { return }
                Self.log.error("Retiron scenario switch failed: \(error.localizedDescription, privacy: .public)")
                loadError = error.localizedDescription
            }
        }
    }

    /// Takes a fetched scenario as the one on screen and caches it for the next offline visit.
    private func adopt(_ fetched: RetironProfile) {
        profile = fetched.data
        revision += 1
        selectedName = fetched.name
        // Retiron's copy is now what's on screen, so any earlier failed push has nothing left to
        // warn about.
        saveError = nil
        preferences.retironActiveProfileName = fetched.name
        if let json = fetched.data.jsonString {
            preferences.retironProfileCacheJSON = json
        }
    }

    // MARK: Edits

    func applyConfig(_ config: HouseholdPlanConfig) {
        guard let current = profile else { return }
        commit(RetironProfileMapper.apply(config, to: current))
    }

    func applyAccounts(_ accounts: [DebtAccount]) {
        guard let current = profile else { return }
        commit(RetironProfileMapper.apply(accounts, to: current))
    }

    func applyDebtBudget(_ budget: Double) {
        guard let current = profile else { return }
        commit(RetironProfileMapper.apply(monthlyDebtBudget: budget, to: current))
    }

    func applyStrategy(_ strategy: DebtStrategy) {
        guard let current = profile else { return }
        commit(RetironProfileMapper.apply(strategy: strategy, to: current))
    }

    /// One place every edit lands: the phone keeps it immediately (state + cache, which
    /// restarts the projection through the owning view's `.task(id:)`), and Retiron hears about
    /// it a moment later.
    func commit(_ edited: RetironProfileData) {
        profile = edited
        revision += 1
        if let json = edited.jsonString {
            preferences.retironProfileCacheJSON = json
        }
        scheduleSave(edited)
    }

    /// Pushes the scenario on screen again after a failed save, for the "Try again" the notice
    /// card offers.
    func retrySave() {
        guard let profile else { return }
        scheduleSave(profile)
    }

    /// Pushes the scenario back to Retiron, 600 ms after the last edit so a dragged slider is
    /// one save rather than fifty.
    private func scheduleSave(_ edited: RetironProfileData) {
        saveTask?.cancel()
        guard let api, let name = selectedName, !name.isEmpty else {
            saveError = nil
            return
        }
        saveTask = Task { [self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            isSaving = true
            defer { isSaving = false }
            do {
                try await api.saveProfile(name, data: edited)
                guard !Task.isCancelled else { return }
                saveError = nil
                lastSynced = Date()
            } catch {
                guard !Task.isCancelled else { return }
                Self.log.error("Retiron profile save failed: \(error.localizedDescription, privacy: .public)")
                Haptics.warning()
                saveError = error.localizedDescription
            }
        }
    }

    // MARK: Recompute

    /// What the detached compute pass hands back in one piece.
    private struct Computed: Sendable {
        var plan: HouseholdPlanResult
        var runways: [HouseholdPlaceRunway]
    }

    /// Projects the scenario off the main actor. The engine is fast, but it is 25 years of
    /// compounding plus up to 120 months of debt simulation, and the main actor is for drawing.
    func recompute() async {
        guard let data = profile else { return }
        let key = recomputeKey
        // Coming back to the tab with an up-to-date plan shouldn't burn another projection.
        if plan != nil, lastComputedKey == key { return }

        if plan != nil {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            isRecomputing = true
        }

        let config = RetironProfileMapper.config(from: data)
        let accounts = RetironProfileMapper.debtAccounts(from: data)
        let strategy = RetironProfileMapper.strategy(from: data)
        let budget = RetironProfileMapper.monthlyDebtBudget(from: data)
        let transfer = RetironProfileMapper.balanceTransfer(from: data)
        let fiMultiple = key.fiMultiple

        // Cancelling the owning view's task does NOT reach into the detached one; it finishes
        // and the guard below keeps its stale answer from landing.
        let result = await Task.detached(priority: .userInitiated) { () -> Computed in
            let rows = HouseholdPlanner.project(config)
            let raw = HouseholdPlanner.fiSummary(rows: rows, config: config,
                                                 fiMultiple: fiMultiple)
            let summary = HouseholdSummary(fiTarget: raw.fiTarget,
                                           portfolioAtTarget: raw.portfolioAtTarget,
                                           fiPct: raw.fiPct,
                                           netWorthAtTarget: raw.netWorthAtTarget,
                                           debtFreeYearIndex: raw.debtFreeYearIndex,
                                           dpHitYearIndex: raw.dpHitYearIndex)
            let debt = DebtSimulator.simulate(accounts: accounts, monthlyBudget: budget,
                                              strategy: strategy, balanceTransfer: transfer)
            let plan = HouseholdPlanResult(config: config, rows: rows, summary: summary,
                                           accounts: accounts, strategy: strategy,
                                           monthlyDebtBudget: budget, debt: debt)
            let yearsToTarget = max(0, config.targetRetirementAge - config.personA.age)
            let rentAnnual = (plan.targetRow?.netRentMonthly ?? 0) * 12
            let runways = Destination.defaults.map { destination in
                HouseholdPlaceRunway(destination: destination,
                                     runway: DestinationMath.runway(destination: destination,
                                                                    portfolioAtTarget: summary.portfolioAtTarget,
                                                                    netRentAnnualAtTarget: rentAnnual,
                                                                    inflationPct: config.inflationPct,
                                                                    yearsToTarget: yearsToTarget))
            }
            return Computed(plan: plan, runways: runways)
        }.value
        guard !Task.isCancelled else { return }

        plan = result.plan
        runways = result.runways
        lastComputedKey = key
        isRecomputing = false
    }

    /// 25 by default (the 4% rule); when the owner has saved a personal RetirementConfig, the
    /// household goal follows their withdrawal rate instead, so the hero goal and the What If
    /// FI line agree on what "enough" means.
    private var personalFIMultiple: Double {
        let json = preferences.retirementConfigJSON
        guard !json.isEmpty else { return HouseholdPlanner.fiMultiple }
        let config = RetirementConfigCodec.decode(json)
        return 100 / max(config.withdrawalRatePct, 0.1)
    }
}
