import SwiftUI

// MARK: - AmountKeypad
//
// Custom amount keypad used by Quick Add and the budget editors. 4 rows x 3 columns
// (1–9, decimal separator, 0, delete) plus a full-width sign toggle when `allowsSign`.
//
// Entry model (hybrid ATM/calculator):
// - Default "shift" mode: each digit shifts existing cents left — 1 → $0.01 → $0.12 → $1.23.
// - Tapping "." enters fractional mode: digits typed so far become whole units and up to two
//   further digits fill the cents — "1","2",".","3","4" → $12.34.
// - Delete pops the last keystroke (fraction digit → separator → whole digit).
// - The internal entry state resets whenever the bound amount is externally set to `.zero`,
//   and adopts external non-zero values so editing an existing amount stays consistent.

struct AmountKeypad: View {
    @Binding private var amount: Money
    private let allowsSign: Bool

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var wholeDigits = ""
    @State private var fractionDigits = ""
    @State private var hasSeparator = false
    @State private var isNegative = false

    init(amount: Binding<Money>, allowsSign: Bool = true) {
        self._amount = amount
        self.allowsSign = allowsSign
    }

    // MARK: Keys

    private enum Key: Hashable {
        case digit(Int)
        case separator
        case delete
    }

    private static let rows: [[Key]] = [
        [.digit(1), .digit(2), .digit(3)],
        [.digit(4), .digit(5), .digit(6)],
        [.digit(7), .digit(8), .digit(9)],
        [.separator, .digit(0), .delete],
    ]

    // MARK: Body

    var body: some View {
        VStack(spacing: theme.layout.spacing * 0.75) {
            ForEach(Self.rows.indices, id: \.self) { rowIndex in
                HStack(spacing: theme.layout.spacing * 0.75) {
                    ForEach(Self.rows[rowIndex], id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
            if allowsSign {
                signToggle
            }
        }
        .onAppear {
            adoptExternal(amount)
        }
        .onChange(of: amount) { _, newValue in
            adoptExternal(newValue)
        }
    }

    private func keyButton(_ key: Key) -> some View {
        Button {
            handle(key)
        } label: {
            keyLabel(key)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(keyShape.fill(theme.palette.fill))
                .contentShape(keyShape)
        }
        .buttonStyle(KeypadKeyStyle(pressAnimation: reduceMotion ? nil : theme.motion.snappy))
        .accessibilityLabel(accessibilityName(key))
    }

    @ViewBuilder
    private func keyLabel(_ key: Key) -> some View {
        switch key {
        case .digit(let digit):
            Text(String(digit))
                .font(theme.font(.title).monospacedDigit())
                .foregroundStyle(theme.palette.textPrimary)
        case .separator:
            Text(decimalSeparator)
                .font(theme.font(.title).monospacedDigit())
                .foregroundStyle(theme.palette.textPrimary)
        case .delete:
            Image(systemName: "delete.backward")
                .font(theme.font(.headline))
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .fontWeight(theme.icons.weight)
                .foregroundStyle(theme.palette.textSecondary)
        }
    }

    private var signToggle: some View {
        Button {
            isNegative.toggle()
            pushAmount()
        } label: {
            Image(systemName: "plus.forwardslash.minus")
                .font(theme.font(.headline))
                .fontWeight(theme.icons.weight)
                .foregroundStyle(theme.palette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(keyShape.fill(theme.palette.fill))
                .contentShape(keyShape)
        }
        .buttonStyle(KeypadKeyStyle(pressAnimation: reduceMotion ? nil : theme.motion.snappy))
        .accessibilityLabel("Toggle sign")
    }

    private var keyShape: AnyShape {
        theme.shape.buttonsAreCapsule ? AnyShape(Capsule()) : AnyShape(theme.controlShape)
    }

    private var decimalSeparator: String {
        Locale.current.decimalSeparator ?? "."
    }

    private func accessibilityName(_ key: Key) -> String {
        switch key {
        case .digit(let digit): return String(digit)
        case .separator: return "Decimal separator"
        case .delete: return "Delete"
        }
    }

    // MARK: Entry state

    /// Current value of the internal entry, in cents (signed).
    private var entryCents: Int64 {
        let whole = Int64(wholeDigits) ?? 0
        let raw: Int64
        if hasSeparator {
            let padded = fractionDigits.padding(toLength: 2, withPad: "0", startingAt: 0)
            raw = whole * 100 + (Int64(padded) ?? 0)
        } else {
            raw = whole // shift mode: typed digits ARE the cents
        }
        return isNegative ? -raw : raw
    }

    private func handle(_ key: Key) {
        switch key {
        case .digit(let digit):
            appendDigit(digit)
        case .separator:
            guard !hasSeparator else { return }
            hasSeparator = true
        case .delete:
            deleteLast()
        }
        pushAmount()
    }

    private func appendDigit(_ digit: Int) {
        if hasSeparator {
            guard fractionDigits.count < 2 else { return }
            fractionDigits.append(String(digit))
        } else {
            guard wholeDigits.count < 9 else { return }
            if wholeDigits.isEmpty && digit == 0 { return } // leading zeros are meaningless here
            wholeDigits.append(String(digit))
        }
    }

    private func deleteLast() {
        if !fractionDigits.isEmpty {
            fractionDigits.removeLast()
        } else if hasSeparator {
            hasSeparator = false
        } else if !wholeDigits.isEmpty {
            wholeDigits.removeLast()
        } else if isNegative {
            isNegative = false
        }
    }

    private func pushAmount() {
        amount = Money(cents: entryCents)
    }

    /// Keep internal entry state in agreement with the binding. Our own pushes arrive with a
    /// matching value and are ignored; an external `.zero` clears the entry (contract), and any
    /// other external value is adopted in shift mode so subsequent keys behave predictably.
    private func adoptExternal(_ newValue: Money) {
        guard newValue.cents != entryCents else { return }
        if newValue == .zero {
            wholeDigits = ""
            fractionDigits = ""
            hasSeparator = false
            isNegative = false
        } else {
            wholeDigits = String(newValue.cents.magnitude)
            fractionDigits = ""
            hasSeparator = false
            isNegative = newValue.cents < 0
        }
    }
}

// MARK: - KeypadKeyStyle

/// Keypad press treatment: scale to 0.94 with the theme's snappy spring and a rigid tick on
/// touch-down.
private struct KeypadKeyStyle: ButtonStyle {
    var pressAnimation: Animation?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(pressAnimation, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tick() }
            }
    }
}
