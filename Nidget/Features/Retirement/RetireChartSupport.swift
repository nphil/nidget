import SwiftUI
import Charts

// MARK: - Retire chart support
//
// The shared layer every Retire chart and card builds on, implemented once so the old bug
// classes cannot recur file by file: rounded age ticks (with the empty-domain fallback), the
// scrub callout pill with its overflow resolution baked in, categorical chart colors that can
// never collide with the palette's status colors, the deduplicated age/span text helpers, the
// place names, the tile and pill components, and the one keypad sheet the whole tab uses.

// MARK: - Household plan result types
//
// What one run of the household engine hands back, carried from the detached compute task in
// HouseholdPlanModel to every card and chart. Everything is Sendable so it can cross that
// boundary; everything is plain data so the views stay dumb and the model owns all the state.

/// The headline numbers `HouseholdPlanner.fiSummary` works out, in a named struct so it can ride
/// out of a detached task and into the glance and the drill-ins.
struct HouseholdSummary: Sendable, Equatable {
    var fiTarget: Double
    var portfolioAtTarget: Double
    var fiPct: Double
    var netWorthAtTarget: Double
    var debtFreeYearIndex: Int?
    var dpHitYearIndex: Int?
}

/// One complete plan: the projection, its summary, and the monthly debt payoff run beside it.
struct HouseholdPlanResult: Sendable {
    var config: HouseholdPlanConfig
    var rows: [HouseholdYear]
    var summary: HouseholdSummary
    var accounts: [DebtAccount]
    var strategy: DebtStrategy
    var monthlyDebtBudget: Double
    var debt: DebtSimResult

    /// The row the summary is reported against: the target age, or the last row when the target
    /// sits past the horizon.
    var targetRow: HouseholdYear? {
        rows.first { $0.ageA == config.targetRetirementAge } ?? rows.last
    }
}

// MARK: - Age axis ticks

/// Multiples of `step` that sit fully inside the closed domain, for every age axis in the tab.
/// A domain too narrow to contain a multiple falls back to the endpoints so short plans still
/// label their axis.
func roundAgeTicks(min minAge: Double, max maxAge: Double, step: Double = 5) -> [Double] {
    guard minAge.isFinite, maxAge.isFinite, maxAge >= minAge, step > 0 else { return [] }
    var ticks: [Double] = []
    var tick = (minAge / step).rounded(.up) * step
    while tick <= maxAge {
        ticks.append(tick)
        tick += step
    }
    if ticks.isEmpty {
        return minAge == maxAge ? [minAge] : [minAge, maxAge]
    }
    return ticks
}

// MARK: - Shared text helpers

/// Rounds an age for display, clamped to something a human could be.
func clampedAge(_ age: Double) -> Int {
    guard age.isFinite else { return 0 }
    return Int(min(max(age.rounded(), 0), 150))
}

/// "about 7 months" / "about 3 years" for a shift of that many months; the sign is ignored so
/// callers can write their own "closer" or "later" around it.
func spanText(months: Int) -> String {
    let magnitude = abs(months)
    if magnitude == 1 { return "about a month" }
    if magnitude < 24 { return "about \(magnitude) months" }
    let years = Int((Double(magnitude) / 12.0).rounded())
    return "about \(years) years"
}

// MARK: - HouseholdCopy

/// Every city and state name the household plan shows, in one place. View files never carry a
/// literal place name; the day the plan points somewhere else, this is the whole edit.
enum HouseholdCopy {
    static let homeCity = "Atlanta"
    static let homeState = "Georgia"
    static let nextCity = "Tacoma"
    static let nextState = "Washington"
}

// MARK: - ChartRole

/// Categorical chart colors by role. Roles map to `palette.chart` indexes 0, 1, 3 and 5 by
/// construction; slots 2 and 4 are skipped deliberately because they match `palette.positive`
/// and `palette.negative` in the default theme, and a categorical series must never wear a
/// status color by accident. This enum is the ONLY place `palette.chart` is ever indexed.
enum ChartRole: CaseIterable {
    case role0, role1, role2, role3

    private var paletteIndex: Int {
        switch self {
        case .role0: return 0
        case .role1: return 1
        case .role2: return 3
        case .role3: return 5
        }
    }

    func color(in palette: ThemePalette) -> Color {
        palette.chart[paletteIndex % palette.chart.count]
    }

    /// Fixed rotation for coloring a list of entities by stable position (debt accounts).
    static let cycle: [ChartRole] = [.role0, .role1, .role2, .role3]

    /// Cycled color for a stable position in a list.
    static func color(at position: Int, in palette: ThemePalette) -> Color {
        let index = ((position % cycle.count) + cycle.count) % cycle.count
        return cycle[index].color(in: palette)
    }
}

// MARK: - ChartScrubCallout

/// One value line inside the scrub callout pill: an amount with an optional trailing caption
/// ("invested", "a month", "debt").
struct ChartCalloutLine {
    var amount: Money
    var caption: String?

    init(_ amount: Money, caption: String? = nil) {
        self.amount = amount
        self.caption = caption
    }
}

/// The scrub idiom every dragging chart shares: a dashed vertical RuleMark at the scrubbed x
/// with the callout pill annotated above it, overflow resolution baked in so the pill can never
/// leave the plot at either edge. Charts pass the theme through because chart content builds
/// outside the SwiftUI environment; the pill's AmountText still reads privacy mode normally.
struct ChartScrubCallout: ChartContent {
    private let theme: Theme
    private let x: Double
    private let xName: String
    private let title: String
    private let lines: [ChartCalloutLine]

    init(theme: Theme, x: Double, xName: String = "Age", title: String,
         lines: [ChartCalloutLine]) {
        self.theme = theme
        self.x = x
        self.xName = xName
        self.title = title
        self.lines = lines
    }

    var body: some ChartContent {
        RuleMark(x: .value(xName, x))
            .foregroundStyle(theme.palette.textTertiary.opacity(0.35))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .annotation(position: .top, alignment: .center, spacing: 6,
                        overflowResolution: .init(x: .fit(to: .plot), y: .disabled)) {
                pill
            }
    }

    private var pill: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 3) {
                    AmountText(line.amount, style: .caption, colorized: false)
                    if let caption = line.caption {
                        Text(caption)
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textTertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background { theme.controlShape.fill(theme.palette.surfaceElevated) }
    }
}

// MARK: - TryingPill

/// Small accent capsule shown wherever numbers are being fed by unsaved what-if drafts, so a
/// played-with plan can never pass itself off as the saved one.
struct TryingPill: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("Trying things")
            .font(theme.font(.caption))
            .fontWeight(.semibold)
            .foregroundStyle(theme.palette.accent)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background { Capsule().fill(theme.palette.accent.opacity(0.14)) }
            .accessibilityLabel("Trying things. These numbers include unsaved changes.")
    }
}

// MARK: - RetireTile

/// Styled caption for the plain-text tile case; the generic initializer lets tiles compose
/// richer captions (AmountText plus a word, a warning-colored line) from the same pieces.
struct RetireTileCaption: View {
    private let text: String

    @Environment(\.theme) private var theme

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(theme.font(.caption))
            .foregroundStyle(theme.palette.textTertiary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }
}

/// One drill-in doorway on the glance: SectionHeader label with a chevron, one hero line, one
/// caption. The whole tile is a single tap target and it is never shorter than 96pt, so the
/// grid never reflows when a tile's content changes.
struct RetireTile<Caption: View>: View {
    private let title: String
    private let value: String
    private let caption: Caption
    private let action: () -> Void

    @Environment(\.theme) private var theme

    init(_ title: String, value: String, action: @escaping () -> Void,
         @ViewBuilder caption: () -> Caption) {
        self.title = title
        self.value = value
        self.caption = caption()
        self.action = action
    }

    var body: some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
                SectionHeader(title, trailing: { AnyView(chevron) })
                Text(value)
                    .font(theme.font(.title))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                caption
            }
            .frame(maxWidth: .infinity,
                   minHeight: max(96 - theme.layout.cardPadding * 2, 0),
                   alignment: .topLeading)
            .themedCard()
            .contentShape(theme.cardShape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(theme.font(.caption))
            .fontWeight(theme.icons.weight)
            .foregroundStyle(theme.palette.textTertiary)
            .accessibilityHidden(true)
    }
}

extension RetireTile where Caption == RetireTileCaption {
    init(_ title: String, value: String, caption: String, action: @escaping () -> Void) {
        self.init(title, value: value, action: action) { RetireTileCaption(caption) }
    }
}

// MARK: - AmountEntrySheet
//
// The one keypad sheet in the tab, standing in for the pair of amount sheets the redesign
// replaced: title and caption, a live display that ticks with `.numericText()`, the shared
// `AmountKeypad` (no sign, these are all magnitudes) and a Set button. The staged amount only
// leaves through `onSet`. Detents and the drag indicator are baked in here so every call site
// presents it the same way.

struct AmountEntrySheet: View {
    private let title: String
    private let caption: String
    private let onSet: (Money) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var amount: Money

    init(title: String, caption: String, initial: Money, onSet: @escaping (Money) -> Void) {
        self.title = title
        self.caption = caption
        self.onSet = onSet
        _amount = State(initialValue: initial)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: theme.layout.spacing) {
                header
                AmountText(amount, style: .display, colorized: false)
                    .frame(maxWidth: .infinity)
                AmountKeypad(amount: $amount, allowsSign: false)
                NidgetButton("Set Amount", systemImage: "checkmark") {
                    onSet(Money(cents: max(amount.cents, 0)))
                    dismiss()
                }
            }
            .padding(theme.layout.cardPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .themedScreen()
        .presentationDetents([.height(520), .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.font(.title))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(caption)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: theme.layout.spacing)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(theme.font(.title))
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.palette.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }
}
