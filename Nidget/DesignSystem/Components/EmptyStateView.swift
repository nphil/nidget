import SwiftUI

// MARK: - EmptyStateView
//
// Friendly empty state with a large hierarchical symbol that gently breathes (static under
// Reduce Motion), a headline, a caption, and an optional call-to-action.

struct EmptyStateView: View {
    private let systemImage: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(systemImage: String, title: String, message: String,
         actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: theme.layout.spacing) {
            Image(systemName: systemImage)
                .font(theme.font(.hero))
                .symbolRenderingMode(.hierarchical)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.accent)
                .symbolEffect(.breathe, isActive: !reduceMotion)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(title)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(message)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            if let actionTitle, let action {
                NidgetButton(actionTitle, role: .secondary, action: action)
                    .frame(maxWidth: 280)
                    .padding(.top, theme.layout.spacing * 0.5)
            }
        }
        .multilineTextAlignment(.center)
        .padding(theme.layout.cardPadding)
        .frame(maxWidth: .infinity)
    }
}
