import SwiftUI

// MARK: - WelcomeView
//
// Onboarding step 0 — the identity moment. Big brand ring, the app name in the theme's hero
// face, three feature bullets, and one way forward. `onGetStarted` pushes ServerSetupView
// (wired by OnboardingFlow in RootView.swift).

struct WelcomeView: View {
    private let onGetStarted: () -> Void

    @Environment(\.theme) private var theme

    init(onGetStarted: @escaping () -> Void) {
        self.onGetStarted = onGetStarted
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            welcomeContent
            ScrollView {
                welcomeContent
            }
        }
        .themedScreen()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var welcomeContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: theme.layout.spacing * 2)
            VStack(spacing: theme.layout.spacing + 4) {
                BrandRingMark(size: 120, animated: true)
                VStack(spacing: 6) {
                    Text("Nidget")
                        .font(theme.font(.hero))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text("Your Actual budget, in your pocket.")
                        .font(theme.font(.subheadline))
                        .foregroundStyle(theme.palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            Spacer(minLength: theme.layout.spacing * 2)
            VStack(alignment: .leading, spacing: theme.layout.spacing + 4) {
                featureRow(symbol: "bolt",
                           title: "Capture in seconds",
                           detail: "Quick Add learns your payees and fills in the category for you.")
                featureRow(symbol: "square.grid.2x2",
                           title: "One screen, whole picture",
                           detail: "A dashboard of your money that never needs scrolling.")
                featureRow(symbol: "airplane",
                           title: "Works offline",
                           detail: "Log anywhere. Nidget syncs when the network shows up.")
            }
            .themedCard()
            Spacer(minLength: theme.layout.spacing * 2)
            NidgetButton("Get Started", systemImage: "arrow.right", action: onGetStarted)
        }
        .padding(.horizontal, theme.layout.spacing * 2)
        .padding(.vertical, theme.layout.spacing)
    }

    private func featureRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: theme.layout.spacing) {
            Image(systemName: symbol)
                .font(theme.font(.headline))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(detail)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
