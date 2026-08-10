import Foundation
import SwiftUI

// MARK: - Guide pages
//
// The seven pages of the in-app Guide (docs/UX_ROUND2.md §1). Each page is a title, a few
// short sentences, and a small live visual built from the app's real design language — mini
// mocks that echo ProgressRing, AmountText, the cleared checkmark, the sync pill, dashboard
// tiles, and the Quick Add sparkles chip. Every visual is static and cheap: hardcoded sample
// numbers, no store reads, and `.allowsHitTesting(false)` via the shared scaffold.
//
// MAINTENANCE RULE (CLAUDE.md): whenever a feature shown here changes, its page changes in
// the same commit. The Guide must always match the app.

// MARK: - Shared scaffold

/// Common page layout: the visual floats in the upper half, the title and copy sit below.
/// The visual is decorative — untouchable and hidden from VoiceOver, which reads the copy.
private struct GuidePage<Visual: View>: View {
    let title: String
    let text: String
    let visual: Visual

    @Environment(\.theme) private var theme

    init(title: String, text: String, @ViewBuilder visual: () -> Visual) {
        self.title = title
        self.text = text
        self.visual = visual()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: theme.layout.spacing)
            visual
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Spacer(minLength: theme.layout.spacing * 1.5)
            Text(title)
                .font(theme.font(.title))
                .foregroundStyle(theme.palette.textPrimary)
                .padding(.bottom, theme.layout.spacing * 0.75)
            Text(text)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, theme.layout.cardPadding + 4)
        .padding(.bottom, theme.layout.spacing)
    }
}

// MARK: - Page 1: the envelope idea

struct GuideEnvelopePage: View {
    @Environment(\.theme) private var theme

    var body: some View {
        GuidePage(
            title: "Give every dollar a job",
            text: "You only budget money you already have. It lands in To Budget, and you deal it out into envelopes, one for each thing you spend on. Whatever sits in an envelope is yours to spend. That is the whole trick."
        ) {
            VStack(spacing: theme.layout.spacing) {
                toBudgetPill
                    .guideSpotlight(cornerRadius: 26, inset: 6)
                arrowsRow
                HStack(spacing: theme.layout.spacing * 0.75) {
                    MockEnvelopeCard(name: "Groceries", amount: Money(cents: 30000), fillFraction: 1.0)
                    MockEnvelopeCard(name: "Transit", amount: Money(cents: 8000), fillFraction: 0.65)
                    MockEnvelopeCard(name: "Fun", amount: Money(cents: 12000), fillFraction: 0.4)
                }
            }
        }
    }

    private var toBudgetPill: some View {
        HStack(spacing: 8) {
            Text("To Budget")
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textSecondary)
            AmountText(Money(cents: 62000), style: .title)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background {
            Capsule()
                .fill(theme.palette.surface)
                .overlay(Capsule().strokeBorder(theme.palette.surfaceBorder, lineWidth: 1))
        }
    }

    private var arrowsRow: some View {
        HStack(spacing: 56) {
            ForEach(0..<3, id: \.self) { _ in
                Image(systemName: "arrow.down")
                    .font(theme.font(.caption))
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
    }
}

private struct MockEnvelopeCard: View {
    let name: String
    let amount: Money
    let fillFraction: Double

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            AmountText(amount, style: .caption)
            MockProgressBar(fraction: fillFraction)
        }
        .themedCard(padding: 10)
    }
}

// MARK: - Page 2: the Budget screen

struct GuideBudgetPage: View {
    @Environment(\.theme) private var theme

    private static let budgetedWidth: CGFloat = 70
    private static let spentWidth: CGFloat = 70
    private static let balanceWidth: CGFloat = 82

    var body: some View {
        GuidePage(
            title: "The Budget screen",
            text: "Tap the budgeted amount to fill an envelope. Spent is what left this month, and the balance pill is what remains. A red balance just means that envelope ran dry. Swipe the row and move some money over from another one, no guilt required."
        ) {
            VStack(spacing: theme.layout.spacing * 0.5) {
                mockRow
                    .themedCard(padding: 12)
                labelsRow
            }
        }
    }

    private var mockRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Groceries")
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                AmountText(Money(cents: 15000), style: .body, colorized: false)
                    .frame(width: Self.budgetedWidth, alignment: .trailing)
                AmountText(Money(cents: -8640), style: .body)
                    .frame(width: Self.spentWidth, alignment: .trailing)
                balancePill
                    .frame(width: Self.balanceWidth)
                    .guideSpotlight(cornerRadius: 16, inset: 4)
            }
            MockProgressBar(fraction: 0.58)
        }
    }

    private var balancePill: some View {
        AmountText(Money(cents: 6360), style: .caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(theme.palette.positive.opacity(0.16))
            }
    }

    private var labelsRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 4)
            columnLabel("Budgeted", width: Self.budgetedWidth)
            columnLabel("Spent", width: Self.spentWidth)
            columnLabel("Balance", width: Self.balanceWidth)
        }
        .padding(.horizontal, 12)
    }

    private func columnLabel(_ text: String, width: CGFloat) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "arrow.up")
                .font(theme.font(.caption))
                .fontWeight(theme.icons.weight)
                .foregroundStyle(theme.palette.accent)
            Text(text)
                .font(theme.font(.label))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: width)
    }
}

// MARK: - Page 3: Quick Add + the cleared checkmark

struct GuideQuickAddPage: View {
    @Environment(\.theme) private var theme

    var body: some View {
        GuidePage(
            title: "Log spending in seconds",
            text: "The + button opens Quick Add: amount, payee, done. Nidget learns your payees and fills in the category next time. The little check means your bank confirmed that transaction. A lock means it is reconciled and settled."
        ) {
            VStack(spacing: theme.layout.spacing) {
                HStack(spacing: theme.layout.spacing) {
                    plusButton
                        .guideSpotlight(cornerRadius: 30, inset: 6)
                    Image(systemName: "arrow.right")
                        .font(theme.font(.caption))
                        .fontWeight(theme.icons.weight)
                        .foregroundStyle(theme.palette.textTertiary)
                    keypadCard
                        .frame(width: 164)
                }
                transactionRow
                    .themedCard(padding: 12)
                calloutRow
            }
        }
    }

    private var plusButton: some View {
        Image(systemName: "plus")
            .font(theme.font(.title))
            .fontWeight(theme.icons.weight)
            .symbolVariant(theme.icons.fill ? .fill : .none)
            .foregroundStyle(theme.palette.onAccent)
            .frame(width: 52, height: 52)
            .background {
                Circle()
                    .fill(theme.palette.accent)
                    .shadow(color: theme.effects.glowAccents ? theme.palette.accent.opacity(0.5) : .clear,
                            radius: theme.effects.glowAccents ? 10 : 0)
            }
    }

    private var keypadCard: some View {
        VStack(spacing: 6) {
            AmountText(Money(cents: -450), style: .title)
                .frame(maxWidth: .infinity, alignment: .trailing)
            keypadRow(["1", "2", "3"])
            keypadRow(["4", "5", "6"])
        }
        .themedCard(padding: 10)
    }

    private func keypadRow(_ labels: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(theme.font(.subheadline).monospacedDigit())
                    .foregroundStyle(theme.palette.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background {
                        keyShape.fill(theme.palette.fill)
                    }
            }
        }
    }

    private var keyShape: AnyShape {
        theme.shape.buttonsAreCapsule ? AnyShape(Capsule()) : AnyShape(theme.controlShape)
    }

    private var transactionRow: some View {
        HStack(spacing: theme.layout.spacing * 0.75) {
            MockClearedCheck()
            VStack(alignment: .leading, spacing: 3) {
                Text("Blue Bottle Coffee")
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                MockChip(text: "Eating Out")
            }
            Spacer(minLength: 8)
            AmountText(Money(cents: -450), style: .body)
        }
    }

    private var calloutRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up")
                .font(theme.font(.caption))
                .fontWeight(theme.icons.weight)
                .foregroundStyle(theme.palette.accent)
            Text("Cleared by your bank")
                .font(theme.font(.label))
                .foregroundStyle(theme.palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
    }
}

/// The cleared indicator exactly as TransactionRow draws it: an accent-ringed circle with a
/// bold little check inside.
private struct MockClearedCheck: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(theme.palette.accent, lineWidth: 1.5)
                .frame(width: 18, height: 18)
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.palette.accent)
        }
    }
}

// MARK: - Page 4: accounts + sync

struct GuideAccountsPage: View {
    @Environment(\.theme) private var theme

    var body: some View {
        GuidePage(
            title: "Accounts and sync",
            text: "On-budget accounts feed your envelopes. Off-budget accounts, like investments, just track what you own. Bank imports you set up on your Actual server show up here automatically. Everything works offline and syncs to your server when it can, and the little pill up top keeps you posted."
        ) {
            VStack(spacing: theme.layout.spacing) {
                HStack(spacing: theme.layout.spacing * 0.75) {
                    MockAccountCard(name: "Checking", tag: "On budget",
                                    highlighted: true, amount: Money(cents: 231406))
                    MockAccountCard(name: "Brokerage", tag: "Off budget",
                                    highlighted: false, amount: Money(cents: 4820000))
                }
                HStack(spacing: theme.layout.spacing * 0.75) {
                    MockSyncPill(systemImage: "arrow.triangle.2.circlepath", text: "Syncing", spinning: true)
                        .guideSpotlight(cornerRadius: 20, inset: 5)
                    MockSyncPill(systemImage: "wifi.slash", text: "Offline · 2 pending")
                }
            }
        }
    }
}

private struct MockAccountCard: View {
    let name: String
    let tag: String
    let highlighted: Bool
    let amount: Money

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(theme.font(.headline))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            Text(tag)
                .font(theme.font(.label))
                .foregroundStyle(highlighted ? theme.palette.accent : theme.palette.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    Capsule().fill(highlighted ? theme.palette.accent.opacity(0.16) : theme.palette.fill)
                }
            AmountText(amount, style: .body, colorized: false)
        }
        .themedCard(padding: 12)
    }
}

/// A miniature of RootView's sync status pill, including the gentle spin while "syncing".
private struct MockSyncPill: View {
    let systemImage: String
    let text: String
    var spinning = false

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(theme.font(.caption))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .symbolEffect(.rotate, options: .repeat(.continuous),
                              isActive: spinning && !reduceMotion)
                .foregroundStyle(theme.palette.accent)
            Text(text)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            Capsule()
                .fill(theme.palette.surface)
                .overlay(Capsule().strokeBorder(theme.palette.surfaceBorder, lineWidth: 1))
        }
    }
}

// MARK: - Page 5: the dashboard

struct GuideDashboardPage: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GuidePage(
            title: "Your dashboard",
            text: "Everything that matters fits on one screen. Press and hold any tile to rearrange, resize, or swap in a different widget. Tap a tile to jump straight to that part of the app."
        ) {
            VStack(spacing: theme.layout.spacing * 0.75) {
                HStack(spacing: theme.layout.spacing * 0.75) {
                    MockTile(title: "To Budget") {
                        AmountText(Money(cents: 62000), style: .title)
                    }
                    jigglingTile
                        .guideSpotlight(cornerRadius: theme.shape.cornerRadius, inset: 5)
                }
                HStack(spacing: theme.layout.spacing * 0.75) {
                    MockTile(title: "Net Worth") {
                        Sparkline(values: [3.0, 3.4, 3.2, 3.8, 4.1, 4.0, 4.6])
                            .frame(height: 30)
                    }
                    MockTile(title: "Month") {
                        VStack(alignment: .leading, spacing: 6) {
                            MockProgressBar(fraction: 0.32)
                            Text("Day 10 of 31")
                                .font(theme.font(.caption))
                                .foregroundStyle(theme.palette.textSecondary)
                        }
                    }
                }
            }
            .frame(maxWidth: 320)
        }
    }

    /// The edit-mode wobble, drawn with a TimelineView like BrandRingMark so no Animation
    /// objects are involved and Reduce Motion gets a perfectly still tile.
    private var jigglingTile: some View {
        Group {
            if reduceMotion {
                spendingTile
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    spendingTile
                        .rotationEffect(.degrees(sin(t * 12) * 1.6))
                }
            }
        }
    }

    private var spendingTile: some View {
        MockTile(title: "Spending") {
            HStack(spacing: 8) {
                ProgressRing(progress: 0.62, lineWidth: 5)
                    .frame(width: 36, height: 36)
                AmountText(Money(cents: -84250), style: .caption)
            }
        }
    }
}

private struct MockTile<Content: View>: View {
    let title: String
    let content: Content

    @Environment(\.theme) private var theme

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(theme.font(.label))
                .foregroundStyle(theme.palette.textSecondary)
                .textCase(theme.typography.labelCase)
                .tracking(theme.typography.labelTracking)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            content
            Spacer(minLength: 0)
        }
        .frame(minHeight: 66, alignment: .topLeading)
        .themedCard(padding: 10)
    }
}

// MARK: - Page 6: retirement

struct GuideRetirementPage: View {
    @Environment(\.theme) private var theme

    private static let values: [Double] = [12, 14, 16, 19, 22, 26, 30, 35, 41, 48, 56, 65, 75, 86, 98]
    private static let threshold: Double = 65

    var body: some View {
        GuidePage(
            title: "Retirement",
            text: "Link your investment accounts and Nidget works out when work becomes optional, using what you actually spend. Drag on the chart to explore any age. The sliders show how saving a little more, or spending a little less, moves the date."
        ) {
            VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
                chart
                    .frame(height: 140)
                HStack {
                    Text("Age 30")
                    Spacer(minLength: 0)
                    Text("Age 70")
                }
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
            }
            .themedCard(padding: 14)
        }
    }

    private var chart: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let minValue = Self.values.min() ?? 0
            let maxValue = Self.values.max() ?? 1
            let range = max(maxValue - minValue, 1)
            let lineY = size.height * CGFloat(1 - (Self.threshold - minValue) / range)
            let crossIndex = Self.values.firstIndex { $0 >= Self.threshold } ?? (Self.values.count - 1)
            let crossX = size.width * CGFloat(crossIndex) / CGFloat(max(Self.values.count - 1, 1))
            ZStack(alignment: .topLeading) {
                Sparkline(values: Self.values)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: lineY))
                    path.addLine(to: CGPoint(x: size.width, y: lineY))
                }
                .stroke(theme.palette.textSecondary,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                Text("Enough to retire")
                    .font(theme.font(.label))
                    .foregroundStyle(theme.palette.textSecondary)
                    .position(x: size.width * 0.28, y: lineY - 12)
                Circle()
                    .fill(theme.palette.accent)
                    .frame(width: 9, height: 9)
                    .guideSpotlight(cornerRadius: 12, inset: 6)
                    .position(x: crossX, y: lineY)
                Text("Age 58")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textPrimary)
                    .position(x: crossX, y: lineY + 18)
            }
        }
    }
}

// MARK: - Page 7: Intelligence

struct GuideIntelligencePage: View {
    @Environment(\.theme) private var theme

    var body: some View {
        GuidePage(
            title: "Intelligence",
            text: "This part is optional. Download a small model from Hugging Face and Nidget can suggest categories and find transactions by meaning, like \u{201C}that sushi place\u{201D}. Everything runs right on your phone. Nothing ever leaves it."
        ) {
            VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
                suggestionCard
                searchCard
            }
        }
    }

    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New payee: Bean There")
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textSecondary)
            HStack(spacing: 8) {
                MockSparkleChip(text: "Coffee Shops")
                    .guideSpotlight(cornerRadius: 18, inset: 5)
                MockChip(text: "Groceries")
                MockChip(text: "Fun")
            }
        }
        .themedCard(padding: 12)
    }

    private var searchCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(theme.font(.subheadline))
                .fontWeight(theme.icons.weight)
                .foregroundStyle(theme.palette.textTertiary)
            Text("that sushi place")
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "sparkles")
                .font(theme.font(.subheadline))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.accent)
        }
        .themedCard(padding: 12)
    }
}

/// The Quick Add on-device suggestion chip, exactly as QuickAddView styles it.
private struct MockSparkleChip: View {
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(theme.font(.caption))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
            Text(text)
                .lineLimit(1)
        }
        .font(theme.font(.subheadline))
        .fontWeight(.semibold)
        .foregroundStyle(theme.palette.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            Capsule().fill(theme.palette.accent.opacity(0.16))
        }
    }
}

// MARK: - Small shared mocks

/// The thin spent/budgeted bar from CategoryRow, at mock scale.
private struct MockProgressBar: View {
    let fraction: Double

    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.palette.fill)
                Capsule()
                    .fill(theme.accentGradient)
                    .frame(width: max(0, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

/// A neutral category chip, matching TransactionRow's chip treatment.
private struct MockChip: View {
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(theme.font(.caption))
            .foregroundStyle(theme.palette.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(theme.palette.fill)
            }
    }
}
