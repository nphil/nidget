import SwiftUI

// MARK: - RetirementLeverShift
//
// What one lever (save more, spend less, earn more) does to the projected retirement age,
// relative to the current what-if state. Computed off-main by `RetirementLeverMath` inside
// RetirementView's single detached compute task and cached with the rest of the plan.

enum RetirementLeverShift: Equatable, Sendable {
    /// Positive = retire this many months earlier; negative = later; near zero = no real change.
    case months(Int)
    /// The base plan never reaches the target, but this lever does, at roughly this age.
    case inReach(age: Double)
    /// Neither the base plan nor this lever reaches the target within the horizon.
    case outOfReach
    /// The base plan already retires today; a lever can't improve on that.
    case alreadyThere
}

/// The three lever results the "What would help" card renders.
struct RetirementLeverOutcomes: Equatable, Sendable {
    var saveMore: RetirementLeverShift
    var spendLess: RetirementLeverShift
    var earnMore: RetirementLeverShift
}

// MARK: - RetirementLeverMath
//
// Pure math, callable off the main actor. Each lever re-runs `RetirementPlanner.snapshot` with
// a small tweak on top of the current effective config; 300 Monte Carlo runs keep it cheap
// (the projected age comes from the deterministic path, which doesn't depend on run count).

enum RetirementLeverMath {
    /// The lever step for contributions and spending: $100 a month (in the budget's currency).
    static let leverDollars = Money(cents: 10_000)
    /// The lever step for expected return: one percentage point.
    static let leverReturnStep = 1.0
    /// Monte Carlo runs per lever snapshot — bands aren't shown, so cheap is fine.
    static let leverRuns = 300

    /// All three lever outcomes relative to `baseProjectedAge` (the current plan's crossing age).
    static func outcomes(config: RetirementConfig, investedNow: Money,
                         annualSpendingFromBudget: Money,
                         baseProjectedAge: Double?) -> RetirementLeverOutcomes {
        if let base = baseProjectedAge, base <= Double(config.currentAge) + 0.01 {
            return RetirementLeverOutcomes(saveMore: .alreadyThere,
                                           spendLess: .alreadyThere,
                                           earnMore: .alreadyThere)
        }

        var saveConfig = config
        saveConfig.monthlyContribution = saveConfig.monthlyContribution + leverDollars

        // Spending less helps twice: the FI target shrinks AND the freed money is saved.
        var spendConfig = config
        let effectiveAnnual = config.annualSpendingOverride ?? annualSpendingFromBudget
        spendConfig.annualSpendingOverride =
            Money(cents: max(effectiveAnnual.cents - leverDollars.cents * 12, 0))
        spendConfig.monthlyContribution = spendConfig.monthlyContribution + leverDollars

        var earnConfig = config
        earnConfig.expectedReturnPct += leverReturnStep

        func projected(_ candidate: RetirementConfig) -> Double? {
            RetirementPlanner.snapshot(config: candidate, investedNow: investedNow,
                                       annualSpendingFromBudget: annualSpendingFromBudget,
                                       runs: leverRuns).projectedRetireAge
        }

        return RetirementLeverOutcomes(
            saveMore: shift(base: baseProjectedAge, candidate: projected(saveConfig)),
            spendLess: shift(base: baseProjectedAge, candidate: projected(spendConfig)),
            earnMore: shift(base: baseProjectedAge, candidate: projected(earnConfig)))
    }

    /// Base crossing age vs. lever crossing age → a displayable shift.
    static func shift(base: Double?, candidate: Double?) -> RetirementLeverShift {
        switch (base, candidate) {
        case let (.some(baseAge), .some(candidateAge)):
            let months = ((baseAge - candidateAge) * 12).rounded()
            guard months.isFinite else { return .months(0) }
            return .months(Int(min(max(months, -6000), 6000)))
        case let (.none, .some(candidateAge)):
            return .inReach(age: candidateAge)
        case (_, .none):
            return .outOfReach
        }
    }

    /// Interpolated age at which the deterministic path reaches HALF the FI number; nil when it
    /// never does, or when the FI number is degenerate (the planner caps an unreachable target
    /// at 10^15 cents — a chart-flattening value that means "no meaningful target").
    static func halfwayAge(snapshot: RetirementSnapshot) -> Double? {
        let degenerateCap: Int64 = 1_000_000_000_000_000
        guard snapshot.fiNumber.cents > 0, snapshot.fiNumber.cents < degenerateCap else { return nil }
        let half = snapshot.fiNumber.doubleValue / 2.0
        let points = snapshot.deterministic
        guard let first = points.first else { return nil }
        if first.value.doubleValue >= half { return first.age }
        guard points.count > 1 else { return nil }
        for i in 1..<points.count where points[i].value.doubleValue >= half {
            let previous = points[i - 1].value.doubleValue
            let delta = points[i].value.doubleValue - previous
            let fraction = delta > 0 ? (half - previous) / delta : 0
            return points[i - 1].age + fraction * (points[i].age - points[i - 1].age)
        }
        return nil
    }
}

// MARK: - RetirementLeversCard
//
// "What would help": three computed rows, each showing what one concrete change does to
// the retirement date. Tapping a row applies that change to the what-if sliders, so the whole
// screen (hero age, chart, sentence) animates to the new plan.

struct RetirementLeversCard: View {
    let outcomes: RetirementLeverOutcomes
    let onSaveMore: () -> Void
    let onSpendLess: () -> Void
    let onEarnMore: () -> Void

    @Environment(\.theme) private var theme

    private var stepAmount: String {
        CurrencyFormatter.string(RetirementLeverMath.leverDollars, format: .whole)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            cardLabel("What Would Help")
            leverRow(icon: "banknote",
                     title: "Save \(stepAmount) more each month",
                     note: nil,
                     shift: outcomes.saveMore,
                     action: onSaveMore)
            divider
            leverRow(icon: "cart.badge.minus",
                     title: "Spend \(stepAmount) less each month",
                     note: "It helps twice: a smaller target and more saved.",
                     shift: outcomes.spendLess,
                     action: onSpendLess)
            divider
            leverRow(icon: "chart.line.uptrend.xyaxis",
                     title: "Earn 1% more each year",
                     note: nil,
                     shift: outcomes.earnMore,
                     action: onEarnMore)
        }
        .themedCard()
    }

    private func leverRow(icon: String, title: String, note: String?,
                          shift: RetirementLeverShift,
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(theme.font(.body))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(outcomeText(shift))
                        .font(theme.font(.caption))
                        .foregroundStyle(outcomeColor(shift))
                        .fixedSize(horizontal: false, vertical: true)
                    if let note {
                        Text(note)
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: theme.layout.spacing)
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
        .accessibilityElement(children: .combine)
        .accessibilityHint("Tries this change on the what if sliders")
    }

    private func outcomeText(_ shift: RetirementLeverShift) -> String {
        switch shift {
        case .months(let months):
            if months > 1 { return "Retire \(Self.span(months)) earlier." }
            if months < -1 { return "Retire \(Self.span(months)) later." }
            return "Barely moves the date."
        case .inReach(let age):
            return "Brings retirement in reach near age \(Self.clampedAge(age))."
        case .outOfReach:
            return "Not enough on its own."
        case .alreadyThere:
            return "You could retire already."
        }
    }

    private func outcomeColor(_ shift: RetirementLeverShift) -> Color {
        switch shift {
        case .months(let months):
            if months > 1 { return theme.palette.positive }
            if months < -1 { return theme.palette.negative }
            return theme.palette.textSecondary
        case .inReach, .alreadyThere:
            return theme.palette.positive
        case .outOfReach:
            return theme.palette.textTertiary
        }
    }

    private static func span(_ months: Int) -> String {
        let magnitude = abs(months)
        if magnitude == 1 { return "about a month" }
        if magnitude < 24 { return "about \(magnitude) months" }
        let years = Int((Double(magnitude) / 12.0).rounded())
        return "about \(years) years"
    }

    private static func clampedAge(_ age: Double) -> Int {
        guard age.isFinite else { return 0 }
        return Int(min(max(age.rounded(), 0), 150))
    }

    private func cardLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.font(.label))
            .foregroundStyle(theme.palette.textSecondary)
            .textCase(theme.typography.labelCase)
            .tracking(theme.typography.labelTracking)
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.palette.separator)
            .frame(height: 1)
    }
}

// MARK: - RetirementMilestonesRow
//
// Two small side-by-side milestone cards: Coast FIRE (when contributions could stop) and the
// halfway point to the FI target. Both read straight off the computed snapshot — no extra
// planner runs.

struct RetirementMilestonesRow: View {
    let snapshot: RetirementSnapshot
    let retireAge: Int
    let currentAge: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: theme.layout.cardSpacing) {
            milestoneCard(title: "Coast FIRE", value: coastValue, sentence: coastSentence)
            milestoneCard(title: "Halfway There", value: halfwayValue, sentence: halfwaySentence)
        }
    }

    // MARK: Coast

    private var coastValue: String {
        guard let coast = snapshot.coastFIREAge else { return "Not yet" }
        if coast <= Double(currentAge) + 0.05 { return "Now" }
        return "Age \(Self.clampedAge(coast))"
    }

    private var coastSentence: String {
        guard let coast = snapshot.coastFIREAge else {
            return "Growth alone will not get you there by \(retireAge). Your contributions still matter."
        }
        if coast <= Double(currentAge) + 0.05 {
            return "You could stop saving today and growth alone would still get you there by \(retireAge)."
        }
        return "Save until then and growth alone can finish the job by \(retireAge)."
    }

    // MARK: Halfway

    private var halfwayAge: Double? {
        RetirementLeverMath.halfwayAge(snapshot: snapshot)
    }

    private var halfwayValue: String {
        if snapshot.progress >= 0.5 { return "Passed" }
        guard let age = halfwayAge else { return "Not yet" }
        return "Age \(Self.clampedAge(age))"
    }

    private var halfwaySentence: String {
        if snapshot.progress >= 0.5 {
            return "You are already past the halfway mark to your target."
        }
        if halfwayAge != nil {
            return "Your savings reach half your target around then."
        }
        return "Half your target is still a way off on these numbers."
    }

    // MARK: Shared

    private func milestoneCard(title: String, value: String, sentence: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            cardLabel(title)
            Text(value)
                .font(theme.font(.title))
                .foregroundStyle(theme.palette.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(sentence)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard()
        .accessibilityElement(children: .combine)
    }

    private static func clampedAge(_ age: Double) -> Int {
        guard age.isFinite else { return 0 }
        return Int(min(max(age.rounded(), 0), 150))
    }

    private func cardLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.font(.label))
            .foregroundStyle(theme.palette.textSecondary)
            .textCase(theme.typography.labelCase)
            .tracking(theme.typography.labelTracking)
    }
}

// MARK: - ContributionDetector
//
// Detects the owner's real monthly contribution from the ledger: the average net inflow into
// the linked (investment) accounts over the last 6 months, counting only transfer legs
// (rows with `transferID != nil` whose `accountID` is a linked account — the transfer leg
// convention verified in docs/PROTOCOL.md / BudgetDatabase). Paged through the existing
// `AppStore.transactions(_:)` read, never touching SQLite directly.

@MainActor
enum ContributionDetector {
    /// Months of history averaged over.
    static let monthsWindow = 6

    /// Average monthly net transfer inflow into the linked accounts; nil when there are no
    /// linked accounts or the net flow isn't positive (nothing worth suggesting).
    static func detectedMonthlyContribution(store: AppStore,
                                            linkedAccountIDs: [String]) async -> Money? {
        guard !linkedAccountIDs.isEmpty else { return nil }
        let window = BudgetMonth.current.advanced(by: -(monthsWindow - 1))...BudgetMonth.current
        let pageSize = 500
        var total = Money.zero
        for accountID in linkedAccountIDs {
            var offset = 0
            while true {
                let page = await store.transactions(
                    TransactionQuery(accountID: accountID, months: window,
                                     limit: pageSize, offset: offset))
                guard !Task.isCancelled else { return nil }
                for transaction in page where transaction.transferID != nil {
                    total = total + transaction.amount
                }
                if page.count < pageSize { break }
                offset += page.count
            }
        }
        let monthly = Money(cents: total.cents / Int64(monthsWindow))
        return monthly.cents > 0 ? monthly : nil
    }
}
