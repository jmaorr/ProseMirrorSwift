#if os(macOS)
import AppKit
import PMModel
import PMState

/// Focus dimming: top-level blocks the selection doesn't touch draw at `focusDimming` alpha.
/// Drawing only: the text storage and layout are untouched.
extension ProseTextView {
    /// The string range of the top-level blocks the selection touches, while dimming is on.
    public var focusedBlockRange: NSRange? { focus.range }

    /// The alpha a fragment starting at `offset` draws with right now.
    public func focusAlpha(atString offset: Int) -> CGFloat {
        guard let dim = focusDimming else { return 1 }
        func alpha(_ range: NSRange?) -> CGFloat { range.map { NSLocationInRange(offset, $0) ? 1 : dim } ?? 1 }
        let target = alpha(focus.range)
        guard focus.progress < 1 else { return target }
        let from = alpha(focus.previous)
        return from + (target - from) * focus.progress
    }

    func updateFocus() {
        let range = focusDimming == nil ? nil : computeFocusedRange()
        guard range != focus.range else { return }
        focus.previous = focus.range
        focus.range = range
        guard focusDimming != nil else { return }
        if animatesChrome && focus.previous != nil {
            focus.progress = 0
            focus.start = CACurrentMediaTime()
            focus.timer?.invalidate()
            focus.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self else { t.invalidate(); return }
                    self.focus.progress = min(1, CGFloat((CACurrentMediaTime() - self.focus.start) / FocusState.duration))
                    if self.focus.progress >= 1 { t.invalidate() }
                    self.needsDisplay = true
                }
            }
        } else {
            focus.progress = 1
        }
        needsDisplay = true
    }

    private func computeFocusedRange() -> NSRange? {
        let doc = state.doc
        guard doc.childCount > 0 else { return nil }
        // The top-level blocks holding the selection's ends, as a document range.
        let from = state.selection.from, to = state.selection.to
        var lower: Int?, upper = 0, offset = 0
        for i in 0..<doc.childCount {
            let end = offset + doc.child(i).nodeSize
            let last = i == doc.childCount - 1
            if lower == nil, from < end || last { lower = offset }
            if lower != nil { upper = end }
            if to < end || last { break }
            offset = end
        }
        guard let start = lower else { return nil }
        // Spans are in document order: find the first inside, then walk to the last.
        let spans = renderer.spans
        var lo = 0, hi = spans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if spans[mid].pmStart < start { lo = mid + 1 } else { hi = mid }
        }
        guard lo < spans.count, spans[lo].pmStart < upper else { return nil }
        var i = lo
        while i + 1 < spans.count, spans[i + 1].pmStart < upper { i += 1 }
        let strStart = spans[lo].strStart
        let strEnd = min(spans[i].strStart + spans[i].length + 1, textStorage?.length ?? Int.max)
        return NSRange(location: strStart, length: strEnd - strStart)
    }
}

final class FocusState {
    static let duration: CFTimeInterval = 0.15
    var range: NSRange?
    var previous: NSRange?
    var progress: CGFloat = 1
    var start: CFTimeInterval = 0
    var timer: Timer?
}
#endif
