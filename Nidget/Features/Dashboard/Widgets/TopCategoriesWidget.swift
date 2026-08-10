import SwiftUI

// MARK: - TopCategoriesWidget
//
// This month's hungriest categories as ranked bars, colored from the theme's chart palette.
// Bars are pure shapes scaled against the top category. Loads via `.task(id: store.accounts)`
// so mutations and syncs refresh the ranking; tapping opens the Budget tab.

struct TopCategoriesWidget: View {
    let span: WidgetSpan

    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct CategorySpend: Equatable, Identifiable {
        let id: String
        let name: String
        /// Positive magnitude of the month's outflow.
        let amount: Money
    }

    @State private var categories: [CategorySpend] = []
    @State private var hasLoaded = false

    var body: some View {
        WidgetCardButton(action: { router.tab = .budget }) {
            content
        }
        .accessibilityHint("Opens the budget")
        .task(id: store.accounts) {
            let spending = await store.spendingByCategory(month: .current)
            guard !Task.isCancelled else { return }
            categories = spending.prefix(4).map {
                CategorySpend(id: $0.categoryID, name: $0.name, amount: $0.amount)
            }
            hasLoaded = true
        }
    }

    private var rowLimit: Int {
        switch span {
        case .s1x1: return 1
        case .s2x1: return 3
        case .s2x2: return 4
        }
    }

    private var topAmount: Money {
        categories.first?.amount ?? .zero
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            WidgetLabel(span == .s1x1 ? "Top Spend" : "Top Categories")
            if !hasLoaded {
                loadingBody
            } else if categories.isEmpty {
                emptyBody
            } else if span == .s1x1 {
                compactBody
            } else {
                VStack(spacing: theme.layout.spacing * 0.5) {
                    ForEach(Array(categories.prefix(rowLimit).enumerated()),
                            id: \.element.id) { index, category in
                        categoryRow(category, index: index)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: categories)
    }

    private var loadingBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            AmountText(.zero, style: .title, redacted: true)
            Text("Ranking the damage…")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var emptyBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text("Nothing spent yet")
                .font(theme.font(.headline))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("A spotless month — so far.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var compactBody: some View {
        if let top = categories.first {
            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 0)
                Text(top.name)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                AmountText(top.amount.negated, style: .title)
                bar(fraction: 1, color: theme.palette.chart.first ?? theme.palette.accent)
            }
        }
    }

    private func categoryRow(_ category: CategorySpend, index: Int) -> some View {
        let fraction = topAmount.cents > 0
            ? category.amount.doubleValue / topAmount.doubleValue
            : 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: theme.layout.spacing * 0.5) {
                Text(category.name)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: theme.layout.spacing * 0.5)
                AmountText(category.amount.negated, style: .caption)
            }
            bar(fraction: fraction, color: theme.palette.chart[index % theme.palette.chart.count])
        }
        .accessibilityElement(children: .combine)
    }

    private func bar(fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: theme.chart.barCornerRadius, style: .continuous)
                    .fill(theme.palette.fill)
                RoundedRectangle(cornerRadius: theme.chart.barCornerRadius, style: .continuous)
                    .fill(color)
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), 4))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
