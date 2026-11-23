import XCTest
import PMModel
import PMOracle
import PMMarkdown

/// Markdown output against the JS oracle: prosemirror-markdown's default serializer on its own
/// schema, and tiptap-markdown's serializer (TiptapMarkdownSerializerState with tiptap-markdown's
/// StarterKit rules) on the tiptap test schema.
final class MarkdownParityTests: XCTestCase {
    func testDefaultSerializerMatchesJS() throws {
        let schema = try Schema(json: try Oracle.shared.value("markdownSchema"))
        let count = fuzzCount(300)
        let cases = try Oracle.shared.value("defaultMarkdownCases", ["seed": .int(7000), "count": .int(count)])
        var failures = 0
        for c in cases.arrayValue ?? [] {
            let doc = try schema.nodeFromJSON(c["doc"]!)
            // JS throws on docs real notes don't have (an image with no src); skip those.
            guard c["md"]?.stringValue != nil else { continue }
            let tight = c["tight"]?.boolValue ?? false
            let swift = try? MarkdownSerializer.default.serialize(doc, tightLists: tight)
            let js = c["md"]?.stringValue
            if swift != js {
                failures += 1
                if failures <= 3 { XCTFail("doc \(c["doc"]!)\nJS:    \(js.debugDescription)\nSwift: \(swift.debugDescription)") }
            }
        }
        XCTAssertEqual(failures, 0, "\(failures) of \(count) differ")
    }

    func testTiptapSerializerMatchesJS() throws {
        let schema = Schemas.tiptap
        let count = fuzzCount(300)
        let cases = try Oracle.shared.value("tiptapMarkdownCases", ["schema": Schemas.tiptapJSON, "seed": .int(9000), "count": .int(count)])
        var failures = 0, compared = 0
        for c in cases.arrayValue ?? [] {
            let doc = try schema.nodeFromJSON(c["doc"]!)
            guard let js = c["md"]?.stringValue else { continue }
            let swift = try? TiptapMarkdownRules.serializer.serialize(doc)
            compared += 1
            if swift != js {
                failures += 1
                if failures <= 3 { XCTFail("doc \(c["doc"]!)\nJS:    \(js.debugDescription)\nSwift: \(swift.debugDescription)") }
            }
        }
        XCTAssertEqual(compared, count)
        XCTAssertEqual(failures, 0, "\(failures) of \(compared) differ")
    }

    /// The shapes people write, spelled out, against the JS: emphasis around whitespace is
    /// shifted inwards (tiptap-markdown's trimInline), task items, and adjacent ordered lists
    /// (kept apart by an extra blank line and alternating `.` and `)`).
    func testTiptapExamples() throws {
        let schema = Schemas.tiptap
        let json: JSONValue = ["type": "doc", "content": [
            ["type": "heading", "attrs": ["level": 1], "content": [["type": "text", "text": "Plan"]]],
            ["type": "paragraph", "content": [
                ["type": "text", "text": "Ship"], ["type": "text", "text": " today ", "marks": [["type": "bold"]]],
                ["type": "text", "text": "and "], ["type": "text", "text": "gone", "marks": [["type": "strike"]]],
                ["type": "hardBreak"], ["type": "text", "text": "a <tag>"]]],
            ["type": "taskList", "content": [
                ["type": "taskItem", "attrs": ["checked": true], "content": [["type": "paragraph", "content": [["type": "text", "text": "Done"]]]]],
                ["type": "taskItem", "attrs": ["checked": false], "content": [["type": "paragraph", "content": [["type": "text", "text": "Next"]]]]]]],
            ["type": "orderedList", "attrs": ["start": 1], "content": [
                ["type": "listItem", "content": [["type": "paragraph", "content": [["type": "text", "text": "one"]]]]]]],
            ["type": "orderedList", "attrs": ["start": 1], "content": [
                ["type": "listItem", "content": [["type": "paragraph", "content": [["type": "text", "text": "again"]]]]]]],
        ]]
        let doc = try schema.nodeFromJSON(json)
        let expected = """
        # Plan

        Ship **today** and ~~gone~~\\
        a &lt;tag&gt;

        - [x] Done
        - [ ] Next

        1. one


        1) again
        """
        XCTAssertEqual(try TiptapMarkdownRules.serializer.serialize(doc), expected)
        XCTAssertEqual(try Oracle.shared.value("tiptapMarkdown", ["schema": Schemas.tiptapJSON, "doc": json]).stringValue, expected)
    }
}
