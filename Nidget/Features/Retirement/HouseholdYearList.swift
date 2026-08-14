import SwiftUI

// MARK: - HouseholdYearList
//
// The Years face of the Household Plan. Retiron shows this as a fifteen column table, which is a
// desktop answer; on a phone each year is a card. Collapsed it reads year, ages, net worth and
// what happened; tapped it opens into the full set of numbers as labelled rows.
//
// The year the primary earner reaches the target retirement age is drawn with an accent border,
// because that is the row the whole plan is aimed at.

struct HouseholdYearList: View {
    let plan: HouseholdPlanResult

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expanded: Set<Int> = []

    var body: some View {
        VStack(spacing: theme.layout.cardSpacing) {
            headerCard
            ForEach(plan.rows) { row in
                yearCard(row)
            }
        }
    }

    // MARK: Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            cardLabel("Year By Year")
            Text("One card per year, oldest first. Tap any of them to see the whole picture for that year.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedCard()
    }

    // MARK: One year

    private func yearCard(_ row: HouseholdYear) -> some View {
        let isOpen = expanded.contains(row.yearIndex)
        let isTarget = row.ageA == plan.config.targetRetirementAge
        return VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            Button {
                toggle(row.yearIndex)
            } label: {
                summaryRow(row, isOpen: isOpen, isTarget: isTarget)
            }
            .buttonStyle(.plain)
            chipRow(row, isTarget: isTarget)
            if isOpen {
                Rectangle()
                    .fill(theme.palette.separator)
                    .frame(height: 1)
                detailRows(row)
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

    // MARK: Detail

    @ViewBuilder
    private func detailRows(_ row: HouseholdYear) -> some View {
        VStack(spacing: theme.layout.spacing * 0.4) {
            moneyRow("\(plan.config.personA.name) total pay", row.totalCompA)
            moneyRow("\(plan.config.personB.name) total pay", row.totalCompB)
            moneyRow("Household gross", row.grossIncome)
            moneyRow("Take home", row.takeHome)
            moneyRow("Tax", row.totalTax)
            moneyRow("Retirement accounts", row.portfolio)
            moneyRow("Brokerage", row.brokerage)
            moneyRow("Atlanta equity", row.atlEquity)
            if row.tacEquity > 0 {
                moneyRow("Tacoma equity", row.tacEquity)
            }
            moneyRow("Cards", row.ccBalance, clearedWhenZero: true)
            moneyRow("Loans", row.slBalance, clearedWhenZero: true)
            if row.netRentMonthly != 0 {
                moneyRow("Rent after costs", row.netRentMonthly, caption: "a month")
            }
            moneyRow("Housing", row.housingCost, caption: "for the year")
            moneyRow("Left over", row.freeCash, caption: "after everything")
            if row.dpTarget > 0 && row.dpSaved < row.dpTarget {
                moneyRow("Down payment pot", row.dpSaved)
            }
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

    private func cardLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.font(.label))
            .foregroundStyle(theme.palette.textSecondary)
            .textCase(theme.typography.labelCase)
            .tracking(theme.typography.labelTracking)
    }

    private static func percentText(_ value: Double) -> String {
        let safe = value.isFinite ? min(max(value, -999), 999) : 0
        return (safe / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}
