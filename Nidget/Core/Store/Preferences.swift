import Foundation
import Observation

// MARK: - Preferences
//
// UserDefaults-backed app preferences (ARCHITECTURE §9, amended: NO theme fields — ThemeManager
// owns its own persistence). Each stored property persists via didSet; property observers do not
// fire during init, so loading stored values in init never re-writes them.
//
// `currencyCode` additionally pushes into `CurrencyFormatter.currencyCode` so every formatted
// amount app-wide follows the preference immediately.

@MainActor @Observable
final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let dashboardLayoutJSON = "nidget.pref.dashboardLayoutJSON"
        static let currencyCode = "nidget.pref.currencyCode"
        static let biometricLock = "nidget.pref.biometricLock"
        static let privacyModeDefault = "nidget.pref.privacyModeDefault"
        static let retirementConfigJSON = "nidget.pref.retirementConfigJSON"
        static let defaultAccountID = "nidget.pref.defaultAccountID"
        static let simplefinAccountMapJSON = "nidget.pref.simplefinAccountMapJSON"
    }

    /// Serialized `[DashboardItem]` (Features/Dashboard). Empty string = use the default layout.
    var dashboardLayoutJSON: String {
        didSet { UserDefaults.standard.set(dashboardLayoutJSON, forKey: Key.dashboardLayoutJSON) }
    }

    /// ISO 4217 code used app-wide for formatting amounts.
    var currencyCode: String {
        didSet {
            UserDefaults.standard.set(currencyCode, forKey: Key.currencyCode)
            CurrencyFormatter.currencyCode = currencyCode
        }
    }

    /// Require Face ID (AppLockScreen) to open the app.
    var biometricLock: Bool {
        didSet { UserDefaults.standard.set(biometricLock, forKey: Key.biometricLock) }
    }

    /// Start each launch with amounts blurred (`AppStore.privacyMode`'s initial value).
    var privacyModeDefault: Bool {
        didSet { UserDefaults.standard.set(privacyModeDefault, forKey: Key.privacyModeDefault) }
    }

    /// Serialized `RetirementConfig` (Core/Retirement). Empty string = defaults.
    var retirementConfigJSON: String {
        didSet { UserDefaults.standard.set(retirementConfigJSON, forKey: Key.retirementConfigJSON) }
    }

    /// Account preselected in Quick Add; nil = first on-budget account.
    var defaultAccountID: String? {
        didSet {
            if let defaultAccountID {
                UserDefaults.standard.set(defaultAccountID, forKey: Key.defaultAccountID)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.defaultAccountID)
            }
        }
    }

    /// JSON object mapping SimpleFIN account id → Actual account id ("{}" when nothing mapped).
    var simplefinAccountMapJSON: String {
        didSet { UserDefaults.standard.set(simplefinAccountMapJSON, forKey: Key.simplefinAccountMapJSON) }
    }

    private init() {
        let defaults = UserDefaults.standard
        dashboardLayoutJSON = defaults.string(forKey: Key.dashboardLayoutJSON) ?? ""
        currencyCode = defaults.string(forKey: Key.currencyCode)
            ?? Locale.current.currency?.identifier ?? "USD"
        biometricLock = defaults.bool(forKey: Key.biometricLock)
        privacyModeDefault = defaults.bool(forKey: Key.privacyModeDefault)
        retirementConfigJSON = defaults.string(forKey: Key.retirementConfigJSON) ?? ""
        defaultAccountID = defaults.string(forKey: Key.defaultAccountID)
        simplefinAccountMapJSON = defaults.string(forKey: Key.simplefinAccountMapJSON) ?? "{}"
        // didSet does not run during init — push the loaded value explicitly.
        CurrencyFormatter.currencyCode = currencyCode
    }

    // MARK: Convenience

    /// Decoded view of `simplefinAccountMapJSON` (SimpleFIN account id → Actual account id).
    /// Setting re-serializes deterministically (sorted keys) and persists via the JSON property.
    var simplefinAccountMap: [String: String] {
        get {
            guard let data = simplefinAccountMapJSON.data(using: .utf8),
                  let map = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return map
        }
        set {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                simplefinAccountMapJSON = json
            }
        }
    }
}
