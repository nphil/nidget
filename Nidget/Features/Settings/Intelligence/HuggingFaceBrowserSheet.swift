import SwiftUI

// MARK: - HuggingFaceBrowserSheet
//
// Sheet from `IntelligenceView`'s "Add from Hugging Face" buttons (docs/AI.md §4). Search Hugging
// Face for GGUF repos, expand one to see its files with sizes, and download straight into
// `ModelDownloadManager` as a new custom `ModelSpec`. Unlike HomeBoy's version (which dismisses
// the moment you tap Download) this sheet stays open after a download starts — the task calls for
// "in-progress rows with progress + cancel" to be a real, visible feature of this screen, so the
// user can start several downloads, watch them, and cancel one, all without leaving and reopening.
//
// The purpose picker doubles as the search scope (`HuggingFaceRepository.search` uses it to fill
// in a default query when the field is empty) and as what gets baked into the `ModelSpec` when a
// file is downloaded, so switching it re-runs the search.
//
// The Hugging Face token field binds straight to `AIModelManager.shared.hfToken` — the engine
// layer's existing session-only store (deliberately not persisted; see AIModelManager.swift) —
// rather than a second local copy, so a token typed here is immediately what `download(_:)` uses.

struct HuggingFaceBrowserSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    @State private var purpose: ModelPurpose
    @State private var query = ""
    @State private var sort: HFSort = .downloads
    @State private var results: [HFModel] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var expandedRepoID: String?
    @State private var filesByRepo: [String: [HFTreeEntry]] = [:]
    @State private var loadingFilesFor: String?
    @State private var showTokenField = false
    @State private var showToken = false

    init(purpose: ModelPurpose) {
        _purpose = State(initialValue: purpose)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            header
            purposePicker
            searchField
            sortPicker
            tokenDisclosure
            resultsContent
        }
        .padding(.top, theme.layout.spacing)
        .themedScreen()
        .task { runSearch() }
        .onChange(of: purpose) { _, _ in runSearch() }
        .onChange(of: sort) { _, _ in runSearch() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Add a Model")
                .font(theme.font(.title))
                .foregroundStyle(theme.palette.textPrimary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(theme.font(.title))
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.palette.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, theme.layout.cardPadding)
    }

    private var purposePicker: some View {
        ChipPicker(items: [ModelPurpose.embedding, .generation], selection: $purpose,
                  label: { $0 == .embedding ? "Embedding" : "Generation" })
            .padding(.horizontal, theme.layout.cardPadding)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(theme.font(.body))
                .fontWeight(theme.icons.weight)
                .foregroundStyle(theme.palette.textTertiary)
            TextField(searchPlaceholder, text: $query)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { runSearch() }
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    runSearch()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(theme.font(.subheadline))
                        .fontWeight(theme.icons.weight)
                        .symbolVariant(theme.icons.fill ? .fill : .none)
                        .foregroundStyle(theme.palette.textTertiary)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(theme.controlShape.fill(theme.palette.fill))
        .padding(.horizontal, theme.layout.cardPadding)
    }

    private var searchPlaceholder: String {
        purpose == .embedding ? "Search embedding models" : "Search language models"
    }

    private var sortPicker: some View {
        ChipPicker(items: HFSort.allCases, selection: $sort, label: \.label)
            .padding(.horizontal, theme.layout.cardPadding)
    }

    // MARK: Token

    private var tokenDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : theme.motion.snappy) { showTokenField.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "key")
                        .font(theme.font(.caption))
                        .fontWeight(theme.icons.weight)
                        .foregroundStyle(theme.palette.textTertiary)
                    Text("Hugging Face token (optional)")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                    Spacer(minLength: 0)
                    Image(systemName: showTokenField ? "chevron.up" : "chevron.down")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showTokenField {
                tokenField
                Text("Raises download limits and unlocks gated models. Stays on this device for this session only.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .padding(.horizontal, theme.layout.cardPadding)
    }

    private var tokenField: some View {
        HStack(spacing: 8) {
            Group {
                if showToken {
                    TextField("hf_…", text: tokenBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("hf_…", text: tokenBinding)
                }
            }
            .font(theme.font(.body))
            .foregroundStyle(theme.palette.textPrimary)
            Button {
                showToken.toggle()
            } label: {
                Image(systemName: showToken ? "eye.slash" : "eye")
                    .foregroundStyle(theme.palette.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(theme.controlShape.fill(theme.palette.fill))
    }

    private var tokenBinding: Binding<String> {
        Binding(get: { AIModelManager.shared.hfToken }, set: { AIModelManager.shared.hfToken = $0 })
    }

    // MARK: Results

    @ViewBuilder
    private var resultsContent: some View {
        if isSearching && results.isEmpty {
            ProgressView()
                .padding(.top, 24)
                .frame(maxWidth: .infinity)
        } else if results.isEmpty {
            EmptyStateView(systemImage: "magnifyingglass",
                           title: "No models found",
                           message: "Try a different search, or check your connection and try again.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: theme.layout.spacing * 0.6) {
                    ForEach(results) { repoCard($0) }
                }
                .padding(theme.layout.cardPadding)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func repoCard(_ model: HFModel) -> some View {
        let compat = HuggingFaceRepository.classifyRepo(model.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                toggle(model)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.name)
                            .font(theme.font(.subheadline))
                            .fontWeight(.medium)
                            .foregroundStyle(theme.palette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: theme.layout.spacing * 0.5)
                        Image(systemName: expandedRepoID == model.id ? "chevron.up" : "chevron.down")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textTertiary)
                    }
                    Text(model.author)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                    statsRow(model)
                    if let warning = compat.warning {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(theme.font(.caption))
                                .foregroundStyle(theme.palette.warning)
                            Text(warning)
                                .font(theme.font(.caption))
                                .foregroundStyle(theme.palette.warning)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedRepoID == model.id {
                Divider().background(theme.palette.separator)
                fileList(model)
            }
        }
        .themedCard(padding: 12)
    }

    private func statsRow(_ model: HFModel) -> some View {
        HStack(spacing: 12) {
            if let downloads = model.downloads {
                statChip(icon: "arrow.down.circle", value: downloads)
            }
            if let likes = model.likes {
                statChip(icon: "heart", value: likes)
            }
            Spacer(minLength: 0)
        }
    }

    private func statChip(icon: String, value: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
            Text("\(value)")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        }
    }

    @ViewBuilder
    private func fileList(_ model: HFModel) -> some View {
        if loadingFilesFor == model.id {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading files…")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
            }
        } else {
            let files = filesByRepo[model.id] ?? []
            if files.isEmpty {
                Text("No GGUF files usable on-device in this repo.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(files) { file in
                        fileRow(repoID: model.id, file: file)
                    }
                }
            }
        }
    }

    private func fileRow(repoID: String, file: HFTreeEntry) -> some View {
        let spec = HuggingFaceRepository.customSpec(repoId: repoID, file: file, purpose: purpose)
        let state = ModelDownloadManager.shared.state(for: spec.id)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(fileLabel(file.path))
                    .font(theme.font(.caption))
                    .fontWeight(.medium)
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                fileStatus(state, file: file)
            }
            Spacer(minLength: theme.layout.spacing * 0.5)
            fileTrailing(state, spec: spec)
        }
        .frame(minHeight: 36)
    }

    private func fileLabel(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func isShard(_ path: String) -> Bool {
        path.lowercased().contains("-of-")
    }

    @ViewBuilder
    private func fileStatus(_ state: ModelDownloadManager.DownloadState, file: HFTreeEntry) -> some View {
        switch state {
        case .notDownloaded:
            HStack(spacing: 6) {
                if let size = file.sizeText {
                    Text(size)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                }
                if isShard(file.path) {
                    Text("split file, may not load alone")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.warning)
                }
            }
        case .downloading(let p):
            Text(p < 0 ? "Downloading…" : "Downloading \(Int(p * 100))%")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        case .ready:
            Text("Added")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.positive)
        case .failed(let message):
            Text("Failed: \(message)")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.negative)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func fileTrailing(_ state: ModelDownloadManager.DownloadState, spec: ModelSpec) -> some View {
        switch state {
        case .notDownloaded, .failed:
            Button {
                startDownload(spec)
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.palette.accent)
        case .downloading:
            HStack(spacing: 8) {
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
            Image(systemName: "checkmark.circle")
                .foregroundStyle(theme.palette.positive)
        }
    }

    private func startDownload(_ spec: ModelSpec) {
        Haptics.tap()
        AIModelManager.shared.addCustomModel(spec)
    }

    // MARK: Search & file loading

    private func runSearch() {
        searchTask?.cancel()
        let q = query
        let p = purpose
        let s = sort
        let token = AIModelManager.shared.hfToken
        isSearching = true
        searchTask = Task {
            let repo = HuggingFaceRepository(token: token.isEmpty ? nil : token)
            let found = await repo.search(q, purpose: p, sort: s)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }

    private func toggle(_ model: HFModel) {
        if expandedRepoID == model.id {
            expandedRepoID = nil
            return
        }
        Haptics.tick()
        expandedRepoID = model.id
        guard filesByRepo[model.id] == nil else { return }
        loadingFilesFor = model.id
        let token = AIModelManager.shared.hfToken
        Task {
            let repo = HuggingFaceRepository(token: token.isEmpty ? nil : token)
            let files = await repo.files(model.id)
            guard !Task.isCancelled else { return }
            filesByRepo[model.id] = files
            loadingFilesFor = nil
        }
    }
}
