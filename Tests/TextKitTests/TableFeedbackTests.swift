#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMTextKit
import PMTables
import PMTableView
import PMExampleSetup

/// Text placement in cells, the selection outline, leaving a table at the document's end,
/// grips that stay while you reach for them, and range selections across a table.
@MainActor
final class TableFeedbackTests: XCTestCase {
    private let none = NSRange(location: NSNotFound, length: 0)
    private func host(_ h: TableHarness) throws -> TableHostView { try XCTUnwrap(h.grid.enclosingScrollView?.superview as? TableHostView) }

    private func p(_ t: String) -> JSONValue { J.p(t) }
    private func table(_ rows: [[String]]) -> JSONValue { J.table(rows) }
    private func harness(_ content: [JSONValue]) throws -> TableHarness { try TableHarness(try TestDocs.doc(content)) }

    private func key(_ view: NSView, _ chars: String, _ code: UInt16) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        view.keyDown(with: event)
    }

    // 2. A one-line cell is as tall as its font's line: no extra room above the text.
    func testCellTextIsNotPushedDown() throws {
        let h = try TableHarness.grid([["Groceries"]])
        let rendered = try XCTUnwrap(h.grid.renderedCell(at: (try TableMap.get(h.grid.table!)).map[0]))
        let font = try XCTUnwrap(rendered.string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let natural = ceil(font.ascender - font.descender + font.leading)
        XCTAssertEqual(rendered.height(forWidth: 200), natural, accuracy: 1.5)
    }

    // 3. Selected cells get one outline around the block, not one per cell doubling on shared edges.
    func testSelectionOutlineIsOneRect() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        try h.selectCells(0, 0, 1, 1)
        let overlay = try XCTUnwrap(h.grid.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.zPosition == 10 })
        let path = try XCTUnwrap(overlay.path)
        var rect = CGRect.zero
        XCTAssertTrue(path.isRect(&rect), "a single rectangle")
        let union = h.grid.selectedCellRects.reduce(CGRect.null) { $0.union($1) }
        XCTAssertEqual(rect.insetBy(dx: -h.grid.style.selectionOutline / 2, dy: -h.grid.style.selectionOutline / 2), union)
    }

    // 4a. Arrow down out of the last row of a table that ends the document makes a line to type on.
    func testArrowDownLeavesTableAtNoteEnd() throws {
        let h = try harness([p("above"), table([["a"], ["b"]])])
        let cell = try h.cellPos(1, 0)
        h.window.makeFirstResponder(h.view)
        h.dispatch(h.core.state.tr.setSelection(TextSelection.create(h.core.state.doc, cell + 3)))
        let editor = try XCTUnwrap(h.window.firstResponder as? ProseTextView)
        key(editor, String(UnicodeScalar(NSDownArrowFunctionKey)!), 125)
        h.settle()
        XCTAssertEqual(h.core.state.doc.lastChild?.type.name, "paragraph")
        XCTAssertEqual(h.core.state.selection.fromPos.parent.type.name, "paragraph")
        XCTAssertEqual(h.core.state.selection.from, h.core.state.doc.content.size - 1)
        XCTAssertTrue(h.window.firstResponder === h.view, "typing goes to the document")
    }

    // 4a'. The same from an empty cell of a table just inserted with insertTable.
    func testArrowDownLeavesInsertedTable() throws {
        let h = try harness([p("x")])
        h.view.undoCommand = { _, _, _ in true }
        h.window.makeFirstResponder(h.view)
        h.dispatch(h.core.state.tr.setSelection(TextSelection.create(h.core.state.doc, 2)))
        XCTAssertTrue(insertTable(schema: h.core.state.schema, rows: 3, cols: 3, headerRow: true)(h.core.state, h.core.dispatch, h.view))
        h.settle()
        h.settle()
        XCTAssertEqual(h.core.state.doc.lastChild?.type.name, "table")
        let cell = try h.cellPos(2, 2)
        // From the header row's first cell to a body cell: the editor's style changes too.
        h.dispatch(h.core.state.tr.setSelection(TextSelection.create(h.core.state.doc, cell + 2)))
        XCTAssertEqual(h.core.state.selection.head, cell + 2, "the selection stays where it was put")
        let editor = try XCTUnwrap(h.window.firstResponder as? ProseTextView)
        key(editor, String(UnicodeScalar(NSDownArrowFunctionKey)!), 125)
        h.settle()
        XCTAssertEqual(h.core.state.doc.lastChild?.type.name, "paragraph")
        XCTAssertTrue(h.window.firstResponder === h.view)
    }

    // 4b. Arrow right at the end of the last cell does the same.
    func testArrowRightLeavesTableAtNoteEnd() throws {
        let h = try harness([p("above"), table([["a", "b"]])])
        let cell = try h.cellPos(0, 1)
        h.window.makeFirstResponder(h.view)
        h.dispatch(h.core.state.tr.setSelection(TextSelection.create(h.core.state.doc, cell + 3)))
        let editor = try XCTUnwrap(h.window.firstResponder as? ProseTextView)
        key(editor, String(UnicodeScalar(NSRightArrowFunctionKey)!), 124)
        h.settle()
        XCTAssertEqual(h.core.state.doc.lastChild?.type.name, "paragraph")
        XCTAssertEqual(h.core.state.selection.from, h.core.state.doc.content.size - 1)
    }

    // 4c. A click below a table that ends the document makes a line there.
    func testClickBelowTableAtNoteEnd() throws {
        let h = try harness([p("above"), table([["a"], ["b"]])])
        let below = NSPoint(x: 100, y: h.view.bounds.height - 20)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: h.view.convert(below, to: nil), modifierFlags: [],
                                                     timestamp: 0, windowNumber: h.window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
        h.window.makeFirstResponder(h.view)
        XCTAssertTrue(h.view.clickBelowContent?(h.view, click) ?? false)
        h.settle()
        XCTAssertEqual(h.core.state.doc.lastChild?.type.name, "paragraph")
        XCTAssertEqual(h.core.state.selection.from, h.core.state.doc.content.size - 1)
    }

    // 5. Moving off the table towards a grip keeps the grips, and the row grip follows the
    // pointer up and down the margin.
    func testGripsStayWhileReachingForThem() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let host = try host(h)
        let delay = TableMotion.revealDelay
        TableMotion.revealDelay = 0
        defer { TableMotion.revealDelay = delay }
        func move(_ point: NSPoint) throws {
            host.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: h.grid.convert(point, to: nil), modifierFlags: [],
                                                                    timestamp: 0, windowNumber: h.window.windowNumber, context: nil,
                                                                    eventNumber: 0, clickCount: 0, pressure: 0)))
        }
        try move(NSPoint(x: 20, y: 10))
        XCTAssertGreaterThan(host.rowGrip.alphaValue, 0)
        // The pointer is tracked well past the grips, so they don't leave as you reach for them.
        host.updateTrackingAreas()
        for point in [NSPoint(x: -40, y: 10), NSPoint(x: 20, y: -40)] {
            let local = host.convert(point, from: h.grid)
            XCTAssertTrue(host.trackingAreas.contains { $0.rect.contains(local) }, "tracked at \(point)")
        }
        // Past the grip, into the margin.
        try move(NSPoint(x: -30, y: 10))
        XCTAssertGreaterThan(host.rowGrip.alphaValue, 0, "still there beside the table")
        XCTAssertEqual(host.rowGrip.kind, .row(0))
        try move(NSPoint(x: -30, y: h.grid.layout.rowY[1] + 5))
        XCTAssertEqual(host.rowGrip.kind, .row(1), "follows the pointer down the margin")
        // Above the table, the column grip follows along the top.
        try move(NSPoint(x: h.grid.layout.columnX[1] + 5, y: -12))
        XCTAssertGreaterThan(host.columnGrip.alphaValue, 0)
        XCTAssertEqual(host.columnGrip.kind, .column(1))
    }

    // 6. Selecting from the line below a table to the line above takes the table with it:
    // the selection survives, the document keeps focus, and the table shows as selected.
    func testRangeSelectionAcrossTable() throws {
        let h = try harness([p("above"), table([["a", "b"]]), p("below")])
        h.window.makeFirstResponder(h.view)
        let storage = try XCTUnwrap(h.view.textStorage?.string as NSString?)
        let below = storage.range(of: "below"), above = storage.range(of: "above")
        // As a drag from the end of "below" back to the middle of "above".
        h.view.setSelectedRange(NSRange(location: above.location + 2, length: below.upperBound - above.location - 2),
                                affinity: .upstream, stillSelecting: false)
        h.settle()
        let sel = h.core.state.selection
        XCTAssertTrue(sel is TextSelection)
        XCTAssertLessThan(sel.from, h.grid.tablePos)
        XCTAssertGreaterThan(sel.to, h.grid.tablePos + h.grid.table!.nodeSize)
        XCTAssertTrue(h.window.firstResponder === h.view, "the document keeps focus")
        XCTAssertEqual(h.grid.selectedCellRects.count, 2, "the table shows as selected")
        // Deleting takes the table too.
        h.view.deleteBackward(nil)
        XCTAssertEqual(h.core.state.doc.childCount, 1)
        XCTAssertEqual(h.core.state.doc.textContent, "ab")
    }

    // 6b. A drag whose top end lands on the table's own line still takes the table.
    func testRangeEndingOnTableLineIncludesTable() throws {
        let h = try harness([p("above"), table([["a", "b"]]), p("below")])
        h.window.makeFirstResponder(h.view)
        let storage = try XCTUnwrap(h.view.textStorage?.string as NSString?)
        let below = storage.range(of: "below"), attachment = storage.range(of: "\u{FFFC}")
        h.view.setSelectedRange(NSRange(location: attachment.location, length: below.upperBound - attachment.location),
                                affinity: .upstream, stillSelecting: false)
        XCTAssertLessThan(h.core.state.selection.from, h.grid.tablePos, "the table is in the range")
        XCTAssertEqual(h.grid.selectedCellRects.count, 2)
    }
}
#endif
