import SwiftUI

// MARK: - ServerSetupView
//
// Onboarding step 1 (and also pushed from Settings to change servers — `isOnboarding` only
// tweaks the copy). URL + password go straight into `store.connect`, which on success flips
// the setup state to `.needsFilePick` and RootContentView takes it from there. The status row
// animates through spinning → checkmark / shaking-error states.

struct ServerSetupView: View {
    private let isOnboarding: Bool

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var serverURLText = ""
    @State private var password = ""
    @State private var phase: ConnectPhase = .idle
    @State private var failCount = 0
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case url, password
    }

    private enum ConnectPhase: Equatable {
        case idle, connecting, success, failure(String)
    }

    init(isOnboarding: Bool = true) {
        self.isOnboarding = isOnboarding
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.layout.cardSpacing) {
                header
                fieldsCard
                statusRow
                NidgetButton(phase == .connecting ? "Connecting…" : "Connect",
                             systemImage: "bolt.horizontal",
                             action: { Task { await connect() } })
                    .disabled(!canConnect)
                    .opacity(canConnect ? 1 : 0.55)
                tailscaleHint
            }
            .padding(.horizontal, theme.layout.spacing * 2)
            .padding(.top, theme.layout.spacing)
            .padding(.bottom, theme.layout.spacing * 2)
        }
        .scrollDismissesKeyboard(.interactively)
        .themedScreen()
        .navigationTitle("Connect")
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            if serverURLText.isEmpty, let stored = KeychainStore.get("actual.serverURL") {
                serverURLText = stored
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isOnboarding {
                Text("Step 1 of 2")
                    .font(theme.font(.label))
                    .textCase(theme.typography.labelCase)
                    .tracking(theme.typography.labelTracking)
                    .foregroundStyle(theme.palette.accent)
            }
            Text("Connect your server")
                .font(theme.font(.title))
                .foregroundStyle(theme.palette.textPrimary)
            Text("Nidget speaks Actual's sync protocol directly — point it at your server and it takes it from there.")
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fieldsCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            SectionHeader("Server URL")
            TextField("http://actual.local:5006", text: $serverURLText)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focusedField, equals: .url)
                .onSubmit { focusedField = .password }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(fieldShape.fill(theme.palette.fill))

            SectionHeader("Password")
            SecureField("Server password", text: $password)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($focusedField, equals: .password)
                .onSubmit { Task { await connect() } }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(fieldShape.fill(theme.palette.fill))
        }
        .themedCard()
    }

    /// A stable slot whose content switches with the connection test, so the layout never
    /// jumps while states animate through it.
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
                    Text("Checking your server…")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textSecondary)
                }
                .transition(.opacity)
            case .success:
                HStack(spacing: 8) {
                    BouncingCheckmark()
                    Text("Connected!")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.positive)
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            case .failure(let message):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ShakingErrorIcon(trigger: failCount)
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

    private var tailscaleHint: some View {
        HStack(alignment: .top, spacing: theme.layout.spacing * 0.75) {
            Image(systemName: "network")
                .font(theme.font(.caption))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.textTertiary)
                .accessibilityHidden(true)
            Text("Self-hosting at home? A Tailscale address like http://actual.your-tailnet.ts.net:5006 reaches your server from anywhere — no ports to open.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Connect

    private var canConnect: Bool {
        phase != .connecting
            && !serverURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    private var fieldShape: AnyShape {
        theme.shape.buttonsAreCapsule ? AnyShape(Capsule()) : AnyShape(theme.controlShape)
    }

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

    private func connect() async {
        guard phase != .connecting else { return }
        let trimmed = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else { return }
        guard let url = normalizedURL(from: trimmed) else {
            failCount += 1
            setPhase(.failure("That doesn't look like a server address. Include http:// or https://, and the port if there is one."))
            Haptics.warning()
            return
        }

        focusedField = nil
        setPhase(.connecting)
        do {
            try await store.connect(serverURL: url, password: password)
            setPhase(.success)
            Haptics.success()
            // On success the store flips to .needsFilePick and RootContentView swaps this
            // screen for the file picker — nothing further to do here.
        } catch {
            failCount += 1
            let message = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't sign in. Double-check the address and password."
            setPhase(.failure(message))
            Haptics.warning()
        }
    }

    private func setPhase(_ newPhase: ConnectPhase) {
        if reduceMotion {
            phase = newPhase
        } else {
            withAnimation(theme.motion.spring) { phase = newPhase }
        }
    }
}

// MARK: - Status symbols
//
// Value-driven discrete symbol effects don't fire when their view is freshly inserted (the
// value hasn't changed from the view's perspective), so both status icons nudge a local
// trigger from `.task` right after insertion — reliably bouncing/shaking on first show and
// again on every repeat failure.

private struct BouncingCheckmark: View {
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

private struct ShakingErrorIcon: View {
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
