import SwiftUI

// MARK: - Dark themes (ThemeCatalog+Light.swift declares the ThemeCatalog enum)

extension ThemeCatalog {
    static let dark: [Theme] = [
        obsidian, terminal, aurora, neonLedger, nocturne,
        ink, ember, deepSea, velvet, graphite,
        cosmos, forestNight, brutalistDark, espresso, northern,
        slateGlass, onyxGold, midnightHarbor, signal, staticNoise,
    ]
}

private extension ThemeCatalog {

    // Refined near-black with a cool blue edge. The dark default.
    static let obsidian = Theme(
        id: "dark.obsidian",
        name: "Obsidian",
        tagline: "Volcanic glass, midnight blue edge.",
        mode: .dark,
        pairedID: "light.porcelain",
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.05, green: 0.05, blue: 0.07)),
            surface: Color(red: 0.11, green: 0.11, blue: 0.14),
            surfaceElevated: Color(red: 0.16, green: 0.16, blue: 0.20),
            surfaceBorder: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.08),
            textPrimary: Color(red: 0.95, green: 0.95, blue: 0.97),
            textSecondary: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.65),
            textTertiary: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.40),
            accent: Color(red: 0.45, green: 0.62, blue: 1.0),
            accentSecondary: Color(red: 0.66, green: 0.50, blue: 1.0),
            onAccent: Color(red: 0.03, green: 0.04, blue: 0.09),
            positive: Color(red: 0.35, green: 0.85, blue: 0.55),
            negative: Color(red: 1.0, green: 0.45, blue: 0.45),
            warning: Color(red: 1.0, green: 0.72, blue: 0.30),
            fill: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.07),
            separator: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.08),
            chart: [
                Color(red: 0.45, green: 0.62, blue: 1.0),
                Color(red: 0.66, green: 0.50, blue: 1.0),
                Color(red: 0.35, green: 0.85, blue: 0.55),
                Color(red: 1.0, green: 0.72, blue: 0.30),
                Color(red: 1.0, green: 0.45, blue: 0.55),
                Color(red: 0.35, green: 0.80, blue: 0.90),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .rounded, displayWeight: .bold,
            labelCase: .uppercase, labelTracking: 1.2, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 20, controlRadius: 12,
                          cardStyle: .flat, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .glass
        ),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .medium, fill: false),
        chart: ChartStyle(barCornerRadius: 5, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.35),
                            snappy: .snappy(duration: 0.22),
                            emphasis: .bouncy(duration: 0.5, extraBounce: 0.06))
    )

    // Green phosphor CRT: mono type, hard corners, scanline grain.
    static let terminal = Theme(
        id: "dark.terminal",
        name: "Terminal",
        tagline: "Green phosphor. Cursor blinking.",
        mode: .dark,
        pairedID: "light.newsprint",
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.02, green: 0.04, blue: 0.02)),
            surface: Color(red: 0.04, green: 0.07, blue: 0.04),
            surfaceElevated: Color(red: 0.08, green: 0.13, blue: 0.08),
            surfaceBorder: Color(red: 0.20, green: 0.85, blue: 0.35).opacity(0.35),
            textPrimary: Color(red: 0.60, green: 1.0, blue: 0.65),
            textSecondary: Color(red: 0.40, green: 0.75, blue: 0.45),
            textTertiary: Color(red: 0.30, green: 0.55, blue: 0.35),
            accent: Color(red: 0.25, green: 0.95, blue: 0.45),
            accentSecondary: Color(red: 0.95, green: 0.75, blue: 0.25),
            onAccent: Color(red: 0.01, green: 0.05, blue: 0.02),
            positive: Color(red: 0.25, green: 0.95, blue: 0.45),
            negative: Color(red: 1.0, green: 0.35, blue: 0.30),
            warning: Color(red: 0.95, green: 0.75, blue: 0.25),
            fill: Color(red: 0.25, green: 0.90, blue: 0.40).opacity(0.08),
            separator: Color(red: 0.25, green: 0.90, blue: 0.40).opacity(0.20),
            chart: [
                Color(red: 0.25, green: 0.95, blue: 0.45),
                Color(red: 0.95, green: 0.75, blue: 0.25),
                Color(red: 0.30, green: 0.85, blue: 0.90),
                Color(red: 0.80, green: 1.0, blue: 0.80),
                Color(red: 1.0, green: 0.45, blue: 0.30),
                Color(red: 0.10, green: 0.60, blue: 0.35),
            ]
        ),
        typography: ThemeTypography(
            design: .monospaced, displayDesign: .monospaced, displayWeight: .semibold,
            labelCase: .uppercase, labelTracking: 1.5, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 4, controlRadius: 4,
                          cardStyle: .outlined, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: true, noiseOpacity: 0.06, chrome: .opaque
        ),
        layout: ThemeLayout(spacing: 8, cardPadding: 12, cardSpacing: 8),
        icons: IconStyle(weight: .regular, fill: false),
        chart: ChartStyle(barCornerRadius: 0, smoothLines: false, filledAreas: false, gridLines: true),
        motion: ThemeMotion(spring: .snappy(duration: 0.18),
                            snappy: .snappy(duration: 0.12),
                            emphasis: .snappy(duration: 0.25))
    )

    // Sheets of color drifting behind frosted glass.
    static let aurora = Theme(
        id: "dark.aurora",
        name: "Aurora",
        tagline: "Sheets of light behind frosted glass.",
        mode: .dark,
        pairedID: "light.daybreak",
        palette: ThemePalette(
            backdrop: .mesh([
                Color(red: 0.04, green: 0.05, blue: 0.12),
                Color(red: 0.10, green: 0.04, blue: 0.18),
                Color(red: 0.02, green: 0.10, blue: 0.14),
                Color(red: 0.08, green: 0.03, blue: 0.10),
                Color(red: 0.03, green: 0.08, blue: 0.16),
            ]),
            surface: Color(red: 0.10, green: 0.10, blue: 0.18),
            surfaceElevated: Color(red: 0.15, green: 0.15, blue: 0.25),
            surfaceBorder: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.14),
            textPrimary: Color(red: 0.94, green: 0.94, blue: 0.99),
            textSecondary: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.65),
            textTertiary: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.40),
            accent: Color(red: 0.62, green: 0.60, blue: 1.0),
            accentSecondary: Color(red: 0.40, green: 0.90, blue: 0.85),
            onAccent: Color(red: 0.04, green: 0.05, blue: 0.12),
            positive: Color(red: 0.40, green: 0.92, blue: 0.65),
            negative: Color(red: 1.0, green: 0.45, blue: 0.55),
            warning: Color(red: 1.0, green: 0.75, blue: 0.35),
            fill: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.09),
            separator: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.10),
            chart: [
                Color(red: 0.62, green: 0.60, blue: 1.0),
                Color(red: 0.40, green: 0.90, blue: 0.85),
                Color(red: 0.45, green: 0.90, blue: 0.60),
                Color(red: 1.0, green: 0.55, blue: 0.80),
                Color(red: 1.0, green: 0.75, blue: 0.35),
                Color(red: 0.45, green: 0.70, blue: 1.0),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .rounded, displayWeight: .bold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 24, controlRadius: 14,
                          cardStyle: .glass, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.35),
                               radius: 20, x: 0, y: 10),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: true, noiseOpacity: 0, chrome: .glass
        ),
        layout: ThemeLayout(spacing: 14, cardPadding: 18, cardSpacing: 14),
        icons: IconStyle(weight: .medium, fill: false),
        chart: ChartStyle(barCornerRadius: 6, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.45),
                            snappy: .snappy(duration: 0.24),
                            emphasis: .bouncy(duration: 0.55, extraBounce: 0.1))
    )

    // Synthwave: magenta on deep purple, glowing gradient borders.
    static let neonLedger = Theme(
        id: "dark.neon",
        name: "Neon Ledger",
        tagline: "Synthwave balance sheet after midnight.",
        mode: .dark,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .verticalGradient([
                Color(red: 0.10, green: 0.02, blue: 0.18),
                Color(red: 0.02, green: 0.02, blue: 0.10),
            ]),
            surface: Color(red: 0.13, green: 0.06, blue: 0.22),
            surfaceElevated: Color(red: 0.19, green: 0.10, blue: 0.30),
            surfaceBorder: Color(red: 0.95, green: 0.30, blue: 0.80).opacity(0.35),
            textPrimary: Color(red: 0.97, green: 0.94, blue: 1.0),
            textSecondary: Color(red: 0.97, green: 0.94, blue: 1.0).opacity(0.68),
            textTertiary: Color(red: 0.97, green: 0.94, blue: 1.0).opacity(0.42),
            accent: Color(red: 1.0, green: 0.35, blue: 0.75),
            accentSecondary: Color(red: 0.25, green: 0.90, blue: 0.95),
            onAccent: Color(red: 0.08, green: 0.02, blue: 0.12),
            positive: Color(red: 0.30, green: 0.95, blue: 0.75),
            negative: Color(red: 1.0, green: 0.40, blue: 0.50),
            warning: Color(red: 1.0, green: 0.80, blue: 0.30),
            fill: Color(red: 1.0, green: 0.40, blue: 0.80).opacity(0.10),
            separator: Color(red: 0.80, green: 0.40, blue: 0.90).opacity(0.18),
            chart: [
                Color(red: 1.0, green: 0.35, blue: 0.75),
                Color(red: 0.25, green: 0.90, blue: 0.95),
                Color(red: 0.70, green: 0.50, blue: 1.0),
                Color(red: 1.0, green: 0.60, blue: 0.30),
                Color(red: 0.40, green: 0.95, blue: 0.60),
                Color(red: 0.40, green: 0.60, blue: 1.0),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .default, displayWeight: .heavy,
            labelCase: .uppercase, labelTracking: 1.4, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 16, controlRadius: 10,
                          cardStyle: .gradientOutline, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.45),
                               radius: 16, x: 0, y: 8),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: true, noiseOpacity: 0, chrome: .floating
        ),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .semibold, fill: true),
        chart: ChartStyle(barCornerRadius: 2, smoothLines: false, filledAreas: true, gridLines: true),
        motion: ThemeMotion(spring: .snappy(duration: 0.22),
                            snappy: .snappy(duration: 0.14),
                            emphasis: .bouncy(duration: 0.4, extraBounce: 0.1))
    )

    // Serif editorial by lamplight: ivory, champagne, unhurried.
    static let nocturne = Theme(
        id: "dark.nocturne",
        name: "Nocturne",
        tagline: "Serif numerals by lamplight.",
        mode: .dark,
        pairedID: "light.paper",
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.07, green: 0.07, blue: 0.10)),
            surface: Color(red: 0.11, green: 0.11, blue: 0.15),
            surfaceElevated: Color(red: 0.16, green: 0.16, blue: 0.21),
            surfaceBorder: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.08),
            textPrimary: Color(red: 0.93, green: 0.91, blue: 0.86),
            textSecondary: Color(red: 0.93, green: 0.91, blue: 0.86).opacity(0.65),
            textTertiary: Color(red: 0.93, green: 0.91, blue: 0.86).opacity(0.40),
            accent: Color(red: 0.85, green: 0.72, blue: 0.45),
            accentSecondary: Color(red: 0.60, green: 0.55, blue: 0.80),
            onAccent: Color(red: 0.10, green: 0.08, blue: 0.04),
            positive: Color(red: 0.55, green: 0.80, blue: 0.55),
            negative: Color(red: 0.90, green: 0.50, blue: 0.45),
            warning: Color(red: 0.90, green: 0.70, blue: 0.35),
            fill: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.06),
            separator: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.08),
            chart: [
                Color(red: 0.85, green: 0.72, blue: 0.45),
                Color(red: 0.62, green: 0.55, blue: 0.85),
                Color(red: 0.55, green: 0.75, blue: 0.55),
                Color(red: 0.85, green: 0.50, blue: 0.50),
                Color(red: 0.50, green: 0.65, blue: 0.80),
                Color(red: 0.75, green: 0.55, blue: 0.35),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .serif, displayWeight: .semibold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 12, controlRadius: 8,
                          cardStyle: .flat, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .opaque
        ),
        layout: ThemeLayout(spacing: 14, cardPadding: 18, cardSpacing: 14),
        icons: IconStyle(weight: .light, fill: false),
        chart: ChartStyle(barCornerRadius: 2, smoothLines: true, filledAreas: false, gridLines: true),
        motion: ThemeMotion(spring: .smooth(duration: 0.45),
                            snappy: .snappy(duration: 0.25),
                            emphasis: .smooth(duration: 0.65))
    )

    // Monochrome, monospace, nothing extra.
    static let ink = Theme(
        id: "dark.ink",
        name: "Ink",
        tagline: "Monochrome, monospace, no noise.",
        mode: .dark,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.03, green: 0.03, blue: 0.03)),
            surface: Color(red: 0.08, green: 0.08, blue: 0.08),
            surfaceElevated: Color(red: 0.14, green: 0.14, blue: 0.14),
            surfaceBorder: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.12),
            textPrimary: Color(red: 0.96, green: 0.96, blue: 0.96),
            textSecondary: Color(red: 0.96, green: 0.96, blue: 0.96).opacity(0.65),
            textTertiary: Color(red: 0.96, green: 0.96, blue: 0.96).opacity(0.40),
            accent: Color(red: 0.96, green: 0.96, blue: 0.96),
            accentSecondary: Color(red: 0.60, green: 0.60, blue: 0.60),
            onAccent: Color(red: 0.05, green: 0.05, blue: 0.05),
            positive: Color(red: 0.60, green: 0.85, blue: 0.65),
            negative: Color(red: 0.95, green: 0.55, blue: 0.50),
            warning: Color(red: 0.90, green: 0.75, blue: 0.45),
            fill: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.07),
            separator: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.12),
            chart: [
                Color(red: 0.95, green: 0.95, blue: 0.95),
                Color(red: 0.70, green: 0.75, blue: 0.80),
                Color(red: 0.80, green: 0.72, blue: 0.60),
                Color(red: 0.55, green: 0.60, blue: 0.55),
                Color(red: 0.65, green: 0.55, blue: 0.65),
                Color(red: 0.45, green: 0.50, blue: 0.58),
            ]
        ),
        typography: ThemeTypography(
            design: .monospaced, displayDesign: .monospaced, displayWeight: .medium,
            labelCase: .uppercase, labelTracking: 1.2, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 8, controlRadius: 6,
                          cardStyle: .flat, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .opaque
        ),
        layout: ThemeLayout(spacing: 10, cardPadding: 14, cardSpacing: 10),
        icons: IconStyle(weight: .regular, fill: false),
        chart: ChartStyle(barCornerRadius: 0, smoothLines: false, filledAreas: false, gridLines: true),
        motion: ThemeMotion(spring: .snappy(duration: 0.2),
                            snappy: .snappy(duration: 0.12),
                            emphasis: .snappy(duration: 0.28))
    )

    // Coals in the grate: deep maroon, orange glow.
    static let ember = Theme(
        id: "dark.ember",
        name: "Ember",
        tagline: "Coals still glowing in the grate.",
        mode: .dark,
        pairedID: "light.coral",
        palette: ThemePalette(
            backdrop: .verticalGradient([
                Color(red: 0.10, green: 0.03, blue: 0.02),
                Color(red: 0.04, green: 0.02, blue: 0.03),
            ]),
            surface: Color(red: 0.15, green: 0.07, blue: 0.05),
            surfaceElevated: Color(red: 0.22, green: 0.11, blue: 0.08),
            surfaceBorder: Color(red: 1.0, green: 0.50, blue: 0.30).opacity(0.15),
            textPrimary: Color(red: 0.98, green: 0.93, blue: 0.90),
            textSecondary: Color(red: 0.98, green: 0.93, blue: 0.90).opacity(0.65),
            textTertiary: Color(red: 0.98, green: 0.93, blue: 0.90).opacity(0.40),
            accent: Color(red: 1.0, green: 0.45, blue: 0.25),
            accentSecondary: Color(red: 1.0, green: 0.70, blue: 0.30),
            onAccent: Color(red: 0.12, green: 0.03, blue: 0.01),
            positive: Color(red: 0.50, green: 0.85, blue: 0.50),
            negative: Color(red: 1.0, green: 0.35, blue: 0.45),
            warning: Color(red: 1.0, green: 0.75, blue: 0.30),
            fill: Color(red: 1.0, green: 0.50, blue: 0.30).opacity(0.09),
            separator: Color(red: 1.0, green: 0.60, blue: 0.40).opacity(0.12),
            chart: [
                Color(red: 1.0, green: 0.45, blue: 0.25),
                Color(red: 1.0, green: 0.72, blue: 0.30),
                Color(red: 0.95, green: 0.35, blue: 0.40),
                Color(red: 0.85, green: 0.55, blue: 0.35),
                Color(red: 0.80, green: 0.45, blue: 0.65),
                Color(red: 0.35, green: 0.75, blue: 0.70),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .rounded, displayWeight: .bold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 18, controlRadius: 12,
                          cardStyle: .elevated, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.45),
                               radius: 16, x: 0, y: 8),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: true, noiseOpacity: 0, chrome: .floating
        ),
        layout: ThemeLayout(spacing: 13, cardPadding: 16, cardSpacing: 13),
        icons: IconStyle(weight: .medium, fill: true),
        chart: ChartStyle(barCornerRadius: 6, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.4),
                            snappy: .snappy(duration: 0.22),
                            emphasis: .bouncy(duration: 0.5, extraBounce: 0.1))
    )

    // Bioluminescent cyan drifting in navy depths.
    static let deepSea = Theme(
        id: "dark.deepsea",
        name: "Deep Sea",
        tagline: "Bioluminescence under pressure.",
        mode: .dark,
        pairedID: "light.seafoam",
        palette: ThemePalette(
            backdrop: .aurora(base: Color(red: 0.01, green: 0.05, blue: 0.10), glows: [
                Color(red: 0.0, green: 0.35, blue: 0.45),
                Color(red: 0.05, green: 0.20, blue: 0.50),
                Color(red: 0.0, green: 0.45, blue: 0.40),
            ]),
            surface: Color(red: 0.04, green: 0.10, blue: 0.16),
            surfaceElevated: Color(red: 0.08, green: 0.16, blue: 0.24),
            surfaceBorder: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.12),
            textPrimary: Color(red: 0.90, green: 0.97, blue: 0.98),
            textSecondary: Color(red: 0.90, green: 0.97, blue: 0.98).opacity(0.65),
            textTertiary: Color(red: 0.90, green: 0.97, blue: 0.98).opacity(0.40),
            accent: Color(red: 0.25, green: 0.90, blue: 0.85),
            accentSecondary: Color(red: 0.35, green: 0.65, blue: 1.0),
            onAccent: Color(red: 0.0, green: 0.10, blue: 0.12),
            positive: Color(red: 0.35, green: 0.90, blue: 0.60),
            negative: Color(red: 1.0, green: 0.45, blue: 0.50),
            warning: Color(red: 1.0, green: 0.78, blue: 0.35),
            fill: Color(red: 0.30, green: 0.80, blue: 0.80).opacity(0.08),
            separator: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.10),
            chart: [
                Color(red: 0.25, green: 0.90, blue: 0.85),
                Color(red: 0.40, green: 0.65, blue: 1.0),
                Color(red: 0.35, green: 0.90, blue: 0.60),
                Color(red: 0.65, green: 0.55, blue: 1.0),
                Color(red: 1.0, green: 0.78, blue: 0.35),
                Color(red: 1.0, green: 0.55, blue: 0.75),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .rounded, displayWeight: .bold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 22, controlRadius: 12,
                          cardStyle: .glass, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.40),
                               radius: 18, x: 0, y: 10),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: true, noiseOpacity: 0, chrome: .glass
        ),
        layout: ThemeLayout(spacing: 13, cardPadding: 17, cardSpacing: 13),
        icons: IconStyle(weight: .medium, fill: false),
        chart: ChartStyle(barCornerRadius: 6, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.42),
                            snappy: .snappy(duration: 0.24),
                            emphasis: .bouncy(duration: 0.55, extraBounce: 0.08))
    )

    // Plum dusk with gold thread and serif headings.
    static let velvet = Theme(
        id: "dark.velvet",
        name: "Velvet",
        tagline: "Plum dusk, gold thread, low light.",
        mode: .dark,
        pairedID: "light.lavender",
        palette: ThemePalette(
            backdrop: .verticalGradient([
                Color(red: 0.12, green: 0.05, blue: 0.14),
                Color(red: 0.05, green: 0.03, blue: 0.08),
            ]),
            surface: Color(red: 0.16, green: 0.09, blue: 0.18),
            surfaceElevated: Color(red: 0.23, green: 0.14, blue: 0.26),
            surfaceBorder: Color(red: 0.90, green: 0.75, blue: 0.50).opacity(0.15),
            textPrimary: Color(red: 0.96, green: 0.92, blue: 0.96),
            textSecondary: Color(red: 0.96, green: 0.92, blue: 0.96).opacity(0.65),
            textTertiary: Color(red: 0.96, green: 0.92, blue: 0.96).opacity(0.40),
            accent: Color(red: 0.80, green: 0.55, blue: 0.90),
            accentSecondary: Color(red: 0.95, green: 0.75, blue: 0.50),
            onAccent: Color(red: 0.10, green: 0.04, blue: 0.12),
            positive: Color(red: 0.55, green: 0.85, blue: 0.60),
            negative: Color(red: 1.0, green: 0.45, blue: 0.55),
            warning: Color(red: 0.95, green: 0.75, blue: 0.40),
            fill: Color(red: 0.80, green: 0.60, blue: 0.90).opacity(0.08),
            separator: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.09),
            chart: [
                Color(red: 0.80, green: 0.55, blue: 0.90),
                Color(red: 0.95, green: 0.75, blue: 0.50),
                Color(red: 0.95, green: 0.50, blue: 0.65),
                Color(red: 0.40, green: 0.80, blue: 0.75),
                Color(red: 0.55, green: 0.60, blue: 0.95),
                Color(red: 0.60, green: 0.80, blue: 0.60),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .serif, displayWeight: .semibold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 20, controlRadius: 12,
                          cardStyle: .elevated, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.45),
                               radius: 18, x: 0, y: 10),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .floating
        ),
        layout: ThemeLayout(spacing: 14, cardPadding: 18, cardSpacing: 14),
        icons: IconStyle(weight: .light, fill: false),
        chart: ChartStyle(barCornerRadius: 4, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.45),
                            snappy: .snappy(duration: 0.24),
                            emphasis: .smooth(duration: 0.65))
    )

    // Matte pencil gray. All business, no decoration.
    static let graphite = Theme(
        id: "dark.graphite",
        name: "Graphite",
        tagline: "Matte pencil gray, all business.",
        mode: .dark,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.09, green: 0.09, blue: 0.10)),
            surface: Color(red: 0.13, green: 0.13, blue: 0.15),
            surfaceElevated: Color(red: 0.18, green: 0.18, blue: 0.21),
            surfaceBorder: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.10),
            textPrimary: Color(red: 0.94, green: 0.94, blue: 0.95),
            textSecondary: Color(red: 0.94, green: 0.94, blue: 0.95).opacity(0.65),
            textTertiary: Color(red: 0.94, green: 0.94, blue: 0.95).opacity(0.40),
            accent: Color(red: 0.62, green: 0.72, blue: 0.85),
            accentSecondary: Color(red: 0.55, green: 0.60, blue: 0.68),
            onAccent: Color(red: 0.06, green: 0.07, blue: 0.09),
            positive: Color(red: 0.55, green: 0.82, blue: 0.60),
            negative: Color(red: 0.95, green: 0.50, blue: 0.48),
            warning: Color(red: 0.92, green: 0.72, blue: 0.40),
            fill: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.06),
            separator: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.09),
            chart: [
                Color(red: 0.62, green: 0.72, blue: 0.85),
                Color(red: 0.75, green: 0.70, blue: 0.62),
                Color(red: 0.55, green: 0.78, blue: 0.58),
                Color(red: 0.90, green: 0.70, blue: 0.40),
                Color(red: 0.92, green: 0.52, blue: 0.50),
                Color(red: 0.70, green: 0.62, blue: 0.85),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .default, displayWeight: .semibold,
            labelCase: .uppercase, labelTracking: 1.1, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 12, controlRadius: 8,
                          cardStyle: .outlined, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .opaque
        ),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .medium, fill: false),
        chart: ChartStyle(barCornerRadius: 2, smoothLines: false, filledAreas: false, gridLines: true),
        motion: ThemeMotion(spring: .smooth(duration: 0.32),
                            snappy: .snappy(duration: 0.2),
                            emphasis: .smooth(duration: 0.45))
    )

    // Deep-field nebulas with gradient-ring cards.
    static let cosmos = Theme(
        id: "dark.cosmos",
        name: "Cosmos",
        tagline: "Deep field, nebula edges.",
        mode: .dark,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .mesh([
                Color(red: 0.03, green: 0.02, blue: 0.10),
                Color(red: 0.10, green: 0.02, blue: 0.14),
                Color(red: 0.02, green: 0.05, blue: 0.12),
                Color(red: 0.06, green: 0.02, blue: 0.16),
                Color(red: 0.01, green: 0.03, blue: 0.08),
            ]),
            surface: Color(red: 0.08, green: 0.07, blue: 0.16),
            surfaceElevated: Color(red: 0.13, green: 0.11, blue: 0.24),
            surfaceBorder: Color(red: 0.60, green: 0.50, blue: 1.0).opacity(0.25),
            textPrimary: Color(red: 0.95, green: 0.94, blue: 1.0),
            textSecondary: Color(red: 0.95, green: 0.94, blue: 1.0).opacity(0.65),
            textTertiary: Color(red: 0.95, green: 0.94, blue: 1.0).opacity(0.40),
            accent: Color(red: 0.60, green: 0.52, blue: 1.0),
            accentSecondary: Color(red: 0.95, green: 0.45, blue: 0.85),
            onAccent: Color(red: 0.04, green: 0.03, blue: 0.10),
            positive: Color(red: 0.40, green: 0.90, blue: 0.70),
            negative: Color(red: 1.0, green: 0.45, blue: 0.55),
            warning: Color(red: 1.0, green: 0.75, blue: 0.35),
            fill: Color(red: 0.60, green: 0.55, blue: 1.0).opacity(0.09),
            separator: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.09),
            chart: [
                Color(red: 0.60, green: 0.52, blue: 1.0),
                Color(red: 0.95, green: 0.45, blue: 0.85),
                Color(red: 0.40, green: 0.85, blue: 0.95),
                Color(red: 1.0, green: 0.80, blue: 0.45),
                Color(red: 0.45, green: 0.90, blue: 0.65),
                Color(red: 0.40, green: 0.60, blue: 1.0),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .rounded, displayWeight: .bold,
            labelCase: .uppercase, labelTracking: 1.2, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 24, controlRadius: 14,
                          cardStyle: .gradientOutline, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.40),
                               radius: 18, x: 0, y: 10),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: true, noiseOpacity: 0, chrome: .floating
        ),
        layout: ThemeLayout(spacing: 13, cardPadding: 17, cardSpacing: 13),
        icons: IconStyle(weight: .medium, fill: true),
        chart: ChartStyle(barCornerRadius: 5, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.42),
                            snappy: .snappy(duration: 0.22),
                            emphasis: .bouncy(duration: 0.55, extraBounce: 0.12))
    )

    // Moss and starlight under the canopy.
    static let forestNight = Theme(
        id: "dark.forest",
        name: "Forest Night",
        tagline: "Moss and starlight through the canopy.",
        mode: .dark,
        pairedID: "light.meadow",
        palette: ThemePalette(
            backdrop: .verticalGradient([
                Color(red: 0.03, green: 0.08, blue: 0.05),
                Color(red: 0.02, green: 0.04, blue: 0.03),
            ]),
            surface: Color(red: 0.06, green: 0.12, blue: 0.08),
            surfaceElevated: Color(red: 0.10, green: 0.18, blue: 0.13),
            surfaceBorder: Color(red: 0.50, green: 0.80, blue: 0.50).opacity(0.12),
            textPrimary: Color(red: 0.92, green: 0.97, blue: 0.92),
            textSecondary: Color(red: 0.92, green: 0.97, blue: 0.92).opacity(0.65),
            textTertiary: Color(red: 0.92, green: 0.97, blue: 0.92).opacity(0.40),
            accent: Color(red: 0.45, green: 0.85, blue: 0.45),
            accentSecondary: Color(red: 0.85, green: 0.80, blue: 0.40),
            onAccent: Color(red: 0.02, green: 0.10, blue: 0.04),
            positive: Color(red: 0.50, green: 0.88, blue: 0.55),
            negative: Color(red: 1.0, green: 0.48, blue: 0.42),
            warning: Color(red: 0.95, green: 0.78, blue: 0.35),
            fill: Color(red: 0.50, green: 0.85, blue: 0.50).opacity(0.08),
            separator: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.08),
            chart: [
                Color(red: 0.45, green: 0.85, blue: 0.45),
                Color(red: 0.85, green: 0.80, blue: 0.40),
                Color(red: 0.35, green: 0.75, blue: 0.70),
                Color(red: 0.55, green: 0.70, blue: 0.95),
                Color(red: 0.95, green: 0.50, blue: 0.60),
                Color(red: 0.80, green: 0.62, blue: 0.45),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .rounded, displayWeight: .bold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 16, controlRadius: 10,
                          cardStyle: .flat, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .opaque
        ),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .medium, fill: true),
        chart: ChartStyle(barCornerRadius: 5, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.4),
                            snappy: .snappy(duration: 0.22),
                            emphasis: .bouncy(duration: 0.5, extraBounce: 0.08))
    )

    // Concrete at night: white borders, taxi-yellow accent.
    static let brutalistDark = Theme(
        id: "dark.brutalist",
        name: "Brutalist Dark",
        tagline: "Concrete at night, paint still wet.",
        mode: .dark,
        pairedID: "light.brutalist",
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.08, green: 0.08, blue: 0.08)),
            surface: Color(red: 0.13, green: 0.13, blue: 0.13),
            surfaceElevated: Color(red: 0.20, green: 0.20, blue: 0.20),
            surfaceBorder: Color(red: 0.95, green: 0.95, blue: 0.95),
            textPrimary: Color(red: 0.97, green: 0.97, blue: 0.97),
            textSecondary: Color(red: 0.97, green: 0.97, blue: 0.97).opacity(0.70),
            textTertiary: Color(red: 0.97, green: 0.97, blue: 0.97).opacity(0.45),
            accent: Color(red: 1.0, green: 0.85, blue: 0.0),
            accentSecondary: Color(red: 0.30, green: 0.75, blue: 1.0),
            onAccent: Color(red: 0.05, green: 0.05, blue: 0.05),
            positive: Color(red: 0.30, green: 0.90, blue: 0.40),
            negative: Color(red: 1.0, green: 0.30, blue: 0.30),
            warning: Color(red: 1.0, green: 0.65, blue: 0.10),
            fill: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.08),
            separator: Color(red: 0.95, green: 0.95, blue: 0.95).opacity(0.60),
            chart: [
                Color(red: 1.0, green: 0.85, blue: 0.0),
                Color(red: 0.30, green: 0.75, blue: 1.0),
                Color(red: 1.0, green: 0.35, blue: 0.30),
                Color(red: 0.30, green: 0.90, blue: 0.40),
                Color(red: 1.0, green: 0.40, blue: 0.85),
                Color(red: 0.95, green: 0.95, blue: 0.95),
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

    // Dark roast browns with crema-colored serifs.
    static let espresso = Theme(
        id: "dark.espresso",
        name: "Espresso",
        tagline: "Dark roast, crema-colored serifs.",
        mode: .dark,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.09, green: 0.06, blue: 0.04)),
            surface: Color(red: 0.14, green: 0.10, blue: 0.07),
            surfaceElevated: Color(red: 0.20, green: 0.15, blue: 0.11),
            surfaceBorder: Color(red: 0.90, green: 0.75, blue: 0.55).opacity(0.14),
            textPrimary: Color(red: 0.95, green: 0.89, blue: 0.80),
            textSecondary: Color(red: 0.95, green: 0.89, blue: 0.80).opacity(0.65),
            textTertiary: Color(red: 0.95, green: 0.89, blue: 0.80).opacity(0.40),
            accent: Color(red: 0.85, green: 0.62, blue: 0.40),
            accentSecondary: Color(red: 0.90, green: 0.45, blue: 0.25),
            onAccent: Color(red: 0.12, green: 0.07, blue: 0.03),
            positive: Color(red: 0.55, green: 0.82, blue: 0.50),
            negative: Color(red: 1.0, green: 0.48, blue: 0.42),
            warning: Color(red: 0.95, green: 0.72, blue: 0.35),
            fill: Color(red: 0.90, green: 0.70, blue: 0.50).opacity(0.08),
            separator: Color(red: 0.90, green: 0.75, blue: 0.55).opacity(0.10),
            chart: [
                Color(red: 0.85, green: 0.62, blue: 0.40),
                Color(red: 0.90, green: 0.45, blue: 0.25),
                Color(red: 0.95, green: 0.88, blue: 0.75),
                Color(red: 0.85, green: 0.55, blue: 0.55),
                Color(red: 0.70, green: 0.70, blue: 0.40),
                Color(red: 0.50, green: 0.70, blue: 0.75),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .serif, displayWeight: .semibold,
            labelCase: nil, labelTracking: 0, useMonospacedDigits: false
        ),
        shape: ThemeShape(cornerRadius: 14, controlRadius: 10,
                          cardStyle: .flat, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0.04, chrome: .opaque
        ),
        layout: ThemeLayout(spacing: 13, cardPadding: 17, cardSpacing: 13),
        icons: IconStyle(weight: .regular, fill: false),
        chart: ChartStyle(barCornerRadius: 3, smoothLines: true, filledAreas: false, gridLines: true),
        motion: ThemeMotion(spring: .smooth(duration: 0.45),
                            snappy: .snappy(duration: 0.25),
                            emphasis: .smooth(duration: 0.6))
    )

    // Green fire over a frozen sky, glass below.
    static let northern = Theme(
        id: "dark.northern",
        name: "Northern",
        tagline: "Green fire over a frozen sky.",
        mode: .dark,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .aurora(base: Color(red: 0.02, green: 0.04, blue: 0.09), glows: [
                Color(red: 0.0, green: 0.60, blue: 0.45),
                Color(red: 0.10, green: 0.30, blue: 0.60),
                Color(red: 0.30, green: 0.70, blue: 0.50),
            ]),
            surface: Color(red: 0.05, green: 0.10, blue: 0.14),
            surfaceElevated: Color(red: 0.09, green: 0.16, blue: 0.21),
            surfaceBorder: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.13),
            textPrimary: Color(red: 0.92, green: 0.97, blue: 0.96),
            textSecondary: Color(red: 0.92, green: 0.97, blue: 0.96).opacity(0.65),
            textTertiary: Color(red: 0.92, green: 0.97, blue: 0.96).opacity(0.40),
            accent: Color(red: 0.30, green: 0.95, blue: 0.65),
            accentSecondary: Color(red: 0.45, green: 0.75, blue: 1.0),
            onAccent: Color(red: 0.0, green: 0.10, blue: 0.07),
            positive: Color(red: 0.35, green: 0.92, blue: 0.60),
            negative: Color(red: 1.0, green: 0.45, blue: 0.50),
            warning: Color(red: 1.0, green: 0.78, blue: 0.35),
            fill: Color(red: 0.30, green: 0.90, blue: 0.65).opacity(0.08),
            separator: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.10),
            chart: [
                Color(red: 0.30, green: 0.95, blue: 0.65),
                Color(red: 0.45, green: 0.75, blue: 1.0),
                Color(red: 0.70, green: 0.55, blue: 1.0),
                Color(red: 1.0, green: 0.55, blue: 0.80),
                Color(red: 1.0, green: 0.80, blue: 0.40),
                Color(red: 0.30, green: 0.80, blue: 0.85),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .rounded, displayWeight: .bold,
            labelCase: .uppercase, labelTracking: 1.0, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 20, controlRadius: 12,
                          cardStyle: .glass, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.40),
                               radius: 16, x: 0, y: 8),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: true, noiseOpacity: 0, chrome: .glass
        ),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .medium, fill: false),
        chart: ChartStyle(barCornerRadius: 4, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.4),
                            snappy: .snappy(duration: 0.22),
                            emphasis: .bouncy(duration: 0.5, extraBounce: 0.1))
    )

    // Cool stone and clean glass. No fuss.
    static let slateGlass = Theme(
        id: "dark.slateglass",
        name: "Slate Glass",
        tagline: "Cool stone, clean glass, no fuss.",
        mode: .dark,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .verticalGradient([
                Color(red: 0.13, green: 0.15, blue: 0.19),
                Color(red: 0.07, green: 0.08, blue: 0.11),
            ]),
            surface: Color(red: 0.16, green: 0.18, blue: 0.22),
            surfaceElevated: Color(red: 0.22, green: 0.24, blue: 0.29),
            surfaceBorder: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.12),
            textPrimary: Color(red: 0.94, green: 0.95, blue: 0.97),
            textSecondary: Color(red: 0.94, green: 0.95, blue: 0.97).opacity(0.65),
            textTertiary: Color(red: 0.94, green: 0.95, blue: 0.97).opacity(0.40),
            accent: Color(red: 0.55, green: 0.80, blue: 0.95),
            accentSecondary: Color(red: 0.65, green: 0.70, blue: 0.80),
            onAccent: Color(red: 0.05, green: 0.09, blue: 0.12),
            positive: Color(red: 0.50, green: 0.85, blue: 0.60),
            negative: Color(red: 0.98, green: 0.50, blue: 0.50),
            warning: Color(red: 0.95, green: 0.75, blue: 0.40),
            fill: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.07),
            separator: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.09),
            chart: [
                Color(red: 0.55, green: 0.80, blue: 0.95),
                Color(red: 0.65, green: 0.70, blue: 0.80),
                Color(red: 0.50, green: 0.85, blue: 0.60),
                Color(red: 0.95, green: 0.75, blue: 0.40),
                Color(red: 0.95, green: 0.55, blue: 0.60),
                Color(red: 0.70, green: 0.65, blue: 0.95),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .default, displayWeight: .semibold,
            labelCase: .uppercase, labelTracking: 1.1, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 18, controlRadius: 10,
                          cardStyle: .glass, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.35),
                               radius: 14, x: 0, y: 7),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .glass
        ),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .medium, fill: false),
        chart: ChartStyle(barCornerRadius: 3, smoothLines: true, filledAreas: true, gridLines: true),
        motion: ThemeMotion(spring: .smooth(duration: 0.35),
                            snappy: .snappy(duration: 0.2),
                            emphasis: .smooth(duration: 0.5))
    )

    // Black lacquer with gilt edges and wide-tracked labels.
    static let onyxGold = Theme(
        id: "dark.onyx",
        name: "Onyx & Gold",
        tagline: "Black lacquer, gilt edges.",
        mode: .dark,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.04, green: 0.04, blue: 0.05)),
            surface: Color(red: 0.09, green: 0.09, blue: 0.10),
            surfaceElevated: Color(red: 0.14, green: 0.14, blue: 0.15),
            surfaceBorder: Color(red: 1.0, green: 0.84, blue: 0.45).opacity(0.30),
            textPrimary: Color(red: 0.97, green: 0.95, blue: 0.90),
            textSecondary: Color(red: 0.97, green: 0.95, blue: 0.90).opacity(0.65),
            textTertiary: Color(red: 0.97, green: 0.95, blue: 0.90).opacity(0.40),
            accent: Color(red: 1.0, green: 0.80, blue: 0.35),
            accentSecondary: Color(red: 0.85, green: 0.60, blue: 0.25),
            onAccent: Color(red: 0.10, green: 0.08, blue: 0.02),
            positive: Color(red: 0.55, green: 0.85, blue: 0.55),
            negative: Color(red: 1.0, green: 0.45, blue: 0.45),
            warning: Color(red: 1.0, green: 0.55, blue: 0.25),
            fill: Color(red: 1.0, green: 0.84, blue: 0.50).opacity(0.07),
            separator: Color(red: 1.0, green: 0.84, blue: 0.50).opacity(0.12),
            chart: [
                Color(red: 1.0, green: 0.80, blue: 0.35),
                Color(red: 0.85, green: 0.60, blue: 0.30),
                Color(red: 0.95, green: 0.92, blue: 0.82),
                Color(red: 0.40, green: 0.80, blue: 0.60),
                Color(red: 0.45, green: 0.65, blue: 1.0),
                Color(red: 0.95, green: 0.45, blue: 0.50),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .serif, displayWeight: .semibold,
            labelCase: .uppercase, labelTracking: 1.8, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 16, controlRadius: 8,
                          cardStyle: .gradientOutline, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.50),
                               radius: 18, x: 0, y: 10),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: true, noiseOpacity: 0, chrome: .floating
        ),
        layout: ThemeLayout(spacing: 13, cardPadding: 17, cardSpacing: 13),
        icons: IconStyle(weight: .light, fill: false),
        chart: ChartStyle(barCornerRadius: 2, smoothLines: true, filledAreas: false, gridLines: true),
        motion: ThemeMotion(spring: .smooth(duration: 0.45),
                            snappy: .snappy(duration: 0.24),
                            emphasis: .smooth(duration: 0.65))
    )

    // Mast lights on black water, a thin bright horizon.
    static let midnightHarbor = Theme(
        id: "dark.harbor",
        name: "Midnight Harbor",
        tagline: "Mast lights on black water.",
        mode: .dark,
        pairedID: "light.solstice",
        palette: ThemePalette(
            backdrop: .horizon(top: Color(red: 0.03, green: 0.06, blue: 0.12),
                               bottom: Color(red: 0.01, green: 0.02, blue: 0.05),
                               accentLine: Color(red: 0.40, green: 0.80, blue: 1.0)),
            surface: Color(red: 0.07, green: 0.10, blue: 0.16),
            surfaceElevated: Color(red: 0.11, green: 0.15, blue: 0.23),
            surfaceBorder: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.10),
            textPrimary: Color(red: 0.92, green: 0.95, blue: 0.98),
            textSecondary: Color(red: 0.92, green: 0.95, blue: 0.98).opacity(0.65),
            textTertiary: Color(red: 0.92, green: 0.95, blue: 0.98).opacity(0.40),
            accent: Color(red: 0.40, green: 0.75, blue: 1.0),
            accentSecondary: Color(red: 1.0, green: 0.70, blue: 0.35),
            onAccent: Color(red: 0.02, green: 0.06, blue: 0.10),
            positive: Color(red: 0.45, green: 0.88, blue: 0.60),
            negative: Color(red: 1.0, green: 0.45, blue: 0.48),
            warning: Color(red: 1.0, green: 0.72, blue: 0.35),
            fill: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.07),
            separator: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.09),
            chart: [
                Color(red: 0.40, green: 0.75, blue: 1.0),
                Color(red: 1.0, green: 0.70, blue: 0.35),
                Color(red: 0.45, green: 0.88, blue: 0.60),
                Color(red: 0.35, green: 0.80, blue: 0.85),
                Color(red: 1.0, green: 0.55, blue: 0.65),
                Color(red: 0.65, green: 0.60, blue: 1.0),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .default, displayWeight: .bold,
            labelCase: .uppercase, labelTracking: 1.1, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 14, controlRadius: 10,
                          cardStyle: .elevated, buttonsAreCapsule: true),
        effects: ThemeEffects(
            shadow: ShadowSpec(color: Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.45),
                               radius: 16, x: 0, y: 8),
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0, chrome: .floating
        ),
        layout: ThemeLayout(spacing: 12, cardPadding: 16, cardSpacing: 12),
        icons: IconStyle(weight: .medium, fill: false),
        chart: ChartStyle(barCornerRadius: 3, smoothLines: true, filledAreas: true, gridLines: false),
        motion: ThemeMotion(spring: .smooth(duration: 0.38),
                            snappy: .snappy(duration: 0.22),
                            emphasis: .bouncy(duration: 0.5, extraBounce: 0.06))
    )

    // High-contrast amber instrumentation on black.
    static let signal = Theme(
        id: "dark.signal",
        name: "Signal",
        tagline: "Amber on black. Read at a glance.",
        mode: .dark,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.02, green: 0.02, blue: 0.02)),
            surface: Color(red: 0.07, green: 0.06, blue: 0.03),
            surfaceElevated: Color(red: 0.12, green: 0.10, blue: 0.05),
            surfaceBorder: Color(red: 1.0, green: 0.70, blue: 0.10).opacity(0.35),
            textPrimary: Color(red: 1.0, green: 0.80, blue: 0.30),
            textSecondary: Color(red: 0.85, green: 0.65, blue: 0.25),
            textTertiary: Color(red: 0.60, green: 0.46, blue: 0.18),
            accent: Color(red: 1.0, green: 0.70, blue: 0.10),
            accentSecondary: Color(red: 1.0, green: 0.45, blue: 0.10),
            onAccent: Color(red: 0.08, green: 0.05, blue: 0.0),
            positive: Color(red: 0.40, green: 0.95, blue: 0.40),
            negative: Color(red: 1.0, green: 0.30, blue: 0.25),
            warning: Color(red: 1.0, green: 0.55, blue: 0.10),
            fill: Color(red: 1.0, green: 0.70, blue: 0.10).opacity(0.08),
            separator: Color(red: 1.0, green: 0.70, blue: 0.10).opacity(0.20),
            chart: [
                Color(red: 1.0, green: 0.70, blue: 0.10),
                Color(red: 1.0, green: 0.48, blue: 0.15),
                Color(red: 1.0, green: 0.88, blue: 0.40),
                Color(red: 0.45, green: 0.95, blue: 0.45),
                Color(red: 0.98, green: 0.92, blue: 0.80),
                Color(red: 1.0, green: 0.35, blue: 0.25),
            ]
        ),
        typography: ThemeTypography(
            design: .default, displayDesign: .monospaced, displayWeight: .bold,
            labelCase: .uppercase, labelTracking: 1.6, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 8, controlRadius: 6,
                          cardStyle: .outlined, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: true, noiseOpacity: 0, chrome: .opaque
        ),
        layout: ThemeLayout(spacing: 10, cardPadding: 14, cardSpacing: 10),
        icons: IconStyle(weight: .semibold, fill: false),
        chart: ChartStyle(barCornerRadius: 0, smoothLines: false, filledAreas: false, gridLines: true),
        motion: ThemeMotion(spring: .snappy(duration: 0.18),
                            snappy: .snappy(duration: 0.12),
                            emphasis: .snappy(duration: 0.25))
    )

    // Test-card colors cutting through channel-gray noise.
    static let staticNoise = Theme(
        id: "dark.static",
        name: "Static",
        tagline: "Channel gray. Signal in the noise.",
        mode: .dark,
        pairedID: nil,
        palette: ThemePalette(
            backdrop: .solid(Color(red: 0.06, green: 0.06, blue: 0.06)),
            surface: Color(red: 0.11, green: 0.11, blue: 0.11),
            surfaceElevated: Color(red: 0.17, green: 0.17, blue: 0.17),
            surfaceBorder: Color(red: 0.90, green: 0.90, blue: 0.90),
            textPrimary: Color(red: 0.95, green: 0.95, blue: 0.95),
            textSecondary: Color(red: 0.95, green: 0.95, blue: 0.95).opacity(0.68),
            textTertiary: Color(red: 0.95, green: 0.95, blue: 0.95).opacity(0.42),
            accent: Color(red: 0.20, green: 0.85, blue: 0.95),
            accentSecondary: Color(red: 0.95, green: 0.40, blue: 0.85),
            onAccent: Color(red: 0.02, green: 0.08, blue: 0.09),
            positive: Color(red: 0.35, green: 0.90, blue: 0.40),
            negative: Color(red: 0.95, green: 0.35, blue: 0.30),
            warning: Color(red: 0.95, green: 0.80, blue: 0.30),
            fill: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.08),
            separator: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.25),
            chart: [
                Color(red: 0.95, green: 0.95, blue: 0.95),
                Color(red: 0.95, green: 0.90, blue: 0.30),
                Color(red: 0.30, green: 0.90, blue: 0.95),
                Color(red: 0.35, green: 0.90, blue: 0.40),
                Color(red: 0.95, green: 0.40, blue: 0.85),
                Color(red: 0.95, green: 0.35, blue: 0.30),
            ]
        ),
        typography: ThemeTypography(
            design: .monospaced, displayDesign: .monospaced, displayWeight: .bold,
            labelCase: .uppercase, labelTracking: 1.4, useMonospacedDigits: true
        ),
        shape: ThemeShape(cornerRadius: 4, controlRadius: 4,
                          cardStyle: .brutal, buttonsAreCapsule: false),
        effects: ThemeEffects(
            shadow: nil,
            brutalShadowOffset: CGSize(width: 4, height: 4),
            glowAccents: false, noiseOpacity: 0.08, chrome: .opaque
        ),
        layout: ThemeLayout(spacing: 10, cardPadding: 14, cardSpacing: 10),
        icons: IconStyle(weight: .regular, fill: false),
        chart: ChartStyle(barCornerRadius: 0, smoothLines: false, filledAreas: false, gridLines: true),
        motion: ThemeMotion(spring: .snappy(duration: 0.18),
                            snappy: .snappy(duration: 0.1),
                            emphasis: .snappy(duration: 0.24))
    )
}
