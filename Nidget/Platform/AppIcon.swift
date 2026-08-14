import UIKit

// MARK: - AppIcon
//
// The home screen icon, and optionally keeping it in step with the chosen theme.
//
// The asset catalog carries the primary `AppIcon` (which holds its own light, dark and tinted
// appearances, so iOS handles those without any help from here) plus one alternate icon per theme
// in ThemeCatalog. All of them are drawn by `scripts/render-app-icons.pl`, which derives each
// theme's icon from that theme's own palette — so a new theme gets an icon by re-running the
// script, not by writing code here.
//
// Names must match what the script writes: a theme id with its dot swapped for a dash, behind a
// `ThemeIcon-` prefix. `assetName(for:)` is the single place that rule lives.
//
// One thing to know about iOS: a *successful* icon change puts up a system alert telling the owner
// the icon changed, and there is no way to opt out of it. So `apply` never makes a call it doesn't
// have to — if the wanted icon is already the one showing, it returns without touching UIKit. That
// is what keeps the alert tied to an actual change instead of to every launch and every trip
// through the theme gallery.

@MainActor
enum AppIcon {

    /// Asset-catalog name of the alternate icon drawn for a theme id.
    static func assetName(for themeID: String) -> String {
        "ThemeIcon-" + themeID.replacingOccurrences(of: ".", with: "-")
    }

    /// Whether the device will let the icon change at all.
    static var isSupported: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    /// The alternate icon currently showing; nil means the primary icon.
    static var currentAssetName: String? {
        UIApplication.shared.alternateIconName
    }

    /// Points the home screen at `themeID`'s icon, or back at the primary icon when `themeID` is
    /// nil. A no-op when the right icon is already showing, or when the device doesn't support
    /// alternate icons at all.
    ///
    /// Failures are swallowed on purpose: the icon is decoration, and there is nothing useful to
    /// say to someone who just picked a theme if iOS declines to swap the artwork.
    static func apply(themeID: String?) {
        guard isSupported else { return }
        let wanted = themeID.map(assetName(for:))
        guard wanted != currentAssetName else { return }
        UIApplication.shared.setAlternateIconName(wanted, completionHandler: nil)
    }
}
