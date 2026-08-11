import SwiftUI

// MARK: - QuickAddWidget
//
// The fast lane: a big friendly plus that opens the global Quick Add sheet (the same one the
// tab bar accessory presents). Purely an affordance — no data, no loading states, glows when the
// theme glows.

struct QuickAddWidget: View {
    let span: WidgetSpan

    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme

    var body: some View {
        WidgetCardButton(alignment: .center, action: { router.quickAddPresented = true }) {
            VStack(spacing: theme.layout.spacing * 0.5) {
                Image(systemName: "plus")
                    .font(theme.font(.display))
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.onAccent)
                    .frame(width: 56, height: 56)
                    .background {
                        Circle()
                            .fill(theme.palette.accent)
                            .shadow(color: theme.effects.glowAccents
                                    ? theme.palette.accent.opacity(0.5)
                                    : .clear,
                                    radius: theme.effects.glowAccents ? 10 : 0,
                                    x: 0,
                                    y: theme.effects.glowAccents ? 3 : 0)
                    }
                    .accessibilityHidden(true)
                Text("Quick Add")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityLabel("Quick Add")
        .accessibilityHint("Opens the transaction keypad")
    }
}
