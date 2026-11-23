// Selection and edit mapping shared by the AppKit and UIKit text views: string ranges in the
// rendered text to document positions and selections, and prosemirror-view's text diff.
#if os(macOS) || canImport(UIKit)
import Foundation
import PMModel
import PMState

extension ProseViewHost {
    /// Document range covered by a string range.
    func docRange(_ range: NSRange) -> (from: Int, to: Int) {
        let from = renderer.docPosition(range.location)?.pos ?? 0
        let to = range.length == 0 ? from : (renderer.docPosition(range.upperBound)?.pos ?? from)
        return (from, max(from, to))
    }

    /// The selection a string range stands for.
    func selection(for range: NSRange) -> Selection {
        let doc = state.doc
        if range.length == 1, let span = renderer.span(atString: range.location), span.isLeaf, span.strStart == range.location {
            return NodeSelection.create(doc, span.pmStart)
        }
        let (from, to) = docRange(range)
        if from == to {
            let rpos = doc.resolve(from)
            return rpos.parent.inlineContent ? TextSelection(rpos) : Selection.near(rpos)
        }
        // An end between blocks (on a table's line) moves outward to the nearest text, so the
        // block it's beside is in the range rather than the end snapping into it.
        func outward(_ pos: Int, _ dir: Int) -> ResolvedPos {
            let rpos = doc.resolve(pos)
            guard !rpos.parent.inlineContent, let found = Selection.findFrom(rpos, dir, textOnly: true) else { return rpos }
            return found.headPos
        }
        let start = outward(from, -1), end = outward(to, 1)
        // Keep the anchor on the side it was on, so shift-extension feels right.
        let backward = state.selection.anchor == to && state.selection.head != to
        return backward ? TextSelection.between(end, start) : TextSelection.between(start, end)
    }

    /// `range` grown to cover every collapsed run it reaches into, or nil when it reaches none.
    /// A caret (empty range) at a run's edge doesn't reach into it.
    func rangeCoveringCollapsedRuns(_ range: NSRange) -> NSRange? {
        guard renderer.doc === state.doc else { return nil }
        var lower = range.location, upper = range.upperBound
        var hit = false
        for run in renderer.runs where run.collapsed {
            let start = run.strStart, end = run.strStart + (run.to - run.from)
            let reaches = range.length == 0 ? (start < range.location && range.location < end)
                : (range.location < end && range.upperBound > start)
            guard reaches else { continue }
            hit = true
            lower = min(lower, start)
            upper = max(upper, end)
        }
        return hit ? NSRange(location: lower, length: upper - lower) : nil
    }
}

public enum TextDiff {
    /// prosemirror-view's `findDiff` on UTF-16: the changed range `start..<endA` in `a` and
    /// `start..<endB` in `b`, preferring a change that ends at `preferred` when it's ambiguous.
    public static func findDiff(_ a: [UInt16], _ b: [UInt16], preferred: Int) -> (start: Int, endA: Int, endB: Int)? {
        var start = 0
        while start < a.count && start < b.count && a[start] == b[start] { start += 1 }
        if start == a.count && start == b.count { return nil }
        var endA = a.count, endB = b.count
        while endA > 0 && endB > 0 && a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        if endA < start && a.count < b.count {
            let move = preferred <= start && preferred >= endA ? start - preferred : 0
            start -= move
            endB = start + (endB - endA)
            endA = start
        } else if endB < start {
            let move = preferred <= start && preferred >= endB ? start - preferred : 0
            start -= move
            endA = start + (endA - endB)
            endB = start
        }
        // Never split a surrogate pair.
        if start > 0, UTF16.isTrailSurrogate(start < a.count ? a[start] : (start < b.count ? b[start] : 0)) { start -= 1 }
        if endA < a.count, UTF16.isTrailSurrogate(a[endA]) { endA += 1; endB += 1 }
        return (start, endA, endB)
    }
}
#endif
