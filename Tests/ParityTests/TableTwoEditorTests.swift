import XCTest
import PMModel
import PMState
import PMTables
import PMOracle
import YSync

/// A JS editor (y-prosemirror) and a Swift one (YSync, PMTables) editing the same tables through
/// Yjs: they converge, and neither finds anything left to fix (no churn).
final class TwoEditorTableTests: XCTestCase {
    private let oracle = Oracle.shared

    func testTwoEditorsNoChurn() throws {
        registerCellSelection()
        let schema = Schemas.tiptap
        // tableEditing, as an editor installs it: it repairs tables after every change.
        let plugins = [tableEditing()]
        let names = ["addColumnBefore", "addColumnAfter", "deleteColumn", "addRowBefore", "addRowAfter", "deleteRow", "mergeCells",
                     "splitCell", "toggleHeaderRow", "toggleHeaderColumn", "toggleHeaderCell", "deleteCellSelection", "updateColumnWidth",
                     "moveTableRow(0,1)", "moveTableColumn(1,0)"]
        for seed in 0..<fuzzCount(4) {
            let doc = try XCTUnwrap(TableCorpus.fixedDocs(seed: 20_000 + seed, count: 1).first)
            let ydoc = YDocument(clientID: 1)
            let binding = YSyncBinding(doc: ydoc, schema: schema)
            var outbox: [Data] = []
            ydoc.onUpdate { update, _ in outbox.append(update) }
            binding.seed(doc)
            var state = EditorState.create(EditorStateConfig(doc: doc, plugins: plugins))
            // As an app writing to Yjs does: a plugin's change appended to a remote pull is
            // written as housekeeping.
            func dispatch(_ tr: Transaction) {
                let (next, trs) = state.applyTransaction(tr)
                state = next
                binding.localStateChanged(state, tr)
                if trs.count > 1, !tr.docChanged || tr.getMeta(YSyncBinding.remoteMeta) != nil {
                    binding.localStateChanged(state, nil, undoable: false)
                }
            }
            let id = "js-\(seed)"
            _ = try oracle.value("yPeerCreate", ["schema": Schemas.tiptapJSON, "id": .string(id), "clientID": 2])
            @discardableResult
            func sync() throws -> Bool {
                for _ in 0..<6 {
                    let toJS = outbox.map { JSONValue.string($0.base64EncodedString()) }
                    outbox = []
                    if !toJS.isEmpty { _ = try oracle.value("yPeerApply", ["id": .string(id), "updates": .array(toJS)]) }
                    let fromJS = try oracle.value("yPeerTakeUpdates", ["id": .string(id)]).arrayValue ?? []
                    for u in fromJS { XCTAssertTrue(ydoc.applyUpdate(Data(base64Encoded: u.stringValue!)!, origin: "remote")) }
                    if let tr = binding.remoteTransaction(state) { dispatch(tr) }
                    if toJS.isEmpty && fromJS.isEmpty && outbox.isEmpty { return true }
                }
                return false
            }
            try sync()
            var rand = Rand(seed + 1)
            for step in 0..<50 {
                if let (table, pos) = TableCorpus.tables(state.doc).first, let map = try? TableMap.get(table),
                   case let cells = map.map.filter({ $0 != 0 }), !cells.isEmpty {
                    let cell = cells[Int(rand.next() * Double(cells.count)) % cells.count]
                    let other = cells[Int(rand.next() * Double(cells.count)) % cells.count]
                    let sel: Selection = rand.next() < 0.5
                        ? Selection.near(state.doc.resolve(pos + 1 + cell + 1))
                        : ((try? CellSelection.create(state.doc, pos + 1 + cell, pos + 1 + other)) ?? Selection.near(state.doc.resolve(pos + 2)))
                    dispatch(state.tr.setSelection(sel))
                    let name = names[Int(rand.next() * Double(names.count)) % names.count]
                    _ = tableCommand(name)?(state, { dispatch($0) }, nil)
                }
                if step % 5 == 4 {
                    _ = try oracle.value("yPeerRandomEdits", ["id": .string(id), "seed": .int(seed * 100 + step), "count": 2])
                }
                try sync()
            }
            XCTAssertTrue(try sync(), "seed \(seed): the editors keep sending each other changes")
            let jsDoc = try oracle.value("yPeerDoc", ["id": .string(id)])
            if let d = sameDoc(state.doc.toJSON(), jsDoc) {
                return XCTFail("seed \(seed): editors differ: \(d)")
            }
            // Like prosemirror-tables, a repair runs once per change, so a table can stay part-fixed
            // until its next edit, in both editors alike. Fixing the final doc fully gives the
            // same result in both.
            var swiftFixed = state.doc
            for _ in 0..<5 { guard let next = fixTables(EditorState.create(EditorStateConfig(doc: swiftFixed)))?.doc else { break }; swiftFixed = next }
            var jsFixed = jsDoc
            for _ in 0..<5 {
                let next = try oracle.value("fixTables", ["schema": Schemas.tiptapJSON, "doc": jsFixed])
                if next == .null { break }
                jsFixed = next
            }
            if let d = sameDoc(swiftFixed.toJSON(), jsFixed) { XCTFail("seed \(seed): repairs differ: \(d)") }
            XCTAssertTrue(outbox.isEmpty)
            XCTAssertEqual(try oracle.value("yPeerTakeUpdates", ["id": .string(id)]).arrayValue?.count ?? 0, 0)
            _ = try? oracle.value("yPeerDestroy", ["id": .string(id)])
        }
    }
}
