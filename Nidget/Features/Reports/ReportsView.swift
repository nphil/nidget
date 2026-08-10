import SwiftUI

// MARK: - ReportsView
//
// Pushed via `Route.reports` (ARCHITECTURE §14/§16): a report-kind ChipPicker (Spending / Net
// Worth / Cash Flow / Categories) plus a month-range ChipPicker (3/6/12 months), driving one of
// four self-contained report cards. Each report card owns its own data load keyed to the range
// (`.task(id:)`, cancellation-guarded per LESSONS_FROM_STASHY §1) so switching ranges never
// stomps a still-in-flight load from a previous selection, and switching report kinds simply
// swaps the card's concrete type (mirrors the loading/empty/list `@ViewBuilder` switches already
// used by BudgetView/TransactionDetailView elsewhere in the app).

struct ReportsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var kind: ReportKind = .spending
    @State private var range: ReportRange = .six

    init() {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.layout.spacing) {
                pickers
                reportContent
            }
            .padding(theme.layout.cardPadding)
            .animation(reduceMotion ? nil : theme.motion.spring, value: range)
        }
        .scrollIndicators(.hidden)
        .themedScreen()
        .navigationTitle("Reports")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Pickers

    private var pickers: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.6) {
            ChipPicker(items: ReportKind.allCases, selection: $kind, label: { $0.label })
            ChipPicker(items: ReportRange.allCases, selection: $range, label: { $0.label })
        }
    }

    // MARK: Report switch

    @ViewBuilder
    private var reportContent: some View {
        switch kind {
        case .spending:
            SpendingReport(monthsBack: range.monthsBack)
        case .netWorth:
            NetWorthReport(monthsBack: range.monthsBack)
        case .cashFlow:
            CashFlowReport(monthsBack: range.monthsBack)
        case .categories:
            CategoryTrendsReport(monthsBack: range.monthsBack)
        }
    }
}

// MARK: - ReportKind / ReportRange

private enum ReportKind: String, CaseIterable, Hashable {
    case spending, netWorth, cashFlow, categories

    var label: String {
        switch self {
        case .spending: return "Spending"
        case .netWorth: return "Net Worth"
        case .cashFlow: return "Cash Flow"
        case .categories: return "Categories"
        }
    }
}

private enum ReportRange: Int, CaseIterable, Hashable {
    case three = 3, six = 6, twelve = 12

    var monthsBack: Int { rawValue }
    var label: String { "\(rawValue)M" }
}

// MARK: - ReportCardHeader
//
// Shared title + key-stat header for every report card (ARCHITECTURE §14: "Each report in a
// .themedCard with title + key stat header"). Each report picks its own coloring/sign for the
// stat since spend magnitudes, net worth, and signed cash flow all read differently — spend
// totals are shown negated (outflow-red) like the dashboard widgets do, net worth is neutral,
// and cash flow is a genuinely signed figure.

struct ReportCardHeader: View {
    let title: String
    let statAmount: Money
    let statLabel: String
    var colorized: Bool = true
    var showSign: Bool = false

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(statLabel)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: theme.layout.spacing)
            AmountText(statAmount, style: .title, colorized: colorized, showSign: showSign)
        }
    }
}
