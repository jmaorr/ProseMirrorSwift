#if os(macOS)
import AppKit

/// How the insertion point is drawn.
public enum TextCaret: Equatable {
    /// AppKit's own insertion point (coloured by `insertionPointColor`).
    case system
    /// A bar of a given width, drawn by the view.
    case bar(width: CGFloat)
    /// A block `widthEm` of the font size wide, drawn by the view. It steps between
    /// characters rather than gliding.
    case block(widthEm: CGFloat)
}

/// A caret the view draws itself, as a layer that blinks in the render server.
final class CaretState {
    var style: TextCaret = .system
    var color: NSColor = .textColor
    /// AppKit's insertion point colour while ours is drawn instead.
    var savedSystemColor: NSColor?
    let layer = CALayer()
    /// How deep in viewport layouts (TextKit's, or one `ensureLayout(through:)` started) the view
    /// is: placements from inside one read the frames it gives and lay nothing out themselves.
    var viewportLayouts = 0
    var inViewportLayout: Bool { viewportLayouts > 0 }
}

extension ProseTextView {
    /// Lay the text out through `location` the way it is drawn, so rects read from its fragments
    /// are where the text is on screen.
    ///
    /// On screen that is TextKit's viewport layout, which positions what NSTextView draws. A
    /// separate `ensureLayout(for:)` stacks fragments on its own and, once the layout above has
    /// been invalidated (a chrome frame's restyle, an image arriving), can put them hundreds of
    /// points from where the viewport layout puts the drawn text: the caret then floats in empty
    /// space until the next placement. Off screen, mid-edit (no
    /// viewport layout while the storage is being edited) or for a location outside the viewport,
    /// lay out from the top of the viewport (the document's start when `location` is above it)
    /// through `location`: just an empty range there lays out only that fragment, under
    /// neighbours still holding the estimates TextKit gave them when text above changed.
    func ensureLayout(through location: NSTextLocation) {
        guard let tlm = textLayoutManager else { return }
        let viewport = tlm.textViewportLayoutController
        func inViewport() -> Bool {
            guard let range = viewport.viewportRange else { return false }
            return range.location.compare(location) != .orderedDescending && location.compare(range.endLocation) != .orderedDescending
        }
        // Called from the viewport layout itself: its frames are the ones drawn.
        if caretState.inViewportLayout, inViewport() { return }
        if !caretState.inViewportLayout, window != nil, textStorage?.editedMask.isEmpty != false {
            caretState.viewportLayouts += 1
            viewport.layoutViewport()
            caretState.viewportLayouts -= 1
            if inViewport() { return }
        }
        var start = tlm.documentRange.location
        if let top = viewport.viewportRange?.location, top.compare(location) != .orderedDescending { start = top }
        tlm.ensureLayout(for: NSTextRange(location: start, end: location) ?? NSTextRange(location: location))
    }

    /// The line box (line spacing included) around string offset `offset`, in view coordinates.
    public func lineRect(atString offset: Int) -> CGRect? { lineRect(atString: offset, layingOut: true) }

    /// `layingOut` false reads the frames as last laid out (what is drawn), laying nothing out.
    func lineRect(atString offset: Int, layingOut: Bool) -> CGRect? {
        guard let tlm = textLayoutManager, let tcs = textContentStorage,
              let loc = tcs.location(tcs.documentRange.location, offsetBy: offset) else { return nil }
        if layingOut { ensureLayout(through: loc) }
        var line: CGRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: loc), type: .standard, options: [.rangeNotRequired]) { _, rect, _, _ in
            line = rect
            return false
        }
        return line?.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// The custom caret's rect in view coordinates; nil with the system caret or a non-empty selection.
    /// A block covers the glyph box (ascender to descender) on the line's baseline, like a typewriter's.
    public var caretRect: CGRect? { caretRect(layingOut: true) }

    func caretRect(layingOut: Bool) -> CGRect? {
        let offset = selectedRange().location
        guard caret != .system, !selectsLeafBlock, selectedRange().length == 0, var r = lineRect(atString: offset, layingOut: layingOut),
              let tlm = textLayoutManager, let tcs = textContentStorage,
              let loc = tcs.location(tcs.documentRange.location, offsetBy: offset),
              let fragment = tlm.textLayoutFragment(for: loc) else { return nil }
        let length = textStorage?.length ?? 0
        let font = (offset < length ? textStorage?.attribute(.font, at: offset, effectiveRange: nil)
            : length > 0 ? textStorage?.attribute(.font, at: length - 1, effectiveRange: nil) : nil) as? NSFont
            ?? typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: NSFont.systemFontSize)
        // The baseline of the line holding the caret, from the fragment's own line layout.
        let start = tlm.offset(from: tlm.documentRange.location, to: fragment.rangeInElement.location)
        let lines = fragment.textLineFragments
        let line = lines.first { NSLocationInRange(offset - start, $0.characterRange) } ?? lines.last
        if let line {
            let baseline = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y + textContainerOrigin.y
            r.origin.y = baseline - font.ascender
            r.size.height = font.ascender - font.descender
            // An empty last paragraph's fragment starts at the container's edge, its indent only
            // in the line's own bounds, and TextKit's segment rect ignores that: never left of
            // where the line's first glyph would go.
            let lineStart = fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + textContainerOrigin.x
            r.origin.x = max(r.origin.x, lineStart)
        }
        switch caret {
        case .system: return nil
        case .bar(let width): r.size.width = width
        case .block(let em): r.size.width = font.pointSize * em
        }
        return r
    }

    func caretStyleChanged() {
        if caret == .system {
            caretState.layer.removeFromSuperlayer()
            if let saved = caretState.savedSystemColor { insertionPointColor = saved }
            caretState.savedSystemColor = nil
        } else {
            if caretState.savedSystemColor == nil {
                caretState.savedSystemColor = insertionPointColor
                caretState.color = insertionPointColor
            }
            insertionPointColor = .clear
            wantsLayer = true
            if caretState.layer.superlayer == nil { layer?.addSublayer(caretState.layer) }
        }
        updateCaret()
    }

    /// Move the custom caret to the selection and (with `restartBlink`) restart its blink, so it
    /// stays solid while typing. Called whenever the selection is set and whenever AppKit or the
    /// view re-places its own insertion point after layout (`updateInsertionPointStateAndRestartTimer`).
    func updateCaret(restartBlink: Bool = true) {
        guard caret != .system else { return }
        let l = caretState.layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let r = caretRect, window?.firstResponder === self {
            l.isHidden = false
            l.frame = r
            l.backgroundColor = caretState.color.cgColor
            if case .block = caret { l.cornerRadius = 0 } else { l.cornerRadius = 1 }
            l.zPosition = 10
            if restartBlink || l.animation(forKey: "blink") == nil {
                l.removeAnimation(forKey: "blink")
                let blink = CAKeyframeAnimation(keyPath: "opacity")
                blink.values = [1, 1, 0, 0]
                blink.keyTimes = [0, 0.5, 0.5, 1]
                blink.duration = 1.05
                blink.repeatCount = .infinity
                blink.beginTime = CACurrentMediaTime() + 0.5
                l.add(blink, forKey: "blink")
            }
        } else {
            l.isHidden = true
        }
        CATransaction.commit()
        #if DEBUG
        // Debug builds with the PMInputLog default set: where each placement put the caret, against the
        // fragment TextKit has for it and the visible rect, to compare with what is on screen.
        if InputTrace.enabled {
            let offset = selectedRange().location
            let fragment = textContentStorage.flatMap { tcs in tcs.location(tcs.documentRange.location, offsetBy: offset) }
                .flatMap { textLayoutManager?.textLayoutFragment(for: $0)?.layoutFragmentFrame }
            InputTrace.note(self, "caret \(l.isHidden ? "hidden" : "\(l.frame)") restart=\(restartBlink) viewportLayout=\(caretState.inViewportLayout) editing=\(textStorage?.editedMask.isEmpty == false) fragment=\(fragment.map { "\($0)" } ?? "nil") visible=\(visibleRect) key=\(window?.isKeyWindow == true)")
        }
        #endif
    }
}
#endif
