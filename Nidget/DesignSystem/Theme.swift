import SwiftUI

// MARK: - Theme model
//
// A Theme is a complete design personality. It drives color, typography (font design + weight +
// casing), card construction, corner geometry, background treatment, shadow/glow, chrome style,
// icon rendering, spacing density, chart rendering, and motion character.
// Themes are code-defined (see ThemeCatalog+Light / ThemeCatalog+Dark); only the selected id is
// persisted. Feature code must consume themes exclusively through `@Environment(\.theme)`.

enum ThemeMode: String, Codable, Hashable {
    case light, dark
}

// MARK: Backdrop

/// Full-screen background treatment rendered by `Backdrop` (DesignSystem/Backdrop.swift).
enum BackdropStyle {
    /// Single flat color.
    case solid(Color)
    /// Top-to-bottom linear gradient through the given stops.
    case verticalGradient([Color])
    /// Soft 3x3 mesh gradient; colors are cycled to fill the 9 control points.
    case mesh([Color])
    /// Base color with large, blurred glow blobs floating near the top corners.
    case aurora(base: Color, glows: [Color])
    /// Two-tone split with a thin glowing horizon line between them.
    case horizon(top: Color, bottom: Color, accentLine: Color?)
}

// MARK: Palette

struct ThemePalette {
    var backdrop: BackdropStyle

    /// Base card fill.
    var surface: Color
    /// Fill for nested/raised elements sitting on a card (chips, keypad keys' hover state).
    var surfaceElevated: Color
    /// Card border color (used by .outlined / .brutal / hairlines).
    var surfaceBorder: Color

    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color

    var accent: Color
    var accentSecondary: Color
    /// Foreground drawn on top of `accent` fills.
    var onAccent: Color

    var positive: Color
    var negative: Color
    var warning: Color

    /// Subtle fill for controls, chips, and keypad keys.
    var fill: Color
    var separator: Color

    /// Categorical chart palette. Always ≥ 6 entries; consume via `chart[i % chart.count]`.
    var chart: [Color]
}

// MARK: Typography

struct ThemeTypography {
    /// Design for body/reading text.
    var design: Font.Design
    /// Design for display numerals and large titles (may differ from body — e.g. serif display
    /// over default body, or rounded everywhere).
    var displayDesign: Font.Design
    var displayWeight: Font.Weight
    /// Casing applied to section labels (`SectionHeader`); nil leaves natural case.
    var labelCase: Text.Case?
    /// Letter tracking for section labels (pts). Pair wide tracking with uppercase labels.
    var labelTracking: CGFloat
    /// Use monospaced digits for all amount text (alignment-critical themes; always true for
    /// monospaced-design themes).
    var useMonospacedDigits: Bool
}

/// Semantic font roles. All feature text uses `theme.font(_:)` — never `.font(.system(...))`.
enum FontRole {
    case hero        // 44pt — the one big number on a screen
    case display     // 32pt — card hero numbers
    case title       // 22pt — screen/card titles
    case headline    // 17pt semibold — row emphasis
    case body        // 17pt
    case subheadline // 15pt
    case caption     // 13pt
    case label       // 12pt — section labels (respect labelCase/labelTracking)
}

// MARK: Shape & card construction

enum CardStyle {
    /// Fill only. Quiet, editorial.
    case flat
    /// Fill + 1pt border.
    case outlined
    /// Fill + soft ambient shadow.
    case elevated
    /// Translucent material over the backdrop + hairline highlight border.
    case glass
    /// 2pt border + hard offset shadow. Neo-brutalist.
    case brutal
    /// Fill + 1.5pt accent→accentSecondary gradient border.
    case gradientOutline
}

struct ThemeShape {
    /// Corner radius for cards and sheets.
    var cornerRadius: CGFloat
    /// Corner radius for buttons, chips, and small controls (ignored when `buttonsAreCapsule`).
    var controlRadius: CGFloat
    var cardStyle: CardStyle
    var buttonsAreCapsule: Bool
}

// MARK: Effects & chrome

struct ShadowSpec {
    var color: Color
    var radius: CGFloat
    var x: CGFloat
    var y: CGFloat
}

/// Tab-bar / floating-control treatment.
enum ChromeStyle {
    /// System Liquid Glass chrome.
    case glass
    /// Opaque surface-colored chrome with a top hairline.
    case opaque
    /// Floating pill tab bar inset from the edges.
    case floating
}

struct ThemeEffects {
    /// Shadow used by `.elevated` cards (and floating buttons on any style).
    var shadow: ShadowSpec?
    /// Offset for the `.brutal` hard shadow.
    var brutalShadowOffset: CGSize
    /// Render a soft glow behind accent-colored heroes (rings, primary buttons).
    var glowAccents: Bool
    /// 0…0.12 opacity of the tiled noise texture over the backdrop (0 = off).
    var noiseOpacity: Double
    var chrome: ChromeStyle
}

// MARK: Layout, icons, charts, motion

struct ThemeLayout {
    /// Base spacing unit between sibling elements.
    var spacing: CGFloat
    /// Default inner padding of `.themedCard()`.
    var cardPadding: CGFloat
    /// Gap between cards / dashboard widgets.
    var cardSpacing: CGFloat
}

struct IconStyle {
    var weight: Font.Weight
    /// Prefer `.fill` symbol variants.
    var fill: Bool
}

struct ChartStyle {
    var barCornerRadius: CGFloat
    /// Catmull-Rom smoothed lines vs. straight segments.
    var smoothLines: Bool
    /// Fill line charts with a vertical accent gradient.
    var filledAreas: Bool
    var gridLines: Bool
}

struct ThemeMotion {
    /// Default spring for state/layout changes.
    var spring: Animation
    /// Quick feedback (pressed states, toggles).
    var snappy: Animation
    /// Celebratory / hero transitions.
    var emphasis: Animation
}

// MARK: - Theme

struct Theme: Identifiable {
    let id: String
    let name: String
    /// One-line personality description shown in the theme gallery.
    let tagline: String
    let mode: ThemeMode
    /// id of this theme's counterpart in the other mode, when a designed pair exists.
    let pairedID: String?

    let palette: ThemePalette
    let typography: ThemeTypography
    let shape: ThemeShape
    let effects: ThemeEffects
    let layout: ThemeLayout
    let icons: IconStyle
    let chart: ChartStyle
    let motion: ThemeMotion

    // MARK: Fonts

    func font(_ role: FontRole) -> Font {
        let f: Font
        switch role {
        case .hero:
            f = .system(size: 44, weight: typography.displayWeight, design: typography.displayDesign)
        case .display:
            f = .system(size: 32, weight: typography.displayWeight, design: typography.displayDesign)
        case .title:
            f = .system(size: 22, weight: .semibold, design: typography.displayDesign)
        case .headline:
            f = .system(size: 17, weight: .semibold, design: typography.design)
        case .body:
            f = .system(size: 17, weight: .regular, design: typography.design)
        case .subheadline:
            f = .system(size: 15, weight: .regular, design: typography.design)
        case .caption:
            f = .system(size: 13, weight: .regular, design: typography.design)
        case .label:
            f = .system(size: 12, weight: .semibold, design: typography.design)
        }
        switch role {
        case .hero, .display, .title:
            return typography.useMonospacedDigits ? f.monospacedDigit() : f
        default:
            return f
        }
    }

    /// Font for an amount at a given role, always honoring `useMonospacedDigits`.
    func amountFont(_ role: FontRole) -> Font {
        typography.useMonospacedDigits ? font(role).monospacedDigit() : font(role)
    }

    // MARK: Convenience

    var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: shape.cornerRadius, style: .continuous)
    }

    var controlShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: shape.controlRadius, style: .continuous)
    }

    /// Accent gradient used for progress fills, gauge arcs, and gradient borders.
    var accentGradient: LinearGradient {
        LinearGradient(colors: [palette.accent, palette.accentSecondary],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var colorScheme: ColorScheme { mode == .dark ? .dark : .light }
}

// MARK: - Fallback theme (used only before ThemeManager injects a catalog theme)

extension Theme {
    static let fallback = Theme(
        id: "fallback.graphite",
        name: "Graphite",
        tagline: "Neutral starting point.",
        mode: .dark,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.07, green: 0.07, blue: 0.09)),
            surface: Color(red: 0.12, green: 0.12, blue: 0.15),
            surfaceElevated: Color(red: 0.17, green: 0.17, blue: 0.21),
            surfaceBorder: Color.white.opacity(0.10),
            textPrimary: Color.white.opacity(0.95),
            textSecondary: Color.white.opacity(0.65),
            textTertiary: Color.white.opacity(0.40),
            accent: Color(red: 0.45, green: 0.62, blue: 1.0),
            accentSecondary: Color(red: 0.66, green: 0.50, blue: 1.0),
            onAccent: Color(red: 0.05, green: 0.06, blue: 0.10),
            positive: Color(red: 0.35, green: 0.80, blue: 0.55),
            negative: Color(red: 1.0, green: 0.45, blue: 0.45),
            warning: Color(red: 1.0, green: 0.72, blue: 0.30),
            fill: Color.white.opacity(0.08),
            separator: Color.white.opacity(0.08),
            chart: [
                Color(red: 0.45, green: 0.62, blue: 1.0),
                Color(red: 0.66, green: 0.50, blue: 1.0),
                Color(red: 0.35, green: 0.80, blue: 0.55),
                Color(red: 1.0, green: 0.72, blue: 0.30),
                Color(red: 1.0, green: 0.45, blue: 0.45),
                Color(red: 0.40, green: 0.80, blue: 0.85),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .rounded, displayWeight: .bold,
            labelCase: .uppercase, labelTracking: 1.2, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 20, controlRadius: 12,
                          cardStyle: .flat, buttonsAreCapsule: true),
        effects: ThemeEffects(shadow: nil, brutalShadowOffset: CGSize(width: 4, height: 4),
                              glowAccents: false, noiseOpacity: 0, chrome: .glass),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .medium, fill: false),
        chart: ChartStyle(barCornerRadius: 4, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.35),
                            snappy: .snappy(duration: 0.22),
                            emphasis: .bouncy(duration: 0.5, extraBounce: 0.06))
    )
}

// MARK: - Environment

private struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: Theme = .fallback
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}
