import SwiftUI

// MARK: - RetironSettingsView
//
// Pushed via `Route.retironSettings` (ARCHITECTURE §14/§16), so it carries no NavigationStack of
// its own — the same shape as `SecuritySettingsView`. Retiron is the household planner running on
// the owner's own server; this screen is all of its setup: where it lives, the token it hands out,
// whether Nidget pushes balances after every sync, and a way to push right now.
//
// Storage follows ARCHITECTURE §9: the address and token are secrets and go to the Keychain under
// `retiron.serverURL` / `retiron.token`, everything else is a `Preferences` flag. The saved token
// is never read back into the field — this screen never shows a credential — so an empty token
// field means "keep the one already saved", which is what the placeholder says once there is one.
//
// Test checks `GET /api/health` and then reads `GET /api/nidget/token`, which Retiron leaves
// unauthenticated on purpose (it is a LAN and tailnet app, and the whole point of that endpoint is
// that setup can fill the token in instead of making anyone retype it). When a token has already
// been typed it is compared rather than overwritten, so a stale paste is caught here instead of
// quietly failing on the next push.

struct RetironSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var serverURLText = ""
    @State private var tokenText = ""
    @State private var phase: ConnectPhase = .idle
    @State private var failCount = 0
    @State private var isPushing = false
    @State private var showDisconnectConfirm = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case url, token
    }

    private enum ConnectPhase: Equatable {
        case idle, connecting, success(String), failure(String)
    }

    init() {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.layout.spacing) {
                SectionHeader("Your Retiron")
                fieldsCard
                statusRow
                actionButtons
                if isConnected {
                    SectionHeader("Pushing")
                        .padding(.top, theme.layout.spacing * 0.5)
                    pushCard
                }
                SectionHeader("What Gets Shared")
                    .padding(.top, theme.layout.spacing * 0.5)
                explainerCard
                if isConnected {
                    NidgetButton("Disconnect Retiron", systemImage: "xmark.circle", role: .destructive) {
                        showDisconnectConfirm = true
                    }
                    .padding(.top, theme.layout.spacing * 0.25)
                }
                footnote
            }
            .padding(theme.layout.cardPadding)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .themedScreen()
        .navigationTitle("Retiron")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if serverURLText.isEmpty, let stored = KeychainStore.get(RetironKey.serverURL) {
                serverURLText = stored
            }
        }
        .confirmationDialog("Disconnect Retiron?",
                            isPresented: $showDisconnectConfirm,
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nidget forgets the address and token, and stops sending anything. Your budget and everything saved in Retiron stay exactly as they are.")
        }
    }

    // MARK: - Fields

    private var fieldsCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            SectionHeader("Address")
            TextField("http://192.168.1.69:5152", text: $serverURLText)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focusedField, equals: .url)
                .onSubmit { focusedField = .token }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(fieldShape.fill(theme.palette.fill))

            SectionHeader("Token")
            SecureField(tokenPlaceholder, text: $tokenText)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focusedField, equals: .token)
                .onSubmit { Task { await test() } }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(fieldShape.fill(theme.palette.fill))

            Text("Open Retiron in a browser and look for Nidget Sync in its settings. Tap Test and Nidget can pick the token up for you when you are on the same network.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedCard()
    }

    private var tokenPlaceholder: String {
        hasStoredToken ? "Saved token stays as it is" : "Paste the token from Retiron"
    }

    private var fieldShape: AnyShape {
        theme.shape.buttonsAreCapsule ? AnyShape(Capsule()) : AnyShape(theme.controlShape)
    }

    /// A stable slot whose content switches with the connection test, so nothing below it jumps
    /// while the states animate through (same treatment as `ServerSetupView`).
    private var statusRow: some View {
        ZStack(alignment: .leading) {
            switch phase {
            case .idle:
                EmptyView()
            case .connecting:
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(theme.font(.subheadline))
                        .fontWeight(theme.icons.weight)
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: !reduceMotion)
                        .foregroundStyle(theme.palette.accent)
                    Text("Knocking on Retiron's door…")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textSecondary)
                }
                .transition(.opacity)
            case .success(let message):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RetironCheckmark()
                    Text(message)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.positive)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            case .failure(let message):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RetironErrorIcon(trigger: failCount)
                    Text(message)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.negative)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .animation(reduceMotion ? nil : theme.motion.spring, value: phase)
        .accessibilityElement(children: .combine)
    }

    private var actionButtons: some View {
        VStack(spacing: theme.layout.spacing * 0.75) {
            NidgetButton(isTesting ? "Testing…" : "Test", systemImage: "bolt.horizontal",
                         role: .secondary) {
                Task { await test() }
            }
            .disabled(!canTest)
            .opacity(canTest ? 1 : 0.55)
            NidgetButton("Save", systemImage: "checkmark.circle") { save() }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.55)
        }
    }

    // MARK: - Pushing

    private var pushCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.6) {
            Toggle(isOn: autoPushBinding) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle")
                        .font(theme.font(.subheadline))
                        .fontWeight(theme.icons.weight)
                        .symbolVariant(theme.icons.fill ? .fill : .none)
                        .foregroundStyle(theme.palette.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Push After Every Sync")
                            .font(theme.font(.body))
                            .foregroundStyle(theme.palette.textPrimary)
                        Text("Retiron sees your real balances without you having to think about it.")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .tint(theme.palette.accent)
            .frame(minHeight: 44)
            separator
            lastPushRow
            NidgetButton(isPushing ? "Pushing…" : "Push Now", systemImage: "arrow.up.to.line",
                         role: .secondary) {
                Task { await pushNow() }
            }
            .disabled(isPushing)
        }
        .themedCard()
    }

    private var autoPushBinding: Binding<Bool> {
        Binding(get: { preferences.retironAutoPush }, set: { preferences.retironAutoPush = $0 })
    }

    private var lastPushRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(theme.font(.subheadline))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.textTertiary)
                .frame(width: 22)
            Text(lastPushText)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }

    private var lastPushText: String {
        guard preferences.retironLastPush > 0 else { return "Nothing sent yet" }
        let date = Date(timeIntervalSince1970: preferences.retironLastPush)
        return "Last push \(date.formatted(.relative(presentation: .named)))"
    }

    /// `pushRetironSnapshot(manual:)` reports its own failures through the store's toast, so the
    /// only thing left to say here is a haptic — and the honest signal for "did it land" is the
    /// timestamp it writes on success.
    private func pushNow() async {
        guard !isPushing else { return }
        isPushing = true
        let before = preferences.retironLastPush
        await store.pushRetironSnapshot()
        // The busy flag always comes back down, cancelled or not, or the row would sit on
        // "Pushing…" forever; only the haptic is skipped when this task is gone.
        isPushing = false
        guard !Task.isCancelled else { return }
        if preferences.retironLastPush > before {
            Haptics.success()
        } else {
            Haptics.warning()
        }
    }

    // MARK: - Explainer

    private var explainerCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            explainerRow("arrow.up.right",
                         "Nidget sends your account balances and the last twelve months of spending, so the plan runs on real numbers instead of guesses.")
            explainerRow("arrow.down.left",
                         "Retiron sends back your saved plans, so you can look at them and change them from your phone.")
            explainerRow("lock",
                         "Both only ever talk to your own server. Nothing about your money leaves it.")
        }
        .themedCard()
    }

    private func explainerRow(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(theme.font(.subheadline))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.accent)
                .frame(width: 22)
            Text(text)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var footnote: some View {
        Text("The address and token are kept in this device's Keychain, next to your Actual server details, and they go away when you disconnect.")
            .font(theme.font(.caption))
            .foregroundStyle(theme.palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, theme.layout.spacing * 0.25)
    }

    private var separator: some View {
        Rectangle()
            .fill(theme.palette.separator)
            .frame(height: 1)
    }

    // MARK: - State

    private var isConnected: Bool {
        preferences.retironEnabled && hasStoredToken
            && KeychainStore.get(RetironKey.serverURL)?.isEmpty == false
    }

    private var hasStoredToken: Bool {
        KeychainStore.get(RetironKey.token)?.isEmpty == false
    }

    private var isTesting: Bool {
        phase == .connecting
    }

    private var trimmedURLText: String {
        serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedToken: String {
        tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canTest: Bool {
        phase != .connecting && !trimmedURLText.isEmpty
    }

    private var canSave: Bool {
        phase != .connecting && !trimmedURLText.isEmpty && (!trimmedToken.isEmpty || hasStoredToken)
    }

    /// Same rule as `ServerSetupView`: a bare host gets https, and anything that isn't http(s)
    /// with a real host is not an address.
    private func normalizedURL(from text: String) -> URL? {
        var candidate = text
        if !candidate.contains("://") {
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil else {
            return nil
        }
        return url
    }

    // MARK: - Test

    private func test() async {
        guard phase != .connecting, !trimmedURLText.isEmpty else { return }
        guard let url = normalizedURL(from: trimmedURLText) else {
            fail("That doesn't look like an address. Include http:// or https://, and the port if there is one.")
            return
        }

        focusedField = nil
        setPhase(.connecting)
        let typed = trimmedToken
        let effectiveToken = typed.isEmpty ? (KeychainStore.get(RetironKey.token) ?? "") : typed
        let api = RetironAPI(baseURL: url, token: effectiveToken)

        do {
            try await api.health()
        } catch {
            guard !Task.isCancelled else { return }
            fail((error as? LocalizedError)?.errorDescription
                 ?? "Nothing answered at that address. Check the address and that Retiron is running.")
            return
        }
        guard !Task.isCancelled else { return }

        // The token endpoint is open by design, so a failure to read it is not a failure to
        // connect — the server is clearly there.
        let published = try? await api.fetchToken()
        guard !Task.isCancelled else { return }

        guard let published, !published.isEmpty else {
            succeed("Retiron answered. Paste its token and save.")
            return
        }
        if effectiveToken.isEmpty {
            tokenText = published
            succeed("Retiron answered, and its token is filled in for you. Tap Save.")
        } else if effectiveToken != published {
            fail("Retiron answered, but that isn't the token it is showing. Copy it again from the Retiron page.")
        } else {
            succeed("Retiron answered and the token matches.")
        }
    }

    // MARK: - Save and disconnect

    /// An empty token field keeps whatever is already in the Keychain, so someone changing only
    /// the address never has to go and find the token again.
    private func save() {
        guard let url = normalizedURL(from: trimmedURLText) else {
            fail("That doesn't look like an address. Include http:// or https://, and the port if there is one.")
            return
        }
        let typed = trimmedToken
        guard !typed.isEmpty || hasStoredToken else {
            fail("Paste Retiron's token first, or tap Test and let Nidget fetch it.")
            return
        }

        KeychainStore.set(url.absoluteString, key: RetironKey.serverURL)
        if !typed.isEmpty {
            KeychainStore.set(typed, key: RetironKey.token)
        }
        preferences.retironEnabled = true
        serverURLText = url.absoluteString
        tokenText = ""
        focusedField = nil
        succeed("Saved. Nidget will keep Retiron up to date.")
    }

    /// Forgets the link entirely: both Keychain items and every Retiron preference back to its
    /// default, including the cached plan, so nothing stale is left to draw.
    private func disconnect() {
        KeychainStore.delete(RetironKey.serverURL)
        KeychainStore.delete(RetironKey.token)
        preferences.retironEnabled = false
        preferences.retironAutoPush = true
        preferences.retironLastPush = 0
        preferences.retironProfileCacheJSON = ""
        preferences.retironActiveProfileName = ""
        serverURLText = ""
        tokenText = ""
        focusedField = nil
        setPhase(.idle)
        Haptics.warning()
    }

    // MARK: - Phase helpers

    private func succeed(_ message: String) {
        setPhase(.success(message))
        Haptics.success()
    }

    private func fail(_ message: String) {
        failCount += 1
        setPhase(.failure(message))
        Haptics.warning()
    }

    private func setPhase(_ newPhase: ConnectPhase) {
        if reduceMotion {
            phase = newPhase
        } else {
            withAnimation(theme.motion.spring) { phase = newPhase }
        }
    }
}

// MARK: - Keychain keys

/// The Retiron half of ARCHITECTURE §9's key list. `AppStore` keeps its own copy of these strings
/// for the push and the wipe; both are file-private on purpose, the same way `SettingsView` reads
/// `"actual.serverURL"` directly for display.
private enum RetironKey {
    static let serverURL = "retiron.serverURL"
    static let token = "retiron.token"
}

// MARK: - Status symbols
//
// `ServerSetupView`'s equivalents are private to that file, so this screen carries its own pair.
// Value-driven discrete symbol effects don't fire for a view that was just inserted (from its own
// point of view the value never changed), so both nudge a local trigger from `.task` right after
// insertion — bouncing or shaking on first show, and again on every repeat failure.

private struct RetironCheckmark: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var bounceTrigger = 0

    var body: some View {
        Image(systemName: "checkmark.circle")
            .font(theme.font(.subheadline))
            .fontWeight(theme.icons.weight)
            .symbolVariant(.fill)
            .symbolEffect(.bounce, value: bounceTrigger)
            .foregroundStyle(theme.palette.positive)
            .task {
                guard !reduceMotion, !Task.isCancelled else { return }
                bounceTrigger += 1
            }
    }
}

private struct RetironErrorIcon: View {
    /// Bump on every failure so repeat failures shake the already-visible icon again.
    let trigger: Int

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var shakeTrigger = 0

    var body: some View {
        Image(systemName: "exclamationmark.triangle")
            .font(theme.font(.subheadline))
            .fontWeight(theme.icons.weight)
            .symbolVariant(theme.icons.fill ? .fill : .none)
            .symbolEffect(.wiggle, value: shakeTrigger)
            .foregroundStyle(theme.palette.negative)
            .task(id: trigger) {
                guard !reduceMotion, !Task.isCancelled else { return }
                shakeTrigger += 1
            }
    }
}
