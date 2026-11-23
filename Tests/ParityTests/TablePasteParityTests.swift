import XCTest
import PMModel
import PMState
import PMOracle
import PMTables

final class TablePasteParityTests: XCTestCase {
    override func setUp() { registerCellSelection() }

    func testPasteParity() throws {
        var compared = 0
        for (i, doc) in try TableCorpus.fixedDocs(seed: 11_000, count: fuzzCount(80)).enumerated() {
            let js = try Oracle.shared.value("tablePasteCases", ["schema": Schemas.tiptapJSON, "doc": doc.toJSON(), "seed": .int(i)])
            for jsCase in js.arrayValue ?? [] {
                let selection = jsCase["selection"]!
                let swift = catching {
                    let state = EditorState.create(EditorStateConfig(doc: doc, selection: try Selection.fromJSON(doc, selection)))
                    var tr: Transaction?
                    let errors = CommandErrors.errorCount
                    let handled = handlePaste(state, try Slice.fromJSON(Schemas.tiptap, jsCase["slice"]!), { tr = $0 })
                    if CommandErrors.errorCount != errors { throw CommandErrors.last! }
                    return .object(JSONObject([("handled", .bool(handled)), ("doc", tr?.doc.toJSON() ?? .null),
                                               ("selection", tr?.selection.toJSON() ?? .null)]))
                }
                if jsCase["result"]?["error"] != nil { XCTAssertNotNil(swift["error"], "case \(i) \(selection)"); continue }
                assertParity(swift, jsCase["result"]!, "case \(i) \(selection) slice \(jsCase["slice"]!)")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 200)
    }
}
