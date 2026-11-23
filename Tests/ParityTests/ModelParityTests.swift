import XCTest
import PMModel
import PMOracle

/// Swift replay of oracle/src/model.js `probeDoc`, using the random inputs JS recorded.
func probeDoc(_ doc: Node, js: JSONValue) -> JSONValue {
    func nodeSummary(_ n: Node?) -> JSONValue {
        guard let n else { return .null }
        return ["type": .string(n.type.name), "size": .int(n.nodeSize), "marks": .array(n.marks.map { $0.toJSON() })]
    }
    let size = doc.content.size
    var positions: [JSONValue] = []
    for (pos, jsPos) in zip(0...size, js["positions"]!.arrayValue!) {
        let rpos = doc.resolve(pos)
        let other = jsPos["other"]!.intValue!
        let rother = doc.resolve(other)
        var levels: [JSONValue] = []
        for d in 0...rpos.depth {
            levels.append([
                "type": .string(rpos.node(d).type.name), "index": .int(rpos.index(d)), "indexAfter": .int(rpos.indexAfter(d)),
                "start": .int(rpos.start(d)), "end": .int(rpos.end(d)),
                "before": d > 0 ? .int(rpos.before(d)) : .null, "after": d > 0 ? .int(rpos.after(d)) : .null,
            ])
        }
        let range = rpos.blockRange(rother)
        positions.append([
            "pos": .int(pos), "depth": .int(rpos.depth), "parentOffset": .int(rpos.parentOffset),
            "textOffset": .int(rpos.textOffset), "levels": .array(levels),
            "marks": .array(rpos.marks().map { $0.toJSON() }),
            "marksAcross": rpos.marksAcross(rother).map { .array($0.map { $0.toJSON() }) } ?? .null,
            "nodeAfter": nodeSummary(rpos.nodeAfter), "nodeBefore": nodeSummary(rpos.nodeBefore),
            "nodeAt": nodeSummary(doc.nodeAt(pos)),
            "other": .int(other), "sharedDepth": .int(rpos.sharedDepth(other)), "sameParent": .bool(rpos.sameParent(rother)),
            "blockRange": range.map { r in
                ["depth": .int(r.depth), "start": .int(r.start), "end": .int(r.end),
                 "startIndex": .int(r.startIndex), "endIndex": .int(r.endIndex)]
            } ?? .null,
        ])
    }
    let markTypes = doc.type.schema.markTypes
    let slices: [JSONValue] = js["slices"]!.arrayValue!.map { s in
        let from = s["from"]!.intValue!, to = s["to"]!.intValue!
        let slice = doc.slice(from, to)
        return ["from": .int(from), "to": .int(to), "slice": slice.toJSON(),
                "maxOpen": Slice.maxOpen(slice.content).toJSON(),
                "rangeHasMark": .array(markTypes.map { .bool(doc.rangeHasMark(from, to, $0)) })]
    }
    let replaces: [JSONValue] = js["replaces"]!.arrayValue!.map { e in
        let from = e["from"]!.intValue!, to = e["to"]!.intValue!, sFrom = e["sFrom"]!.intValue!, sTo = e["sTo"]!.intValue!
        var entry = JSONObject([("from", .int(from)), ("to", .int(to)), ("sFrom", .int(sFrom)), ("sTo", .int(sTo))])
        do {
            let result = try doc.replace(from, to, doc.slice(sFrom, sTo))
            entry["result"] = result.toJSON()
            entry["diffStart"] = .opt(doc.content.findDiffStart(result.content).map { .int($0) })
            entry["diffEnd"] = .opt(doc.content.findDiffEnd(result.content).map { .array([.int($0.a), .int($0.b)]) })
        } catch {
            entry["error"] = .string("\(error)")
        }
        return .object(entry)
    }
    return [
        "doc": doc.toJSON(), "nodeSize": .int(doc.nodeSize), "textContent": .string(doc.textContent),
        "textBetween": .string(doc.textBetween(0, size, blockSeparator: "\n", leafText: "*")),
        "positions": .array(positions), "slices": .array(slices), "replaces": .array(replaces),
    ]
}

func probeSchema(_ schema: Schema) -> JSONValue {
    var nodes: [JSONValue] = []
    for type in schema.nodeTypes {
        let match = type.contentMatch
        var wrap = JSONObject(), fill = JSONObject()
        for t in schema.nodeTypes {
            wrap[t.name] = match.findWrapping(t).map { .array($0.map { .string($0.name) }) } ?? .null
            let node: Node? = t.isText ? schema.text("x") : t.createAndFill()
            if let node, let f = match.fillBefore(Fragment.from(node), toEnd: true) {
                fill[t.name] = f.toJSON() ?? .array([])
            } else {
                fill[t.name] = .null
            }
        }
        nodes.append([
            "type": .string(type.name), "inlineContent": .bool(type.inlineContent), "isLeaf": .bool(type.isLeaf),
            "isBlock": .bool(type.isBlock), "isTextblock": .bool(type.isTextblock), "isAtom": .bool(type.isAtom),
            "defaultType": .opt(match.defaultType.map { .string($0.name) }), "validEnd": .bool(match.validEnd),
            "edges": .array(match.next.map { .string($0.type.name) }),
            "markSet": .opt(type.markSet.map { .array($0.map { .string($0.name) }) }),
            "createAndFill": .opt(type.createAndFill()?.toJSON()),
            "wrap": .object(wrap), "fill": .object(fill),
        ])
    }
    let marks: [JSONValue] = schema.markTypes.map {
        ["name": .string($0.name), "rank": .int($0.rank), "excluded": .array($0.excluded.map { .string($0.name) })]
    }
    return ["nodes": .array(nodes), "marks": .array(marks)]
}

func runModelParity(schemaJSON: JSONValue, schema: Schema, seed: Int, count: Int, file: StaticString = #filePath, line: UInt = #line) throws {
    let batch = 50
    var done = 0
    while done < count {
        let n = min(batch, count - done)
        let cases = try Oracle.shared.value("modelCases", ["schema": schemaJSON, "seed": .int(seed + done), "count": .int(n)])
        for (i, js) in cases.arrayValue!.enumerated() {
            let doc = try Node.fromJSON(schema, js["doc"]!)
            try doc.check()
            let swift = probeDoc(doc, js: js)
            if let d = jsonDiff(swift, js) {
                XCTFail("seed \(seed + done + i): \(d)", file: file, line: line)
                return
            }
        }
        done += n
    }
}

func runInvalidParity(schemaJSON: JSONValue, schema: Schema, seed: Int, count: Int, file: StaticString = #filePath, line: UInt = #line) throws {
    let cases = try Oracle.shared.value("invalidCases", ["schema": schemaJSON, "seed": .int(seed), "count": .int(count)])
    var errors = 0
    for (i, js) in cases.arrayValue!.enumerated() {
        var swift = JSONObject()
        swift["json"] = js["json"]!
        do {
            let node = try Node.fromJSON(schema, js["json"]!)
            try node.check()
            swift["ok"] = node.toJSON()
        } catch {
            swift["error"] = .string("\(error)")
            errors += 1
        }
        // Error messages are compared loosely: only presence must match.
        if (swift["error"] == nil) != (js["error"] == nil) {
            XCTFail("invalid seed \(seed + i): Swift \(swift["error"].map { "\($0)" } ?? "ok") vs JS \(js["error"].map { "\($0)" } ?? "ok") for \(js["json"]!)", file: file, line: line)
            return
        }
        if let ok = swift["ok"] { assertParity(ok, js["ok"]!, "invalid seed \(seed + i)", file: file, line: line) }
    }
    XCTAssertGreaterThan(errors, 0, "mutation generator never produced invalid docs", file: file, line: line)
}

final class ModelParityTests: XCTestCase {
    func testSchemaStructureBasic() throws {
        let js = try Oracle.shared.value("probeSchema", ["schema": Schemas.basicJSON])
        assertParity(probeSchema(Schemas.basic), js)
    }

    func testRandomDocsBasic() throws {
        try runModelParity(schemaJSON: Schemas.basicJSON, schema: Schemas.basic, seed: 1, count: fuzzCount(300))
    }

    func testInvalidDocsBasic() throws {
        try runInvalidParity(schemaJSON: Schemas.basicJSON, schema: Schemas.basic, seed: 1000, count: fuzzCount(300))
    }

    func testSchemaStructureTiptap() throws {
        let js = try Oracle.shared.value("probeSchema", ["schema": Schemas.tiptapJSON])
        assertParity(probeSchema(Schemas.tiptap), js)
    }

    func testRandomDocsTiptap() throws {
        try runModelParity(schemaJSON: Schemas.tiptapJSON, schema: Schemas.tiptap, seed: 5000, count: fuzzCount(300))
    }

    func testInvalidDocsTiptap() throws {
        try runInvalidParity(schemaJSON: Schemas.tiptapJSON, schema: Schemas.tiptap, seed: 9000, count: fuzzCount(300))
    }

    func testContentExpressions() throws {
        // Exercise the content-expression parser and DFA on a range of expressions.
        let exprs = ["block+", "paragraph block*", "(paragraph | heading)+", "heading paragraph{2,4}", "paragraph{2}",
                     "paragraph{1,}", "heading? paragraph*", "(heading paragraph)* blockquote?", "inline*", "text*",
                     "block*", "(block | inline)", "paragraph+ (heading | blockquote)*", "nope+", "paragraph{x}",
                     "(paragraph", "paragraph )", "inline block", "heading{0,1} paragraph{0,2} heading{1}"]
        for expr in exprs {
            var nodes = Schemas.basicJSON["nodes"]!.arrayValue!
            nodes.append(["test_node", ["content": .string(expr)]])
            var spec = Schemas.basicJSON.objectValue!
            spec["nodes"] = .array(nodes)
            let specJSON = JSONValue.object(spec)
            let jsErr = try Oracle.shared.value("schemaError", ["schema": specJSON])
            var swiftErr: String? = nil
            var schema: Schema? = nil
            do { schema = try Schema(json: specJSON) } catch { swiftErr = "\(error)" }
            XCTAssertEqual(swiftErr, jsErr.stringValue, "expr \(expr)")
            if let schema {
                let js = try Oracle.shared.value("probeSchema", ["schema": specJSON])
                assertParity(probeSchema(schema), js, "expr \(expr)")
            }
        }
    }
}
