import SwiftUI

// MARK: - WhatIfView
//
// The personal playground, pushed via `Route.retireWhatIf`. Everything on this screen mutates
// PersonalPlanModel DRAFTS only: sliders feed the debounced detached recompute owned by the
// glance, and nothing touches Retiron. "Save as my plan" folds the spending delta into the
// config and writes `Preferences.retirementConfigJSON`; Reset reseeds the drafts.
//
// Lever hygiene: a lever tap on the glance pre-applies a draft, sets `pendingLeverSeed` and
// pushes here. If that flag was set on arrival and the user never touches anything or saves,
// popping back discards the draft, so a lever tap can never leave hidden dirty state behind a
// back-swipe. Drafts the user made by hand earlier survive, because the flag is not set for them.

@MainActor
struct WhatIfView: View {
    /// Optional on purpose: a force read traps if this destination is ever built outside the
    /// Retire tab's injected stack, so the models are unwrapped once and the screen shows a
    /// placeholder instead of crashing.
    @Environment(PersonalPlanModel.self) private var personal: PersonalPlanModel?
    @Environment(HouseholdPlanModel.self) private var household: HouseholdPlanModel?

    var body: some View {
        if let personal, let household {
            WhatIfContent(personal: personal, household: household)
        } else {
            RetirePlaceholderScreen(title: "What If")
        }
    }
}

// MARK: - Placeholder
//
// What every Retire drill-in shows when its models are not in the environment. It should never
// be seen in the shipped app; it exists so a stray mount degrades instead of trapping.

struct RetirePlaceholderScreen: View {
    let title: String

    var body: some View {
        EmptyStateView(systemImage: "chart.line.uptrend.xyaxis",
                       title: "Nothing to show yet",
                       message: "Open this from the Retire tab and your plan comes with it.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedScreen()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - WhatIfContent

@MainActor
private struct WhatIfContent: View {
    let personal: PersonalPlanModel
    let household: HouseholdPlanModel

    @Environment(Preferences.self) private var preferences
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.privacyMode) private var privacyMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True while a finger is on any slider, gating the per-detent tick haptic so programmatic
    /// reseeds stay silent.
    @State private var isAdjustingSlider = false

    /// A lever pre-applied the drafts on the way in; those drafts are discarded on the way out
    /// unless the user takes over or saves.
    @State private var leverSeeded = false
    @State private var userTouched = false
    @State private var saved = false
    @State private var hasAppeared = false

    var body: some View {
        content
            .themedScreen()
            .navigationTitle("What If")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: personal.computeKey) {
                await personal.recompute()
            }
            .onChange(of: preferences.retirementConfigJSON) { _, _ in
                personal.reloadSavedConfig()
            }
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true
                // Only a lever pre-apply counts as throwaway state. Drafts the user made by
                // hand on an earlier visit are theirs, and popping back must not eat them.
                leverSeeded = personal.pendingLeverSeed
                personal.pendingLeverSeed = false
            }
            .onDisappear {
                if leverSeeded && !userTouched && !saved {
                    personal.resetDrafts()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if personal.isUnconfigured {
            emptyState
        } else if let plan = personal.plan {
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
                       action: { router.push(.planInputs) })
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

    // MARK: Layout

    private func planScroll(_ plan: PersonalPlanResult) -> some View {
        ScrollView {
            VStack(spacing: theme.layout.cardSpacing) {
                sandboxCaption
                RetirementChartCard(snapshot: plan.snapshot,
                                    config: plan.config,
                                    isRecomputing: personal.isRecomputing)
                fiProgressCard(plan.snapshot)
                spendingCard(plan)
                slidersCard
                RetirementMilestonesRow(snapshot: plan.snapshot,
                                        retireAge: plan.config.retireAge,
                                        currentAge: plan.config.currentAge)
                if personal.draftDiffers {
                    saveBar
                }
                footerSentence
            }
            .padding(.horizontal, theme.layout.cardPadding)
            .padding(.top, theme.layout.spacing * 0.5)
            .padding(.bottom, theme.layout.cardSpacing)
            .animation(reduceMotion ? nil : theme.motion.spring, value: personal.draftDiffers)
        }
        .scrollIndicators(.hidden)
    }

    private var sandboxCaption: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("A sandbox. Nothing saves or syncs until you tap Save.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: theme.layout.spacing)
            if personal.draftDiffers {
                TryingPill()
            }
        }
    }

    private var footerSentence: some View {
        Text("These try-outs run on your real balances and change only this phone. The shared household plan is edited behind the gear and syncs to Retiron.")
            .font(theme.font(.caption))
            .foregroundStyle(theme.palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Personal FI progress

    /// The personal FI number's connected-state home: one sentence over the down-payment-style
    /// capsule bar. The label shows the true percent; the bar clamps at full.
    private func fiProgressCard(_ snapshot: RetirementSnapshot) -> some View {
        let fraction = snapshot.progress.isFinite ? min(max(snapshot.progress, 0), 1) : 0
        return VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Enough to retire:")
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.textSecondary)
                // The period rides in its own zero-spacing stack so it sits tight against the
                // amount instead of drifting a space away from it.
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    AmountText(snapshot.fiNumber, style: .body, colorized: false)
                    Text(".")
                        .font(theme.font(.subheadline))
                        .foregroundStyle(theme.palette.textSecondary)
                }
                Text("You are \(progressText(snapshot.progress)) there.")
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            progressBar(fraction)
        }
        .themedCard()
        .accessibilityElement(children: .combine)
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(theme.palette.fill)
                Capsule()
                    .fill(theme.accentGradient)
                    .frame(width: max(0, width * fraction))
            }
        }
        .frame(height: 8)
        .animation(reduceMotion ? nil : theme.motion.snappy, value: fraction)
        .accessibilityHidden(true)
    }

    private func progressText(_ progress: Double) -> String {
        let safe = progress.isFinite ? max(progress, 0) : 0
        return min(safe, 9.99).formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: Spending card

    private func spendingCard(_ plan: PersonalPlanResult) -> some View {
        @Bindable var personal = personal
        let averageMonthly = Money(cents: plan.derivedAnnualSpending.cents / 12)
        let retirementMonthly = Money(cents: plan.snapshot.annualSpending.cents / 12)
        return VStack(alignment: .leading, spacing: theme.layout.spacing) {
            SectionHeader("Spending")
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
            if personal.savedConfig.annualSpendingOverride == nil {
                Text("Taken from your last 12 months of real spending.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            sliderRow(title: "Spend less or more",
                      accessibilityLabel: "Monthly spending change",
                      value: $personal.draftSpendDelta, range: -1000...1000, step: 50) {
                Text(spendDeltaLabel)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: personal.draftSpendDelta)
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
            if let divergence = divergenceSentence {
                Text(divergence)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .privacySensitive()
            }
        }
        .themedCard()
        .onChange(of: personal.draftSpendDelta) { _, _ in sliderTick() }
    }

    private var spendDeltaLabel: String {
        guard personal.hasSpendDelta else { return "No change" }
        let amount = CurrencyFormatter.string(Self.money(fromDollars: abs(personal.draftSpendDelta)),
                                              format: .whole)
        return personal.draftSpendDelta < 0 ? "\(amount) less" : "\(amount) more"
    }

    /// The computed plain sentence under the delta slider. Uses the COMPUTED plan (not the live
    /// slider value) so it always describes numbers that actually ran through the planner.
    private func spendingSentence(_ plan: PersonalPlanResult) -> String? {
        guard abs(plan.spendDelta) > 0.5 else { return nil }
        let amount = CurrencyFormatter.string(Self.money(fromDollars: abs(plan.spendDelta)),
                                              format: .whole)
        let direction = plan.spendDelta < 0 ? "less" : "more"
        let lead = "Spending \(amount) \(direction) each month"
        switch (plan.baselineProjectedAge, plan.snapshot.projectedRetireAge) {
        case let (.some(base), .some(current)):
            let months = Int(((base - current) * 12).rounded())
            if months > 1 { return "\(lead) moves retirement \(spanText(months: months)) closer." }
            if months < -1 { return "\(lead) pushes retirement \(spanText(months: months)) later." }
            return "\(lead) barely moves the date here."
        case let (.none, .some(current)):
            return "\(lead) brings retirement in reach, around age \(clampedAge(current))."
        case (.some, .none):
            return "\(lead) puts retirement out of reach on these numbers."
        case (.none, .none):
            return "Even with this change, retirement is not yet in reach on these numbers."
        }
    }

    /// The honest blend line: shown only when connected and the household assumption and real
    /// spending disagree by more than 15 percent.
    private var divergenceSentence: String? {
        guard household.isConnected,
              let assumedAnnual = household.plan?.config.annualSpend, assumedAnnual > 0,
              let actual = personal.actualMonthlySpend, actual.cents > 0 else { return nil }
        let assumedMonthly = Money(clampedDollars: assumedAnnual / 12)
        guard assumedMonthly.cents > 0 else { return nil }
        let gap = abs(assumedMonthly.doubleValue - actual.doubleValue) / assumedMonthly.doubleValue
        guard gap > 0.15 else { return nil }
        // Both amounts ride inside flowing copy, where AmountText cannot go, so privacy mode is
        // honored by hand exactly as the glance's copy of this sentence does.
        let assumed = privacyMode ? "••••"
            : CurrencyFormatter.string(assumedMonthly, format: .whole)
        let spending = privacyMode ? "••••"
            : CurrencyFormatter.string(actual, format: .whole)
        return "The household plan assumes \(assumed) a month. You actually spend \(spending)."
    }

    // MARK: Sliders card

    private var slidersCard: some View {
        @Bindable var personal = personal
        return VStack(alignment: .leading, spacing: theme.layout.spacing) {
            SectionHeader("What If…")
            sliderRow(title: "Retire at",
                      accessibilityLabel: "Retirement age",
                      value: $personal.draftRetireAge, range: 40...75, step: 1) {
                Text("\(clampedAge(personal.draftRetireAge))")
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: personal.draftRetireAge)
            }
            sliderRow(title: "Monthly contribution",
                      accessibilityLabel: "Monthly contribution",
                      value: $personal.draftContribution, range: 0...10_000, step: 100) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    AmountText(Self.money(fromDollars: personal.draftContribution),
                               style: .body, colorized: false)
                    Text("/mo")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            if personal.hasSpendDelta {
                Text(spendDeltaContributionNote)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detected = personal.detectedContribution,
               abs(detected.doubleValue - personal.draftContribution) >= 1 {
                detectedHintRow(detected)
            }
            sliderRow(title: "Expected return",
                      accessibilityLabel: "Expected annual return",
                      value: $personal.draftReturn, range: 3...12, step: 0.5) {
                Text(Self.percentText(personal.draftReturn))
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: personal.draftReturn)
            }
        }
        .themedCard()
        .onChange(of: personal.draftRetireAge) { _, _ in sliderTick() }
        .onChange(of: personal.draftContribution) { _, _ in sliderTick() }
        .onChange(of: personal.draftReturn) { _, _ in sliderTick() }
    }

    private var spendDeltaContributionNote: String {
        let amount = CurrencyFormatter.string(Self.money(fromDollars: abs(personal.draftSpendDelta)),
                                              format: .whole)
        return personal.draftSpendDelta < 0
            ? "Plus the \(amount) a month you would not be spending."
            : "Minus the \(amount) a month of extra spending."
    }

    private func detectedHintRow(_ detected: Money) -> some View {
        Button {
            Haptics.tick()
            userTouched = true
            withAnimation(reduceMotion ? nil : theme.motion.snappy) {
                personal.draftContribution = min(max(detected.doubleValue, 0), 10_000)
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
                   onEditingChanged: { editing in
                       isAdjustingSlider = editing
                       if editing { userTouched = true }
                   })
                .tint(theme.palette.accent)
                .accessibilityLabel(accessibilityLabel)
        }
        .frame(minHeight: 44)
    }

    /// Detent tick per discrete slider step, only while a finger is actually on a slider, so
    /// programmatic reseeds (lever pre-applies, post-save) stay silent.
    private func sliderTick() {
        if isAdjustingSlider { Haptics.tick() }
    }

    // MARK: Save bar

    /// Reset is deliberately as prominent as Save: throwing a played-with plan away should be
    /// as easy as keeping it.
    private var saveBar: some View {
        HStack(spacing: theme.layout.cardSpacing) {
            NidgetButton("Save as my plan", systemImage: "checkmark") {
                personal.saveDraft()
                saved = true
            }
            NidgetButton("Reset", role: .secondary) {
                Haptics.tick()
                personal.resetDrafts()
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: Number helpers

    private static func percentText(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(1)))
    }

    /// Whole currency units to Money, clamped well inside Int64.
    private static func money(fromDollars dollars: Double) -> Money {
        let cents = (dollars * 100).rounded()
        guard cents.isFinite else { return .zero }
        let clamped = min(max(cents, 0), 1e15)
        return Money(cents: Int64(clamped))
    }
}
