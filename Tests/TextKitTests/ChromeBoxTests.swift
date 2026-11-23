#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
@testable import PMTextKit
import PMTableView
import PMExampleSetup

/// A chrome box (a block quote drawn as a card that opens with a footer of controls): its size
/// wherever it sits, editing inside it, and keys it leaves alone.
@MainActor
final class ChromeBoxTests: XCTestCase {
    private var windows: [NSWindow] = []
    override func tearDown() { for w in windows { w.close() }; windows = []; super.tearDown() }

    private let title = "Call the plumber about the leak"

    /// A view of `blocks` with boxed quotes (tables as grids), the caret `offset` characters into
    /// the first quote's text (its end by default), first responder in a window.
    private func makeView(_ blocks: [JSONValue], offset: Int? = nil, readOnly: Bool = false,
                          height: CGFloat = 700) throws -> ProseTextView {
        let doc = try TestDocs.doc(blocks)
        var plugins = exampleSetup(schema: TestDocs.schema)
        // A read-only gate: no document changes.
        if readOnly { plugins.insert(Plugin(PluginSpec(filterTransaction: { tr, _ in !tr.docChanged })), at: 0) }
        var state = EditorState.create(EditorStateConfig(doc: doc, plugins: plugins))
        var textStart: Int?, textSize = 0
        doc.descendants { node, pos, _, _ in
            if textStart == nil, node.type.name == "blockquote" { textStart = pos + 2; textSize = node.child(0).content.size }
            return textStart == nil
        }
        let caret = try XCTUnwrap(textStart) + (offset ?? textSize)
        state = state.apply(state.tr.setSelection(TextSelection.create(state.doc, caret)))
        let core = EditorCore(state: state)
        var style = BoxedQuoteStyle()
        style.base.tables = TableEmbeds(core: core, tableStyle: style.base.tableStyle, cellStyle: BasicStyle())
        let view = ProseTextView(core: core, style: style)
        view.animatesChrome = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.documentView = view
        view.frame = NSRect(x: 0, y: 0, width: 600, height: height)
        window.contentView = scroll
        window.makeFirstResponder(view)
        windows.append(window)
        window.displayIfNeeded()
        if let tlm = view.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        return view
    }

    private func longDocument() -> [JSONValue] {
        var blocks: [JSONValue] = [J.p("Intro"), J.quote([J.p(title)])]
        for i in 0..<80 { blocks.append(J.p("Paragraph \(i) with enough words to wrap the line in a narrow window, more or less.")) }
        return blocks
    }

    private func key(_ view: ProseTextView, _ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: view.window!.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        view.keyDown(with: event)
        view.window?.displayIfNeeded()
    }

    private func boxText(_ view: ProseTextView) -> String {
        var t: String?
        view.state.doc.descendants { node, _, _, _ in
            if t == nil, node.type.name == "blockquote" { t = node.textContent }
            return t == nil
        }
        return t ?? ""
    }

    /// The active box's height, or nil when no box is active.
    private func activeBoxHeight(_ view: ProseTextView) -> CGFloat? {
        guard let active = view.activeChrome else { return nil }
        return view.chromeFrame(at: active.pos)?.height
    }

    // MARK: Size

    /// A box is its text plus the controls' footer wherever it sits: mid-document, as the
    /// document's last block (where TextKit adds an empty extra line to the last paragraph),
    /// or after a table.
    func testBoxIsTheSameAtTheEndOfTheDocument() throws {
        let quote = J.quote([J.p("Nah it's alright then")])
        let table = J.table([["", "", ""], ["", "", ""], ["", "", ""]])
        let middle = try XCTUnwrap(activeBoxHeight(try makeView([J.p("x"), quote, J.p("y")], offset: 3)))
        XCTAssertLessThan(middle, 110)
        XCTAssertGreaterThan(middle, 34, "text plus footer")
        XCTAssertEqual(try XCTUnwrap(activeBoxHeight(try makeView([J.p("x"), quote], offset: 3))), middle, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(activeBoxHeight(try makeView([J.p("x"), table, quote], offset: 3))), middle, accuracy: 0.5)
    }

    /// The active box shows its controls; one leaves it, closing the box.
    func testActiveBoxShowsItsControls() throws {
        let view = try makeView([J.p("x"), J.quote([J.p("Inside")]), J.p("y")])
        let active = try XCTUnwrap(view.activeChrome)
        XCTAssertEqual(active.buttons, ["Done"])
        let open = try XCTUnwrap(view.chromeFrame(at: active.pos)).height
        view.pressChromeControl("Done")
        XCTAssertNil(view.activeChrome)
        XCTAssertEqual(view.state.selection.fromPos.parent.textContent, "y")
        if let tlm = view.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        let closed = try XCTUnwrap(view.chromeFrame(at: active.pos)).height
        XCTAssertEqual(open - closed, BoxedQuoteStyle().footer, accuracy: 0.5, "the footer goes as the box closes")
    }

    // MARK: Editing

    func testBackspaceDeletesInABox() throws {
        let view = try makeView(longDocument())
        view.insertText("s", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(boxText(view), title + "s")
        key(view, 51, "\u{7F}")
        XCTAssertEqual(boxText(view), title)
        key(view, 51, "\u{7F}")
        XCTAssertEqual(boxText(view), String(title.dropLast()))
    }

    func testMovingTheCaretKeepsTheBoxItsSize() throws {
        let view = try makeView(longDocument())
        let start = try XCTUnwrap(activeBoxHeight(view))
        XCTAssertLessThan(start, 150)
        for step in 1...4 {
            key(view, 123, "\u{F702}", [.option, .function, .numericPad])
            let h = try XCTUnwrap(activeBoxHeight(view), "step \(step)")
            XCTAssertEqual(h, start, accuracy: 0.5, "after \(step) word(s) left")
        }
        for step in 1...6 {
            key(view, 123, "\u{F702}", [.function, .numericPad])
            XCTAssertEqual(try XCTUnwrap(activeBoxHeight(view)), start, accuracy: 0.5, "after \(step) char(s) left")
        }
    }

    /// A read-only document ignores typing, and the view keeps showing the document it has.
    func testTypingInAReadOnlyBoxChangesNothing() throws {
        let view = try makeView(longDocument(), readOnly: true)
        let start = try XCTUnwrap(activeBoxHeight(view))
        let before = view.textStorage?.string
        view.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        key(view, 51, "\u{7F}")
        XCTAssertEqual(boxText(view), title)
        XCTAssertEqual(view.textStorage?.string, before, "text on screen matches the document")
        for step in 1...4 {
            key(view, 123, "\u{F702}", [.option, .function, .numericPad])
            XCTAssertEqual(try XCTUnwrap(activeBoxHeight(view)), start, accuracy: 0.5, "after \(step) word(s) left")
        }
    }

    /// A key equivalent no binding claims (Cmd-, is an app's Settings) is left to the menu.
    func testUnboundKeyEquivalentIsLeftToTheMenu() throws {
        let view = try makeView(longDocument())
        let before = view.state.doc
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                     windowNumber: view.window!.windowNumber, context: nil, characters: ",",
                                     charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43)!
        XCTAssertFalse(view.performKeyEquivalent(with: event))
        XCTAssertTrue(view.state.doc === before)
    }
}
#endif
