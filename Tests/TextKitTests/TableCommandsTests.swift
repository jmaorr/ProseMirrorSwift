#if os(macOS)
import XCTest
import PMModel
import PMState
import PMTables
import PMExampleSetup

/// PMExampleSetup's table commands, without a view.
final class TableCommandsTests: XCTestCase {
    private func state(_ content: [JSONValue], selection: Int? = nil) throws -> EditorState {
        TestDocs.state(try TestDocs.doc(content), selection: selection)
    }

    func testInsertTableDefaults() throws {
        var state = try state([J.p("hello")], selection: 6)
        XCTAssertTrue(insertTable(schema: state.schema)(state, { state = state.apply($0) }, nil))
        let table = try XCTUnwrap(state.doc.children.first { $0.type.name == "table" })
        XCTAssertEqual(table.childCount, 3)
        XCTAssertEqual(table.child(0).childCount, 3)
        XCTAssertTrue(table.child(0).children.allSatisfy { $0.type.name == "table_header" })
        XCTAssertTrue(table.child(1).children.allSatisfy { $0.type.name == "table_cell" })
        let cell = try XCTUnwrap(cellAround(state.selection.fromPos))
        XCTAssertEqual(cell.index(), 0)
        XCTAssertEqual(cell.index(-1), 0)
    }

    func testInsertTableWithoutHeaderRow() throws {
        var state = try state([J.p("")])
        XCTAssertTrue(insertTable(schema: state.schema, rows: 2, cols: 4, headerRow: false)(state, { state = state.apply($0) }, nil))
        let table = try XCTUnwrap(state.doc.children.first { $0.type.name == "table" })
        let map = try TableMap.get(table)
        XCTAssertEqual(map.height, 2)
        XCTAssertEqual(map.width, 4)
        XCTAssertTrue(table.children.allSatisfy { $0.children.allSatisfy { $0.type.name == "table_cell" } })
    }

    func testDeleteTableWithEveryCellSelected() throws {
        var state = try state([J.p("before"), J.table([["a", "b"], ["c", "d"]]), J.p("after")])
        let map = try TableMap.get(state.doc.child(1))
        let start = state.doc.child(0).nodeSize + 1
        state = state.apply(state.tr.setSelection(try CellSelection.create(state.doc, start + map.map.first!, start + map.map.last!)))
        let sel = try XCTUnwrap(state.selection as? CellSelection)
        XCTAssertTrue(sel.isRowSelection() && sel.isColSelection())
        XCTAssertTrue(deleteTable(state, { state = state.apply($0) }, nil))
        XCTAssertEqual(state.doc.childCount, 2)
        XCTAssertFalse(state.doc.children.contains { $0.type.name == "table" })
    }
}
#endif
