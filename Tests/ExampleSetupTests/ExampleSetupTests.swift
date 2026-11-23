import XCTest
import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import PMModel
import PMState
import PMCommands
import PMKeymap
import PMTextKit
import PMTables
import PMExampleSetup
import YSync

/// A view without a screen: enough for plugins' key and text input handlers.
private final class HeadlessView: EditorView {
    var state: EditorState
    var composing = false
    init(_ state: EditorState) { self.state = state }
    func dispatch(_ tr: Transaction) { state = state.apply(tr) }
    func endOfTextblock(_ dir: String, _ state: EditorState?) -> Bool {
        let head = (state ?? self.state).selection.headPos
        if dir == "backward" || dir == "left" || dir == "up" { return head.parentOffset == 0 }
        return head.parentOffset == head.parent.content.size
    }

    /// Types `text` one character at a time, as a text view would: input rules first, then an insertion.
    func type(_ text: String) {
        for ch in text {
            let s = String(ch), sel = state.selection
            if state.plugins.contains(where: { $0.props.handleTextInput?(self, sel.from, sel.to, s) == true }) { continue }
            dispatch(try! state.tr.insertText(s, sel.from, sel.to))
        }
    }

    @discardableResult
    func press(_ event: KeyEvent) -> Bool {
        state.plugins.contains { $0.props.handleKeyDown?(self, event) == true }
    }
}

final class ExampleSetupTests: XCTestCase {
    let schema = BasicSchema.schema

    private func view(_ doc: Node, selection: (Node) -> Selection = { Selection.atEnd($0) }) -> HeadlessView {
        HeadlessView(EditorState.create(EditorStateConfig(doc: doc, selection: selection(doc), plugins: exampleSetup(schema: schema))))
    }

    private func emptyDoc() throws -> Node {
        try schema.node("doc", nil, [try schema.node("paragraph")])
    }

    // MARK: Schema

    func testSchemaMatchesBasicFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../fixtures/schemas/basic.json").standardized
        let fixture = try Schema(json: try JSONValue.parse(String(contentsOf: url, encoding: .utf8)))

        // The fixture's nodes come first, in the same order; the table nodes follow.
        let names = schema.nodeTypes.map(\.name)
        XCTAssertEqual(Array(names.prefix(fixture.nodeTypes.count)), fixture.nodeTypes.map(\.name))
        XCTAssertEqual(Array(names.dropFirst(fixture.nodeTypes.count)), ["table", "table_row", "table_cell", "table_header"])

        for expected in fixture.nodeTypes {
            let a = try XCTUnwrap(schema.nodes[expected.name]).spec, b = expected.spec
            let name = expected.name
            XCTAssertEqual(a.content, b.content, name)
            XCTAssertEqual(a.marks, b.marks, name)
            XCTAssertEqual(a.group, b.group, name)
            XCTAssertEqual(a.inline, b.inline, name)
            XCTAssertEqual(a.atom, b.atom, name)
            XCTAssertEqual(a.selectable, b.selectable, name)
            XCTAssertEqual(a.draggable, b.draggable, name)
            XCTAssertEqual(a.code, b.code, name)
            XCTAssertEqual(a.defining, b.defining, name)
            XCTAssertEqual(a.isolating, b.isolating, name)
            XCTAssertEqual(a.attrs.map(\.0), b.attrs.map(\.0), name)
            for ((attr, x), (_, y)) in zip(a.attrs, b.attrs) {
                XCTAssertEqual(x.default, y.default, "\(name).\(attr)")
                XCTAssertEqual(x.validateType, y.validateType, "\(name).\(attr)")
            }
        }
        XCTAssertEqual(schema.markTypes.map(\.name), fixture.markTypes.map(\.name))
        for expected in fixture.markTypes {
            let a = try XCTUnwrap(schema.marks[expected.name]).spec, b = expected.spec
            XCTAssertEqual(a.inclusive, b.inclusive, expected.name)
            XCTAssertEqual(a.code, b.code, expected.name)
            XCTAssertEqual(a.excludes, b.excludes, expected.name)
            XCTAssertEqual(a.attrs.map(\.0), b.attrs.map(\.0), expected.name)
            for ((attr, x), (_, y)) in zip(a.attrs, b.attrs) {
                XCTAssertEqual(x.default, y.default, "\(expected.name).\(attr)")
                XCTAssertEqual(x.validateType, y.validateType, "\(expected.name).\(attr)")
            }
        }

        let roles = tableNodeTypes(schema)
        XCTAssertEqual(roles[.table]?.name, "table")
        XCTAssertEqual(roles[.row]?.name, "table_row")
        XCTAssertEqual(roles[.cell]?.name, "table_cell")
        XCTAssertEqual(roles[.headerCell]?.name, "table_header")
    }

    func testSampleDocumentUsesEveryNodeAndRoundTrips() throws {
        let doc = BasicSchema.sampleDocument
        try doc.check()
        var used = Set<String>()
        doc.descendants { node, _, _, _ in
            used.insert(node.type.name)
            for mark in node.marks { used.insert(mark.type.name) }
            return true
        }
        used.insert(doc.type.name)
        XCTAssertEqual(used, Set(schema.nodeTypes.map(\.name) + schema.markTypes.map(\.name)))
        XCTAssertTrue(try schema.nodeFromJSON(doc.toJSON()).eq(doc))
    }

    func testSampleDocumentSyncsThroughYSync() throws {
        // What ExampleEditor does on joining an empty room, then a second editor joining it.
        let first = YDocument()
        YSyncBinding(doc: first, schema: schema).seed(BasicSchema.sampleDocument)
        let second = YDocument()
        XCTAssertTrue(second.applyUpdate(first.encodeStateAsUpdate()))
        let doc = try XCTUnwrap(YSyncBinding(doc: second, schema: schema).documentFromY())
        XCTAssertTrue(doc.eq(BasicSchema.sampleDocument))
    }

    // MARK: Input rules

    func testHashSpaceMakesAHeading() throws {
        let v = view(try emptyDoc())
        v.type("## Title")
        let block = try XCTUnwrap(v.state.doc.firstChild)
        XCTAssertEqual(block.type.name, "heading")
        XCTAssertEqual(block.attrs["level"]?.intValue, 2)
        XCTAssertEqual(block.textContent, "Title")
    }

    func testDashSpaceMakesABulletList() throws {
        let v = view(try emptyDoc())
        v.type("- item")
        let list = try XCTUnwrap(v.state.doc.firstChild)
        XCTAssertEqual(list.type.name, "bullet_list")
        XCTAssertEqual(list.firstChild?.type.name, "list_item")
        XCTAssertEqual(list.textContent, "item")
    }

    func testOtherInputRules() throws {
        var v = view(try emptyDoc())
        v.type("3. third")
        XCTAssertEqual(v.state.doc.firstChild?.type.name, "ordered_list")
        XCTAssertEqual(v.state.doc.firstChild?.attrs["order"]?.intValue, 3)

        v = view(try emptyDoc())
        v.type("> quoted")
        XCTAssertEqual(v.state.doc.firstChild?.type.name, "blockquote")

        v = view(try emptyDoc())
        v.type("```")
        XCTAssertEqual(v.state.doc.firstChild?.type.name, "code_block")

        v = view(try emptyDoc())
        v.type("\"Wait...\" -- she said")
        XCTAssertEqual(v.state.doc.textContent, "\u{201C}Wait\u{2026}\u{201D} \u{2014} she said")
    }

    // MARK: Keymap

    func testModBTogglesStrong() throws {
        let doc = try schema.node("doc", nil, [try schema.node("paragraph", nil, [schema.text("hello")])])
        let v = view(doc) { TextSelection.create($0, 1, 6) }
        let strong = try XCTUnwrap(schema.marks["strong"])
        XCTAssertTrue(v.press(KeyEvent(key: "b", keyCode: 66, metaKey: true)))
        XCTAssertTrue(v.state.doc.rangeHasMark(1, 6, strong))
        XCTAssertTrue(v.press(KeyEvent(key: "b", keyCode: 66, metaKey: true)))
        XCTAssertFalse(v.state.doc.rangeHasMark(1, 6, strong))
    }

    func testListAndHeadingKeys() throws {
        let v = view(try emptyDoc())
        v.type("- one")
        XCTAssertTrue(v.press(KeyEvent(key: "Enter", keyCode: 13)))
        v.type("two")
        XCTAssertTrue(v.press(KeyEvent(key: "Tab", keyCode: 9)))
        let list = try XCTUnwrap(v.state.doc.firstChild)
        XCTAssertEqual(list.childCount, 1, "the second item nests inside the first")
        XCTAssertEqual(list.firstChild?.lastChild?.type.name, "bullet_list")

        let h = view(try emptyDoc())
        XCTAssertTrue(h.press(KeyEvent(key: "3", keyCode: 51, shiftKey: true, ctrlKey: true)))
        XCTAssertEqual(h.state.doc.firstChild?.type.name, "heading")
        XCTAssertEqual(h.state.doc.firstChild?.attrs["level"]?.intValue, 3)
    }

    func testUndoAndInsertTable() throws {
        let v = view(try emptyDoc())
        v.type("abc")
        XCTAssertTrue(v.press(KeyEvent(key: "z", keyCode: 90, metaKey: true)))
        XCTAssertEqual(v.state.doc.textContent, "")

        XCTAssertTrue(insertTable(schema: schema, rows: 2, cols: 3)(v.state, v.dispatch, v))
        let table = try XCTUnwrap(v.state.doc.firstChild)
        XCTAssertEqual(table.type.name, "table")
        XCTAssertEqual(table.childCount, 2)
        XCTAssertEqual(table.firstChild?.firstChild?.type.name, "table_header")
        XCTAssertEqual(table.lastChild?.firstChild?.type.name, "table_cell")
        // The caret is in the first cell.
        XCTAssertEqual(v.state.selection.fromPos.node(-1).type.name, "table_header")
    }

    // MARK: Style

    #if os(macOS)
    @MainActor
    func testBasicStyleRendersEveryNode() throws {
        let doc = BasicSchema.sampleDocument
        let state = EditorState.create(EditorStateConfig(doc: doc, plugins: exampleSetup(schema: schema)))
        let textView = BasicStyle().makeTextView(state: state)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertGreaterThan(storage.length, 0)

        func font(ofBlock index: Int) throws -> NSFont {
            let span = textView.renderer.spans[index]
            return try XCTUnwrap(storage.attribute(.font, at: span.strStart, effectiveRange: nil) as? NSFont)
        }
        // The sample starts with a level 1 heading and then a paragraph.
        XCTAssertEqual(doc.child(0).type.name, "heading")
        XCTAssertEqual(doc.child(1).type.name, "paragraph")
        XCTAssertGreaterThan(try font(ofBlock: 0).pointSize, try font(ofBlock: 1).pointSize)

        // The table is one embedded grid.
        var tables = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value.map({ String(describing: type(of: $0)) }) == "TableAttachment" { tables += 1 }
        }
        XCTAssertEqual(tables, 1)
        XCTAssertEqual(textView.renderer.spans.filter { $0.embedSize != nil }.count, 1)

        // Lay it out (TextKit draws nothing here, but sizes everything) and edit it.
        textView.layoutSubtreeIfNeeded()
        textView.dispatch(try textView.state.tr.insertText("Edited: ", 1))
        XCTAssertTrue(storage.string.hasPrefix("Edited: "))

        // Without tables wired up, cells render as paragraphs.
        let plain = ProseTextView(state: state, style: BasicStyle())
        XCTAssertNil(plain.renderer.spans.first { $0.embedSize != nil })
    }

    func testDarkAndLightGiveDifferentColours() throws {
        let style = BasicStyle()
        let paragraph = try schema.node("paragraph", nil, [schema.text("x")])
        let (attrs, _) = style.paragraph(paragraph, ancestors: [], marker: nil)
        let text = try XCTUnwrap(attrs[.foregroundColor] as? NSColor)

        func resolved(_ color: NSColor, _ name: NSAppearance.Name) throws -> NSColor {
            var out: NSColor?
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) }
            return try XCTUnwrap(out)
        }
        for color in [text, style.codeBlockBackground, style.inlineCodeBackground, style.linkColor] {
            XCTAssertNotEqual(try resolved(color, .aqua), try resolved(color, .darkAqua), "\(color)")
        }
        // Light text is dark, dark text is light.
        XCTAssertLessThan(try resolved(text, .aqua).brightnessComponent, 0.5)
        XCTAssertGreaterThan(try resolved(text, .darkAqua).brightnessComponent, 0.5)
    }
    #elseif os(iOS)
    func testDarkAndLightGiveDifferentColours() throws {
        let style = BasicStyle()
        let paragraph = try schema.node("paragraph", nil, [schema.text("x")])
        let (attrs, _) = style.paragraph(paragraph, ancestors: [], marker: nil)
        let text = try XCTUnwrap(attrs[.foregroundColor] as? UIColor)
        let light = UITraitCollection(userInterfaceStyle: .light), dark = UITraitCollection(userInterfaceStyle: .dark)
        for color in [text, style.codeBlockBackground, style.inlineCodeBackground] {
            XCTAssertNotEqual(color.resolvedColor(with: light), color.resolvedColor(with: dark))
        }
    }
    #endif
}
