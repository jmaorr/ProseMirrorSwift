#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMTables
import PMTableView

/// Tables in dark mode, and scrolling the note with the pointer over a table.
@MainActor
final class TableDarkAndScrollTests: XCTestCase {
    private func p(_ t: String) -> JSONValue { J.p(t) }

    private func tableDoc(paragraphsAfter: Int = 0) throws -> Node {
        var content: [JSONValue] = [J.table([["Hello there"]])]
        for i in 0..<paragraphsAfter { content.append(p("Line \(i)")) }
        return try TestDocs.doc(content)
    }

    /// The brightest pixel a cell draws over black.
    private func brightest(_ layer: CellLayer) -> CGFloat {
        let size = layer.bounds.size
        let w = Int(size.width * 2), h = Int(size.height * 2)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: 2, y: 2)
        layer.draw(in: ctx)
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var best: CGFloat = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            best = max(best, CGFloat(Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2])) / (3 * 255))
        }
        return best
    }

    /// In dark mode a cell's text is light, even when it draws outside the view's appearance
    /// (Core Animation draws layers with whatever appearance is current).
    func testCellTextFollowsDarkMode() throws {
        let h = try TableHarness(try tableDoc(paragraphsAfter: 1))
        // The caret after the table: an edited cell hides its static text under the editor.
        h.view.dispatch(h.view.state.tr.setSelection(Selection.atEnd(h.view.state.doc)))
        h.window.appearance = NSAppearance(named: .darkAqua)
        h.settle()
        let map = try TableMap.get(try XCTUnwrap(h.grid.table))
        let layer = try XCTUnwrap(h.grid.cellLayer(at: map.map[0]))
        var drawn: CGFloat = 0
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { drawn = brightest(layer) }
        XCTAssertGreaterThan(drawn, 0.6, "dark mode cell text should be light")
    }

    /// Scrolling up or down with the pointer over a table scrolls the document, not nothing.
    func testVerticalScrollOverATableScrollsTheNote() throws {
        let h = try TableHarness(try tableDoc(paragraphsAfter: 120))
        let host = try XCTUnwrap(h.grid.enclosingScrollView?.superview as? TableHostView)
        let note = try XCTUnwrap(h.view.enclosingScrollView)
        // The harness's text view keeps the window's height: give the note room to scroll.
        h.view.setFrameSize(NSSize(width: h.view.frame.width, height: 4000))
        h.settle()
        let before = note.contentView.bounds.origin.y
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -120, wheel2: 0, wheel3: 0))
        cg.location = h.window.convertPoint(toScreen: host.convert(NSPoint(x: 20, y: 10), to: nil))
        host.scrollView.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        h.settle()
        XCTAssertGreaterThan(note.contentView.bounds.origin.y, before + 50)
    }

    /// A wide table still scrolls sideways under the pointer.
    func testSidewaysScrollStillMovesAWideTable() throws {
        // Fixed column widths wider than the note's column, as a resized table has.
        let cells: [JSONValue] = (0..<8).map { TableJ.textCell("Column \($0)", colwidth: [150]) }
        let doc = try TestDocs.doc([TableJ.table([cells]), p("after")])
        let h = try TableHarness(doc)
        let host = try XCTUnwrap(h.grid.enclosingScrollView?.superview as? TableHostView)
        XCTAssertGreaterThan(h.grid.frame.width, host.scrollView.contentView.bounds.width)
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -150, wheel3: 0))
        host.scrollView.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        // The clip view can apply the scroll on a later turn when the machine is busy.
        let deadline = Date().addingTimeInterval(2)
        while host.scrollView.contentView.bounds.origin.x <= 50, Date() < deadline { h.settle() }
        XCTAssertGreaterThan(host.scrollView.contentView.bounds.origin.x, 50)
    }
}
#endif
