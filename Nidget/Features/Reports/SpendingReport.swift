import SwiftUI
import Charts

// MARK: - SpendingReport
//
// Donut breakdown of spending by category, aggregated across the selected month range from
// `store.spendingByCategory(month:)` (there's no range-native query, so this sums per-month
// results — cheap local SQLite reads, one per month in range). Top 8 categories + an "Other"
// bucket for the remainder; tapping a sector or legend row cross-highlights the other (dimmed to
// 0.35 opacity) and reveals a jump to that category's transactions.

struct SpendingReport: View {
    let monthsBack: Int

    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.privacyMode) private var privacyMode

    private struct CategorySlice: Identifiable, Equatable {
        let id: String
        let name: String
        let amount: Money
        let isOther: Bool
    }

    @State private var slices: [CategorySlice] = []
    @State private var total: Money = .zero
    @State private var hasLoaded = false
    @State private var selection: String?
    @State private var selectedAngle: Double?

    private static let topCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            ReportCardHeader(title: "Spending by Category",
                             statAmount: total.negated,
                             statLabel: "\(monthsBack)-month total",
                             colorized: false)
            if !hasLoaded {
                loadingBody
            } else if slices.isEmpty {
                EmptyStateView(systemImage: "chart.pie",
                               title: "Nothing spent",
                               message: "No spending recorded across the selected range.")
                    .frame(maxWidth: .infinity)
            } else {
                donutChart
                legend
                selectedCategoryAction
            }
        }
        .themedCard()
        .task(id: monthsBack) {
            hasLoaded = false
            selection = nil
            selectedAngle = nil
            await load()
        }
    }

    // MARK: Loading

    private var loadingBody: some View {
        VStack(spacing: theme.layout.spacing) {
            ProgressView()
                .controlSize(.large)
                .tint(theme.palette.accent)
            Text("Crunching the numbers…")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: Donut

    private var donutChart: some View {
        Chart(slices) { slice in
            SectorMark(angle: .value("Amount", slice.amount.doubleValue),
                       innerRadius: .ratio(0.62),
                       angularInset: 1.5)
                .foregroundStyle(color(for: slice))
                .opacity(opacity(for: slice))
        }
        .chartAngleSelection(value: $selectedAngle)
        .chartLegend(.hidden)
        .frame(height: 220)
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let rect = geometry[plotFrame]
                    VStack(spacing: 2) {
                        Text("Spent")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textTertiary)
                        AmountText(total.negated, style: .title, colorized: false)
                    }
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: slices)
        .privacySensitive()
        .blur(radius: privacyMode ? 8 : 0)
        .accessibilityHidden(true)
        .onChange(of: selectedAngle) { _, newValue in
            guard let newValue, let id = sliceID(forAngleValue: newValue) else { return }
            toggleSelection(id)
        }
    }

    private func sliceID(forAngleValue value: Double) -> String? {
        var cumulative = 0.0
        for slice in slices {
            let upper = cumulative + slice.amount.doubleValue
            if value <= upper { return slice.id }
            cumulative = upper
        }
        return slices.last?.id
    }

    private func color(for slice: CategorySlice) -> Color {
        guard !slice.isOther else { return theme.palette.textTertiary.opacity(0.5) }
        guard let index = slices.firstIndex(where: { $0.id == slice.id }) else { return theme.palette.accent }
        return theme.palette.chart[index % theme.palette.chart.count]
    }

    private func opacity(for slice: CategorySlice) -> Double {
        guard let selection else { return 1.0 }
        return slice.id == selection ? 1.0 : 0.35
    }

    private func toggleSelection(_ id: String) {
        Haptics.tick()
        let apply = { selection = (selection == id) ? nil : id }
        if reduceMotion {
            apply()
        } else {
            withAnimation(theme.motion.snappy) { apply() }
        }
    }

    // MARK: Legend

    private var legend: some View {
        VStack(spacing: theme.layout.spacing * 0.5) {
            ForEach(slices) { slice in
                legendRow(slice)
            }
        }
    }

    private func legendRow(_ slice: CategorySlice) -> some View {
        Button {
            toggleSelection(slice.id)
        } label: {
            HStack(spacing: theme.layout.spacing * 0.5) {
                Circle()
                    .fill(color(for: slice))
                    .frame(width: 10, height: 10)
                Text(slice.name)
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: theme.layout.spacing * 0.5)
                Text(percentText(slice))
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                AmountText(slice.amount.negated, style: .caption, colorized: false)
            }
            .frame(minHeight: 44)
            .opacity(opacity(for: slice))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(slice.name), \(percentText(slice)), \(CurrencyFormatter.string(slice.amount))")
        .accessibilityAddTraits(selection == slice.id ? [.isSelected] : [])
    }

    private func percentText(_ slice: CategorySlice) -> String {
        guard total.cents > 0 else { return "0%" }
        return (slice.amount.doubleValue / total.doubleValue)
            .formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: Selected category action

    @ViewBuilder
    private var selectedCategoryAction: some View {
        if let selection, let slice = slices.first(where: { $0.id == selection }), !slice.isOther {
            NidgetButton("View \(slice.name) Transactions", systemImage: "list.bullet", role: .secondary) {
                Haptics.tick()
                router.openTransactions(filter: TransactionQuery(categoryID: slice.id, months: monthRange))
            }
            .padding(.top, theme.layout.spacing * 0.25)
        }
    }

    private var monthRange: ClosedRange<BudgetMonth> {
        let months = BudgetMonth.lastMonths(monthsBack)
        let first = months.first ?? .current
        let last = months.last ?? .current
        return first...last
    }

    // MARK: Load

    private func load() async {
        let months = BudgetMonth.lastMonths(monthsBack)
        var totals: [String: (name: String, amount: Money)] = [:]
        for month in months {
            guard !Task.isCancelled else { return }
            let rows = await store.spendingByCategory(month: month)
            for row in rows {
                let existing = totals[row.categoryID]?.amount ?? .zero
                totals[row.categoryID] = (name: row.name, amount: existing + row.amount)
            }
        }
        guard !Task.isCancelled else { return }

        let sorted = totals
            .map { CategorySlice(id: $0.key, name: $0.value.name, amount: $0.value.amount, isOther: false) }
            .sorted { $0.amount.cents > $1.amount.cents }
        let top = Array(sorted.prefix(Self.topCount))
        let rest = sorted.dropFirst(Self.topCount)
        let restTotal = rest.reduce(Money.zero) { $0 + $1.amount }

        var result = top
        if restTotal.cents > 0 {
            result.append(CategorySlice(id: "other", name: "Other", amount: restTotal, isOther: true))
        }

        slices = result
        total = sorted.reduce(Money.zero) { $0 + $1.amount }
        hasLoaded = true
    }
}
