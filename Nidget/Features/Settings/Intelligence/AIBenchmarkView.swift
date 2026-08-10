import SwiftUI

// MARK: - AIBenchmarkView
//
// Pushed via `Route.aiBenchmark` (ARCHITECTURE §16, docs/AI.md §4) — no NavigationStack of its
// own. One screen, two independent tests: how fast the loaded generation model replies to a
// sample categorization prompt (tokens/sec, prompt/generated token counts, prefill time) and how
// fast the loaded embedding model turns a batch of representative transaction strings into
// vectors (texts/sec). Both stay behind a load prompt until their engine is actually resident in
// memory — this screen never loads a model just by appearing, only on an explicit tap, since
// pulling a multi-hundred-MB model into memory as a side effect of looking at a benchmark screen
// would be a surprising, heavy thing to do silently.
//
// Unlike HomeBoy's version, there's no multi-model comparison matrix, backend selector, or saved
// runs here — Nidget only ever has ONE selected model per purpose and ONE backend preference
// (both already chosen on the Intelligence screen), so this screen just benchmarks whatever is
// actually loaded right now.

struct AIBenchmarkView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ai: AIModelManager { AIModelManager.shared }

    @State private var loadingGeneration = false
    @State private var loadingEmbedding = false
    @State private var generationLoadError: String?
    @State private var embeddingLoadError: String?

    @State private var runningGeneration = false
    @State private var runningEmbedding = false
    @State private var generationResult: LlmKit.ChatBenchmark?
    @State private var generationError: String?
    @State private var embeddingResult: EmbeddingBenchmarkResult?
    @State private var embeddingError: String?

    init() {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.layout.spacing) {
                SectionHeader("Generation")
                generationSection
                SectionHeader("Embedding")
                    .padding(.top, theme.layout.spacing * 0.5)
                embeddingSection
            }
            .padding(theme.layout.cardPadding)
        }
        .scrollIndicators(.hidden)
        .themedScreen()
        .navigationTitle("Benchmark")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Generation

    @ViewBuilder
    private var generationSection: some View {
        if ai.generationModelID == nil {
            promptCard(icon: "message", title: "No generation model yet",
                      message: "Add one from Intelligence, then come back to see how fast it replies.",
                      showsLoad: false, isLoading: false, error: nil, action: {})
        } else if !ai.generatorStatus.loaded {
            promptCard(icon: "message", title: generationModelName ?? "Generation model",
                      message: "Load it into memory to run the benchmark.",
                      showsLoad: true, isLoading: loadingGeneration, error: generationLoadError,
                      action: loadGeneration)
        } else {
            VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
                NidgetButton(runningGeneration ? "Running…" : "Run Benchmark", systemImage: "bolt",
                            role: .primary) { runGenerationBenchmark() }
                    .disabled(runningGeneration)
                if let generationError {
                    errorLine(generationError)
                }
                if let generationResult {
                    generationResultsCard(generationResult)
                }
            }
        }
    }

    private var generationModelName: String? {
        ai.generationModelID.flatMap { ai.spec(id: $0)?.displayName }
    }

    private func loadGeneration() {
        guard !loadingGeneration else { return }
        loadingGeneration = true
        generationLoadError = nil
        Task {
            await ai.loadModel(.generation)
            loadingGeneration = false
            if ai.generatorStatus.loaded {
                Haptics.success()
            } else {
                generationLoadError = "Couldn't load this model. Try downloading it again from Intelligence."
                Haptics.warning()
            }
        }
    }

    private func runGenerationBenchmark() {
        guard !runningGeneration else { return }
        runningGeneration = true
        generationError = nil
        Task {
            let result = await ai.generator.chatBenchmark(system: Self.benchmarkSystemPrompt,
                                                           user: Self.benchmarkUserPrompt)
            runningGeneration = false
            if let result {
                generationResult = result
                Haptics.success()
            } else {
                generationError = "Couldn't run the benchmark. Try loading the model again."
                Haptics.warning()
            }
        }
    }

    private func generationResultsCard(_ benchmark: LlmKit.ChatBenchmark) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            heroStat(benchmark.tokensPerSec, unit: "tokens per second")
            separator
            statRow("Prompt tokens", "\(benchmark.promptTokens)")
            statRow("Generated tokens", "\(benchmark.genTokens)")
            statRow("Prefill", "\(Int(benchmark.prefillMs)) ms")
            statRow("Generation time", "\(Int(benchmark.genMs)) ms")
            if !benchmark.text.isEmpty {
                separator
                Text("Sample reply")
                    .font(theme.font(.label))
                    .foregroundStyle(theme.palette.textSecondary)
                    .textCase(theme.typography.labelCase)
                    .tracking(theme.typography.labelTracking)
                Text(benchmark.text)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .themedCard()
    }

    private static let benchmarkSystemPrompt =
        "You help categorize spending. Reply with only the single most likely budget category name for the transaction below, nothing else."
    private static let benchmarkUserPrompt = "Transaction: Trader Joe's, weekly groceries\nCategory:"

    // MARK: - Embedding

    @ViewBuilder
    private var embeddingSection: some View {
        if ai.embeddingModelID == nil {
            promptCard(icon: "text.magnifyingglass", title: "No embedding model yet",
                      message: "Add one from Intelligence, then come back to see how fast it works.",
                      showsLoad: false, isLoading: false, error: nil, action: {})
        } else if !ai.embedderStatus.loaded {
            promptCard(icon: "text.magnifyingglass", title: embeddingModelName ?? "Embedding model",
                      message: "Load it into memory to run the benchmark.",
                      showsLoad: true, isLoading: loadingEmbedding, error: embeddingLoadError,
                      action: loadEmbedding)
        } else {
            VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
                NidgetButton(runningEmbedding ? "Running…" : "Run Benchmark", systemImage: "bolt",
                            role: .primary) { runEmbeddingBenchmark() }
                    .disabled(runningEmbedding)
                if let embeddingError {
                    errorLine(embeddingError)
                }
                if let embeddingResult {
                    embeddingResultsCard(embeddingResult)
                }
            }
        }
    }

    private var embeddingModelName: String? {
        ai.embeddingModelID.flatMap { ai.spec(id: $0)?.displayName }
    }

    private func loadEmbedding() {
        guard !loadingEmbedding else { return }
        loadingEmbedding = true
        embeddingLoadError = nil
        Task {
            await ai.loadModel(.embedding)
            loadingEmbedding = false
            if ai.embedderStatus.loaded {
                Haptics.success()
            } else {
                embeddingLoadError = "Couldn't load this model. Try downloading it again from Intelligence."
                Haptics.warning()
            }
        }
    }

    private func runEmbeddingBenchmark() {
        guard !runningEmbedding else { return }
        runningEmbedding = true
        embeddingError = nil
        Task {
            let start = Date()
            let vectors = await ai.embedder.embedBatch(Self.benchmarkTexts, isQuery: false)
            let elapsedMs = Date().timeIntervalSince(start) * 1000
            runningEmbedding = false
            let dims = vectors.compactMap { $0 }
            guard let first = dims.first, elapsedMs > 0 else {
                embeddingError = "Couldn't run the benchmark. Try loading the model again."
                Haptics.warning()
                return
            }
            let perSecond = Double(Self.benchmarkTexts.count) / (elapsedMs / 1000)
            embeddingResult = EmbeddingBenchmarkResult(textsPerSecond: perSecond, dimensions: first.count,
                                                        elapsedMs: elapsedMs)
            Haptics.success()
        }
    }

    private func embeddingResultsCard(_ result: EmbeddingBenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            heroStat(result.textsPerSecond, unit: "texts per second")
            separator
            statRow("Batch size", "\(Self.benchmarkTexts.count)")
            statRow("Vector size", "\(result.dimensions)")
            statRow("Elapsed", "\(Int(result.elapsedMs)) ms")
        }
        .themedCard()
    }

    /// 20 representative payee/notes pairs run through the same canonical text shape the real
    /// index uses (`EmbeddingIndex.embeddedText`), so this benchmark exercises exactly what
    /// reindexing actually embeds, not a synthetic stand-in. The intermediate array is explicitly
    /// typed so the type checker doesn't have to infer a common tuple shape across 20 literals
    /// (some carrying `nil`) on its own.
    private static let benchmarkPayeeNotes: [(payee: String, notes: String?)] = [
        ("Trader Joe's", "weekly groceries"), ("Shell", "gas fill up"), ("Netflix", nil),
        ("Chipotle", "lunch with the team"), ("Amazon", "phone case"), ("Starbucks", nil),
        ("Target", "household supplies"), ("Uber", "ride to the airport"), ("Spotify", nil),
        ("CVS Pharmacy", "prescription refill"), ("Whole Foods", "dinner ingredients"),
        ("AT&T", "phone bill"), ("Delta Air Lines", "flight to Denver"),
        ("Home Depot", "paint and brushes"), ("Planet Fitness", "monthly membership"),
        ("Costco", "bulk shopping"), ("DoorDash", "Friday takeout"), ("Chevron", nil),
        ("Apple", "app store purchase"), ("Marriott", "weekend stay"),
    ]

    private static let benchmarkTexts: [String] = benchmarkPayeeNotes.map {
        EmbeddingIndex.embeddedText(payee: $0.payee, notes: $0.notes)
    }

    // MARK: - Shared bits

    private func promptCard(icon: String, title: String, message: String, showsLoad: Bool,
                            isLoading: Bool, error: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: theme.layout.spacing * 0.6) {
            Image(systemName: icon)
                .font(theme.font(.title))
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.accent)
            Text(title)
                .font(theme.font(.headline))
                .foregroundStyle(theme.palette.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .multilineTextAlignment(.center)
            if showsLoad {
                NidgetButton(isLoading ? "Loading…" : "Load Model", systemImage: "arrow.down.circle",
                            role: .secondary, action: action)
                    .disabled(isLoading)
            }
            if let error {
                errorLine(error)
            }
        }
        .frame(maxWidth: .infinity)
        .themedCard()
    }

    private func errorLine(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(theme.font(.caption))
                .fontWeight(theme.icons.weight)
                .foregroundStyle(theme.palette.negative)
            Text(message)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.negative)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The one big numeral per test: `theme.font(.display)` per docs/AI.md, not `AmountText`
    /// (this isn't money) — still gets the same numeric content-transition treatment.
    private func heroStat(_ value: Double, unit: String) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted(.number.precision(.fractionLength(1))))
                .font(theme.font(.display))
                .monospacedDigit()
                .foregroundStyle(theme.palette.textPrimary)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : theme.motion.snappy, value: value)
            Text(unit)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textSecondary)
            Spacer(minLength: theme.layout.spacing)
            Text(value)
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
        }
        .frame(minHeight: 26)
    }

    private var separator: some View {
        Rectangle()
            .fill(theme.palette.separator)
            .frame(height: 1)
    }
}

private struct EmbeddingBenchmarkResult {
    var textsPerSecond: Double
    var dimensions: Int
    var elapsedMs: Double
}
