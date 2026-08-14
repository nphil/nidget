import SwiftUI

// MARK: - SettingsView
//
// The Settings tab root (ARCHITECTURE §14/§16): a custom themed layout of cards — never a plain
// Form — covering the server connection, Retiron (the household planner this app syncs balances
// with), Intelligence (on-device AI), Appearance
// (with the theme gallery entry point), Dashboard editing, Security, Preferences, and About. Every
// card reads its state live from `AppStore`/`Preferences`/`ThemeManager`/`KeychainStore` on every
// body evaluation (no locally mirrored copies), so returning from a pushed screen (theme gallery,
// security settings, Intelligence) always reflects the latest state without a manual refresh
// hook — SwiftUI re-invokes `body` whenever `router.settingsPath` changes
// (it's read via the `NavigationStack` binding), which covers every push/pop through this tab.
// The Intelligence card additionally reads `AIModelManager`/`ModelDownloadManager` — singletons
// not in ARCHITECTURE §16's environment-injection list, so they're read directly via `.shared`,
// same discipline as `KeychainStore` above.
//
// Server host display parses `KeychainStore`'s stored server URL for display only — the password
// and session token are never read here, matching ARCHITECTURE §9's "never show credentials" rule
// for this screen. The "Edit Dashboard" action deliberately does nothing more than switch tabs
// (ARCHITECTURE explicitly rules out inventing a cross-agent UserDefaults handoff flag) — editing
// itself is toggled from the pencil button already on the Dashboard tab.

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(ThemeManager.self) private var themeManager
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showDisconnectConfirm = false
    @State private var showCurrencyPicker = false
    @State private var isPushingRetiron = false

    init() {}

    var body: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.settingsPath) {
            screenContent
                .withRouteDestinations()
        }
    }

    // MARK: Screen

    private var screenContent: some View {
        ScrollView {
            VStack(spacing: theme.layout.cardSpacing) {
                serverCard
                retironCard
                intelligenceCard
                guideCard
                appearanceCard
                dashboardCard
                securityCard
                preferencesCard
                aboutCard
            }
            .padding(theme.layout.cardPadding)
            // Pin the content to the viewport width. Without this, anything the layout pass
            // measures a point too wide makes the whole screen pan and bounce sideways, since a
            // vertical ScrollView happily scrolls any horizontal overflow.
            .containerRelativeFrame(.horizontal)
        }
        .scrollIndicators(.hidden)
        .themedScreen()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showCurrencyPicker) {
            CurrencyPickerSheet(currencyCode: currencyCodeBinding)
        }
        .confirmationDialog("Disconnect this budget?",
                            isPresented: $showDisconnectConfirm,
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                Task { await store.disconnectAndWipe() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local copy of your budget and every saved credential from this device. You can reconnect anytime.")
        }
    }

    // MARK: - Server card

    private var serverCard: some View {
        SettingsCard(title: "Server", systemImage: "server.rack") {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayBudgetName)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Text(serverHost)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
            separator
            syncStatusRow
            syncButton
            NidgetButton("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                showDisconnectConfirm = true
            }
        }
    }

    private var displayBudgetName: String {
        store.budgetName.isEmpty ? "Untitled Budget" : store.budgetName
    }

    /// Host (and non-default port) parsed from the stored server URL — the password and session
    /// token live in the Keychain too but are never read here.
    private var serverHost: String {
        guard let raw = KeychainStore.get("actual.serverURL"), let url = URL(string: raw),
              let host = url.host else {
            return "Not connected"
        }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    private var isSyncing: Bool { store.syncStatus == .syncing }

    private var syncStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: syncStatusIcon)
                .font(theme.font(.subheadline))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isSyncing && !reduceMotion)
                .foregroundStyle(syncStatusColor)
            Text(syncStatusText)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : theme.motion.snappy, value: syncStatusText)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }

    private var syncStatusIcon: String {
        switch store.syncStatus {
        case .idle: return "checkmark.circle"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .offline: return "wifi.slash"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var syncStatusColor: Color {
        switch store.syncStatus {
        case .idle: return theme.palette.positive
        case .syncing: return theme.palette.accent
        case .offline: return theme.palette.warning
        case .error: return theme.palette.negative
        }
    }

    private var syncStatusText: String {
        switch store.syncStatus {
        case .idle(let lastSync):
            guard let lastSync else { return "Not synced yet" }
            return "Synced \(lastSync.formatted(.relative(presentation: .named)))"
        case .syncing:
            return "Syncing…"
        case .offline(let pending):
            return pending > 0 ? "Offline · \(pending) change\(pending == 1 ? "" : "s") pending" : "Offline"
        case .error(let message):
            return message
        }
    }

    /// A plain `NidgetButton` has no hook for a spinning icon, so the spin is layered on top via
    /// a second, non-interactive icon aligned over the button's own — the button's structure and
    /// modifier chain stay unconditional (LESSONS_FROM_STASHY §1); only the overlay's presence
    /// and the spin toggle on.
    private var syncButton: some View {
        ZStack(alignment: .leading) {
            NidgetButton(isSyncing ? "Syncing…" : "Sync Now",
                        systemImage: "arrow.triangle.2.circlepath",
                        role: .secondary) {
                Task { await store.syncNow() }
            }
            .disabled(isSyncing)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(theme.font(.headline))
                .fontWeight(theme.icons.weight)
                .foregroundStyle(theme.palette.accent)
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isSyncing && !reduceMotion)
                .padding(.leading, 16)
                .opacity(isSyncing ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Retiron card
    //
    // Retiron is the household planner on the owner's own server. Same live-state discipline as
    // the rest of this file: the host comes straight from the Keychain and the push state from
    // `Preferences` on every body evaluation, so coming back from `RetironSettingsView` shows the
    // new state without a refresh hook.

    private var retironCard: some View {
        SettingsCard(title: "Retiron", systemImage: "server.rack") {
            navRow("Household Planner", systemImage: "chart.line.uptrend.xyaxis",
                  detail: retironHost) {
                router.push(.retironSettings)
            }
            if preferences.retironEnabled {
                separator
                retironPushRow
                NidgetButton(isPushingRetiron ? "Pushing…" : "Push Now",
                            systemImage: "arrow.up.to.line",
                            role: .secondary) {
                    Task { await pushRetironNow() }
                }
                .disabled(isPushingRetiron)
            }
        }
    }

    /// Host (and non-default port) of the planner, read for display only — its token is never
    /// touched here, the same rule the Actual server row follows.
    private var retironHost: String {
        guard preferences.retironEnabled,
              let raw = KeychainStore.get("retiron.serverURL"), let url = URL(string: raw),
              let host = url.host else {
            return "Not connected"
        }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    private var retironPushRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle")
                .font(theme.font(.subheadline))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.textTertiary)
            Text(retironLastPushText)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }

    private var retironLastPushText: String {
        guard preferences.retironLastPush > 0 else { return "Nothing sent yet" }
        let date = Date(timeIntervalSince1970: preferences.retironLastPush)
        return "Last push \(date.formatted(.relative(presentation: .named)))"
    }

    /// The push reports its own failures through the store toast, so all that's left here is the
    /// haptic, and the honest signal for "did it land" is the timestamp it writes on success.
    private func pushRetironNow() async {
        guard !isPushingRetiron else { return }
        isPushingRetiron = true
        let before = preferences.retironLastPush
        await store.pushRetironSnapshot()
        isPushingRetiron = false
        guard !Task.isCancelled else { return }
        if preferences.retironLastPush > before {
            Haptics.success()
        } else {
            Haptics.warning()
        }
    }

    // MARK: - Intelligence card

    private var installedAIModelCount: Int {
        AIModelManager.shared.customModels.filter { ModelDownloadManager.shared.isReady($0.id) }.count
    }

    private var intelligenceSubtitle: String {
        let count = installedAIModelCount
        return count > 0 ? "\(count) model\(count == 1 ? "" : "s") installed" : "Off"
    }

    private var intelligenceCard: some View {
        SettingsCard(title: "Intelligence", systemImage: "sparkles") {
            navRow("On-Device AI", systemImage: "brain", detail: intelligenceSubtitle) {
                router.push(.intelligence)
            }
        }
    }

    // MARK: - Guide card

    private var guideCard: some View {
        SettingsCard(title: "How Nidget Works", systemImage: "book") {
            navRow("The five minute tour", systemImage: "map") {
                router.push(.guide)
            }
        }
    }

    // MARK: - Appearance card

    private var lightTheme: Theme {
        ThemeCatalog.theme(id: themeManager.lightThemeID)
            ?? ThemeCatalog.theme(id: ThemeCatalog.defaultLightID) ?? .fallback
    }

    private var darkTheme: Theme {
        ThemeCatalog.theme(id: themeManager.darkThemeID)
            ?? ThemeCatalog.theme(id: ThemeCatalog.defaultDarkID) ?? .fallback
    }

    private var appearanceModeBinding: Binding<AppearanceMode> {
        Binding(get: { themeManager.appearanceMode }, set: { themeManager.appearanceMode = $0 })
    }

    private var themedAppIconBinding: Binding<Bool> {
        Binding(get: { preferences.themedAppIcon }, set: { preferences.themedAppIcon = $0 })
    }

    private var appearanceCard: some View {
        SettingsCard(title: "Appearance", systemImage: "paintpalette") {
            ChipPicker(items: AppearanceMode.allCases, selection: appearanceModeBinding,
                      label: { $0.displayName })
            separator
            themeRow("Light", lightTheme)
            themeRow("Dark", darkTheme)
            navRow("Theme Gallery", systemImage: "square.grid.2x2") {
                router.push(.themeGallery)
            }
            if AppIcon.isSupported {
                separator
                themedAppIconRow
            }
        }
    }

    private var themedAppIconRow: some View {
        Toggle(isOn: themedAppIconBinding) {
            HStack(spacing: 8) {
                Image(systemName: "app.badge")
                    .font(theme.font(.subheadline))
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .foregroundStyle(theme.palette.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Match Home Screen Icon")
                        .font(theme.font(.body))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text("Every theme comes with its own icon. iOS will show a note each time the icon changes.")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(theme.palette.accent)
        .frame(minHeight: 44)
    }

    private func themeRow(_ label: String, _ t: Theme) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(t.accentGradient)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(theme.palette.surfaceBorder, lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                Text(t.name)
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Dashboard card

    private var dashboardCard: some View {
        SettingsCard(title: "Dashboard", systemImage: "rectangle.grid.2x2") {
            Text("Rearrange, resize, or add widgets to your one-screen dashboard.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NidgetButton("Edit Dashboard", systemImage: "pencil", role: .secondary) {
                router.tab = .dashboard
            }
            Text("Press and hold a tile on the Dashboard tab to start editing.")
                .font(theme.font(.label))
                .foregroundStyle(theme.palette.textTertiary)
        }
    }

    // MARK: - Security card

    private var securityCard: some View {
        SettingsCard(title: "Security", systemImage: "lock.shield") {
            navRow("Face ID Lock", systemImage: "faceid",
                  detail: preferences.biometricLock ? "On" : "Off") {
                router.push(.securitySettings)
            }
        }
    }

    // MARK: - Preferences card

    private var currencyCodeBinding: Binding<String> {
        Binding(get: { preferences.currencyCode }, set: { preferences.currencyCode = $0 })
    }

    private var defaultAccountIDBinding: Binding<String?> {
        Binding(get: { preferences.defaultAccountID }, set: { preferences.defaultAccountID = $0 })
    }

    private var defaultAccountChoices: [Account] {
        store.accounts.filter { !$0.closed }
    }

    private var preferencesCard: some View {
        SettingsCard(title: "Preferences", systemImage: "slider.horizontal.3") {
            navRow("Currency", systemImage: "banknote", detail: preferences.currencyCode) {
                showCurrencyPicker = true
            }
            separator
            defaultAccountRow
        }
    }

    private var defaultAccountRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "building.columns")
                .font(theme.font(.subheadline))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.accent)
                .frame(width: 22)
            Text("Default Account")
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
            Spacer(minLength: theme.layout.spacing)
            Picker("", selection: defaultAccountIDBinding) {
                Text("None").tag(String?.none)
                ForEach(defaultAccountChoices) { account in
                    Text(account.name).tag(String?.some(account.id))
                }
            }
            .pickerStyle(.menu)
            .tint(theme.palette.accent)
            .labelsHidden()
        }
        .frame(minHeight: 44)
    }

    // MARK: - About card

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private var aboutCard: some View {
        SettingsCard(title: "About", systemImage: "info.circle") {
            HStack {
                Text("Nidget")
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer(minLength: theme.layout.spacing)
                Text("v\(appVersion) (\(buildNumber))")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            .frame(minHeight: 24)
            Text("An independent, native companion for Actual Budget — not affiliated with or endorsed by the Actual Budget project. Your budget lives on your own server; nothing is sent anywhere else.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shared row helpers

    private var separator: some View {
        Rectangle()
            .fill(theme.palette.separator)
            .frame(height: 1)
    }

    private var chevronRight: some View {
        Image(systemName: "chevron.right")
            .font(theme.font(.caption))
            .fontWeight(theme.icons.weight)
            .foregroundStyle(theme.palette.textTertiary)
    }

    private func navRow(_ label: String, systemImage: String, detail: String? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(theme.font(.subheadline))
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .foregroundStyle(theme.palette.accent)
                    .frame(width: 22)
                Text(label)
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer(minLength: theme.layout.spacing)
                if let detail {
                    Text(detail)
                        .font(theme.font(.subheadline))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                }
                chevronRight
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Double-tap to open")
    }
}

// MARK: - SettingsCard
//
// Every Settings section's shared shell: an icon + label header (styled like `SectionHeader`'s
// type treatment, but composed inline since it lives inside the card rather than above it) over
// arbitrary row content, wrapped in the theme's card treatment.

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    @Environment(\.theme) private var theme

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(theme.font(.subheadline))
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .foregroundStyle(theme.palette.accent)
                    .accessibilityHidden(true)
                Text(title)
                    .font(theme.font(.label))
                    .foregroundStyle(theme.palette.textSecondary)
                    .textCase(theme.typography.labelCase)
                    .tracking(theme.typography.labelTracking)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            content
        }
        .themedCard()
    }
}

// MARK: - CurrencyPickerSheet
//
// A small, self-contained sheet listing common ISO 4217 codes with search — not routed through
// `Route` since it's local, single-purpose UI owned entirely by this file.

/// Key paths cannot refer to tuple elements, so the currency list is a nominal, Identifiable
/// type on purpose (same reasoning as `CategoryPickerSheet.CategoryMatch`).
private struct CurrencyEntry: Identifiable {
    let code: String
    let name: String
    var id: String { code }
}

private struct CurrencyPickerSheet: View {
    @Binding var currencyCode: String

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

    private static let currencies: [CurrencyEntry] = [
        CurrencyEntry(code: "USD", name: "US Dollar"), CurrencyEntry(code: "EUR", name: "Euro"),
        CurrencyEntry(code: "GBP", name: "British Pound"), CurrencyEntry(code: "JPY", name: "Japanese Yen"),
        CurrencyEntry(code: "CAD", name: "Canadian Dollar"), CurrencyEntry(code: "AUD", name: "Australian Dollar"),
        CurrencyEntry(code: "CHF", name: "Swiss Franc"), CurrencyEntry(code: "CNY", name: "Chinese Yuan"),
        CurrencyEntry(code: "INR", name: "Indian Rupee"), CurrencyEntry(code: "NZD", name: "New Zealand Dollar"),
        CurrencyEntry(code: "SGD", name: "Singapore Dollar"), CurrencyEntry(code: "HKD", name: "Hong Kong Dollar"),
        CurrencyEntry(code: "SEK", name: "Swedish Krona"), CurrencyEntry(code: "NOK", name: "Norwegian Krone"),
        CurrencyEntry(code: "DKK", name: "Danish Krone"), CurrencyEntry(code: "MXN", name: "Mexican Peso"),
        CurrencyEntry(code: "BRL", name: "Brazilian Real"), CurrencyEntry(code: "ZAR", name: "South African Rand"),
        CurrencyEntry(code: "KRW", name: "South Korean Won"), CurrencyEntry(code: "PLN", name: "Polish Zloty"),
    ]

    var body: some View {
        NavigationStack {
            content
                .themedScreen()
                .navigationTitle("Currency")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt: "Search currencies")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var filtered: [CurrencyEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Self.currencies }
        return Self.currencies.filter {
            $0.code.localizedCaseInsensitiveContains(query)
                || $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            EmptyStateView(systemImage: "magnifyingglass",
                           title: "No currency found",
                           message: "Nothing named anything like that. Try fewer letters.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { entry in
                        row(entry)
                        if entry.id != filtered.last?.id {
                            Divider().background(theme.palette.separator)
                        }
                    }
                }
                .padding(.horizontal, theme.layout.cardPadding)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func row(_ entry: CurrencyEntry) -> some View {
        let isSelected = entry.code == currencyCode
        return Button {
            Haptics.tick()
            currencyCode = entry.code
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.code)
                        .font(theme.font(.body))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(entry.name)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textSecondary)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(theme.font(.headline))
                        .fontWeight(theme.icons.weight)
                        .foregroundStyle(theme.palette.accent)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
