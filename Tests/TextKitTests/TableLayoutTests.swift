#if os(macOS)
import XCTest
import PMModel
import PMTables
import PMTableView

final class TableLayoutTests: XCTestCase {
    private let style = TableStyle()

    private func cell(_ colwidth: JSONValue = .null, colspan: Int = 1, rowspan: Int = 1) -> JSONValue {
        ["type": "table_cell", "attrs": ["colspan": .number(Double(colspan)), "rowspan": .number(Double(rowspan)), "colwidth": colwidth],
         "content": [["type": "paragraph"]]]
    }

    private func table(_ rows: [[JSONValue]]) throws -> Node {
        try TestDocs.schema.nodeFromJSON(TableJ.table(rows))
    }

    /// Every cell's content is 20pt tall unless `heights` says otherwise (by cell position).
    private func layout(_ table: Node, width: CGFloat = 600, heights: [Int: CGFloat] = [:],
                        override: [Int: CGFloat] = [:]) throws -> TableLayout {
        TableLayout.make(table: table, map: try TableMap.get(table), availableWidth: width, style: style,
                         contentHeight: { pos, _ in heights[pos] ?? 20 }, overrideWidths: override)
    }

    func testFlexibleColumnsShareWidth() throws {
        let l = try layout(try table([[cell(), cell(), cell()]]))
        XCTAssertEqual(l.columnWidths, [200, 200, 200])
        XCTAssertEqual(l.size.width, 600)
    }

    func testFixedAndFlexible() throws {
        let l = try layout(try table([[cell([150]), cell(), cell()]]))
        XCTAssertEqual(l.columnWidths, [150, 225, 225])
    }

    func testFlexibleFloor() throws {
        let l = try layout(try table([[cell([500]), cell([500]), cell()]]))
        XCTAssertEqual(l.columnWidths, [500, 500, 25])
        XCTAssertEqual(l.size.width, 1025)
    }

    func testAllFixedSumsWidths() throws {
        let l = try layout(try table([[cell([100]), cell([120])]]))
        XCTAssertEqual(l.columnWidths, [100, 120])
        XCTAssertEqual(l.size.width, 220)
    }

    func testWidthsComeFromFirstRow() throws {
        // As prosemirror-tables' column resizing: only the first row's colwidth sizes columns.
        let l = try layout(try table([[cell(), cell()], [cell([300]), cell()]]))
        XCTAssertEqual(l.columnWidths, [300, 300])
    }

    func testColspanWidthsAndRect() throws {
        let t = try table([[cell([80, 120], colspan: 2), cell()], [cell(), cell(), cell()]])
        let l = try layout(t)
        XCTAssertEqual(l.columnWidths, [80, 120, 400])
        let first = try TableMap.get(t).map[0]
        XCTAssertEqual(l.cellRect(pos: first), CGRect(x: 0, y: 0, width: 200, height: 32))
    }

    func testOverrideWidthsForLivePreview() throws {
        let l = try layout(try table([[cell(), cell()]]), override: [0: 100])
        XCTAssertEqual(l.columnWidths, [100, 500])
    }

    func testRowHeightsFollowTallestCell() throws {
        let t = try table([[cell(), cell()], [cell(), cell()]])
        let map = try TableMap.get(t)
        let l = try layout(t, heights: [map.map[1]: 50])
        // Content plus 6pt padding top and bottom.
        XCTAssertEqual(l.rowHeights, [62, 32])
        XCTAssertEqual(l.size.height, 94)
    }

    func testRowspanHeightGoesToLastRow() throws {
        let t = try table([[cell(rowspan: 2), cell()], [cell()]])
        let map = try TableMap.get(t)
        let l = try layout(t, heights: [map.map[0]: 100])
        XCTAssertEqual(l.rowHeights, [32, 80])
        XCTAssertEqual(l.cellRect(pos: map.map[0])?.height, 112)
    }

    func testHitTesting() throws {
        let t = try table([[cell(), cell()], [cell(), cell()]])
        let map = try TableMap.get(t)
        let l = try layout(t)
        XCTAssertEqual(l.cell(at: CGPoint(x: 10, y: 10)), map.map[0])
        XCTAssertEqual(l.cell(at: CGPoint(x: 310, y: 40)), map.map[3])
        XCTAssertNil(l.cell(at: CGPoint(x: 700, y: 10)))
        XCTAssertEqual(l.columnBorder(near: 303, tolerance: 4), 1)
        XCTAssertEqual(l.columnBorder(near: 597, tolerance: 4), 2)
        XCTAssertNil(l.columnBorder(near: 150, tolerance: 4))
    }

    func testMalformedMapDoesNotCrash() throws {
        for doc in try TableJ.corpus(seed: 12_000, count: 100) {
            for (table, _) in TableJ.tables(doc) {
                let l = try layout(table)
                XCTAssertGreaterThan(l.size.height, 0)
            }
        }
    }
}
#endif
