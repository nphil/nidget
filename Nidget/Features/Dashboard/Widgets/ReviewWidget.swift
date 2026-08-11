import SwiftUI

// MARK: - ReviewWidget
//
// How many imported transactions are still waiting for a category, as one big number. Patterned
// on TopCategoriesWidget: a whole-card `WidgetCardButton` (which carries the dashboard's
// long-press-to-edit and pull-to-glow gestures), and a `.task(id: store.accounts)` load so a sync
// or an edit refreshes the count without any observation of its own.
//
// At zero it stops nagging: no badge, no accent, just "All caught up".

struct ReviewWidget: View {
    let span: WidgetSpan

    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var count = 0
    @State private var hasLoaded = false

    var body: some View {
        WidgetCardButton(action: { router.push(.review) }) {
            content
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens Review")
        .task(id: store.accounts) {
            let value = await store.reviewCount()
            guard !Task.isCancelled else { return }
            count = value
            hasLoaded = true
        }
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            WidgetLabel("Needs Review")
            if !hasLoaded {
                loadingBody
            } else if count == 0 {
                clearBody
            } else {
                waitingBody
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: count)
    }

    private var loadingBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text("··")
                .font(theme.amountFont(.display))
                .foregroundStyle(theme.palette.textTertiary)
            Text("Checking what came in…")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var clearBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle")
                .font(theme.font(.title))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.palette.positive)
                .accessibilityHidden(true)
            Text("All caught up")
                .font(theme.font(.headline))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if span != .s1x1 {
                // With nothing to decide, this line is the only place the AI's own filings get
                // mentioned. They are deliberately kept out of the big number (a badge should
                // only count work), so without this the spot-check section would be invisible.
                Text(clearSubtitle)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private var waitingBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text("\(count)")
                .font(theme.amountFont(.display))
                .foregroundStyle(theme.palette.accent)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(subtitle)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(span == .s1x1 ? 1 : 2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
    }

    private var clearSubtitle: String {
        let filed = store.autoFiledCount
        guard filed > 0 else { return "Nothing waiting for a category." }
        return filed == 1
            ? "Nidget filed 1 on its own. Tap to check it."
            : "Nidget filed \(filed) on its own. Tap to check them."
    }

    private var subtitle: String {
        if span == .s1x1 {
            return "to sort"
        }
        return count == 1
            ? "transaction is waiting for a category"
            : "transactions are waiting for a category"
    }

    private var accessibilityLabel: String {
        guard hasLoaded else { return "Needs Review" }
        if count == 0 { return "Needs Review, all caught up" }
        return count == 1
            ? "Needs Review, 1 transaction waiting"
            : "Needs Review, \(count) transactions waiting"
    }
}
