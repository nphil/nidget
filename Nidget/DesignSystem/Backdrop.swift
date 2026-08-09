import SwiftUI
import UIKit

// MARK: - Backdrop
//
// Renders a `BackdropStyle` (Theme.swift) as the full-bleed background of a screen.
// Used exclusively by `.themedScreen()` (ThemeManager.swift), which layers the optional
// noise texture on top and applies `ignoresSafeArea()`.

struct Backdrop: View {
    let style: BackdropStyle

    init(style: BackdropStyle) {
        self.style = style
    }

    var body: some View {
        switch style {
        case .solid(let color):
            color
        case .verticalGradient(let colors):
            LinearGradient(colors: colors.isEmpty ? [Color.gray] : colors,
                           startPoint: .top, endPoint: .bottom)
        case .mesh(let colors):
            MeshBackdrop(colors: colors)
        case .aurora(let base, let glows):
            AuroraBackdrop(base: base, glows: glows)
        case .horizon(let top, let bottom, let accentLine):
            HorizonBackdrop(top: top, bottom: bottom, accentLine: accentLine)
        }
    }
}

// MARK: - Mesh

/// Soft 3x3 mesh gradient. The supplied colors are cycled across the 9 control points.
/// Two non-corner control points drift very subtly over time (periods near a minute) so the
/// backdrop feels alive without ever drawing attention; motion is disabled entirely under
/// Reduce Motion.
private struct MeshBackdrop: View {
    let colors: [Color]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = colors.isEmpty ? [Color.gray] : colors
        let meshColors = (0..<9).map { palette[$0 % palette.count] }
        if reduceMotion {
            Rectangle()
                .fill(MeshGradient(width: 3, height: 3,
                                   points: Self.points(at: 0),
                                   colors: meshColors))
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: false)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Rectangle()
                    .fill(MeshGradient(width: 3, height: 3,
                                       points: Self.points(at: t),
                                       colors: meshColors))
            }
        }
    }

    /// 3x3 control grid. Corners and most edge points are pinned; the center point drifts in
    /// both axes and the right-edge midpoint drifts along its edge (staying on x = 1 so the
    /// mesh always covers the full rect).
    private static func points(at time: TimeInterval) -> [SIMD2<Float>] {
        let dx = Float(sin(time * 0.11) * 0.045)
        let dy = Float(cos(time * 0.08) * 0.045)
        let edgeDY = Float(sin(time * 0.06 + 1.3) * 0.04)
        return [
            SIMD2<Float>(0.0, 0.0), SIMD2<Float>(0.5, 0.0), SIMD2<Float>(1.0, 0.0),
            SIMD2<Float>(0.0, 0.5), SIMD2<Float>(0.5 + dx, 0.5 + dy), SIMD2<Float>(1.0, 0.5 + edgeDY),
            SIMD2<Float>(0.0, 1.0), SIMD2<Float>(0.5, 1.0), SIMD2<Float>(1.0, 1.0),
        ]
    }
}

// MARK: - Aurora

/// Base color with up to three large, heavily blurred glow blobs floating near the upper
/// corners and mid-screen.
private struct AuroraBackdrop: View {
    let base: Color
    let glows: [Color]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                base
                if glows.count > 0 {
                    Circle()
                        .fill(glows[0])
                        .frame(width: size.width * 0.9, height: size.width * 0.9)
                        .blur(radius: 100)
                        .opacity(0.5)
                        .position(x: size.width * 0.12, y: size.height * 0.10)
                }
                if glows.count > 1 {
                    Circle()
                        .fill(glows[1])
                        .frame(width: size.width * 0.85, height: size.width * 0.85)
                        .blur(radius: 110)
                        .opacity(0.5)
                        .position(x: size.width * 0.92, y: size.height * 0.18)
                }
                if glows.count > 2 {
                    Circle()
                        .fill(glows[2])
                        .frame(width: size.width * 0.8, height: size.width * 0.8)
                        .blur(radius: 120)
                        .opacity(0.45)
                        .position(x: size.width * 0.5, y: size.height * 0.55)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }
}

// MARK: - Horizon

/// Two stacked color fields split at 38% height, with an optional thin glowing line on the seam.
private struct HorizonBackdrop: View {
    let top: Color
    let bottom: Color
    let accentLine: Color?

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    top.frame(height: height * 0.38)
                    bottom
                }
                if let accentLine {
                    Rectangle()
                        .fill(accentLine)
                        .frame(height: 2)
                        .shadow(color: accentLine.opacity(0.9), radius: 4)
                        .shadow(color: accentLine.opacity(0.5), radius: 12)
                        .offset(y: height * 0.38 - 1)
                }
            }
        }
    }
}

// MARK: - NoiseTexture
//
// A tiny tileable film-grain texture, generated once and cached. `.themedScreen()` overlays it
// at `theme.effects.noiseOpacity` for themes that want a tactile, printed feel.

enum NoiseTexture {
    /// 160x160 image of ~1500 deterministic pseudo-random 1pt dots (half white, half black,
    /// each at 50% alpha). Seeded so the grain is identical across launches.
    private static let image: UIImage = {
        let side: CGFloat = 160
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        srand48(7)
        return renderer.image { context in
            let cg = context.cgContext
            for _ in 0..<1500 {
                let x = CGFloat(drand48()) * side
                let y = CGFloat(drand48()) * side
                let isWhite = drand48() < 0.5
                let dot = UIColor(white: isWhite ? 1.0 : 0.0, alpha: 0.5)
                cg.setFillColor(dot.cgColor)
                cg.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }()

    /// The cached grain, tiled to fill whatever space it is placed in.
    static var tiled: some View {
        Image(uiImage: image)
            .resizable(resizingMode: .tile)
    }
}
