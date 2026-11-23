#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMTextKit
import PMTables
import PMTableView

@MainActor
final class TableGridTests: XCTestCase {
    private func simpleDoc() throws -> Node {
        try TestDocs.doc([J.p("above"), J.table([["a", "b"], ["c", "d"]]), J.p("below")])
    }

    func testTableRendersAsAttachment() throws {
        let h = try TableHarness(try simpleDoc())
        XCTAssertEqual(h.view.textStorage?.string, "above\n\u{FFFC}\nbelow\n")
        XCTAssertEqual(h.tables.grids.count, 1)
        XCTAssertNotNil(h.grid.superview, "grid view loaded into the document")
    }

    func testCellLayersMatchLayout() throws {
        let h = try TableHarness(try simpleDoc())
        let grid = h.grid
        XCTAssertEqual(grid.layout.cellRects.count, 4)
        for (pos, rect) in grid.layout.cellRects {
            XCTAssertEqual(grid.cellLayer(at: pos)?.frame, CGRect(origin: rect.origin, size: CGSize(width: rect.width + 1, height: rect.height + 1)))
            XCTAssertNotNil(grid.cellLayer(at: pos)?.cell)
        }
    }

    func testHostReflowWhenCellGrows() throws {
        let h = try TableHarness(try simpleDoc())
        let belowBefore = h.lineTop(atString: 8)
        let heightBefore = h.grid.layout.size.height
        let cellPos = h.grid.tableStart + (try TableMap.get(h.grid.table!)).map[0]
        let long = String(repeating: "grow the row with many words ", count: 12)
        h.dispatch(try h.core.state.tr.insertText(long, cellPos + 2))
        XCTAssertGreaterThan(h.grid.layout.size.height, heightBefore + 20)
        XCTAssertEqual(h.lineTop(atString: 8) - belowBefore, h.grid.layout.size.height - heightBefore, accuracy: 1)
    }

    func testCellCacheReusesUnchangedCells() throws {
        let h = try TableHarness(try simpleDoc())
        let map = try TableMap.get(h.grid.table!)
        let others = map.map.dropFirst().map { h.grid.cellLayer(at: $0)?.cell }
        let first = h.grid.cellLayer(at: map.map[0])?.cell
        h.dispatch(try h.core.state.tr.insertText("x", h.grid.tableStart + map.map[0] + 2))
        let newMap = try TableMap.get(h.grid.table!)
        XCTAssertFalse(h.grid.cellLayer(at: newMap.map[0])?.cell === first)
        for (old, pos) in zip(others, newMap.map.dropFirst()) { XCTAssertTrue(h.grid.cellLayer(at: pos)?.cell === old) }
    }

    func testCellRangeRectsAndPositions() throws {
        let h = try TableHarness(try TestDocs.doc([J.table([["hello world"]])]))
        let pos = (try TableMap.get(h.grid.table!)).map[0]
        let cell = try XCTUnwrap(h.grid.renderedCell(at: pos))
        let rects = cell.rects(for: NSRange(location: 6, length: 5))
        XCTAssertFalse(rects.isEmpty)
        let mid = CGPoint(x: rects[0].midX, y: rects[0].midY)
        XCTAssertEqual(cell.characterIndex(at: mid).map { (6...11).contains($0) }, true)
        // Offset 6 in the cell's text is 1 (paragraph open) + 6 into its content.
        XCTAssertEqual(cell.position(atString: 6), 7)
    }

    func testOverlayDrawn() throws {
        let h = try TableHarness(try TestDocs.doc([J.table([["misspeled"]])]))
        let layer = try XCTUnwrap(h.grid.cellLayer(at: (try TableMap.get(h.grid.table!)).map[0]))
        layer.hidesText = false
        let plain = tableBitmap(layer)
        layer.overlays = [CellOverlay(range: NSRange(location: 0, length: 9), kind: .underline(.systemRed))]
        XCTAssertNotEqual(tableBitmap(layer), plain)
    }

    func testRendersMalformedTable() throws {
        for corpusDoc in try TableJ.corpus(seed: 13_000, count: 40) {
            let h = try TableHarness(corpusDoc)
            XCTAssertFalse(h.tables.grids.isEmpty)
            for grid in h.tables.grids { XCTAssertGreaterThan(grid.layout.size.height, 0) }
        }
    }

    func testWideTableScrollsAndKeepsCellRects() throws {
        let cells = (0..<12).map { TableJ.textCell("c\($0)", colwidth: [120]) }
        let h = try TableHarness(try TestDocs.doc([TableJ.table([cells])]), width: 600)
        let host = try h.host()
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(host.scrolls)
        h.grid.scroll(NSPoint(x: 300, y: 0))
        let visible = h.grid.visibleRect
        XCTAssertEqual(visible.minX, 300, accuracy: 1)
        let pos = h.grid.layout.cell(at: CGPoint(x: visible.minX + 10, y: 10))
        XCTAssertEqual(pos.flatMap { h.grid.table?.nodeAt($0)?.textContent }, "c2")
    }

    func testCellWithListAndQuoteRenders() throws {
        let list = J.ul(["one", "two"])
        let quote = J.quote([J.p("said")])
        let h = try TableHarness(try TestDocs.doc([TableJ.table([[TableJ.cell([list, quote])]])]))
        let cell = try XCTUnwrap(h.grid.renderedCell(at: (try TableMap.get(h.grid.table!)).map[0]))
        XCTAssertEqual(cell.string.string, "one\ntwo\nsaid\n")
        XCTAssertGreaterThan(cell.text.height, 40)
    }

    func testNestedTableIsReadOnlyCard() throws {
        let inner = J.table([["x", "y"]])
        let h = try TableHarness(try TestDocs.doc([TableJ.table([[TableJ.cell([inner])]])]))
        XCTAssertEqual(h.tables.grids.count, 1, "no grid for the nested table")
        let cell = try XCTUnwrap(h.grid.renderedCell(at: (try TableMap.get(h.grid.table!)).map[0]))
        XCTAssertEqual(cell.string.string, "\u{FFFC}\n")
        let deco = cell.string.attribute(.pmBlock, at: 0, effectiveRange: nil) as? BlockDecoration
        XCTAssertEqual(deco?.leafLabel, "Table — 1×2, edit on web")
    }

    /// A sample table with a header row, a list in a cell and a wrapping cell renders, hovers
    /// and takes a cell selection; written to TABLE_SNAPSHOT_DIR when it's set.
    func testSnapshotSampleTable() throws {
        let doc = try TestDocs.doc([
            J.p("A paragraph above the table."),
            TableJ.table([
                [TableJ.textCell("Item", type: "table_header"), TableJ.textCell("Owner", type: "table_header"),
                 TableJ.textCell("Notes", type: "table_header")],
                [TableJ.textCell("Groceries"), TableJ.textCell("Sam"), TableJ.cell([J.ul(["milk", "bread"])])],
                [TableJ.textCell("Plan the trip"), TableJ.textCell(""), TableJ.textCell("A longer note that wraps onto a second line in its cell")],
            ]),
            J.p("A paragraph below."),
        ])
        let h = try TableHarness(doc)
        h.snapshot("sample-table")
        let map = try TableMap.get(h.grid.table!)
        let rect = try XCTUnwrap(h.grid.layout.cellRect(pos: map.map[4]))
        h.grid.hover(at: NSPoint(x: rect.midX, y: rect.maxY - 4))
        h.dispatch(h.core.state.tr.setSelection(try CellSelection.create(h.core.state.doc, h.grid.tableStart + map.map[4],
                                                                            h.grid.tableStart + map.map[8])))
        h.grid.hover(at: NSPoint(x: rect.midX, y: h.grid.layout.size.height - 4))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(h.grid.selectedCellRects.count, 4)
        h.snapshot("sample-table-hover")
    }
}
#endif
