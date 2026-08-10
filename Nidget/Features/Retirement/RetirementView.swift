import SwiftUI
import Charts

// MARK: - RetirementConfigCodec
//
// The single encode/decode path between `RetirementConfig` and
// `Preferences.retirementConfigJSON`. Decoding tolerates an empty or corrupt string by falling
// back to the default config (ARCHITECTURE §11); encoding is deterministic (sorted keys) so the
// stored JSON string only changes when the config actually does — which keeps
// `onChange(of: retirementConfigJSON)` observers and `.task(id:)` keys honest.

enum RetirementConfigCodec {
    /// Stored JSON → config; empty/corrupt input falls back to the defaults.
    static func decode(_ json: String) -> RetirementConfig {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RetirementConfig.self, from: data) else {
            return RetirementConfig()
        }
        return decoded
    }

    /// Config → deterministic (sorted-keys) JSON for Preferences. nil only if encoding fails.
    static func encode(_ config: RetirementConfig) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(config) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - RetirementView
//
// The Retire tab root (ARCHITECTURE §14): FI progress hero (GaugeArc + invested vs FI number),
// a Monte Carlo projection chart (percentile bands + deterministic line + FI/retire-age rules),
// a success-probability stat, a coast-FIRE callout, and live "what if" sliders.
//
// Data flow: the SAVED config comes from `Preferences.retirementConfigJSON`; the sliders edit a
// DRAFT (retire age / monthly contribution / expected return) layered on top of it. Any change
// to the draft, the saved config, or account balances re-runs `RetirementPlanner.snapshot`
// (1,000 Monte Carlo runs) on a detached task — debounced 250 ms once a first plan exists
// (LESSONS_FROM_STASHY §1: debounce query changes; dedupe with cancellation guards so a stale
// task never clobbers a newer result). "Save these assumptions" persists the draft back to
// Preferences, whose change reseeds the draft — making draft == saved and hiding the button.

@MainActor
struct RetirementView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.privacyMode) private var privacyMode

    /// Decoded mirror of `Preferences.retirementConfigJSON`, kept current via onChange.
    @State private var savedConfig: RetirementConfig
    /// What-if draft values (only the three slider-editable fields).
    @State private var draftRetireAge: Double
    @State private var draftContribution: Double   // whole currency units per month
    @State private var draftReturn: Double
    /// True while a finger is on any what-if slider — gates the per-detent tick haptic so
    /// programmatic reseeds stay silent.
    @State private var isAdjustingSlider = false

    @State private var plan: PlanResult?
    @State private var isRecomputing = false
    @State private var lastComputedKey: ComputeKey?

    init() {
        let config = RetirementConfigCodec.decode(Preferences.shared.retirementConfigJSON)
        _savedConfig = State(initialValue: config)
        _draftRetireAge = State(initialValue: Double(config.retireAge))
        _draftContribution = State(initialValue: max(Double(config.monthlyContribution.cents) / 100.0, 0))
        _draftReturn = State(initialValue: config.expectedReturnPct)
    }

    // MARK: Derived state

    /// The planner result plus the exact config it was computed with, so chart adornments
    /// (retire-age rule) always agree with the plotted data even mid-debounce.
    private struct PlanResult {
        var snapshot: RetirementSnapshot
        var config: RetirementConfig
    }

    /// Everything a recompute depends on; used as the `.task(id:)` key.
    private struct ComputeKey: Equatable {
        var configJSON: String
        var accounts: [Account]
        var retireAge: Double
        var contribution: Double
        var expectedReturn: Double
    }

    private var computeKey: ComputeKey {
        ComputeKey(configJSON: preferences.retirementConfigJSON,
                   accounts: store.accounts,
                   retireAge: draftRetireAge,
                   contribution: draftContribution,
                   expectedReturn: draftReturn)
    }

    /// Saved config with the what-if draft layered on top — what the planner actually runs.
    private var draftConfig: RetirementConfig {
        var config = savedConfig
        config.retireAge = Self.clampedInt(draftRetireAge, min: 0, max: 150)
        config.monthlyContribution = Self.money(fromDollars: draftContribution)
        config.expectedReturnPct = draftReturn
        return config
    }

    private var draftDiffers: Bool {
        let draft = draftConfig
        return draft.retireAge != savedConfig.retireAge
            || draft.monthlyContribution != savedConfig.monthlyContribution
            || abs(draft.expectedReturnPct - savedConfig.expectedReturnPct) > 0.0001
    }

    /// Nothing to plan with: no linked accounts AND no outside assets.
    private var isUnconfigured: Bool {
        savedConfig.linkedAccountIDs.isEmpty && savedConfig.extraAssets == .zero
    }

    // MARK: Body

    var body: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.retirePath) {
            screenContent
                .withRouteDestinations()
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
                        router.push(.retirementAssumptions)
                    } label: {
                        Image(systemName: "gearshape")
                            .symbolVariant(theme.icons.fill ? .fill : .none)
                            .fontWeight(theme.icons.weight)
                    }
                    .accessibilityLabel("Retirement assumptions")
                }
            }
            .onChange(of: preferences.retirementConfigJSON) { _, newValue in
                let config = RetirementConfigCodec.decode(newValue)
                savedConfig = config
                seedDrafts(from: config)
            }
            .task(id: computeKey) {
                await recompute()
            }
    }

    @ViewBuilder
    private var content: some View {
        if isUnconfigured {
            emptyState
        } else if let plan {
            planScroll(plan)
        } else {
            loadingView
        }
    }

    // MARK: Empty & loading

    private var emptyState: some View {
        EmptyStateView(systemImage: "chart.line.uptrend.xyaxis",
                       title: "Link your investment accounts",
                       message: "Tell Nidget which accounts hold your future — or add outside assets — and it'll chart your road to financial independence.",
                       actionTitle: "Set Up Retirement",
                       action: { router.push(.retirementAssumptions) })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
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

    // MARK: Plan layout

    private func planScroll(_ plan: PlanResult) -> some View {
        ScrollView {
            VStack(spacing: theme.layout.cardSpacing) {
                heroCard(plan)
                projectionCard(plan)
                successCard(plan)
                if let coastAge = plan.snapshot.coastFIREAge {
                    coastCard(coastAge: coastAge, retireAge: plan.config.retireAge)
                }
                whatIfCard
            }
            .padding(.horizontal, theme.layout.cardPadding)
            .padding(.top, theme.layout.spacing * 0.5)
            .padding(.bottom, theme.layout.cardSpacing)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Hero card

    private func heroCard(_ plan: PlanResult) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            cardLabel("Financial Independence")
            GaugeArc(progress: plan.snapshot.progress,
                     label: progressText(plan.snapshot.progress),
                     detail: "to FI")
                .frame(width: 190, height: 190)
                .frame(maxWidth: .infinity)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    cardLabel("Invested")
                    AmountText(plan.snapshot.invested, style: .display, colorized: false)
                }
                Spacer(minLength: theme.layout.spacing)
                VStack(alignment: .trailing, spacing: 2) {
                    cardLabel("FI Number")
                    AmountText(plan.snapshot.fiNumber, style: .display, colorized: false)
                }
            }
        }
        .themedCard()
    }

    private func progressText(_ progress: Double) -> String {
        let safe = progress.isFinite ? max(progress, 0) : 0
        return min(safe, 9.99).formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: Projection card

    private func projectionCard(_ plan: PlanResult) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            HStack {
                cardLabel("Projection")
                Spacer(minLength: theme.layout.spacing)
                if isRecomputing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.palette.accent)
                }
            }
            if plan.snapshot.deterministic.count > 1 {
                projectionChart(plan)
                Text(projectionCaption(plan))
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Not enough years between now and life expectancy to draw a projection — check your ages in the assumptions.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .themedCard()
    }

    private func projectionCaption(_ plan: PlanResult) -> String {
        if let projected = plan.snapshot.projectedRetireAge {
            let age = Self.clampedInt(projected, min: 0, max: 150)
            return "Steady growth reaches your FI number around age \(age). Bands span the middle 50% and 80% of simulations."
        }
        return "Steady growth doesn't reach your FI number within this plan. Bands span the middle 50% and 80% of simulations."
    }

    /// One vertical slice of a Monte Carlo percentile band.
    private struct BandPoint: Identifiable {
        var year: Int
        var low: Double
        var high: Double
        var id: Int { year }
    }

    private static func bandPoints(years: [Int], low: [Money], high: [Money]) -> [BandPoint] {
        let count = min(years.count, min(low.count, high.count))
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            BandPoint(year: years[index], low: low[index].doubleValue, high: high[index].doubleValue)
        }
    }

    private func projectionChart(_ plan: PlanResult) -> some View {
        let snapshot = plan.snapshot
        let outer = Self.bandPoints(years: snapshot.percentileBands.years,
                                    low: snapshot.percentileBands.p10,
                                    high: snapshot.percentileBands.p90)
        let inner = Self.bandPoints(years: snapshot.percentileBands.years,
                                    low: snapshot.percentileBands.p25,
                                    high: snapshot.percentileBands.p75)
        let fiValue = snapshot.fiNumber.doubleValue
        let dataMax = max(outer.map(\.high).max() ?? 0,
                          snapshot.deterministic.map { $0.value.doubleValue }.max() ?? 0)
        // A degenerate FI number (e.g. a 0% withdrawal rate caps it at $10T) would flatten the
        // whole chart if the y-scale stretched to include it — only draw the rule when it's in
        // the same neighborhood as the data.
        let fiVisible = fiValue > 0 && fiValue <= max(dataMax, 1) * 2
        let yMax = max(max(dataMax, fiVisible ? fiValue : 0) * 1.08, 1)
        let retirePoint = snapshot.deterministic.first { $0.age >= Double(plan.config.retireAge) }
        let interpolation: InterpolationMethod = theme.chart.smoothLines ? .catmullRom : .linear

        return Chart {
            ForEach(outer) { point in
                AreaMark(x: .value("Year", point.year),
                         yStart: .value("10th percentile", point.low),
                         yEnd: .value("90th percentile", point.high))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(theme.palette.accent.opacity(0.12))
            }
            ForEach(inner) { point in
                AreaMark(x: .value("Year", point.year),
                         yStart: .value("25th percentile", point.low),
                         yEnd: .value("75th percentile", point.high))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(theme.palette.accent.opacity(0.25))
            }
            ForEach(snapshot.deterministic) { point in
                LineMark(x: .value("Year", point.year),
                         y: .value("Projected", point.value.doubleValue))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(theme.palette.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            if fiVisible {
                RuleMark(y: .value("FI Number", fiValue))
                    .foregroundStyle(theme.palette.positive)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("FI")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.positive)
                    }
            }
            if let retirePoint {
                RuleMark(x: .value("Retire", retirePoint.year))
                    .foregroundStyle(theme.palette.textTertiary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Text("Age \(plan.config.retireAge)")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textSecondary)
                    }
            }
        }
        .chartYScale(domain: 0...yMax)
        .chartXAxis {
            AxisMarks { value in
                if theme.chart.gridLines { AxisGridLine() }
                AxisValueLabel {
                    if let year = value.as(Int.self) {
                        Text(String(year))
                    }
                }
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                if theme.chart.gridLines { AxisGridLine() }
                AxisValueLabel {
                    if let dollars = value.as(Double.self) {
                        Text(Self.compactMoney(dollars))
                    }
                }
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .frame(height: 240)
        .privacySensitive()
        .blur(radius: privacyMode ? 8 : 0)
        .accessibilityHidden(true)
    }

    // MARK: Success card

    private func successCard(_ plan: PlanResult) -> some View {
        let probability = plan.snapshot.successProbability
        let percentText = probability.formatted(.percent.precision(.fractionLength(0)))
        return VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
            cardLabel("Chance of Success")
            Text(percentText)
                .font(theme.font(.display))
                .foregroundStyle(successColor(probability))
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : theme.motion.snappy, value: percentText)
            Text(successInterpretation(probability))
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Across 1,000 simulated market histories.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .themedCard()
        .accessibilityElement(children: .combine)
    }

    private func successColor(_ probability: Double) -> Color {
        if probability >= 0.85 { return theme.palette.positive }
        if probability >= 0.60 { return theme.palette.warning }
        return theme.palette.negative
    }

    private func successInterpretation(_ probability: Double) -> String {
        if probability >= 0.85 {
            return "Your money outlives you in nearly every simulated future."
        }
        if probability >= 0.60 {
            return "Decent odds, but a rough market decade could knock this plan off course."
        }
        return "Most simulated futures run dry — more savings or a later retirement would help."
    }

    // MARK: Coast-FIRE card

    private func coastCard(coastAge: Double, retireAge: Int) -> some View {
        HStack(spacing: theme.layout.spacing) {
            Image(systemName: "sailboat")
                .font(theme.font(.title))
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .fontWeight(theme.icons.weight)
                .foregroundStyle(theme.palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Coast FIRE is in reach")
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Coasting from age \(Self.ageText(coastAge)) reaches FI by \(retireAge) — growth alone carries you the rest of the way.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .themedCard()
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    private static func ageText(_ age: Double) -> String {
        let safe = age.isFinite ? age : 0
        return safe.formatted(.number.precision(.fractionLength(0...1)))
    }

    // MARK: What-if card

    private var whatIfCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            cardLabel("What If…")
            sliderRow(title: "Retire at",
                      accessibilityLabel: "Retirement age",
                      value: $draftRetireAge, range: 40...75, step: 1) {
                Text("\(Self.clampedInt(draftRetireAge, min: 0, max: 150))")
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: draftRetireAge)
            }
            sliderRow(title: "Monthly contribution",
                      accessibilityLabel: "Monthly contribution",
                      value: $draftContribution, range: 0...10_000, step: 100) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    AmountText(Self.money(fromDollars: draftContribution), style: .body, colorized: false)
                    Text("/mo")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            sliderRow(title: "Expected return",
                      accessibilityLabel: "Expected annual return",
                      value: $draftReturn, range: 3...12, step: 0.5) {
                Text(Self.percentText(draftReturn))
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: draftReturn)
            }
            if draftDiffers {
                NidgetButton("Save these assumptions", systemImage: "checkmark") {
                    saveDraft()
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .themedCard()
        .animation(reduceMotion ? nil : theme.motion.spring, value: draftDiffers)
        .onChange(of: draftRetireAge) { _, _ in sliderTick() }
        .onChange(of: draftContribution) { _, _ in sliderTick() }
        .onChange(of: draftReturn) { _, _ in sliderTick() }
    }

    private func sliderRow<ValueLabel: View>(
        title: String,
        accessibilityLabel: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        @ViewBuilder valueLabel: () -> ValueLabel
    ) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer(minLength: theme.layout.spacing)
                valueLabel()
            }
            Slider(value: value, in: range, step: step,
                   onEditingChanged: { editing in isAdjustingSlider = editing })
                .tint(theme.palette.accent)
                .accessibilityLabel(accessibilityLabel)
        }
        .frame(minHeight: 44)
    }

    /// Detent tick per discrete slider step — only while a finger is actually on a slider, so
    /// programmatic reseeds (launch, post-save) stay silent.
    private func sliderTick() {
        if isAdjustingSlider { Haptics.tick() }
    }

    // MARK: Draft persistence

    private func seedDrafts(from config: RetirementConfig) {
        draftRetireAge = Double(config.retireAge)
        draftContribution = max(Double(config.monthlyContribution.cents) / 100.0, 0)
        draftReturn = config.expectedReturnPct
    }

    private func saveDraft() {
        guard let json = RetirementConfigCodec.encode(draftConfig) else {
            Haptics.warning()
            return
        }
        preferences.retirementConfigJSON = json
        Haptics.success()
    }

    // MARK: Recompute

    private func recompute() async {
        guard !isUnconfigured else { return }
        let key = computeKey
        // Reappearing with an up-to-date plan (tab switch) shouldn't burn another simulation.
        if plan != nil, lastComputedKey == key { return }

        if plan != nil {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            isRecomputing = true
        }

        let config = draftConfig
        let linked = Set(config.linkedAccountIDs)
        let investedNow = store.accounts
            .filter { linked.contains($0.id) }
            .reduce(Money.zero) { $0 + $1.balance }

        let series = await store.monthlySpendSeries(monthsBack: 12)
        guard !Task.isCancelled else { return }
        let annualSpending = series.reduce(Money.zero) { $0 + $1.1.magnitude }

        // The planner (1,000 Monte Carlo runs) stays off the main actor. Cancelling this view's
        // task does NOT propagate into the detached task — it just finishes and the guards below
        // keep its stale result from landing.
        let snapshot = await Task.detached(priority: .userInitiated) {
            RetirementPlanner.snapshot(config: config,
                                       investedNow: investedNow,
                                       annualSpendingFromBudget: annualSpending,
                                       runs: 1000)
        }.value
        guard !Task.isCancelled else { return }

        withAnimation(reduceMotion ? nil : theme.motion.spring) {
            plan = PlanResult(snapshot: snapshot, config: config)
        }
        lastComputedKey = key
        isRecomputing = false
    }

    // MARK: Shared helpers

    private func cardLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.font(.label))
            .foregroundStyle(theme.palette.textSecondary)
            .textCase(theme.typography.labelCase)
            .tracking(theme.typography.labelTracking)
    }

    private static func percentText(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(1)))
    }

    /// Whole currency units → Money, clamped well inside Int64 (LESSONS_FROM_STASHY §2:
    /// `isFinite` alone doesn't make a Double→Int conversion safe).
    private static func money(fromDollars dollars: Double) -> Money {
        let cents = (dollars * 100).rounded()
        guard cents.isFinite else { return .zero }
        let clamped = min(max(cents, 0), 1e15)
        return Money(cents: Int64(clamped))
    }

    private static func clampedInt(_ value: Double, min minValue: Int, max maxValue: Int) -> Int {
        guard value.isFinite else { return minValue }
        return Int(Swift.min(Swift.max(value.rounded(), Double(minValue)), Double(maxValue)))
    }

    private static func compactMoney(_ dollars: Double) -> String {
        let cents = (dollars * 100).rounded()
        let clamped = cents.isFinite ? min(max(cents, -9e17), 9e17) : 0
        return CurrencyFormatter.string(Money(cents: Int64(clamped)), format: .compact)
    }
}
