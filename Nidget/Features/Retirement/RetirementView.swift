import SwiftUI
import os

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
// The Retire tab root, reframed around the owner's actual question: "how far from retirement
// am I, and how does my spending affect that?" (docs/UX_ROUND2.md §2). Layout, top to bottom:
// countdown hero ("Retirement at ~58" + years to go, FI ring second), the spending card with a
// live delta slider and a computed plain sentence, the interactive age chart
// (`RetirementChartCard`), the "What moves the needle" levers, the milestones row, the what-if
// sliders, and an optional on-device "Explain my plan" card when a generation model is
// installed.
//
// Data flow: the SAVED config comes from `Preferences.retirementConfigJSON`; the sliders edit a
// DRAFT (retire age / monthly contribution / expected return / spending delta) layered on top.
// Any change to the draft, the saved config, or account balances re-runs the planner on ONE
// detached task — main snapshot (1,000 Monte Carlo runs) plus the delta-zero baseline and the
// three lever variants (300 runs each; the projected age is deterministic-path math, so run
// count doesn't change it) — debounced 250 ms once a first plan exists (LESSONS_FROM_STASHY §1:
// debounce query changes; dedupe with cancellation guards so a stale task never clobbers a
// newer result). "Save these assumptions" persists the draft (folding a nonzero spending delta
// into the override and contribution) back to Preferences, whose change reseeds the draft.

@MainActor
struct RetirementView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.privacyMode) private var privacyMode

    private static let log = Logger(subsystem: "app.nidget", category: "retire")

    /// Decoded mirror of `Preferences.retirementConfigJSON`, kept current via onChange.
    @State private var savedConfig: RetirementConfig
    /// What-if draft values (the slider-editable fields).
    @State private var draftRetireAge: Double
    @State private var draftContribution: Double   // whole currency units per month
    @State private var draftReturn: Double
    /// Spending delta in whole currency units per month; negative = spend less. It moves BOTH
    /// the retirement-spending assumption and the contribution (money not spent is money saved).
    @State private var draftSpendDelta: Double = 0
    /// True while a finger is on any what-if slider — gates the per-detent tick haptic so
    /// programmatic reseeds stay silent.
    @State private var isAdjustingSlider = false

    @State private var plan: PlanResult?
    @State private var isRecomputing = false
    @State private var lastComputedKey: ComputeKey?

    /// Monthly contribution detected from transfers into the linked accounts; nil = none found.
    @State private var detectedContribution: Money?

    /// On-device plan narrative ("Explain my plan"); nil until requested.
    @State private var planSummary: String?
    @State private var isExplaining = false
    /// Bumped to abandon any in-flight explanation (stale plan or a newer request).
    @State private var explainToken = 0

    init() {
        let config = RetirementConfigCodec.decode(Preferences.shared.retirementConfigJSON)
        _savedConfig = State(initialValue: config)
        _draftRetireAge = State(initialValue: Double(config.retireAge))
        _draftContribution = State(initialValue: max(Double(config.monthlyContribution.cents) / 100.0, 0))
        _draftReturn = State(initialValue: config.expectedReturnPct)
    }

    // MARK: Derived state

    /// The planner result plus the exact config it was computed with, so chart adornments
    /// always agree with the plotted data even mid-debounce.
    private struct PlanResult {
        var snapshot: RetirementSnapshot
        /// The EFFECTIVE config the planner ran (draft + spending delta folded in).
        var config: RetirementConfig
        /// Last-12-months outflow the spending average and delta baseline derive from.
        var derivedAnnualSpending: Money
        /// The spending delta (currency units/month) this result reflects.
        var spendDelta: Double
        /// Projected crossing age with the spending delta zeroed (== the snapshot's own when
        /// the delta is zero). Drives the computed spending sentence.
        var baselineProjectedAge: Double?
        var levers: RetirementLeverOutcomes
    }

    /// Everything a recompute depends on; used as the `.task(id:)` key.
    private struct ComputeKey: Equatable {
        var configJSON: String
        var accounts: [Account]
        var retireAge: Double
        var contribution: Double
        var expectedReturn: Double
        var spendDelta: Double
    }

    /// What the single detached compute task hands back.
    private struct DetachedPlan: Sendable {
        var snapshot: RetirementSnapshot
        var levers: RetirementLeverOutcomes
        var baselineProjectedAge: Double?
    }

    private var computeKey: ComputeKey {
        ComputeKey(configJSON: preferences.retirementConfigJSON,
                   accounts: store.accounts,
                   retireAge: draftRetireAge,
                   contribution: draftContribution,
                   expectedReturn: draftReturn,
                   spendDelta: draftSpendDelta)
    }

    /// Saved config with the three plain slider fields layered on top. The spending delta is
    /// folded in later (in `recompute`/`saveDraft`) because it needs the derived annual spend.
    private var draftConfig: RetirementConfig {
        var config = savedConfig
        config.retireAge = Self.clampedInt(draftRetireAge, min: 0, max: 150)
        config.monthlyContribution = Self.money(fromDollars: draftContribution)
        config.expectedReturnPct = draftReturn
        return config
    }

    private var hasSpendDelta: Bool { abs(draftSpendDelta) > 0.5 }

    private var draftDiffers: Bool {
        let draft = draftConfig
        return draft.retireAge != savedConfig.retireAge
            || draft.monthlyContribution != savedConfig.monthlyContribution
            || abs(draft.expectedReturnPct - savedConfig.expectedReturnPct) > 0.0001
            || hasSpendDelta
    }

    /// Nothing to plan with: no linked accounts AND no outside assets.
    private var isUnconfigured: Bool {
        savedConfig.linkedAccountIDs.isEmpty && savedConfig.extraAssets == .zero
    }

    /// A generation model is selected and its file is on disk — the "Explain my plan" card
    /// exists only then. Reads observable manager state, so body re-evaluates on changes.
    private var canExplainPlan: Bool {
        guard let id = AIModelManager.shared.generationModelID else { return false }
        return ModelDownloadManager.shared.state(for: id) == .ready
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
            .task(id: savedConfig.linkedAccountIDs) {
                let detected = await ContributionDetector.detectedMonthlyContribution(
                    store: store, linkedAccountIDs: savedConfig.linkedAccountIDs)
                guard !Task.isCancelled else { return }
                detectedContribution = detected
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
                       message: "Tell Nidget which accounts hold your future, or add outside assets, and it will chart your road to retirement.",
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
                spendingCard(plan)
                RetirementChartCard(snapshot: plan.snapshot,
                                    config: plan.config,
                                    isRecomputing: isRecomputing)
                RetirementLeversCard(outcomes: plan.levers,
                                     onSaveMore: { applySaveMoreLever() },
                                     onSpendLess: { applySpendLessLever() },
                                     onEarnMore: { applyEarnMoreLever() })
                RetirementMilestonesRow(snapshot: plan.snapshot,
                                        retireAge: plan.config.retireAge,
                                        currentAge: plan.config.currentAge)
                whatIfCard
                if canExplainPlan {
                    explainCard(plan)
                }
            }
            .padding(.horizontal, theme.layout.cardPadding)
            .padding(.top, theme.layout.spacing * 0.5)
            .padding(.bottom, theme.layout.cardSpacing)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Hero card

    private func heroCard(_ plan: PlanResult) -> some View {
        let headline = heroHeadline(plan)
        return VStack(alignment: .leading, spacing: theme.layout.spacing) {
            cardLabel("Retirement")
            Text(headline)
                .font(theme.font(.display))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : theme.motion.snappy, value: headline)
            Text(heroSubline(plan))
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: theme.layout.spacing) {
                GaugeArc(progress: plan.snapshot.progress,
                         label: progressText(plan.snapshot.progress),
                         detail: "to FI")
                    .frame(width: 120, height: 120)
                Spacer(minLength: theme.layout.spacing)
                VStack(alignment: .trailing, spacing: theme.layout.spacing * 0.75) {
                    VStack(alignment: .trailing, spacing: 2) {
                        cardLabel("Invested")
                        AmountText(plan.snapshot.invested, style: .title, colorized: false)
                            .minimumScaleFactor(0.6)
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        cardLabel("Enough to retire")
                        AmountText(plan.snapshot.fiNumber, style: .title, colorized: false)
                            .minimumScaleFactor(0.6)
                    }
                }
            }
        }
        .themedCard()
    }

    private func heroHeadline(_ plan: PlanResult) -> String {
        guard let projected = plan.snapshot.projectedRetireAge else { return "Not yet in reach" }
        if projected <= Double(plan.config.currentAge) + 0.01 { return "You could retire now" }
        return "Retirement at ~\(Self.clampedInt(projected, min: 0, max: 150))"
    }

    private func heroSubline(_ plan: PlanResult) -> String {
        guard let projected = plan.snapshot.projectedRetireAge else {
            return "On these numbers your savings never quite get there. The levers below show what would help."
        }
        let years = projected - Double(plan.config.currentAge)
        if years <= 0.01 { return "Your savings already cover your retirement spending." }
        if years < 1 { return "Less than a year to go." }
        if years < 2 { return "About \(Self.clampedInt(years * 12, min: 1, max: 24)) months to go." }
        return "About \(Self.clampedInt(years, min: 2, max: 150)) years to go."
    }

    private func progressText(_ progress: Double) -> String {
        let safe = progress.isFinite ? max(progress, 0) : 0
        return min(safe, 9.99).formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: Spending card

    private func spendingCard(_ plan: PlanResult) -> some View {
        let averageMonthly = Money(cents: plan.derivedAnnualSpending.cents / 12)
        let retirementMonthly = Money(cents: plan.snapshot.annualSpending.cents / 12)
        return VStack(alignment: .leading, spacing: theme.layout.spacing) {
            cardLabel("Spending")
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Now, each month")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                    AmountText(averageMonthly, style: .title, colorized: false)
                }
                Spacer(minLength: theme.layout.spacing)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("In retirement")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                    AmountText(retirementMonthly, style: .title, colorized: false)
                }
            }
            if savedConfig.annualSpendingOverride == nil {
                Text("Taken from your last 12 months of real spending.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            sliderRow(title: "Spend less or more",
                      accessibilityLabel: "Monthly spending change",
                      value: $draftSpendDelta, range: -1000...1000, step: 50) {
                Text(spendDeltaLabel)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: draftSpendDelta)
            }
            if let sentence = spendingSentence(plan) {
                Text(sentence)
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Slide to try spending less or more each month.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .themedCard()
        .onChange(of: draftSpendDelta) { _, _ in sliderTick() }
    }

    private var spendDeltaLabel: String {
        guard hasSpendDelta else { return "No change" }
        let amount = CurrencyFormatter.string(Self.money(fromDollars: abs(draftSpendDelta)),
                                              format: .whole)
        return draftSpendDelta < 0 ? "\(amount) less" : "\(amount) more"
    }

    /// The computed plain sentence under the delta slider. Uses the COMPUTED plan (not the live
    /// slider value) so it always describes numbers that actually ran through the planner.
    private func spendingSentence(_ plan: PlanResult) -> String? {
        guard abs(plan.spendDelta) > 0.5 else { return nil }
        let amount = CurrencyFormatter.string(Self.money(fromDollars: abs(plan.spendDelta)),
                                              format: .whole)
        let direction = plan.spendDelta < 0 ? "less" : "more"
        let lead = "Spending \(amount) \(direction) each month"
        switch (plan.baselineProjectedAge, plan.snapshot.projectedRetireAge) {
        case let (.some(base), .some(current)):
            let months = Int(((base - current) * 12).rounded())
            if months > 1 { return "\(lead) moves retirement \(Self.spanText(months: months)) closer." }
            if months < -1 { return "\(lead) pushes retirement \(Self.spanText(months: months)) later." }
            return "\(lead) barely moves the date here."
        case let (.none, .some(current)):
            return "\(lead) brings retirement in reach, around age \(Self.clampedInt(current, min: 0, max: 150))."
        case (.some, .none):
            return "\(lead) puts retirement out of reach on these numbers."
        case (.none, .none):
            return "Even with this change, retirement is not yet in reach on these numbers."
        }
    }

    private static func spanText(months: Int) -> String {
        let magnitude = abs(months)
        if magnitude == 1 { return "about a month" }
        if magnitude < 24 { return "about \(magnitude) months" }
        let years = Int((Double(magnitude) / 12.0).rounded())
        return "about \(years) years"
    }

    // MARK: Lever application

    private func applySaveMoreLever() {
        withAnimation(reduceMotion ? nil : theme.motion.snappy) {
            draftContribution = min(draftContribution + RetirementLeverMath.leverDollars.doubleValue, 10_000)
        }
    }

    private func applySpendLessLever() {
        withAnimation(reduceMotion ? nil : theme.motion.snappy) {
            draftSpendDelta = max(draftSpendDelta - RetirementLeverMath.leverDollars.doubleValue, -1_000)
        }
    }

    private func applyEarnMoreLever() {
        withAnimation(reduceMotion ? nil : theme.motion.snappy) {
            draftReturn = min(draftReturn + RetirementLeverMath.leverReturnStep, 12)
        }
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
            if hasSpendDelta {
                Text(spendDeltaContributionNote)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detectedContribution,
               abs(detectedContribution.doubleValue - draftContribution) >= 1 {
                detectedHintRow(detectedContribution)
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

    private var spendDeltaContributionNote: String {
        let amount = CurrencyFormatter.string(Self.money(fromDollars: abs(draftSpendDelta)),
                                              format: .whole)
        return draftSpendDelta < 0
            ? "Plus the \(amount) a month you would not be spending."
            : "Minus the \(amount) a month of extra spending."
    }

    private func detectedHintRow(_ detected: Money) -> some View {
        Button {
            Haptics.tick()
            withAnimation(reduceMotion ? nil : theme.motion.snappy) {
                draftContribution = min(max(detected.doubleValue, 0), 10_000)
            }
        } label: {
            HStack(spacing: 4) {
                Text("Transfers suggest about")
                AmountText(detected, style: .caption, colorized: false)
                Text("a month.")
                Spacer(minLength: theme.layout.spacing * 0.5)
                Text("Use")
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.palette.accent)
            }
            .font(theme.font(.caption))
            .foregroundStyle(theme.palette.textTertiary)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Sets the contribution slider to the amount detected from your transfers")
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
    /// programmatic reseeds (launch, post-save, lever taps) stay silent.
    private func sliderTick() {
        if isAdjustingSlider { Haptics.tick() }
    }

    // MARK: Explain card (on-device AI)

    private func explainCard(_ plan: PlanResult) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            cardLabel("In Plain Words")
            if let planSummary {
                Text(planSummary)
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .privacySensitive()
                    .blur(radius: privacyMode ? 6 : 0)
                Button {
                    explain(plan)
                } label: {
                    Text("Explain again")
                        .font(theme.font(.caption))
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.palette.accent)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if isExplaining {
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
                    explain(plan)
                }
                Text("A few plain sentences from the on-device model. Nothing leaves your phone.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .themedCard()
        .animation(reduceMotion ? nil : theme.motion.spring, value: planSummary == nil)
    }

    private func explain(_ plan: PlanResult) {
        explainToken += 1
        let token = explainToken
        isExplaining = true
        planSummary = nil
        let system = Self.explainSystemPrompt
        let facts = Self.explainFacts(plan)
        Task {
            let reply = await AIModelManager.shared.generator.chat(
                system: system, user: facts,
                maxTokens: 220, temperature: 0.3, topK: 20)
            guard token == explainToken else { return }   // a newer request or plan took over
            isExplaining = false
            let cleaned = Self.clippedSentences(Self.strippedDashes(reply ?? ""), limit: 4)
            if cleaned.isEmpty {
                Self.log.debug("Plan explanation came back empty")
                Haptics.warning()
            } else {
                withAnimation(reduceMotion ? nil : theme.motion.spring) {
                    planSummary = cleaned
                }
            }
        }
    }

    private static let explainSystemPrompt =
        "You are a warm, plain-spoken money coach inside a personal budgeting app. "
        + "Explain the user's retirement plan in three or four short sentences, using only the "
        + "facts given. No lists, no headings, no disclaimers, no advice to see a professional."

    private static func explainFacts(_ plan: PlanResult) -> String {
        let snapshot = plan.snapshot
        let config = plan.config
        var lines: [String] = []
        lines.append("Current age: \(config.currentAge)")
        lines.append("Saved so far: \(CurrencyFormatter.string(snapshot.invested, format: .whole))")
        lines.append("Enough to retire: \(CurrencyFormatter.string(snapshot.fiNumber, format: .whole)) at a \((config.withdrawalRatePct / 100).formatted(.percent.precision(.fractionLength(0...1)))) withdrawal rate")
        let monthlySpend = Money(cents: snapshot.annualSpending.cents / 12)
        lines.append("Planned monthly spending in retirement: \(CurrencyFormatter.string(monthlySpend, format: .whole))")
        lines.append("Saving each month: \(CurrencyFormatter.string(config.monthlyContribution, format: .whole))")
        lines.append("Expected return: \((config.expectedReturnPct / 100).formatted(.percent.precision(.fractionLength(0...1)))) a year, with \((config.inflationPct / 100).formatted(.percent.precision(.fractionLength(0...1)))) inflation")
        if let projected = snapshot.projectedRetireAge {
            lines.append("Projected retirement age: about \(clampedInt(projected, min: 0, max: 150))")
        } else {
            lines.append("Projected retirement age: not reached with these numbers")
        }
        lines.append("Chance the money lasts to \(config.lifeExpectancy): \(snapshot.successProbability.formatted(.percent.precision(.fractionLength(0))))")
        return "Facts about my retirement plan:\n"
            + lines.joined(separator: "\n")
            + "\nExplain what these numbers mean for me."
    }

    /// First `limit` sentences of `text`, joined with single spaces. Anything the model rambles
    /// past the limit is dropped.
    private static func clippedSentences(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var sentences: [String] = []
        trimmed.enumerateSubstrings(in: trimmed.startIndex..<trimmed.endIndex,
                                    options: [.bySentences, .localized]) { substring, _, _, stop in
            if let substring {
                let sentence = substring.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
            }
            if sentences.count >= limit { stop = true }
        }
        return sentences.joined(separator: " ")
    }

    /// The copy rule bans em dashes everywhere user-facing; model output gets the same wash.
    private static func strippedDashes(_ text: String) -> String {
        text.replacingOccurrences(of: " — ", with: ", ")
            .replacingOccurrences(of: "—", with: ", ")
            .replacingOccurrences(of: " – ", with: ", ")
            .replacingOccurrences(of: "–", with: ", ")
    }

    // MARK: Draft persistence

    private func seedDrafts(from config: RetirementConfig) {
        draftRetireAge = Double(config.retireAge)
        draftContribution = max(Double(config.monthlyContribution.cents) / 100.0, 0)
        draftReturn = config.expectedReturnPct
        draftSpendDelta = 0
    }

    private func saveDraft() {
        var config = draftConfig
        if hasSpendDelta, let plan {
            // Fold the spending delta into the persistent fields, both ways it acts: the
            // retirement-spending override moves by delta x 12, and the freed (or consumed)
            // money moves the contribution the opposite way.
            let delta = Self.signedMoney(fromDollars: draftSpendDelta)
            let baseAnnual = savedConfig.annualSpendingOverride ?? plan.derivedAnnualSpending
            config.annualSpendingOverride = Money(cents: max(baseAnnual.cents + delta.cents * 12, 0))
            config.monthlyContribution = Money(cents: max(config.monthlyContribution.cents - delta.cents, 0))
        }
        guard let json = RetirementConfigCodec.encode(config) else {
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

        let baseConfig = draftConfig
        let linked = Set(baseConfig.linkedAccountIDs)
        let investedNow = store.accounts
            .filter { linked.contains($0.id) }
            .reduce(Money.zero) { $0 + $1.balance }

        let series = await store.monthlySpendSeries(monthsBack: 12)
        guard !Task.isCancelled else { return }
        let annualSpending = series.reduce(Money.zero) { $0 + $1.1.magnitude }

        // Fold the spending delta into the effective config: the retirement-spending target
        // moves by delta x 12, and the freed (or consumed) money moves the contribution.
        let spendDelta = draftSpendDelta
        let hasDelta = abs(spendDelta) > 0.5
        var config = baseConfig
        if hasDelta {
            let delta = Self.signedMoney(fromDollars: spendDelta)
            let baseAnnual = baseConfig.annualSpendingOverride ?? annualSpending
            config.annualSpendingOverride = Money(cents: max(baseAnnual.cents + delta.cents * 12, 0))
            config.monthlyContribution = Money(cents: max(baseConfig.monthlyContribution.cents - delta.cents, 0))
        }
        let zeroDeltaConfig = baseConfig

        // ONE detached task computes everything off the main actor: the main snapshot
        // (1,000 runs), the delta-zero baseline, and the three levers (300 runs each).
        // Cancelling this view's task does NOT propagate into the detached task — it just
        // finishes and the guards below keep its stale result from landing.
        let result = await Task.detached(priority: .userInitiated) { () -> DetachedPlan in
            let snapshot = RetirementPlanner.snapshot(config: config,
                                                      investedNow: investedNow,
                                                      annualSpendingFromBudget: annualSpending,
                                                      runs: 1000)
            let levers = RetirementLeverMath.outcomes(config: config,
                                                      investedNow: investedNow,
                                                      annualSpendingFromBudget: annualSpending,
                                                      baseProjectedAge: snapshot.projectedRetireAge)
            var baselineProjected = snapshot.projectedRetireAge
            if hasDelta {
                baselineProjected = RetirementPlanner.snapshot(config: zeroDeltaConfig,
                                                               investedNow: investedNow,
                                                               annualSpendingFromBudget: annualSpending,
                                                               runs: RetirementLeverMath.leverRuns).projectedRetireAge
            }
            return DetachedPlan(snapshot: snapshot, levers: levers,
                                baselineProjectedAge: baselineProjected)
        }.value
        guard !Task.isCancelled else { return }

        withAnimation(reduceMotion ? nil : theme.motion.spring) {
            plan = PlanResult(snapshot: result.snapshot,
                              config: config,
                              derivedAnnualSpending: annualSpending,
                              spendDelta: spendDelta,
                              baselineProjectedAge: result.baselineProjectedAge,
                              levers: result.levers)
            // A narrative about the old numbers would now be wrong — drop it.
            if planSummary != nil { planSummary = nil }
        }
        if isExplaining {
            explainToken += 1
            isExplaining = false
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

    /// Signed variant for the spending delta (negative = spend less).
    private static func signedMoney(fromDollars dollars: Double) -> Money {
        let cents = (dollars * 100).rounded()
        guard cents.isFinite else { return .zero }
        let clamped = min(max(cents, -1e15), 1e15)
        return Money(cents: Int64(clamped))
    }

    private static func clampedInt(_ value: Double, min minValue: Int, max maxValue: Int) -> Int {
        guard value.isFinite else { return minValue }
        return Int(Swift.min(Swift.max(value.rounded(), Double(minValue)), Double(maxValue)))
    }
}
