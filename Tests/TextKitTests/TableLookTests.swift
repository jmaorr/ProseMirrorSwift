#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMTextKit
import PMTables
import PMTableView
import PMExampleSetup

/// How tables look and feel: grips in the margin, borders that move with their cells.
@MainActor
final class TableLookTests: XCTestCase {
    private func host(_ h: TableHarness) throws -> TableHostView { try h.host() }

    // Grips hang into the document's margin: TextKit's line view mustn't clip them, and clicks
    // there must reach them.
    func testRowGripInMarginIsVisibleAndClickable() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let host = try host(h)
        let delay = TableMotion.revealDelay
        TableMotion.revealDelay = 0
        defer { TableMotion.revealDelay = delay }
        h.grid.hover(at: NSPoint(x: 20, y: 10))
        XCTAssertLessThan(host.rowGrip.frame.minX, 0, "the row grip is left of the table")
        if #available(macOS 14, *) { XCTAssertFalse(try XCTUnwrap(host.superview).clipsToBounds) }
        let center = NSPoint(x: host.rowGrip.frame.midX, y: host.rowGrip.frame.midY)
        let inSuper = try XCTUnwrap(h.view.superview).convert(center, from: host)
        XCTAssertTrue(h.view.hitTest(inSuper) === host.rowGrip)
    }

    // The grips and "+" set their own cursor, not the text I-beam.
    func testHandlesSetTheirOwnCursor() throws {
        let host = try host(try TableHarness.grid([["a", "b"]]))
        for handle in [host.rowGrip, host.columnGrip, host.tableGrip, host.addRowButton, host.addColumnButton] {
            XCTAssertTrue(handle.trackingAreas.contains { $0.options.contains(.cursorUpdate) && $0.owner === handle })
        }
    }

    // Each cell draws its own fill and rules, so a dragged row takes its borders with it.
    func testCellsCarryTheirOwnBorders() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let grid = h.grid
        for (pos, rect) in grid.layout.cellRects {
            let layer = try XCTUnwrap(grid.cellLayer(at: pos))
            XCTAssertEqual(layer.borderWidth, grid.style.ruleWidth)
            XCTAssertNotNil(layer.borderColor)
            // Neighbours overlap by one rule, so shared edges are drawn once.
            XCTAssertEqual(layer.frame, CGRect(x: rect.minX, y: rect.minY, width: rect.width + grid.style.ruleWidth,
                                               height: rect.height + grid.style.ruleWidth))
        }
        grid.beginDrag(row: 0)
        for layer in grid.dragLayers(0...0, isRow: true) { XCTAssertNotNil(layer.backgroundColor, "a lifted row is opaque") }
        grid.cancelDrag()
    }

    // Header cells are tinted.
    func testHeaderCellsAreFilled() throws {
        let doc = try TestDocs.doc([J.table([["h"], ["c"]], header: true)])
        let h = try TableHarness(doc)
        let map = try TableMap.get(try XCTUnwrap(h.grid.table))
        XCTAssertEqual(h.grid.cellLayer(at: map.map[0])?.backgroundColor, h.grid.style.headerFill.cgColor)
        XCTAssertNil(h.grid.cellLayer(at: map.map[1])?.backgroundColor)
    }

    // The editing cell keeps its borders; only its static text hides under the editor.
    func testEditedCellKeepsBorders() throws {
        let h = try TableHarness.grid([["a", "b"]])
        let pos = try h.cellPos(0, 0)
        h.window.makeFirstResponder(h.view)
        h.dispatch(h.core.state.tr.setSelection(TextSelection.create(h.core.state.doc, pos + 2)))
        let layer = try XCTUnwrap(h.grid.cellLayer(at: pos - h.grid.tableStart))
        XCTAssertFalse(layer.isHidden)
        XCTAssertTrue(layer.hidesText)
    }

    // A table wider than the column fades out at the edge it continues past.
    func testWideTableFadesAtItsEdge() throws {
        let cells: [JSONValue] = (0..<8).map { _ in TableJ.textCell("", colwidth: [150]) }
        let wide = try TableHarness(try TestDocs.doc([TableJ.table([cells])]))
        let wideHost = try host(wide)
        XCTAssertTrue(wideHost.scrolls)
        XCTAssertEqual(wideHost.fadingEdges, [.maxX])
        let narrow = try host(try TableHarness.grid([["a", "b"]]))
        XCTAssertEqual(narrow.fadingEdges, [])
        XCTAssertNil(narrow.scrollView.layer?.mask)
    }

    // Lists and quotes inside a cell indent less than outside, and cell lines are tighter.
    func testCellBlocksAreCompact() throws {
        let schema = TestDocs.schema
        let style = BasicStyle()
        let para = try schema.nodeFromJSON(J.p(""))
        let list = try schema.nodeFromJSON(J.ul([""]))
        let item = list.child(0)
        let cell = try schema.nodeFromJSON(TableJ.textCell(""))
        func paragraphStyle(_ ancestors: [Node]) -> NSParagraphStyle {
            style.paragraph(para, ancestors: ancestors, marker: nil).0[.paragraphStyle] as! NSParagraphStyle
        }
        let inNote = paragraphStyle([list, item])
        let inCell = paragraphStyle([cell, list, item])
        XCTAssertLessThan(inCell.headIndent, inNote.headIndent)
        XCTAssertLessThan(paragraphStyle([cell]).lineHeightMultiple, paragraphStyle([]).lineHeightMultiple)
        // As the grid renders it: the cell is the root, so its style supplies the cell as an ancestor.
        let h = try TableHarness(try TestDocs.doc([TableJ.table([[TableJ.cell([list.toJSON()])]])]))
        let rendered = try XCTUnwrap(h.grid.renderedCell(at: (try TableMap.get(h.grid.table!)).map[0]))
        let drawn = rendered.string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual(drawn.headIndent, inCell.headIndent)
    }

    // A note opened with a table shows it without waiting for an edit or scroll: TextKit adds
    // attachment views on a later layout pass, which the table asks for.
    func testTableShowsWhenNoteOpens() throws {
        let schema = TestDocs.schema
        let doc = try TestDocs.doc([J.table([[""]])])
        let core = EditorCore(state: EditorState.create(EditorStateConfig(doc: doc, plugins: exampleSetup(schema: schema))))
        var style = BasicStyle()
        let tables = TableEmbeds(core: core, tableStyle: style.tableStyle, cellStyle: style)
        style.tables = tables
        let view = ProseTextView(core: core, style: style)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        window.contentView = view
        // One layout pass, as when the document opens; then the run loop, with no further layout.
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let grid = try XCTUnwrap(tables.grids.first)
        XCTAssertNotNil(grid.window, "the table's view is in the document")
    }

    // Passing over a table shows nothing; resting on it brings the grips in.
    func testGripsWaitForThePointerToRest() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let host = try host(h)
        let delay = TableMotion.revealDelay
        TableMotion.revealDelay = 0.15
        defer { TableMotion.revealDelay = delay }
        h.grid.hover(at: NSPoint(x: 20, y: 10))
        XCTAssertEqual(host.rowGrip.alphaValue, 0, "not on first touch")
        h.grid.hover(at: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(host.rowGrip.alphaValue, 0, "the pointer left before the grips came in")
        h.grid.hover(at: NSPoint(x: 20, y: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertGreaterThan(host.rowGrip.alphaValue, 0)
    }

    // Grips are grabbed: an open hand over them, a closed one while holding.
    func testGripsShowAHand() throws {
        let h = try TableHarness.grid([["a", "b"]])
        let host = try host(h)
        host.rowGrip.cursorUpdate(with: try h.mouse(.mouseMoved, 0, 0))
        XCTAssertEqual(NSCursor.current, NSCursor.openHand)
        host.rowGrip.mouseDown(with: try h.mouse(.leftMouseDown, 0, 0))
        XCTAssertEqual(NSCursor.current, NSCursor.closedHand)
        host.rowGrip.mouseUp(with: try h.mouse(.leftMouseUp, 0, 0))
        host.addRowButton.cursorUpdate(with: try h.mouse(.mouseMoved, 0, 0))
        XCTAssertEqual(NSCursor.current, NSCursor.arrow, "the edge \"+\" is a plain button, not a hand")
    }

    // The document's text view sets the I-beam as the pointer moves; over a grip it defers to the grip.
    func testNoteDefersCursorToGrip() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let host = try host(h)
        let delay = TableMotion.revealDelay
        TableMotion.revealDelay = 0
        defer { TableMotion.revealDelay = delay }
        h.grid.hover(at: NSPoint(x: 20, y: 10))
        let center = host.convert(NSPoint(x: host.rowGrip.frame.midX, y: host.rowGrip.frame.midY), to: nil)
        let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: center, modifierFlags: [], timestamp: 0,
                                                     windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        NSCursor.iBeam.set()
        h.view.mouseMoved(with: moved)
        XCTAssertEqual(NSCursor.current, NSCursor.openHand)
        NSCursor.iBeam.set()
        h.view.cursorUpdate(with: moved)
        XCTAssertEqual(NSCursor.current, NSCursor.openHand)
    }

    // The grip is what you hold: it travels with the dragged column (or row).
    func testGripFollowsTheDrag() throws {
        let h = try TableHarness.grid([["a", "b", "c"], ["d", "e", "f"]])
        let host = try host(h)
        let delay = TableMotion.revealDelay
        TableMotion.revealDelay = 0
        defer { TableMotion.revealDelay = delay }
        h.grid.hover(at: NSPoint(x: 20, y: 10))
        let column = host.columnGrip.frame.midX, row = host.rowGrip.frame.midY
        h.grid.beginDrag(column: 0)
        h.grid.hover(at: NSPoint(x: 200, y: 10))
        h.grid.updateDrag(offset: 40)
        XCTAssertEqual(host.columnGrip.frame.midX, column + 40, accuracy: 0.5)
        XCTAssertEqual(host.columnGrip.kind, .column(0))
        h.grid.cancelDrag()
        h.grid.beginDrag(row: 0)
        h.grid.updateDrag(offset: 15)
        XCTAssertEqual(host.rowGrip.frame.midY, row + 15, accuracy: 0.5)
        h.grid.cancelDrag()
    }

    // Over a column border the document shows the resize cursor, not the I-beam.
    func testColumnBorderShowsResizeCursor() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let border = NSPoint(x: h.grid.layout.columnX[1], y: h.grid.layout.rowY[1] + 5)
        let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: h.grid.convert(border, to: nil), modifierFlags: [],
                                                     timestamp: 0, windowNumber: h.window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 0, pressure: 0))
        NSCursor.iBeam.set()
        h.view.mouseMoved(with: moved)
        XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
    }

    // The "+" bars are roomy enough to see and hit.
    func testAddBarsAreComfortable() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let host = try host(h)
        host.layoutHandles()
        XCTAssertGreaterThanOrEqual(host.addRowButton.frame.height, 16)
        XCTAssertGreaterThanOrEqual(host.addColumnButton.frame.width, 16)
        XCTAssertGreaterThanOrEqual(host.height, host.addRowButton.frame.maxY, "the bar fits in the table's line")
    }

    // An empty cell is as tall as one with a line of text, so typing doesn't grow the row.
    func testEmptyRowMatchesTypedRow() throws {
        let h = try TableHarness.grid([[""], ["x"]])
        XCTAssertEqual(h.grid.layout.rowHeights[0], h.grid.layout.rowHeights[1])
    }

    // A dragged row or column is lifted out of the table, so it can travel past the table's edge.
    func testDraggedBlockTravelsPastTheEdge() throws {
        let h = try TableHarness.grid([["a", "b", "c"], ["d", "e", "f"]])
        let host = try host(h)
        h.grid.beginDrag(column: 2)
        h.grid.updateDrag(offset: 200)
        let layers = h.grid.dragLayers(2...2, isRow: false)
        XCTAssertFalse(layers.isEmpty)
        for layer in layers {
            let lifted = try XCTUnwrap(layer.superlayer)
            XCTAssertTrue(lifted.superlayer === host.layer, "lifted into the table's host, which doesn't clip")
            XCTAssertGreaterThan(lifted.frame.maxX, host.scrollView.frame.maxX)
        }
        h.grid.cancelDrag()
        for layer in layers { XCTAssertTrue(layer.superlayer === h.grid.layer, "back in the grid") }
    }

    // Adding a row grows the table over the motion's duration, so the document below slides
    // rather than jumping; with Reduce Motion it changes at once.
    func testAddingARowGrowsSmoothly() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let host = try host(h)
        let reduce = TableMotion.reduceMotion
        defer { TableMotion.reduceMotion = reduce }
        TableMotion.reduceMotion = { false }
        let before = host.height
        h.grid.addRowAtEnd()
        let target = host.grid.frame.height + TableHostView.chromeHeight(host.grid.style)
        XCTAssertGreaterThan(target, before)
        XCTAssertLessThan(host.height, target, "doesn't jump to the new height")
        XCTAssertLessThanOrEqual(host.scrollView.frame.height, host.height, "the new row is revealed as the table grows")
        RunLoop.current.run(until: Date().addingTimeInterval(TableMotion.duration + 0.15))
        XCTAssertEqual(host.height, target)

        TableMotion.reduceMotion = { true }
        h.grid.addRowAtEnd()
        XCTAssertEqual(host.height, host.grid.frame.height + TableHostView.chromeHeight(host.grid.style))
    }

    // Adding a column keeps each existing cell's layer: nothing swaps or fades but the new
    // column, and the existing cells slide to their new widths.
    func testAddingAColumnKeepsCellsInPlace() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let reduce = TableMotion.reduceMotion
        defer { TableMotion.reduceMotion = reduce }
        TableMotion.reduceMotion = { false }
        func layers() throws -> [String: CellLayer] {
            let table = try XCTUnwrap(h.grid.table), map = try TableMap.get(table)
            var out: [String: CellLayer] = [:]
            for pos in Set(map.map) { out[table.nodeAt(pos)!.textContent] = try XCTUnwrap(h.grid.cellLayer(at: pos)) }
            return out
        }
        let before = try layers()
        h.grid.addColumnAtEnd()
        let after = try layers()
        for text in ["a", "b", "c", "d"] {
            XCTAssertTrue(after[text] === before[text], "\(text) keeps its layer")
            XCTAssertNil(after[text]?.animation(forKey: "appear"), "\(text) doesn't fade in again")
        }
        XCTAssertNotNil(after["c"]?.animation(forKey: "bounds") ?? after["c"]?.animation(forKey: "position"), "existing cells slide")
        XCTAssertNotNil(after[""]?.animation(forKey: "appear"), "the new column fades in")
    }
}
#endif
