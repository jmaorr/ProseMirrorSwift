#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMTextKit
import PMTables
import PMTableView
import PMExampleSetup
import YSync

@MainActor
final class TableEditingTests: XCTestCase {

    /// p("above"), 2×2 table ("a" "b" / "c" "d"), and p("below") unless `textAfter` is false.
    private func harness(textAfter: Bool = true, rows: [[String]] = [["a", "b"], ["c", "d"]]) throws -> TableHarness {
        try TableHarness.grid(rows, textAfter: textAfter)
    }

    /// Absolute position before cell (row, col).
    private func cellPos(_ h: TableHarness, _ row: Int, _ col: Int) throws -> Int {
        let map = try TableMap.get(h.grid.table!)
        return h.grid.tableStart + map.map[row * map.width + col]
    }

    private func text(_ h: TableHarness, _ row: Int, _ col: Int) throws -> String {
        h.core.state.doc.nodeAt(try cellPos(h, row, col))!.textContent
    }

    /// Caret at the end of cell (row, col)'s text, and the editor focused there.
    private func caret(_ h: TableHarness, _ row: Int, _ col: Int, atStart: Bool = false) throws {
        let pos = try cellPos(h, row, col)
        let node = h.core.state.doc.nodeAt(pos)!
        let target = atStart ? pos + 2 : pos + node.nodeSize - 2
        h.window.makeFirstResponder(h.view)
        h.dispatch(h.core.state.tr.setSelection(TextSelection.create(h.core.state.doc, target)))
    }

    private func key(_ view: NSView, _ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        view.keyDown(with: event)
    }

    private func editor(_ h: TableHarness) throws -> ProseTextView { try XCTUnwrap(h.grid.editor) }

    func testClickEditsCell() throws {
        let h = try harness()
        let rel = try cellPos(h, 0, 1) - h.grid.tableStart
        let rect = try XCTUnwrap(h.grid.layout.cellRect(pos: rel))
        let inWindow = h.grid.convert(NSPoint(x: rect.maxX - 5, y: rect.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        h.grid.mouseDown(with: event)
        h.settle()
        let editor = try editor(h)
        XCTAssertFalse(editor.isHidden)
        XCTAssertEqual(editor.scope, try cellPos(h, 0, 1))
        XCTAssertTrue(h.window.firstResponder === editor)
        XCTAssertEqual(h.core.state.selection.from, try cellPos(h, 0, 1) + 3, "caret after the cell's text")
        XCTAssertTrue(h.grid.cellLayer(at: rel)?.hidesText ?? false, "static text hidden under the editor")
    }

    func testTabMovesAndSelectsNextCell() throws {
        let h = try harness()
        try caret(h, 0, 0)
        let editor = try editor(h)
        XCTAssertTrue(h.window.firstResponder === editor, "focus followed the selection into the cell")
        key(editor, "\t", 48)
        h.settle()
        let next = try cellPos(h, 0, 1)
        XCTAssertEqual(editor.scope, next)
        XCTAssertEqual(h.core.state.selection.from, next + 2)
        XCTAssertEqual(h.core.state.selection.to, next + 3)
    }

    func testReturnAddsParagraphInCell() throws {
        let h = try harness()
        try caret(h, 0, 0)
        key(try editor(h), "\r", 36)
        let cell = h.core.state.doc.nodeAt(try cellPos(h, 0, 0))!
        XCTAssertEqual(cell.childCount, 2)
        XCTAssertEqual(try editor(h).textStorage?.string, "a\n\n")
    }

    func testArrowDownFromLastLineGoesToCellBelow() throws {
        let h = try harness()
        try caret(h, 0, 1)
        key(try editor(h), String(UnicodeScalar(NSDownArrowFunctionKey)!), 125, [.numericPad, .function])
        h.settle()
        let below = try cellPos(h, 1, 1)
        XCTAssertGreaterThan(h.core.state.selection.from, below)
        XCTAssertLessThan(h.core.state.selection.from, below + 4)
        XCTAssertEqual(try editor(h).scope, below)
    }

    func testArrowOffBottomCreatesParagraph() throws {
        let h = try harness(textAfter: false)
        try caret(h, 1, 0)
        key(try editor(h), String(UnicodeScalar(NSDownArrowFunctionKey)!), 125, [.numericPad, .function])
        h.settle()
        let doc = h.core.state.doc
        XCTAssertEqual(doc.childCount, 3)
        XCTAssertEqual(doc.lastChild?.type.name, "paragraph")
        XCTAssertEqual(h.core.state.selection.from, doc.content.size - 1)
        XCTAssertTrue(try editor(h).isHidden)
        XCTAssertTrue(h.window.firstResponder === h.view, "focus back in the document")
    }

    func testEscapeSelectsCell() throws {
        let h = try harness()
        try caret(h, 1, 1)
        key(try editor(h), "\u{1b}", 53)
        h.settle()
        let sel = try XCTUnwrap(h.core.state.selection as? CellSelection)
        XCTAssertEqual(sel.anchorCell.pos, try cellPos(h, 1, 1))
        XCTAssertTrue(h.window.firstResponder === h.grid)
    }

    func testCommandAWalksCellTableDoc() throws {
        let h = try harness(rows: [["one two", "b"], ["c", "d"]])
        try caret(h, 0, 0)
        let editor = try editor(h)
        XCTAssertTrue(editor.run(selectAllInTable))
        XCTAssertEqual(h.core.state.selection.to - h.core.state.selection.from, 7, "the cell's text")
        XCTAssertTrue(editor.run(selectAllInTable))
        let all = try XCTUnwrap(h.core.state.selection as? CellSelection)
        XCTAssertTrue(all.isRowSelection() && all.isColSelection())
        XCTAssertTrue(h.grid.editor?.isHidden ?? true)
        XCTAssertTrue(selectAllInTable(h.core.state, h.core.dispatch, nil))
        XCTAssertTrue(h.core.state.selection is AllSelection)
    }

    /// A composition open when focus moves lands in its own cell.
    func testCompositionCommittedBeforeTab() throws {
        let h = try harness()
        try caret(h, 0, 0)
        let editor = try editor(h)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.composing)
        editor.run(goToNextCell(1))
        h.settle()
        XCTAssertEqual(try text(h, 0, 0), "ani")
        XCTAssertEqual(try text(h, 0, 1), "b")
        XCTAssertEqual(h.core.state.doc.child(0).textContent, "above")
        XCTAssertEqual(h.core.state.doc.child(2).textContent, "below")
    }

    func testRemoteDeleteOfActiveCellMovesFocus() throws {
        let h = try harness()
        try caret(h, 1, 0)
        let table = h.grid.table!
        let rowStart = h.grid.tableStart + table.child(0).nodeSize
        let tr = try h.core.state.tr.delete(rowStart, rowStart + table.child(1).nodeSize)
        _ = tr.setMeta(YSyncBinding.remoteMeta, true)
        h.dispatch(tr)
        XCTAssertEqual(h.grid.table?.childCount, 1)
        XCTAssertEqual(try text(h, 0, 0), "a")
        XCTAssertEqual(try text(h, 0, 1), "b")
        let editor = try editor(h)
        if let cell = cellAround(h.core.state.selection.fromPos) {
            XCTAssertEqual(editor.scope, cell.pos)
            XCTAssertFalse(editor.isHidden)
        } else {
            XCTAssertTrue(editor.isHidden)
        }
        XCTAssertEqual(h.core.state.doc.child(2).textContent, "below")
    }

    /// Switching a cell from its static drawing to the editor doesn't move the text: the editor
    /// sits at the cell's padding, and every character lands where the static drawing put it.
    func testStaticAndEditingTextLineUp() throws {
        let h = try harness(rows: [["Some text in a cell that wraps onto a second line, and a third if it can", "b"], ["c", "d"]])
        let rel = try cellPos(h, 0, 0) - h.grid.tableStart
        let layer = try XCTUnwrap(h.grid.cellLayer(at: rel))
        let rendered = try XCTUnwrap(h.grid.renderedCell(at: rel))
        try caret(h, 0, 0, atStart: true)
        let editor = try editor(h)
        XCTAssertEqual(editor.frame.origin.x, layer.frame.minX + h.grid.style.cellPadding.left)
        XCTAssertEqual(editor.frame.origin.y, layer.frame.minY + h.grid.style.cellPadding.top)
        XCTAssertEqual(editor.frame.width, rendered.text.width)
        let tlm = try XCTUnwrap(editor.textLayoutManager)
        for offset in [0, 10, 40, 70] {
            let start = tlm.textContentManager!.location(tlm.documentRange.location, offsetBy: offset)!
            let range = NSTextRange(location: start, end: tlm.textContentManager!.location(start, offsetBy: 1)!)!
            var editorRect = CGRect.null
            tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, r, _, _ in editorRect = r; return false }
            let staticRect = try XCTUnwrap(rendered.rects(for: NSRange(location: offset, length: 1)).first)
            XCTAssertEqual(editorRect.minX, staticRect.minX, accuracy: 0.5, "offset \(offset)")
            XCTAssertEqual(editorRect.minY, staticRect.minY, accuracy: 0.5, "offset \(offset)")
        }
    }

    func testEditorFollowsHorizontalScroll() throws {
        let cells = (0..<12).map { TableJ.textCell("c\($0)", colwidth: [120]) }
        let h = try TableHarness(try TestDocs.doc([TableJ.table([cells])]), width: 600)
        h.grid.scroll(NSPoint(x: 600, y: 0))
        try caret(h, 0, 6)
        let editor = try editor(h)
        let rel = try cellPos(h, 0, 6) - h.grid.tableStart
        XCTAssertEqual(editor.frame.minX, h.grid.layout.cellRect(pos: rel)!.minX + h.grid.style.cellPadding.left)
        XCTAssertTrue(h.grid.visibleRect.intersects(editor.frame))
    }

    func testCodeBlockInCellIsReadOnly() throws {
        let h = try TableHarness(try TestDocs.doc([TableJ.table([[TableJ.cell([J.code("let x = 1")]), TableJ.textCell("b")]])]))
        try caret(h, 0, 0)
        XCTAssertFalse(try editor(h).isEditable)
        try caret(h, 0, 1)
        XCTAssertTrue(try editor(h).isEditable)
    }

    func testTypingPerformance50x12() throws {
        let rows = (0..<50).map { r in (0..<12).map { "r\(r)c\($0)" } }
        let h = try harness(rows: rows)
        try caret(h, 25, 6)
        let editor = try editor(h)
        let none = NSRange(location: NSNotFound, length: 0)
        let start = Date()
        for ch in "typing in a big table, fifty chars long, measured" { editor.insertText(String(ch), replacementRange: none) }
        let perKey = Date().timeIntervalSince(start) / 50
        XCTAssertTrue(try text(h, 25, 6).hasSuffix("measured"))
        print("TABLE PERF 50x12: \(String(format: "%.2f", perKey * 1000)) ms per keystroke")
        XCTAssertLessThan(perKey, 0.008)
    }
}
#endif
