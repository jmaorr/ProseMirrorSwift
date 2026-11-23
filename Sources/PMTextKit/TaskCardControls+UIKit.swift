#if canImport(UIKit) && !os(macOS)
import UIKit
import PMModel
import PMState

/// Task card controls on iOS, around the shared chrome: the checkbox's 44 × 44 pt touch target,
/// the long-press card menu, the tick animation and pointer hover (iPad). View state only.
final class CardControlState {
    /// Ticks in flight (the box's spring, the strike-through's sweep).
    let checks = CheckAnimations()
    var animatesChecks = true
    var checkLink: CADisplayLink?
    var lastCheckTick: CFTimeInterval = 0

    /// Pointer hover (iPad): the card under the pointer, and the checkbox.
    let chromeHover = HoverFade()
    let markerHover = HoverFade()
    var hoveredChrome: Int?
    var hoveredMarker: Int?
    var hoverLink: CADisplayLink?
    var lastHoverTick: CFTimeInterval = 0
    /// VoiceOver actions for the selection (`ProseTextView.accessibilityActionsProvider`).
    var accessibilityActions: ((EditorState) -> [EditorAccessibilityAction])?
    /// VoiceOver elements for the pills on screen.
    let pillAccessibility = PillAccessibilityCache()
    /// Menu buttons over the pills on screen that open a menu, by card and pill.
    var pillButtons: [String: PillMenuButton] = [:]
    /// What the buttons were last laid out for: the document, the strip width, the view's
    /// size and the area covered (content coordinates).
    var pillMenuCover: (doc: ObjectIdentifier?, width: CGFloat, size: CGSize, area: CGRect)?
}

/// The smallest touch target (Human Interface Guidelines: 44 × 44 pt).
let minimumTouchTarget: CGFloat = 44

extension ProseTextView {
    // MARK: Checkbox target

    /// The touch target around a marker drawn at `box`: at least 44 × 44 pt, centred on it
    /// vertically, and ending 8 pt to its right so a tap on the text after it places the caret.
    static func markerTarget(around box: CGRect) -> CGRect {
        let right = box.maxX + 8
        let left = min(box.minX - 10, right - minimumTouchTarget)
        let height = max(minimumTouchTarget, box.height + 16)
        return CGRect(x: left, y: box.midY - height / 2, width: right - left, height: height)
    }

    /// The string offset of the paragraph whose clickable marker's touch target is at `point`
    /// (content coordinates). A target can reach into the lines above and below its own; the
    /// nearest marker wins.
    func markerOffset(at point: CGPoint) -> Int? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let p = CGPoint(x: point.x - hostContainerOrigin.x, y: point.y - hostContainerOrigin.y)
        let lineStart = textContainer.lineFragmentPadding
        let reach = minimumTouchTarget / 2 + 8
        // After an edit TextKit may not have laid these lines out again yet.
        tlm.ensureLayout(for: CGRect(x: 0, y: max(0, p.y - reach), width: textContainer.size.width, height: 2 * reach))
        // From the top of what's on screen: right after an edit, TextKit's point lookup can
        // answer with a later paragraph than the one at the point.
        let start = tlm.textViewportLayoutController.viewportRange?.location ?? tlm.documentRange.location
        var best: (fragment: NSTextLayoutFragment, distance: CGFloat)?
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            if fragment.layoutFragmentFrame.minY > p.y + reach { return false }
            guard let block = fragment as? BlockLayoutFragment, let box = block.checkboxRect(lineStart: lineStart),
                  Self.markerTarget(around: box).contains(p) else { return true }
            let distance = abs(p.y - box.midY)
            if best == nil || distance < best!.distance { best = (fragment, distance) }
            return true
        }
        return best.map { tcm.offset(from: tcm.documentRange.location, to: $0.fragment.rangeInElement.location) }
    }

    /// Content-space touch target of the checkbox for the paragraph at string offset `offset`.
    public func checkboxHitRect(atString offset: Int) -> CGRect? {
        checkboxRect(atString: offset).map(Self.markerTarget(around:))
    }

    /// Tap at `point` (content coordinates) as a finger would on a checkbox: toggles the one
    /// whose target is there. Returns whether there was one and it toggled.
    @discardableResult
    public func tapMarker(at point: CGPoint) -> Bool {
        guard onMarkerClick != nil, let offset = markerOffset(at: point) else { return false }
        return tapMarker(atString: offset)
    }

    /// Lay out a chrome region's text, so its box can be measured right after an edit.
    func ensureLayout(for region: ChromeRegion) {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let start = tcm.location(tcm.documentRange.location, offsetBy: region.strStart),
              let end = tcm.location(tcm.documentRange.location, offsetBy: region.strEnd),
              let range = NSTextRange(location: start, end: end) else { return }
        tlm.ensureLayout(for: range)
    }

    // MARK: Action buttons

    /// Frame of the active card's button with this title (its touch target), if shown.
    public func chromeControlFrame(_ title: String) -> CGRect? {
        chromeControls.buttons.first { !$0.isHidden && $0.accessibilityIdentifier == title }?.frame
    }

    /// Run a chrome node's control as a button press does: its own undo step.
    @discardableResult
    func runChromeControl(_ control: ChromeControl, at pos: Int) -> Bool {
        closeHistoryOnNextInput = true
        return run { state, dispatch, view in
            control.action(pos)(state, dispatch.map { dispatch in { tr in dispatch(self.separateUndoStep?(tr) ?? tr) } }, view)
        }
    }

    // MARK: Card menu

    /// The card whose control area is at `point`: its checkbox's target, or the active card's
    /// button row. Only nodes with controls (task cards, snippets) have one.
    func cardMenuTarget(at point: CGPoint) -> Int? {
        // Pills in the card's strip are buttons of their own.
        if tappablePill(at: point) != nil { return nil }
        var pos: Int?
        if onMarkerClick != nil, let offset = markerOffset(at: point), let (docPos, _) = renderer.docPosition(offset) {
            let rpos = state.doc.resolve(docPos)
            var depth = rpos.depth
            while depth > 0, pos == nil {
                if renderer.style.chrome(for: rpos.node(depth))?.activates == true { pos = rpos.before(depth) }
                depth -= 1
            }
        } else if let active = chromeState.activePos, let region = renderer.chromes.first(where: { $0.pos == active }),
                  let rect = chromeRect(region) {
            let footer = region.box.footer * region.progress + region.box.paddingBottom
            if footer > region.box.paddingBottom, CGRect(x: rect.minX, y: rect.maxY - footer, width: rect.width, height: footer).contains(point) {
                pos = active
            }
        }
        guard let pos, let node = state.doc.nodeAt(pos), !renderer.style.controls(for: node).isEmpty else { return nil }
        return pos
    }

    /// The card menu for a long press at `point` (content coordinates): the card's controls, as
    /// on the Mac card (New Task, Description, Delete). Nil away from a card's control area.
    public func cardMenu(at point: CGPoint) -> UIMenu? {
        guard let pos = cardMenuTarget(at: point), let node = state.doc.nodeAt(pos) else { return nil }
        let actions = renderer.style.controls(for: node).map { control in
            UIAction(title: control.title, attributes: control.destructive ? .destructive : []) { [weak self] _ in
                guard let self, let current = self.cardMenuTarget(at: point), current == pos else { return }
                self.runChromeControl(control, at: pos)
            }
        }
        return UIMenu(title: "", children: actions)
    }

    /// Run the card menu's item with this title for the card at `point`, as choosing it does.
    @discardableResult
    public func performCardMenuItem(_ title: String, at point: CGPoint) -> Bool {
        guard let pos = cardMenuTarget(at: point), let node = state.doc.nodeAt(pos),
              let control = renderer.style.controls(for: node).first(where: { $0.title == title }) else { return false }
        return runChromeControl(control, at: pos)
    }

    /// Show the card menu at `point`, as a long press there does. Returns whether there is one.
    @discardableResult
    public func presentCardMenu(at point: CGPoint) -> Bool {
        guard cardMenuTarget(at: point) != nil else { return false }
        cardMenuInteraction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        return true
    }

    @objc func cardLongPressed(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began else { return }
        presentCardMenu(at: press.location(in: self))
    }

    // MARK: Tick animation

    /// Animate ticks (off in tests that check the settled look).
    public var animatesChecks: Bool {
        get { cardControlState.animatesChecks }
        set { cardControlState.animatesChecks = newValue }
    }

    /// The tick animation for the paragraph at `offset`, while one is running.
    public func checkAnimation(atString offset: Int) -> CheckAnimationState? { cardControlState.checks.state(atString: offset) }

    /// Step every tick animation (the display link calls this; tests call it directly).
    public func advanceCheckAnimations(by dt: CFTimeInterval) {
        let checks = cardControlState.checks
        let finished = checks.advance(by: dt)
        // The strike-through draws with the text, in TextKit's fragment views: redraw those
        // paragraphs, and once more as each animation ends so the settled look shows.
        let offsets = Array(checks.entries.keys) + finished
        redrawParagraphs(atString: offsets)
        // The checkbox draws behind, in the decoration tiles: only the ticking paragraphs.
        for offset in offsets {
            if let rect = decorationRect(ofParagraphAtString: offset) { decorations.setNeedsDisplay(contentRect: rect) }
        }
        if checks.entries.isEmpty {
            cardControlState.checkLink?.invalidate()
            cardControlState.checkLink = nil
        }
    }

    func startCheckAnimations() {
        let state = cardControlState
        // Only once per rendered document: a selection change leaves the last flips in place.
        guard state.checks.takeFlips(of: renderer.doc), state.animatesChecks, !prefersReducedMotion(), !renderer.toggledChecks.isEmpty else { return }
        for pos in renderer.toggledChecks {
            let offset = renderer.stringOffset(pos)
            guard offset < textStorage.length,
                  let d = textStorage.attribute(.pmBlock, at: offset, effectiveRange: nil) as? BlockDecoration,
                  case .checkbox(let checked, _) = d.marker else { continue }
            state.checks.entries[offset] = (0, checked)
        }
        guard state.checkLink == nil, !state.checks.entries.isEmpty else { return }
        state.lastCheckTick = 0
        let link = CADisplayLink(target: LinkTicker { [weak self] link in
            guard let self else { link.invalidate(); return }
            let s = self.cardControlState
            let dt = s.lastCheckTick == 0 ? link.targetTimestamp - link.timestamp : link.timestamp - s.lastCheckTick
            s.lastCheckTick = link.timestamp
            self.advanceCheckAnimations(by: dt)
        }, selector: #selector(LinkTicker.tick(_:)))
        link.add(to: .main, forMode: .common)
        state.checkLink = link
    }

    private func redrawParagraphs(atString offsets: [Int]) {
        guard !offsets.isEmpty, let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return }
        for offset in offsets {
            guard let loc = tcm.location(tcm.documentRange.location, offsetBy: offset),
                  let fragment = tlm.textLayoutFragment(for: loc) else { continue }
            tlm.invalidateLayout(for: fragment.rangeInElement)
        }
        tlm.textViewportLayoutController.layoutViewport()
    }

    // MARK: Pointer hover (iPad)

    /// Where the hover looks draw: every card and checkbox hovered or fading, in content coordinates.
    func hoverDecorationRects() -> [CGRect] {
        let s = cardControlState
        let chromes = Set(s.chromeHover.levels.keys).union([s.chromeHover.target].compactMap { $0 })
        let markers = Set(s.markerHover.levels.keys).union([s.markerHover.target].compactMap { $0 })
        return chromes.compactMap { decorationRect(ofChromeAt: $0) } + markers.compactMap { decorationRect(ofParagraphAtString: $0) }
    }

    /// The pointer moved to `point` (content coordinates), or left the view (nil): fade the
    /// hover look onto the card and the checkbox under it, as on the Mac.
    public func pointerMoved(to point: CGPoint?) {
        let s = cardControlState
        let marker = point.flatMap { onMarkerClick != nil ? markerOffset(at: $0) : nil }
        let chrome = point.flatMap { point in
            chromeCandidates(in: CGRect(origin: point, size: .zero)).first { region in
                region.box.activates && chromeRect(region)?.contains(point) == true
            }?.pos
        }
        guard marker != s.hoveredMarker || chrome != s.hoveredChrome else { return }
        // What was hovered (still fading out) and what is now.
        let before = hoverDecorationRects()
        s.hoveredMarker = marker
        s.hoveredChrome = chrome
        s.chromeHover.animates = chromeState.animates
        s.markerHover.animates = chromeState.animates
        s.chromeHover.set(chrome)
        s.markerHover.set(marker)
        for rect in before + hoverDecorationRects() { decorations.setNeedsDisplay(contentRect: rect) }
        guard !(s.chromeHover.settled && s.markerHover.settled), s.hoverLink == nil else { return }
        s.lastHoverTick = 0
        let link = CADisplayLink(target: LinkTicker { [weak self] link in
            guard let self else { link.invalidate(); return }
            let s = self.cardControlState
            let dt = s.lastHoverTick == 0 ? link.targetTimestamp - link.timestamp : link.timestamp - s.lastHoverTick
            s.lastHoverTick = link.timestamp
            let fading = self.hoverDecorationRects()
            s.chromeHover.step(dt)
            s.markerHover.step(dt)
            for rect in fading { self.decorations.setNeedsDisplay(contentRect: rect) }
            guard s.chromeHover.settled && s.markerHover.settled else { return }
            link.invalidate()
            s.hoverLink = nil
        }, selector: #selector(LinkTicker.tick(_:)))
        link.add(to: .main, forMode: .common)
        s.hoverLink = link
    }

    /// How far the hover look on the card at `pos` has faded in (0 without a pointer).
    public func chromeHoverLevel(at pos: Int) -> CGFloat { cardControlState.chromeHover.level(pos) }

    /// How far the hover look on the checkbox of the paragraph at string offset `offset` has faded in.
    public func markerHoverLevel(atString offset: Int) -> CGFloat { cardControlState.markerHover.level(offset) }

    @objc func pointerHovered(_ hover: UIHoverGestureRecognizer) {
        switch hover.state {
        case .began, .changed: pointerMoved(to: hover.location(in: self))
        default: pointerMoved(to: nil)
        }
    }

    // MARK: Gestures

    /// Add the card gestures (once the view is in a window).
    func installCardGestures() {
        guard cardLongPress.view == nil else { return }
        addGestureRecognizer(cardLongPress)
        addGestureRecognizer(pointerHover)
        addInteraction(cardMenuInteraction)
    }
}

/// Lets the card long press take only touches on a card's control area, and makes UIKit's own
/// long presses (the loupe, selection) wait for it there.
final class CardMenuGate: NSObject, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    weak var view: ProseTextView?
    init(_ view: ProseTextView) { self.view = view }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        MainActor.assumeIsolated {
            guard let view else { return false }
            return view.cardMenuTarget(at: touch.location(in: view)) != nil
        }
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view === recognizer.view && other is UILongPressGestureRecognizer
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        MainActor.assumeIsolated { view?.cardMenu(at: configuration.sourcePoint) }
    }
}

/// Lets the pointer hover recognizer run alongside UIKit's own pointer handling.
final class HoverGate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// CADisplayLink retains its target; this holds a closure (which holds the view weakly) instead.
final class LinkTicker: NSObject {
    private let action: @MainActor (CADisplayLink) -> Void
    init(_ action: @escaping @MainActor (CADisplayLink) -> Void) { self.action = action }
    @objc func tick(_ link: CADisplayLink) { MainActor.assumeIsolated { action(link) } }
}
#endif
