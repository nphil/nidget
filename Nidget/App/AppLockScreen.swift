import SwiftUI
import LocalAuthentication
import os

// MARK: - AppLockScreen
//
// Full-screen biometric gate, overlaid by RootContentView across every setup state. Entirely
// self-managing: it locks on launch when `Preferences.biometricLock` is on, re-locks when the
// app spends more than 8 seconds in the background, and auto-attempts Face ID as soon as the
// lock engages while the app is frontmost. When unlocked it renders nothing and passes all
// touches through.

struct AppLockScreen: View {
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isLocked = false
    @State private var backgroundedAt: Date?
    @State private var isAuthenticating = false
    @State private var authFailed = false

    private static let graceSeconds: TimeInterval = 8
    private static let log = Logger(subsystem: "app.nidget", category: "applock")

    var body: some View {
        ZStack {
            if isLocked {
                lockUI
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: isLocked)
        .onAppear {
            if preferences.biometricLock {
                isLocked = true
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhase(newPhase)
        }
        .task(id: isLocked) {
            // Auto-attempt when the lock engages while the app is frontmost (covers cold
            // launches where the scene is already active before this view appears).
            guard isLocked, scenePhase == .active, !Task.isCancelled else { return }
            await authenticate()
        }
    }

    // MARK: Lock UI

    private var lockUI: some View {
        VStack(spacing: theme.layout.spacing * 2) {
            Spacer(minLength: 0)
            BrandRingMark(size: 104, animated: false)
            VStack(spacing: 6) {
                Text("Nidget is locked")
                    .font(theme.font(.title))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(authFailed ? "That didn't work — try again."
                                : "Your budget stays between you and Face ID.")
                    .font(theme.font(.caption))
                    .foregroundStyle(authFailed ? theme.palette.negative : theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            NidgetButton(isAuthenticating ? "Unlocking…" : "Unlock",
                         systemImage: "faceid",
                         action: { Task { await authenticate() } })
                .frame(maxWidth: 280)
                .disabled(isAuthenticating)
                .opacity(isAuthenticating ? 0.6 : 1)
        }
        .padding(theme.layout.spacing * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedScreen()
    }

    // MARK: Scene phase

    private func handleScenePhase(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            if preferences.biometricLock && !isLocked {
                backgroundedAt = Date()
            }
        case .active:
            if preferences.biometricLock {
                if let at = backgroundedAt, Date().timeIntervalSince(at) > Self.graceSeconds {
                    isLocked = true
                }
                backgroundedAt = nil
                if isLocked && !isAuthenticating {
                    Task { await authenticate() }
                }
            } else {
                // Lock was disabled in Settings while a stale lock lingered.
                isLocked = false
                backgroundedAt = nil
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    // MARK: Authentication

    private func authenticate() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        authFailed = false
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        var policyError: NSError?
        let biometricsAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                            error: &policyError)
        let policy: LAPolicy = biometricsAvailable
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication

        do {
            let success = try await context.evaluatePolicy(policy,
                                                           localizedReason: "Unlock your budget")
            if success {
                unlock()
            } else {
                markFailed()
            }
        } catch {
            if policy == .deviceOwnerAuthenticationWithBiometrics,
               shouldFallBackToPasscode(error) {
                await fallbackToPasscode()
            } else {
                markFailed()
            }
        }
    }

    /// Biometric outcomes that the device passcode can still resolve.
    private func shouldFallBackToPasscode(_ error: Error) -> Bool {
        guard let laError = error as? LAError else { return false }
        switch laError.code {
        case .userFallback, .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled:
            return true
        default:
            return false
        }
    }

    private func fallbackToPasscode() async {
        do {
            let success = try await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                                                               localizedReason: "Unlock your budget")
            if success {
                unlock()
            } else {
                markFailed()
            }
        } catch {
            markFailed()
        }
    }

    private func unlock() {
        isLocked = false
        authFailed = false
        Haptics.success()
    }

    private func markFailed() {
        authFailed = true
        Haptics.warning()
        Self.log.notice("Unlock attempt failed")
    }
}
