import XCTest
import PMModel
import PMOracle
import PMTables

/// Seeded tables from the oracle (well-formed and malformed), shared by the table tests.
enum TableCorpus {
    static func docs(seed: Int, count: Int) throws -> [Node] {
        let json = try Oracle.shared.value("tableCorpus", ["seed": .int(seed), "count": .int(count)])
        return try (json.arrayValue ?? []).map { try Schemas.tiptap.nodeFromJSON($0) }
    }

    /// Every table in `doc`, in document order, with the position before it.
    static func tables(_ doc: Node) -> [(node: Node, pos: Int)] {
        var out: [(Node, Int)] = []
        doc.descendants { node, pos, _, _ in
            if node.type.spec.extra["tableRole"]?.stringValue == "table" { out.append((node, pos)) }
            return true
        }
        return out
    }
}

/// Mirrors the oracle's `catching`: `{ok: value}` or `{error: message}`.
func catching(_ f: () throws -> JSONValue) -> JSONValue {
    do { return .object(JSONObject([("ok", try f())])) } catch {
        return .object(JSONObject([("error", .string("\(error)"))]))
    }
}

final class TableMapParityTests: XCTestCase {
    private func mapsJSON(_ doc: Node) throws -> JSONValue {
        .array(try TableCorpus.tables(doc).map { table, pos in
            var o = JSONObject([("pos", .int(pos))])
            for (k, v) in try TableMap.get(table).toJSON().objectValue! { o[k] = v }
            return .object(o)
        })
    }

    func testTableMapParity() throws {
        for (i, doc) in try TableCorpus.docs(seed: 1, count: fuzzCount(300)).enumerated() {
            let js = try Oracle.shared.value("tableMap", ["schema": Schemas.tiptapJSON, "doc": doc.toJSON()])
            assertParity(try mapsJSON(doc), js, "case \(i)")
        }
    }

    func testTableMapQueries() throws {
        for (i, doc) in try TableCorpus.docs(seed: 1000, count: fuzzCount(150)).enumerated() {
            let js = try Oracle.shared.value("tableMapQueries", ["schema": Schemas.tiptapJSON, "doc": doc.toJSON(), "seed": .int(i)])
            for (t, (table, _)) in TableCorpus.tables(doc).enumerated() {
                let map = try TableMap.get(table)
                guard let jsTable = js[t] else { return XCTFail("case \(i): JS has no table \(t)") }
                for jsCell in jsTable["cells"]?.arrayValue ?? [] {
                    let cell = jsCell["cell"]!.intValue!, other = jsCell["other"]!.intValue!
                    let rect = try? map.rectBetween(cell, other)
                    let swift: JSONValue = .object(JSONObject([
                        ("cell", .int(cell)), ("other", .int(other)),
                        ("findCell", catching { try map.findCell(cell).toJSON() }),
                        ("colCount", catching { .int(try map.colCount(cell)) }),
                        ("next", .array([("horiz", -1), ("horiz", 1), ("vert", -1), ("vert", 1)].map { axis, dir in
                            catching { try map.nextCell(cell, axis: axis, dir: dir).map { .int($0) } ?? .null } })),
                        ("rectBetween", catching { try map.rectBetween(cell, other).toJSON() }),
                        ("cellsInRect", rect.map { r in catching { .array(map.cellsInRect(r).map { .int($0) }) } } ?? .null),
                    ]))
                    assertParity(swift, jsCell, "case \(i) table \(t) cell \(cell)")
                }
                let positions: JSONValue = .array((0..<map.height).map { row in
                    .array((0..<map.width).map { col in catching { .int(map.positionAt(row: row, col: col, table: table)) } })
                })
                assertParity(positions, jsTable["positionAt"]!, "case \(i) table \(t) positionAt")
            }
        }
    }
}

final class TableUtilParityTests: XCTestCase {
    func testUtilParity() throws {
        for (i, doc) in try TableCorpus.docs(seed: 2000, count: fuzzCount(80)).enumerated() {
            let js = try Oracle.shared.value("tableUtilCases", ["schema": Schemas.tiptapJSON, "doc": doc.toJSON(), "seed": .int(i)])
            for jsPos in js["positions"]?.arrayValue ?? [] {
                let pos = jsPos["pos"]!.intValue!
                let resolved = doc.resolve(pos)
                let cell = cellAround(resolved)
                var o = JSONObject([("pos", .int(pos)), ("cellAround", cell.map { .int($0.pos) } ?? .null),
                                    ("cellNear", cellNear(resolved).map { .int($0.pos) } ?? .null)])
                if let cell {
                    o["findCell"] = catching { try findCell(cell).toJSON() }
                    o["colCount"] = catching { .int(try colCount(cell)) }
                    o["next"] = .array([("horiz", -1), ("horiz", 1), ("vert", -1), ("vert", 1)].map { axis, dir in
                        catching { try nextCell(cell, axis: axis, dir: dir).map { .int($0.pos) } ?? .null } })
                    let at = jsPos["colspan"]!["at"]!.intValue!, n = jsPos["colspan"]!["n"]!.intValue!
                    let attrs = cell.nodeAfter!.attrs
                    o["colspan"] = .object(JSONObject([("at", .int(at)), ("n", .int(n)),
                                                       ("remove", .object(removeColSpan(attrs, pos: at, n: n))),
                                                       ("add", .object(addColSpan(attrs, pos: at, n: n)))]))
                }
                assertParity(.object(o), jsPos, "case \(i) pos \(pos)")
            }
            let headers: JSONValue = .array(try TableCorpus.tables(doc).map { table, _ in
                let map = try TableMap.get(table)
                return .array((0..<map.width).map { col in catching { .bool(columnIsHeader(map, table, col)) } })
            })
            assertParity(headers, js["headers"]!, "case \(i) headers")
        }
    }
}
