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
        static let hasSeenGuide = "nidget.pref.hasSeenGuide"
        static let retirementConfigJSON = "nidget.pref.retirementConfigJSON"
        static let defaultAccountID = "nidget.pref.defaultAccountID"
        static let aiCustomModelsJSON = "nidget.pref.aiCustomModelsJSON"
        static let aiEmbeddingModelID = "nidget.pref.aiEmbeddingModelID"
        static let aiGenerationModelID = "nidget.pref.aiGenerationModelID"
        static let aiBackend = "nidget.pref.aiBackend"
        static let aiGenerationEngine = "nidget.pref.aiGenerationEngine"
        static let aiAutoUnloadMinutes = "nidget.pref.aiAutoUnloadMinutes"
        static let aiSemanticSearch = "nidget.pref.aiSemanticSearch"
        static let aiQuickAddSuggestions = "nidget.pref.aiQuickAddSuggestions"
        static let aiAutoCategorize = "nidget.pref.aiAutoCategorize"
        static let categoryIconsJSON = "nidget.pref.categoryIconsJSON"
        static let aiAutoFiledIDsJSON = "nidget.pref.aiAutoFiledIDs"
        static let themedAppIcon = "nidget.pref.themedAppIcon"
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

    /// The onboarding Guide has been seen (or skipped) once; RootView stops auto-presenting it.
    var hasSeenGuide: Bool {
        didSet { UserDefaults.standard.set(hasSeenGuide, forKey: Key.hasSeenGuide) }
    }

    /// Swap the home screen icon to the active theme's icon (`AppIcon`, Platform). Off by default:
    /// iOS announces every icon change with an alert of its own, so this has to be asked for.
    var themedAppIcon: Bool {
        didSet { UserDefaults.standard.set(themedAppIcon, forKey: Key.themedAppIcon) }
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

    /// Raw `GenerationEngineKind` for writing text ("llama" = a downloaded GGUF model,
    /// "apple" = the phone's built-in Apple model). Embeddings always stay on llama.cpp.
    var aiGenerationEngine: String {
        didSet { UserDefaults.standard.set(aiGenerationEngine, forKey: Key.aiGenerationEngine) }
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

    /// Auto-apply high-confidence category suggestions to newly synced bank transactions.
    var aiAutoCategorize: Bool {
        didSet { UserDefaults.standard.set(aiAutoCategorize, forKey: Key.aiAutoCategorize) }
    }

    /// Category id -> SF Symbol name (`CategoryIconCatalog`). Local only: Actual's server has no
    /// icon column on categories (PROTOCOL §categories), so these are never written into a CRDT
    /// message and never sync — they ride along in an iOS device backup and nothing else, the
    /// same rule the AI embedding index follows. Persisted as one JSON string.
    var categoryIcons: [String: String] {
        didSet {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(categoryIcons),
                  let json = String(data: data, encoding: .utf8) else { return }
            UserDefaults.standard.set(json, forKey: Key.categoryIconsJSON)
        }
    }

    /// Transaction ids the AI categorized on its own, with when (unix seconds), awaiting the
    /// owner's spot check. Local only: this is Nidget's own bookkeeping, it has no column on
    /// Actual's server and is never written into a CRDT message, exactly like `categoryIcons`.
    /// The review queue reads it to offer those transactions back for a look. Pruned after 30
    /// days and whenever one is confirmed, so it stays small. Persisted as one JSON string.
    var aiAutoFiledIDs: [String: Double] {
        didSet {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(aiAutoFiledIDs),
                  let json = String(data: data, encoding: .utf8) else { return }
            UserDefaults.standard.set(json, forKey: Key.aiAutoFiledIDsJSON)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        dashboardLayoutJSON = defaults.string(forKey: Key.dashboardLayoutJSON) ?? ""
        currencyCode = defaults.string(forKey: Key.currencyCode)
            ?? Locale.current.currency?.identifier ?? "USD"
        biometricLock = defaults.bool(forKey: Key.biometricLock)
        privacyModeDefault = defaults.bool(forKey: Key.privacyModeDefault)
        hasSeenGuide = defaults.bool(forKey: Key.hasSeenGuide)
        themedAppIcon = defaults.bool(forKey: Key.themedAppIcon)
        retirementConfigJSON = defaults.string(forKey: Key.retirementConfigJSON) ?? ""
        defaultAccountID = defaults.string(forKey: Key.defaultAccountID)
        aiCustomModelsJSON = defaults.string(forKey: Key.aiCustomModelsJSON) ?? ""
        aiEmbeddingModelID = defaults.string(forKey: Key.aiEmbeddingModelID)
        aiGenerationModelID = defaults.string(forKey: Key.aiGenerationModelID)
        aiBackend = defaults.string(forKey: Key.aiBackend) ?? "auto"
        aiGenerationEngine = defaults.string(forKey: Key.aiGenerationEngine) ?? "llama"
        aiAutoUnloadMinutes = defaults.object(forKey: Key.aiAutoUnloadMinutes) as? Int ?? 5
        aiSemanticSearch = defaults.object(forKey: Key.aiSemanticSearch) as? Bool ?? true
        aiQuickAddSuggestions = defaults.object(forKey: Key.aiQuickAddSuggestions) as? Bool ?? true
        aiAutoCategorize = defaults.bool(forKey: Key.aiAutoCategorize)
        categoryIcons = Self.decodeIcons(defaults.string(forKey: Key.categoryIconsJSON))
        aiAutoFiledIDs = Self.decodeAutoFiled(defaults.string(forKey: Key.aiAutoFiledIDsJSON))
        // didSet does not run during init — push the loaded value explicitly.
        CurrencyFormatter.currencyCode = currencyCode
    }

    // MARK: Category icons

    /// The symbol chosen for a category, or nil when it has none.
    func icon(forCategory id: String) -> String? {
        categoryIcons[id]
    }

    /// Sets a category's symbol; nil (or an empty name) removes the entry entirely.
    func setIcon(_ symbol: String?, forCategory id: String) {
        if let symbol, !symbol.isEmpty {
            categoryIcons[id] = symbol
        } else {
            categoryIcons.removeValue(forKey: id)
        }
    }

    // MARK: Auto-filed transactions

    /// Forgets auto-filed entries older than `days`. An unreviewed spot check stops being worth
    /// showing after a month, and this keeps the stored map from growing forever. Only assigns
    /// when something actually goes, so the common case writes nothing.
    func pruneAutoFiled(olderThan days: Double = 30) {
        guard !aiAutoFiledIDs.isEmpty else { return }
        let cutoff = Date().timeIntervalSince1970 - max(0, days) * 86_400
        let kept = aiAutoFiledIDs.filter { $0.value >= cutoff }
        guard kept.count != aiAutoFiledIDs.count else { return }
        aiAutoFiledIDs = kept
    }

    /// Stored JSON → auto-filed ids. Same defensive rule as the icons: a missing, empty, or
    /// corrupt value means "none", never a crash on launch.
    private static func decodeAutoFiled(_ json: String?) -> [String: Double] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// Stored JSON → icons. A missing, empty, or corrupt value yields no icons rather than
    /// throwing: a bad string must never keep the app from launching.
    private static func decodeIcons(_ json: String?) -> [String: String] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
