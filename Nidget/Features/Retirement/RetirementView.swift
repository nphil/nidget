import SwiftUI

// MARK: - RetirementConfigCodec
//
// The single encode/decode path between `RetirementConfig` and
// `Preferences.retirementConfigJSON`. Decoding tolerates an empty or corrupt string by falling
// back to the default config (ARCHITECTURE §11); encoding is deterministic (sorted keys) so the
// stored JSON string only changes when the config actually does, which keeps
// `onChange(of: retirementConfigJSON)` observers and `.task(id:)` keys honest.

enum RetirementConfigCodec {
    /// Stored JSON to config; empty or corrupt input falls back to the defaults.
    static func decode(_ json: String) -> RetirementConfig {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RetirementConfig.self, from: data) else {
            return RetirementConfig()
        }
        return decoded
    }

    /// Config to deterministic (sorted-keys) JSON for Preferences. nil only if encoding fails.
    static func encode(_ config: RetirementConfig) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(config) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - RetirementView
//
// The Retire tab root, now the ten-second glance over both engines: the household plan Retiron
// holds (hero ring, net worth chart, drill-in tiles) and the personal Monte Carlo planner (the
// reality-check row, the lever rows, the playground behind them). Everything deeper lives one
// push away: Plan Inputs behind the gear, What If behind the reality row and the levers, and
// The Plan / Debt / Places behind the tiles.
//
// State lives in the two @Observable models created here and injected through the environment,
// so every drill-in reads the same plan with no binding plumbing. Both compute pipelines run
// detached and debounced inside the models; this file only draws.
//
// When Retiron is not connected the same screen reads as a complete single-person planner:
// personal hero, projection chart, milestone tiles, spending, levers, and a doorway card to
// connect the household plan. With nothing configured at all, two doors and no dead end.

@MainActor
struct RetirementView: View {
    @Environment(AppRouter.self) private var router
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.privacyMode) private var privacyMode

    @State private var personal = PersonalPlanModel()
    @State private var household = HouseholdPlanModel()

    /// "Also switches the plan on Retiron", shown for two seconds after a scenario switch.
    @State private var showsScenarioCaption = false
    @State private var scenarioCaptionTask: Task<Void, Never>?

    // MARK: Body

    var body: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.retirePath) {
            screenContent
                .withRouteDestinations()
                .environment(personal)
                .environment(household)
        }
    }

    private var screenContent: some View {
        content
            .themedScreen()
            .navigationTitle("Retire")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.push(.planInputs)
                    } label: {
                        Image(systemName: "gearshape")
                            .symbolVariant(theme.icons.fill ? .fill : .none)
                            .fontWeight(theme.icons.weight)
                    }
                    .accessibilityLabel("Plan inputs")
                }
            }
            .refreshable {
                await household.load()
            }
            .task(id: household.isConnected) {
                await household.load()
            }
            .task(id: household.recomputeKey) {
                await household.recompute()
            }
            .task(id: personal.computeKey) {
                await personal.recompute()
            }
            .task(id: personal.savedConfig.linkedAccountIDs) {
                await personal.refreshDetectedContribution()
            }
            .task {
                await personal.refreshActualMonthlySpend()
            }
            .onChange(of: preferences.retirementConfigJSON) { _, _ in
                personal.reloadSavedConfig()
            }
    }

    // MARK: State branching (the degraded-states matrix)

    @ViewBuilder
    private var content: some View {
        if household.isConnected {
            if let plan = household.plan {
                connectedScroll(plan)
            } else if household.isLoading || household.profile != nil {
                // Either the fetch is on the wire or the cache is adopted and the first
                // projection is in flight: the plan lands in a beat.
                householdLoadingView
            } else {
                // Connected with nothing to draw: a fresh Retiron, an empty server, or one we
                // could not reach. The note goes up top and the personal strand carries on
                // below, so there is always a way forward and pull to refresh still works.
                personalStrand(showsRetironError: true)
            }
        } else {
            personalStrand(showsRetironError: false)
        }
    }

    @ViewBuilder
    private func personalStrand(showsRetironError: Bool) -> some View {
        if personal.isUnconfigured {
            if showsRetironError {
                retironErrorScroll {
                    nothingConfigured
                }
            } else {
                nothingConfigured
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let plan = personal.plan {
            personalScroll(plan, showsRetironError: showsRetironError)
        } else if showsRetironError {
            retironErrorScroll {
                personalLoadingView
                    .frame(minHeight: 220)
            }
        } else {
            personalLoadingView
        }
    }

    /// The Retiron note above whatever the personal strand has to show, in a scroll view so pull
    /// to refresh stays live while the household side is empty.
    private func retironErrorScroll<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(spacing: theme.layout.cardSpacing) {
                retironErrorCard
                content()
            }
            .padding(.horizontal, theme.layout.cardPadding)
            .padding(.top, theme.layout.spacing * 0.5)
            .padding(.bottom, theme.layout.cardSpacing)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Empty & loading

    /// Two doors, no dead end: the personal planner or the household one.
    private var nothingConfigured: some View {
        VStack(spacing: theme.layout.spacing) {
            EmptyStateView(systemImage: "chart.line.uptrend.xyaxis",
                           title: "Plan your retirement",
                           message: "Link your investment accounts and Nidget will chart the road from here to done.",
                           actionTitle: "Set Up",
                           action: { router.push(.planInputs) })
            NidgetButton("Connect Retiron instead", role: .subtle) {
                router.push(.retironSettings)
            }
            .frame(maxWidth: 280)
        }
    }

    private var personalLoadingView: some View {
        VStack(spacing: theme.layout.spacing) {
            ProgressView()
                .controlSize(.large)
                .tint(theme.palette.accent)
            Text("Simulating 1,000 market futures…")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var householdLoadingView: some View {
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

    // MARK: Connected layout

    private func connectedScroll(_ plan: HouseholdPlanResult) -> some View {
        ScrollView {
            VStack(spacing: theme.layout.cardSpacing) {
                scenarioArea
                noticeCards
                heroCard(plan)
                HouseholdNetWorthChart(rows: plan.rows, config: plan.config)
                tileGrid(plan)
                spendingTile(assumedAnnualSpend: plan.config.annualSpend)
                whatWouldHelp
                // Connected with the personal side unconfigured still has a story to tell: the
                // household facts alone are enough for the model to put the plan into words.
                if personal.canExplainPlan,
                   personal.plan != nil || !householdExplainFacts.isEmpty {
                    explainCard
                }
                footerCard
            }
            .padding(.horizontal, theme.layout.cardPadding)
            .padding(.top, theme.layout.spacing * 0.5)
            .padding(.bottom, theme.layout.cardSpacing)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Scenario row (Card 0)

    /// The chip row renders only when connected with two or more scenarios and the Menu fallback
    /// has not taken over; a single scenario shows its name in the hero header instead.
    /// `scenarioNames` is seeded from the cache, so this holds still across a reload instead of
    /// blinking with the network.
    private var showsScenarioRow: Bool {
        household.isConnected && household.scenarioNames.count > 1 && !scenarioMenuFallback
    }

    /// Too many or too long for chips: the row collapses into a Menu in the hero header.
    private var scenarioMenuFallback: Bool {
        household.scenarioNames.count > 4
            || household.scenarioNames.contains { $0.count > 16 }
    }

    private var scenarioBinding: Binding<String> {
        Binding(get: { [household] in
            household.selectedName ?? household.scenarioNames.first ?? ""
        }, set: { name in
            household.select(name)
            flashScenarioCaption()
        })
    }

    @ViewBuilder
    private var scenarioArea: some View {
        if showsScenarioRow || showsScenarioCaption {
            VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
                if showsScenarioRow {
                    ChipPicker(items: household.scenarioNames,
                               selection: scenarioBinding,
                               label: { $0 })
                        .transition(.opacity)
                }
                if showsScenarioCaption {
                    Text("Also switches the plan on Retiron")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                       value: showsScenarioCaption)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                       value: showsScenarioRow)
        }
    }

    /// The caption belongs to the chip row. Without the row it would arrive as a bare line
    /// floating above the hero, so the Menu fallback simply skips it.
    private func flashScenarioCaption() {
        guard showsScenarioRow else { return }
        scenarioCaptionTask?.cancel()
        showsScenarioCaption = true
        scenarioCaptionTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            showsScenarioCaption = false
        }
    }

    private var scenarioMenu: some View {
        Menu {
            ForEach(household.scenarioNames, id: \.self) { name in
                Button {
                    household.select(name)
                    flashScenarioCaption()
                } label: {
                    if name == household.selectedName {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(household.selectedName ?? "Scenario")
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.accent)
                    .lineLimit(1)
                Image(systemName: "chevron.down.circle")
                    .font(theme.font(.caption))
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.accent)
            }
        }
        .accessibilityLabel("Switch scenario")
    }

    // MARK: Notice cards (Card 0b)

    /// Both notices read `syncState`, the same enum the hero spinner and the footer read, so no
    /// two surfaces can ever disagree about what Retiron is doing.
    @ViewBuilder
    private var noticeCards: some View {
        switch household.syncState {
        case .cached(let loadError):
            if let loadError {
                noticeCard("Retiron isn't answering", loadError)
            }
        case .localEdits(let saveError):
            noticeCard("Saved on this phone only", saveError)
        case .notConnected, .syncing, .live:
            EmptyView()
        }
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

    /// The reason Retiron has nothing to show, when it gave one. `.cached(loadError: nil)` is the
    /// ordinary "connected, nothing back yet" case, and the card reads fine without a detail line.
    private var cachedLoadError: String? {
        if case .cached(let loadError) = household.syncState { return loadError }
        return nil
    }

    /// The compact hero-slot note for the connected-but-nothing-to-show state. It covers both a
    /// Retiron we could not reach and a Retiron with no scenario saved yet, so the headline says
    /// which one it is and the detail line appears only when there was an error to quote.
    private var retironErrorCard: some View {
        let detail = cachedLoadError
        return HStack(alignment: .top, spacing: theme.layout.spacing * 0.75) {
            Image(systemName: detail == nil ? "house" : "antenna.radiowaves.left.and.right.slash")
                .font(theme.font(.title))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.palette.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(detail == nil ? "No household plan on Retiron yet."
                                   : "Could not reach Retiron.")
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                if let detail {
                    Text(detail)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: theme.layout.spacing)
            Button("Retry") {
                Task { await household.load() }
            }
            .font(theme.font(.headline))
            .foregroundStyle(theme.palette.accent)
        }
        .themedCard()
    }

    // MARK: Hero (Card 1, connected)

    private func heroCard(_ plan: HouseholdPlanResult) -> some View {
        let summary = plan.summary
        return VStack(alignment: .leading, spacing: theme.layout.spacing) {
            SectionHeader("Retirement", trailing: heroTrailing)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: theme.layout.spacing) {
                    heroGauge(summary)
                    heroText(plan)
                }
            } else {
                HStack(alignment: .center, spacing: theme.layout.spacing) {
                    heroGauge(summary)
                    heroText(plan)
                }
            }
            realityFooter
        }
        .themedCard()
    }

    /// One slot, one owner. Identity wins over activity: the Menu or the scenario name stays put
    /// and the spinner tucks in beside it, so the control never vanishes mid switch. The bare
    /// spinner is only for when there is no name to show yet.
    private var heroTrailing: (() -> AnyView)? {
        if scenarioMenuFallback, household.scenarioNames.count > 1 {
            return { AnyView(HStack(spacing: 6) {
                scenarioMenu
                syncingDot
            }) }
        }
        if household.scenarioNames.count <= 1, let name = household.selectedName {
            return { AnyView(HStack(spacing: 6) {
                Text(name)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                    .lineLimit(1)
                syncingDot
            }) }
        }
        if household.isSyncing {
            return { AnyView(ProgressView().controlSize(.small).tint(theme.palette.accent)) }
        }
        return nil
    }

    /// The small inline spinner that rides beside the scenario identity while a sync is running.
    @ViewBuilder
    private var syncingDot: some View {
        if household.isSyncing {
            ProgressView()
                .controlSize(.small)
                .tint(theme.palette.accent)
                .accessibilityLabel("Syncing")
        }
    }

    private func heroGauge(_ summary: HouseholdSummary) -> some View {
        // fiPct is a percent; GaugeArc wants a 0...1 fraction and clamps there, while the label
        // keeps the true percent so a plan past its goal reads as surplus (142% on a full ring).
        GaugeArc(progress: summary.fiPct / 100,
                 label: Self.percentText(summary.fiPct),
                 detail: "of goal")
            .frame(width: 120, height: 120)
    }

    private func heroText(_ plan: HouseholdPlanResult) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
            Text(heroHeadline(plan))
                .font(theme.font(.headline))
                .foregroundStyle(theme.palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let subline = heroSubline(plan) {
                Text(subline)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: theme.layout.spacing) {
                heroStat("Saved by then", Money(clampedDollars: plan.summary.portfolioAtTarget))
                heroStat("The goal", Money(clampedDollars: plan.summary.fiTarget))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heroStat(_ label: String, _ amount: Money) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
            AmountText(amount, style: .title, colorized: false)
                .minimumScaleFactor(0.6)
        }
    }

    /// Data-driven headline: the first projected year the portfolio crosses the FI target.
    private func heroHeadline(_ plan: HouseholdPlanResult) -> String {
        let summary = plan.summary
        let targetAge = plan.config.targetRetirementAge
        if summary.fiTarget > 0,
           let crossing = plan.rows.first(where: { $0.liquidPortfolio >= summary.fiTarget }) {
            if crossing.ageA < targetAge {
                return "Work turns optional around age \(crossing.ageA)."
            }
            return "The plan reaches the goal at \(crossing.ageA)."
        }
        return "The plan gets you \(Self.percentText(summary.fiPct)) of the way by \(targetAge)."
    }

    /// "Next up" is the first life event still ahead of this year; a plan with none stays quiet.
    private func heroSubline(_ plan: HouseholdPlanResult) -> String? {
        guard let next = plan.rows.first(where: { $0.yearIndex > 0 && !$0.events.isEmpty }),
              let event = next.events.first else { return nil }
        // Engine events are proper nouns ("Isabel full time", "HSA restarts"), so they keep the
        // capitalisation Retiron gave them.
        return "Next up: \(event) in \(next.calendarYear)."
    }

    /// The personal engine's voice inside the household hero: real balances against a thousand
    /// simulated markets, one tap from the playground behind the numbers.
    private var realityFooter: some View {
        Button {
            Haptics.tick()
            router.push(personal.isUnconfigured ? .planInputs : .retireWhatIf)
        } label: {
            HStack(spacing: theme.layout.spacing * 0.5) {
                if personal.draftDiffers, !personal.isUnconfigured {
                    TryingPill()
                }
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(theme.font(.body))
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.accent)
                    .accessibilityHidden(true)
                realityText
                Spacer(minLength: theme.layout.spacing * 0.5)
                if !personal.isUnconfigured, personal.plan == nil {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.palette.accent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(theme.font(.caption))
                        .fontWeight(theme.icons.weight)
                        .foregroundStyle(theme.palette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Checked against your real balances. Opens the What If playground.")
    }

    @ViewBuilder
    private var realityText: some View {
        if personal.isUnconfigured {
            Text("Link your accounts to check this plan against real balances")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let plan = personal.plan {
            // The amount rides inside flowing copy, where AmountText cannot go, so privacy mode
            // is substituted by hand and the row is marked sensitive.
            let invested = privacyMode ? "••••"
                : CurrencyFormatter.string(plan.snapshot.invested, format: .compact)
            let funded = Self.clampedPercentCount(plan.snapshot.successProbability)
            Text("Reality check: \(invested) invested today, \(funded) of 100 simulated futures stay funded.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .privacySensitive()
        } else {
            Text("Checking against 1,000 market futures")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
        }
    }

    // MARK: Tile grid (Card 3)

    private func tileGrid(_ plan: HouseholdPlanResult) -> some View {
        let spacing = theme.layout.cardSpacing * 0.75
        return VStack(spacing: spacing) {
            HStack(alignment: .top, spacing: spacing) {
                planTile(plan)
                debtTile(plan)
            }
            HStack(alignment: .top, spacing: spacing) {
                downPaymentTile(plan)
                placesTile
            }
        }
    }

    private func planTile(_ plan: HouseholdPlanResult) -> some View {
        let value: String
        if let next = plan.rows.first(where: { $0.yearIndex > 0 && !$0.events.isEmpty }),
           let event = next.events.first {
            value = "\(event) in \(next.calendarYear)"
        } else {
            value = "Steady until \(plan.config.targetRetirementAge)"
        }
        return RetireTile("The Plan", value: value, caption: "Year by year") {
            router.push(.retireYears)
        }
    }

    private func debtTile(_ plan: HouseholdPlanResult) -> some View {
        let totalOwed = plan.accounts.reduce(0.0) { $0 + max($1.balance, 0) }
        let isClear = plan.accounts.isEmpty || totalOwed <= 0
        return RetireTile("Debt", value: debtTileValue(plan, isClear: isClear), action: {
            router.push(.retireDebt)
        }) {
            if isClear {
                RetireTileCaption("Nothing owed")
            } else if let promo = promoWarning(plan) {
                Text(promo)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.warning)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            } else {
                HStack(spacing: 4) {
                    AmountText(Money(clampedDollars: totalOwed), style: .caption, colorized: false)
                    Text("still owed")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
        }
    }

    private func debtTileValue(_ plan: HouseholdPlanResult, isClear: Bool) -> String {
        if isClear { return "All clear" }
        guard plan.debt.payoffMonths < DebtSimulator.maxMonths - 1,
              let last = plan.debt.schedule.last else {
            return "Over \(DebtSimulator.maxMonths / 12) years"
        }
        return "Free by \(last.date.formatted(.dateTime.month(.abbreviated).year()))"
    }

    /// "0% on Visa ends in May": the promo rate closest to running out inside six months.
    private func promoWarning(_ plan: HouseholdPlanResult) -> String? {
        guard let soonest = plan.accounts
            .filter({ $0.promoEndMonth > 0 && $0.promoEndMonth <= 6 && $0.balance > 0 })
            .min(by: { $0.promoEndMonth < $1.promoEndMonth }) else { return nil }
        guard let endDate = Calendar.current.date(byAdding: .month,
                                                  value: soonest.promoEndMonth,
                                                  to: Date()) else { return nil }
        let month = endDate.formatted(.dateTime.month(.wide))
        return "0% on \(soonest.name) ends in \(month)"
    }

    private func downPaymentTile(_ plan: HouseholdPlanResult) -> some View {
        let now = plan.rows.first
        let saved = now?.dpSaved ?? 0
        let target = now?.dpTarget ?? 0
        let fraction = target > 0 ? min(max(saved / target, 0), 1) : 0
        return RetireTile("Down payment",
                          value: "\(Self.percentText(fraction * 100)) saved",
                          action: {
            household.pendingYearsAnchor = .downPayment
            router.push(.retireYears)
        }) {
            HStack(spacing: 4) {
                AmountText(Money(clampedDollars: saved), style: .caption, colorized: false)
                Text("of")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                AmountText(Money(clampedDollars: target), style: .caption, colorized: false)
            }
        }
    }

    private var placesTile: some View {
        let best = household.runways.max { $0.runway.runwayYears < $1.runway.runwayYears }
        let value: String
        if let best, best.runway.runwayYears > 0 {
            if best.runway.runwayYears >= DestinationMath.maxRunwayYears {
                value = "\(best.destination.name), \(Self.wholeYears(DestinationMath.maxRunwayYears))+ yrs"
            } else {
                value = "\(best.destination.name), \(Self.wholeYears(best.runway.runwayYears)) yrs"
            }
        } else {
            value = "Not yet"
        }
        let count = household.runways.count
        let caption = count > 0 ? "\(count) places priced" : "Priced from the plan"
        return RetireTile("Places", value: value, caption: caption) {
            router.push(.retirePlaces)
        }
    }

    /// The full-width daily-money tile. `assumedAnnualSpend` is the household plan's spending
    /// assumption when connected, nil otherwise; the honest blend sentence appears only when it
    /// and reality diverge by more than 15 percent.
    private func spendingTile(assumedAnnualSpend: Double?) -> some View {
        let value: String
        if let actual = personal.actualMonthlySpend, actual.cents > 0 {
            let spend = privacyMode ? "••••" : CurrencyFormatter.string(actual, format: .whole)
            value = "Spending \(spend) a month"
        } else {
            value = "Adding it up"
        }
        return RetireTile("Spending", value: value, action: {
            router.push(.retireWhatIf)
        }) {
            RetireTileCaption(spendingCaption(assumedAnnualSpend: assumedAnnualSpend))
        }
    }

    private func spendingCaption(assumedAnnualSpend: Double?) -> String {
        if let assumedAnnual = assumedAnnualSpend, assumedAnnual > 0,
           let actual = personal.actualMonthlySpend, actual.cents > 0 {
            let assumedMonthly = Money(clampedDollars: assumedAnnual / 12)
            if assumedMonthly.cents > 0 {
                let gap = abs(assumedMonthly.doubleValue - actual.doubleValue)
                    / assumedMonthly.doubleValue
                if gap > 0.15 {
                    let assumed = privacyMode ? "••••"
                        : CurrencyFormatter.string(assumedMonthly, format: .whole)
                    let spending = privacyMode ? "••••"
                        : CurrencyFormatter.string(actual, format: .whole)
                    return "The household plan assumes \(assumed) a month. You actually spend \(spending)."
                }
            }
        }
        let retirementMonthly: Money?
        if let plan = personal.plan {
            retirementMonthly = Money(cents: plan.snapshot.annualSpending.cents / 12)
        } else if let assumedAnnual = assumedAnnualSpend, assumedAnnual > 0 {
            retirementMonthly = Money(clampedDollars: assumedAnnual / 12)
        } else {
            retirementMonthly = nil
        }
        guard let retirementMonthly else { return "Your money, month by month." }
        let amount = privacyMode ? "••••"
            : CurrencyFormatter.string(retirementMonthly, format: .whole)
        return "In retirement: \(amount) a month."
    }

    // MARK: What would help (Card 4)

    @ViewBuilder
    private var whatWouldHelp: some View {
        if personal.isUnconfigured {
            inviteRow(icon: "slider.horizontal.3",
                      text: "Link accounts to try what-ifs") {
                router.push(.planInputs)
            }
        } else if let outcomes = personal.leverOutcomes {
            RetirementLeversCard(outcomes: outcomes,
                                 showsTryingPill: personal.draftDiffers,
                                 onSaveMore: {
                                     personal.applySaveMoreLever()
                                     router.push(.retireWhatIf)
                                 },
                                 onSpendLess: {
                                     personal.applySpendLessLever()
                                     router.push(.retireWhatIf)
                                 },
                                 onEarnMore: {
                                     personal.applyEarnMoreLever()
                                     router.push(.retireWhatIf)
                                 },
                                 onOpen: {
                                     router.push(.retireWhatIf)
                                 })
        }
    }

    private func inviteRow(icon: String, text: String,
                           action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            HStack(spacing: theme.layout.spacing * 0.75) {
                Image(systemName: icon)
                    .font(theme.font(.title))
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.accent)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                Text(text)
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: theme.layout.spacing * 0.5)
                Image(systemName: "chevron.right")
                    .font(theme.font(.caption))
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedCard()
    }

    // MARK: In plain words (Card 5)

    private var explainCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            SectionHeader("In plain words")
            if let planSummary = personal.planSummary {
                Text(planSummary)
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .privacySensitive()
                    .blur(radius: privacyMode ? 6 : 0)
                Button {
                    personal.explain(extraFacts: householdExplainFacts)
                } label: {
                    Text("Explain again")
                        .font(theme.font(.caption))
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.palette.accent)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if personal.isExplaining {
                HStack(spacing: theme.layout.spacing * 0.5) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.palette.accent)
                    Text("Putting your plan into words…")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                }
                .frame(minHeight: 32)
            } else {
                NidgetButton("Explain my plan", systemImage: "sparkles", role: .secondary) {
                    personal.explain(extraFacts: householdExplainFacts)
                }
                Text("A few plain sentences from the on-device model. Nothing leaves your phone.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .themedCard()
        .animation(reduceMotion ? nil : theme.motion.spring,
                   value: personal.planSummary == nil)
    }

    /// When connected, the narrative gets the merged picture: household FI percent at the
    /// target age and the debt-free year.
    private var householdExplainFacts: [String] {
        guard household.isConnected, let plan = household.plan else { return [] }
        var facts = ["The shared household plan reaches \(Self.percentText(plan.summary.fiPct)) of its goal at age \(plan.config.targetRetirementAge)"]
        if let index = plan.summary.debtFreeYearIndex {
            facts.append("The household debt is cleared in \(plan.config.baseYear + index)")
        }
        return facts
    }

    // MARK: Footer plumbing card (Card 6)

    /// The quiet, stable home for sync state, always the last card. Every string derives from
    /// `household.syncState`, the same enum the hero spinner reads.
    @ViewBuilder
    private var footerCard: some View {
        switch household.syncState {
        case .notConnected:
            planTogetherCard
        case .syncing:
            footerRow(text: "Syncing with Retiron.", buttonTitle: nil, action: nil)
        case .live(let updated):
            footerRow(text: "Synced with Retiron. Scenario: \(household.selectedName ?? "Your plan"). Updated \(updated.formatted(.relative(presentation: .named))).",
                      buttonTitle: "Settings") {
                router.push(.retironSettings)
            }
        case .cached:
            footerRow(text: "Showing your last synced plan.", buttonTitle: "Retry") {
                Task { await household.load() }
            }
        case .localEdits:
            // Retrying the save, not the load: loading here would adopt the server copy and take
            // the unsent edit with it.
            footerRow(text: "Changes saved on this phone. Retiron has not caught up.",
                      buttonTitle: "Retry") {
                household.retrySave()
            }
        }
    }

    private func footerRow(text: String, buttonTitle: String?,
                           action: (() -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.layout.spacing) {
            Text(text)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: theme.layout.spacing * 0.5)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.accent)
            }
        }
        .themedCard()
    }

    /// Not connected: the footer becomes the doorway to the household plan.
    private var planTogetherCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            SectionHeader("Plan together")
            Text("Connect your Retiron server to plan with both incomes, both houses, and the debt.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NidgetButton("Connect Retiron", role: .secondary) {
                router.push(.retironSettings)
            }
        }
        .themedCard()
    }

    // MARK: Not-connected layout (the personal strand)

    private func personalScroll(_ plan: PersonalPlanResult,
                                showsRetironError: Bool) -> some View {
        ScrollView {
            VStack(spacing: theme.layout.cardSpacing) {
                if showsRetironError {
                    retironErrorCard
                }
                personalHero(plan)
                RetirementChartCard(snapshot: plan.snapshot,
                                    config: plan.config,
                                    isRecomputing: personal.isRecomputing)
                milestonesDoorway(plan)
                if !household.isConnected {
                    householdInviteRow
                }
                spendingTile(assumedAnnualSpend: nil)
                whatWouldHelp
                if personal.canExplainPlan {
                    explainCard
                }
                if !household.isConnected {
                    footerCard
                }
            }
            .padding(.horizontal, theme.layout.cardPadding)
            .padding(.top, theme.layout.spacing * 0.5)
            .padding(.bottom, theme.layout.cardSpacing)
        }
        .scrollIndicators(.hidden)
    }

    /// Today's personal hero, kept whole: projected-age headline, progress ring on the FI
    /// fraction, and the invested / enough-to-retire stat pair.
    private func personalHero(_ plan: PersonalPlanResult) -> some View {
        let headline = personalHeroHeadline(plan)
        return VStack(alignment: .leading, spacing: theme.layout.spacing) {
            SectionHeader("Retirement", trailing: tryingPillTrailing)
            Text(headline)
                .font(theme.font(.display))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : theme.motion.snappy, value: headline)
            Text(personalHeroSubline(plan))
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: theme.layout.spacing) {
                GaugeArc(progress: plan.snapshot.progress,
                         label: Self.progressText(plan.snapshot.progress),
                         detail: plan.snapshot.progress >= 1 ? "past your number" : "to FI")
                    .frame(width: 120, height: 120)
                Spacer(minLength: theme.layout.spacing)
                VStack(alignment: .trailing, spacing: theme.layout.spacing * 0.75) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Invested")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textTertiary)
                        AmountText(plan.snapshot.invested, style: .title, colorized: false)
                            .minimumScaleFactor(0.6)
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Enough to retire")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textTertiary)
                        AmountText(plan.snapshot.fiNumber, style: .title, colorized: false)
                            .minimumScaleFactor(0.6)
                    }
                }
            }
        }
        .themedCard()
    }

    private func personalHeroHeadline(_ plan: PersonalPlanResult) -> String {
        guard let projected = plan.snapshot.projectedRetireAge else { return "Not yet in reach" }
        if projected <= Double(plan.config.currentAge) + 0.01 { return "You could retire now" }
        return "Retirement at ~\(clampedAge(projected))"
    }

    private func personalHeroSubline(_ plan: PersonalPlanResult) -> String {
        guard let projected = plan.snapshot.projectedRetireAge else {
            return "On these numbers your savings never quite get there. The levers below show what would help."
        }
        let years = projected - Double(plan.config.currentAge)
        if years <= 0.01 { return "Your savings already cover your retirement spending." }
        if years < 1 { return "Less than a year to go." }
        if years < 2 { return "About \(max(clampedAge(years * 12), 1)) months to go." }
        return "About \(clampedAge(years)) years to go."
    }

    /// The two milestone cards, one tap target: both open the playground where the sliders that
    /// move them live.
    private func milestonesDoorway(_ plan: PersonalPlanResult) -> some View {
        Button {
            Haptics.tick()
            router.push(.retireWhatIf)
        } label: {
            RetirementMilestonesRow(snapshot: plan.snapshot,
                                    retireAge: plan.config.retireAge,
                                    currentAge: plan.config.currentAge)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the What If playground")
    }

    private var tryingPillTrailing: (() -> AnyView)? {
        guard personal.draftDiffers else { return nil }
        return { AnyView(TryingPill()) }
    }

    /// The wide doorway on the not-connected glance: what connecting Retiron buys.
    private var householdInviteRow: some View {
        inviteRow(icon: "house.and.flag",
                  text: "The household plan: both incomes, both houses, one screen.") {
            router.push(.retironSettings)
        }
    }

    // MARK: Number helpers

    /// True percent, clamped to something printable; the ring itself clamps separately.
    private static func percentText(_ value: Double) -> String {
        let safe = value.isFinite ? min(max(value, 0), 999) : 0
        return (safe / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// The personal ring label: a 0...1 fraction shown as its true percent.
    private static func progressText(_ progress: Double) -> String {
        let safe = progress.isFinite ? max(progress, 0) : 0
        return min(safe, 9.99).formatted(.percent.precision(.fractionLength(0)))
    }

    /// Success probability (0...1) as "N of 100" futures.
    private static func clampedPercentCount(_ probability: Double) -> Int {
        guard probability.isFinite else { return 0 }
        return Int(min(max((probability * 100).rounded(), 0), 100))
    }

    private static func wholeYears(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value.rounded(), 0), 999))
    }
}
