import SwiftUI

// MARK: - HouseholdOverviewSection
//
// The Overview face of the Household Plan: the FI gauge, the four alerts Retiron shows at the top
// of its own Overview tab, the two charts (net worth over the ages, income by source), the down
// payment tracker, and the two houses.
//
// Everything here reads from an already-computed `HouseholdPlanResult`. No math beyond picking a
// row and dividing, so the section can be rebuilt as often as SwiftUI likes.

struct HouseholdOverviewSection: View {
    let plan: HouseholdPlanResult

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: theme.layout.cardSpacing) {
            heroCard
            alertsCard
            HouseholdNetWorthChart(plan: plan)
            HouseholdIncomeChart(plan: plan)
            downPaymentCard
            realEstateCard
        }
    }

    // MARK: Hero

    private var heroCard: some View {
        let summary = plan.summary
        let targetAge = plan.config.targetRetirementAge
        return VStack(alignment: .leading, spacing: theme.layout.spacing) {
            cardLabel("Financial Independence")
            HStack(spacing: theme.layout.spacing) {
                GaugeArc(progress: summary.fiPct / 100,
                         label: Self.percentText(summary.fiPct),
                         detail: "at \(targetAge)")
                    .frame(width: 120, height: 120)
                Spacer(minLength: theme.layout.spacing)
                VStack(alignment: .trailing, spacing: theme.layout.spacing * 0.75) {
                    statPair("Portfolio at \(targetAge)", Money(clampedDollars: summary.portfolioAtTarget))
                    statPair("Net worth at \(targetAge)", Money(clampedDollars: summary.netWorthAtTarget))
                }
            }
            Text(heroSentence)
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedCard()
    }

    private var heroSentence: String {
        let targetAge = plan.config.targetRetirementAge
        let pct = plan.summary.fiPct
        if pct >= 100 {
            return "On these numbers you have enough to stop at \(targetAge), with the Atlanta rent still coming in on top."
        }
        if pct >= 75 {
            return "Close. A little more saved, or a slightly smaller year of spending, closes the gap by \(targetAge)."
        }
        return "The plan does not get all the way there by \(targetAge) yet. The years and debt sections show where the money goes."
    }

    private func statPair(_ label: String, _ amount: Money) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            cardLabel(label)
            AmountText(amount, style: .title, colorized: false)
                .minimumScaleFactor(0.6)
        }
    }

    // MARK: Alerts

    /// One line of the "what does this plan actually say" list. `amount` is always rendered
    /// through AmountText, so privacy mode holds and the copy stays free of hardcoded currency.
    private struct PlanNote: Identifiable {
        enum Kind {
            case good, warn, info

            var icon: String {
                switch self {
                case .good: return "checkmark.circle"
                case .warn: return "exclamationmark.triangle"
                case .info: return "info.circle"
                }
            }
        }

        var id: String { title }
        var kind: Kind
        var title: String
        var message: String
        var amount: Money
        var amountCaption: String
    }

    private var alertsCard: some View {
        let items = alerts
        return VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            cardLabel("What This Plan Says")
            ForEach(Array(items.enumerated()), id: \.element.id) { index, alert in
                alertRow(alert)
                if index < items.count - 1 {
                    Rectangle()
                        .fill(theme.palette.separator)
                        .frame(height: 1)
                }
            }
        }
        .themedCard()
    }

    private func alertRow(_ alert: PlanNote) -> some View {
        HStack(alignment: .top, spacing: theme.layout.spacing * 0.75) {
            Image(systemName: alert.kind.icon)
                .font(theme.font(.title))
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color(for: alert.kind))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(alert.message)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: theme.layout.spacing * 0.5)
            VStack(alignment: .trailing, spacing: 2) {
                AmountText(alert.amount, style: .body, colorized: false)
                Text(alert.amountCaption)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func color(for kind: PlanNote.Kind) -> Color {
        switch kind {
        case .good: return theme.palette.positive
        case .warn: return theme.palette.warning
        case .info: return theme.palette.accent
        }
    }

    /// The same four readings Retiron puts at the top of its Overview, in plain words.
    private var alerts: [PlanNote] {
        let config = plan.config
        var items: [PlanNote] = []

        // 1. The down payment, measured the year before the planned purchase.
        if let dpRow = row(at: max(config.tacBuyYear - 1, 0)) {
            let onTrack = dpRow.dpSaved >= dpRow.dpTarget
            items.append(PlanNote(kind: onTrack ? .good : .warn,
                                  title: onTrack ? "Down payment on track" : "Down payment is short",
                                  message: onTrack
                                      ? "That covers the deposit on the Tacoma house the year before you buy."
                                      : "Clearing the cards and the loans sooner is what frees this up.",
                                  amount: Money(clampedDollars: dpRow.dpSaved),
                                  amountCaption: "by \(dpRow.calendarYear)"))
        }

        // 2. Atlanta as a rental, in the first year it is one.
        if let rentRow = row(at: config.tacBuyYear) {
            let positive = rentRow.netRentMonthly >= 0
            items.append(PlanNote(kind: .info,
                                  title: positive ? "Atlanta pays for itself" : "Atlanta costs you a little",
                                  message: "Rent after the mortgage, the taxes and the running costs, in the first year you let it.",
                                  amount: Money(clampedDollars: rentRow.netRentMonthly),
                                  amountCaption: "a month"))
        }

        // 3. Financial independence at the target age.
        let pct = plan.summary.fiPct
        items.append(PlanNote(kind: pct >= 100 ? .good : .warn,
                              title: pct >= 100
                                  ? "Enough to stop at \(config.targetRetirementAge)"
                                  : "Not quite enough at \(config.targetRetirementAge)",
                              message: "You need 25 years of spending saved. This plan reaches \(Self.percentText(pct)) of it.",
                              amount: Money(clampedDollars: plan.summary.fiTarget),
                              amountCaption: "the target"))

        // 4. What Washington's missing income tax is worth today.
        if let first = plan.rows.first {
            let saving = (first.baseA + first.bonusA) * config.stateTaxPct / 100
            items.append(PlanNote(kind: .info,
                                  title: "Washington takes no income tax",
                                  message: "That is what Georgia takes out of your pay at today's salary.",
                                  amount: Money(clampedDollars: saving),
                                  amountCaption: "a year"))
        }
        return items
    }

    // MARK: Down payment

    private var downPaymentCard: some View {
        let now = plan.rows.first
        let saved = now?.dpSaved ?? 0
        let target = now?.dpTarget ?? 0
        let fraction = target > 0 ? min(max(saved / target, 0), 1) : 0
        return VStack(alignment: .leading, spacing: theme.layout.spacing) {
            cardLabel("Down Payment")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                AmountText(Money(clampedDollars: saved), style: .title, colorized: false)
                Text("of")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                AmountText(Money(clampedDollars: target), style: .body, colorized: false)
                Spacer(minLength: theme.layout.spacing)
                Text(Self.percentText(fraction * 100))
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: fraction)
            }
            progressBar(fraction)
            Text(downPaymentSentence)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedCard()
    }

    private var downPaymentSentence: String {
        let config = plan.config
        let buyYear = config.baseYear + config.tacBuyYear
        let percentDown = Self.percentText(config.tacDownPct)
        guard let hitIndex = plan.summary.dpHitYearIndex else {
            return "That is \(percentDown) down on the Tacoma house. The pot does not reach it inside this plan, so a smaller deposit or a later move is what makes it work."
        }
        let hitYear = config.baseYear + hitIndex
        if hitIndex <= config.tacBuyYear {
            return "That is \(percentDown) down on the Tacoma house. You get there in \(hitYear), and you plan to buy in \(buyYear)."
        }
        return "That is \(percentDown) down on the Tacoma house. You get there in \(hitYear), which is after the \(buyYear) you planned to buy."
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
        .animation(reduceMotion ? nil : theme.motion.spring, value: fraction)
        .accessibilityHidden(true)
    }

    // MARK: Real estate

    private var realEstateCard: some View {
        let config = plan.config
        let today = plan.rows.first
        let rentRow = row(at: config.tacBuyYear)
        let loan = config.tacPrice * (1 - config.tacDownPct / 100)
        let payment = HouseholdPlanner.mortgagePayment(principal: loan,
                                                       annualRatePct: config.tacRatePct,
                                                       years: config.mortgageTermYears)
        return VStack(alignment: .leading, spacing: theme.layout.spacing) {
            cardLabel("The Two Houses")
            VStack(spacing: theme.layout.spacing * 0.5) {
                houseHeader("Atlanta", systemImage: "house")
                moneyRow("Worth today", Money(clampedDollars: today?.atlValue ?? 0))
                moneyRow("Your share of it", Money(clampedDollars: today?.atlEquity ?? 0))
                moneyRow("Rent after costs", Money(clampedDollars: rentRow?.netRentMonthly ?? 0),
                         caption: "a month once you move out")
            }
            Rectangle()
                .fill(theme.palette.separator)
                .frame(height: 1)
            VStack(spacing: theme.layout.spacing * 0.5) {
                houseHeader("Tacoma", systemImage: "house.lodge")
                moneyRow("Asking price", Money(clampedDollars: config.tacPrice))
                moneyRow("Mortgage payment", Money(clampedDollars: payment), caption: "a month")
                HStack {
                    Text("Bought in")
                        .font(theme.font(.body))
                        .foregroundStyle(theme.palette.textPrimary)
                    Spacer(minLength: theme.layout.spacing)
                    Text(String(config.baseYear + config.tacBuyYear))
                        .font(theme.font(.headline))
                        .foregroundStyle(theme.palette.textPrimary)
                        .monospacedDigit()
                }
                .frame(minHeight: 44)
            }
        }
        .themedCard()
    }

    private func houseHeader(_ name: String, systemImage: String) -> some View {
        HStack(spacing: theme.layout.spacing * 0.5) {
            Image(systemName: systemImage)
                .font(theme.font(.body))
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .fontWeight(theme.icons.weight)
                .foregroundStyle(theme.palette.accent)
                .accessibilityHidden(true)
            Text(name)
                .font(theme.font(.headline))
                .foregroundStyle(theme.palette.textPrimary)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 32)
    }

    private func moneyRow(_ label: String, _ amount: Money, caption: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textPrimary)
                if let caption {
                    Text(caption)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            Spacer(minLength: theme.layout.spacing)
            AmountText(amount, style: .body, colorized: false)
        }
        .frame(minHeight: 44)
    }

    // MARK: Helpers

    private func row(at index: Int) -> HouseholdYear? {
        plan.rows.first { $0.yearIndex == index }
    }

    private func cardLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.font(.label))
            .foregroundStyle(theme.palette.textSecondary)
            .textCase(theme.typography.labelCase)
            .tracking(theme.typography.labelTracking)
    }

    static func percentText(_ value: Double) -> String {
        let safe = value.isFinite ? min(max(value, 0), 999) : 0
        return (safe / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}

// MARK: - HouseholdPlanEntryCard
//
// The doorway on the Retire tab. It runs the projection on the cached scenario so the card can
// show something true (FI percent at the target age, and the next thing the plan says happens)
// without waiting for Retiron. When Retiron has never been set up, the same card invites the
// owner to set it up instead.

struct HouseholdPlanEntryCard: View {
    @Environment(AppRouter.self) private var router
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme

    @State private var teaser: Teaser?

    private struct Teaser: Sendable, Equatable {
        var fiPct: Double
        var targetAge: Int
        var nextEvent: String?
        var nextEventYear: Int?
    }

    var body: some View {
        Button {
            router.push(preferences.retironEnabled ? .householdPlan : .retironSettings)
        } label: {
            HStack(spacing: theme.layout.spacing * 0.75) {
                Image(systemName: "house.and.flag")
                    .font(theme.font(.title))
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.palette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Household Plan")
                        .font(theme.font(.headline))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(subtitle)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        .accessibilityHint(preferences.retironEnabled
                           ? "Opens the household plan"
                           : "Opens the Retiron setup screen")
        .task(id: teaserKey) {
            await loadTeaser()
        }
    }

    private var teaserKey: String {
        "\(preferences.retironEnabled)|\(preferences.retironProfileCacheJSON)"
    }

    private var subtitle: String {
        guard preferences.retironEnabled else {
            return "Both salaries, both houses and the road to 55, kept in Retiron. Connect it here."
        }
        guard let teaser else {
            return "Both salaries, both houses and the road to 55."
        }
        let pct = HouseholdOverviewSection.percentText(teaser.fiPct)
        if let event = teaser.nextEvent, let year = teaser.nextEventYear {
            return "\(pct) of the way to stopping at \(teaser.targetAge). Next up: \(event.lowercased()) in \(year)."
        }
        return "\(pct) of the way to stopping at \(teaser.targetAge)."
    }

    /// Projects the cached scenario off the main actor. Nothing is fetched here: the card is a
    /// summary of what the phone already knows, and the full screen does the talking to Retiron.
    private func loadTeaser() async {
        guard preferences.retironEnabled,
              let data = RetironProfileData(jsonString: preferences.retironProfileCacheJSON) else {
            teaser = nil
            return
        }
        let config = RetironProfileMapper.config(from: data)
        let result = await Task.detached(priority: .utility) { () -> Teaser in
            let rows = HouseholdPlanner.project(config)
            let summary = HouseholdPlanner.fiSummary(rows: rows, config: config)
            // "Start" is not news; the first event after this year is.
            let next = rows.first { $0.yearIndex > 0 && !$0.events.isEmpty }
            return Teaser(fiPct: summary.fiPct,
                          targetAge: config.targetRetirementAge,
                          nextEvent: next?.events.first,
                          nextEventYear: next?.calendarYear)
        }.value
        guard !Task.isCancelled else { return }
        teaser = result
    }
}
