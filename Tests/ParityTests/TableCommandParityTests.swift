import XCTest
import PMModel
import PMState
import PMOracle
import PMTables

/// The Swift command for an oracle command name (see `tableCommand` in oracle/src/tables.js).
func tableCommand(_ name: String) -> Command? {
    switch name {
    case "addColumnBefore": return addColumnBefore
    case "addColumnAfter": return addColumnAfter
    case "deleteColumn": return deleteColumn
    case "addRowBefore": return addRowBefore
    case "addRowAfter": return addRowAfter
    case "deleteRow": return deleteRow
    case "mergeCells": return mergeCells
    case "splitCell": return splitCell
    case "setCellAttr": return setCellAttr("colwidth", [77])
    case "toggleHeaderRow": return toggleHeaderRow
    case "toggleHeaderColumn": return toggleHeaderColumn
    case "toggleHeaderCell": return toggleHeaderCell
    case "toggleHeader(row)": return toggleHeader("row")
    case "toggleHeader(column)": return toggleHeader("column")
    case "toggleHeader(cell)": return toggleHeader("cell")
    case "goToNextCell(1)": return goToNextCell(1)
    case "goToNextCell(-1)": return goToNextCell(-1)
    case "deleteTable": return deleteTable
    case "deleteCellSelection": return deleteCellSelection
    case "updateColumnWidth":
        return { state, dispatch, view in
            guard let cell = cellAround(state.selection.headPos) ?? cellNear(state.selection.headPos) else { return false }
            return updateColumnWidth(cellPos: cell.pos, width: 133)(state, dispatch, view)
        }
    default:
        let parts = name.split(whereSeparator: { "(),".contains($0) })
        guard parts.count == 3, let from = Int(parts[1]), let to = Int(parts[2]) else { return nil }
        if parts[0] == "moveTableRow" { return moveTableRow(from: from, to: to) }
        if parts[0] == "moveTableColumn" { return moveTableColumn(from: from, to: to) }
        return nil
    }
}

/// Runs `name` on `doc` with `selection` in Swift: `{applied, doc, selection}` like the oracle.
func runTableCommand(_ name: String, doc: Node, selection: JSONValue) -> JSONValue {
    catching {
        let sel = try Selection.fromJSON(doc, selection)
        let state = EditorState.create(EditorStateConfig(doc: doc, selection: sel))
        var tr: Transaction?
        let errors = CommandErrors.errorCount
        let applied = tableCommand(name)!(state, { tr = $0 }, nil)
        if CommandErrors.errorCount != errors { throw CommandErrors.last! }
        return .object(JSONObject([("applied", .bool(applied)), ("doc", tr?.doc.toJSON() ?? .null),
                                   ("selection", tr?.selection.toJSON() ?? .null)]))
    }
}

extension TableCorpus {
    /// Corpus docs after fixTables has settled: what commands meet in an editor, where the
    /// tableEditing plugin repairs tables after every transaction.
    static func fixedDocs(seed: Int, count: Int) throws -> [Node] {
        try docs(seed: seed, count: count).map { doc in
            var doc = doc
            for _ in 0..<5 {
                guard let next = fixTables(EditorState.create(EditorStateConfig(doc: doc)))?.doc else { break }
                doc = next
            }
            return doc
        }
    }
}

final class TableCommandParityTests: XCTestCase {
    override func setUp() { registerCellSelection() }

    private func sweep(_ commands: [String], seed: Int, count: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        var compared = 0
        for (i, doc) in try TableCorpus.fixedDocs(seed: seed, count: count).enumerated() {
            let js = try Oracle.shared.value("tableCommandCases", ["schema": Schemas.tiptapJSON, "doc": doc.toJSON(), "seed": .int(i),
                                                                   "commands": .array(commands.map { .string($0) })])
            for jsCase in js.arrayValue ?? [] {
                let name = jsCase["command"]!.stringValue!, selection = jsCase["selection"]!
                let swift = runTableCommand(name, doc: doc, selection: selection)
                // Error texts differ between the languages; both must fail, or both succeed alike.
                if jsCase["result"]?["error"] != nil {
                    XCTAssertNotNil(swift["error"], "case \(i) \(name) \(selection): JS threw \(jsCase["result"]!["error"]!)",
                                    file: file, line: line)
                    continue
                }
                assertParity(swift, jsCase["result"]!, "case \(i) \(name) \(selection)", file: file, line: line)
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 100, file: file, line: line)
    }

    func testRowColumnCommandsParity() throws {
        try sweep(["addColumnBefore", "addColumnAfter", "deleteColumn", "addRowBefore", "addRowAfter", "deleteRow"],
                  seed: 7000, count: fuzzCount(60))
    }

    func testCellCommandsParity() throws {
        try sweep(["mergeCells", "splitCell", "setCellAttr", "toggleHeaderRow", "toggleHeaderColumn", "toggleHeaderCell",
                   "toggleHeader(row)", "toggleHeader(column)", "toggleHeader(cell)", "goToNextCell(1)", "goToNextCell(-1)",
                   "deleteTable", "deleteCellSelection", "updateColumnWidth"],
                  seed: 8000, count: fuzzCount(60))
    }

    /// Every (from, to) pair, including moves merged cells make impossible.
    func testMoveRowColumnParity() throws {
        var compared = 0
        for (i, doc) in try TableCorpus.fixedDocs(seed: 9000, count: fuzzCount(40)).enumerated() {
            guard let (table, _) = TableCorpus.tables(doc).first else { continue }
            let map = try TableMap.get(table)
            var names: [String] = []
            for f in 0..<map.height { for t in 0..<map.height { names.append("moveTableRow(\(f),\(t))") } }
            for f in 0..<map.width { for t in 0..<map.width { names.append("moveTableColumn(\(f),\(t))") } }
            let js = try Oracle.shared.value("tableCommandCases", ["schema": Schemas.tiptapJSON, "doc": doc.toJSON(), "seed": .int(i),
                                                                   "commands": .array(names.map { .string($0) })])
            for jsCase in js.arrayValue ?? [] where jsCase["selection"]?["type"] == "text" {
                let name = jsCase["command"]!.stringValue!
                let swift = runTableCommand(name, doc: doc, selection: jsCase["selection"]!)
                if jsCase["result"]?["error"] != nil {
                    // JS throws on a few degenerate ranges; Swift declines instead.
                    XCTAssertNotEqual(swift["ok"]?["applied"], .bool(true), "case \(i) \(name)")
                    continue
                }
                assertParity(swift, jsCase["result"]!, "case \(i) \(name)")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 100)
    }

    func testClearColumnWidths() throws {
        func hasWidths(_ table: Node) -> Bool {
            var widths = false
            table.descendants { node, _, _, _ in
                if let w = node.attrs["colwidth"], w != .null { widths = true }
                return true
            }
            return widths
        }
        let (doc, table, pos) = try XCTUnwrap(TableCorpus.docs(seed: 8000, count: 60).lazy.compactMap { doc in
            TableCorpus.tables(doc).first { hasWidths($0.node) }.map { (doc, $0.node, $0.pos) }
        }.first)
        let state = EditorState.create(EditorStateConfig(doc: doc))
        var result: Transaction?
        XCTAssertTrue(clearColumnWidths(tablePos: pos)(state, { result = $0 }, nil))
        let after = try XCTUnwrap(result?.doc.nodeAt(pos))
        after.descendants { node, _, _, _ in
            if node.type.tableRole == .cell || node.type.tableRole == .headerCell {
                XCTAssertEqual(node.attrs["colwidth"], .null)
            }
            return true
        }
        XCTAssertEqual(after.textContent, table.textContent)
    }
}

final class TableKeyParityTests: XCTestCase {
    func testTableKeysParity() throws {
        let plugin = tableEditing()
        var compared = 0
        for (i, doc) in try TableCorpus.fixedDocs(seed: 10_000, count: fuzzCount(40)).enumerated() {
            let js = try Oracle.shared.value("tableKeyCases", ["schema": Schemas.tiptapJSON, "doc": doc.toJSON(), "seed": .int(i)])
            for jsCase in js.arrayValue ?? [] {
                let key = jsCase["key"]!.stringValue!, selection = jsCase["selection"]!
                let swift = catching {
                    let view = HeadlessView(EditorState.create(EditorStateConfig(doc: doc, selection: try Selection.fromJSON(doc, selection),
                                                                                 plugins: [plugin])))
                    let handled = view.handleKeyDown(scenarioKeyEvent(key))
                    return .object(JSONObject([("handled", .bool(handled)), ("doc", view.state.doc.toJSON()),
                                               ("selection", view.state.selection.toJSON())]))
                }
                if jsCase["result"]?["error"] != nil { XCTAssertNotNil(swift["error"], "case \(i) \(key) \(selection)"); continue }
                assertParity(swift, jsCase["result"]!, "case \(i) \(key) \(selection)")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 500)
    }
}
