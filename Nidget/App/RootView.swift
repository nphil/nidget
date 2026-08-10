import SwiftUI

// MARK: - RootView
//
// The app frame. Resolves the active theme into the environment, mirrors the device color
// scheme into ThemeManager, and hands off to RootContentView which switches on the store's
// setup state. Everything below this view consumes `@Environment(\.theme)` /
// `@Environment(\.privacyMode)` without knowing where they came from.

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RootContentView()
            .environment(\.theme, themeManager.active)
            .environment(\.privacyMode, store.privacyMode)
            .onAppear {
                themeManager.systemIsDark = colorScheme == .dark
            }
            .onChange(of: colorScheme) { _, newValue in
                themeManager.systemIsDark = newValue == .dark
            }
    }
}

// MARK: - RootContentView
//
// Switches on AppStore.setup and hosts the global overlays: the floating Quick Add button,
// the sync status pill, the error toast, the app lock gate, and the privacy blur.

private struct RootContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Survives the .needsFilePick → .syncingFirstTime → .needsFilePick round trip that a
    /// failed `selectFile` causes, so the recreated FilePickView can still show the failure.
    @State private var filePickError: String?

    /// Presents the Guide over the first `.ready` state. `Preferences.hasSeenGuide` is marked
    /// at presentation time, not on dismiss: dismissing a `.fullScreenCover` re-fires the
    /// presenting view's `.onAppear` before any `onDismiss` closure runs, so a dismiss-time
    /// write would let that re-fired onAppear present the Guide a second time.
    @State private var showGuide = false

    private static let quickAddTabs: [AppTab] = [.dashboard, .budget, .transactions]

    var body: some View {
        ZStack {
            switch store.setup {
            case .loading:
                LoadingStateView()
                    .transition(.opacity)
            case .needsServer:
                OnboardingFlow()
                    .transition(.opacity)
            case .needsFilePick(let files):
                FilePickView(files: files, failureMessage: $filePickError)
                    .transition(.opacity)
            case .syncingFirstTime:
                FirstSyncView()
                    .transition(.opacity)
            case .error(let message):
                SetupErrorView(message: message)
                    .transition(.opacity)
            case .ready:
                readyView
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: store.setup)
        .tint(theme.palette.accent)
        .overlay { AppLockScreen() }
        .overlay { privacyShield }
        .onChange(of: store.setup) { _, newValue in
            if newValue == .syncingFirstTime {
                filePickError = nil
            }
        }
    }

    // MARK: Ready state — tabs + global overlays

    private var readyView: some View {
        @Bindable var router = router
        return TabView(selection: $router.tab) {
            Tab("Dashboard", systemImage: "gauge", value: AppTab.dashboard) {
                DashboardView()
            }
            Tab("Budget", systemImage: "envelope", value: AppTab.budget) {
                BudgetView()
            }
            Tab("Transactions", systemImage: "list.bullet.rectangle", value: AppTab.transactions) {
                TransactionsView()
            }
            Tab("Retire", systemImage: "chart.line.uptrend.xyaxis", value: AppTab.retire) {
                RetirementView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tint(theme.palette.accent)
        .modifier(TabChromeModifier(chrome: theme.effects.chrome, surface: theme.palette.surface))
        .overlay(alignment: .bottomTrailing) { quickAddOverlay }
        .overlay(alignment: .top) { syncStatusOverlay }
        .overlay(alignment: .bottom) { errorToastOverlay }
        .sheet(isPresented: $router.quickAddPresented) {
            QuickAddView()
                .presentationDetents([.height(560), .large])
        }
        .fullScreenCover(isPresented: $showGuide) {
            GuideView()
        }
        .onAppear {
            // readyView only exists while setup == .ready, so this fires exactly when the app
            // first becomes usable — right after the first sync, or on a later cold launch if
            // the Guide was never seen. hasSeenGuide is set here, at presentation time, because
            // this onAppear fires again while the cover is still dismissing — marking the
            // preference on dismiss instead would re-present the Guide right after Skip.
            if !preferences.hasSeenGuide {
                preferences.hasSeenGuide = true
                showGuide = true
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // OpenQuickAddIntent (Platform/AppShortcuts.swift) opens the app and requests the
            // Quick Add sheet via PendingActions; the sheet must be presented from the app frame.
            if phase == .active, PendingActions.quickAddRequested {
                PendingActions.quickAddRequested = false
                router.quickAddPresented = true
            }
        }
    }

    // MARK: Quick Add floating button

    @ViewBuilder
    private var quickAddOverlay: some View {
        ZStack {
            if Self.quickAddTabs.contains(router.tab) {
                QuickAddFloatingButton {
                    router.quickAddPresented = true
                }
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: router.tab)
        .padding(.trailing, theme.layout.spacing + 8)
        .padding(.bottom, 68)
    }

    // MARK: Sync status pill

    @ViewBuilder
    private var syncStatusOverlay: some View {
        ZStack {
            switch store.syncStatus {
            case .syncing:
                SyncStatusPill(systemImage: "arrow.triangle.2.circlepath",
                               text: "Syncing",
                               spinning: true)
                    .transition(.move(edge: .top).combined(with: .opacity))
            case .offline(let pending):
                SyncStatusPill(systemImage: "wifi.slash",
                               text: pending > 0 ? "Offline · \(pending) pending" : "Offline",
                               spinning: false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            case .idle, .error:
                EmptyView()
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: store.syncStatus)
        .padding(.top, theme.layout.spacing * 0.5)
    }

    // MARK: Error toast

    @ViewBuilder
    private var errorToastOverlay: some View {
        ZStack {
            if let error = store.lastError {
                ErrorToastView(error: error) {
                    store.clearError()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: error.id) {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    if store.lastError?.id == error.id {
                        store.clearError()
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: store.lastError)
        .padding(.horizontal, theme.layout.spacing + 8)
        .padding(.bottom, 76)
    }

    // MARK: Privacy shield

    @ViewBuilder
    private var privacyShield: some View {
        ZStack {
            if scenePhase != .active {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.snappy, value: scenePhase == .active)
        .allowsHitTesting(false)
    }
}

// MARK: - TabChromeModifier
//
// Applies the theme's chrome style to the tab bar. `.glass` and `.floating` keep the default
// Liquid Glass chrome (floating is approximated by tint only — no invented APIs); `.opaque`
// pins a surface-colored, always-visible bar.

private struct TabChromeModifier: ViewModifier {
    let chrome: ChromeStyle
    let surface: Color

    func body(content: Content) -> some View {
        switch chrome {
        case .glass, .floating:
            content
        case .opaque:
            content
                .toolbarBackground(surface, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
    }
}

// MARK: - QuickAddFloatingButton
//
// 56pt accent circle with a plus, floating above the tab bar. Press feedback + Haptics.tap
// come from PressableButtonStyle (same treatment as NidgetButton).

private struct QuickAddFloatingButton: View {
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(theme.font(.title))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.onAccent)
                .frame(width: 56, height: 56)
                .background {
                    Circle()
                        .fill(theme.palette.accent)
                        .shadow(color: theme.effects.shadow?.color ?? .clear,
                                radius: theme.effects.shadow?.radius ?? 0,
                                x: theme.effects.shadow?.x ?? 0,
                                y: theme.effects.shadow?.y ?? 0)
                        .shadow(color: theme.effects.glowAccents ? theme.palette.accent.opacity(0.5) : .clear,
                                radius: theme.effects.glowAccents ? 12 : 0,
                                x: 0,
                                y: theme.effects.glowAccents ? 4 : 0)
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(pressAnimation: reduceMotion ? nil : theme.motion.snappy))
        .accessibilityLabel("Add transaction")
    }
}

// MARK: - SyncStatusPill

private struct SyncStatusPill: View {
    let systemImage: String
    let text: String
    var spinning = false

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(theme.font(.caption))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .symbolEffect(.rotate, options: .repeat(.continuous),
                              isActive: spinning && !reduceMotion)
                .foregroundStyle(theme.palette.accent)
            Text(text)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : theme.motion.snappy, value: text)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            Capsule()
                .fill(theme.palette.surface)
                .overlay(Capsule().strokeBorder(theme.palette.surfaceBorder, lineWidth: 1))
                .shadow(color: theme.effects.shadow?.color ?? .clear,
                        radius: theme.effects.shadow?.radius ?? 0,
                        x: theme.effects.shadow?.x ?? 0,
                        y: theme.effects.shadow?.y ?? 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - ErrorToastView

private struct ErrorToastView: View {
    let error: AppError
    let dismiss: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: dismiss) {
            HStack(alignment: .firstTextBaseline, spacing: theme.layout.spacing) {
                Image(systemName: "exclamationmark.triangle")
                    .font(theme.font(.headline))
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .foregroundStyle(theme.palette.negative)
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.message)
                        .font(theme.font(.headline))
                        .foregroundStyle(theme.palette.textPrimary)
                    if let detail = error.detail, !detail.isEmpty {
                        Text(detail)
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "xmark")
                    .font(theme.font(.caption))
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            .multilineTextAlignment(.leading)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedCard(padding: 14)
        .accessibilityLabel("Error: \(error.message)")
        .accessibilityHint("Double-tap to dismiss")
    }
}

// MARK: - BrandRingMark
//
// The app's identity motif: a gapped accent-gradient ring around a center dot. Shared by the
// loading screen, first-sync screen, WelcomeView, and AppLockScreen. When `animated`, the gap
// slowly orbits via TimelineView (the same technique as the mesh Backdrop — no Animation
// objects, and completely static under Reduce Motion).

struct BrandRingMark: View {
    var size: CGFloat = 96
    var animated: Bool = false

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lineWidth = max(size * 0.10, 6)
        ZStack {
            if animated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ring(lineWidth: lineWidth)
                        .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 3.0) / 3.0 * 360.0))
                }
            } else {
                ring(lineWidth: lineWidth)
            }
            Circle()
                .fill(theme.palette.accent)
                .frame(width: size * 0.16, height: size * 0.16)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func ring(lineWidth: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: 0.8)
            .stroke(theme.accentGradient,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(lineWidth / 2)
            .shadow(color: theme.effects.glowAccents ? theme.palette.accent.opacity(0.5) : .clear,
                    radius: theme.effects.glowAccents ? 10 : 0)
    }
}

// MARK: - LoadingStateView

private struct LoadingStateView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: theme.layout.spacing * 2) {
            BrandRingMark(size: 96, animated: true)
            VStack(spacing: 4) {
                Text("Nidget")
                    .font(theme.font(.title))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Opening your budget…")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedScreen()
    }
}

// MARK: - FirstSyncView
//
// Shown during `.syncingFirstTime` — the download + first delta sync after picking a file.
// Narration advances every couple of seconds and parks on the last line.

private struct FirstSyncView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var lineIndex = 0

    private static let lines = [
        "Downloading your budget…",
        "Unpacking envelopes…",
        "Reconciling the ledger…",
        "Warming up the charts…",
        "Almost there…",
    ]

    var body: some View {
        VStack(spacing: theme.layout.spacing * 2) {
            BrandRingMark(size: 96, animated: true)
            VStack(spacing: 4) {
                Text("Setting things up")
                    .font(theme.font(.title))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(Self.lines[lineIndex])
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.textSecondary)
                    .id(lineIndex)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedScreen()
        .task {
            while !Task.isCancelled && lineIndex < Self.lines.count - 1 {
                try? await Task.sleep(for: .seconds(2.4))
                guard !Task.isCancelled else { return }
                let next = min(lineIndex + 1, Self.lines.count - 1)
                if reduceMotion {
                    lineIndex = next
                } else {
                    withAnimation(theme.motion.spring) { lineIndex = next }
                }
            }
        }
    }
}

// MARK: - SetupErrorView

private struct SetupErrorView: View {
    let message: String

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        EmptyStateView(systemImage: "antenna.radiowaves.left.and.right.slash",
                       title: "Couldn't reach your server",
                       message: message,
                       actionTitle: "Try Again",
                       action: { Task { await store.bootstrap() } })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedScreen()
    }
}

// MARK: - OnboardingFlow
//
// Step 0 → 1 of onboarding: welcome pushes the server setup screen. Step 2 (file pick) is a
// separate setup state, so RootContentView swaps this whole flow out once connect succeeds.

private struct OnboardingFlow: View {
    @State private var showServerSetup = false

    var body: some View {
        NavigationStack {
            WelcomeView { showServerSetup = true }
                .navigationDestination(isPresented: $showServerSetup) {
                    ServerSetupView()
                }
        }
    }
}
