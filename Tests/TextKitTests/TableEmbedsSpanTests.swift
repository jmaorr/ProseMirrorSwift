#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMTextKit
import PMTables
import PMTableView

/// TableEmbeds keeps a table's grid when a change replaces a range that still holds the
/// table's own node.
@MainActor
final class TableEmbedsSpanTests: XCTestCase {
    private func table(_ text: (Int, Int) -> String) -> JSONValue {
        TableJ.table((0..<2).map { r in
            (0..<2).map { c in TableJ.textCell(text(r, c), type: r == 0 ? "table_header" : "table_cell") }
        })
    }

    func testGridKeptWhenAChangeSpansAnUnchangedTable() throws {
        let schema = TestDocs.schema
        let h = try TableHarness(try TestDocs.doc([J.p("Seed plan"), table { "R\($0)C\($1)" }, J.p("Weekly"),
                                                   table { "W\($0)\($1)" }, J.p("End")]))
        let doc = h.core.state.doc
        let first = 1 + doc.child(0).nodeSize - 1
        XCTAssertEqual(doc.nodeAt(first)?.type.name, "table")
        let oldSecond = first + doc.child(1).nodeSize + doc.child(2).nodeSize
        let secondGrid = try XCTUnwrap(h.tables.grid(at: oldSecond), "the second table's grid")
        let edited = try schema.nodeFromJSON(table { $0 == 1 && $1 == 0 ? "Beans" : "R\($0)C\($1)" })
        var rest: [Node] = [edited]
        for i in 2..<doc.childCount { rest.append(doc.child(i)) }
        h.dispatch(try h.core.state.tr.replaceWith(first, doc.content.size, rest))

        let newSecond = first + edited.nodeSize + h.core.state.doc.child(2).nodeSize
        XCTAssertTrue(h.tables.grid(at: newSecond) === secondGrid, "the same grid, not a new one")
        XCTAssertEqual(secondGrid.tablePos, newSecond)
        XCTAssertNotNil(secondGrid.table)
        XCTAssertEqual(h.tables.grids.count, 2)
        let offset = h.view.renderer.stringOffset(newSecond, bias: 1)
        let shown = h.view.textStorage?.attribute(.attachment, at: offset, effectiveRange: nil) as? TableAttachment
        XCTAssertTrue(shown?.grid === secondGrid, "the text shows the grid the embeds update")
        // A later edit reaches it.
        let map = try TableMap.get(try XCTUnwrap(secondGrid.table))
        h.dispatch(try h.core.state.tr.insertText("Rain ", newSecond + 1 + map.map[2] + 2))
        XCTAssertEqual(secondGrid.renderedCell(at: map.map[2])?.node.textContent, "Rain W10")
    }
}
#endif
