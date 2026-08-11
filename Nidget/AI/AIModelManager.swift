// Ported from HomeBoy (nphil/HomeBoy) — keep in sync deliberately, not automatically.
import Foundation
import Observation
import os

/// Progress of an `EmbeddingIndex` reindex, mirrored on `AIModelManager` for the UI.
struct AIIndexingProgress: Sendable, Equatable {
    var done: Int
    var total: Int
}

/// Which backend writes text. Only generation has a choice: embeddings are llama.cpp only,
/// because Apple's framework exposes no embedding API Nidget's index could use.
enum GenerationEngineKind: String, CaseIterable, Identifiable, Sendable {
    /// A GGUF model the user downloaded, run through llama.cpp. The default.
    case llama
    /// The phone's own Apple model, nothing to download.
    case apple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .llama: return "Downloaded model"
        case .apple: return "Apple on-device"
        }
    }
}

/// Top-level on-device AI coordinator: owns model selection, the download list, and the
/// two llama.cpp worker engines (embedding + generation). Ported from HomeBoy's
/// AIModelManager / EmbeddingService / GenerationEngine trio, persisting through `Preferences`
/// instead of raw UserDefaults keys. All blocking llama calls run on the nested `Engine` worker
/// actor, never the main thread.
///
/// It is also the router for the two generation backends: a downloaded GGUF model (the default)
/// and Apple's built-in on-device model (`FoundationModelEngine`). Text features call
/// `generate(...)` and never pick a backend themselves. Embeddings stay llama.cpp only.
@MainActor @Observable
final class AIModelManager {
    static let shared = AIModelManager()

    private static let log = Logger(subsystem: "app.nidget", category: "ai")

    // MARK: - Selection & settings (persisted via Preferences — docs/AI.md §2)

    /// User-added model specs (from the Hugging Face browser). All Nidget models are custom.
    var customModels: [ModelSpec] {
        didSet { persistCustomModels() }
    }

    /// Selected embedding model id; nil = semantic features off.
    var embeddingModelID: String? {
        didSet {
            Preferences.shared.aiEmbeddingModelID = embeddingModelID
            configureEmbedder()
        }
    }

    /// Selected generation model id; nil = LLM refinement off.
    var generationModelID: String? {
        didSet {
            Preferences.shared.aiGenerationModelID = generationModelID
            configureGenerator()
        }
    }

    /// Which backend writes text (docs/AI.md §6). Defaults to `.llama` so existing setups keep
    /// behaving exactly as they did.
    var generationEngine: GenerationEngineKind {
        didSet { Preferences.shared.aiGenerationEngine = generationEngine.rawValue }
    }

    /// Execution backend for both engines (HomeBoy keeps a per-model map; Nidget uses one
    /// global preference per docs/AI.md §4).
    var backend: LlamaBackend {
        didSet {
            Preferences.shared.aiBackend = backend.rawValue
            configureEmbedder()
            configureGenerator()
        }
    }

    /// Minutes of idle time before a loaded model is freed (0 = never auto-unload).
    var autoUnloadMinutes: Int {
        didSet {
            Preferences.shared.aiAutoUnloadMinutes = autoUnloadMinutes
            configureEmbedder()
            configureGenerator()
        }
    }

    /// Hugging Face token for gated repos. Session-only — deliberately not persisted
    /// (HomeBoy stores it in UserDefaults; a credential does not belong there).
    var hfToken: String = ""

    // MARK: - Live status (for the Intelligence screen)

    private(set) var embedderStatus = EngineStatus()
    private(set) var generatorStatus = EngineStatus()

    /// Mirror of the embedding index's reindex progress; nil when idle.
    private(set) var indexingProgress: AIIndexingProgress?

    /// Called by `EmbeddingIndex` as a reindex advances.
    func setIndexingProgress(_ progress: AIIndexingProgress?) {
        indexingProgress = progress
    }

    // MARK: - Worker engines

    let embedder = Engine(purpose: .embedding)
    let generator = Engine(purpose: .generation)

    /// Apple's built-in on-device model. Always present as an object; it reports its own
    /// availability and returns nil when it can't run (see FoundationModelEngine).
    let foundationModel = FoundationModelEngine.shared

    private init() {
        let prefs = Preferences.shared
        customModels = Self.decodeCustomModels(prefs.aiCustomModelsJSON)
        embeddingModelID = prefs.aiEmbeddingModelID
        generationModelID = prefs.aiGenerationModelID
        generationEngine = GenerationEngineKind(rawValue: prefs.aiGenerationEngine) ?? .llama
        backend = LlamaBackend(rawValue: prefs.aiBackend) ?? .auto
        autoUnloadMinutes = prefs.aiAutoUnloadMinutes

        // Surface live engine status (loaded / backend / unload countdown) to the UI.
        Task {
            await self.embedder.setReporter { [weak self] status in
                Task { @MainActor in self?.embedderStatus = status }
            }
        }
        Task {
            await self.generator.setReporter { [weak self] status in
                Task { @MainActor in self?.generatorStatus = status }
            }
        }

        // Property observers don't fire during init — push the initial config manually.
        configureEmbedder()
        configureGenerator()

        // Re-point the engines whenever a download finishes (a model becomes ready).
        ModelDownloadManager.shared.onStatesChanged = { [weak self] in
            self?.configureEmbedder()
            self?.configureGenerator()
        }
    }

    // MARK: - Model management

    func allModels(_ purpose: ModelPurpose) -> [ModelSpec] {
        ModelCatalog.builtIn(purpose) + customModels.filter { $0.purpose == purpose }
    }

    func spec(id: String) -> ModelSpec? {
        ModelCatalog.spec(id: id, customs: customModels)
    }

    func download(_ spec: ModelSpec) {
        ModelDownloadManager.shared.download(spec, hfToken: hfToken)
    }

    func addCustomModel(_ spec: ModelSpec) {
        if !customModels.contains(where: { $0.id == spec.id }) { customModels.append(spec) }
        // Auto-select the first downloaded model of each kind so it's usable immediately.
        if spec.purpose == .embedding, embeddingModelID == nil { embeddingModelID = spec.id }
        if spec.purpose == .generation, generationModelID == nil { generationModelID = spec.id }
        download(spec)
    }

    func deleteModel(_ id: String) {
        ModelDownloadManager.shared.delete(id)
        customModels.removeAll { $0.id == id }
        if embeddingModelID == id { embeddingModelID = nil }
        if generationModelID == id { generationModelID = nil }
        configureEmbedder()
        configureGenerator()
    }

    // MARK: - Generation router (docs/AI.md §6)

    /// The backend `generate` would use right now, or nil when neither can write anything.
    ///
    /// Order: the chosen engine first, then whatever else can actually answer. The last branch
    /// matters — a phone with Apple Intelligence on and nothing downloaded still gets working
    /// text features even though the stored preference says "llama", which is what keeps
    /// `generationReady` an honest promise for the buttons that check it.
    var activeGenerationEngine: GenerationEngineKind? {
        if generationEngine == .apple, foundationModel.isAvailable { return .apple }
        if llamaGenerationReady { return .llama }
        if foundationModel.isAvailable { return .apple }
        return nil
    }

    /// True when either backend can currently produce text. Features gate their AI-only UI on
    /// this rather than on `generationModelID`, so an Apple-only setup isn't treated as empty.
    var generationReady: Bool { activeGenerationEngine != nil }

    /// A generation model is selected and its file is on disk.
    var llamaGenerationReady: Bool {
        guard let id = generationModelID else { return false }
        return ModelDownloadManager.shared.isReady(id)
    }

    /// The single entry point for every text feature. Routes to Apple's on-device model or to
    /// the llama.cpp generator, and if Apple comes back empty falls through to llama rather
    /// than giving up (only when a downloaded model is actually there to fall through to).
    /// The llama arguments are passed straight through, so that path behaves exactly as before.
    ///
    /// `allowLlamaFallback: false` makes an Apple miss final. Callers running inside a sync pass
    /// false unless the llama model happens to be loaded already, because falling through would
    /// cold-load a multi-hundred-megabyte model mid-sync — the exact thing
    /// `CategorySuggestionService`'s "only when already loaded" rule exists to prevent.
    func generate(system: String, user: String,
                  maxTokens: Int32 = 128, temperature: Float = 0.4, topK: Int32 = 20,
                  allowLlamaFallback: Bool = true) async -> String? {
        if activeGenerationEngine == .apple {
            if let reply = await foundationModel.generate(system: system, user: user,
                                                          temperature: Double(temperature)) {
                return reply
            }
            guard allowLlamaFallback, llamaGenerationReady else { return nil }
        }
        return await generator.chat(system: system, user: user,
                                    maxTokens: maxTokens, temperature: temperature, topK: topK)
    }

    // MARK: - Engine lifecycle

    func engine(for purpose: ModelPurpose) -> Engine {
        purpose == .embedding ? embedder : generator
    }

    /// Load the selected model for `purpose` right now (Intelligence screen "Load" button,
    /// benchmarks). Normally engines load lazily on first use.
    func loadModel(_ purpose: ModelPurpose) async {
        let id = modelID(for: purpose)
        let target = engine(for: purpose)
        await target.configure(modelID: id, path: readyPath(id),
                               backend: backend, unloadMinutes: autoUnloadMinutes)
        let loaded = await target.load()
        if !loaded {
            Self.log.notice("Load failed for \(purpose.rawValue, privacy: .public) engine")
        }
    }

    /// Free the model for `purpose` immediately.
    func unloadModel(_ purpose: ModelPurpose) async {
        await engine(for: purpose).unload()
    }

    func configureEmbedder() {
        let id = embeddingModelID
        let path = readyPath(id)
        let b = backend
        let minutes = autoUnloadMinutes
        Task { await self.embedder.configure(modelID: id, path: path, backend: b, unloadMinutes: minutes) }
    }

    func configureGenerator() {
        let id = generationModelID
        let path = readyPath(id)
        let b = backend
        let minutes = autoUnloadMinutes
        Task { await self.generator.configure(modelID: id, path: path, backend: b, unloadMinutes: minutes) }
    }

    private func modelID(for purpose: ModelPurpose) -> String? {
        purpose == .embedding ? embeddingModelID : generationModelID
    }

    private func readyPath(_ id: String?) -> String? {
        guard let id, ModelDownloadManager.shared.isReady(id) else { return nil }
        return ModelDownloadManager.modelPath(id).path
    }

    // MARK: - Persistence (through Preferences)

    private func persistCustomModels() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(customModels),
           let json = String(data: data, encoding: .utf8) {
            Preferences.shared.aiCustomModelsJSON = json
        }
    }

    private static func decodeCustomModels(_ json: String) -> [ModelSpec] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let specs = try? JSONDecoder().decode([ModelSpec].self, from: data) else {
            return []
        }
        return specs
    }

    // MARK: - Worker actor

    /// Worker actor owning one llama.cpp model handle. Every blocking llama call happens
    /// here, never on the main thread. Merges HomeBoy's EmbeddingService GGUF path (lazy
    /// load, GPU health probe, asymmetric nomic/BGE prefixes) with its GenerationEngine
    /// (chat, idle auto-unload via the use-token pattern).
    actor Engine {
        nonisolated let purpose: ModelPurpose

        private var modelID: String?
        private var path: String?
        private var backend: LlamaBackend = .auto
        private var unloadMinutes = 5
        private var handle: UInt64?
        private var triedLoad = false
        private var engaged: LlamaBackend?
        private var lastBackend: LlamaBackend?
        private var unloadAt: Date?
        private var useToken = 0
        private var reporter: (@Sendable (EngineStatus) -> Void)?

        private static let log = Logger(subsystem: "app.nidget", category: "ai")

        init(purpose: ModelPurpose) {
            self.purpose = purpose
        }

        func setReporter(_ reporter: @escaping @Sendable (EngineStatus) -> Void) {
            self.reporter = reporter
            report()
        }

        /// Point the engine at a model file. Unloads any previous model when the
        /// selection, file, or backend changes (ported from HomeBoy).
        func configure(modelID: String?, path: String?, backend: LlamaBackend, unloadMinutes: Int) {
            if modelID != self.modelID || path != self.path || backend != self.backend {
                unload()
                self.modelID = modelID
                self.path = path
                self.backend = backend
            }
            self.unloadMinutes = unloadMinutes
            report()
        }

        var isLoaded: Bool { handle != nil }

        /// Load immediately (instead of lazily on first use). Returns false on failure.
        @discardableResult
        func load() -> Bool {
            triedLoad = false
            guard ensureLoaded() != nil else {
                report()
                return false
            }
            touch()
            return true
        }

        func unload() {
            if let h = handle {
                LlmKit.free(h)
                handle = nil
            }
            if let e = engaged { lastBackend = e }
            engaged = nil
            unloadAt = nil
            triedLoad = false
            report()
        }

        /// Embed one text with the asymmetric retrieval prefix applied.
        /// nil when no embedding model is configured/loadable.
        func embed(_ text: String, isQuery: Bool) -> [Float]? {
            guard purpose == .embedding, let h = ensureLoaded() else { return nil }
            touch()
            let vector = LlmKit.embed(h, text: prefix(isQuery: isQuery) + text)
            return vector.isEmpty ? nil : vector
        }

        /// Embed a batch in a single actor hop (one idle-timer touch for the whole batch).
        func embedBatch(_ texts: [String], isQuery: Bool) -> [[Float]?] {
            guard purpose == .embedding, let h = ensureLoaded() else {
                return texts.map { _ in nil }
            }
            touch()
            let p = prefix(isQuery: isQuery)
            return texts.map { text in
                let vector = LlmKit.embed(h, text: p + text)
                return vector.isEmpty ? nil : vector
            }
        }

        /// Run a chat completion. nil when no generation model is configured/loadable.
        func chat(system: String, user: String,
                  maxTokens: Int32 = 128, temperature: Float = 0.4, topK: Int32 = 20) -> String? {
            guard purpose == .generation, let h = ensureLoaded() else { return nil }
            touch()
            return LlmKit.chat(h, system: system, user: user,
                               maxTokens: maxTokens, temperature: temperature, topK: topK)
        }

        /// Chat with timing + token counts, for the benchmark screen.
        func chatBenchmark(system: String, user: String,
                           maxTokens: Int32 = 96, temperature: Float = 0.4,
                           topK: Int32 = 20) -> LlmKit.ChatBenchmark? {
            guard purpose == .generation, let h = ensureLoaded() else { return nil }
            touch()
            return LlmKit.chatBenchmark(h, system: system, user: user,
                                        maxTokens: maxTokens, temperature: temperature, topK: topK)
        }

        // MARK: Internals

        private func ensureLoaded() -> UInt64? {
            if let h = handle { return h }
            if triedLoad { return nil }
            triedLoad = true
            guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
            // Metal embedding graphs CAN misbehave on some GPUs (garbage / non-deterministic
            // vectors that slip past a NaN check), so every embedding GPU load must pass a
            // strict probe (finite + deterministic) or fall back to CPU. On healthy GPUs
            // Metal is correct AND much faster, so .auto prefers it; the probe is the net.
            let order: [LlamaBackend]
            switch backend {
            case .cpu:        order = [.cpu]
            case .gpu, .auto: order = [.gpu, .cpu]
            }
            for candidate in order {
                guard let h = LlmKit.loadModel(path: path,
                                               embeddings: purpose == .embedding,
                                               backend: candidate) else { continue }
                if purpose == .embedding, !probeIsHealthy(h) {
                    LlmKit.free(h)
                    continue
                }
                handle = h
                engaged = candidate
                report()
                Self.log.info("Loaded \(self.purpose.rawValue, privacy: .public) model on \(candidate.rawValue, privacy: .public)")
                return h
            }
            Self.log.notice("No backend could load the \(self.purpose.rawValue, privacy: .public) model")
            return nil
        }

        /// A backend is healthy only if it returns finite, non-degenerate, and
        /// *deterministic* embeddings — embedding the same text twice must match.
        private func probeIsHealthy(_ handle: UInt64) -> Bool {
            let a = LlmKit.embed(handle, text: "lubricant for the door hinge")
            guard a.count > 1, !a.contains(where: { $0.isNaN || $0.isInfinite }) else { return false }
            if a.allSatisfy({ $0 == 0 }) { return false }
            let b = LlmKit.embed(handle, text: "lubricant for the door hinge")
            guard b.count == a.count else { return false }
            var diff: Float = 0
            for i in 0..<a.count { diff += abs(a[i] - b[i]) }
            return diff < 1e-3
        }

        /// Asymmetric retrieval prefixes (quality degrades badly if omitted for nomic/BGE).
        private func prefix(isQuery: Bool) -> String {
            let id = (modelID ?? "").lowercased()
            if id.contains("nomic") { return isQuery ? "search_query: " : "search_document: " }
            if id.contains("bge") {
                return isQuery ? "Represent this sentence for searching relevant passages: " : ""
            }
            return ""
        }

        /// Reset the idle-unload countdown after the engine is used (HomeBoy token pattern).
        private func touch() {
            useToken += 1
            guard unloadMinutes > 0 else {
                unloadAt = nil
                report()
                return
            }
            unloadAt = Date().addingTimeInterval(Double(unloadMinutes) * 60)
            scheduleUnload(token: useToken)
            report()
        }

        private func scheduleUnload(token: Int) {
            let minutes = unloadMinutes
            Task {
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
                await self.unloadIfIdle(token)
            }
        }

        private func unloadIfIdle(_ token: Int) {
            if token == useToken, handle != nil { unload() }   // no newer use since → free it
        }

        private func report() {
            reporter?(EngineStatus(modelId: modelID,
                                   loaded: handle != nil,
                                   backend: handle != nil ? engaged : nil,
                                   lastBackend: engaged ?? lastBackend,
                                   unloadAt: handle != nil ? unloadAt : nil))
        }
    }
}
