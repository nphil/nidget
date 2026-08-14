import SwiftUI
import Charts

// MARK: - HouseholdNetWorthChart
//
// Everything the household owns and owes, plotted against the primary earner's age: net worth,
// the invested portfolio, the equity in the two houses, and the consumer debt drawn below the
// line because that is what it does to the total.
//
// Drag to scrub (`chartXSelection`, the same pattern as RetirementChart and NetWorthReport): the
// callout names the age and reads back the two numbers that matter at it.

struct HouseholdNetWorthChart: View {
    let plan: HouseholdPlanResult

    @Environment(\.theme) private var theme
    @Environment(\.privacyMode) private var privacyMode

    @State private var selectedAge: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            cardLabel("Net Worth Over Time")
            if plan.rows.count > 1 {
                chart
                legend
                Text("Debt is drawn below the line. Drag across the chart to read any year.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("There are not enough years in this plan to draw a curve.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .themedCard()
        .onChange(of: selectedAge) { oldValue, newValue in
            if oldValue == nil, newValue != nil { Haptics.tick() }
        }
    }

    // MARK: Chart

    private var chart: some View {
        let rows = plan.rows
        let minAge = Double(rows.first?.ageA ?? 0)
        let maxAge = Double(rows.last?.ageA ?? 1)
        let interpolation: InterpolationMethod = theme.chart.smoothLines ? .catmullRom : .linear
        let highest = rows.map { max($0.netWorth, max($0.liquidPortfolio, $0.realEstateEquity)) }.max() ?? 1
        let deepest = rows.map { -$0.totalDebt }.min() ?? 0
        let yMax = max(highest * 1.08, 1)
        let yMin = min(deepest * 1.2, 0)
        let nearest = nearestRow
        let targetAge = plan.config.targetRetirementAge

        return Chart {
            if Double(targetAge) > minAge && Double(targetAge) < maxAge {
                RuleMark(x: .value("Age", Double(targetAge)))
                    .foregroundStyle(theme.palette.accent.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            ForEach(rows) { row in
                LineMark(x: .value("Age", Double(row.ageA)),
                         y: .value("Net worth", row.netWorth),
                         series: .value("Series", "Net worth"))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(color(0))
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(rows) { row in
                LineMark(x: .value("Age", Double(row.ageA)),
                         y: .value("Portfolio", row.liquidPortfolio),
                         series: .value("Series", "Portfolio"))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(color(1))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            ForEach(rows) { row in
                LineMark(x: .value("Age", Double(row.ageA)),
                         y: .value("Houses", row.realEstateEquity),
                         series: .value("Series", "Houses"))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(color(2))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            ForEach(rows) { row in
                LineMark(x: .value("Age", Double(row.ageA)),
                         y: .value("Debt", -row.totalDebt),
                         series: .value("Series", "Debt"))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(theme.palette.negative)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            if let nearest {
                RuleMark(x: .value("Age", Double(nearest.ageA)))
                    .foregroundStyle(theme.palette.textTertiary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 6) {
                        callout(nearest)
                    }
                PointMark(x: .value("Age", Double(nearest.ageA)),
                          y: .value("Net worth", nearest.netWorth))
                    .foregroundStyle(color(0))
                    .symbolSize(90)
            }
        }
        .chartXScale(domain: minAge...maxAge)
        .chartYScale(domain: yMin...yMax)
        .chartXSelection(value: $selectedAge)
        .chartXAxis {
            AxisMarks(values: .stride(by: 5)) { value in
                if theme.chart.gridLines { AxisGridLine() }
                AxisValueLabel {
                    if let age = value.as(Double.self) {
                        Text(String(Self.clampedAge(age)))
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

    private var nearestRow: HouseholdYear? {
        guard let selectedAge else { return nil }
        return plan.rows.min {
            abs(Double($0.ageA) - selectedAge) < abs(Double($1.ageA) - selectedAge)
        }
    }

    private func callout(_ row: HouseholdYear) -> some View {
        VStack(spacing: 2) {
            Text("\(row.calendarYear), age \(row.ageA)")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
            AmountText(Money(clampedDollars: row.netWorth), style: .caption, colorized: false)
            HStack(spacing: 3) {
                AmountText(Money(clampedDollars: row.liquidPortfolio), style: .caption, colorized: false)
                Text("invested")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background { theme.controlShape.fill(theme.palette.surfaceElevated) }
    }

    // MARK: Legend

    private var legend: some View {
        HStack(spacing: theme.layout.spacing) {
            legendDot("Net worth", color(0))
            legendDot("Invested", color(1))
            legendDot("Houses", color(2))
            legendDot("Debt", theme.palette.negative)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func legendDot(_ label: String, _ swatch: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(swatch)
                .frame(width: 8, height: 8)
            Text(label)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
                .lineLimit(1)
        }
    }

    // MARK: Helpers

    private func color(_ index: Int) -> Color {
        theme.palette.chart[index % theme.palette.chart.count]
    }

    private func cardLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.font(.label))
            .foregroundStyle(theme.palette.textSecondary)
            .textCase(theme.typography.labelCase)
            .tracking(theme.typography.labelTracking)
    }

    private static func clampedAge(_ age: Double) -> Int {
        guard age.isFinite else { return 0 }
        return Int(min(max(age.rounded(), 0), 150))
    }

    private static func compactMoney(_ dollars: Double) -> String {
        // Clamp well inside Int64 before converting (LESSONS_FROM_STASHY §2: `isFinite` alone
        // doesn't make a Double→Int conversion safe).
        let cents = (dollars * 100).rounded()
        let clamped = cents.isFinite ? min(max(cents, -9e17), 9e17) : 0
        return CurrencyFormatter.string(Money(cents: Int64(clamped)), format: .compact)
    }
}

// MARK: - HouseholdIncomeChart
//
// Where the household's money comes from, year by year: the primary salary, the bonus and RSUs on
// top of it, the second earner, and the Atlanta rent once the house is let. Stacked bars, because
// the question is both "how much" and "made of what".

struct HouseholdIncomeChart: View {
    let plan: HouseholdPlanResult

    @Environment(\.theme) private var theme
    @Environment(\.privacyMode) private var privacyMode

    /// One block of one bar.
    private struct Slice: Identifiable {
        var id: String
        var age: Int
        var source: String
        var amount: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            cardLabel("Income By Source")
            if plan.rows.isEmpty {
                Text("There is nothing to chart until the plan has a year in it.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
            } else {
                chart
                legend
            }
        }
        .themedCard()
    }

    // MARK: Chart

    private var chart: some View {
        let slices = self.slices
        let sources = sourceNames
        return Chart(slices) { slice in
            BarMark(x: .value("Age", slice.age),
                    y: .value("Income", slice.amount))
                .foregroundStyle(by: .value("Source", slice.source))
                .cornerRadius(theme.chart.barCornerRadius)
        }
        .chartForegroundStyleScale(domain: sources, range: sources.indices.map { color($0) })
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: axisAges) { value in
                if theme.chart.gridLines { AxisGridLine() }
                AxisValueLabel {
                    if let age = value.as(Int.self) {
                        Text(String(age))
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
        .frame(height: 200)
        .privacySensitive()
        .blur(radius: privacyMode ? 8 : 0)
        .accessibilityHidden(true)
    }

    private var sourceNames: [String] {
        let nameA = plan.config.personA.name
        let nameB = plan.config.personB.name
        return ["\(nameA) salary", "Bonus and stock", nameB, "Atlanta rent"]
    }

    private var slices: [Slice] {
        let sources = sourceNames
        var built: [Slice] = []
        built.reserveCapacity(plan.rows.count * sources.count)
        for row in plan.rows {
            let amounts = [row.baseA, row.bonusA + row.rsuA, row.totalCompB,
                           max(0, row.netRentMonthly * 12)]
            for (index, source) in sources.enumerated() where amounts[index] > 0 {
                built.append(Slice(id: "\(row.yearIndex)-\(index)", age: row.ageA,
                                   source: source, amount: amounts[index]))
            }
        }
        return built
    }

    /// Label every fifth age so 25 bars keep a readable axis.
    private var axisAges: [Int] {
        plan.rows.map(\.ageA).filter { $0 % 5 == 0 }
    }

    // MARK: Legend

    private var legend: some View {
        let sources = sourceNames
        return HStack(spacing: theme.layout.spacing * 0.75) {
            ForEach(Array(sources.enumerated()), id: \.element) { index, source in
                HStack(spacing: 4) {
                    Circle()
                        .fill(color(index))
                        .frame(width: 8, height: 8)
                    Text(source)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    // MARK: Helpers

    private func color(_ index: Int) -> Color {
        theme.palette.chart[index % theme.palette.chart.count]
    }

    private func cardLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.font(.label))
            .foregroundStyle(theme.palette.textSecondary)
            .textCase(theme.typography.labelCase)
            .tracking(theme.typography.labelTracking)
    }

    private static func compactMoney(_ dollars: Double) -> String {
        let cents = (dollars * 100).rounded()
        let clamped = cents.isFinite ? min(max(cents, -9e17), 9e17) : 0
        return CurrencyFormatter.string(Money(cents: Int64(clamped)), format: .compact)
    }
}

// MARK: - HouseholdDebtChart
//
// The debt coming down, month by month: one thin line per account and a thicker accent line for
// everything added together. The schedule stops the month the last balance clears, so the chart
// ends where the debt does.

struct HouseholdDebtChart: View {
    let plan: HouseholdPlanResult

    @Environment(\.theme) private var theme
    @Environment(\.privacyMode) private var privacyMode

    /// One account's balance at the start of one month.
    private struct Point: Identifiable {
        var id: String
        var date: Date
        var name: String
        var balance: Double
    }

    private var points: [Point] {
        var built: [Point] = []
        built.reserveCapacity(plan.debt.schedule.count * plan.accounts.count)
        for month in plan.debt.schedule {
            for account in plan.accounts {
                built.append(Point(id: "\(account.id)-\(month.monthIndex)",
                                   date: month.date, name: account.name,
                                   balance: month.balances[account.id] ?? 0))
            }
        }
        return built
    }

    var body: some View {
        let interpolation: InterpolationMethod = theme.chart.smoothLines ? .catmullRom : .linear
        return VStack(alignment: .leading, spacing: theme.layout.spacing) {
            cardLabel("The Way Down")
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Month", point.date),
                             y: .value("Balance", point.balance),
                             series: .value("Account", point.name))
                        .interpolationMethod(interpolation)
                        .foregroundStyle(color(for: point.name))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                ForEach(plan.debt.schedule) { month in
                    LineMark(x: .value("Month", month.date),
                             y: .value("Balance", month.totalBalance),
                             series: .value("Account", "Everything"))
                        .interpolationMethod(interpolation)
                        .foregroundStyle(theme.palette.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    if theme.chart.gridLines { AxisGridLine() }
                    AxisValueLabel()
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
            .frame(height: 200)
            .privacySensitive()
            .blur(radius: privacyMode ? 8 : 0)
            .accessibilityHidden(true)
            legend
        }
        .themedCard()
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.layout.spacing * 0.75) {
                legendDot("Everything", theme.palette.accent)
                ForEach(plan.accounts) { account in
                    legendDot(account.name, color(for: account.name))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityHidden(true)
    }

    private func legendDot(_ label: String, _ swatch: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(swatch)
                .frame(width: 8, height: 8)
            Text(label)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
                .lineLimit(1)
        }
    }

    private func color(for name: String) -> Color {
        let index = plan.accounts.firstIndex { $0.name == name } ?? 0
        return theme.palette.chart[index % theme.palette.chart.count]
    }

    private func cardLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.font(.label))
            .foregroundStyle(theme.palette.textSecondary)
            .textCase(theme.typography.labelCase)
            .tracking(theme.typography.labelTracking)
    }

    private static func compactMoney(_ dollars: Double) -> String {
        let cents = (dollars * 100).rounded()
        let clamped = cents.isFinite ? min(max(cents, -9e17), 9e17) : 0
        return CurrencyFormatter.string(Money(cents: Int64(clamped)), format: .compact)
    }
}
