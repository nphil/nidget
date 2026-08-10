import SwiftUI

// MARK: - NetWorthWidget
//
// Twelve months of net worth as a Sparkline with the current total and a year-over-year delta
// chip. Loads through `.task(id: store.accounts)` so any balance change (sync, new
// transaction) refreshes the series; stale tasks never write (Task.isCancelled guard —
// LESSONS §1). Tapping pushes the Accounts screen.

struct NetWorthWidget: View {
    let span: WidgetSpan

    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var values: [Double] = []
    @State private var current: Money = .zero
    @State private var delta: Money = .zero
    @State private var hasLoaded = false

    var body: some View {
        WidgetCardButton(action: { router.push(.accounts) }) {
            content
        }
        .accessibilityHint("Opens your accounts")
        .task(id: store.accounts) {
            let series = await store.netWorthSeries(monthsBack: 12)
            guard !Task.isCancelled else { return }
            values = series.map { $0.1.doubleValue }
            current = series.last?.1 ?? .zero
            delta = current - (series.first?.1 ?? .zero)
            hasLoaded = true
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
            WidgetLabel("Net Worth")
            Spacer(minLength: 0)
            if hasLoaded {
                AmountText(current, style: .title, colorized: false)
                deltaChip
            } else {
                AmountText(.zero, style: .title, redacted: true)
                Text("Counting coins…")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: current)
    }

    private var wideBody: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            HStack(alignment: .firstTextBaseline) {
                WidgetLabel("Net Worth")
                Spacer(minLength: theme.layout.spacing * 0.5)
                if hasLoaded {
                    deltaChip
                }
            }
            if hasLoaded {
                AmountText(current, style: span == .s2x2 ? .display : .title, colorized: false)
            } else {
                AmountText(.zero, style: .title, redacted: true)
            }
            if hasLoaded && values.count < 2 {
                Spacer(minLength: 0)
                Text("Add accounts to see the trend take shape.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer(minLength: 0)
            } else {
                Sparkline(values: values, fillGradient: theme.chart.filledAreas)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: values)
    }

    // MARK: Delta chip

    private var deltaChip: some View {
        let rising = delta.cents >= 0
        let chipColor = rising ? theme.palette.positive : theme.palette.negative
        return HStack(spacing: 3) {
            Image(systemName: rising ? "arrow.up.right" : "arrow.down.right")
                .font(theme.font(.caption))
                .fontWeight(theme.icons.weight)
                .foregroundStyle(chipColor)
            AmountText(delta, style: .caption, showSign: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(chipColor.opacity(0.14))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rising ? "Up over the last year" : "Down over the last year")
    }
}
