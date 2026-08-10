import SwiftUI

// MARK: - ThemeGalleryView
//
// Pushed via `Route.themeGallery` (ARCHITECTURE §14/§16) — no NavigationStack of its own. THE
// showcase screen: a Light/Dark `ChipPicker` (defaulting to whichever mode is currently active,
// per ARCHITECTURE §14) over a 2-column grid of `ThemePreviewCard`, one per catalog theme in the
// selected mode. Every card renders its OWN theme end-to-end (colors, type, card construction,
// backdrop) via `ThemePreviewCard`'s local `.environment(\.theme, theme)` injection, so browsing
// this screen — itself rendered in the ambient app theme via `.themedScreen()` — is the one place
// in the app where 20 completely different visual personalities sit side by side. Selecting a
// card writes straight into `ThemeManager`; since `ThemeManager` is `@Observable` and shared via
// the environment, the change is visible everywhere (including this screen's own chrome) the
// moment the user backs out.

struct ThemeGalleryView: View {
    @Environment(\.theme) private var theme

    @State private var mode: ThemeMode

    init() {
        // Defaults to whichever mode is actively rendering right now (ARCHITECTURE §14). Read
        // directly from the shared singleton since `@Environment` isn't populated yet in `init`.
        _mode = State(initialValue: ThemeManager.shared.active.mode)
    }

    var body: some View {
        content
            .themedScreen()
            .navigationTitle("Theme Gallery")
            .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Screen

    private var content: some View {
        VStack(spacing: theme.layout.spacing) {
            modePicker
            grid
        }
        .padding(.horizontal, theme.layout.cardPadding)
        .padding(.top, theme.layout.spacing * 0.5)
    }

    private var modePicker: some View {
        ChipPicker(items: [ThemeMode.light, ThemeMode.dark], selection: $mode,
                  label: { $0 == .light ? "Light" : "Dark" })
    }

    private var themesForMode: [Theme] {
        mode == .light ? ThemeCatalog.light : ThemeCatalog.dark
    }

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: theme.layout.cardSpacing),
         GridItem(.flexible(), spacing: theme.layout.cardSpacing)]
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: theme.layout.cardSpacing) {
                ForEach(themesForMode) { candidate in
                    ThemePreviewCard(theme: candidate)
                }
            }
            .padding(.vertical, theme.layout.spacing * 0.5)
        }
        .scrollIndicators(.hidden)
    }
}
