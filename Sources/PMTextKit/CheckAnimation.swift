#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if os(macOS) || canImport(UIKit)
import PMModel

/// How far through its tick a checkbox is: the strike-through's reach and the box's scale.
public struct CheckAnimationState: Equatable {
    public var strike: CGFloat
    public var scale: CGFloat
}

/// Ticks in flight, keyed by the paragraph's string offset. View state only.
final class CheckAnimations {
    /// The box's spring; the strike-through sweeps in over `strikeDuration`.
    static let duration: CFTimeInterval = 0.45
    static let strikeDuration: CFTimeInterval = 0.25
    var entries: [Int: (elapsed: CFTimeInterval, checking: Bool)] = [:]
    var timer: Timer?
    var last: CFTimeInterval = 0
    /// The rendered document whose checkbox flips were last started: the renderer keeps
    /// `toggledChecks` until its next re-render, so a selection-only update would see them again.
    private weak var startedDoc: Node?

    /// Whether `doc`'s flips are new, marking them seen: true once per rendered document.
    func takeFlips(of doc: Node?) -> Bool {
        guard let doc, doc !== startedDoc else { return false }
        startedDoc = doc
        return true
    }

    /// The tick animation for the paragraph at `offset`, while one is running.
    func state(atString offset: Int) -> CheckAnimationState? {
        guard let e = entries[offset] else { return nil }
        let t = min(1, CGFloat(e.elapsed / Self.duration))
        let st = min(1, CGFloat(e.elapsed / Self.strikeDuration))
        let eased = 1 - pow(1 - st, 3)
        return CheckAnimationState(strike: e.checking ? eased : 1 - eased, scale: Self.spring(t, checking: e.checking))
    }

    /// A damped spring on the box's scale: ticking pops it in from small and past full size;
    /// unticking gives it a small dip. Exactly 1 at both ends of the bounce's settle.
    static func spring(_ t: CGFloat, checking: Bool) -> CGFloat {
        guard t < 1 else { return 1 }
        let amplitude: CGFloat = checking ? 0.4 : 0.12
        return 1 - amplitude * exp(-4 * t) * cos(3 * .pi * t) * (1 - t)
    }

    /// Step every animation by `dt`; returns the offsets of the ones that finished.
    @discardableResult
    func advance(by dt: CFTimeInterval) -> [Int] {
        for key in entries.keys { entries[key]!.elapsed += dt }
        let finished = entries.filter { $0.value.elapsed >= Self.duration }.map(\.key)
        for key in finished { entries[key] = nil }
        return finished
    }
}

#if os(macOS)
extension ProseTextView {
    /// The tick animation for the paragraph at `offset`, while one is running.
    public func checkAnimation(atString offset: Int) -> CheckAnimationState? { checkAnimations.state(atString: offset) }

    /// The box's spring (`CheckAnimations.spring`).
    static func checkSpring(_ t: CGFloat, checking: Bool) -> CGFloat { CheckAnimations.spring(t, checking: checking) }

    /// Step every tick animation (the timer calls this; tests call it directly).
    public func advanceCheckAnimations(by dt: CFTimeInterval) {
        checkAnimations.advance(by: dt)
        if checkAnimations.entries.isEmpty {
            checkAnimations.timer?.invalidate()
            checkAnimations.timer = nil
        }
        needsDisplay = true
    }

    func startCheckAnimations() {
        // Only once per rendered document: a selection change leaves the last flips in place.
        guard checkAnimations.takeFlips(of: renderer.doc), animatesChecks, !renderer.toggledChecks.isEmpty else { return }
        for pos in renderer.toggledChecks {
            let offset = renderer.stringOffset(pos)
            guard offset < (textStorage?.length ?? 0),
                  let d = textStorage?.attribute(.pmBlock, at: offset, effectiveRange: nil) as? BlockDecoration,
                  case .checkbox(let checked, _) = d.marker else { continue }
            checkAnimations.entries[offset] = (0, checked)
        }
        guard checkAnimations.timer == nil, !checkAnimations.entries.isEmpty else { return }
        checkAnimations.last = CACurrentMediaTime()
        checkAnimations.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                let now = CACurrentMediaTime()
                self.advanceCheckAnimations(by: now - self.checkAnimations.last)
                self.checkAnimations.last = now
            }
        }
    }
}
#endif
#endif
