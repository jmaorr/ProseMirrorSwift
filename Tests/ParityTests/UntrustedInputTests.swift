import XCTest
import CoreGraphics
import PMModel
import PMTransform
import PMState
import PMTables
import PMMarkdown
#if os(macOS) || os(iOS)
import PMTableView
#endif

/// Documents arrive from collaborators and from the pasteboard, so attribute values and JSON
/// are untrusted. Each case here used to trap (or hang); now it throws or is clamped.
final class UntrustedInputTests: XCTestCase {
    private let basic = Schemas.basic
    private let tiptap = Schemas.tiptap

    private func parse(_ text: String) throws -> JSONValue { try JSONValue.parse(text) }

    private func doc(_ blocks: JSONValue...) throws -> Node {
        try basic.nodeFromJSON(["type": "doc", "content": .array(blocks)])
    }

    private func para(_ text: String) -> JSONValue {
        ["type": "paragraph", "content": [["type": "text", "text": .string(text)]]]
    }

    // MARK: 1. Int conversions

    func testIntValueRejectsNonFiniteAndHugeNumbers() throws {
        XCTAssertNil(try parse("1e400").intValue, "inf")
        XCTAssertNil(try parse("-1e400").intValue, "-inf")
        XCTAssertNil(JSONValue.number(.nan).intValue)
        XCTAssertNil(JSONValue.number(9.3e18).intValue)
        XCTAssertNil(JSONValue.number(-9.3e18).intValue)
        XCTAssertNil(JSONValue.number(9_223_372_036_854_775_808).intValue, "2^63")
        XCTAssertEqual(JSONValue.number(2.7).intValue, 2)
        XCTAssertEqual(JSONValue.number(-2.7).intValue, -2)
        XCTAssertEqual(JSONValue.number(1e12).intValue, 1_000_000_000_000)
        XCTAssertNil(JSONValue.safeInt(1e17))
        XCTAssertEqual(JSONValue.safeInt(9_007_199_254_740_992), 9_007_199_254_740_992)
    }

    func testHugeAttrsInDocumentJSON() throws {
        let node = try basic.nodeFromJSON(try parse(
            #"{"type":"doc","content":[{"type":"heading","attrs":{"level":1e400},"content":[{"type":"text","text":"x"}]}]}"#))
        XCTAssertNil(node.child(0).attrs["level"]?.intValue)
        // Serializing an infinite attr gives JSON.stringify's null, not a trap.
        XCTAssertTrue(node.toJSON().description.contains(#""level":null"#))
    }

    func testStepJSONWithHugePositionsThrows() throws {
        for text in [#"{"stepType":"replace","from":1e400,"to":1}"#,
                     #"{"stepType":"replace","from":0,"to":9.3e18}"#,
                     #"{"stepType":"replaceAround","from":0,"to":1,"gapFrom":-1e400,"gapTo":1,"insert":0}"#,
                     #"{"stepType":"addMark","from":1e300,"to":1,"mark":{"type":"em"}}"#,
                     #"{"stepType":"addNodeMark","pos":1e20,"mark":{"type":"em"}}"#,
                     #"{"stepType":"attr","pos":1e400,"attr":"level","value":1}"#] {
            XCTAssertThrowsError(try Step.fromJSON(basic, try parse(text)), text)
        }
        XCTAssertNoThrow(try Step.fromJSON(basic, try parse(#"{"stepType":"replace","from":1,"to":2}"#)))
    }

    func testSelectionJSONWithBadPositionsThrows() throws {
        registerCellSelection()
        let d = try doc(para("hello"))
        for text in [#"{"type":"text","anchor":1e400,"head":1}"#,
                     #"{"type":"text","anchor":1,"head":-1}"#,
                     #"{"type":"text","anchor":1,"head":99999}"#,
                     #"{"type":"node","anchor":1e400}"#,
                     #"{"type":"node","anchor":7}"#, // the end of the doc: no node after
                     #"{"type":"cell","anchor":1e400,"head":1}"#,
                     #"{"type":"cell","anchor":1,"head":2}"#] { // not in a table
            XCTAssertThrowsError(try Selection.fromJSON(d, try parse(text)), text)
        }
        XCTAssertEqual(try Selection.fromJSON(d, try parse(#"{"type":"text","anchor":2,"head":4}"#)).to, 4)
    }

    // MARK: 2. Number formatting

    func testFormatNumberPastInt64MatchesJS() {
        // Expected strings are what JS's String(n) prints.
        XCTAssertEqual(JSONValue.number(9.3e18).description, "9300000000000000000")
        XCTAssertEqual(JSONValue.number(-9.3e18).description, "-9300000000000000000")
        XCTAssertEqual(JSONValue.number(9_223_372_036_854_777_856).description, "9223372036854778000")
        XCTAssertEqual(JSONValue.number(1e20).description, "100000000000000000000")
        XCTAssertEqual(JSONValue.number(1_152_921_504_606_846_976).description, "1152921504606847000")
        XCTAssertEqual(JSONValue.number(999_999_999_999_999_868_928).description, "999999999999999900000")
        XCTAssertEqual(JSONValue.number(9_007_199_254_740_992).description, "9007199254740992")
        XCTAssertEqual(JSONValue.number(9_007_199_254_740_991).description, "9007199254740991")
        XCTAssertEqual(JSONValue.number(1e21).description, "1e+21")
        XCTAssertEqual(JSONValue.number(42).description, "42")
        XCTAssertEqual(JSONValue.number(-0.5).description, "-0.5")
        XCTAssertEqual(JSONValue.number(.infinity).description, "null")
    }

    // MARK: 3. Slices

    func testSliceJSONOpenDepths() throws {
        let content = #"[{"type":"blockquote","content":[{"type":"paragraph","content":[{"type":"text","text":"x"}]}]}]"#
        func slice(_ open: String) throws -> Slice {
            try Slice.fromJSON(basic, try parse(#"{"content":\#(content),\#(open)}"#))
        }
        for bad in [#""openStart":1e400"#, #""openEnd":1e400"#, #""openStart":-1"#, #""openEnd":-1"#,
                    #""openStart":1.5"#, #""openStart":3"#, #""openEnd":3"#, #""openStart":"1""#,
                    #""openStart":9.3e18"#] {
            XCTAssertThrowsError(try slice(bad), bad)
        }
        let ok = try slice(#""openStart":2,"openEnd":1"#)
        XCTAssertEqual(ok.openStart, 2)
        XCTAssertEqual(ok.openEnd, 1)
        XCTAssertEqual(ok.size, ok.content.size - 3)
        // Open depth on an empty paragraph: it can be open (1), not deeper.
        XCTAssertNoThrow(try Slice.fromJSON(basic, try parse(#"{"content":[{"type":"paragraph"}],"openStart":1,"openEnd":1}"#)))
        XCTAssertThrowsError(try Slice.fromJSON(basic, try parse(#"{"content":[{"type":"paragraph"}],"openStart":2}"#)))
        // A leaf can't be open at all.
        XCTAssertThrowsError(try Slice.fromJSON(basic, try parse(#"{"content":[{"type":"horizontal_rule"}],"openStart":1}"#)))
    }

    func testRemoveBetweenThrowsForBadRanges() throws {
        let s = try Slice.fromJSON(basic, try parse(
            #"{"content":[{"type":"paragraph","content":[{"type":"text","text":"ab"}]},{"type":"paragraph","content":[{"type":"text","text":"cd"}]}]}"#))
        XCTAssertThrowsError(try s.removeBetween(-1, 1))
        XCTAssertThrowsError(try s.removeBetween(0, 100))
        XCTAssertThrowsError(try s.removeBetween(3, 1))
        XCTAssertThrowsError(try s.removeBetween(2, 6), "non-flat")
        XCTAssertEqual(try s.removeBetween(1, 2).content.size, s.content.size - 1)
    }

    // MARK: 4. Nesting depth

    func testDeeplyNestedJSONTextThrows() {
        let deep = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
        XCTAssertThrowsError(try JSONValue.parse(deep))
        let deepObj = String(repeating: #"{"a":"#, count: 10_000) + "1" + String(repeating: "}", count: 10_000)
        XCTAssertThrowsError(try JSONValue.parse(deepObj))
        let limit = JSONValue.maxNestingDepth
        XCTAssertNoThrow(try JSONValue.parse(String(repeating: "[", count: limit) + String(repeating: "]", count: limit)))
        XCTAssertThrowsError(try JSONValue.parse(String(repeating: "[", count: limit + 1) + String(repeating: "]", count: limit + 1)))
    }

    func testDeeplyNestedNodeJSONThrows() throws {
        // Built in code (as a collaborator's document would be), not parsed, so only
        // Node.fromJSON's own limit stands between it and the stack.
        var node: JSONValue = para("x")
        for _ in 0..<10_000 { node = ["type": "blockquote", "content": [node]] }
        XCTAssertThrowsError(try basic.nodeFromJSON(["type": "doc", "content": [node]]))
        XCTAssertThrowsError(try Slice.fromJSON(basic, ["content": [node]]))

        var shallow: JSONValue = para("x")
        for _ in 0..<100 { shallow = ["type": "blockquote", "content": [shallow]] }
        XCTAssertNoThrow(try basic.nodeFromJSON(["type": "doc", "content": [shallow]]))
    }

    func testDeeplyNestedAttrsThrow() throws {
        var deep: JSONValue = 1
        for _ in 0..<10_000 { deep = [deep] }
        let mark: JSONValue = ["type": "link", "attrs": ["href": deep]]
        XCTAssertThrowsError(try basic.markFromJSON(mark))
        let text: JSONValue = ["type": "text", "text": "x", "marks": [mark]]
        XCTAssertThrowsError(try basic.nodeFromJSON(["type": "paragraph", "content": [text]]))
        XCTAssertThrowsError(try basic.nodeFromJSON(["type": "heading", "attrs": ["level": deep]]))
    }

    // MARK: 5. Tables

    private func cell(colspan: JSONValue = 1, rowspan: JSONValue = 1, colwidth: JSONValue = .null) -> JSONValue {
        ["type": "tableCell", "attrs": ["colspan": colspan, "rowspan": rowspan, "colwidth": colwidth],
         "content": [["type": "paragraph"]]]
    }

    private func table(_ rows: [[JSONValue]]) throws -> Node {
        try tiptap.nodeFromJSON(["type": "table", "content": .array(rows.map { ["type": "tableRow", "content": .array($0)] })])
    }

    func testCellSpansAreClamped() throws {
        XCTAssertEqual(cellSpan(JSONObject([("colspan", -1)]), "colspan"), 1)
        XCTAssertEqual(cellSpan(JSONObject([("colspan", 0)]), "colspan"), 1)
        XCTAssertEqual(cellSpan(JSONObject([("colspan", 1e12)]), "colspan"), maxCellSpan)
        XCTAssertEqual(cellSpan(JSONObject([("colspan", try parse("1e400"))]), "colspan"), 1)
        XCTAssertEqual(cellSpan(JSONObject([("colspan", "3")]), "colspan"), 1)
        XCTAssertEqual(cellSpan(JSONObject([("rowspan", 3)]), "rowspan"), 3)

        let negative = try TableMap.get(try table([[cell(colspan: -1), cell()], [cell(rowspan: -1), cell()]]))
        XCTAssertEqual(negative.width, 2)
        XCTAssertEqual(negative.height, 2)

        let huge = try TableMap.get(try table([[cell(colspan: 1e12)], [cell(rowspan: 1e12)]]))
        XCTAssertEqual(huge.width, maxCellSpan)
        XCTAssertEqual(huge.height, 2)
        XCTAssertNotNil(huge.problems)

        let infinite = try TableMap.get(try table([[cell(colspan: try parse("1e400"), rowspan: try parse("-1e400"))]]))
        XCTAssertEqual(infinite.width, 1)
    }

    func testAbsurdTablesAreRejected() throws {
        // 2000 cells of colspan 1000: a 2,000,000-wide grid.
        let wide = try table([Array(repeating: cell(colspan: 1e12), count: 2000)])
        XCTAssertThrowsError(try TableMap.get(wide))
        // Overlapping spans: few slots, but each cell would visit 1000 × 1000 of them.
        let rows = (0..<5).map { _ in [cell(colspan: 1000, rowspan: 1000)] }
        let overlapping = try table(rows + Array(repeating: [cell()], count: 995))
        XCTAssertThrowsError(try TableMap.get(overlapping))
    }

    func testPastedCellsWithHostileSpans() throws {
        let t = try table([[cell(colspan: -1, rowspan: -1), cell(colspan: 1e12)], [cell(rowspan: try parse("1e400")), cell()]])
        let pasted = pastedCells(Slice(Fragment.from(t), 1, 1))
        XCTAssertNotNil(pasted)
        XCTAssertLessThanOrEqual(pasted!.width, maxCellSpan + 1)
    }

    #if os(macOS) || os(iOS)
    func testTableLayoutClampsHostileFirstRow() throws {
        // The map of an ordinary 2 × 1 table, laid out against a first row whose spans and
        // widths are hostile: the layout must stay within the map's columns.
        let plain = try table([[cell(), cell()]])
        let map = try TableMap.get(plain)
        for colspan: JSONValue in [-1, 1e12, try parse("1e400"), 0] {
            let hostile = try table([[cell(colspan: colspan, colwidth: [1e300, 1e300]), cell()]])
            let layout = TableLayout.make(table: hostile, map: map, availableWidth: 600, style: TableStyle(),
                                          contentHeight: { _, _ in 20 })
            XCTAssertEqual(layout.columnWidths.count, 2, "\(colspan)")
            XCTAssertTrue(layout.size.width.isFinite)
            XCTAssertLessThanOrEqual(layout.columnWidths[0], TableLayout.maxColumnWidth)
        }
        let hugeTable = try table([[cell(colspan: 1e12)]])
        let layout = TableLayout.make(table: hugeTable, map: try TableMap.get(hugeTable), availableWidth: 600,
                                      style: TableStyle(), contentHeight: { _, _ in 20 })
        XCTAssertEqual(layout.columnWidths.count, maxCellSpan)
    }
    #endif

    // MARK: 6. Markdown

    private func markdown(_ blocks: JSONValue...) throws -> String {
        try MarkdownSerializer.default.serialize(try basic.nodeFromJSON(["type": "doc", "content": .array(blocks)]))
    }

    func testHeadingLevelIsClamped() throws {
        let text: JSONValue = [["type": "text", "text": "x"]]
        XCTAssertEqual(try markdown(["type": "heading", "attrs": ["level": 1e12], "content": text]), "###### x")
        XCTAssertEqual(try markdown(["type": "heading", "attrs": ["level": -5], "content": text]), "# x")
        XCTAssertEqual(try markdown(["type": "heading", "attrs": ["level": try parse("1e400")], "content": text]), "# x")
        XCTAssertEqual(try markdown(["type": "heading", "attrs": ["level": 3], "content": text]), "### x")
    }

    func testOrderedListStartCantOverflow() throws {
        let items: JSONValue = [["type": "list_item", "content": [para("a")]], ["type": "list_item", "content": [para("b")]]]
        for order: JSONValue in [9.2e18, -9.2e18, try parse("1e400")] {
            XCTAssertNoThrow(try markdown(["type": "ordered_list", "attrs": ["order": order], "content": items]), "\(order)")
        }
        XCTAssertEqual(try markdown(["type": "ordered_list", "attrs": ["order": 9], "content": items]), " 9. a\n\n10. b")
    }

    func testLinkHrefCantInjectBlocks() throws {
        let link: JSONValue = ["type": "paragraph", "content": [
            ["type": "text", "text": "click", "marks": [["type": "link", "attrs": ["href": "http://a\n# x\r\nb", "title": "t\n\n# y"]]]]]]
        let md = try markdown(link)
        XCTAssertEqual(md, #"[click](http://a%0A# x%0D%0Ab "t  # y")"#)
        XCTAssertFalse(md.contains("\n"))

        // An autolink (text equal to the href) with a line break goes out in brackets, encoded.
        let auto: JSONValue = ["type": "paragraph", "content": [
            ["type": "text", "text": "http://a\n# x", "marks": [["type": "link", "attrs": ["href": "http://a\n# x"]]]]]]
        XCTAssertFalse(try markdown(auto).contains("<http"))
        XCTAssertTrue(try markdown(auto).contains("](http://a%0A# x)"))

        // Ordinary URLs are written exactly as prosemirror-markdown writes them.
        let plain: JSONValue = ["type": "paragraph", "content": [
            ["type": "text", "text": "c", "marks": [["type": "link", "attrs": ["href": "http://a/(b) c"]]]]]]
        XCTAssertEqual(try markdown(plain), #"[c](http://a/\(b\) c)"#)
    }

    func testImageSrcCantInjectBlocks() throws {
        let image: JSONValue = ["type": "paragraph", "content": [
            ["type": "image", "attrs": ["src": "http://a\n\n# x", "alt": "a\n\nb", "title": "t\r\nu"]]]]
        XCTAssertEqual(try markdown(image), #"![a  b](http://a%0A%0A# x "t u")"#)
    }
}
