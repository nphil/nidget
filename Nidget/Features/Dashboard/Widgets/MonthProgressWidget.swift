import SwiftUI

// MARK: - MonthProgressWidget
//
// How deep into the month you are, and whether spending is keeping pace: a day-of-month
// progress bar (accent gradient) with a tick marking the spent fraction of the budget, plus an
// ahead/behind chip. The pace comparison only renders when the Budget tab is looking at the
// real current month — pacing against a browsed past month would be nonsense. Tapping opens
// the Budget tab.

struct MonthProgressWidget: View {
    let span: WidgetSpan

    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WidgetCardButton(action: { router.tab = .budget }) {
            content
        }
        .accessibilityHint("Opens the budget")
    }

    // MARK: Data

    private var month: BudgetMonth { .current }
    private var dayOfMonth: Int { BudgetDay.today.dayComponent }
    private var dayCount: Int { max(month.dayCount, 1) }

    private var monthFraction: Double {
        min(max(Double(dayOfMonth) / Double(dayCount), 0), 1)
    }

    /// Spent ÷ budgeted for the true current month; nil while loading, browsing another month,
    /// or when nothing is budgeted.
    private var spentFraction: Double? {
        guard store.currentMonth == .current,
              let snapshot = store.monthSnapshot,
              snapshot.totalBudgeted.cents > 0 else { return nil }
        return snapshot.totalSpent.magnitude.doubleValue / snapshot.totalBudgeted.doubleValue
    }

    private enum Pace {
        case under, on, over

        var text: String {
            switch self {
            case .under: return "Under pace"
            case .on: return "On pace"
            case .over: return "Spending fast"
            }
        }
    }

    private var pace: Pace? {
        guard let spentFraction else { return nil }
        if spentFraction > monthFraction + 0.04 { return .over }
        if spentFraction < monthFraction - 0.04 { return .under }
        return .on
    }

    private func paceColor(_ pace: Pace) -> Color {
        switch pace {
        case .under: return theme.palette.positive
        case .on: return theme.palette.accent
        case .over: return theme.palette.warning
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if span == .s1x1 {
            compactBody
        } else {
            wideBody
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            WidgetLabel(month.shortName)
            Spacer(minLength: 0)
            Text("Day \(dayOfMonth)")
                .font(theme.font(.display))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : theme.motion.snappy, value: dayOfMonth)
            Text("of \(dayCount)")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
            progressBar
            if let pace {
                Text(pace.text)
                    .font(theme.font(.label))
                    .foregroundStyle(paceColor(pace))
                    .lineLimit(1)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: spentFraction)
    }

    private var wideBody: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            HStack {
                WidgetLabel("Month Progress")
                Spacer(minLength: theme.layout.spacing * 0.5)
                if let pace {
                    paceChip(pace)
                }
            }
            Spacer(minLength: 0)
            Text("Day \(dayOfMonth) of \(dayCount)")
                .font(theme.font(.title))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : theme.motion.snappy, value: dayOfMonth)
            progressBar
            Text(footerText)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: spentFraction)
    }

    private var footerText: String {
        let elapsed = monthFraction.formatted(.percent.precision(.fractionLength(0)))
        guard let spentFraction else {
            return "\(elapsed) of \(month.displayName) gone"
        }
        let spent = spentFraction.formatted(.percent.precision(.fractionLength(0)))
        return "\(elapsed) of the month · \(spent) of the budget spent"
    }

    private func paceChip(_ pace: Pace) -> some View {
        Text(pace.text)
            .font(theme.font(.label))
            .foregroundStyle(paceColor(pace))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(paceColor(pace).opacity(0.14))
            }
            .lineLimit(1)
    }

    // MARK: Bar

    private var progressBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.palette.fill)
                Capsule()
                    .fill(theme.accentGradient)
                    .frame(width: max(width * monthFraction, 8))
                if let spentFraction, let pace {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(paceColor(pace))
                        .frame(width: 3, height: 14)
                        .offset(x: min(max(width * spentFraction, 0), width - 3))
                }
            }
        }
        .frame(height: 14)
        .animation(reduceMotion ? nil : theme.motion.spring, value: monthFraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Month progress")
        .accessibilityValue(Text(monthFraction.formatted(.percent.precision(.fractionLength(0)))))
    }
}
