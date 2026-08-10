import SwiftUI
import LocalAuthentication

// MARK: - SecuritySettingsView
//
// Pushed via `Route.securitySettings` (ARCHITECTURE §14/§16) — no NavigationStack of its own.
// Face ID lock (`Preferences.biometricLock`) tests `LAContext.canEvaluatePolicy` synchronously
// the moment the toggle is switched on, surfacing an inline error and leaving the toggle off if
// neither biometrics nor a device passcode are available — mirroring the broader
// `.deviceOwnerAuthentication` policy `AppLockScreen` itself falls back to, so this check never
// promises a lock the app can't actually enforce. Privacy mode has two controls: a launch default
// (`Preferences.privacyModeDefault`) and an immediate live toggle on `AppStore.privacyMode` for
// "hide everything right now" without waiting for a relaunch.

struct SecuritySettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme

    @State private var biometricError: String?

    init() {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.layout.spacing) {
                SectionHeader("Face ID")
                faceIDCard
                SectionHeader("Privacy")
                    .padding(.top, theme.layout.spacing * 0.5)
                privacyCard
                footnotes
            }
            .padding(theme.layout.cardPadding)
        }
        .scrollIndicators(.hidden)
        .themedScreen()
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Face ID

    private var faceIDCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.6) {
            Toggle(isOn: biometricBinding) {
                HStack(spacing: 8) {
                    Image(systemName: "faceid")
                        .font(theme.font(.subheadline))
                        .fontWeight(theme.icons.weight)
                        .foregroundStyle(theme.palette.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Require Face ID")
                            .font(theme.font(.body))
                            .foregroundStyle(theme.palette.textPrimary)
                        Text("Lock Nidget after 8 seconds in the background.")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textSecondary)
                    }
                }
            }
            .tint(theme.palette.accent)
            .frame(minHeight: 44)
            if let biometricError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(theme.font(.caption))
                        .fontWeight(theme.icons.weight)
                        .foregroundStyle(theme.palette.negative)
                    Text(biometricError)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.negative)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .themedCard()
    }

    private var biometricBinding: Binding<Bool> {
        Binding(
            get: { preferences.biometricLock },
            set: { newValue in
                if newValue {
                    enableBiometricLock()
                } else {
                    biometricError = nil
                    preferences.biometricLock = false
                    Haptics.tick()
                }
            })
    }

    /// `canEvaluatePolicy` is synchronous and merely checks capability (it doesn't prompt) — no
    /// need to leave the main actor or await anything here.
    private func enableBiometricLock() {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            biometricError = policyError?.localizedDescription
                ?? "This device doesn't have Face ID or a passcode set up, so the lock can't be enabled."
            Haptics.warning()
            return
        }
        biometricError = nil
        preferences.biometricLock = true
        Haptics.success()
    }

    // MARK: - Privacy

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.6) {
            Toggle(isOn: privacyDefaultBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hide Amounts on Launch")
                        .font(theme.font(.body))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text("Every screen opens with balances blurred until you unhide them.")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
            .tint(theme.palette.accent)
            .frame(minHeight: 44)
            separator
            Toggle(isOn: privacyNowBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hide Amounts Now")
                        .font(theme.font(.body))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text("Blurs every amount in the app immediately, until you turn this back off.")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
            .tint(theme.palette.accent)
            .frame(minHeight: 44)
        }
        .themedCard()
    }

    private var privacyDefaultBinding: Binding<Bool> {
        Binding(get: { preferences.privacyModeDefault }, set: { preferences.privacyModeDefault = $0 })
    }

    private var privacyNowBinding: Binding<Bool> {
        Binding(get: { store.privacyMode }, set: { store.privacyMode = $0 })
    }

    private var separator: some View {
        Rectangle()
            .fill(theme.palette.separator)
            .frame(height: 1)
    }

    // MARK: - Footnotes

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
            Text("Your server address and password are stored in this device's Keychain, encrypted and inaccessible until after your first unlock each restart.")
            Text("Nidget talks to your Actual server directly — commonly over Tailscale or another private network you control — with no relay or third party in between.")
        }
        .font(theme.font(.caption))
        .foregroundStyle(theme.palette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, theme.layout.spacing * 0.25)
    }
}
