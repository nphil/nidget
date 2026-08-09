import Foundation

// MARK: - Money
//
// Fixed-point money in minor units (cents), matching Actual's integer amounts exactly.
// Negative = outflow, positive = inflow (Actual's convention).

struct Money: Hashable, Sendable, Comparable, AdditiveArithmetic, Codable {
    var cents: Int64

    init(cents: Int64) { self.cents = cents }

    static let zero = Money(cents: 0)

    /// Parse a decimal string like "-12.34" (SimpleFIN amounts, user input). Returns nil on junk.
    init?(decimalString: String) {
        let trimmed = decimalString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        let scaled = NSDecimalNumber(decimal: decimal).multiplying(byPowerOf10: 2)
        self.cents = Int64((scaled.doubleValue).rounded())
    }

    var isNegative: Bool { cents < 0 }
    var magnitude: Money { Money(cents: abs(cents)) }
    var negated: Money { Money(cents: -cents) }
    var doubleValue: Double { Double(cents) / 100.0 }

    static func + (lhs: Money, rhs: Money) -> Money { Money(cents: lhs.cents + rhs.cents) }
    static func - (lhs: Money, rhs: Money) -> Money { Money(cents: lhs.cents - rhs.cents) }
    static func < (lhs: Money, rhs: Money) -> Bool { lhs.cents < rhs.cents }

    static func * (lhs: Money, rhs: Double) -> Money {
        Money(cents: Int64((Double(lhs.cents) * rhs).rounded()))
    }
}

// MARK: - Formatting

enum MoneyFormat {
    /// "$1,234.56"
    case full
    /// "$1,234" — whole units, for tight spaces where cents are noise.
    case whole
    /// "$1.2k" / "$3.4M" — widgets and axis labels.
    case compact
}

enum CurrencyFormatter {
    /// ISO 4217 code used app-wide; AppStore/Preferences sets this at launch and on change.
    nonisolated(unsafe) static var currencyCode: String = "USD"

    static func string(_ money: Money, format: MoneyFormat = .full, explicitPlus: Bool = false) -> String {
        let value = money.doubleValue
        let sign = explicitPlus && money.cents > 0 ? "+" : ""
        switch format {
        case .full:
            return sign + value.formatted(.currency(code: currencyCode))
        case .whole:
            return sign + value.formatted(.currency(code: currencyCode).precision(.fractionLength(0)))
        case .compact:
            let magnitude = abs(value)
            let symbolized = symbol()
            let neg = value < 0 ? "−" : sign
            if magnitude >= 1_000_000 {
                return "\(neg)\(symbolized)\((magnitude / 1_000_000).formatted(.number.precision(.fractionLength(0...1))))M"
            } else if magnitude >= 10_000 {
                return "\(neg)\(symbolized)\((magnitude / 1_000).formatted(.number.precision(.fractionLength(0...1))))k"
            } else {
                return neg + symbolized + magnitude.formatted(.number.precision(.fractionLength(0)))
            }
        }
    }

    static func symbol() -> String {
        let locale = Locale.current
        if locale.currency?.identifier == currencyCode, let s = locale.currencySymbol { return s }
        // Fall back to a locale that uses this currency's canonical symbol.
        return Locale(identifier: "en_US").localizedCurrencySymbol(forCurrencyCode: currencyCode) ?? currencyCode
    }
}

private extension Locale {
    func localizedCurrencySymbol(forCurrencyCode code: String) -> String? {
        switch code {
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "JPY": return "¥"
        case "INR": return "₹"
        case "CAD", "AUD", "NZD", "SGD", "HKD": return "$"
        case "CHF": return "CHF"
        default: return nil
        }
    }
}
