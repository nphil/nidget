import SwiftUI
import os

// MARK: - Household plan result types
//
// What one run of the engine hands back, carried from the detached compute task to the section
// views. Everything is Sendable so it can cross that boundary; everything is plain data so the
// sections stay dumb and the screen owns all the state.

/// The headline numbers `HouseholdPlanner.fiSummary` works out, in a named struct so it can ride
/// out of a detached task and into four different section views.
struct HouseholdSummary: Sendable, Equatable {
    var fiTarget: Double
    var portfolioAtTarget: Double
    var fiPct: Double
    var netWorthAtTarget: Double
    var debtFreeYearIndex: Int?
    var dpHitYearIndex: Int?
}

/// One complete plan: the projection, its summary, and the monthly debt payoff run beside it.
struct HouseholdPlanResult: Sendable {
    var config: HouseholdPlanConfig
    var rows: [HouseholdYear]
    var summary: HouseholdSummary
    var accounts: [DebtAccount]
    var strategy: DebtStrategy
    var monthlyDebtBudget: Double
    var debt: DebtSimResult

    /// The row the summary is reported against: the target age, or the last row when the target
    /// sits past the horizon.
    var targetRow: HouseholdYear? {
        rows.first { $0.ageA == config.targetRetirementAge } ?? rows.last
    }
}

/// The four faces of the screen. Overview opens first.
enum HouseholdPlanSection: String, CaseIterable, Hashable {
    case overview, years, debt, places

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .years: return "Years"
        case .debt: return "Debt"
        case .places: return "Places"
        }
    }
}

// MARK: - HouseholdPlanView
//
// The household plan: two earners, two homes, consumer debt, a down-payment goal and a target
// retirement age, all projected 25 years out. Pushed via `Route.householdPlan`, so it owns no
// NavigationStack of its own.
//
// Where the numbers come from: Retiron (the self-hosted planner) holds the named scenarios. This
// screen fetches one, maps it into `HouseholdPlanConfig` through `RetironProfileMapper`, and runs
// `HouseholdPlanner.project` plus `DebtSimulator.simulate` off the main actor. The last scenario
// is cached in `Preferences.retironProfileCacheJSON`, so the plan still draws when Retiron is
// asleep; edits are written to that cache first and pushed to Retiron after, never the other way
// round, which means a failed save costs the owner nothing.
//
// Compute pattern is RetirementView's: the whole profile is the `.task(id:)` key, a first plan
// renders immediately and every later change waits 250 ms before recomputing, and cancellation
// guards keep a stale run from landing on a newer one.

@MainActor
struct HouseholdPlanView: View {
    @Environment(AppRouter.self) private var router
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let log = Logger(subsystem: "app.nidget", category: "retiron")

    /// Keychain keys for the Retiron link. AppStore keeps its own private copies of these two
    /// strings; they are the contract in ARCHITECTURE §9, not something either file invents.
    private static let serverURLKey = "retiron.serverURL"
    private static let tokenKey = "retiron.token"

    /// The scenario being shown, exactly as Retiron stores it. Single source of truth: the config
    /// and the debt accounts are both read out of this, and every edit writes back into it.
    @State private var profile: RetironProfileData?
    @State private var scenarioNames: [String] = []
    @State private var selectedName: String?
    @State private var activeName: String?

    @State private var plan: HouseholdPlanResult?
    @State private var section: HouseholdPlanSection = .overview
    @State private var isLoading = false
    @State private var isRecomputing = false
    @State private var loadError: String?
    /// Set when an edit reached this phone but not Retiron. The plan still shows; this is the
    /// honest note beside it.
    @State private var saveError: String?
    @State private var showInputs = false
    /// The debounced push of an edited scenario back to Retiron.
    @State private var saveTask: Task<Void, Never>?

    // MARK: Derived state

    private var isConnected: Bool {
        preferences.retironEnabled && KeychainStore.get(Self.serverURLKey) != nil
    }

    private var api: RetironAPI? {
        guard preferences.retironEnabled,
              let host = KeychainStore.get(Self.serverURLKey),
              let url = URL(string: host) else { return nil }
        return RetironAPI(baseURL: url, token: KeychainStore.get(Self.tokenKey) ?? "")
    }

    /// Chip selection. Setting it loads that scenario and tells Retiron it is the active one.
    private var scenarioBinding: Binding<String> {
        Binding(get: { selectedName ?? scenarioNames.first ?? "" },
                set: { select($0) })
    }

    // MARK: Body

    var body: some View {
        content
            .themedScreen()
            .navigationTitle("Household Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showInputs = true
                    } label: {
                        Image(systemName: "pencil")
                            .symbolVariant(theme.icons.fill ? .fill : .none)
                            .fontWeight(theme.icons.weight)
                    }
                    .disabled(plan == nil)
                    .accessibilityLabel("Edit plan inputs")
                }
            }
            .task {
                await load()
            }
            .task(id: profile) {
                await recompute()
            }
            .sheet(isPresented: $showInputs) {
                if let plan {
                    HouseholdInputsSheet(config: plan.config) { edited in
                        applyConfig(edited)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !isConnected {
            notConnectedState
        } else if let plan {
            planScroll(plan)
        } else if isLoading || profile != nil {
            loadingView
        } else {
            errorState
        }
    }

    // MARK: Screen states

    private var notConnectedState: some View {
        EmptyStateView(systemImage: "server.rack",
                       title: "Connect Retiron",
                       message: "Retiron is the planner that holds your household scenarios. Point Nidget at it and the whole plan shows up here.",
                       actionTitle: "Set Up Retiron",
                       action: { router.push(.retironSettings) })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: theme.layout.spacing) {
            ProgressView()
                .controlSize(.large)
                .tint(theme.palette.accent)
            Text("Working out the next 25 years…")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorState: some View {
        EmptyStateView(systemImage: "antenna.radiowaves.left.and.right.slash",
                       title: "Retiron isn't answering",
                       message: loadError ?? "Nothing came back from Retiron, and there is no saved plan on this phone yet.",
                       actionTitle: "Try Again",
                       action: { Task { await load() } })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Layout

    private func planScroll(_ plan: HouseholdPlanResult) -> some View {
        ScrollView {
            VStack(spacing: theme.layout.cardSpacing) {
                scenarioCard
                if let loadError {
                    noticeCard("Retiron isn't answering", loadError)
                }
                if let saveError {
                    noticeCard("Saved on this phone only", saveError)
                }
                ChipPicker(items: HouseholdPlanSection.allCases,
                           selection: $section,
                           label: { $0.label })
                switch section {
                case .overview:
                    HouseholdOverviewSection(plan: plan)
                case .years:
                    HouseholdYearList(plan: plan)
                case .debt:
                    HouseholdDebtSection(plan: plan,
                                         onEditAccounts: { applyAccounts($0) },
                                         onSetBudget: { applyDebtBudget($0) },
                                         onSetStrategy: { applyStrategy($0) })
                case .places:
                    HouseholdPlacesSection(plan: plan)
                }
            }
            .padding(.horizontal, theme.layout.cardPadding)
            .padding(.top, theme.layout.spacing * 0.5)
            .padding(.bottom, theme.layout.cardSpacing)
            .animation(reduceMotion ? nil : theme.motion.spring, value: section)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await load()
        }
    }

    // MARK: Scenario row

    private var scenarioCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            HStack {
                cardLabel("Scenario")
                Spacer(minLength: theme.layout.spacing)
                if isRecomputing || isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.palette.accent)
                }
            }
            if scenarioNames.count > 1 {
                ChipPicker(items: scenarioNames, selection: scenarioBinding, label: { $0 })
            } else {
                Text(selectedName ?? "Your plan")
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
            }
            Text(scenarioCaption)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedCard()
    }

    private var scenarioCaption: String {
        if scenarioNames.isEmpty {
            return "Saved on this phone from your last visit. Changes go to Retiron when it answers again."
        }
        if let selectedName, let activeName, selectedName != activeName {
            return "Retiron is showing \(activeName). Tap a name to switch both."
        }
        return "This is the scenario Retiron is showing too."
    }

    private func noticeCard(_ title: String, _ message: String) -> some View {
        HStack(alignment: .top, spacing: theme.layout.spacing * 0.75) {
            Image(systemName: "exclamationmark.triangle")
                .font(theme.font(.title))
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.palette.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(message)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .themedCard()
    }

    // MARK: Loading from Retiron

    /// Draws the cached scenario first so something is on screen straight away, then asks Retiron
    /// for the current list and the active scenario.
    private func load() async {
        if profile == nil, let cached = RetironProfileData(jsonString: preferences.retironProfileCacheJSON) {
            profile = cached
            let cachedName = preferences.retironActiveProfileName
            selectedName = cachedName.isEmpty ? nil : cachedName
        }
        guard let api else { return }
        isLoading = true
        do {
            let list = try await api.profiles()
            guard !Task.isCancelled else { return }
            scenarioNames = list.profiles.map(\.name)
            activeName = list.active
            // A remembered name Retiron no longer knows 404s on fetch, and worse, the next edit's
            // save would upsert it straight back into existence. Forget it and follow Retiron.
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
            isLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            Self.log.error("Retiron plan load failed: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    /// Switches scenario: fetch it, show it, and tell Retiron it is the active one.
    private func select(_ name: String) {
        guard !name.isEmpty, name != selectedName, let api else { return }
        Haptics.tick()
        // `selectedName` is the name `scheduleSave` writes under, so it must never run ahead of
        // the data in `profile`. `adopt` sets it once the right scenario is actually in hand;
        // until then the chip stays put and the card spinner carries the feedback.
        isLoading = true
        Task {
            do {
                let fetched = try await api.profile(named: name)
                guard !Task.isCancelled else { return }
                adopt(fetched)
                try await api.setActive(name)
                guard !Task.isCancelled else { return }
                activeName = name
                loadError = nil
            } catch {
                guard !Task.isCancelled else { return }
                Self.log.error("Retiron scenario switch failed: \(error.localizedDescription, privacy: .public)")
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// Takes a fetched scenario as the one on screen and caches it for the next offline visit.
    private func adopt(_ fetched: RetironProfile) {
        profile = fetched.data
        selectedName = fetched.name
        preferences.retironActiveProfileName = fetched.name
        if let json = fetched.data.jsonString {
            preferences.retironProfileCacheJSON = json
        }
    }

    // MARK: Edits

    private func applyConfig(_ config: HouseholdPlanConfig) {
        guard let current = profile else { return }
        commit(RetironProfileMapper.apply(config, to: current))
    }

    private func applyAccounts(_ accounts: [DebtAccount]) {
        guard let current = profile else { return }
        commit(RetironProfileMapper.apply(accounts, to: current))
    }

    private func applyDebtBudget(_ budget: Double) {
        guard let current = profile else { return }
        commit(RetironProfileMapper.apply(monthlyDebtBudget: budget, to: current))
    }

    private func applyStrategy(_ strategy: DebtStrategy) {
        guard let current = profile else { return }
        commit(RetironProfileMapper.apply(strategy: strategy, to: current))
    }

    /// One place every edit lands: the phone keeps it immediately (state + cache, which restarts
    /// the projection through `.task(id:)`), and Retiron hears about it a moment later.
    private func commit(_ edited: RetironProfileData) {
        profile = edited
        if let json = edited.jsonString {
            preferences.retironProfileCacheJSON = json
        }
        scheduleSave(edited)
    }

    /// Pushes the scenario back to Retiron, 600 ms after the last edit so a dragged slider is one
    /// save rather than fifty.
    private func scheduleSave(_ edited: RetironProfileData) {
        saveTask?.cancel()
        guard let api, let name = selectedName, !name.isEmpty else {
            saveError = nil
            return
        }
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            do {
                try await api.saveProfile(name, data: edited)
                guard !Task.isCancelled else { return }
                saveError = nil
            } catch {
                guard !Task.isCancelled else { return }
                Self.log.error("Retiron profile save failed: \(error.localizedDescription, privacy: .public)")
                Haptics.warning()
                withAnimation(reduceMotion ? nil : theme.motion.spring) {
                    saveError = error.localizedDescription
                }
            }
        }
    }

    // MARK: Recompute

    /// Projects the scenario off the main actor. The engine is fast, but it is 25 years of
    /// compounding plus up to 120 months of debt simulation, and the main actor is for drawing.
    private func recompute() async {
        guard let data = profile else { return }

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

        // Cancelling this view's task does NOT reach into the detached one; it finishes and the
        // guard below keeps its stale answer from landing.
        let result = await Task.detached(priority: .userInitiated) { () -> HouseholdPlanResult in
            let rows = HouseholdPlanner.project(config)
            let raw = HouseholdPlanner.fiSummary(rows: rows, config: config)
            let summary = HouseholdSummary(fiTarget: raw.fiTarget,
                                           portfolioAtTarget: raw.portfolioAtTarget,
                                           fiPct: raw.fiPct,
                                           netWorthAtTarget: raw.netWorthAtTarget,
                                           debtFreeYearIndex: raw.debtFreeYearIndex,
                                           dpHitYearIndex: raw.dpHitYearIndex)
            let debt = DebtSimulator.simulate(accounts: accounts, monthlyBudget: budget,
                                              strategy: strategy, balanceTransfer: transfer)
            return HouseholdPlanResult(config: config, rows: rows, summary: summary,
                                       accounts: accounts, strategy: strategy,
                                       monthlyDebtBudget: budget, debt: debt)
        }.value
        guard !Task.isCancelled else { return }

        withAnimation(reduceMotion ? nil : theme.motion.spring) {
            plan = result
        }
        isRecomputing = false
    }

    // MARK: Shared bits

    private func cardLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.font(.label))
            .foregroundStyle(theme.palette.textSecondary)
            .textCase(theme.typography.labelCase)
            .tracking(theme.typography.labelTracking)
    }
}
