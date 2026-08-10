import SwiftUI

// MARK: - ThemePreviewCard
//
// One tile in `ThemeGalleryView`'s grid: a miniature mock dashboard rendered fully in the
// PREVIEWED theme — not the ambient ThemeGalleryView theme — plus the theme's name (in its own
// display font) and tagline. `theme` is held as a plain stored value (not `@Environment(\.theme)`)
// so this view's own chrome (card background, corner radius, selection ring) always reflects the
// theme it is showcasing regardless of what theme is active elsewhere; `.environment(\.theme,
// theme)` is applied once, at the end of the body's modifier chain, so every shared DesignSystem
// component nested inside — `.themedCard()`, `Sparkline`, `ProgressRing`, `Backdrop` — resolves
// ITS `@Environment(\.theme)` read to this same theme (environment values propagate to
// descendants regardless of chain order, so this covers the whole subtree including `.themedCard()`
// and both mock widgets even though they're chained before the `.environment()` call).
//
// Performance (ARCHITECTURE §16 / LESSONS_FROM_STASHY §1): the mini canvas is static — the
// backdrop's own animation (the mesh gradient's `TimelineView`) is frozen by locally overriding
// `accessibilityReduceMotion` to `true` for just this subtree, independent of the user's real
// setting — then the whole thing is flattened with `.drawingGroup()` and hit-testing disabled.
// With up to 20 cards on screen at once this keeps the grid cheap to scroll.

struct ThemePreviewCard: View {
    let theme: Theme

    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isPopping = false

    init(theme: Theme) {
        self.theme = theme
    }

    private var isSelected: Bool { themeManager.isSelected(theme) }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: theme.layout.spacing * 0.6) {
                miniature
                    .frame(height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: max(theme.shape.cornerRadius * 0.4, 6),
                                                style: .continuous))
                labelBlock
            }
            .themedCard(padding: 10)
            .overlay {
                theme.cardShape
                    .strokeBorder(isSelected ? theme.palette.accent : Color.clear, lineWidth: 2.5)
            }
            .overlay(alignment: .topTrailing) {
                if theme.pairedID != nil { pairedBadge }
            }
            .environment(\.theme, theme)
        }
        .buttonStyle(.plain)
        .scaleEffect(isPopping ? 1.05 : 1.0)
        .accessibilityLabel(Text("\(theme.name). \(theme.tagline)"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(isSelected ? "Selected theme" : "Double-tap to apply this theme")
    }

    // MARK: Miniature mock dashboard

    private static let fakeSparkline: [Double] = [4, 6, 5, 8, 7, 10, 9, 12, 10, 13]

    private var miniature: some View {
        ZStack {
            Backdrop(style: theme.palette.backdrop, animated: false)
            if theme.effects.noiseOpacity > 0 {
                NoiseTexture.tiled
                    .opacity(theme.effects.noiseOpacity)
            }
            HStack(spacing: 5) {
                sparklineTile
                ringTile
            }
            .padding(6)
        }
        .allowsHitTesting(false)
        .drawingGroup()
    }

    private var sparklineTile: some View {
        Sparkline(values: Self.fakeSparkline, fillGradient: theme.chart.filledAreas)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedCard(padding: 4)
    }

    private var ringTile: some View {
        ProgressRing(progress: 0.68, lineWidth: 4)
            .themedCard(padding: 4)
            .frame(width: 56)
    }

    // MARK: Label

    private var labelBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(theme.name)
                .font(theme.font(.title))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(theme.tagline)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pairedBadge: some View {
        Image(systemName: "link")
            .font(theme.font(.caption))
            .fontWeight(theme.icons.weight)
            .foregroundStyle(theme.palette.onAccent)
            .padding(6)
            .background(Circle().fill(theme.palette.accent))
            .padding(6)
            .accessibilityLabel("Paired with a matching theme")
    }

    // MARK: Selection

    private func select() {
        Haptics.success()
        themeManager.select(theme)
        guard !reduceMotion else { return }
        withAnimation(theme.motion.emphasis) {
            isPopping = true
        }
        withAnimation(theme.motion.spring.delay(0.14)) {
            isPopping = false
        }
    }
}
