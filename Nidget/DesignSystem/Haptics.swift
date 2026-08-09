import UIKit

// MARK: - Haptics
//
// Pre-prepared feedback generators shared app-wide.
// - `tap`    — standard light impact for button presses and row taps.
// - `tick`   — rigid, low-intensity detent for keypad keys and picker changes.
// - `success`/`warning` — notification feedback for saves, sync completion, and errors.
//
// The generators are created once and re-`prepare()`d after each use so the Taptic Engine
// stays warm during rapid interactions (keypad typing, chip scrubbing).

@MainActor
enum Haptics {
    private static let tapGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let tickGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private static let notifyGenerator = UINotificationFeedbackGenerator()

    /// Standard press feedback (buttons, rows, floating Quick Add).
    static func tap() {
        tapGenerator.impactOccurred()
        tapGenerator.prepare()
    }

    /// Fine detent feedback (keypad keys, chip selection, steppers).
    static func tick() {
        tickGenerator.impactOccurred(intensity: 0.6)
        tickGenerator.prepare()
    }

    /// Positive completion (transaction saved, sync finished, theme applied).
    static func success() {
        notifyGenerator.notificationOccurred(.success)
        notifyGenerator.prepare()
    }

    /// Something needs attention (validation failure, sync error).
    static func warning() {
        notifyGenerator.notificationOccurred(.warning)
        notifyGenerator.prepare()
    }
}
