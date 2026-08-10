import SwiftUI

// MARK: - SimpleFINSetupView
//
// Pushed via `Route.simpleFINSetup` (ARCHITECTURE §14/§16) — no NavigationStack of its own.
// State-dependent: not linked shows a setup-token field that exchanges the token for an access
// URL via `SimpleFINClient.claim(setupToken:)`, stored under Keychain key `simplefin.accessURL`
// (ARCHITECTURE §9). Linked fetches the account list directly (today's `start-date`, so the
// balance/org/name metadata comes back without pulling a real transaction window — the actual
// 60-day import window lives entirely inside `AppStore.importSimpleFIN()`, called unchanged from
// here), renders a mapping row per SimpleFIN account writing straight into
// `Preferences.simplefinAccountMap` (persisted as `simplefinAccountMapJSON`), and offers "Import
// Now" + "Unlink". `isLinked` is read fresh from the Keychain on every body evaluation (no local
// mirror) — the same self-refreshing pattern as `SettingsView`, since every state change here
// (`phase`, `isConnecting`, …) already forces a fresh body pass that re-reads it.

struct SimpleFINSetupView: View {
    @Environment(AppStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum LoadPhase {
        case idle, loading, loaded, error(String)
    }

    // Not-linked flow
    @State private var setupToken = ""
    @State private var isConnecting = false
    @State private var connectError: String?

    // Linked flow
    @State private var phase: LoadPhase = .idle
    @State private var sfAccounts: [SFAccount] = []
    @State private var isImporting = false
    @State private var lastImportSummary: ImportSummary?
    @State private var showUnlinkConfirm = false

    init() {}

    private var isLinked: Bool {
        KeychainStore.get("simplefin.accessURL") != nil
    }

    var body: some View {
        content
            .themedScreen()
            .navigationTitle("SimpleFIN")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if isLinked { await loadAccounts() }
            }
            .confirmationDialog("Unlink SimpleFIN?",
                                isPresented: $showUnlinkConfirm,
                                titleVisibility: .visible) {
                Button("Unlink", role: .destructive) { unlink() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the saved connection and every account mapping from this device. Transactions already imported stay in your budget.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if isLinked {
            linkedContent
        } else {
            notLinkedContent
        }
    }

    // MARK: - Not linked

    private var notLinkedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.layout.spacing) {
                SectionHeader("Connect SimpleFIN")
                explainerCard
                SectionHeader("Setup Token")
                    .padding(.top, theme.layout.spacing * 0.5)
                tokenCard
            }
            .padding(theme.layout.cardPadding)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
    }

    private var explainerCard: some View {
        Text("SimpleFIN links your bank accounts so transactions can be imported straight into this budget. Get a setup token from your SimpleFIN provider, then paste it below — it's used once, in exchange for a long-lived connection stored securely on this device.")
            .font(theme.font(.caption))
            .foregroundStyle(theme.palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .themedCard()
    }

    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.6) {
            TextField("Paste your setup token", text: $setupToken, axis: .vertical)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...4)
                .padding(12)
                .background(theme.controlShape.fill(theme.palette.fill))
            if let connectError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(theme.font(.caption))
                        .fontWeight(theme.icons.weight)
                        .foregroundStyle(theme.palette.negative)
                    Text(connectError)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.negative)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            NidgetButton(isConnecting ? "Connecting…" : "Connect", systemImage: "link", role: .primary) {
                connect()
            }
            .disabled(isConnecting || trimmedToken.isEmpty)
        }
        .themedCard()
    }

    private var trimmedToken: String {
        setupToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connect() {
        guard !isConnecting, !trimmedToken.isEmpty else { return }
        isConnecting = true
        connectError = nil
        Task {
            do {
                let accessURL = try await SimpleFINClient.claim(setupToken: trimmedToken)
                KeychainStore.set(accessURL, key: "simplefin.accessURL")
                isConnecting = false
                setupToken = ""
                Haptics.success()
                await loadAccounts()
            } catch {
                isConnecting = false
                connectError = Self.friendlyMessage(for: error)
                Haptics.warning()
            }
        }
    }

    // MARK: - Linked

    private var linkedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.layout.spacing) {
                linkedBody
                unlinkButton
                    .padding(.top, theme.layout.spacing * 0.5)
            }
            .padding(theme.layout.cardPadding)
        }
        .scrollIndicators(.hidden)
        .refreshable { await loadAccounts() }
    }

    @ViewBuilder
    private var linkedBody: some View {
        switch phase {
        case .idle, .loading:
            ShimmerLoadingCard()
        case .loaded:
            if sfAccounts.isEmpty {
                EmptyStateView(systemImage: "building.columns",
                               title: "No accounts found",
                               message: "This SimpleFIN connection didn't return any accounts. Check your provider's settings.")
            } else {
                SectionHeader("Map Accounts")
                mappingCard
                SectionHeader("Import")
                    .padding(.top, theme.layout.spacing * 0.5)
                importCard
            }
        case .error(let message):
            EmptyStateView(systemImage: "exclamationmark.triangle",
                           title: "Couldn't load accounts",
                           message: message,
                           actionTitle: "Try Again",
                           action: { Task { await loadAccounts() } })
        }
    }

    // MARK: Mapping

    private var mappingCard: some View {
        VStack(spacing: 0) {
            ForEach(sfAccounts, id: \.id) { account in
                mappingRow(account)
                if account.id != sfAccounts.last?.id {
                    Divider().background(theme.palette.separator)
                }
            }
        }
        .themedCard(padding: 8)
    }

    private var mappableAccounts: [Account] {
        store.accounts.filter { !$0.closed }
    }

    private func mappingRow(_ account: SFAccount) -> some View {
        HStack(spacing: theme.layout.spacing * 0.6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name.isEmpty ? "Unnamed account" : account.name)
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if !account.org.isEmpty {
                        Text(account.org)
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textTertiary)
                            .lineLimit(1)
                    }
                    AmountText(account.balance, style: .caption, colorized: false)
                }
            }
            Spacer(minLength: theme.layout.spacing * 0.5)
            Picker("", selection: mappingBinding(for: account.id)) {
                Text("Not Mapped").tag(String?.none)
                ForEach(mappableAccounts) { actualAccount in
                    Text(actualAccount.name).tag(String?.some(actualAccount.id))
                }
            }
            .pickerStyle(.menu)
            .tint(theme.palette.accent)
            .labelsHidden()
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 4)
    }

    private func mappingBinding(for sfAccountID: String) -> Binding<String?> {
        Binding(
            get: { preferences.simplefinAccountMap[sfAccountID] },
            set: { newValue in
                var map = preferences.simplefinAccountMap
                if let newValue {
                    map[sfAccountID] = newValue
                } else {
                    map.removeValue(forKey: sfAccountID)
                }
                preferences.simplefinAccountMap = map
            })
    }

    // MARK: Import

    private var importCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.6) {
            NidgetButton(isImporting ? "Importing…" : "Import Now",
                        systemImage: "arrow.down.circle", role: .primary) {
                importNow()
            }
            .disabled(isImporting)
            importResult
        }
        .themedCard()
    }

    @ViewBuilder
    private var importResult: some View {
        if let summary = lastImportSummary {
            VStack(alignment: .leading, spacing: 6) {
                resultRow(systemImage: "arrow.down.circle", label: "Imported",
                         count: summary.imported, color: theme.palette.positive)
                resultRow(systemImage: "checkmark.circle", label: "Already had",
                         count: summary.skipped, color: theme.palette.textSecondary)
                if summary.pendingSkipped > 0 {
                    resultRow(systemImage: "clock", label: "Pending (skipped)",
                             count: summary.pendingSkipped, color: theme.palette.textTertiary)
                }
                if !summary.unmapped.isEmpty {
                    resultRow(systemImage: "exclamationmark.triangle", label: "Unmapped accounts",
                             count: summary.unmapped.count, color: theme.palette.warning)
                }
            }
            .transition(.opacity)
        }
    }

    private func resultRow(systemImage: String, label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(theme.font(.subheadline))
                .fontWeight(theme.icons.weight)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(label)
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textSecondary)
            Spacer(minLength: theme.layout.spacing)
            Text("\(count)")
                .font(theme.font(.subheadline))
                .fontWeight(.semibold)
                .foregroundStyle(theme.palette.textPrimary)
                .contentTransition(.numericText())
        }
        .frame(minHeight: 26)
    }

    private func importNow() {
        guard !isImporting else { return }
        isImporting = true
        Task {
            let summary = await store.importSimpleFIN()
            isImporting = false
            if let summary {
                if reduceMotion {
                    lastImportSummary = summary
                } else {
                    withAnimation(theme.motion.spring) { lastImportSummary = summary }
                }
                Haptics.success()
            }
        }
    }

    // MARK: Unlink

    private var unlinkButton: some View {
        NidgetButton("Unlink SimpleFIN", systemImage: "xmark.circle", role: .destructive) {
            showUnlinkConfirm = true
        }
    }

    private func unlink() {
        KeychainStore.delete("simplefin.accessURL")
        preferences.simplefinAccountMap = [:]
        sfAccounts = []
        lastImportSummary = nil
        phase = .idle
        Haptics.warning()
    }

    // MARK: Loading accounts

    private func loadAccounts() async {
        guard let accessURL = KeychainStore.get("simplefin.accessURL") else {
            phase = .idle
            return
        }
        phase = .loading
        let client = SimpleFINClient(accessURL: accessURL)
        do {
            // Today's start-date keeps this metadata-only fetch cheap — the real 60-day import
            // window lives in `AppStore.importSimpleFIN()`, untouched by this call.
            let accounts = try await client.accounts(startDate: Date(), includePending: false)
            guard !Task.isCancelled else { return }
            sfAccounts = accounts.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            phase = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            phase = .error(Self.friendlyMessage(for: error))
        }
    }

    private static func friendlyMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        let description = error.localizedDescription
        return description.isEmpty ? "Something went wrong. Try again." : description
    }
}

// MARK: - ShimmerLoadingCard
//
// A small pulsing placeholder for the account list while it loads. Uses only `theme.motion.spring`
// (never an ad-hoc curve) via a self-driven toggle loop, entirely skipped under Reduce Motion.

private struct ShimmerLoadingCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pulse = false

    var body: some View {
        VStack(spacing: theme.layout.spacing * 0.75) {
            ForEach(0..<3, id: \.self) { _ in row }
        }
        .themedCard()
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                withAnimation(theme.motion.spring) { pulse.toggle() }
                try? await Task.sleep(for: .seconds(0.65))
                guard !Task.isCancelled else { return }
            }
        }
    }

    private var row: some View {
        HStack(spacing: theme.layout.spacing * 0.75) {
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(theme.palette.fill).frame(width: 130, height: 13)
                Capsule().fill(theme.palette.fill).frame(width: 84, height: 11)
            }
            Spacer(minLength: 0)
            Capsule().fill(theme.palette.fill).frame(width: 56, height: 13)
        }
        .frame(minHeight: 44)
        .opacity(pulse ? 0.35 : 0.85)
    }
}
