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
        static let aiCustomModelsJSON = "nidget.pref.aiCustomModelsJSON"
        static let aiEmbeddingModelID = "nidget.pref.aiEmbeddingModelID"
        static let aiGenerationModelID = "nidget.pref.aiGenerationModelID"
        static let aiBackend = "nidget.pref.aiBackend"
        static let aiAutoUnloadMinutes = "nidget.pref.aiAutoUnloadMinutes"
        static let aiSemanticSearch = "nidget.pref.aiSemanticSearch"
        static let aiQuickAddSuggestions = "nidget.pref.aiQuickAddSuggestions"
        static let aiAutoCategorize = "nidget.pref.aiAutoCategorize"
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

    /// Serialized `[ModelSpec]` — user-added GGUF models (AI). Empty string = none.
    var aiCustomModelsJSON: String {
        didSet { UserDefaults.standard.set(aiCustomModelsJSON, forKey: Key.aiCustomModelsJSON) }
    }

    /// Selected embedding model id (AI); nil = none selected.
    var aiEmbeddingModelID: String? {
        didSet {
            if let aiEmbeddingModelID {
                UserDefaults.standard.set(aiEmbeddingModelID, forKey: Key.aiEmbeddingModelID)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.aiEmbeddingModelID)
            }
        }
    }

    /// Selected generation model id (AI); nil = none selected.
    var aiGenerationModelID: String? {
        didSet {
            if let aiGenerationModelID {
                UserDefaults.standard.set(aiGenerationModelID, forKey: Key.aiGenerationModelID)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.aiGenerationModelID)
            }
        }
    }

    /// Raw `LlamaBackend` for the AI engines ("auto" / "gpu" / "cpu").
    var aiBackend: String {
        didSet { UserDefaults.standard.set(aiBackend, forKey: Key.aiBackend) }
    }

    /// Minutes of idle time before a loaded AI model is freed (0 = never).
    var aiAutoUnloadMinutes: Int {
        didSet { UserDefaults.standard.set(aiAutoUnloadMinutes, forKey: Key.aiAutoUnloadMinutes) }
    }

    /// Blend semantic matches into transaction search when an embedding model is installed.
    var aiSemanticSearch: Bool {
        didSet { UserDefaults.standard.set(aiSemanticSearch, forKey: Key.aiSemanticSearch) }
    }

    /// Offer AI category suggestions in Quick Add for unknown payees.
    var aiQuickAddSuggestions: Bool {
        didSet { UserDefaults.standard.set(aiQuickAddSuggestions, forKey: Key.aiQuickAddSuggestions) }
    }

    /// Auto-apply high-confidence category suggestions during SimpleFIN import.
    var aiAutoCategorize: Bool {
        didSet { UserDefaults.standard.set(aiAutoCategorize, forKey: Key.aiAutoCategorize) }
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
        aiCustomModelsJSON = defaults.string(forKey: Key.aiCustomModelsJSON) ?? ""
        aiEmbeddingModelID = defaults.string(forKey: Key.aiEmbeddingModelID)
        aiGenerationModelID = defaults.string(forKey: Key.aiGenerationModelID)
        aiBackend = defaults.string(forKey: Key.aiBackend) ?? "auto"
        aiAutoUnloadMinutes = defaults.object(forKey: Key.aiAutoUnloadMinutes) as? Int ?? 5
        aiSemanticSearch = defaults.object(forKey: Key.aiSemanticSearch) as? Bool ?? true
        aiQuickAddSuggestions = defaults.object(forKey: Key.aiQuickAddSuggestions) as? Bool ?? true
        aiAutoCategorize = defaults.bool(forKey: Key.aiAutoCategorize)
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
