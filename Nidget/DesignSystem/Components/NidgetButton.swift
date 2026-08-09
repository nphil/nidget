import SwiftUI

// MARK: - NidgetButtonRole

/// Visual weight of a `NidgetButton`. Distinct from SwiftUI's `ButtonRole`.
enum NidgetButtonRole {
    /// Accent fill + onAccent label; glows when the theme glows.
    case primary
    /// Subtle fill + accent label.
    case secondary
    /// Plain accent text, no fill.
    case subtle
    /// Negative fill + onAccent label.
    case destructive
}

// MARK: - NidgetButton
//
// The app's standard call-to-action button. Capsule or rounded-rect per the theme's shape
// language, minimum 50pt tall, expands to fill its width. Pressing scales to 0.96 with the
// theme's snappy spring and fires `Haptics.tap()` on touch-down.

struct NidgetButton: View {
    private let title: String
    private let systemImage: String?
    private let role: NidgetButtonRole
    private let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, systemImage: String? = nil,
         role: NidgetButtonRole = .primary, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .symbolVariant(theme.icons.fill ? .fill : .none)
                        .fontWeight(theme.icons.weight)
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(theme.font(.headline))
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background { backgroundFill }
            .contentShape(controlShape)
        }
        .buttonStyle(PressableButtonStyle(pressAnimation: reduceMotion ? nil : theme.motion.snappy))
    }

    // MARK: Styling

    private var controlShape: AnyShape {
        theme.shape.buttonsAreCapsule ? AnyShape(Capsule()) : AnyShape(theme.controlShape)
    }

    private var foreground: Color {
        switch role {
        case .primary, .destructive: return theme.palette.onAccent
        case .secondary, .subtle: return theme.palette.accent
        }
    }

    @ViewBuilder
    private var backgroundFill: some View {
        switch role {
        case .primary:
            controlShape
                .fill(theme.palette.accent)
                .shadow(color: theme.effects.glowAccents ? theme.palette.accent.opacity(0.45) : .clear,
                        radius: theme.effects.glowAccents ? 10 : 0, x: 0, y: 4)
        case .secondary:
            controlShape.fill(theme.palette.fill)
        case .subtle:
            Color.clear
        case .destructive:
            controlShape.fill(theme.palette.negative)
        }
    }
}

// MARK: - PressableButtonStyle

/// Shared pressed-state treatment: scale 0.96 with the theme's snappy spring (nil under Reduce
/// Motion) and a tap haptic on touch-down.
struct PressableButtonStyle: ButtonStyle {
    var pressAnimation: Animation?
    var pressedScale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .animation(pressAnimation, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
    }
}
