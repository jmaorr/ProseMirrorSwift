#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMTextKit
import PMTables
import PMTableView
import YSync

@MainActor
final class TableInteractionTests: XCTestCase {
    private func sel(_ h: TableHarness) throws -> CellSelection { try XCTUnwrap(h.core.state.selection as? CellSelection) }

    func testDragSelectsRectangle() throws {
        let h = try TableHarness.grid([["a", "b", "c"], ["d", "e", "f"]])
        h.grid.mouseDown(with: try h.mouse(.leftMouseDown, 0, 0))
        h.grid.mouseDragged(with: try h.mouse(.leftMouseDragged, 1, 1))
        h.grid.mouseUp(with: try h.mouse(.leftMouseUp, 1, 1))
        h.settle()
        let s = try sel(h)
        XCTAssertEqual(s.anchorCell.pos, try h.cellPos(0, 0))
        XCTAssertEqual(s.headCell.pos, try h.cellPos(1, 1))
        XCTAssertEqual(s.ranges.count, 4)
        XCTAssertTrue(h.window.firstResponder === h.grid)
    }

    func testShiftClickExtends() throws {
        let h = try TableHarness.grid([["a", "b", "c"], ["d", "e", "f"]])
        h.dispatch(h.core.state.tr.setSelection(TextSelection.create(h.core.state.doc, try h.cellPos(0, 1) + 2)))
        h.grid.mouseDown(with: try h.mouse(.leftMouseDown, 1, 2, flags: .shift))
        h.settle()
        let s = try sel(h)
        XCTAssertEqual(s.anchorCell.pos, try h.cellPos(0, 1))
        XCTAssertEqual(s.headCell.pos, try h.cellPos(1, 2))
    }

    func testArrowsMoveSelection() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        try h.selectCells(0, 0, 0, 0)
        h.key(h.grid, tableArrowKeys["right"]!.0, tableArrowKeys["right"]!.1, [.function])
        XCTAssertEqual(try sel(h).anchorCell.pos, try h.cellPos(0, 1))
        h.key(h.grid, tableArrowKeys["down"]!.0, tableArrowKeys["down"]!.1, [.function])
        XCTAssertEqual(try sel(h).anchorCell.pos, try h.cellPos(1, 1))
        XCTAssertEqual(try sel(h).ranges.count, 1)
    }

    func testShiftArrowsExtend() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        try h.selectCells(0, 0, 0, 0)
        h.key(h.grid, tableArrowKeys["right"]!.0, tableArrowKeys["right"]!.1, [.function, .shift])
        h.key(h.grid, tableArrowKeys["down"]!.0, tableArrowKeys["down"]!.1, [.function, .shift])
        let s = try sel(h)
        XCTAssertEqual(s.anchorCell.pos, try h.cellPos(0, 0))
        XCTAssertEqual(s.headCell.pos, try h.cellPos(1, 1))
    }

    func testTypingReplacesCell() throws {
        let h = try TableHarness.grid([["abc", "b"], ["c", "d"]])
        try h.selectCells(0, 0, 0, 0)
        h.key(h.grid, "x", 7)
        XCTAssertEqual(try h.text(0, 0), "x")
        XCTAssertEqual(h.core.state.selection.from, try h.cellPos(0, 0) + 3)
        XCTAssertTrue(h.window.firstResponder === h.grid.editor)
    }

    func testReturnEditsAtEnd() throws {
        let h = try TableHarness.grid([["abc", "b"], ["c", "d"]])
        try h.selectCells(0, 0, 0, 0)
        h.key(h.grid, "\r", 36)
        XCTAssertEqual(try h.text(0, 0), "abc")
        XCTAssertEqual(h.core.state.selection.from, try h.cellPos(0, 0) + 5)
        XCTAssertTrue(h.window.firstResponder === h.grid.editor)
    }

    func testBackspaceClearsCells() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        try h.selectCells(0, 0, 0, 1)
        h.key(h.grid, "\u{7f}", 51)
        XCTAssertEqual(try h.text(0, 0), "")
        XCTAssertEqual(try h.text(0, 1), "")
        XCTAssertEqual(try h.text(1, 0), "c")
    }

    func testBackspaceAllCellsDeletesTableWhenAsked() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        h.grid.deletesTableWhenAllSelected = true
        try h.selectCells(0, 0, 1, 1)
        h.key(h.grid, "\u{7f}", 51)
        XCTAssertEqual(h.core.state.doc.childCount, 2)
        XCTAssertTrue(h.core.state.doc.children.allSatisfy { $0.type.name == "paragraph" })
    }

    func testEscapeLadder() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        try h.selectCells(0, 1, 0, 1)
        h.key(h.grid, "\u{1b}", 53)
        let all = try sel(h)
        XCTAssertTrue(all.isRowSelection() && all.isColSelection())
        h.key(h.grid, "\u{1b}", 53)
        XCTAssertTrue(h.core.state.selection is TextSelection)
        XCTAssertEqual(h.core.state.selection.from, h.grid.tablePos + h.grid.table!.nodeSize + 1, "caret in the paragraph after")
        XCTAssertTrue(h.window.firstResponder === h.view)
    }

    func testOverlayFramesMatchSelection() throws {
        let h = try TableHarness.grid([["a", "b", "c"], ["d", "e", "f"]])
        try h.selectCells(0, 1, 1, 2)
        let expected = try [(0, 1), (0, 2), (1, 1), (1, 2)].map { h.grid.layout.cellRect(pos: try h.cellPos($0.0, $0.1) - h.grid.tableStart)! }
        XCTAssertEqual(Set(h.grid.selectedCellRects.map { "\($0)" }), Set(expected.map { "\($0)" }))
        h.dispatch(h.core.state.tr.setSelection(TextSelection.create(h.core.state.doc, 2)))
        XCTAssertTrue(h.grid.selectedCellRects.isEmpty)
    }
}

@MainActor
final class TableMenuTests: XCTestCase {
    private func item(_ items: [NSMenuItem], _ title: String) throws -> NSMenuItem {
        try XCTUnwrap(items.first { $0.title == title }, "no item \(title) in \(items.map(\.title))")
    }

    private func click(_ item: NSMenuItem) { _ = item.target?.perform(item.action, with: item) }

    func testMenuEnablement() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        try h.selectCells(0, 0, 1, 0)
        var items = h.grid.tableMenuItems(for: h.core.state)
        XCTAssertTrue(try item(items, "Merge Cells").isEnabled)
        XCTAssertFalse(try item(items, "Split Cell").isEnabled)
        XCTAssertEqual(try item(items, "Header Row").state, .off)
        click(try item(items, "Merge Cells"))
        h.settle()
        items = h.grid.tableMenuItems(for: h.core.state)
        XCTAssertTrue(try item(items, "Split Cell").isEnabled)
        XCTAssertFalse(try item(items, "Merge Cells").isEnabled)
        click(try item(items, "Header Row"))
        h.settle()
        XCTAssertEqual(try item(h.grid.tableMenuItems(for: h.core.state), "Header Row").state, .on)
    }

    func testMenuTitlesCountSelection() throws {
        let h = try TableHarness.grid([["a", "b", "c"], ["d", "e", "f"], ["g", "h", "i"]])
        try h.selectCells(0, 0, 2, 1)
        let titles = h.grid.tableMenuItems(for: h.core.state).map(\.title)
        XCTAssertTrue(titles.contains("Delete 3 Rows"))
        XCTAssertTrue(titles.contains("Delete 2 Columns"))
        try h.selectCells(1, 2, 1, 2)
        let one = h.grid.tableMenuItems(for: h.core.state).map(\.title)
        XCTAssertTrue(one.contains("Delete Row"))
        XCTAssertTrue(one.contains("Delete Column"))
    }

    func testMenuItemsRunCommandsOnRightRect() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"], ["e", "f"]])
        try h.selectCells(1, 0, 2, 1)
        click(try item(h.grid.tableMenuItems(for: h.core.state), "Delete 2 Rows"))
        h.settle()
        XCTAssertEqual(h.grid.table?.childCount, 1)
        XCTAssertEqual(try h.text(0, 0), "a")
    }

    func testShortcuts() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        try h.selectCells(0, 0, 0, 0)
        h.key(h.grid, String(UnicodeScalar(NSDownArrowFunctionKey)!), 125, [.option, .function])
        XCTAssertEqual(h.grid.table?.childCount, 3)
        h.key(h.grid, String(UnicodeScalar(NSRightArrowFunctionKey)!), 124, [.option, .function])
        XCTAssertEqual((try TableMap.get(h.grid.table!)).width, 3)
        try h.selectCells(0, 0, 0, 1)
        h.key(h.grid, "µ", 46, [.option, .command])
        XCTAssertEqual(h.grid.table?.child(0).childCount, 2, "first two cells merged into one, third remains")
        try h.selectCells(2, 0, 2, 2)
        h.key(h.grid, "\u{7f}", 51, [.command])
        XCTAssertEqual(h.grid.table?.childCount, 2)
    }

    func testCopyWritesSliceAndText() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let board = NSPasteboard(name: NSPasteboard.Name("table-tests-\(UUID().uuidString)"))
        h.view.pasteboard = board
        h.grid.cellsPasteboardWriter = { _ in [NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text"): "a\tb"] }
        try h.selectCells(0, 0, 0, 1)
        h.grid.copy(nil)
        XCTAssertNotNil(board.string(forType: ProseTextView.sliceType))
        XCTAssertEqual(board.string(forType: NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text")), "a\tb")
        XCTAssertNotNil(board.string(forType: .string))
        board.releaseGlobally()
    }

    func testPasteCellsGrowsTable() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let board = NSPasteboard(name: NSPasteboard.Name("table-tests-\(UUID().uuidString)"))
        h.view.pasteboard = board
        try h.selectCells(0, 0, 1, 1)
        h.grid.copy(nil)
        try h.selectCells(1, 1, 1, 1)
        h.dispatch(h.core.state.tr.setSelection(TextSelection.create(h.core.state.doc, try h.cellPos(1, 1) + 2)))
        XCTAssertTrue(h.grid.pasteCells(from: board))
        h.settle()
        let map = try TableMap.get(h.grid.table!)
        XCTAssertEqual(map.width, 3)
        XCTAssertEqual(map.height, 3)
        XCTAssertEqual(try h.text(2, 2), "d")
        board.releaseGlobally()
    }

    func testRightClickKeepsCellSelection() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        try h.selectCells(0, 0, 1, 1)
        let menu = h.grid.menu(for: try h.mouse(.rightMouseDown, 1, 0))
        XCTAssertNotNil(menu)
        let s = try XCTUnwrap(h.core.state.selection as? CellSelection)
        XCTAssertEqual(s.ranges.count, 4)
    }
}

@MainActor
final class TableManipulationTests: XCTestCase {
    private func host(_ h: TableHarness) throws -> TableHostView { try h.host() }

    private func countingDispatches(_ h: TableHarness) -> () -> Int {
        var count = 0
        let previous = h.core.onChange
        h.core.onChange = { state, tr in
            if tr?.docChanged == true { count += 1 }
            previous?(state, tr)
        }
        return { count }
    }

    func testGripClickSelectsRowColumnTable() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let host = try host(h)
        let rect = h.grid.layout.cellRect(pos: try h.cellPos(1, 1) - h.grid.tableStart)!
        h.grid.hover(at: NSPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(host.rowGrip.kind, .row(1))
        XCTAssertEqual(host.columnGrip.kind, .column(1))
        host.rowGrip.mouseDown(with: try h.mouse(.leftMouseDown, 1, 1))
        host.rowGrip.mouseUp(with: try h.mouse(.leftMouseUp, 1, 1))
        var sel = try XCTUnwrap(h.core.state.selection as? CellSelection)
        XCTAssertTrue(sel.isRowSelection())
        XCTAssertEqual(sel.ranges.count, 2)
        host.columnGrip.mouseDown(with: try h.mouse(.leftMouseDown, 1, 1))
        host.columnGrip.mouseUp(with: try h.mouse(.leftMouseUp, 1, 1))
        sel = try XCTUnwrap(h.core.state.selection as? CellSelection)
        XCTAssertTrue(sel.isColSelection())
        host.tableGrip.mouseDown(with: try h.mouse(.leftMouseDown, 0, 0))
        host.tableGrip.mouseUp(with: try h.mouse(.leftMouseUp, 0, 0))
        sel = try XCTUnwrap(h.core.state.selection as? CellSelection)
        XCTAssertTrue(sel.isRowSelection() && sel.isColSelection())
    }

    func testEdgePlusAddsRowAndColumn() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let host = try host(h)
        host.addRowButton.mouseDown(with: try h.mouse(.leftMouseDown, 1, 1))
        host.addRowButton.mouseUp(with: try h.mouse(.leftMouseUp, 1, 1))
        XCTAssertEqual(h.grid.table?.childCount, 3)
        host.addColumnButton.mouseDown(with: try h.mouse(.leftMouseDown, 1, 1))
        host.addColumnButton.mouseUp(with: try h.mouse(.leftMouseUp, 1, 1))
        XCTAssertEqual((try TableMap.get(h.grid.table!)).width, 3)
    }

    func testResizePreviewIsViewOnly() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let changes = countingDispatches(h)
        let before = h.grid.layout.columnWidths[0]
        h.grid.beginResize(border: 1)
        h.grid.updateResize(delta: 60)
        XCTAssertEqual(h.grid.layout.columnWidths[0], before + 60)
        XCTAssertEqual(changes(), 0)
    }

    func testResizeCommitsOneTransaction() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let changes = countingDispatches(h)
        h.grid.beginResize(border: 1)
        h.grid.updateResize(delta: -40)
        h.grid.updateResize(delta: -80)
        h.grid.endResize()
        XCTAssertEqual(changes(), 1)
        let first = h.grid.table!.child(0).child(0)
        XCTAssertEqual(first.attrs["colwidth"]?.arrayValue?.first?.numberValue, Double(Int((h.grid.layout.columnWidths[0]).rounded())))
        XCTAssertEqual(h.grid.table!.child(1).child(0).attrs["colwidth"], first.attrs["colwidth"])
    }

    func testResizeClampsTo48() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        h.grid.beginResize(border: 1)
        h.grid.updateResize(delta: -1000)
        h.grid.endResize()
        XCTAssertEqual(h.grid.table!.child(0).child(0).attrs["colwidth"]?.arrayValue?.first?.numberValue, 48)
    }

    func testDoubleClickBorderFits() throws {
        let h = try TableHarness.grid([["short", "b"], ["a much longer cell text", "d"]])
        h.grid.fitColumn(border: 1)
        let width = try XCTUnwrap(h.grid.table!.child(0).child(0).attrs["colwidth"]?.arrayValue?.first?.numberValue)
        XCTAssertGreaterThan(width, 120)
        XCTAssertLessThan(width, 260)
        let rel = try h.cellPos(1, 0) - h.grid.tableStart
        XCTAssertEqual(h.grid.renderedCell(at: rel)?.height(forWidth: h.grid.layout.columnWidths[0] - 20), h.grid.renderedCell(at: try h.cellPos(0, 0) - h.grid.tableStart)?.height(forWidth: 100), "fits on one line")
    }

    func testEscapeCancelsResize() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let changes = countingDispatches(h)
        let before = h.grid.layout.columnWidths
        h.grid.beginResize(border: 1)
        h.grid.updateResize(delta: 70)
        h.key(h.grid, "\u{1b}", 53)
        XCTAssertNil(h.grid.resizing)
        XCTAssertEqual(h.grid.layout.columnWidths, before)
        XCTAssertEqual(changes(), 0)
    }

    func testGestureBoundaryCalledTwice() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        var boundaries = 0
        h.grid.onGestureBoundary = { boundaries += 1 }
        h.grid.beginResize(border: 1)
        h.grid.updateResize(delta: 30)
        h.grid.endResize()
        XCTAssertEqual(boundaries, 2)
        h.grid.addRowAtEnd()
        XCTAssertEqual(boundaries, 4)
    }

    func testResizeThroughMouse() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let x = h.grid.layout.columnX[1]
        func event(_ type: NSEvent.EventType, _ px: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: h.grid.convert(NSPoint(x: px, y: 10), to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let before = h.grid.layout.columnWidths[0]
        h.grid.mouseDown(with: event(.leftMouseDown, x))
        h.grid.mouseDragged(with: event(.leftMouseDragged, x + 25))
        h.grid.mouseUp(with: event(.leftMouseUp, x + 25))
        XCTAssertEqual(h.grid.table!.child(0).child(0).attrs["colwidth"]?.arrayValue?.first?.numberValue, Double(Int((before + 25).rounded())))
    }
}

@MainActor
final class TableDragTests: XCTestCase {
    override func tearDown() { TableMotion.reduceMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } }

    private func column(_ h: TableHarness, _ col: Int) throws -> [String] {
        let map = try TableMap.get(h.grid.table!)
        return try (0..<map.height).map { try h.text($0, col) }
    }

    func testDragRowCommitsOneMove() throws {
        let h = try TableHarness.grid([["a", "1"], ["b", "2"], ["c", "3"]])
        var docChanges = 0
        h.core.onChange = { _, tr in if tr?.docChanged == true { docChanges += 1 } }
        h.grid.beginDrag(row: 0)
        let heights = h.grid.layout.rowHeights
        for step in 1...10 { h.grid.updateDrag(offset: CGFloat(step) * (heights[1] + 2) / 10) }
        XCTAssertEqual(docChanges, 0, "dragging is view-only")
        XCTAssertEqual(h.grid.dragging?.target, 1)
        h.grid.endDrag()
        h.settle()
        XCTAssertEqual(docChanges, 1)
        XCTAssertEqual(try column(h, 0), ["b", "a", "c"])
        XCTAssertEqual(try column(h, 1), ["2", "1", "3"])
    }

    func testDragSelectedRowsMovesTogether() throws {
        let h = try TableHarness.grid([["a"], ["b"], ["c"], ["d"]])
        try h.selectCells(0, 0, 1, 0)
        h.grid.beginDrag(row: 1)
        XCTAssertEqual(h.grid.dragging?.from, 0...1)
        let y = h.grid.layout.rowY
        h.grid.updateDrag(offset: y[4] - y[2] + h.grid.layout.rowHeights[3] / 2 + 2)
        XCTAssertEqual(h.grid.dragging?.target, 2)
        h.grid.endDrag()
        XCTAssertEqual(try column(h, 0), ["c", "d", "a", "b"])
    }

    func testRefusedDropSnapsBack() throws {
        // A cell spanning rows 0-1 ties them: moving row 2 between them is refused.
        func c(_ t: String, rowspan: Int = 1) -> JSONValue { TableJ.textCell(t, rowspan: rowspan) }
        let doc = try TestDocs.doc([TableJ.table([[c("tall", rowspan: 2), c("x")], [c("y")], [c("z1"), c("z2")]])])
        let h = try TableHarness(doc)
        let before = h.core.state.doc
        // Row 0 can't move to index 1: the tall cell ties rows 0 and 1 together.
        h.grid.beginDrag(row: 0)
        h.grid.updateDrag(offset: h.grid.layout.rowHeights[1] + 2)
        XCTAssertEqual(h.grid.dragging?.target, 1)
        h.grid.endDrag()
        XCTAssertTrue(h.core.state.doc.eq(before), "refused move leaves the table alone")
        for layer in h.grid.dragLayers(0...2, isRow: true) { XCTAssertTrue(CATransform3DIsIdentity(layer.transform)) }
    }

    func testEscapeCancelsDrag() throws {
        let h = try TableHarness.grid([["a"], ["b"], ["c"]])
        let before = h.core.state.doc
        h.window.makeFirstResponder(h.grid)
        h.grid.beginDrag(row: 0)
        h.grid.updateDrag(offset: 200)
        h.key(h.grid, "\u{1b}", 53)
        XCTAssertNil(h.grid.dragging)
        XCTAssertTrue(h.core.state.doc.eq(before))
        for layer in h.grid.dragLayers(0...2, isRow: true) { XCTAssertTrue(CATransform3DIsIdentity(layer.model().transform)) }
    }

    func testReduceMotionUsesCrossFade() throws {
        TableMotion.reduceMotion = { true }
        let h = try TableHarness.grid([["a"], ["b"], ["c"]])
        h.grid.beginDrag(row: 0)
        h.grid.updateDrag(offset: 200)
        for layer in h.grid.dragLayers(1...2, isRow: true) {
            XCTAssertTrue(CATransform3DIsIdentity(layer.transform), "other rows don't slide")
            XCTAssertNil(layer.animation(forKey: "transform"))
        }
        h.grid.cancelDrag()
    }

    func testRemoteInsertAnimates() throws {
        let h = try TableHarness.grid([["a"], ["b"]])
        let map = try TableMap.get(h.grid.table!)
        let rect = SelectedRect(rect: try map.findCell(map.map[1]), map: map, tableStart: h.grid.tableStart, table: h.grid.table!)
        let tr = try addRow(h.core.state.tr, rect, 2)
        _ = tr.setMeta("y-sync$remote", true)
        h.dispatch(tr)
        let newMap = try TableMap.get(h.grid.table!)
        let layer = try XCTUnwrap(h.grid.cellLayer(at: newMap.map[2]))
        XCTAssertNotNil(layer.animation(forKey: "appear"))
        XCTAssertNil(h.grid.cellLayer(at: newMap.map[0])?.animation(forKey: "appear"))
    }

    func testGestureIsOneUndoStep() throws {
        let h = try TableHarness.grid([["one"], ["two"]], textAfter: false)
        let ydoc = YDocument(clientID: 7)
        let binding = YSyncBinding(doc: ydoc, schema: h.core.state.schema)
        binding.enableUndo()
        binding.seed(h.core.state.doc)
        h.core.onChange = { state, tr in binding.localStateChanged(state, tr) }
        h.grid.onGestureBoundary = { binding.stopCapturing() }
        func pull() { if let tr = binding.remoteTransaction(h.core.state) { h.dispatch(tr) } }
        h.dispatch(try h.core.state.tr.insertText("ab", try h.cellPos(1, 0) + 5))
        XCTAssertEqual(try column(h, 0), ["one", "twoab"])
        h.grid.beginDrag(row: 1)
        h.grid.updateDrag(offset: -h.grid.layout.rowY[1] - 2)
        h.grid.endDrag()
        XCTAssertEqual(try column(h, 0), ["twoab", "one"])
        binding.undo(); pull()
        XCTAssertEqual(try column(h, 0), ["one", "twoab"], "first undo reverts just the move")
        binding.undo(); pull()
        XCTAssertEqual(try column(h, 0), ["one", "two"], "second undo reverts the typing")
    }
}
#endif
