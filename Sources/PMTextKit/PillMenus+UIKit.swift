#if canImport(UIKit) && !os(macOS)
import UIKit

// Pills that open a native menu (iOS): a transparent UIButton over each such pill on screen,
// showing its menu as its primary action, as any UIButton menu does. The system places the menu
// above or below the pill; UIKit's text taps never begin there (`gestureRecognizerShouldBegin`
// refuses taps and long presses on pills), so the caret and selection stay. The buttons are
// the text view's subviews, in content coordinates, so they scroll with the text; they're laid
// out again on every layout pass and after every change. A pill without a menu keeps
// `onChromePillTap` (the pill tap).

/// A pill's menu button.
final class PillMenuButton: UIButton {
    weak var host: ProseTextView?
    var hit: ChromePillHit?
}

extension ProseTextView {
    private func key(_ hit: ChromePillHit) -> String { "\(hit.pos)/\(hit.index)/\(hit.id)" }

    /// Place a menu button over each pill on screen that has a menu (`chromePillMenu`), reusing
    /// the ones there; none while pills are off (read-only) or nothing gives menus. While
    /// scrolling, only when the screen leaves the area last covered (half a screen beyond it);
    /// `force` after a change of the text.
    func layoutPillMenus(force: Bool = false) {
        let state = cardControlState
        guard let menu = chromePillMenu, renderer.hasStrips, onChromePillTap != nil, chromePillsEnabled() else {
            for button in state.pillButtons.values { button.removeFromSuperview() }
            state.pillButtons = [:]
            state.pillMenuCover = nil
            return
        }
        let visible = CGRect(origin: contentOffset, size: bounds.size)
        let cover = (doc: renderer.doc.map(ObjectIdentifier.init), width: renderer.layoutWidth, size: bounds.size)
        if !force, let last = state.pillMenuCover, last.doc == cover.doc, last.width == cover.width, last.size == cover.size,
           last.area.contains(visible) {
            for button in state.pillButtons.values where subviews.last !== button { bringSubviewToFront(button) }
            return
        }
        let area = visible.insetBy(dx: 0, dy: -bounds.height * 0.5)
        state.pillMenuCover = (cover.doc, cover.width, cover.size, area)
        // Laid out first: right after a jump, TextKit's positions there are only estimates.
        ensureLayout(around: area)
        var keep: [String: PillMenuButton] = [:]
        for (label, hit) in visiblePills(in: area) {
            let k = key(hit)
            var button = state.pillButtons[k]
            if button == nil {
                // Asked once, when the button is made: whether this pill has a menu at all.
                guard menu(hit) != nil else { continue }
                button = makePillButton()
            }
            guard let button else { continue }
            button.hit = hit
            button.frame = hit.rect
            button.accessibilityLabel = label
            keep[k] = button
        }
        for (k, button) in state.pillButtons where keep[k] == nil { button.removeFromSuperview() }
        state.pillButtons = keep
        // Over TextKit's fragment views, which come and go as the text scrolls.
        for button in keep.values where subviews.last !== button { bringSubviewToFront(button) }
    }

    private func makePillButton() -> PillMenuButton {
        let button = PillMenuButton(type: .custom)
        button.host = self
        button.backgroundColor = .clear
        button.showsMenuAsPrimaryAction = true
        button.accessibilityTraits = .button
        // The menu is made as it opens, so it shows the task as it is then.
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak button] completion in
            MainActor.assumeIsolated {
                guard let button, let view = button.host, let hit = button.hit, view.chromePillsEnabled(),
                      let menu = view.chromePillMenu?(hit) else { completion([]); return }
                completion(menu.children)
            }
        }])
        addSubview(button)
        return button
    }

    /// Whether `point` (content coordinates) is on a pill shown with a menu button.
    func isOnPillMenu(_ point: CGPoint) -> Bool {
        cardControlState.pillButtons.values.contains { $0.superview === self && $0.frame.contains(point) }
    }

    /// The menu buttons on screen, for tests: each pill's hit and its button.
    public var pillMenuButtons: [(hit: ChromePillHit, button: UIButton)] {
        cardControlState.pillButtons.values.compactMap { b in b.hit.map { ($0, b as UIButton) } }
            .sorted { ($0.hit.pos, $0.hit.index) < ($1.hit.pos, $1.hit.index) }
    }

    /// The menu a pill's button shows now, as it would build it on opening (for tests).
    public func pillMenu(for hit: ChromePillHit) -> UIMenu? { chromePillsEnabled() ? chromePillMenu?(hit) : nil }
}
#endif
