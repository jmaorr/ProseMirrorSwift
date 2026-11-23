#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if os(macOS) || canImport(UIKit)
import PMState

// Chrome strip pills on the text views: the strip's width follows the text column, a click or
// tap on a pill goes to `onChromePillTap` (it never places the caret or opens the card), and
// VoiceOver offers each pill of the card holding the selection as a custom action.

extension ProseTextView {
    /// The text column's width, which strips wrap to.
    var stripLayoutWidth: CGFloat {
        #if os(macOS)
        guard let container = textContainer else { return 0 }
        #else
        let container = textContainer
        #endif
        return max(0, container.size.width - 2 * container.lineFragmentPadding)
    }

    /// Before rendering a whole note: note the column's width (if the view has one yet), so its
    /// strips are laid out at it from the start rather than moving at the first layout.
    func seedStripWidth() {
        let width = stripLayoutWidth
        if width > 0 { renderer.setLayoutWidth(width, storage: nil) }
    }

    /// Tell the renderer the column's width; boxes whose strips wrap differently are restyled.
    /// Not during a composition or a native edit (the text there is AppKit's or UIKit's): the
    /// next layout catches up.
    func syncStripWidth() {
        let width = stripLayoutWidth
        guard width != renderer.layoutWidth, !composing, nativeEdit == nil else { return }
        #if os(macOS)
        guard let storage = textStorage else { return }
        #else
        let storage = textStorage
        #endif
        syncingSelection = true
        let changed = renderer.setLayoutWidth(width, storage: storage)
        syncingSelection = false
        guard changed else { return }
        if renderer.refreshChangedText { syncSelectionToView() }
        #if os(macOS)
        refreshPillHover()
        needsDisplay = true
        #else
        decorations.setNeedsDisplay()
        #endif
    }

    /// The pill at `point` (view coordinates; content coordinates on iOS) that a click or tap
    /// would press: only with a handler, and while pills are enabled.
    func tappablePill(at point: CGPoint) -> ChromePillHit? {
        guard onChromePillTap != nil, renderer.hasStrips, chromePillsEnabled() else { return nil }
        return pill(at: point)
    }

    /// The pill drawn at `point` (view coordinates; content coordinates on iOS), if any.
    public func chromePill(at point: CGPoint) -> ChromePillHit? {
        guard renderer.hasStrips else { return nil }
        return pill(at: point)
    }

    /// The pills drawn in the chrome box of the node at `pos`, in order.
    public func chromePills(at pos: Int) -> [ChromePillHit] {
        #if !os(macOS)
        if let region = renderer.chromes.first(where: { $0.pos == pos }) { ensureLayout(for: region) }
        #endif
        return pills(atChrome: pos)
    }

    /// Press the pill at `point`, as a click or tap does. Returns whether there was one to press.
    @discardableResult
    public func tapChromePill(at point: CGPoint) -> Bool {
        guard let hit = tappablePill(at: point) else { return false }
        onChromePillTap?(hit)
        return true
    }

    /// VoiceOver: the pills of the card holding the selection ("Status: In progress"), each a
    /// custom action that presses it.
    func pillAccessibilityActions() -> [(name: String, hit: ChromePillHit)] {
        guard onChromePillTap != nil, renderer.hasStrips, chromePillsEnabled(), let pos = activeChromePos(state),
              let strip = renderer.chromes.first(where: { $0.pos == pos })?.strip else { return [] }
        let hits = chromePills(at: pos)
        return zip(strip.pills, hits).map { ($0.accessibilityLabel, $1) }
    }

    /// The pills drawn in `area` (view coordinates; content coordinates on iOS) with their
    /// VoiceOver labels, in document order.
    func visiblePills(in area: CGRect) -> [(label: String, hit: ChromePillHit)] {
        guard renderer.hasStrips else { return [] }
        var out: [(String, ChromePillHit)] = []
        for region in chromeCandidates(in: area) {
            guard let strip = region.strip else { continue }
            for (index, frame) in pillFrames(region).enumerated() where frame.intersects(area) {
                out.append((strip.pills[index].accessibilityLabel, ChromePillHit(pos: region.pos, index: index, id: strip.pills[index].id, rect: frame)))
            }
        }
        return out
    }

    /// Press the pill `hit` stood for, as VoiceOver does: the pill at that place now, if it's
    /// still there and pills take presses.
    func pressPill(_ hit: ChromePillHit) -> Bool {
        guard let tap = onChromePillTap, chromePillsEnabled(),
              let current = pills(atChrome: hit.pos).first(where: { $0.index == hit.index && $0.id == hit.id }) else { return false }
        tap(current)
        return true
    }
}

/// VoiceOver elements for the pills on screen, kept by card and pill so an element stays the
/// same object while its pill does.
final class PillAccessibilityCache {
    var elements: [String: AnyObject] = [:]

    func element<E: AnyObject>(for hit: ChromePillHit, make: () -> E) -> E {
        let key = "\(hit.pos)/\(hit.index)/\(hit.id)"
        if let e = elements[key] as? E { return e }
        let e = make()
        elements[key] = e
        return e
    }

    /// Forget elements not in `keep` (their pills scrolled away or changed).
    func prune(keeping hits: [ChromePillHit]) {
        let keys = Set(hits.map { "\($0.pos)/\($0.index)/\($0.id)" })
        elements = elements.filter { keys.contains($0.key) }
    }
}

#if os(macOS)
extension ProseTextView {
    /// The pill under the pointer is now `pill`: redraw the old one and the new one.
    func setHoveredPill(_ pill: ChromePillHit?) {
        guard pill != hoveredPillHit else { return }
        for rect in [hoveredPillHit?.rect, pill?.rect].compactMap({ $0 }) { setNeedsDisplay(rect.insetBy(dx: -2, dy: -2)) }
        hoveredPillHit = pill
    }

    /// After the text moved (an edit, the strip's metadata, a new width) the pill under the
    /// pointer may be another one or none: look again where the pointer is (`point`, view
    /// coordinates, for tests).
    func refreshPillHover(at point: CGPoint? = nil) {
        guard hoveredPillHit != nil || renderer.hasStrips else { return }
        guard let point = point ?? window.map({ convert($0.mouseLocationOutsideOfEventStream, from: nil) }),
              visibleRect.contains(point) else {
            setHoveredPill(nil)
            return
        }
        setHoveredPill(tappablePill(at: point))
    }

    /// The text view's own children, then a button for each pill on screen.
    public override func accessibilityChildren() -> [Any]? {
        let own = super.accessibilityChildren() ?? []
        return own + pillAccessibilityElements()
    }

    /// A button for each pill on screen ("Status: In progress"); pressing one presses the pill.
    public func pillAccessibilityElements() -> [NSAccessibilityElement] {
        let visible = visiblePills(in: visibleRect)
        let tappable = onChromePillTap != nil && chromePillsEnabled()
        let out = visible.map { label, hit -> NSAccessibilityElement in
            let element = pillAccessibility.element(for: hit) { PillAccessibilityElement() }
            element.view = self
            element.hit = hit
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(tappable ? .button : .staticText)
            element.setAccessibilityLabel(label)
            element.setAccessibilityFrameInParentSpace(hit.rect)
            return element
        }
        pillAccessibility.prune(keeping: visible.map(\.hit))
        return out
    }

    public override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let own = super.accessibilityCustomActions() ?? []
        let pills = pillAccessibilityActions().map { action in
            NSAccessibilityCustomAction(name: action.name) { [weak self] in
                guard let self, let tap = onChromePillTap else { return false }
                tap(action.hit)
                return true
            }
        }
        return own + pills
    }
}
/// A pill as a VoiceOver button.
final class PillAccessibilityElement: NSAccessibilityElement {
    weak var view: ProseTextView?
    var hit: ChromePillHit?

    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            guard let view, let hit else { return false }
            return view.pressPill(hit)
        }
    }
}
#else
extension ProseTextView {
    /// A button for each pill on screen ("Status: In progress"), in the decorations view (which
    /// sits under the text in content coordinates); activating one presses the pill.
    public func pillAccessibilityElements() -> [UIAccessibilityElement] {
        let area = CGRect(origin: contentOffset, size: bounds.size)
        // A pill with a menu button is that button for VoiceOver ("pop-up button").
        let visible = visiblePills(in: area).filter { !isOnPillMenu(CGPoint(x: $0.hit.rect.midX, y: $0.hit.rect.midY)) }
        let tappable = onChromePillTap != nil && chromePillsEnabled()
        let out = visible.map { label, hit -> UIAccessibilityElement in
            let element = cardControlState.pillAccessibility.element(for: hit) { PillAccessibilityElement(accessibilityContainer: decorations) }
            element.view = self
            element.hit = hit
            element.accessibilityLabel = label
            element.accessibilityTraits = tappable ? .button : .staticText
            element.accessibilityFrameInContainerSpace = hit.rect.offsetBy(dx: -decorations.frame.minX, dy: -decorations.frame.minY)
            return element
        }
        cardControlState.pillAccessibility.prune(keeping: visible.map(\.hit))
        return out
    }
}

/// A pill as a VoiceOver button.
final class PillAccessibilityElement: UIAccessibilityElement {
    weak var view: ProseTextView?
    var hit: ChromePillHit?

    override func accessibilityActivate() -> Bool {
        MainActor.assumeIsolated {
            guard let view, let hit else { return false }
            return view.pressPill(hit)
        }
    }
}

extension ProseTextView {
    /// Lets the pill tap begin only on a pill, and makes UIKit's own taps (caret placement,
    /// word selection) wait for it there: a pill tap never also moves the caret.
    final class PillTapGate: NSObject, UIGestureRecognizerDelegate {
        weak var view: ProseTextView?
        init(_ view: ProseTextView) { self.view = view }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            MainActor.assumeIsolated {
                guard let view else { return false }
                let point = recognizer.location(in: view)
                return view.tappablePill(at: point) != nil && !view.isOnPillMenu(point)
            }
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            MainActor.assumeIsolated {
                guard let view else { return false }
                let point = touch.location(in: view)
                // A pill with a menu button is the button's.
                return view.tappablePill(at: point) != nil && !view.isOnPillMenu(point)
            }
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view === recognizer.view && other is UITapGestureRecognizer
        }
    }

    @objc func pillTapped(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended else { return }
        tapChromePill(at: tap.location(in: self))
    }
}
#endif
#endif
