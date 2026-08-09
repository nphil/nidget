import SwiftUI

// MARK: - ThemeCatalog
//
// The full curated catalog: 20 light themes here, 20 dark themes in ThemeCatalog+Dark.swift.
// Themes are code-defined; only ids are persisted (ThemeManager). Every theme is a complete
// personality across color, type, card construction, geometry, backdrop, chrome, icons, charts,
// and motion.

enum ThemeCatalog {
    static let defaultLightID = "light.porcelain"
    static let defaultDarkID = "dark.obsidian"

    static var all: [Theme] { light + dark }

    static func theme(id: String) -> Theme? { index[id] }

    /// Lazily built id → theme index (static lets are initialized on first use).
    private static let index: [String: Theme] = {
        var map: [String: Theme] = [:]
        for theme in all { map[theme.id] = theme }
        return map
    }()

    static let light: [Theme] = [
        porcelain, paperLedger, mint, daybreak, studio,
        linen, sakura, seafoamGlass, newsprint, butter,
        sky, meadow, coral, brutalistLight, lavender,
        sandstone, arctic, citrus, gallery, solstice,
    ]
}

// MARK: - Light themes

private extension ThemeCatalog {

    // Soft neutral all-rounder. The light default.
    static let porcelain = Theme(
        id: "light.porcelain",
        name: "Porcelain",
        tagline: "Soft white, quietly confident.",
        mode: .light,
        pairedID: "dark.obsidian",
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.96, green: 0.96, blue: 0.97)),
            surface: Color(red: 1.0, green: 1.0, blue: 1.0),
            surfaceElevated: Color(red: 0.94, green: 0.95, blue: 0.97),
            surfaceBorder: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.08),
            textPrimary: Color(red: 0.10, green: 0.11, blue: 0.13),
            textSecondary: Color(red: 0.10, green: 0.11, blue: 0.13).opacity(0.62),
            textTertiary: Color(red: 0.10, green: 0.11, blue: 0.13).opacity(0.38),
            accent: Color(red: 0.20, green: 0.40, blue: 0.95),
            accentSecondary: Color(red: 0.45, green: 0.35, blue: 0.95),
            onAccent: Color(red: 1.0, green: 1.0, blue: 1.0),
            positive: Color(red: 0.0, green: 0.50, blue: 0.30),
            negative: Color(red: 0.82, green: 0.18, blue: 0.22),
            warning: Color(red: 0.72, green: 0.46, blue: 0.05),
            fill: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.05),
            separator: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.07),
            chart: [
                Color(red: 0.20, green: 0.40, blue: 0.95),
                Color(red: 0.55, green: 0.35, blue: 0.95),
                Color(red: 0.05, green: 0.60, blue: 0.60),
                Color(red: 0.90, green: 0.60, blue: 0.10),
                Color(red: 0.90, green: 0.30, blue: 0.45),
                Color(red: 0.35, green: 0.45, blue: 0.60),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .rounded, displayWeight: .bold,
            labelCase: .uppercase, labelTracking: 1.2, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 20, controlRadius: 12,
                          cardStyle: .elevated, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.20, green: 0.30, blue: 0.50).opacity(0.12),
                               radius: 16, x: 0, y: 8),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .glass
        ),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .medium, fill: true),
        chart: ChartStyle(barCornerRadius: 6, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.35),
                            snappy: .snappy(duration: 0.22),
                            emphasis: .bouncy(duration: 0.5, extraBounce: 0.06))
    )

    // Warm serif editorial on cream stock.
    static let paperLedger = Theme(
        id: "light.paper",
        name: "Paper Ledger",
        tagline: "Warm paper and a fountain pen.",
        mode: .light,
        pairedID: "dark.nocturne",
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.96, green: 0.94, blue: 0.89)),
            surface: Color(red: 0.99, green: 0.97, blue: 0.93),
            surfaceElevated: Color(red: 0.94, green: 0.91, blue: 0.85),
            surfaceBorder: Color(red: 0.35, green: 0.30, blue: 0.22).opacity(0.25),
            textPrimary: Color(red: 0.16, green: 0.13, blue: 0.10),
            textSecondary: Color(red: 0.16, green: 0.13, blue: 0.10).opacity(0.65),
            textTertiary: Color(red: 0.16, green: 0.13, blue: 0.10).opacity(0.40),
            accent: Color(red: 0.55, green: 0.25, blue: 0.15),
            accentSecondary: Color(red: 0.30, green: 0.42, blue: 0.30),
            onAccent: Color(red: 0.99, green: 0.97, blue: 0.93),
            positive: Color(red: 0.20, green: 0.42, blue: 0.22),
            negative: Color(red: 0.70, green: 0.20, blue: 0.16),
            warning: Color(red: 0.62, green: 0.42, blue: 0.08),
            fill: Color(red: 0.35, green: 0.30, blue: 0.20).opacity(0.08),
            separator: Color(red: 0.35, green: 0.30, blue: 0.20).opacity(0.12),
            chart: [
                Color(red: 0.55, green: 0.25, blue: 0.15),
                Color(red: 0.30, green: 0.45, blue: 0.28),
                Color(red: 0.20, green: 0.28, blue: 0.48),
                Color(red: 0.72, green: 0.52, blue: 0.12),
                Color(red: 0.45, green: 0.25, blue: 0.40),
                Color(red: 0.15, green: 0.42, blue: 0.45),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .serif, displayWeight: .semibold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 10, controlRadius: 8,
                          cardStyle: .flat, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0.06, chrome: .opaque
        ),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .regular, fill: false),
        chart: ChartStyle(barCornerRadius: 2, smoothLines: false, filledAreas: false, gridLines: true),
        motion: ThemeMotion(spring: .smooth(duration: 0.45),
                            snappy: .snappy(duration: 0.25),
                            emphasis: .smooth(duration: 0.6))
    )

    // Fresh rounded green, playful bounce.
    static let mint = Theme(
        id: "light.mint",
        name: "Mint",
        tagline: "Fresh, rounded, optimistic.",
        mode: .light,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.93, green: 0.97, blue: 0.94)),
            surface: Color(red: 1.0, green: 1.0, blue: 1.0),
            surfaceElevated: Color(red: 0.90, green: 0.96, blue: 0.92),
            surfaceBorder: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.06),
            textPrimary: Color(red: 0.09, green: 0.15, blue: 0.12),
            textSecondary: Color(red: 0.09, green: 0.15, blue: 0.12).opacity(0.62),
            textTertiary: Color(red: 0.09, green: 0.15, blue: 0.12).opacity(0.38),
            accent: Color(red: 0.0, green: 0.50, blue: 0.38),
            accentSecondary: Color(red: 0.15, green: 0.65, blue: 0.60),
            onAccent: Color(red: 1.0, green: 1.0, blue: 1.0),
            positive: Color(red: 0.05, green: 0.50, blue: 0.25),
            negative: Color(red: 0.80, green: 0.22, blue: 0.20),
            warning: Color(red: 0.70, green: 0.45, blue: 0.0),
            fill: Color(red: 0.0, green: 0.40, blue: 0.30).opacity(0.07),
            separator: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.06),
            chart: [
                Color(red: 0.0, green: 0.50, blue: 0.38),
                Color(red: 0.10, green: 0.55, blue: 0.60),
                Color(red: 0.40, green: 0.55, blue: 0.10),
                Color(red: 0.20, green: 0.45, blue: 0.80),
                Color(red: 0.85, green: 0.40, blue: 0.30),
                Color(red: 0.50, green: 0.35, blue: 0.75),
            ]
        ),
        typography: ThemeTypography(
            design: .rounded, displayDesign: .rounded, displayWeight: .bold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 28, controlRadius: 16,
                          cardStyle: .flat, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .floating
        ),
        layout: ThemeLayout(spacing: 14, cardPadding: 18, cardSpacing: 14),
        icons: IconStyle(weight: .semibold, fill: true),
        chart: ChartStyle(barCornerRadius: 8, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .bouncy(duration: 0.4, extraBounce: 0.12),
                            snappy: .snappy(duration: 0.2),
                            emphasis: .bouncy(duration: 0.55, extraBounce: 0.18))
    )

    // Pastel dawn mesh behind glass cards.
    static let daybreak = Theme(
        id: "light.daybreak",
        name: "Daybreak",
        tagline: "Pastel dawn behind glass.",
        mode: .light,
        pairedID: "dark.aurora",
        palette: ThemePalette(
            backdrop: .mesh([
                Color(red: 1.0, green: 0.92, blue: 0.88),
                Color(red: 0.90, green: 0.90, blue: 1.0),
                Color(red: 0.85, green: 0.94, blue: 1.0),
                Color(red: 1.0, green: 0.96, blue: 0.85),
                Color(red: 0.93, green: 0.90, blue: 0.99),
            ]),
            surface: Color(red: 1.0, green: 1.0, blue: 1.0),
            surfaceElevated: Color(red: 0.96, green: 0.94, blue: 0.98),
            surfaceBorder: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.60),
            textPrimary: Color(red: 0.12, green: 0.10, blue: 0.18),
            textSecondary: Color(red: 0.12, green: 0.10, blue: 0.18).opacity(0.62),
            textTertiary: Color(red: 0.12, green: 0.10, blue: 0.18).opacity(0.38),
            accent: Color(red: 0.78, green: 0.25, blue: 0.38),
            accentSecondary: Color(red: 0.95, green: 0.55, blue: 0.25),
            onAccent: Color(red: 1.0, green: 1.0, blue: 1.0),
            positive: Color(red: 0.0, green: 0.50, blue: 0.35),
            negative: Color(red: 0.80, green: 0.22, blue: 0.28),
            warning: Color(red: 0.72, green: 0.45, blue: 0.05),
            fill: Color(red: 0.50, green: 0.30, blue: 0.50).opacity(0.08),
            separator: Color(red: 0.20, green: 0.10, blue: 0.30).opacity(0.10),
            chart: [
                Color(red: 0.78, green: 0.25, blue: 0.38),
                Color(red: 0.85, green: 0.48, blue: 0.10),
                Color(red: 0.25, green: 0.50, blue: 0.85),
                Color(red: 0.55, green: 0.40, blue: 0.85),
                Color(red: 0.05, green: 0.55, blue: 0.55),
                Color(red: 0.80, green: 0.60, blue: 0.10),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .rounded, displayWeight: .bold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 24, controlRadius: 14,
                          cardStyle: .glass, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.60, green: 0.40, blue: 0.50).opacity(0.15),
                               radius: 18, x: 0, y: 10),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .glass
        ),
        layout: ThemeLayout(spacing: 14, cardPadding: 18, cardSpacing: 14),
        icons: IconStyle(weight: .medium, fill: true),
        chart: ChartStyle(barCornerRadius: 6, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.4),
                            snappy: .snappy(duration: 0.22),
                            emphasis: .bouncy(duration: 0.55, extraBounce: 0.1))
    )

    // Gallery-white modernism, heavy type, one loud red.
    static let studio = Theme(
        id: "light.studio",
        name: "Studio",
        tagline: "Gallery white. Let the numbers hang.",
        mode: .light,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.97, green: 0.97, blue: 0.96)),
            surface: Color(red: 1.0, green: 1.0, blue: 1.0),
            surfaceElevated: Color(red: 0.94, green: 0.94, blue: 0.93),
            surfaceBorder: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.08),
            textPrimary: Color(red: 0.07, green: 0.07, blue: 0.07),
            textSecondary: Color(red: 0.07, green: 0.07, blue: 0.07).opacity(0.60),
            textTertiary: Color(red: 0.07, green: 0.07, blue: 0.07).opacity(0.35),
            accent: Color(red: 0.80, green: 0.20, blue: 0.08),
            accentSecondary: Color(red: 0.10, green: 0.10, blue: 0.10),
            onAccent: Color(red: 1.0, green: 1.0, blue: 1.0),
            positive: Color(red: 0.0, green: 0.45, blue: 0.25),
            negative: Color(red: 0.78, green: 0.15, blue: 0.12),
            warning: Color(red: 0.65, green: 0.45, blue: 0.02),
            fill: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.05),
            separator: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.10),
            chart: [
                Color(red: 0.80, green: 0.20, blue: 0.08),
                Color(red: 0.10, green: 0.10, blue: 0.10),
                Color(red: 0.72, green: 0.52, blue: 0.08),
                Color(red: 0.15, green: 0.35, blue: 0.75),
                Color(red: 0.10, green: 0.45, blue: 0.30),
                Color(red: 0.55, green: 0.55, blue: 0.53),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .default, displayWeight: .heavy,
            labelCase: .uppercase, labelTracking: 1.5, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 12, controlRadius: 8,
                          cardStyle: .elevated, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.10),
                               radius: 20, x: 0, y: 10),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .opaque
        ),
        layout: ThemeLayout(spacing: 14, cardPadding: 18, cardSpacing: 16),
        icons: IconStyle(weight: .regular, fill: false),
        chart: ChartStyle(barCornerRadius: 2, smoothLines: false, filledAreas: false, gridLines: true),
        motion: ThemeMotion(spring: .smooth(duration: 0.4),
                            snappy: .snappy(duration: 0.2),
                            emphasis: .smooth(duration: 0.55))
    )

    // Sun-washed cloth, hairline outlines, serif headings.
    static let linen = Theme(
        id: "light.linen",
        name: "Linen",
        tagline: "Sun-washed cloth and quiet mornings.",
        mode: .light,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.95, green: 0.93, blue: 0.88)),
            surface: Color(red: 0.98, green: 0.96, blue: 0.92),
            surfaceElevated: Color(red: 0.93, green: 0.90, blue: 0.84),
            surfaceBorder: Color(red: 0.45, green: 0.38, blue: 0.28).opacity(0.30),
            textPrimary: Color(red: 0.20, green: 0.17, blue: 0.13),
            textSecondary: Color(red: 0.20, green: 0.17, blue: 0.13).opacity(0.65),
            textTertiary: Color(red: 0.20, green: 0.17, blue: 0.13).opacity(0.40),
            accent: Color(red: 0.63, green: 0.33, blue: 0.18),
            accentSecondary: Color(red: 0.55, green: 0.50, blue: 0.30),
            onAccent: Color(red: 0.99, green: 0.97, blue: 0.93),
            positive: Color(red: 0.25, green: 0.42, blue: 0.20),
            negative: Color(red: 0.68, green: 0.22, blue: 0.15),
            warning: Color(red: 0.60, green: 0.42, blue: 0.05),
            fill: Color(red: 0.45, green: 0.38, blue: 0.25).opacity(0.08),
            separator: Color(red: 0.45, green: 0.38, blue: 0.25).opacity(0.14),
            chart: [
                Color(red: 0.63, green: 0.33, blue: 0.18),
                Color(red: 0.48, green: 0.48, blue: 0.22),
                Color(red: 0.30, green: 0.42, blue: 0.55),
                Color(red: 0.72, green: 0.55, blue: 0.20),
                Color(red: 0.55, green: 0.35, blue: 0.42),
                Color(red: 0.35, green: 0.50, blue: 0.40),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .serif, displayWeight: .semibold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 14, controlRadius: 10,
                          cardStyle: .outlined, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0.05, chrome: .opaque
        ),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .regular, fill: false),
        chart: ChartStyle(barCornerRadius: 3, smoothLines: true, filledAreas: false, gridLines: true),
        motion: ThemeMotion(spring: .smooth(duration: 0.45),
                            snappy: .snappy(duration: 0.25),
                            emphasis: .smooth(duration: 0.6))
    )

    // Blossom glow, pink-tinted shadows, springy motion.
    static let sakura = Theme(
        id: "light.sakura",
        name: "Sakura",
        tagline: "Petals drifting over spring light.",
        mode: .light,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .aurora(base: Color(red: 0.99, green: 0.95, blue: 0.96), glows: [
                Color(red: 1.0, green: 0.80, blue: 0.86),
                Color(red: 0.95, green: 0.85, blue: 1.0),
                Color(red: 1.0, green: 0.90, blue: 0.80),
            ]),
            surface: Color(red: 1.0, green: 1.0, blue: 1.0),
            surfaceElevated: Color(red: 0.99, green: 0.93, blue: 0.95),
            surfaceBorder: Color(red: 0.85, green: 0.55, blue: 0.65).opacity(0.25),
            textPrimary: Color(red: 0.22, green: 0.12, blue: 0.16),
            textSecondary: Color(red: 0.22, green: 0.12, blue: 0.16).opacity(0.62),
            textTertiary: Color(red: 0.22, green: 0.12, blue: 0.16).opacity(0.38),
            accent: Color(red: 0.78, green: 0.20, blue: 0.40),
            accentSecondary: Color(red: 0.95, green: 0.55, blue: 0.60),
            onAccent: Color(red: 1.0, green: 1.0, blue: 1.0),
            positive: Color(red: 0.05, green: 0.48, blue: 0.30),
            negative: Color(red: 0.80, green: 0.20, blue: 0.30),
            warning: Color(red: 0.72, green: 0.45, blue: 0.05),
            fill: Color(red: 0.80, green: 0.40, blue: 0.50).opacity(0.08),
            separator: Color(red: 0.40, green: 0.20, blue: 0.25).opacity(0.10),
            chart: [
                Color(red: 0.78, green: 0.20, blue: 0.40),
                Color(red: 0.55, green: 0.38, blue: 0.80),
                Color(red: 0.20, green: 0.55, blue: 0.35),
                Color(red: 0.82, green: 0.58, blue: 0.12),
                Color(red: 0.25, green: 0.50, blue: 0.82),
                Color(red: 0.88, green: 0.45, blue: 0.28),
            ]
        ),
        typography: ThemeTypography(
            design: .rounded, displayDesign: .rounded, displayWeight: .bold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 22, controlRadius: 12,
                          cardStyle: .elevated, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.85, green: 0.40, blue: 0.55).opacity(0.16),
                               radius: 16, x: 0, y: 8),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .floating
        ),
        layout: ThemeLayout(spacing: 13, cardPadding: 16, cardSpacing: 13),
        icons: IconStyle(weight: .medium, fill: true),
        chart: ChartStyle(barCornerRadius: 7, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .bouncy(duration: 0.42, extraBounce: 0.1),
                            snappy: .snappy(duration: 0.2),
                            emphasis: .bouncy(duration: 0.6, extraBounce: 0.15))
    )

    // Cool tide light through frosted glass.
    static let seafoamGlass = Theme(
        id: "light.seafoam",
        name: "Seafoam Glass",
        tagline: "Cool tide light through frosted glass.",
        mode: .light,
        pairedID: "dark.deepsea",
        palette: ThemePalette(
            backdrop: .aurora(base: Color(red: 0.90, green: 0.96, blue: 0.96), glows: [
                Color(red: 0.65, green: 0.90, blue: 0.88),
                Color(red: 0.70, green: 0.88, blue: 0.98),
                Color(red: 0.85, green: 0.97, blue: 0.90),
            ]),
            surface: Color(red: 1.0, green: 1.0, blue: 1.0),
            surfaceElevated: Color(red: 0.90, green: 0.96, blue: 0.95),
            surfaceBorder: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.65),
            textPrimary: Color(red: 0.06, green: 0.16, blue: 0.17),
            textSecondary: Color(red: 0.06, green: 0.16, blue: 0.17).opacity(0.62),
            textTertiary: Color(red: 0.06, green: 0.16, blue: 0.17).opacity(0.38),
            accent: Color(red: 0.0, green: 0.45, blue: 0.50),
            accentSecondary: Color(red: 0.10, green: 0.60, blue: 0.55),
            onAccent: Color(red: 1.0, green: 1.0, blue: 1.0),
            positive: Color(red: 0.0, green: 0.48, blue: 0.30),
            negative: Color(red: 0.80, green: 0.25, blue: 0.25),
            warning: Color(red: 0.70, green: 0.45, blue: 0.02),
            fill: Color(red: 0.0, green: 0.35, blue: 0.35).opacity(0.08),
            separator: Color(red: 0.0, green: 0.20, blue: 0.20).opacity(0.10),
            chart: [
                Color(red: 0.0, green: 0.45, blue: 0.50),
                Color(red: 0.10, green: 0.55, blue: 0.35),
                Color(red: 0.20, green: 0.45, blue: 0.80),
                Color(red: 0.20, green: 0.30, blue: 0.60),
                Color(red: 0.75, green: 0.55, blue: 0.20),
                Color(red: 0.85, green: 0.40, blue: 0.30),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .rounded, displayWeight: .bold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 20, controlRadius: 12,
                          cardStyle: .glass, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.20, green: 0.50, blue: 0.50).opacity(0.14),
                               radius: 16, x: 0, y: 8),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .glass
        ),
        layout: ThemeLayout(spacing: 13, cardPadding: 16, cardSpacing: 13),
        icons: IconStyle(weight: .medium, fill: false),
        chart: ChartStyle(barCornerRadius: 6, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.38),
                            snappy: .snappy(duration: 0.22),
                            emphasis: .bouncy(duration: 0.5, extraBounce: 0.08))
    )

    // Monospace edition on recycled gray stock.
    static let newsprint = Theme(
        id: "light.newsprint",
        name: "Newsprint",
        tagline: "Monospace headlines, morning-edition gray.",
        mode: .light,
        pairedID: "dark.terminal",
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.93, green: 0.92, blue: 0.89)),
            surface: Color(red: 0.96, green: 0.95, blue: 0.92),
            surfaceElevated: Color(red: 0.90, green: 0.89, blue: 0.85),
            surfaceBorder: Color(red: 0.12, green: 0.12, blue: 0.11).opacity(0.70),
            textPrimary: Color(red: 0.10, green: 0.10, blue: 0.09),
            textSecondary: Color(red: 0.10, green: 0.10, blue: 0.09).opacity(0.68),
            textTertiary: Color(red: 0.10, green: 0.10, blue: 0.09).opacity(0.45),
            accent: Color(red: 0.75, green: 0.12, blue: 0.10),
            accentSecondary: Color(red: 0.15, green: 0.15, blue: 0.14),
            onAccent: Color(red: 0.98, green: 0.97, blue: 0.94),
            positive: Color(red: 0.10, green: 0.40, blue: 0.18),
            negative: Color(red: 0.72, green: 0.12, blue: 0.10),
            warning: Color(red: 0.58, green: 0.40, blue: 0.02),
            fill: Color(red: 0.10, green: 0.10, blue: 0.09).opacity(0.07),
            separator: Color(red: 0.10, green: 0.10, blue: 0.09).opacity(0.25),
            chart: [
                Color(red: 0.75, green: 0.12, blue: 0.10),
                Color(red: 0.12, green: 0.12, blue: 0.11),
                Color(red: 0.45, green: 0.44, blue: 0.42),
                Color(red: 0.25, green: 0.35, blue: 0.55),
                Color(red: 0.45, green: 0.45, blue: 0.15),
                Color(red: 0.50, green: 0.32, blue: 0.18),
            ]
        ),
        typography: ThemeTypography(
            design: .monospaced, displayDesign: .monospaced, displayWeight: .bold,
            labelCase: .uppercase, labelTracking: 1.2, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 4, controlRadius: 4,
                          cardStyle: .outlined, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 3, height: 3),
            glowAccents: false, noiseOpacity: 0.07, chrome: .opaque
        ),
        layout: ThemeLayout(spacing: 10, cardPadding: 14, cardSpacing: 10),
        icons: IconStyle(weight: .regular, fill: false),
        chart: ChartStyle(barCornerRadius: 0, smoothLines: false, filledAreas: false, gridLines: true),
        motion: ThemeMotion(spring: .snappy(duration: 0.2),
                            snappy: .snappy(duration: 0.14),
                            emphasis: .snappy(duration: 0.28))
    )

    // Warm, soft, generous corners and bounce.
    static let butter = Theme(
        id: "light.butter",
        name: "Butter",
        tagline: "Warm, soft, spread generously.",
        mode: .light,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .verticalGradient([
                Color(red: 1.0, green: 0.95, blue: 0.80),
                Color(red: 1.0, green: 0.99, blue: 0.94),
            ]),
            surface: Color(red: 1.0, green: 1.0, blue: 1.0),
            surfaceElevated: Color(red: 1.0, green: 0.96, blue: 0.86),
            surfaceBorder: Color(red: 0.60, green: 0.45, blue: 0.10).opacity(0.15),
            textPrimary: Color(red: 0.20, green: 0.15, blue: 0.05),
            textSecondary: Color(red: 0.20, green: 0.15, blue: 0.05).opacity(0.62),
            textTertiary: Color(red: 0.20, green: 0.15, blue: 0.05).opacity(0.38),
            accent: Color(red: 0.60, green: 0.38, blue: 0.0),
            accentSecondary: Color(red: 0.85, green: 0.58, blue: 0.10),
            onAccent: Color(red: 1.0, green: 1.0, blue: 1.0),
            positive: Color(red: 0.15, green: 0.48, blue: 0.20),
            negative: Color(red: 0.78, green: 0.20, blue: 0.15),
            warning: Color(red: 0.70, green: 0.42, blue: 0.02),
            fill: Color(red: 0.60, green: 0.45, blue: 0.10).opacity(0.10),
            separator: Color(red: 0.40, green: 0.30, blue: 0.10).opacity(0.12),
            chart: [
                Color(red: 0.60, green: 0.38, blue: 0.0),
                Color(red: 0.85, green: 0.58, blue: 0.10),
                Color(red: 0.30, green: 0.55, blue: 0.20),
                Color(red: 0.78, green: 0.35, blue: 0.20),
                Color(red: 0.55, green: 0.32, blue: 0.55),
                Color(red: 0.25, green: 0.45, blue: 0.75),
            ]
        ),
        typography: ThemeTypography(
            design: .rounded, displayDesign: .rounded, displayWeight: .bold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 26, controlRadius: 16,
                          cardStyle: .elevated, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.75, green: 0.55, blue: 0.15).opacity(0.18),
                               radius: 18, x: 0, y: 10),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .floating
        ),
        layout: ThemeLayout(spacing: 16, cardPadding: 20, cardSpacing: 16),
        icons: IconStyle(weight: .semibold, fill: true),
        chart: ChartStyle(barCornerRadius: 8, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .bouncy(duration: 0.45, extraBounce: 0.12),
                            snappy: .snappy(duration: 0.2),
                            emphasis: .bouncy(duration: 0.6, extraBounce: 0.18))
    )

    // Clear morning air, glass over a blue gradient.
    static let sky = Theme(
        id: "light.sky",
        name: "Sky",
        tagline: "Clear morning air, glass and light.",
        mode: .light,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .verticalGradient([
                Color(red: 0.72, green: 0.85, blue: 0.98),
                Color(red: 0.92, green: 0.96, blue: 1.0),
            ]),
            surface: Color(red: 1.0, green: 1.0, blue: 1.0),
            surfaceElevated: Color(red: 0.90, green: 0.95, blue: 1.0),
            surfaceBorder: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.70),
            textPrimary: Color(red: 0.08, green: 0.14, blue: 0.22),
            textSecondary: Color(red: 0.08, green: 0.14, blue: 0.22).opacity(0.62),
            textTertiary: Color(red: 0.08, green: 0.14, blue: 0.22).opacity(0.38),
            accent: Color(red: 0.10, green: 0.40, blue: 0.80),
            accentSecondary: Color(red: 0.30, green: 0.60, blue: 0.90),
            onAccent: Color(red: 1.0, green: 1.0, blue: 1.0),
            positive: Color(red: 0.0, green: 0.48, blue: 0.30),
            negative: Color(red: 0.80, green: 0.22, blue: 0.25),
            warning: Color(red: 0.70, green: 0.45, blue: 0.02),
            fill: Color(red: 0.10, green: 0.35, blue: 0.60).opacity(0.08),
            separator: Color(red: 0.10, green: 0.20, blue: 0.40).opacity(0.10),
            chart: [
                Color(red: 0.10, green: 0.40, blue: 0.80),
                Color(red: 0.0, green: 0.55, blue: 0.60),
                Color(red: 0.40, green: 0.35, blue: 0.85),
                Color(red: 0.85, green: 0.60, blue: 0.10),
                Color(red: 0.85, green: 0.35, blue: 0.45),
                Color(red: 0.45, green: 0.55, blue: 0.68),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .rounded, displayWeight: .bold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 22, controlRadius: 12,
                          cardStyle: .glass, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.20, green: 0.40, blue: 0.70).opacity(0.14),
                               radius: 16, x: 0, y: 8),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .glass
        ),
        layout: ThemeLayout(spacing: 13, cardPadding: 16, cardSpacing: 13),
        icons: IconStyle(weight: .medium, fill: false),
        chart: ChartStyle(barCornerRadius: 6, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.38),
                            snappy: .snappy(duration: 0.22),
                            emphasis: .bouncy(duration: 0.5, extraBounce: 0.08))
    )

    // Soft green mesh, wildflower chart colors.
    static let meadow = Theme(
        id: "light.meadow",
        name: "Meadow",
        tagline: "Wildflowers in soft focus.",
        mode: .light,
        pairedID: "dark.forest",
        palette: ThemePalette(
            backdrop: .mesh([
                Color(red: 0.88, green: 0.95, blue: 0.85),
                Color(red: 0.95, green: 0.97, blue: 0.85),
                Color(red: 0.85, green: 0.93, blue: 0.90),
                Color(red: 0.92, green: 0.96, blue: 0.88),
                Color(red: 0.97, green: 0.95, blue: 0.85),
            ]),
            surface: Color(red: 0.99, green: 1.0, blue: 0.97),
            surfaceElevated: Color(red: 0.92, green: 0.96, blue: 0.88),
            surfaceBorder: Color(red: 0.30, green: 0.40, blue: 0.20).opacity(0.18),
            textPrimary: Color(red: 0.12, green: 0.17, blue: 0.10),
            textSecondary: Color(red: 0.12, green: 0.17, blue: 0.10).opacity(0.62),
            textTertiary: Color(red: 0.12, green: 0.17, blue: 0.10).opacity(0.38),
            accent: Color(red: 0.25, green: 0.48, blue: 0.10),
            accentSecondary: Color(red: 0.65, green: 0.60, blue: 0.10),
            onAccent: Color(red: 1.0, green: 1.0, blue: 1.0),
            positive: Color(red: 0.15, green: 0.48, blue: 0.22),
            negative: Color(red: 0.78, green: 0.25, blue: 0.20),
            warning: Color(red: 0.68, green: 0.45, blue: 0.02),
            fill: Color(red: 0.30, green: 0.45, blue: 0.20).opacity(0.09),
            separator: Color(red: 0.20, green: 0.30, blue: 0.15).opacity(0.12),
            chart: [
                Color(red: 0.25, green: 0.48, blue: 0.10),
                Color(red: 0.75, green: 0.55, blue: 0.10),
                Color(red: 0.25, green: 0.50, blue: 0.80),
                Color(red: 0.82, green: 0.30, blue: 0.22),
                Color(red: 0.50, green: 0.35, blue: 0.72),
                Color(red: 0.05, green: 0.52, blue: 0.48),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .rounded, displayWeight: .bold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 18, controlRadius: 12,
                          cardStyle: .flat, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .floating
        ),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .medium, fill: true),
        chart: ChartStyle(barCornerRadius: 6, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.38),
                            snappy: .snappy(duration: 0.22),
                            emphasis: .bouncy(duration: 0.55, extraBounce: 0.1))
    )

    // Sunset warmth over white, easy energy.
    static let coral = Theme(
        id: "light.coral",
        name: "Coral",
        tagline: "Sunset warmth, easy energy.",
        mode: .light,
        pairedID: "dark.ember",
        palette: ThemePalette(
            backdrop: .verticalGradient([
                Color(red: 1.0, green: 0.92, blue: 0.88),
                Color(red: 1.0, green: 0.97, blue: 0.94),
            ]),
            surface: Color(red: 1.0, green: 1.0, blue: 1.0),
            surfaceElevated: Color(red: 1.0, green: 0.93, blue: 0.89),
            surfaceBorder: Color(red: 0.80, green: 0.40, blue: 0.30).opacity(0.18),
            textPrimary: Color(red: 0.22, green: 0.12, blue: 0.09),
            textSecondary: Color(red: 0.22, green: 0.12, blue: 0.09).opacity(0.62),
            textTertiary: Color(red: 0.22, green: 0.12, blue: 0.09).opacity(0.38),
            accent: Color(red: 0.80, green: 0.25, blue: 0.16),
            accentSecondary: Color(red: 0.95, green: 0.55, blue: 0.30),
            onAccent: Color(red: 1.0, green: 1.0, blue: 1.0),
            positive: Color(red: 0.0, green: 0.50, blue: 0.32),
            negative: Color(red: 0.72, green: 0.10, blue: 0.22),
            warning: Color(red: 0.70, green: 0.44, blue: 0.0),
            fill: Color(red: 0.85, green: 0.40, blue: 0.30).opacity(0.09),
            separator: Color(red: 0.40, green: 0.20, blue: 0.15).opacity(0.10),
            chart: [
                Color(red: 0.80, green: 0.25, blue: 0.16),
                Color(red: 0.85, green: 0.50, blue: 0.12),
                Color(red: 0.0, green: 0.52, blue: 0.50),
                Color(red: 0.20, green: 0.30, blue: 0.58),
                Color(red: 0.80, green: 0.25, blue: 0.50),
                Color(red: 0.65, green: 0.55, blue: 0.15),
            ]
        ),
        typography: ThemeTypography(
            design: .rounded, displayDesign: .rounded, displayWeight: .bold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 20, controlRadius: 12,
                          cardStyle: .elevated, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.85, green: 0.35, blue: 0.25).opacity(0.16),
                               radius: 16, x: 0, y: 8),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .floating
        ),
        layout: ThemeLayout(spacing: 13, cardPadding: 16, cardSpacing: 13),
        icons: IconStyle(weight: .medium, fill: true),
        chart: ChartStyle(barCornerRadius: 7, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .bouncy(duration: 0.42, extraBounce: 0.1),
                            snappy: .snappy(duration: 0.2),
                            emphasis: .bouncy(duration: 0.58, extraBounce: 0.16))
    )

    // Hard black lines and offset shadows on raw canvas.
    static let brutalistLight = Theme(
        id: "light.brutalist",
        name: "Brutalist Light",
        tagline: "Black lines, loud blocks, zero apology.",
        mode: .light,
        pairedID: "dark.brutalist",
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.94, green: 0.93, blue: 0.89)),
            surface: Color(red: 0.99, green: 0.98, blue: 0.95),
            surfaceElevated: Color(red: 0.90, green: 0.89, blue: 0.84),
            surfaceBorder: Color(red: 0.05, green: 0.05, blue: 0.05),
            textPrimary: Color(red: 0.05, green: 0.05, blue: 0.05),
            textSecondary: Color(red: 0.05, green: 0.05, blue: 0.05).opacity(0.70),
            textTertiary: Color(red: 0.05, green: 0.05, blue: 0.05).opacity(0.45),
            accent: Color(red: 0.10, green: 0.30, blue: 0.90),
            accentSecondary: Color(red: 0.95, green: 0.75, blue: 0.0),
            onAccent: Color(red: 1.0, green: 1.0, blue: 1.0),
            positive: Color(red: 0.0, green: 0.45, blue: 0.15),
            negative: Color(red: 0.85, green: 0.10, blue: 0.10),
            warning: Color(red: 0.65, green: 0.45, blue: 0.0),
            fill: Color(red: 0.05, green: 0.05, blue: 0.05).opacity(0.07),
            separator: Color(red: 0.05, green: 0.05, blue: 0.05).opacity(0.85),
            chart: [
                Color(red: 0.10, green: 0.30, blue: 0.90),
                Color(red: 0.85, green: 0.65, blue: 0.0),
                Color(red: 0.85, green: 0.10, blue: 0.10),
                Color(red: 0.0, green: 0.50, blue: 0.20),
                Color(red: 0.05, green: 0.05, blue: 0.05),
                Color(red: 0.80, green: 0.10, blue: 0.60),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .default, displayWeight: .heavy,
            labelCase: .uppercase, labelTracking: 1.2, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 6, controlRadius: 4,
                          cardStyle: .brutal, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 5, height: 5),
            glowAccents: false, noiseOpacity: 0, chrome: .opaque
        ),
        layout: ThemeLayout(spacing: 10, cardPadding: 14, cardSpacing: 12),
        icons: IconStyle(weight: .bold, fill: false),
        chart: ChartStyle(barCornerRadius: 0, smoothLines: false, filledAreas: false, gridLines: true),
        motion: ThemeMotion(spring: .snappy(duration: 0.2),
                            snappy: .snappy(duration: 0.12),
                            emphasis: .snappy(duration: 0.28))
    )

    // Dusk-lit violet calm with serif headings.
    static let lavender = Theme(
        id: "light.lavender",
        name: "Lavender",
        tagline: "Dusk-lit calm in soft violet.",
        mode: .light,
        pairedID: "dark.velvet",
        palette: ThemePalette(
            backdrop: .verticalGradient([
                Color(red: 0.93, green: 0.90, blue: 0.98),
                Color(red: 0.97, green: 0.95, blue: 1.0),
            ]),
            surface: Color(red: 1.0, green: 1.0, blue: 1.0),
            surfaceElevated: Color(red: 0.94, green: 0.91, blue: 0.99),
            surfaceBorder: Color(red: 0.45, green: 0.35, blue: 0.65).opacity(0.18),
            textPrimary: Color(red: 0.16, green: 0.12, blue: 0.24),
            textSecondary: Color(red: 0.16, green: 0.12, blue: 0.24).opacity(0.62),
            textTertiary: Color(red: 0.16, green: 0.12, blue: 0.24).opacity(0.38),
            accent: Color(red: 0.48, green: 0.30, blue: 0.75),
            accentSecondary: Color(red: 0.72, green: 0.40, blue: 0.75),
            onAccent: Color(red: 1.0, green: 1.0, blue: 1.0),
            positive: Color(red: 0.05, green: 0.48, blue: 0.32),
            negative: Color(red: 0.80, green: 0.22, blue: 0.30),
            warning: Color(red: 0.70, green: 0.44, blue: 0.02),
            fill: Color(red: 0.45, green: 0.35, blue: 0.70).opacity(0.08),
            separator: Color(red: 0.30, green: 0.20, blue: 0.45).opacity(0.10),
            chart: [
                Color(red: 0.48, green: 0.30, blue: 0.75),
                Color(red: 0.72, green: 0.35, blue: 0.68),
                Color(red: 0.30, green: 0.35, blue: 0.80),
                Color(red: 0.82, green: 0.32, blue: 0.48),
                Color(red: 0.10, green: 0.52, blue: 0.55),
                Color(red: 0.78, green: 0.56, blue: 0.12),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .serif, displayWeight: .semibold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 20, controlRadius: 12,
                          cardStyle: .elevated, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.45, green: 0.35, blue: 0.70).opacity(0.15),
                               radius: 16, x: 0, y: 8),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .floating
        ),
        layout: ThemeLayout(spacing: 13, cardPadding: 17, cardSpacing: 13),
        icons: IconStyle(weight: .regular, fill: false),
        chart: ChartStyle(barCornerRadius: 5, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.42),
                            snappy: .snappy(duration: 0.24),
                            emphasis: .smooth(duration: 0.6))
    )

    // Desert stone: warm, grounded, lightly textured.
    static let sandstone = Theme(
        id: "light.sandstone",
        name: "Sandstone",
        tagline: "Desert stone, sure-footed and warm.",
        mode: .light,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.93, green: 0.89, blue: 0.82)),
            surface: Color(red: 0.97, green: 0.94, blue: 0.88),
            surfaceElevated: Color(red: 0.90, green: 0.85, blue: 0.76),
            surfaceBorder: Color(red: 0.40, green: 0.30, blue: 0.18).opacity(0.30),
            textPrimary: Color(red: 0.22, green: 0.16, blue: 0.10),
            textSecondary: Color(red: 0.22, green: 0.16, blue: 0.10).opacity(0.65),
            textTertiary: Color(red: 0.22, green: 0.16, blue: 0.10).opacity(0.40),
            accent: Color(red: 0.70, green: 0.32, blue: 0.12),
            accentSecondary: Color(red: 0.50, green: 0.42, blue: 0.25),
            onAccent: Color(red: 0.99, green: 0.96, blue: 0.90),
            positive: Color(red: 0.28, green: 0.42, blue: 0.15),
            negative: Color(red: 0.72, green: 0.18, blue: 0.12),
            warning: Color(red: 0.62, green: 0.40, blue: 0.02),
            fill: Color(red: 0.40, green: 0.30, blue: 0.18).opacity(0.09),
            separator: Color(red: 0.40, green: 0.30, blue: 0.18).opacity(0.16),
            chart: [
                Color(red: 0.70, green: 0.32, blue: 0.12),
                Color(red: 0.42, green: 0.48, blue: 0.28),
                Color(red: 0.28, green: 0.38, blue: 0.52),
                Color(red: 0.72, green: 0.52, blue: 0.15),
                Color(red: 0.68, green: 0.38, blue: 0.35),
                Color(red: 0.20, green: 0.45, blue: 0.32),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .default, displayWeight: .semibold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 12, controlRadius: 8,
                          cardStyle: .outlined, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0.04, chrome: .opaque
        ),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .medium, fill: false),
        chart: ChartStyle(barCornerRadius: 3, smoothLines: true, filledAreas: false, gridLines: true),
        motion: ThemeMotion(spring: .smooth(duration: 0.4),
                            snappy: .snappy(duration: 0.24),
                            emphasis: .smooth(duration: 0.55))
    )

    // Ice-clear precision: crisp edges, cold blue, quick motion.
    static let arctic = Theme(
        id: "light.arctic",
        name: "Arctic",
        tagline: "Ice-clear precision, cold light.",
        mode: .light,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.93, green: 0.96, blue: 0.98)),
            surface: Color(red: 1.0, green: 1.0, blue: 1.0),
            surfaceElevated: Color(red: 0.88, green: 0.93, blue: 0.97),
            surfaceBorder: Color(red: 0.30, green: 0.50, blue: 0.65).opacity(0.20),
            textPrimary: Color(red: 0.05, green: 0.12, blue: 0.18),
            textSecondary: Color(red: 0.05, green: 0.12, blue: 0.18).opacity(0.62),
            textTertiary: Color(red: 0.05, green: 0.12, blue: 0.18).opacity(0.38),
            accent: Color(red: 0.0, green: 0.45, blue: 0.65),
            accentSecondary: Color(red: 0.35, green: 0.65, blue: 0.80),
            onAccent: Color(red: 1.0, green: 1.0, blue: 1.0),
            positive: Color(red: 0.0, green: 0.48, blue: 0.35),
            negative: Color(red: 0.80, green: 0.20, blue: 0.25),
            warning: Color(red: 0.68, green: 0.44, blue: 0.0),
            fill: Color(red: 0.10, green: 0.40, blue: 0.55).opacity(0.08),
            separator: Color(red: 0.10, green: 0.30, blue: 0.40).opacity(0.10),
            chart: [
                Color(red: 0.0, green: 0.45, blue: 0.65),
                Color(red: 0.15, green: 0.25, blue: 0.55),
                Color(red: 0.10, green: 0.58, blue: 0.50),
                Color(red: 0.45, green: 0.55, blue: 0.65),
                Color(red: 0.45, green: 0.38, blue: 0.80),
                Color(red: 0.72, green: 0.25, blue: 0.55),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .default, displayWeight: .bold,
            labelCase: .uppercase, labelTracking: 1.2, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 16, controlRadius: 10,
                          cardStyle: .elevated, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.20, green: 0.45, blue: 0.60).opacity(0.12),
                               radius: 14, x: 0, y: 7),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .glass
        ),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .medium, fill: false),
        chart: ChartStyle(barCornerRadius: 2, smoothLines: false, filledAreas: true, gridLines: true),
        motion: ThemeMotion(spring: .smooth(duration: 0.3),
                            snappy: .snappy(duration: 0.18),
                            emphasis: .snappy(duration: 0.35))
    )

    // Loud rounded brutalism in orange and lime.
    static let citrus = Theme(
        id: "light.citrus",
        name: "Citrus",
        tagline: "Zest first, questions later.",
        mode: .light,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .solid(Color(red: 1.0, green: 0.98, blue: 0.92)),
            surface: Color(red: 1.0, green: 1.0, blue: 1.0),
            surfaceElevated: Color(red: 1.0, green: 0.95, blue: 0.85),
            surfaceBorder: Color(red: 0.15, green: 0.10, blue: 0.05),
            textPrimary: Color(red: 0.15, green: 0.10, blue: 0.03),
            textSecondary: Color(red: 0.15, green: 0.10, blue: 0.03).opacity(0.65),
            textTertiary: Color(red: 0.15, green: 0.10, blue: 0.03).opacity(0.40),
            accent: Color(red: 0.90, green: 0.42, blue: 0.0),
            accentSecondary: Color(red: 0.30, green: 0.65, blue: 0.15),
            onAccent: Color(red: 0.15, green: 0.10, blue: 0.03),
            positive: Color(red: 0.10, green: 0.50, blue: 0.10),
            negative: Color(red: 0.80, green: 0.12, blue: 0.15),
            warning: Color(red: 0.60, green: 0.42, blue: 0.0),
            fill: Color(red: 0.90, green: 0.50, blue: 0.10).opacity(0.10),
            separator: Color(red: 0.15, green: 0.10, blue: 0.05).opacity(0.60),
            chart: [
                Color(red: 0.90, green: 0.42, blue: 0.0),
                Color(red: 0.35, green: 0.55, blue: 0.0),
                Color(red: 0.85, green: 0.20, blue: 0.45),
                Color(red: 0.10, green: 0.40, blue: 0.85),
                Color(red: 0.80, green: 0.62, blue: 0.0),
                Color(red: 0.0, green: 0.48, blue: 0.30),
            ]
        ),
        typography: ThemeTypography(
            design: .rounded, displayDesign: .rounded, displayWeight: .heavy,
            labelCase: .uppercase, labelTracking: 1.0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 12, controlRadius: 8,
                          cardStyle: .brutal, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .floating
        ),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .bold, fill: true),
        chart: ChartStyle(barCornerRadius: 4, smoothLines: false, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .bouncy(duration: 0.35, extraBounce: 0.15),
                            snappy: .snappy(duration: 0.15),
                            emphasis: .bouncy(duration: 0.5, extraBounce: 0.2))
    )

    // White walls, serif captions, one red dot.
    static let gallery = Theme(
        id: "light.gallery",
        name: "Gallery",
        tagline: "White walls, serif captions, one red dot.",
        mode: .light,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.98, green: 0.98, blue: 0.97)),
            surface: Color(red: 1.0, green: 1.0, blue: 1.0),
            surfaceElevated: Color(red: 0.95, green: 0.95, blue: 0.94),
            surfaceBorder: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.10),
            textPrimary: Color(red: 0.10, green: 0.10, blue: 0.10),
            textSecondary: Color(red: 0.10, green: 0.10, blue: 0.10).opacity(0.60),
            textTertiary: Color(red: 0.10, green: 0.10, blue: 0.10).opacity(0.35),
            accent: Color(red: 0.72, green: 0.10, blue: 0.15),
            accentSecondary: Color(red: 0.35, green: 0.35, blue: 0.35),
            onAccent: Color(red: 1.0, green: 1.0, blue: 1.0),
            positive: Color(red: 0.10, green: 0.42, blue: 0.25),
            negative: Color(red: 0.75, green: 0.15, blue: 0.20),
            warning: Color(red: 0.62, green: 0.42, blue: 0.0),
            fill: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.04),
            separator: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.12),
            chart: [
                Color(red: 0.72, green: 0.10, blue: 0.15),
                Color(red: 0.20, green: 0.20, blue: 0.20),
                Color(red: 0.55, green: 0.55, blue: 0.54),
                Color(red: 0.70, green: 0.52, blue: 0.10),
                Color(red: 0.20, green: 0.28, blue: 0.50),
                Color(red: 0.35, green: 0.42, blue: 0.25),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .serif, displayWeight: .semibold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 8, controlRadius: 6,
                          cardStyle: .flat, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .opaque
        ),
        layout: ThemeLayout(spacing: 14, cardPadding: 18, cardSpacing: 16),
        icons: IconStyle(weight: .light, fill: false),
        chart: ChartStyle(barCornerRadius: 1, smoothLines: false, filledAreas: false, gridLines: true),
        motion: ThemeMotion(spring: .smooth(duration: 0.45),
                            snappy: .snappy(duration: 0.24),
                            emphasis: .smooth(duration: 0.65))
    )

    // Golden horizon line, amber-to-rose gradient borders.
    static let solstice = Theme(
        id: "light.solstice",
        name: "Solstice",
        tagline: "The longest light, held at the horizon.",
        mode: .light,
        pairedID: "dark.harbor",
        palette: ThemePalette(
            backdrop: .horizon(top: Color(red: 1.0, green: 0.93, blue: 0.80),
                               bottom: Color(red: 0.99, green: 0.97, blue: 0.92),
                               accentLine: Color(red: 0.95, green: 0.60, blue: 0.20)),
            surface: Color(red: 1.0, green: 1.0, blue: 1.0),
            surfaceElevated: Color(red: 1.0, green: 0.95, blue: 0.85),
            surfaceBorder: Color(red: 0.85, green: 0.55, blue: 0.20).opacity(0.30),
            textPrimary: Color(red: 0.20, green: 0.14, blue: 0.06),
            textSecondary: Color(red: 0.20, green: 0.14, blue: 0.06).opacity(0.62),
            textTertiary: Color(red: 0.20, green: 0.14, blue: 0.06).opacity(0.38),
            accent: Color(red: 0.70, green: 0.35, blue: 0.0),
            accentSecondary: Color(red: 0.85, green: 0.25, blue: 0.35),
            onAccent: Color(red: 1.0, green: 1.0, blue: 1.0),
            positive: Color(red: 0.10, green: 0.48, blue: 0.25),
            negative: Color(red: 0.78, green: 0.18, blue: 0.22),
            warning: Color(red: 0.65, green: 0.42, blue: 0.0),
            fill: Color(red: 0.80, green: 0.50, blue: 0.15).opacity(0.10),
            separator: Color(red: 0.45, green: 0.30, blue: 0.10).opacity(0.12),
            chart: [
                Color(red: 0.70, green: 0.35, blue: 0.0),
                Color(red: 0.85, green: 0.25, blue: 0.35),
                Color(red: 0.80, green: 0.60, blue: 0.05),
                Color(red: 0.30, green: 0.45, blue: 0.75),
                Color(red: 0.55, green: 0.28, blue: 0.50),
                Color(red: 0.05, green: 0.50, blue: 0.48),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .default, displayWeight: .bold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 16, controlRadius: 10,
                          cardStyle: .gradientOutline, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .floating
        ),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .medium, fill: false),
        chart: ChartStyle(barCornerRadius: 4, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.4),
                            snappy: .snappy(duration: 0.22),
                            emphasis: .bouncy(duration: 0.5, extraBounce: 0.08))
    )
}
