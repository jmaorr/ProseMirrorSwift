import XCTest
import PMModel
import PMOracle

final class HarnessTests: XCTestCase {
    func testOracleLoads() throws {
        XCTAssertEqual(try Oracle.shared.value("ping"), "pong")
    }

    func testJSONRoundTripMatchesJS() throws {
        let schema = try Fixtures.json("schemas/basic.json")
        let doc: JSONValue = [
            "type": "doc",
            "content": [
                ["type": "heading", "attrs": ["level": 2], "content": [["type": "text", "text": "Hi \"there\" ✨"]]],
                ["type": "paragraph", "content": [
                    ["type": "text", "text": "bold", "marks": [["type": "strong"]]],
                    ["type": "text", "text": " plain"],
                ]],
            ],
        ]
        let js = try Oracle.shared.value("roundTrip", ["schema": schema, "doc": doc])
        // Swift side: serialize + reparse through our JSON layer.
        let swift = try JSONValue.parse(doc.serialized())
        XCTAssertEqual(js["doc"], swift)
    }
}
