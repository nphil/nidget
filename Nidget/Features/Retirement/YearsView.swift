import SwiftUI

// MARK: - YearsView
//
// "The Plan": the household projection year by year, pushed via `Route.retireYears`. The header
// card states the two things the plan says in plain words (the down payment timing and what the
// state tax move is worth), then the down payment tracker, the two houses, the income chart, and
// one expandable card per projected year.
//
// The glance's Down payment tile lands here too: it sets `pendingYearsAnchor` on the model before
// pushing, and this screen consumes it once, scrolls to the down payment card and pulses its
// accent border so the tap visibly answered.

struct YearsView: View {
    /// Optional on purpose: a force read traps if this destination is ever built outside the
    /// Retire tab's injected stack, so the model is unwrapped once and the screen shows a
    /// placeholder instead of crashing.
    @Environment(HouseholdPlanModel.self) private var household: HouseholdPlanModel?

    var body: some View {
        if let household {
            YearsContent(household: household)
        } else {
            RetirePlaceholderScreen(title: "The Plan")
        }
    }
}

private struct YearsContent: View {
    let household: HouseholdPlanModel

    @Environment(\.theme) private var theme
    @Environment(\.privacyMode) private var privacyMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expanded: Set<Int> = []
    @State private var isPulsing = false

    var body: some View {
        Group {
            if let plan = household.plan {
                planScroll(plan)
            } else {
                loadingView
            }
        }
        .themedScreen()
        .navigationTitle("The Plan")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: household.recomputeKey) {
            await household.recompute()
        }
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

    // MARK: Layout

    private func planScroll(_ plan: HouseholdPlanResult) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: theme.layout.cardSpacing) {
                    headerCard(plan)
                    downPaymentCard(plan)
                        .id(YearsAnchor.downPayment)
                    housesCard(plan)
                    HouseholdIncomeChart(rows: plan.rows, config: plan.config)
                    ForEach(plan.rows) { row in
                        yearCard(row, config: plan.config)
                    }
                }
                .padding(.horizontal, theme.layout.cardPadding)
                .padding(.top, theme.layout.spacing * 0.5)
                .padding(.bottom, theme.layout.cardSpacing)
            }
            .scrollIndicators(.hidden)
            .task { await consumeAnchor(proxy) }
        }
    }

    /// Consumes the tile's scroll target exactly once: clear it first so a later visit starts at
    /// the top, then scroll and pulse.
    private func consumeAnchor(_ proxy: ScrollViewProxy) async {
        guard let anchor = household.pendingYearsAnchor else { return }
        household.pendingYearsAnchor = nil
        // One beat for the pushed screen to lay out, or scrollTo has nothing to measure.
        try? await Task.sleep(for: .milliseconds(80))
        if reduceMotion {
            proxy.scrollTo(anchor, anchor: .center)
        } else {
            withAnimation(theme.motion.snappy) {
                proxy.scrollTo(anchor, anchor: .center)
            }
        }
        isPulsing = true
        try? await Task.sleep(for: .seconds(1.2))
        isPulsing = false
    }

    // MARK: Header

    private func headerCard(_ plan: HouseholdPlanResult) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
            SectionHeader("What this plan says")
            Text(headerDownPaymentSentence(plan))
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let tax = taxSentence(plan) {
                Text(tax)
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .privacySensitive()
            }
        }
        .themedCard()
    }

    /// Whether the pot gets there before, in, or after the year the house is bought. The header
    /// and the down payment card both read the verdict from here, so they can never disagree at
    /// the boundary where the two years are the same.
    private enum DownPaymentTiming {
        case before, sameYear, after

        init(hitIndex: Int, buyIndex: Int) {
            if hitIndex < buyIndex {
                self = .before
            } else if hitIndex == buyIndex {
                self = .sameYear
            } else {
                self = .after
            }
        }
    }

    private func headerDownPaymentSentence(_ plan: HouseholdPlanResult) -> String {
        let config = plan.config
        let buyYear = config.baseYear + config.tacBuyYear
        guard let hitIndex = plan.summary.dpHitYearIndex else {
            return "The down payment pot does not reach its target inside this plan."
        }
        let hitYear = config.baseYear + hitIndex
        switch DownPaymentTiming(hitIndex: hitIndex, buyIndex: config.tacBuyYear) {
        case .before:
            return "The down payment is there in \(hitYear), before the \(buyYear) purchase."
        case .sameYear:
            return "The down payment lands in \(buyYear), the same year you plan to buy."
        case .after:
            return "The down payment gets there in \(hitYear), after the \(buyYear) purchase you planned."
        }
    }

    /// The amount rides inside flowing copy, where AmountText cannot go, so privacy mode is
    /// honored by hand and the row is marked privacy sensitive above. nil when the plan never
    /// reaches the move, so the header never promises a saving the years below never show.
    private func taxSentence(_ plan: HouseholdPlanResult) -> String? {
        guard let first = plan.rows.first,
              plan.rows.contains(where: \.inWashington) else { return nil }
        // The whole household stops paying it, not just the first earner. Wages only, exactly
        // the basis `HouseholdPlanner` taxes, so the sentence and the years agree to the dollar.
        let wages = first.baseA + first.bonusA + first.baseB + first.bonusB
        let saving = wages * plan.config.stateTaxPct / 100
        guard saving > 0 else {
            return "The plan already pays no state income tax."
        }
        // "About" earns its rounding: the nearest hundred reads better than exact dollars.
        let rounded = (saving / 100).rounded() * 100
        let amount = privacyMode ? "••••"
            : CurrencyFormatter.string(Money(clampedDollars: rounded), format: .whole)
        return "No state income tax after the move saves about \(amount) a year."
    }

    // MARK: Down payment

    private func downPaymentCard(_ plan: HouseholdPlanResult) -> some View {
        let now = plan.rows.first
        let saved = now?.dpSaved ?? 0
        let target = now?.dpTarget ?? 0
        let fraction = target > 0 ? min(max(saved / target, 0), 1) : 0
        return VStack(alignment: .leading, spacing: theme.layout.spacing) {
            SectionHeader("Down payment")
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
            Text(dpCardSentence(plan))
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedCard()
        .overlay {
            theme.cardShape
                .strokeBorder(theme.palette.accent, lineWidth: 2)
                .opacity(isPulsing ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: isPulsing)
        }
    }

    private func dpCardSentence(_ plan: HouseholdPlanResult) -> String {
        let config = plan.config
        let buyYear = config.baseYear + config.tacBuyYear
        let percentDown = Self.percentText(config.tacDownPct)
        guard let hitIndex = plan.summary.dpHitYearIndex else {
            return "That is \(percentDown) down on the \(HouseholdCopy.nextCity) house. The pot does not reach it inside this plan, so a smaller deposit or a later move is what makes it work."
        }
        let hitYear = config.baseYear + hitIndex
        let lead = "That is \(percentDown) down on the \(HouseholdCopy.nextCity) house."
        switch DownPaymentTiming(hitIndex: hitIndex, buyIndex: config.tacBuyYear) {
        case .before:
            return "\(lead) You get there in \(hitYear), before the \(buyYear) purchase."
        case .sameYear:
            return "\(lead) You get there in \(buyYear), the same year you plan to buy."
        case .after:
            return "\(lead) You get there in \(hitYear), which is after the \(buyYear) you planned to buy."
        }
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

    // MARK: The two houses

    private func housesCard(_ plan: HouseholdPlanResult) -> some View {
        let config = plan.config
        let today = plan.rows.first
        let rentRow = plan.rows.first { $0.yearIndex == config.tacBuyYear }
        let loan = config.tacPrice * (1 - config.tacDownPct / 100)
        let payment = HouseholdPlanner.mortgagePayment(principal: loan,
                                                       annualRatePct: config.tacRatePct,
                                                       years: config.mortgageTermYears)
        return VStack(alignment: .leading, spacing: theme.layout.spacing) {
            SectionHeader("The two houses")
            VStack(spacing: theme.layout.spacing * 0.5) {
                houseHeader(HouseholdCopy.homeCity, systemImage: "house")
                houseRow("Worth today", today?.atlValue ?? 0)
                houseRow("Your share of it", today?.atlEquity ?? 0)
                houseRow("Rent after costs", rentRow?.netRentMonthly ?? 0,
                         caption: "a month once you move out")
            }
            separator
            VStack(spacing: theme.layout.spacing * 0.5) {
                houseHeader(HouseholdCopy.nextCity, systemImage: "house.lodge")
                houseRow("Asking price", config.tacPrice)
                houseRow("Mortgage payment", payment, caption: "a month")
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
            separator
            Text(rentalFooter(rentRow))
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedCard()
    }

    private func rentalFooter(_ rentRow: HouseholdYear?) -> String {
        guard let rentRow else {
            return "The \(HouseholdCopy.homeCity) house becomes a rental once you move out."
        }
        if rentRow.netRentMonthly >= 0 {
            return "Once you let it, the \(HouseholdCopy.homeCity) house pays for itself after the mortgage, the taxes and the running costs."
        }
        return "Once you let it, the \(HouseholdCopy.homeCity) house costs you a little each month after the mortgage, the taxes and the running costs."
    }

    private func houseRow(_ label: String, _ dollars: Double, caption: String? = nil) -> some View {
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
            AmountText(Money(clampedDollars: dollars), style: .body, colorized: false)
        }
        .frame(minHeight: 44)
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

    // MARK: One year

    private func yearCard(_ row: HouseholdYear, config: HouseholdPlanConfig) -> some View {
        let isOpen = expanded.contains(row.yearIndex)
        let isTarget = row.ageA == config.targetRetirementAge
        return VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            Button {
                toggle(row.yearIndex)
            } label: {
                summaryRow(row, isOpen: isOpen, isTarget: isTarget)
            }
            .buttonStyle(.plain)
            chipRow(row, isTarget: isTarget)
            if isOpen {
                separator
                detailClusters(row, config: config)
                    .transition(.opacity)
            }
        }
        .themedCard()
        .overlay {
            if isTarget {
                theme.cardShape.strokeBorder(theme.palette.accent.opacity(0.6), lineWidth: 1.5)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: isOpen)
    }

    private func summaryRow(_ row: HouseholdYear, isOpen: Bool, isTarget: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(row.calendarYear))
                    .font(theme.font(.headline))
                    .foregroundStyle(isTarget ? theme.palette.accent : theme.palette.textPrimary)
                    .monospacedDigit()
                Text("Ages \(row.ageA) and \(row.ageB)")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            Spacer(minLength: theme.layout.spacing)
            VStack(alignment: .trailing, spacing: 2) {
                AmountText(Money(clampedDollars: row.netWorth), style: .body, colorized: false)
                Text("net worth")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                .font(theme.font(.caption))
                .fontWeight(theme.icons.weight)
                .foregroundStyle(theme.palette.textTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    // MARK: Chips

    private func chipRow(_ row: HouseholdYear, isTarget: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.layout.spacing * 0.5) {
                savingsChip(row)
                if isTarget {
                    chip("Target age", color: theme.palette.accent)
                }
                ForEach(row.events, id: \.self) { event in
                    chip(event, color: theme.palette.textSecondary)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func savingsChip(_ row: HouseholdYear) -> some View {
        let rate = row.savingsRatePct
        let color = rate >= 20 ? theme.palette.positive : theme.palette.warning
        return chip("\(Self.percentText(rate)) saved", color: color)
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(theme.font(.caption))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background { Capsule().fill(color.opacity(0.14)) }
    }

    // MARK: Detail clusters

    /// The old fifteen row dump, regrouped so a year reads in order: what came in, what got
    /// saved, what is owned, what is owed, and how the year itself felt.
    private func detailClusters(_ row: HouseholdYear, config: HouseholdPlanConfig) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            cluster("Money in") {
                moneyRow("\(config.personA.name) total pay", row.totalCompA)
                moneyRow("\(config.personB.name) total pay", row.totalCompB)
                moneyRow("Household gross", row.grossIncome)
                moneyRow("Take home", row.takeHome)
                moneyRow("Tax", row.totalTax)
            }
            cluster("Saved") {
                moneyRow("Retirement accounts", row.portfolio)
                moneyRow("Brokerage", row.brokerage)
                if row.dpTarget > 0 && row.dpSaved < row.dpTarget {
                    moneyRow("Down payment pot", row.dpSaved)
                }
                percentRow("Savings rate", row.savingsRatePct)
            }
            cluster("Owned") {
                moneyRow("\(HouseholdCopy.homeCity) equity", row.atlEquity)
                if row.tacEquity > 0 {
                    moneyRow("\(HouseholdCopy.nextCity) equity", row.tacEquity)
                }
            }
            cluster("Owed") {
                moneyRow("Cards", row.ccBalance, clearedWhenZero: true)
                moneyRow("Loans", row.slBalance, clearedWhenZero: true)
            }
            cluster("The year itself") {
                moneyRow("Left over", row.freeCash, caption: "after everything")
                moneyRow("Housing", row.housingCost, caption: "for the year")
                if row.netRentMonthly != 0 {
                    moneyRow("Rent after costs", row.netRentMonthly, caption: "a month")
                }
            }
        }
    }

    private func cluster<Content: View>(_ label: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            SectionHeader(label)
            content()
        }
    }

    private func moneyRow(_ label: String, _ dollars: Double, caption: String? = nil,
                          clearedWhenZero: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textSecondary)
            Spacer(minLength: theme.layout.spacing)
            if clearedWhenZero && dollars <= 0 {
                Text("Cleared")
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.positive)
            } else {
                AmountText(Money(clampedDollars: dollars), style: .body, colorized: false)
            }
            if let caption {
                Text(caption)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .frame(minHeight: 32)
    }

    private func percentRow(_ label: String, _ percent: Double) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textSecondary)
            Spacer(minLength: theme.layout.spacing)
            Text(Self.percentText(percent))
                .font(theme.font(.headline))
                .foregroundStyle(theme.palette.textPrimary)
                .monospacedDigit()
        }
        .frame(minHeight: 32)
    }

    // MARK: Interaction

    private func toggle(_ index: Int) {
        Haptics.tick()
        let apply = {
            if expanded.contains(index) {
                expanded.remove(index)
            } else {
                expanded.insert(index)
            }
        }
        if reduceMotion {
            apply()
        } else {
            withAnimation(theme.motion.snappy) { apply() }
        }
    }

    // MARK: Helpers

    private var separator: some View {
        Rectangle()
            .fill(theme.palette.separator)
            .frame(height: 1)
    }

    private static func percentText(_ value: Double) -> String {
        let safe = value.isFinite ? min(max(value, -999), 999) : 0
        return (safe / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}
