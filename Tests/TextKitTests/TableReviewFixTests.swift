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

/// Collaboration, composition and stale-state cases in tables, each once a bug.
@MainActor
final class TableReviewFixTests: XCTestCase {
    private let none = NSRange(location: NSNotFound, length: 0)

    /// A harness bound to Yjs, with a second Yjs peer (a collaborator) in sync.
    private final class Collab {
        let h: TableHarness
        let binding: YSyncBinding
        let ydoc = YDocument(clientID: 1)
        let peerDoc = YDocument(clientID: 2)
        let peer: YSyncBinding
        var peerState: EditorState

        @MainActor init(_ h: TableHarness) {
            self.h = h
            binding = YSyncBinding(doc: ydoc, schema: h.core.state.schema)
            binding.enableUndo()
            binding.seed(h.core.state.doc)
            peer = YSyncBinding(doc: peerDoc, schema: h.core.state.schema)
            peerState = EditorState.create(EditorStateConfig(schema: h.core.state.schema))
            _ = peerDoc.applyUpdate(ydoc.encodeStateAsUpdate(), origin: "remote")
            if let tr = peer.remoteTransaction(peerState) { peerState = peerState.apply(tr) }
            let core = h.core
            let binding = binding
            let previous = core.onChange
            // As an app writing local changes to Yjs does.
            core.onChange = { state, tr in
                binding.localStateChanged(state, tr)
                if let tr, tr.doc !== state.doc, !tr.docChanged || tr.getMeta(YSyncBinding.remoteMeta) != nil {
                    binding.localStateChanged(state, nil, undoable: false)
                }
                previous?(state, tr)
            }
        }

        /// The collaborator makes an edit; it arrives here and is pulled as the app does.
        @MainActor func remote(_ edit: (EditorState) throws -> Transaction) throws {
            let before = peerDoc.encodeStateVector()
            let tr = try edit(peerState)
            peerState = peerState.apply(tr)
            peer.localStateChanged(peerState, tr)
            XCTAssertTrue(ydoc.applyUpdate(peerDoc.encodeStateAsUpdate(before), origin: "remote"))
            pull()
        }

        /// As an app does: a remote change waits while any view (a cell editor too) composes.
        @MainActor func pull() {
            if h.view.composing || h.tables.composing { return }
            if let tr = binding.remoteTransaction(h.core.state) { h.dispatch(tr) }
        }
    }

    private func type(_ h: TableHarness, _ text: String) {
        for ch in text { (h.window.firstResponder as? NSTextView)?.insertText(String(ch), replacementRange: none) }
        h.settle()
    }

    private func caretInCell(_ h: TableHarness, _ row: Int, _ col: Int) throws {
        let pos = try h.cellPos(row, col)
        h.window.makeFirstResponder(h.view)
        h.dispatch(h.core.state.tr.setSelection(TextSelection.create(h.core.state.doc, pos + h.core.state.doc.nodeAt(pos)!.nodeSize - 2)))
    }

    // C1: a remote change anywhere must not orphan the grid or push focus out of the cell.
    func testRemoteChangeElsewhereKeepsCellEditing() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let c = Collab(h)
        try caretInCell(h, 1, 0)
        XCTAssertTrue(h.window.firstResponder === h.grid.editor)
        try c.remote { state in try state.tr.insertText("X", state.doc.content.size - 1) }
        XCTAssertEqual(h.core.state.doc.lastChild?.textContent, "belowX")
        XCTAssertEqual(h.tables.grids.count, 1)
        XCTAssertTrue(h.window.firstResponder === h.grid.editor, "the cell editor kept focus")
        type(h, "Z")
        XCTAssertEqual(try h.text(1, 0), "cZ")
        XCTAssertEqual(h.core.state.doc.lastChild?.textContent, "belowX")
    }

    // C1 (undo path): a Yjs undo is a remote-shaped pull too.
    func testUndoPullKeepsGrid() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let c = Collab(h)
        try caretInCell(h, 0, 0)
        type(h, "q")
        c.binding.stopCapturing()
        c.binding.undo()
        c.pull()
        XCTAssertEqual(try h.text(0, 0), "a")
        XCTAssertEqual(h.tables.grids.count, 1)
        try caretInCell(h, 0, 1)
        type(h, "w")
        XCTAssertEqual(try h.text(0, 1), "bw")
    }

    // C2: a remote change while composing in a cell must not crash; the app holds it.
    func testRemoteChangeDuringCellCompositionDoesNotCrash() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        let c = Collab(h)
        try caretInCell(h, 0, 0)
        let editor = try XCTUnwrap(h.grid.editor)
        // As an app does: a held pull runs when the composition ends, before its text applies.
        var held = false
        editor.onCompositionEnd = { if held { held = false; if let tr = c.binding.remoteTransaction(h.core.state) { h.core.dispatch(tr) } } }
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
        XCTAssertTrue(h.tables.composing, "the app can see a cell is composing and hold remote pulls")
        try c.remote { state in try state.tr.insertText("Y", 1) }
        held = c.binding.hasRemoteChanges
        XCTAssertTrue(held, "the remote change was held")
        editor.insertText("に", replacementRange: none)
        h.settle()
        XCTAssertEqual(try h.text(0, 0), "aに")
        XCTAssertEqual(h.core.state.doc.firstChild?.textContent, "Yabove")
    }

    // C3: an appended fix (fixTables) moves a later table; its grid and editor follow.
    func testAppendedFixKeepsLaterTableLive() throws {
        let doc = try TestDocs.doc([J.table([["a", "b"], ["c", "d"]]), J.p("mid"), J.table([["e", "f"]])])
        let h = try TableHarness(doc)
        let second = try XCTUnwrap(h.tables.grids.max { $0.tablePos < $1.tablePos })
        let map2 = try TableMap.get(second.table!)
        let cell2 = second.tableStart + map2.map[0]
        h.window.makeFirstResponder(h.view)
        h.dispatch(h.core.state.tr.setSelection(TextSelection.create(h.core.state.doc, cell2 + 3)))
        XCTAssertTrue(h.window.firstResponder === second.editor)
        // Delete cell "d": the first table is a cell short, and fixTables appends one.
        let first = h.core.state.doc.child(0)
        let d = 1 + first.child(0).nodeSize + 1 + first.child(1).child(0).nodeSize
        h.dispatch(try h.core.state.tr.delete(d, d + first.child(1).child(1).nodeSize))
        XCTAssertEqual(h.core.state.doc.child(0).child(1).childCount, 2, "fixTables added the cell back")
        XCTAssertNotNil(second.table, "the second grid still finds its table")
        XCTAssertTrue(h.window.firstResponder === second.editor)
        type(h, "Z")
        XCTAssertEqual(h.core.state.doc.child(2).child(0).child(0).textContent, "eZ")
    }

    // I1: clicking another cell during a composition commits it and moves editing there.
    func testClickAnotherCellDuringComposition() throws {
        let h = try TableHarness.grid([["a", "b"], ["c", "d"]])
        try caretInCell(h, 0, 0)
        let editor = try XCTUnwrap(h.grid.editor)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
        let rel = try h.cellPos(1, 1) - h.grid.tableStart
        let rect = try XCTUnwrap(h.grid.layout.cellRect(pos: rel))
        // Inside the cell, clear of the column border's resize zone.
        h.grid.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: h.grid.convert(NSPoint(x: rect.maxX - 20, y: rect.midY), to: nil),
                                                  modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1)!)
        h.settle()
        XCTAssertEqual(try h.text(0, 0), "ani")
        XCTAssertEqual(editor.scope, try h.cellPos(1, 1))
        type(h, "Z")
        XCTAssertEqual(try h.text(1, 1), "dZ")
    }

    // I2: a table inserted at the caret gets its cell editor, and typing goes into the first cell.
    func testInsertTableStartsEditingFirstCell() throws {
        let doc = try TestDocs.doc([J.p("x")])
        let h = try TableHarness(doc)
        h.view.undoCommand = { _, _, _ in true }
        h.window.makeFirstResponder(h.view)
        h.dispatch(h.core.state.tr.setSelection(TextSelection.create(h.core.state.doc, 2)))
        XCTAssertTrue(insertTable(schema: h.core.state.schema)(h.core.state, h.core.dispatch, h.view))
        // The app lays out between events; TextKit adds the table's view on a later pass.
        h.settle()
        h.settle()
        let grid = try XCTUnwrap(h.tables.grids.first)
        XCTAssertTrue(h.window.firstResponder === grid.editor, "the new table's first cell has focus")
        XCTAssertNotNil(grid.editor?.undoCommand, "the cell editor got the document's undo")
        type(h, "Z")
        let map = try TableMap.get(grid.table!)
        XCTAssertEqual(grid.table!.nodeAt(map.map[0])!.textContent, "Z")
    }

    // I4: a grip index that's gone (a collaborator deleted the row) doesn't crash a drag.
    func testStaleGripIndexDoesNotCrash() throws {
        let h = try TableHarness.grid([["a"], ["b"], ["c"]])
        h.grid.beginDrag(row: 2)
        let table = h.grid.table!
        let lastRow = h.grid.tableStart + table.child(0).nodeSize + table.child(1).nodeSize
        h.dispatch(try h.core.state.tr.delete(lastRow, lastRow + table.child(2).nodeSize))
        h.grid.updateDrag(offset: -40)
        h.grid.endDrag()
        h.grid.beginDrag(row: 9)
        h.grid.updateDrag(offset: 10)
        h.grid.endDrag()
        XCTAssertEqual(h.grid.table?.childCount, 2)
    }
}
#endif
