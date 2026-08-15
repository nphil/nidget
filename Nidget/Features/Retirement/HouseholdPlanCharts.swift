import SwiftUI
import Charts

// MARK: - Household plan charts
//
// The three household charts: net worth over time (the one chart on the connected glance),
// income by source (YearsView), and the debt payoff (DebtView). All of them draw from the
// projection the environment's HouseholdPlanModel computes off the main actor; nothing here
// runs the engine.

// MARK: - HouseholdNetWorthChart
//
// Everything the household owns and owes, plotted against the primary earner's age: net worth
// is the point (the one saturated series), with the portfolio, the equity in the two houses,
// and the consumer debt drawn as muted context lines. Debt is drawn below the line because
// that is what it does to the total. Entity identity comes from the legend plus the line
// treatment, not hue, so the context lines never compete with the accent.
//
// Drag to scrub via the shared ChartScrubCallout: the callout names the year and reads back
// net worth, the portfolio, and the debt still open at it.

struct HouseholdNetWorthChart: View {
    let rows: [HouseholdYear]
    let config: HouseholdPlanConfig

    @Environment(\.theme) private var theme
    @Environment(\.privacyMode) private var privacyMode

    @State private var selectedAge: Double?

    init(rows: [HouseholdYear], config: HouseholdPlanConfig) {
        self.rows = rows
        self.config = config
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            header
            if rows.count > 1 {
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

    private var header: some View {
        Group {
            if let targetNetWorth {
                SectionHeader("Where the money goes over time", trailing: {
                    AnyView(AmountText(targetNetWorth, style: .body, colorized: false))
                })
            } else {
                SectionHeader("Where the money goes over time")
            }
        }
    }

    /// Net worth in the target year, or the last projected year when the target sits past the
    /// horizon; the header's trailing stat.
    private var targetNetWorth: Money? {
        guard let row = rows.first(where: { $0.ageA == config.targetRetirementAge }) ?? rows.last
        else { return nil }
        return Money(clampedDollars: row.netWorth)
    }

    // MARK: Chart

    private var chart: some View {
        let minAge = Double(rows.first?.ageA ?? 0)
        let maxAge = Double(rows.last?.ageA ?? 1)
        let interpolation: InterpolationMethod = theme.chart.smoothLines ? .catmullRom : .linear
        // The domain covers every plotted series. Houses equity is unclamped and can go
        // negative (an underwater home), so the floor is the min over all four, never just
        // the debt line.
        let highest = rows.map {
            max(max($0.netWorth, $0.liquidPortfolio), max($0.realEstateEquity, -$0.totalDebt))
        }.max() ?? 1
        let deepest = rows.map {
            min(min($0.netWorth, $0.liquidPortfolio), min($0.realEstateEquity, -$0.totalDebt))
        }.min() ?? 0
        let yMax = max(highest * 1.08, 1)
        let yMin = min(0, deepest) * 1.05
        let nearest = nearestRow
        let targetAge = Double(config.targetRetirementAge)

        return Chart {
            if theme.chart.filledAreas {
                ForEach(rows) { row in
                    AreaMark(x: .value("Age", Double(row.ageA)),
                             y: .value("Net worth", row.netWorth),
                             series: .value("Series", "Net worth area"))
                        .interpolationMethod(interpolation)
                        .foregroundStyle(areaGradient)
                }
            }
            ForEach(rows) { row in
                LineMark(x: .value("Age", Double(row.ageA)),
                         y: .value("Net worth", row.netWorth),
                         series: .value("Series", "Net worth"))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(theme.palette.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(rows) { row in
                LineMark(x: .value("Age", Double(row.ageA)),
                         y: .value("Portfolio", row.liquidPortfolio),
                         series: .value("Series", "Portfolio"))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(theme.palette.textSecondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(rows) { row in
                LineMark(x: .value("Age", Double(row.ageA)),
                         y: .value("Houses", row.realEstateEquity),
                         series: .value("Series", "Houses"))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(theme.palette.textSecondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(rows) { row in
                LineMark(x: .value("Age", Double(row.ageA)),
                         y: .value("Debt", -row.totalDebt),
                         series: .value("Series", "Debt"))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(theme.palette.textSecondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            // Closed comparison: a projection ending exactly at the target age keeps its marker.
            if targetAge >= minAge && targetAge <= maxAge {
                RuleMark(x: .value("Age", targetAge))
                    .foregroundStyle(theme.palette.textSecondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .topTrailing, alignment: .trailing, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .plot),
                                                          y: .fit(to: .plot))) {
                        // Hidden while scrubbing so the chip can never collide with the
                        // callout; fit-to-plot alone is not trusted near the right edge.
                        if nearest == nil {
                            targetChip
                        }
                    }
            }
            if let nearest {
                ChartScrubCallout(theme: theme, x: Double(nearest.ageA),
                                  title: "\(nearest.calendarYear), age \(nearest.ageA)",
                                  lines: calloutLines(nearest))
                PointMark(x: .value("Age", Double(nearest.ageA)),
                          y: .value("Net worth", nearest.netWorth))
                    .foregroundStyle(theme.palette.accent)
                    .symbolSize(90)
            }
        }
        .chartXScale(domain: minAge...maxAge)
        .chartYScale(domain: yMin...yMax)
        .chartXSelection(value: $selectedAge)
        .chartXAxis {
            AxisMarks(values: roundAgeTicks(min: minAge, max: maxAge)) { value in
                if theme.chart.gridLines { AxisGridLine() }
                AxisValueLabel {
                    if let age = value.as(Double.self) {
                        Text(String(clampedAge(age)))
                    }
                }
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
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

    private var areaGradient: LinearGradient {
        LinearGradient(colors: [theme.palette.accent.opacity(0.18), theme.palette.accent.opacity(0.02)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var targetChip: some View {
        Text(String(config.targetRetirementAge))
            .font(theme.font(.caption))
            .foregroundStyle(theme.palette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background { theme.controlShape.fill(theme.palette.surfaceElevated) }
    }

    private var nearestRow: HouseholdYear? {
        guard let selectedAge else { return nil }
        return rows.min {
            abs(Double($0.ageA) - selectedAge) < abs(Double($1.ageA) - selectedAge)
        }
    }

    private func calloutLines(_ row: HouseholdYear) -> [ChartCalloutLine] {
        var lines = [ChartCalloutLine(Money(clampedDollars: row.netWorth), caption: "net worth"),
                     ChartCalloutLine(Money(clampedDollars: row.liquidPortfolio),
                                      caption: "invested")]
        if row.totalDebt > 0 {
            lines.append(ChartCalloutLine(Money(clampedDollars: row.totalDebt), caption: "debt"))
        }
        return lines
    }

    // MARK: Legend

    /// Swatches mirror the line treatments so the legend teaches the chart: the debt swatch is
    /// a short dashed line, not a dot.
    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.layout.spacing) {
                legendLine("Net worth", color: theme.palette.accent, lineWidth: 2.5)
                legendLine("Invested", color: theme.palette.textSecondary.opacity(0.55),
                           lineWidth: 1.5)
                legendLine("Houses", color: theme.palette.textSecondary.opacity(0.35),
                           lineWidth: 1.5)
                legendLine("Debt", color: theme.palette.textSecondary.opacity(0.45),
                           lineWidth: 1.5, dash: [3, 2])
            }
            .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityHidden(true)
    }

    private func legendLine(_ label: String, color: Color, lineWidth: CGFloat,
                            dash: [CGFloat] = []) -> some View {
        HStack(spacing: 4) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 14, y: 4))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: dash))
            .frame(width: 14, height: 8)
            Text(label)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
                .lineLimit(1)
        }
    }

    // MARK: Helpers

    private static func compactMoney(_ dollars: Double) -> String {
        // Clamp well inside Int64 before converting (LESSONS_FROM_STASHY §2: `isFinite` alone
        // doesn't make a Double to Int conversion safe).
        let cents = (dollars * 100).rounded()
        let clamped = cents.isFinite ? min(max(cents, -9e17), 9e17) : 0
        return CurrencyFormatter.string(Money(cents: Int64(clamped)), format: .compact)
    }
}

// MARK: - HouseholdIncomeChart
//
// Where the household's money comes from, year by year: the primary salary, the bonus and RSUs
// on top of it, the second earner, and the rent once the current home is let. Stacked bars,
// because the question is both "how much" and "made of what". Colors come from ChartRole so a
// categorical series can never wear a status color by accident.

struct HouseholdIncomeChart: View {
    let rows: [HouseholdYear]
    let config: HouseholdPlanConfig

    @Environment(\.theme) private var theme
    @Environment(\.privacyMode) private var privacyMode

    init(rows: [HouseholdYear], config: HouseholdPlanConfig) {
        self.rows = rows
        self.config = config
    }

    /// One income source: stable identity, display label, categorical role, and how to read its
    /// dollars out of a projected year.
    private struct Source: Identifiable {
        var id: String
        var label: String
        var role: ChartRole
        var amount: (HouseholdYear) -> Double
    }

    /// One block of one bar.
    private struct Slice: Identifiable {
        var id: String
        var age: Int
        var source: String
        var amount: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            SectionHeader("Income By Source")
            if rows.isEmpty {
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

    // MARK: Sources

    /// The fixed source list, minus anything that would render as noise: a source whose person
    /// name is blank has no honest label, and an all-zero series has no bar, so both are
    /// dropped before the chart and legend see them.
    private var sources: [Source] {
        let nameA = config.personA.name.trimmingCharacters(in: .whitespaces)
        let nameB = config.personB.name.trimmingCharacters(in: .whitespaces)
        var built: [Source] = []
        if !nameA.isEmpty {
            built.append(Source(id: "salaryA", label: "\(nameA) salary", role: .role0,
                                amount: { $0.baseA }))
        }
        built.append(Source(id: "bonusA", label: "Bonus and stock", role: .role1,
                            amount: { $0.bonusA + $0.rsuA }))
        if !nameB.isEmpty {
            built.append(Source(id: "personB", label: nameB, role: .role2,
                                amount: { $0.totalCompB }))
        }
        built.append(Source(id: "rent", label: "\(HouseholdCopy.homeCity) rent", role: .role3,
                            amount: { max(0, $0.netRentMonthly * 12) }))
        return built.filter { source in
            rows.contains { source.amount($0) > 0 }
        }
    }

    // MARK: Chart

    private var chart: some View {
        let sources = self.sources
        var slices: [Slice] = []
        slices.reserveCapacity(rows.count * sources.count)
        for row in rows {
            for source in sources {
                let amount = source.amount(row)
                if amount > 0 {
                    slices.append(Slice(id: "\(row.yearIndex)-\(source.id)", age: row.ageA,
                                        source: source.label, amount: amount))
                }
            }
        }
        return Chart(slices) { slice in
            BarMark(x: .value("Age", slice.age),
                    y: .value("Income", slice.amount))
                .foregroundStyle(by: .value("Source", slice.source))
                .cornerRadius(theme.chart.barCornerRadius)
        }
        .chartForegroundStyleScale(domain: sources.map(\.label),
                                   range: sources.map { $0.role.color(in: theme.palette) })
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
        .frame(height: 220)
        .privacySensitive()
        .blur(radius: privacyMode ? 8 : 0)
        .accessibilityHidden(true)
    }

    /// Round age ticks; a plan too short to contain a multiple of five falls back to its
    /// endpoints, so a four-year plan still labels its axis.
    private var axisAges: [Int] {
        guard let first = rows.first?.ageA, let last = rows.last?.ageA else { return [] }
        return roundAgeTicks(min: Double(first), max: Double(last)).map { Int($0) }
    }

    // MARK: Legend

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.layout.spacing * 0.75) {
                ForEach(sources) { source in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(source.role.color(in: theme.palette))
                            .frame(width: 8, height: 8)
                        Text(source.label)
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityHidden(true)
    }

    // MARK: Helpers

    private static func compactMoney(_ dollars: Double) -> String {
        let cents = (dollars * 100).rounded()
        let clamped = cents.isFinite ? min(max(cents, -9e17), 9e17) : 0
        return CurrencyFormatter.string(Money(cents: Int64(clamped)), format: .compact)
    }
}

// MARK: - HouseholdDebtChart
//
// The debt coming down, month by month: one thin line per account and a thicker accent line
// for everything added together. Series and colors are keyed by account id, never by name, so
// two cards both called "Visa" stay two lines. Each account's line stops at its payoff month
// (the first zero closes it out), long schedules thin to quarterly samples, and interpolation
// is monotone on smooth-line themes because balances only fall: a monotone spline cannot
// overshoot below zero at a payoff the way Catmull-Rom does.

struct HouseholdDebtChart: View {
    let plan: HouseholdPlanResult

    @Environment(\.theme) private var theme
    @Environment(\.privacyMode) private var privacyMode

    /// One account's balance at the start of one month.
    private struct Point: Identifiable {
        var id: String
        var month: Int
        var balance: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            SectionHeader("The Way Down")
            if plan.debt.schedule.count < 2 || startingTotal <= 0 {
                Text("Nothing left to pay down.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                chart
                legend
            }
        }
        .themedCard()
    }

    // MARK: Chart

    private var chart: some View {
        let interpolation: InterpolationMethod = theme.chart.smoothLines ? .monotone : .linear
        let lastMonth = plan.debt.schedule.last?.monthIndex ?? 0
        return Chart {
            ForEach(Array(plan.accounts.enumerated()), id: \.element.id) { index, account in
                ForEach(accountPoints(for: account)) { point in
                    LineMark(x: .value("Month", point.month),
                             y: .value("Balance", point.balance),
                             series: .value("Account", account.id))
                        .interpolationMethod(interpolation)
                        .foregroundStyle(ChartRole.color(at: index, in: theme.palette))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            ForEach(totalPoints) { point in
                LineMark(x: .value("Month", point.month),
                         y: .value("Balance", point.balance),
                         series: .value("Account", "everything.total"))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(theme.palette.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
        }
        .chartXScale(domain: 0...max(lastMonth, 1))
        .chartYScale(domain: 0...max(startingTotal * 1.05, 1))
        .chartXAxis {
            AxisMarks(values: yearTicks(lastMonth: lastMonth)) { value in
                if theme.chart.gridLines { AxisGridLine() }
                AxisValueLabel {
                    if let month = value.as(Int.self) {
                        Text(month == 0 ? "Now" : "\(month / 12)y")
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
        .frame(height: 220)
        .privacySensitive()
        .blur(radius: privacyMode ? 8 : 0)
        .accessibilityHidden(true)
    }

    private var startingTotal: Double {
        plan.debt.schedule.first?.totalBalance ?? 0
    }

    /// Schedules past five years thin to every third month; payoff months and the final month
    /// always survive so no line ends early or hangs open.
    private var isThinned: Bool {
        plan.debt.schedule.count > 60
    }

    /// One account's series: every kept month up to and including its first zero balance, then
    /// nothing, so paid-off accounts never pile up along the baseline.
    private func accountPoints(for account: DebtAccount) -> [Point] {
        let lastMonth = plan.debt.schedule.last?.monthIndex
        var built: [Point] = []
        for month in plan.debt.schedule {
            let balance = max(0, month.balances[account.id] ?? 0)
            let isPayoff = balance <= 0
            if !isThinned || month.monthIndex % 3 == 0 || isPayoff || month.monthIndex == lastMonth {
                built.append(Point(id: "\(account.id)-\(month.monthIndex)",
                                   month: month.monthIndex, balance: balance))
            }
            if isPayoff { break }
        }
        return built
    }

    private var totalPoints: [Point] {
        let lastMonth = plan.debt.schedule.last?.monthIndex
        var built: [Point] = []
        for month in plan.debt.schedule {
            let isPayoff = month.totalBalance <= 0
            if !isThinned || month.monthIndex % 3 == 0 || isPayoff || month.monthIndex == lastMonth {
                built.append(Point(id: "total-\(month.monthIndex)",
                                   month: month.monthIndex,
                                   balance: max(0, month.totalBalance)))
            }
            if isPayoff { break }
        }
        return built
    }

    /// Yearly x ticks: Now, 1y, 2y and so on.
    private func yearTicks(lastMonth: Int) -> [Int] {
        guard lastMonth > 0 else { return [0] }
        return Array(stride(from: 0, through: lastMonth, by: 12))
    }

    // MARK: Legend

    /// Identity by account id; duplicate display names are disambiguated by position so two
    /// "Visa" cards read "Visa (1)" and "Visa (2)".
    private var legend: some View {
        let names = displayNames
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.layout.spacing * 0.75) {
                legendDot("Everything", theme.palette.accent)
                ForEach(Array(plan.accounts.enumerated()), id: \.element.id) { index, _ in
                    legendDot(names[index], ChartRole.color(at: index, in: theme.palette))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityHidden(true)
    }

    private var displayNames: [String] {
        var counts: [String: Int] = [:]
        for account in plan.accounts {
            counts[account.name, default: 0] += 1
        }
        var seen: [String: Int] = [:]
        return plan.accounts.map { account in
            guard (counts[account.name] ?? 0) > 1 else { return account.name }
            seen[account.name, default: 0] += 1
            return "\(account.name) (\(seen[account.name] ?? 1))"
        }
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

    private static func compactMoney(_ dollars: Double) -> String {
        let cents = (dollars * 100).rounded()
        let clamped = cents.isFinite ? min(max(cents, -9e17), 9e17) : 0
        return CurrencyFormatter.string(Money(cents: Int64(clamped)), format: .compact)
    }
}
