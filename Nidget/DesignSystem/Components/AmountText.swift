import SwiftUI

// MARK: - Privacy mode environment
//
// Global privacy switch. RootView injects `AppStore.privacyMode` here; every AmountText in the
// tree honors it automatically. Defaults to off.

private struct PrivacyModeEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// When true, all rendered amounts are replaced with dots (screen-share / shoulder-surf mode).
    var privacyMode: Bool {
        get { self[PrivacyModeEnvironmentKey.self] }
        set { self[PrivacyModeEnvironmentKey.self] = newValue }
    }
}

// MARK: - AmountStyle

/// Size roles for money text; each maps to a theme font role.
enum AmountStyle {
    case hero, display, title, body, caption

    var fontRole: FontRole {
        switch self {
        case .hero: return .hero
        case .display: return .display
        case .title: return .title
        case .body: return .body
        case .caption: return .caption
        }
    }
}

// MARK: - AmountText
//
// The canonical way to render money anywhere in the app. Formats through CurrencyFormatter,
// colorizes by sign through the theme palette, animates numeric changes on hero/display styles,
// and collapses to dots under explicit redaction or global privacy mode.

struct AmountText: View {
    private let amount: Money
    private let style: AmountStyle
    private let colorized: Bool
    private let showSign: Bool
    private let isRedacted: Bool

    @Environment(\.theme) private var theme
    @Environment(\.privacyMode) private var privacyMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ amount: Money, style: AmountStyle = .body, colorized: Bool = true,
         showSign: Bool = false, redacted: Bool = false) {
        self.amount = amount
        self.style = style
        self.colorized = colorized
        self.showSign = showSign
        self.isRedacted = redacted
    }

    var body: some View {
        let hidden = isRedacted || privacyMode
        let display = hidden ? "••••" : CurrencyFormatter.string(amount, explicitPlus: showSign)
        let styled = Text(display)
            .font(theme.amountFont(style.fontRole))
            .foregroundStyle(textColor(hidden: hidden))
            .lineLimit(1)
        Group {
            if style == .hero || style == .display {
                styled
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: display)
            } else {
                styled
            }
        }
        .privacySensitive(hidden)
        .accessibilityLabel(hidden ? Text("Amount hidden") : Text(display))
    }

    private func textColor(hidden: Bool) -> Color {
        guard colorized, !hidden else { return theme.palette.textPrimary }
        if amount.cents > 0 { return theme.palette.positive }
        if amount.cents < 0 { return theme.palette.negative }
        return theme.palette.textPrimary
    }
}
