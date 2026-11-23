#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMTextKit
import PMExampleSetup

/// BasicStyle, with tables rendered as one attachment character (no grids).
private struct ScopedEmbeddingStyle: DocStyle {
    var base = BasicStyle()
    func paragraph(_ textblock: Node, ancestors: [Node], marker: BlockMarker?) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
        base.paragraph(textblock, ancestors: ancestors, marker: marker)
    }
    func inline(_ marks: [Mark], base attrs: [NSAttributedString.Key: Any], textblock: Node, ancestors: [Node]) -> [NSAttributedString.Key: Any] {
        base.inline(marks, base: attrs, textblock: textblock, ancestors: ancestors)
    }
    func leafBlock(_ node: Node, ancestors: [Node]) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
        base.leafBlock(node, ancestors: ancestors)
    }
    func inlineLeaf(_ node: Node, base attrs: [NSAttributedString.Key: Any]) -> NSAttributedString { base.inlineLeaf(node, base: attrs) }
    func marker(for child: Node, in parent: Node, index: Int) -> BlockMarker? { base.marker(for: child, in: parent, index: index) }
    func embed(for node: Node, at pos: Int, ancestors: [Node]) -> [NSAttributedString.Key: Any]? {
        node.type.name == "table" ? [.attachment: NSTextAttachment()] : nil
    }
}

private enum ScopedTableDocs {
    /// p("ab"), table 2×2 ("c1" "c2" / "c3" "c4"), p("cd").
    static func simple() throws -> Node {
        try TestDocs.doc([J.p("ab"), J.table([["c1", "c2"], ["c3", "c4"]]), J.p("cd")])
    }

    /// Position before the cell at (row, col) of the first table.
    static func cellPos(_ doc: Node, _ row: Int, _ col: Int) -> Int {
        var out = 0
        doc.descendants { node, pos, _, _ in
            if node.type.name == "table" {
                var p = pos + 1
                for r in 0..<row { p += node.child(r).nodeSize }
                p += 1
                for c in 0..<col { p += node.child(row).child(c).nodeSize }
                out = p
                return false
            }
            return true
        }
        return out
    }
}

/// DocRenderer's position mapping around embedded nodes and leaves, and rendering scoped to one node.
@MainActor
final class ScopedRendererTests: XCTestCase {
    func testEmbedSpanMapping() throws {
        let doc = try ScopedTableDocs.simple()
        let renderer = DocRenderer(style: ScopedEmbeddingStyle())
        let storage = NSTextStorage()
        renderer.update(storage, to: doc)
        XCTAssertEqual(storage.string, "ab\n\u{FFFC}\ncd\n")
        let tablePos = 4, tableEnd = tablePos + doc.child(1).nodeSize
        XCTAssertNotNil(storage.attribute(.attachment, at: 3, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.attachment, at: 4, effectiveRange: nil))
        XCTAssertEqual(renderer.stringOffset(tablePos, bias: 1), 3)
        for pos in (tablePos + 1)..<tableEnd {
            XCTAssertEqual(renderer.stringOffset(pos, bias: -1), 3, "pos \(pos)")
            XCTAssertEqual(renderer.stringOffset(pos, bias: 1), 4, "pos \(pos)")
        }
        XCTAssertEqual(renderer.stringOffset(tableEnd, bias: 1), 5)
        XCTAssertEqual(renderer.stringOffset(tableEnd, bias: -1), 4)
        XCTAssertEqual(renderer.docPosition(3)?.pos, tablePos)
        XCTAssertEqual(renderer.docPosition(4)?.pos, tableEnd)
        XCTAssertEqual(renderer.docPosition(5)?.pos, tableEnd + 1)
    }

    /// Two block leaves in a row: a range ending between them ends on the first one's
    /// character (a node selection of it covers that one character, not the next too).
    func testAdjacentBlockLeavesMapping() throws {
        let doc = try TestDocs.doc([J.p("ab"), J.hr, J.hr, J.p("cd")])
        let renderer = DocRenderer(style: BasicStyle())
        let storage = NSTextStorage()
        renderer.update(storage, to: doc)
        XCTAssertEqual(storage.string, "ab\n\u{FFFC}\n\u{FFFC}\ncd\n")
        XCTAssertEqual(renderer.stringOffset(4, bias: 1), 3)
        XCTAssertEqual(renderer.stringOffset(5, bias: -1), 4, "the end of the first rule")
        XCTAssertEqual(renderer.stringOffset(5, bias: 1), 5, "the start of the second")
        XCTAssertEqual(renderer.stringOffset(6, bias: -1), 6, "the end of the second")
    }

    func testScopedRendererRendersOnlyCell() throws {
        let doc = try ScopedTableDocs.simple()
        let renderer = DocRenderer(style: ScopedEmbeddingStyle())
        let storage = NSTextStorage()
        let cell = ScopedTableDocs.cellPos(doc, 1, 0)
        renderer.update(storage, to: doc, scope: cell)
        XCTAssertEqual(storage.string, "c3\n")
        XCTAssertEqual(renderer.scopeStart, cell + 1)
        XCTAssertEqual(renderer.docPosition(0)?.pos, cell + 2)
        XCTAssertEqual(renderer.stringOffset(cell + 3), 1)
    }

    func testScopedRendererFollowsEditsBefore() throws {
        let doc = try ScopedTableDocs.simple()
        let renderer = DocRenderer(style: ScopedEmbeddingStyle())
        let storage = NSTextStorage()
        let cell = ScopedTableDocs.cellPos(doc, 0, 1)
        renderer.update(storage, to: doc, scope: cell)
        let spanBefore = renderer.spans[0]
        let state = EditorState.create(EditorStateConfig(doc: doc))
        let tr = try state.tr.insertText("xyz", 1)
        let mapped = tr.mapping.map(cell)
        renderer.update(storage, to: tr.doc, scope: mapped)
        XCTAssertEqual(storage.string, "c2\n")
        XCTAssertEqual(renderer.spans[0].pmStart, spanBefore.pmStart + 3)
        XCTAssertEqual(renderer.spans[0].strStart, spanBefore.strStart)
    }

    func testUnscopedRenderingUnchanged() throws {
        let doc = try ScopedTableDocs.simple()
        let a = DocRenderer(style: BasicStyle()), b = DocRenderer(style: BasicStyle())
        let sa = NSTextStorage(), sb = NSTextStorage()
        a.update(sa, to: doc)
        b.update(sb, to: doc, scope: nil)
        XCTAssertEqual(sa.string, sb.string)
        XCTAssertEqual(a.spans.map(\.pmStart), b.spans.map(\.pmStart))
        XCTAssertEqual(sa.string, "ab\nc1\nc2\nc3\nc4\ncd\n")
    }
}

/// A view scoped to one table cell, on the same core as the main view.
@MainActor
final class ScopedViewTests: XCTestCase {
    private let none = NSRange(location: NSNotFound, length: 0)

    /// A main view and a cell view on one core, caret at the end of cell (0, 1).
    private func views() throws -> (main: ProseTextView, cell: ProseTextView) {
        let doc = try ScopedTableDocs.simple()
        let core = EditorCore(state: TestDocs.state(doc))
        let main = ProseTextView(core: core, style: ScopedEmbeddingStyle())
        let cellPos = ScopedTableDocs.cellPos(doc, 0, 1)
        let cell = ProseTextView(core: core, style: BasicStyle(), scope: cellPos)
        core.dispatch(core.state.tr.setSelection(TextSelection.create(core.state.doc, cellPos + 4)))
        return (main, cell)
    }

    private func cellText(_ v: ProseTextView, _ row: Int, _ col: Int) -> String {
        v.state.doc.nodeAt(ScopedTableDocs.cellPos(v.state.doc, row, col))!.textContent
    }

    func testTypingInScopedViewEditsCell() throws {
        let (main, cell) = try views()
        XCTAssertEqual(cell.textStorage?.string, "c2\n")
        XCTAssertEqual(cell.selectedRange(), NSRange(location: 2, length: 0))
        for ch in "xy" { cell.insertText(String(ch), replacementRange: none) }
        XCTAssertEqual(cellText(cell, 0, 1), "c2xy")
        XCTAssertEqual(cell.textStorage?.string, "c2xy\n")
        XCTAssertEqual(main.textStorage?.string, "ab\n\u{FFFC}\ncd\n")
        XCTAssertEqual(cell.selectedRange(), NSRange(location: 4, length: 0))
    }

    func testAutocorrectReplacementInCell() throws {
        let (_, cell) = try views()
        let range = NSRange(location: 0, length: 2)
        XCTAssertTrue(cell.shouldChangeText(in: range, replacementString: "Cee"), "edit refused")
        cell.textStorage!.replaceCharacters(in: range, with: "Cee")
        cell.setSelectedRange(NSRange(location: 3, length: 0))
        cell.didChangeText()
        XCTAssertEqual(cellText(cell, 0, 1), "Cee")
        XCTAssertEqual(cellText(cell, 0, 0), "c1")
    }

    func testMarkedTextInCell() throws {
        let (_, cell) = try views()
        cell.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
        XCTAssertTrue(cell.composing)
        cell.insertText("に", replacementRange: none)
        XCTAssertFalse(cell.composing)
        XCTAssertEqual(cellText(cell, 0, 1), "c2に")
        XCTAssertEqual(cell.state.doc.child(2).textContent, "cd")
    }

    func testScopeFollowsEditsBefore() throws {
        let (main, cell) = try views()
        let before = cell.scope!
        main.dispatch(try main.state.tr.insertText("zz", 1))
        XCTAssertEqual(cell.scope, before + 2)
        XCTAssertEqual(cell.textStorage?.string, "c2\n")
    }

    func testScopeLostFiresWhenCellDeleted() throws {
        let (main, cell) = try views()
        var lost = false
        cell.onScopeLost = { lost = true }
        let table = main.state.doc.child(1)
        main.dispatch(try main.state.tr.delete(4, 4 + table.nodeSize))
        XCTAssertTrue(lost)
        XCTAssertNil(cell.scope)
    }

    func testNoCaretWhenSelectionOutsideScope() throws {
        let (main, cell) = try views()
        main.dispatch(main.state.tr.setSelection(TextSelection.create(main.state.doc, 2)))
        XCTAssertFalse(cell.hasSelectionInScope)
        XCTAssertEqual(cell.selectedRange().length, 0)
    }
}
#endif
