import SwiftUI
import UIKit

// MARK: - NidgetApp
//
// App entry point. Owns the AppRouter and injects the four environment objects exactly per
// ARCHITECTURE §16; RootView adds the theme + privacy environment values on top. Bootstrap
// runs once from here so every setup state (including the branded loading screen) renders
// while the budget file opens.

@main
@MainActor
struct NidgetApp: App {
    @State private var router = AppRouter()

    init() {
        // Minimal-chrome polish (LESSONS §1): hide scroll indicators app-wide, once, at launch.
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppStore.shared)
                .environment(ThemeManager.shared)
                .environment(Preferences.shared)
                .environment(router)
                .preferredColorScheme(ThemeManager.shared.preferredColorScheme)
                .task { await AppStore.shared.bootstrap() }
        }
    }
}
