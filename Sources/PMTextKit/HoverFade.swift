#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if os(macOS) || canImport(UIKit)

/// Hover looks fade in and out instead of switching (design rules: Motion, `quick`). One
/// key is hovered at a time; the one before fades out while the new one fades in.
final class HoverFade {
    private(set) var levels: [Int: CGFloat] = [:]
    private(set) var target: Int?
    var duration: CFTimeInterval = 0.15
    var animates = true

    func level(_ key: Int?) -> CGFloat {
        guard let key, let t = levels[key] else { return 0 }
        return t * t * (3 - 2 * t)
    }

    var settled: Bool {
        levels.allSatisfy { key, value in key == target ? value == 1 : false }
    }

    func set(_ key: Int?) {
        target = key
        if let key, levels[key] == nil { levels[key] = 0 }
        if !animates || prefersReducedMotion() {
            levels = key.map { [$0: 1] } ?? [:]
        }
    }

    func step(_ dt: CFTimeInterval) {
        let delta = CGFloat(dt / duration)
        for (key, value) in levels {
            levels[key] = key == target ? min(1, value + delta) : max(0, value - delta)
        }
        levels = levels.filter { $0.value > 0 || $0.key == target }
    }
}

#if os(macOS)
extension ProseTextView {
    /// Advance the hover fades by `dt`; returns whether they're still moving.
    func stepHoverFades(_ dt: CFTimeInterval) -> Bool {
        chromeHover.step(dt)
        markerHover.step(dt)
        needsDisplay = true
        return !(chromeHover.settled && markerHover.settled)
    }
}
#endif
#endif
