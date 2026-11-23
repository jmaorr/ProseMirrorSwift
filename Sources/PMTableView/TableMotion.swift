#if os(macOS)
import AppKit

/// The table's motion: one curve and duration for moves, shorter fades, and a cross-fade
/// instead of movement when Reduce Motion is on.
public enum TableMotion {
    /// Rows and columns sliding, inserting, collapsing.
    public static let duration: CFTimeInterval = 0.22
    /// Grips and "+" fading in and out.
    public static let handleFade: CFTimeInterval = 0.15
    /// Grips coming in once the pointer rests on a table: slower, so they arrive quietly.
    public static let handleReveal: CFTimeInterval = 0.3
    /// How long the pointer rests on a table before its grips come in; passing over shows nothing.
    nonisolated(unsafe) public static var revealDelay: TimeInterval = 0.35
    /// The cell selection's tint fading.
    public static let selectionFade: CFTimeInterval = 0.12
    public static let curve = CAMediaTimingFunction(name: .easeOut)

    /// Overridable for tests; defaults to the system setting.
    nonisolated(unsafe) public static var reduceMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
#endif
