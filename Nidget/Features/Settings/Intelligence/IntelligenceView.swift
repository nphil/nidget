import SwiftUI

// MARK: - IntelligenceView
//
// Pushed via `Route.intelligence` (ARCHITECTURE §16, docs/AI.md §4) — no NavigationStack of its
// own. The whole on-device AI surface in one screen of themed cards (never a stock Form): two
// model slots (Embedding, Generation) with live load state, the shared llama.cpp backend picker,
// the three feature toggles, the semantic search index, and a link through to benchmarking.
//
// `AIModelManager`/`ModelDownloadManager` aren't environment-injected (ARCHITECTURE §16's binding
// list doesn't carry them) — they're `@MainActor @Observable` singletons read directly via
// `.shared`, the same "no locally mirrored copies, read live state every body pass" discipline
// `SettingsView` already uses for `KeychainStore`. `EmbeddingIndex` is an actor with no UI-facing
// observable state of its own beyond what `AIModelManager.indexingProgress` already mirrors, so
// its counts are pulled explicitly into local `@State` and refreshed after every reindex.
//
// Everything here degrades gracefully: with zero models ever added, the whole screen collapses to
// one friendly empty state (docs/AI.md's "single 'Add a model' CTA"); with at least one model, the
// full card stack renders and keeps working while a download runs in the background, since every
// row reads `ModelDownloadManager.shared.states` live.

struct IntelligenceView: View {
    @Environment(AppStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showHFBrowser = false
    @State private var hfBrowsePurpose: ModelPurpose = .embedding
    @State private var indexedCount = 0
    @State private var totalIndexable = 0

    /// Practically "every transaction" (matches the `fetchLimit`/`balanceFetchLimit` convention
    /// used elsewhere for "give me everything" reads — see `ReconcileSheet`/`AccountDetailView`).
    private static let transactionFetchLimit = 20_000

    private var ai: AIModelManager { AIModelManager.shared }

    init() {}

    var body: some View {
        content
            .themedScreen()
            .navigationTitle("Intelligence")
            .navigationBarTitleDisplayMode(.inline)
            .task { await refreshIndexCounts() }
            .sheet(isPresented: $showHFBrowser) {
                HuggingFaceBrowserSheet(purpose: hfBrowsePurpose)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }

    // MARK: Screen

    @ViewBuilder
    private var content: some View {
        if ai.customModels.isEmpty {
            EmptyStateView(
                systemImage: "sparkles",
                title: "No models yet",
                message: "Nidget can search and suggest categories right on your phone once you add a small model from Hugging Face. Nothing ever leaves your device.",
                actionTitle: "Add a Model",
                action: { openBrowser(for: .embedding) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.layout.spacing) {
                    SectionHeader("Models")
                    ModelSlotCard(purpose: .embedding, icon: "text.magnifyingglass", title: "Embedding") {
                        openBrowser(for: .embedding)
                    }
                    ModelSlotCard(purpose: .generation, icon: "message", title: "Generation") {
                        openBrowser(for: .generation)
                    }
                    SectionHeader("Backend")
                        .padding(.top, theme.layout.spacing * 0.5)
                    backendCard
                    SectionHeader("Search & Suggestions")
                        .padding(.top, theme.layout.spacing * 0.5)
                    togglesCard
                    SectionHeader("Index")
                        .padding(.top, theme.layout.spacing * 0.5)
                    indexCard
                    SectionHeader("Benchmark")
                        .padding(.top, theme.layout.spacing * 0.5)
                    benchmarkCard
                }
                .padding(theme.layout.cardPadding)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func openBrowser(for purpose: ModelPurpose) {
        Haptics.tap()
        hfBrowsePurpose = purpose
        showHFBrowser = true
    }

    // MARK: - Backend card

    private var backendCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.6) {
            ChipPicker(items: LlamaBackend.allCases, selection: backendBinding, label: { $0.displayName })
            Text("Auto prefers the GPU and quietly falls back to the CPU if a device can't run it there.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .themedCard()
    }

    private var backendBinding: Binding<LlamaBackend> {
        Binding(get: { ai.backend }, set: { ai.backend = $0 })
    }

    // MARK: - Toggles card

    private var togglesCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.6) {
            toggleRow(icon: "sparkle.magnifyingglass", title: "Semantic Search",
                     message: "Finds related transactions even when the words don't match exactly.",
                     isOn: semanticSearchBinding)
            separator
            toggleRow(icon: "plus.bubble", title: "Quick Add Suggestions",
                     message: "Suggests a category while you're adding a new payee.",
                     isOn: quickAddBinding)
            separator
            toggleRow(icon: "tag", title: "Auto-Categorize",
                     message: "Applies a category automatically when new bank transactions sync in.",
                     isOn: autoCategorizeBinding)
            Text("When new bank transactions arrive from your server, Nidget files the ones it is at least 75 percent sure about. The rest stay uncategorized for you.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .themedCard()
    }

    private func toggleRow(icon: String, title: String, message: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(theme.font(.subheadline))
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .foregroundStyle(theme.palette.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(theme.font(.body))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(message)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
        }
        .tint(theme.palette.accent)
        .frame(minHeight: 44)
    }

    private var semanticSearchBinding: Binding<Bool> {
        Binding(get: { preferences.aiSemanticSearch }, set: { preferences.aiSemanticSearch = $0 })
    }

    private var quickAddBinding: Binding<Bool> {
        Binding(get: { preferences.aiQuickAddSuggestions }, set: { preferences.aiQuickAddSuggestions = $0 })
    }

    private var autoCategorizeBinding: Binding<Bool> {
        Binding(get: { preferences.aiAutoCategorize }, set: { preferences.aiAutoCategorize = $0 })
    }

    // MARK: - Index card

    private var indexCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.6) {
            Text("\(indexedCount) of \(totalIndexable) transactions indexed")
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textPrimary)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : theme.motion.snappy, value: indexedCount)
            if let progress = ai.indexingProgress {
                IndexProgressBar(fraction: progressFraction(progress))
                Text("Indexing \(progress.done) of \(progress.total)…")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            NidgetButton(reindexTitle, systemImage: "arrow.triangle.2.circlepath", role: .secondary) {
                startReindex()
            }
            .disabled(!canReindex)
            if !embeddingReady {
                Text("Add and load an embedding model to build the search index.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .themedCard()
    }

    private func progressFraction(_ progress: AIIndexingProgress) -> Double {
        progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0
    }

    private var embeddingReady: Bool {
        guard let id = ai.embeddingModelID else { return false }
        return ModelDownloadManager.shared.isReady(id)
    }

    private var canReindex: Bool {
        embeddingReady && ai.indexingProgress == nil
    }

    private var reindexTitle: String {
        ai.indexingProgress != nil ? "Indexing…" : "Reindex"
    }

    private func loadTransactionRows() async -> [Transaction] {
        await store.transactions(TransactionQuery(limit: Self.transactionFetchLimit))
    }

    private func refreshIndexCounts() async {
        async let indexedTask = EmbeddingIndex.shared.indexedCount()
        let rows = await loadTransactionRows()
        let indexed = await indexedTask
        guard !Task.isCancelled else { return }
        totalIndexable = rows.filter {
            !EmbeddingIndex.embeddedText(payee: store.payeeName($0.payeeID), notes: $0.notes).isEmpty
        }.count
        indexedCount = indexed
    }

    private func startReindex() {
        guard canReindex, let modelID = ai.embeddingModelID else { return }
        Task {
            let rows = await loadTransactionRows()
            let items = rows.map { tx in
                (id: tx.id,
                 text: EmbeddingIndex.embeddedText(payee: store.payeeName(tx.payeeID), notes: tx.notes),
                 categoryID: tx.categoryID)
            }
            await EmbeddingIndex.shared.reindex(transactions: items, modelID: modelID)
            await refreshIndexCounts()
            Haptics.success()
        }
    }

    // MARK: - Benchmark row

    private var benchmarkCard: some View {
        Button {
            router.push(.aiBenchmark)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .font(theme.font(.subheadline))
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .foregroundStyle(theme.palette.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Run Benchmark")
                        .font(theme.font(.body))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text("See how fast your models run on this device.")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textSecondary)
                }
                Spacer(minLength: theme.layout.spacing)
                Image(systemName: "chevron.right")
                    .font(theme.font(.caption))
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedCard()
        .accessibilityHint("Double-tap to open")
    }

    // MARK: - Shared bits

    private var separator: some View {
        Rectangle()
            .fill(theme.palette.separator)
            .frame(height: 1)
    }
}

// MARK: - IndexProgressBar
//
// A small determinate linear progress bar for the reindex operation. No shared linear-progress
// component exists in DesignSystem/Components (only the circular `ProgressRing`), so this is a
// minimal theme-token-driven bar scoped to this file rather than a new shared component.

private struct IndexProgressBar: View {
    let fraction: Double

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(fraction: Double) {
        self.fraction = fraction
    }

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.palette.fill)
                Capsule()
                    .fill(theme.accentGradient)
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : theme.motion.spring, value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(clamped.formatted(.percent.precision(.fractionLength(0)))))
    }
}

// MARK: - ModelSlotCard
//
// One purpose's whole story in a card: the selected model (name, size, live `EngineStatus`),
// Load/Unload, the list of every model ever added for this purpose (tap a ready one to select it,
// download/cancel/delete inline), and "Add from Hugging Face". Reads `AIModelManager`/
// `ModelDownloadManager` directly (see `IntelligenceView`'s header note) so it stays live while a
// download completes in the background, matching docs/AI.md's "everything works while a download
// runs" requirement.

private struct ModelSlotCard: View {
    let purpose: ModelPurpose
    let icon: String
    let title: String
    let onAddFromHuggingFace: () -> Void

    @Environment(\.theme) private var theme

    @State private var isBusy = false

    private var ai: AIModelManager { AIModelManager.shared }
    private var downloads: ModelDownloadManager { ModelDownloadManager.shared }

    init(purpose: ModelPurpose, icon: String, title: String, onAddFromHuggingFace: @escaping () -> Void) {
        self.purpose = purpose
        self.icon = icon
        self.title = title
        self.onAddFromHuggingFace = onAddFromHuggingFace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            header
            selectionSummary
            if !installedSpecs.isEmpty {
                separator
                VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
                    ForEach(installedSpecs) { spec in
                        modelRow(spec)
                    }
                }
            }
            NidgetButton("Add from Hugging Face", systemImage: "arrow.down.doc", role: .secondary,
                        action: onAddFromHuggingFace)
        }
        .themedCard()
    }

    // MARK: Header & selection

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(theme.font(.subheadline))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.accent)
            Text(title)
                .font(theme.font(.label))
                .foregroundStyle(theme.palette.textSecondary)
                .textCase(theme.typography.labelCase)
                .tracking(theme.typography.labelTracking)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var selectionSummary: some View {
        if let id = selectedModelID, let spec = ai.spec(id: id) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(spec.displayName)
                        .font(theme.font(.headline))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    Text(spec.approxSizeText)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textSecondary)
                }
                statusLine
                loadUnloadButton
            }
        } else if installedSpecs.isEmpty {
            Text("Add a model to turn this on.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
        } else {
            Text("Pick a model below.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
        }
    }

    private var selectedModelID: String? {
        purpose == .embedding ? ai.embeddingModelID : ai.generationModelID
    }

    private var installedSpecs: [ModelSpec] { ai.allModels(purpose) }

    // MARK: Engine status & load/unload

    private var engineStatus: EngineStatus {
        purpose == .embedding ? ai.embedderStatus : ai.generatorStatus
    }

    @ViewBuilder
    private var statusLine: some View {
        let status = engineStatus
        if status.modelId == selectedModelID {
            if status.loaded {
                HStack(spacing: 6) {
                    Circle().fill(theme.palette.positive).frame(width: 6, height: 6)
                    Text(loadedText(status))
                    if let unloadAt = status.unloadAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            countdown(unloadAt: unloadAt, now: context.date)
                        }
                    }
                }
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.positive)
            } else if let last = status.lastBackend {
                Text("Idle · was on \(last.displayName)")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
    }

    private func loadedText(_ status: EngineStatus) -> String {
        guard let backend = status.backend else { return "Loaded" }
        return "Loaded · \(backend.displayName)"
    }

    @ViewBuilder
    private func countdown(unloadAt: Date, now: Date) -> some View {
        let remaining = Int(unloadAt.timeIntervalSince(now))
        if remaining > 0 {
            Text("· unloads in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
        }
    }

    private var isLoaded: Bool {
        let status = engineStatus
        return status.modelId == selectedModelID && status.loaded
    }

    private var isSelectedReady: Bool {
        guard let id = selectedModelID else { return false }
        return downloads.isReady(id)
    }

    private var loadUnloadButton: some View {
        NidgetButton(loadUnloadTitle, systemImage: isLoaded ? "stop.circle" : "play.circle",
                    role: isLoaded ? .secondary : .primary) {
            toggleLoad()
        }
        .disabled(isBusy || !isSelectedReady)
    }

    private var loadUnloadTitle: String {
        if isBusy { return isLoaded ? "Unloading…" : "Loading…" }
        return isLoaded ? "Unload" : "Load"
    }

    private func toggleLoad() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            if isLoaded {
                await ai.unloadModel(purpose)
            } else {
                await ai.loadModel(purpose)
            }
            isBusy = false
        }
    }

    // MARK: Installed model rows

    private func modelRow(_ spec: ModelSpec) -> some View {
        let state = downloads.state(for: spec.id)
        let isSelected = selectedModelID == spec.id
        return HStack(spacing: 10) {
            Button {
                select(spec)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? theme.palette.accent : theme.palette.textTertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(spec.displayName)
                            .font(theme.font(.subheadline))
                            .foregroundStyle(theme.palette.textPrimary)
                            .lineLimit(1)
                        rowStatus(state, spec: spec, isSelected: isSelected)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isReadyState(state))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            trailingAction(state, spec: spec)
        }
        .frame(minHeight: 40)
    }

    private func isReadyState(_ state: ModelDownloadManager.DownloadState) -> Bool {
        if case .ready = state { return true }
        return false
    }

    @ViewBuilder
    private func rowStatus(_ state: ModelDownloadManager.DownloadState, spec: ModelSpec, isSelected: Bool) -> some View {
        switch state {
        case .notDownloaded:
            Text(spec.approxSizeText)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        case .downloading(let p):
            Text(p < 0 ? "Downloading…" : "Downloading \(Int(p * 100))%")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        case .ready:
            Text(isSelected ? "Selected" : "Ready")
                .font(theme.font(.caption))
                .foregroundStyle(isSelected ? theme.palette.accent : theme.palette.textTertiary)
        case .failed(let message):
            Text("Failed: \(message)")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.negative)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func trailingAction(_ state: ModelDownloadManager.DownloadState, spec: ModelSpec) -> some View {
        switch state {
        case .notDownloaded, .failed:
            Button {
                ai.download(spec)
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.palette.accent)
        case .downloading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Button {
                    ModelDownloadManager.shared.cancel(spec.id)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.palette.textTertiary)
            }
        case .ready:
            Button {
                delete(spec)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.palette.negative)
        }
    }

    private func select(_ spec: ModelSpec) {
        guard case .ready = downloads.state(for: spec.id) else { return }
        Haptics.tick()
        if purpose == .embedding {
            ai.embeddingModelID = spec.id
        } else {
            ai.generationModelID = spec.id
        }
    }

    private func delete(_ spec: ModelSpec) {
        Haptics.warning()
        ai.deleteModel(spec.id)
    }

    private var separator: some View {
        Rectangle()
            .fill(theme.palette.separator)
            .frame(height: 1)
    }
}
