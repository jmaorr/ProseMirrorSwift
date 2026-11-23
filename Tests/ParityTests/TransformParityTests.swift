import XCTest
import PMModel
import PMTransform
import PMOracle

private func i(_ v: JSONValue?) -> Int { v!.intValue! }
private func n(_ x: Int) -> JSONValue { .number(Double(x)) }
private func nOpt(_ x: Int?) -> JSONValue { x.map(n) ?? .null }

/// Replays one recorded op from oracle/src/transform.js on `tr`, returning the
/// same observation record JS produced (minus the inputs, which are copied).
private func replayOp(_ op: JSONValue, _ tr: Transform, _ schema: Schema, _ foreign: Node) -> JSONValue {
    var out = op.objectValue!
    // Outputs are recomputed below; drop JS's versions.
    for k in ["slice", "steps", "doc", "error", "fitted", "dropPoint", "insertPoint", "range", "target", "wrapping",
              "canSplit", "canJoin", "joinPoint"] { out[k] = nil }
    let kind = op["kind"]!.stringValue!
    let stepsBefore = tr.steps.count
    let d = tr.doc
    if op["skip"]?.truthy == true {
        out["steps"] = .array([])
        out["doc"] = tr.doc.toJSON()
        return .object(out)
    }
    do {
        switch kind {
        case "replace", "replaceRange":
            let from = i(op["from"]), to = i(op["to"])
            let slice = d.slice(i(op["a"]), i(op["b"]))
            if kind == "replace" {
                let step = try replaceStep(d, from, to, slice)
                out["fitted"] = step?.toJSON() ?? .null
                try tr.replace(from, to, slice)
            } else {
                try tr.replaceRange(from, to, slice)
            }
        case "replaceForeign", "replaceRangeForeign":
            let from = i(op["from"]), to = i(op["to"])
            let slice = foreign.slice(i(op["a"]), i(op["b"]), includeParents: op["parents"]!.truthy)
            out["dropPoint"] = nOpt(dropPoint(d, from, slice))
            if kind == "replaceForeign" { try tr.replace(from, to, slice) } else { try tr.replaceRange(from, to, slice) }
        case "replaceRangeWith":
            let from = i(op["from"]), to = i(op["to"])
            let type = schema.nodes[op["nodeType"]!.stringValue!]!
            let node: Node = type.isText ? schema.text("zz") : type.createAndFill()!
            out["insertPoint"] = nOpt(insertPoint(d, from, node.type))
            try tr.replaceRangeWith(from, to, node)
        case "deleteRange":
            try tr.deleteRange(i(op["from"]), i(op["to"]))
        case "delete":
            try tr.delete(i(op["from"]), i(op["to"]))
        case "insertText":
            try tr.insert(i(op["pos"]), schema.text(op["text"]!.stringValue!))
        case "addMark":
            try tr.addMark(i(op["from"]), i(op["to"]), try schema.markFromJSON(op["mark"]!))
        case "removeMark":
            let from = i(op["from"]), to = i(op["to"])
            switch i(op["which"]) {
            case 0: try tr.removeMark(from, to, try schema.markFromJSON(op["mark"]!))
            case 1: try tr.removeMark(from, to, schema.marks[op["markType"]!.stringValue!]!)
            default: try tr.removeMark(from, to, nil as Mark?)
            }
        case "setBlockType":
            let type = schema.nodes[op["type"]!.stringValue!]!
            try tr.setBlockType(i(op["from"]), i(op["to"]), type, op["attrs"]?.objectValue)
        case "setNodeMarkup":
            let type = op["type"]?.stringValue.map { schema.nodes[$0]! }
            try tr.setNodeMarkup(i(op["pos"]), type, op["attrs"]?.objectValue)
        case "lift", "wrap":
            let range = d.resolve(i(op["from"])).blockRange(d.resolve(i(op["to"])))
            out["range"] = range.map { ["from": n($0.from.pos), "to": n($0.to.pos), "depth": n($0.depth)] } ?? .null
            guard let range else { break }
            if kind == "lift" {
                let target = liftTarget(range)
                out["target"] = nOpt(target)
                if let target { try tr.lift(range, target) }
            } else {
                let type = schema.nodes[op["type"]!.stringValue!]!
                let wrapping = findWrapping(range, type)
                out["wrapping"] = wrapping.map { .array($0.map { ["type": .string($0.type.name), "attrs": $0.attrs.map { .object($0) } ?? .null] }) } ?? .null
                if let wrapping { try tr.wrap(range, wrapping) }
            }
        case "split":
            let pos = i(op["pos"]), depth = i(op["depth"])
            let typesAfter = op["typesAfter"]?.arrayValue.map { $0.map { NodeTypeWithAttrs(schema.nodes[$0.stringValue!]!) } as [NodeTypeWithAttrs?] }
            let can = canSplit(d, pos, depth, typesAfter)
            out["canSplit"] = .bool(can)
            // JS also splits in some cases where canSplit is false (to test failures); follow the recording.
            if can || jsSplitAnyway(op) { try tr.split(pos, depth, typesAfter) }
        case "join":
            let pos = i(op["pos"]), dir = i(op["dir"])
            let can = canJoin(d, pos)
            out["canJoin"] = .bool(can)
            let point = joinPoint(d, pos, dir)
            out["joinPoint"] = nOpt(point)
            if can { try tr.join(pos) } else if let point, canJoin(d, point) { try tr.join(point) }
        case "setNodeAttribute":
            try tr.setNodeAttribute(i(op["pos"]), op["attr"]!.stringValue!, op["value"] ?? .null)
        case "nodeMark":
            let pos = i(op["pos"]), mark = try schema.markFromJSON(op["mark"]!)
            if op["add"]!.truthy { try tr.addNodeMark(pos, mark) }
            else if op["byType"]!.truthy { try tr.removeNodeMark(pos, mark.type) }
            else { try tr.removeNodeMark(pos, mark) }
        default:
            XCTFail("unknown op \(kind)")
        }
    } catch {
        out["error"] = .string("\(error)")
    }
    out["steps"] = .array(tr.steps[stepsBefore...].map { $0.toJSON() })
    out["doc"] = tr.doc.toJSON()
    return .object(out)
}

/// JS calls split when canSplit is false with probability 0.2; whether it did is
/// visible from the recording (an error or steps).
private func jsSplitAnyway(_ op: JSONValue) -> Bool {
    op["error"] != nil || !(op["steps"]?.arrayValue?.isEmpty ?? true)
}

private func compareOp(_ swift: JSONValue, _ js: JSONValue) -> String? {
    // Error messages may differ in wording; compare presence only.
    var s = swift.objectValue!, j = js.objectValue!
    j["slice"] = nil
    let sErr = s["error"], jErr = j["error"]
    if (sErr == nil) != (jErr == nil) {
        return "error mismatch: Swift \(sErr.map { "\($0)" } ?? "none") vs JS \(jErr.map { "\($0)" } ?? "none")"
    }
    s["error"] = nil
    j["error"] = nil
    return jsonDiff(.object(s), .object(j))
}

func runTransformParity(schemaJSON: JSONValue, schema: Schema, seed: Int, count: Int, ops: Int,
                        file: StaticString = #filePath, line: UInt = #line) throws -> Int {
    let batch = 25
    var done = 0, totalSteps = 0
    while done < count {
        let nCases = min(batch, count - done)
        let cases = try Oracle.shared.value("transformCases", ["schema": schemaJSON, "seed": n(seed + done), "count": n(nCases), "ops": n(ops)])
        for (ci, c) in cases.arrayValue!.enumerated() {
            let caseSeed = seed + done + ci
            if ProcessInfo.processInfo.environment["PM_TRACE"] != nil { print("case seed \(caseSeed)"); fflush(stdout) }
            let doc = try schema.nodeFromJSON(c["doc"]!)
            let foreign = try schema.nodeFromJSON(c["foreign"]!)
            let tr = Transform(doc)
            for (oi, op) in c["ops"]!.arrayValue!.enumerated() {
                let swift = replayOp(op, tr, schema, foreign)
                if let diff = compareOp(swift, op) {
                    XCTFail("seed \(caseSeed) op \(oi) (\(op["kind"]!)): \(diff)\nop: \(op)", file: file, line: line)
                    return totalSteps
                }
            }
            totalSteps += tr.steps.count
            // Mapping / algebra checks
            let checks = c["checks"]!
            var mine = JSONObject()
            mine["changedRange"] = tr.changedRange().map { ["from": n($0.from), "to": n($0.to)] } ?? .null
            mine["maps"] = .array(checks["maps"]!.arrayValue!.map { m in
                let pos = i(m["pos"]), assoc = i(m["assoc"])
                let res = tr.mapping.mapResult(pos, assoc: assoc)
                return ["pos": n(pos), "assoc": n(assoc), "mapped": n(tr.mapping.map(pos, assoc: assoc)),
                        "res": [n(res.pos), .bool(res.deleted), .bool(res.deletedBefore), .bool(res.deletedAfter), .bool(res.deletedAcross)]]
            })
            let inv = tr.mapping.invert()
            mine["invertMaps"] = .array(checks["invertMaps"]!.arrayValue!.map { m in
                let pos = i(m["pos"])
                return ["pos": n(pos), "mapped": n(inv.map(pos)), "mappedBack": n(inv.map(pos, assoc: -1))]
            })
            let undo = Transform(tr.doc)
            var invertError: JSONValue = .null
            do {
                for k in stride(from: tr.steps.count - 1, through: 0, by: -1) { try undo.step(tr.steps[k].invert(tr.docs[k])) }
            } catch { invertError = .string("\(error)") }
            mine["inverted"] = ["doc": undo.doc.toJSON(), "error": invertError, "equal": .bool(undo.doc.eq(doc))]
            mine["rebased"] = .array(tr.steps.indices.map { k in tr.steps[k].map(tr.mapping.slice(k + 1))?.toJSON() ?? .null })
            mine["merges"] = .array(tr.steps.indices.dropLast().map { k in tr.steps[k].merge(tr.steps[k + 1])?.toJSON() ?? .null })
            mine["roundTrip"] = .array(tr.steps.map { s in
                do { return try Step.fromJSON(schema, s.toJSON()).toJSON() } catch { return ["error": .string("\(error)")] }
            })
            var jsChecks = checks.objectValue!
            // Error message wording differs; normalise to presence.
            func normErr(_ v: JSONValue?) -> JSONValue { v.map { $0.isNull ? .null : .bool(true) } ?? .null }
            if case .object(var invJS) = jsChecks["inverted"]! { invJS["error"] = normErr(invJS["error"]); jsChecks["inverted"] = .object(invJS) }
            if case .object(var invMine) = mine["inverted"]! { invMine["error"] = normErr(invMine["error"]); mine["inverted"] = .object(invMine) }
            func normRT(_ v: JSONValue) -> JSONValue { .array(v.arrayValue!.map { $0["error"] != nil && $0["stepType"] == nil ? ["error": true] : $0 }) }
            jsChecks["roundTrip"] = normRT(jsChecks["roundTrip"]!)
            mine["roundTrip"] = normRT(mine["roundTrip"]!)
            if let diff = jsonDiff(.object(mine), .object(jsChecks)) {
                XCTFail("seed \(caseSeed) checks: \(diff)", file: file, line: line)
                return totalSteps
            }
        }
        done += nCases
    }
    return totalSteps
}

final class TransformParityTests: XCTestCase {
    func testRandomEditsBasic() throws {
        let steps = try runTransformParity(schemaJSON: Schemas.basicJSON, schema: Schemas.basic, seed: 1, count: fuzzCount(300), ops: 20)
        print("basic: \(fuzzCount(300) * 20) random ops, \(steps) steps")
    }

    func testRandomEditsTiptap() throws {
        let steps = try runTransformParity(schemaJSON: Schemas.tiptapJSON, schema: Schemas.tiptap, seed: 20_000, count: fuzzCount(300), ops: 20)
        print("tiptap: \(fuzzCount(300) * 20) random ops, \(steps) steps")
    }
}
