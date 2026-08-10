import SwiftUI

// MARK: - SpendHeatmapWidget
//
// A mini calendar of the current month where each day is a dot tinted by spending intensity —
// five steps of the theme accent over the quiet-day fill. Weekday-aligned to the user's
// calendar (first weekday respected), with today ringed in accent. Dots encode only relative
// intensity, so privacy mode needs no special handling. Tapping pushes Reports.

struct SpendHeatmapWidget: View {
    let span: WidgetSpan

    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var daily: [Int: Money] = [:]
    @State private var hasLoaded = false

    var body: some View {
        WidgetCardButton(action: { router.push(.reports) }) {
            content
        }
        .accessibilityHint("Opens reports")
        .task(id: store.accounts) {
            let map = await store.dailySpend(month: .current)
            guard !Task.isCancelled else { return }
            daily = map
            hasLoaded = true
        }
    }

    // MARK: Calendar math

    private var month: BudgetMonth { .current }

    private var maxSpendCents: Int64 {
        daily.values.map { $0.magnitude.cents }.max() ?? 0
    }

    /// 0 = no spending; 1…5 = intensity buckets of the day's share of the biggest spend day.
    private func intensity(day: Int) -> Int {
        let cents = daily[day]?.magnitude.cents ?? 0
        guard cents > 0, maxSpendCents > 0 else { return 0 }
        let fraction = Double(cents) / Double(maxSpendCents)
        return min(max(Int((fraction * 5).rounded(.up)), 1), 5)
    }

    private func dotColor(day: Int) -> Color {
        let level = intensity(day: day)
        guard level > 0 else { return theme.palette.fill }
        return theme.palette.accent.opacity(Double(level) * 0.2)
    }

    /// Leading blanks so day 1 lands under its weekday column.
    private var leadingBlanks: Int {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: month.firstDay.date)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    /// Day numbers padded into full weeks (0 = blank cell).
    private var weeks: [[Int]] {
        var cells = Array(repeating: 0, count: leadingBlanks)
        cells.append(contentsOf: 1...month.dayCount)
        while cells.count % 7 != 0 {
            cells.append(0)
        }
        return stride(from: 0, to: cells.count, by: 7).map { start in
            Array(cells[start..<min(start + 7, cells.count)])
        }
    }

    private var weekdayInitials: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        guard symbols.count == 7 else { return [] }
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            HStack {
                WidgetLabel("Spend Heatmap")
                Spacer(minLength: theme.layout.spacing * 0.5)
                Text(month.shortName)
                    .font(theme.font(.label))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            if !hasLoaded {
                VStack {
                    Spacer(minLength: 0)
                    ProgressView()
                        .tint(theme.palette.accent)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
            } else {
                grid
                if span == .s2x2 && maxSpendCents == 0 {
                    Text("No spending yet — a pristine month.")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: daily)
    }

    private var grid: some View {
        VStack(spacing: 4) {
            if span == .s2x2 {
                HStack(spacing: 4) {
                    ForEach(Array(weekdayInitials.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(theme.font(.label))
                            .foregroundStyle(theme.palette.textTertiary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 4) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        dayCell(day)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heatmapAccessibilityLabel)
    }

    @ViewBuilder
    private func dayCell(_ day: Int) -> some View {
        if day == 0 {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Circle()
                .fill(dotColor(day: day))
                .overlay {
                    if day == BudgetDay.today.dayComponent {
                        Circle().strokeBorder(theme.palette.accent, lineWidth: 1.5)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var heatmapAccessibilityLabel: String {
        let activeDays = daily.values.filter { $0.magnitude.cents > 0 }.count
        if activeDays == 0 {
            return "Spending heatmap for \(month.displayName): no spending yet"
        }
        return "Spending heatmap for \(month.displayName): spending on \(activeDays) days"
    }
}
