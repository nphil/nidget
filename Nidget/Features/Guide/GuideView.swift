import SwiftUI

// MARK: - GuideView
//
// The swipeable visual Guide (docs/UX_ROUND2.md §1): eight pages teaching envelope budgeting
// and the app itself, built from the pages in GuidePages.swift. Two presentation modes:
//
// - Cover (default): RootView presents it full-screen after the first successful sync.
//   Shows a Skip button top-right; RootView marks `Preferences.hasSeenGuide` when it presents
//   the cover, so one dismissal is final.
// - Embedded (`init(embedded: true)`): pushed via `Route.guide` from Settings' "How Nidget
//   Works" card, with a normal navigation back button instead of Skip.
//
// The default page-dot indicator fights themed backdrops, so the dots are custom: theme fill
// for idle pages, an accent capsule for the current one. All motion is gated on Reduce Motion.
//
// MAINTENANCE RULE (CLAUDE.md): every feature change updates its Guide page in the same change.

struct GuideView: View {
    private let embedded: Bool

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pageIndex = 0

    private static let pageCount = 8

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                skipBar
            }
            pager
            footer
        }
        .themedScreen()
        .navigationTitle(embedded ? "How Nidget Works" : "")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Pager

    private var pager: some View {
        TabView(selection: $pageIndex) {
            GuideEnvelopePage().tag(0)
            GuideBudgetPage().tag(1)
            GuideQuickAddPage().tag(2)
            GuideAccountsPage().tag(3)
            GuideDashboardPage().tag(4)
            GuideRetirementPage().tag(5)
            GuideHouseholdPage().tag(6)
            GuideIntelligencePage().tag(7)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    // MARK: Skip (cover mode only)

    private var skipBar: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Text("Skip")
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, theme.layout.cardPadding + 4)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Closes the guide")
        }
    }

    // MARK: Footer — dots + final call to action

    private var footer: some View {
        VStack(spacing: theme.layout.spacing) {
            progressDots
            ZStack {
                if pageIndex == Self.pageCount - 1 {
                    NidgetButton("Start budgeting") {
                        dismiss()
                    }
                    .transition(.opacity)
                } else {
                    Text("Swipe to keep going")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                        .transition(.opacity)
                }
            }
            .frame(height: 50)
            .animation(reduceMotion ? nil : theme.motion.spring, value: pageIndex)
        }
        .padding(.horizontal, theme.layout.cardPadding + 4)
        .padding(.top, theme.layout.spacing)
        .padding(.bottom, theme.layout.spacing)
    }

    /// Custom themed page dots: the default indicator's white/grey dots wash out on light
    /// backdrops and clash with dark ones, so these use the palette directly.
    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<Self.pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == pageIndex ? theme.palette.accent : theme.palette.fill)
                    .frame(width: index == pageIndex ? 22 : 8, height: 8)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.snappy, value: pageIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(pageIndex + 1) of \(Self.pageCount)")
    }
}

// MARK: - Guide spotlight
//
// The accent ring + glow drawn around whichever control a page is teaching. The ring lives in
// an overlay with negative padding so it sits just outside the control without disturbing the
// control's own layout (fixed-width columns in the pages depend on that).

private struct GuideSpotlightModifier: ViewModifier {
    var cornerRadius: CGFloat
    var inset: CGFloat

    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(theme.palette.accent, lineWidth: 2)
                .shadow(color: theme.palette.accent.opacity(0.55), radius: 8)
                .padding(-inset)
        }
    }
}

extension View {
    /// Highlights the control a Guide page is talking about with an accent ring and soft glow.
    func guideSpotlight(cornerRadius: CGFloat = 16, inset: CGFloat = 5) -> some View {
        modifier(GuideSpotlightModifier(cornerRadius: cornerRadius, inset: inset))
    }
}
