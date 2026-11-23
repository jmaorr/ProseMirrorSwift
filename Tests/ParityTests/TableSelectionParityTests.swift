import XCTest
import PMModel
import PMState
import PMOracle
import PMTables
import YSync

final class TableSelectionParityTests: XCTestCase {
    override func setUp() { registerCellSelection() }

    private func pair(_ a: Int, _ b: Int) -> JSONValue { .array([.int(a), .int(b)]) }

    func testCellSelectionParity() throws {
        for (i, doc) in try TableCorpus.docs(seed: 3000, count: fuzzCount(120)).enumerated() {
            let js = try Oracle.shared.value("cellSelectionCases", ["schema": Schemas.tiptapJSON, "doc": doc.toJSON(), "seed": .int(i)])
            for jsCase in js.arrayValue ?? [] {
                let anchor = jsCase["anchor"]!.intValue!, head = jsCase["head"]!.intValue!
                let edit = jsCase["edit"]!
                var o = JSONObject([("anchor", .int(anchor)), ("head", .int(head)), ("edit", edit)])
                do {
                    let sel = try CellSelection.create(doc, anchor, head)
                    let mapped = catching {
                        let state = EditorState.create(EditorStateConfig(doc: doc, selection: sel))
                        let tr = state.tr
                        let from = edit["from"]!.intValue!, to = edit["to"]!.intValue!
                        if let text = edit["text"]?.stringValue, !text.isEmpty { _ = try tr.insertText(text, from, to) }
                        else { _ = try tr.delete(from, to) }
                        return sel.map(tr.doc, tr.mapping).toJSON()
                    }
                    o["ok"] = .object(JSONObject([
                        ("ranges", .array(sel.ranges.map { pair($0.from.pos, $0.to.pos) })),
                        ("content", sel.content().toJSON()),
                        ("isRow", .bool(sel.isRowSelection())), ("isCol", .bool(sel.isColSelection())),
                        ("rowSel", catching { try CellSelection.rowSelection(doc.resolve(anchor), doc.resolve(head)).toJSON() }),
                        ("colSel", catching { try CellSelection.colSelection(doc.resolve(anchor), doc.resolve(head)).toJSON() }),
                        ("mapped", mapped),
                    ]))
                } catch {
                    o["error"] = .string("\(error)")
                }
                // Error text differs between the languages; compare that an error happened.
                if jsCase["error"] != nil { XCTAssertNotNil(o["error"], "case \(i): JS threw \(jsCase["error"]!)"); continue }
                // Where JS's map throws (a mapped cell no longer in a table), Swift falls back to a
                // text selection instead of crashing.
                if jsCase["ok"]?["mapped"]?["error"] != nil, var ok = o["ok"]?.objectValue {
                    XCTAssertEqual(ok["mapped"]?["ok"]?["type"], "text", "case \(i): fallback")
                    ok["mapped"] = jsCase["ok"]!["mapped"]
                    o["ok"] = .object(ok)
                }
                assertParity(.object(o), jsCase, "case \(i) \(anchor)-\(head)")
            }
        }
    }

    func testNormalizeSelectionParity() throws {
        for (i, doc) in try TableCorpus.docs(seed: 4000, count: fuzzCount(120)).enumerated() {
            let js = try Oracle.shared.value("normalizeCases", ["schema": Schemas.tiptapJSON, "doc": doc.toJSON(), "seed": .int(i)])
            for jsCase in js.arrayValue ?? [] {
                func normalized(_ sel: Selection) -> JSONValue {
                    let state = EditorState.create(EditorStateConfig(doc: doc, selection: sel))
                    return (normalizeSelection(state, nil, allowTableNodeSelection: false)?.selection ?? state.selection).toJSON()
                }
                guard jsCase["result"]?["ok"] != nil else { continue }
                if jsCase["kind"] == "node" {
                    let pos = jsCase["pos"]!.intValue!
                    assertParity(normalized(NodeSelection.create(doc, pos)), jsCase["result"]!["ok"]!, "case \(i) node \(pos)")
                } else {
                    let a = jsCase["anchor"]!.intValue!, b = jsCase["head"]!.intValue!
                    let sel = TextSelection.between(doc.resolve(a), doc.resolve(b))
                    assertParity(.array([sel.toJSON(), normalized(sel)]), jsCase["result"]!["ok"]!, "case \(i) text \(a)-\(b)")
                }
            }
        }
    }

    func testCellSelectionJSONRoundTrip() throws {
        let doc = try XCTUnwrap(TableCorpus.docs(seed: 1, count: 1).first)
        let (table, pos) = try XCTUnwrap(TableCorpus.tables(doc).first)
        let map = try TableMap.get(table)
        let sel = try CellSelection.create(doc, pos + 1 + map.map[0], pos + 1 + map.map.last!)
        let back = try Selection.fromJSON(doc, sel.toJSON())
        XCTAssertTrue(back is CellSelection)
        XCTAssertTrue(back.eq(sel))
        XCTAssertEqual(sel.getBookmark().resolve(doc).toJSON(), sel.toJSON())
    }
}

final class FixTablesParityTests: XCTestCase {
    private func fixed(_ doc: Node) -> Node? {
        fixTables(EditorState.create(EditorStateConfig(doc: doc)))?.doc
    }

    func testFixTablesParity() throws {
        for (i, doc) in try TableCorpus.docs(seed: 5000, count: fuzzCount(300)).enumerated() {
            let js = try Oracle.shared.value("fixTables", ["schema": Schemas.tiptapJSON, "doc": doc.toJSON()])
            assertParity(fixed(doc)?.toJSON() ?? .null, js, "case \(i)")
        }
    }

    /// The anti-goal: the editors never churn. A single fixTables pass isn't always a fixed
    /// point (in JS too), but plugins re-run appendTransaction until nothing changes, so fix
    /// until stable: both sides must settle in a few rounds, on the same doc, which the other
    /// side then leaves alone.
    func testFixTablesConvergesToSharedFixedPoint() throws {
        for (i, doc) in try TableCorpus.docs(seed: 6000, count: fuzzCount(200)).enumerated() {
            var swiftDoc = doc, jsDoc = doc.toJSON(), rounds = 0
            while let next = fixed(swiftDoc) {
                swiftDoc = next
                rounds += 1
                if rounds > 5 { return XCTFail("case \(i): Swift fixTables doesn't settle") }
            }
            rounds = 0
            while case let next = try Oracle.shared.value("fixTables", ["schema": Schemas.tiptapJSON, "doc": jsDoc]), next != .null {
                jsDoc = next
                rounds += 1
                if rounds > 5 { return XCTFail("case \(i): JS fixTables doesn't settle") }
            }
            assertParity(swiftDoc.toJSON(), jsDoc, "case \(i) fixed point")
            XCTAssertEqual(try Oracle.shared.value("fixTables", ["schema": Schemas.tiptapJSON, "doc": swiftDoc.toJSON()]), .null,
                           "case \(i): JS changes Swift's fixed point")
        }
    }

    /// The web runs fixTables on y-prosemirror's remote transactions too; so do we.
    func testFixTablesRunsOnRemoteTransactions() throws {
        let broken = try XCTUnwrap(TableCorpus.docs(seed: 5000, count: 300).first { fixed($0) != nil })
        let start = try Schemas.tiptap.nodeFromJSON(["type": "doc", "content": [["type": "paragraph"]]])
        let state = EditorState.create(EditorStateConfig(doc: start, plugins: [tableEditing()]))
        let tr = try state.tr.replaceWith(0, start.content.size, broken.content)
        _ = tr.setMeta(YSyncBinding.remoteMeta, true)
        let (next, _) = state.applyTransaction(tr)
        XCTAssertNotNil(fixed(broken), "corpus doc is broken")
        XCTAssertNotEqual(next.doc.content.toJSON(), broken.content.toJSON(), "remote content was fixed")
    }
}
