import SwiftUI

// MARK: - Appearance

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Always Light"
        case .dark: return "Always Dark"
        }
    }
}

// MARK: - ThemeManager
//
// Owns theme selection + persistence. One selected theme per mode; `active` resolves against the
// appearance mode and the system color scheme (fed in by RootView). Self-contained persistence in
// UserDefaults — only ids are stored, themes themselves live in code (ThemeCatalog).

@MainActor @Observable
final class ThemeManager {
    static let shared = ThemeManager()

    private static let lightKey = "nidget.theme.light"
    private static let darkKey = "nidget.theme.dark"
    private static let modeKey = "nidget.theme.mode"

    var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.modeKey) }
    }
    var lightThemeID: String {
        didSet { UserDefaults.standard.set(lightThemeID, forKey: Self.lightKey) }
    }
    var darkThemeID: String {
        didSet { UserDefaults.standard.set(darkThemeID, forKey: Self.darkKey) }
    }
    /// Mirrors the device color scheme; RootView keeps this current via `onChange(of: colorScheme)`.
    var systemIsDark: Bool = true

    private init() {
        let d = UserDefaults.standard
        appearanceMode = AppearanceMode(rawValue: d.string(forKey: Self.modeKey) ?? "") ?? .system
        lightThemeID = d.string(forKey: Self.lightKey) ?? ThemeCatalog.defaultLightID
        darkThemeID = d.string(forKey: Self.darkKey) ?? ThemeCatalog.defaultDarkID
    }

    /// The theme every view should currently render with.
    var active: Theme {
        let wantsDark: Bool
        switch appearanceMode {
        case .system: wantsDark = systemIsDark
        case .light: wantsDark = false
        case .dark: wantsDark = true
        }
        let id = wantsDark ? darkThemeID : lightThemeID
        return ThemeCatalog.theme(id: id)
            ?? (wantsDark ? ThemeCatalog.theme(id: ThemeCatalog.defaultDarkID) : ThemeCatalog.theme(id: ThemeCatalog.defaultLightID))
            ?? .fallback
    }

    /// Select a theme for its own mode's slot.
    func select(_ theme: Theme) {
        switch theme.mode {
        case .light: lightThemeID = theme.id
        case .dark: darkThemeID = theme.id
        }
    }

    func isSelected(_ theme: Theme) -> Bool {
        theme.mode == .light ? lightThemeID == theme.id : darkThemeID == theme.id
    }

    /// Preferred ColorScheme override for the app (nil = follow system).
    var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Screen & card modifiers

private struct ThemedScreenModifier: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Backdrop(style: theme.palette.backdrop)
                    .overlay {
                        if theme.effects.noiseOpacity > 0 {
                            NoiseTexture.tiled
                                .opacity(theme.effects.noiseOpacity)
                                .allowsHitTesting(false)
                        }
                    }
                    .ignoresSafeArea()
            }
    }
}

private struct ThemedCardModifier: ViewModifier {
    @Environment(\.theme) private var theme
    var padding: CGFloat?

    func body(content: Content) -> some View {
        let shape = theme.cardShape
        content
            .padding(padding ?? theme.layout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                switch theme.shape.cardStyle {
                case .flat:
                    shape.fill(theme.palette.surface)
                case .outlined:
                    shape.fill(theme.palette.surface)
                        .overlay(shape.strokeBorder(theme.palette.surfaceBorder, lineWidth: 1))
                case .elevated:
                    shape.fill(theme.palette.surface)
                        .shadow(color: theme.effects.shadow?.color ?? .black.opacity(0.15),
                                radius: theme.effects.shadow?.radius ?? 14,
                                x: theme.effects.shadow?.x ?? 0,
                                y: theme.effects.shadow?.y ?? 6)
                case .glass:
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.strokeBorder(theme.palette.surfaceBorder, lineWidth: 1))
                case .brutal:
                    shape.fill(theme.palette.surfaceBorder)
                        .offset(x: theme.effects.brutalShadowOffset.width,
                                y: theme.effects.brutalShadowOffset.height)
                        .overlay(shape.fill(theme.palette.surface))
                        .overlay(shape.strokeBorder(theme.palette.surfaceBorder, lineWidth: 2))
                case .gradientOutline:
                    shape.fill(theme.palette.surface)
                        .overlay(shape.strokeBorder(theme.accentGradient, lineWidth: 1.5))
                }
            }
    }
}

extension View {
    /// Full-bleed themed background for a screen.
    func themedScreen() -> some View { modifier(ThemedScreenModifier()) }

    /// Wrap content in the theme's card treatment.
    func themedCard(padding: CGFloat? = nil) -> some View {
        modifier(ThemedCardModifier(padding: padding))
    }
}
