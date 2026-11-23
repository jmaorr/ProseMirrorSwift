#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMHistory
@testable import PMTextKit
import PMTableView
import PMExampleSetup

/// The custom caret is drawn where the insertion point is laid out, after every path that moves
/// it: Enter in a chrome box (a block quote drawn as a card that opens), list items, empty lines,
/// undo, style changes, width changes, and while the chrome animates.
@MainActor
final class CaretPlacementTests: XCTestCase {
    private var windows: [NSWindow] = []
    override func tearDown() { for w in windows { w.close() }; windows = []; super.tearDown() }

    private func box(_ paragraphs: String...) -> JSONValue { J.quote(paragraphs.map { J.p($0) }) }

    /// A view with boxed quotes and a bar caret, in a window, first responder. Chrome snaps to
    /// its settled state (no display link fires in tests) unless `animates`, when `stepChrome`
    /// drives the frames.
    private func makeView(_ blocks: [JSONValue], animates: Bool = false, width: CGFloat = 640,
                          height: CGFloat = 700) throws -> ProseTextView {
        let doc = try TestDocs.doc(blocks)
        let core = EditorCore(state: TestDocs.state(doc))
        var style = BoxedQuoteStyle()
        style.base.tables = TableEmbeds(core: core, tableStyle: style.base.tableStyle, cellStyle: BasicStyle())
        let view = ProseTextView(core: core, style: style)
        view.animatesChrome = animates
        view.undoCommand = undo
        view.redoCommand = redo
        view.caret = .bar(width: 2)
        view.caretColor = .systemPink
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.documentView = view
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.minSize = NSSize(width: 0, height: height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        window.contentView = scroll
        window.makeFirstResponder(view)
        windows.append(window)
        window.displayIfNeeded()
        settle()
        return view
    }

    /// Let animations, async work and layout finish.
    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        windows.last?.displayIfNeeded()
    }

    private func key(_ view: ProseTextView, _ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: view.window!.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        view.keyDown(with: event)
        view.window?.displayIfNeeded()
    }

    private func select(_ view: ProseTextView, _ pos: Int) {
        view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, pos)))
    }

    private func pos(_ view: ProseTextView, endOf type: String, index: Int = 0) throws -> Int {
        var found: [Int] = []
        view.state.doc.descendants { node, pos, _, _ in
            if node.type.name == type { found.append(pos + node.nodeSize - 1) }
            return true
        }
        return try XCTUnwrap(found.count > index ? found[index] : nil, "no \(type) #\(index)")
    }

    /// The end of the first paragraph inside the first quote.
    private func boxTextEnd(_ view: ProseTextView) throws -> Int {
        var end: Int?
        view.state.doc.descendants { node, pos, _, _ in
            if end == nil, node.type.name == "blockquote" { end = pos + 1 + node.child(0).nodeSize - 1 }
            return end == nil
        }
        return try XCTUnwrap(end)
    }

    private func boxPos(_ view: ProseTextView) -> Int? {
        var found: Int?
        view.state.doc.descendants { n, p, _, _ in if found == nil, n.type.name == "blockquote" { found = p }; return found == nil }
        return found
    }

    /// Where the caret belongs, worked out from the laid-out text alone.
    private func expectedCaret(_ view: ProseTextView, file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        view.textLayoutManager!.textViewportLayoutController.layoutViewport()
        return try XCTUnwrap(view.caretRect, "no caret rect", file: file, line: line)
    }

    /// The caret drawn on screen matches where the insertion point is laid out.
    private func assertCaretPlaced(_ view: ProseTextView, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        settle()
        let drawn = view.caretState.layer.frame
        XCTAssertFalse(view.caretState.layer.isHidden, "\(what): caret hidden", file: file, line: line)
        let expected = try expectedCaret(view, file: file, line: line)
        XCTAssertEqual(drawn.minX, expected.minX, accuracy: 0.5, "\(what): x", file: file, line: line)
        XCTAssertEqual(drawn.minY, expected.minY, accuracy: 0.5, "\(what): y", file: file, line: line)
        XCTAssertEqual(drawn.height, expected.height, accuracy: 0.5, "\(what): height", file: file, line: line)
        // And the rect honours the paragraph's indent: never left of where its first glyph would go.
        let offset = view.selectedRange().location
        if let style = view.textStorage!.length > offset
            ? view.textStorage!.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle : nil {
            let padding = view.textContainer?.lineFragmentPadding ?? 0
            let indent = min(style.firstLineHeadIndent, style.headIndent)
            XCTAssertGreaterThanOrEqual(expected.minX + 0.5, view.textContainerOrigin.x + padding + indent,
                                        "\(what): left of the paragraph's indent", file: file, line: line)
        }
    }

    /// The caret is on a new, empty line inside the (active) box.
    private func assertCaretInNewLine(_ view: ProseTextView, file: StaticString = #filePath, line: UInt = #line) throws {
        settle()
        XCTAssertEqual(view.state.selection.fromPos.parent.content.size, 0, "on the new, empty line", file: file, line: line)
        let pos = try XCTUnwrap(boxPos(view), file: file, line: line)
        let box = try XCTUnwrap(view.chromeFrame(at: pos), file: file, line: line)
        let caret = view.caretState.layer.frame
        XCTAssertTrue(caret.midY > box.minY && caret.midY < box.maxY && caret.minX > box.minX && caret.maxX < box.maxX,
                      "caret \(caret) in the box \(box)", file: file, line: line)
    }

    // MARK: Chrome boxes

    func testEnterInABoxAddsALineWithTheCaretInIt() throws {
        let view = try makeView([J.p("Intro"), box("Call the plumber"), J.p("After")])
        select(view, try boxTextEnd(view))
        try assertCaretPlaced(view, "box text end")
        key(view, 36, "\r")
        XCTAssertEqual(view.state.doc.child(1).childCount, 2, "a new line in the box")
        try assertCaretPlaced(view, "new line")
        try assertCaretInNewLine(view)
    }

    /// The box is the document's last block, so its new empty line is the last line.
    func testEnterInTheLastBoxOfTheDocument() throws {
        let view = try makeView([J.p("Intro"), box("Call the plumber")])
        select(view, try boxTextEnd(view))
        try assertCaretPlaced(view, "box text end")
        key(view, 36, "\r")
        try assertCaretInNewLine(view)
        try assertCaretPlaced(view, "new last line")
    }

    /// A long document scrolled to its end, the box near the bottom: the text above the
    /// viewport has only estimated frames.
    func testEnterInABoxAtTheEndOfALongDocument() throws {
        var blocks: [JSONValue] = [J.p("Intro")]
        for i in 0..<150 { blocks.append(J.p("Paragraph \(i) with enough words to wrap the line in a narrow window, more or less, and then some more.")) }
        blocks.append(box("Call the plumber"))
        blocks.append(J.p("After"))
        let view = try makeView(blocks)
        select(view, try boxTextEnd(view))
        view.scrollToEndOfDocument(nil)
        try assertCaretPlaced(view, "box text end")
        key(view, 36, "\r")
        XCTAssertEqual(view.state.selection.fromPos.node(view.state.selection.fromPos.depth - 1).type.name, "blockquote")
        try assertCaretPlaced(view, "new line")
        let box = try XCTUnwrap(view.chromeFrame(at: try XCTUnwrap(boxPos(view))))
        XCTAssertTrue(box.insetBy(dx: 0, dy: -1).contains(CGPoint(x: view.caretState.layer.frame.midX, y: view.caretState.layer.frame.midY)),
                      "caret \(view.caretState.layer.frame) in the box \(box)")
    }

    /// A table above the box, the document scrolled a little, the box's chrome animating open.
    /// Every frame, and the end, puts the caret where the drawn layout has its line.
    func testEnterInABoxUnderATableWhileTheChromeAnimates() throws {
        var blocks: [JSONValue] = [J.h(1, "Title"), J.p("Hello world?"),
                                   J.table((0..<8).map { ["R\($0) a", "R\($0) b"] }),
                                   J.p([J.text("https://example.com/page", [J.mark("link", ["href": "https://example.com/page"])])])]
        for i in 0..<4 { blocks.append(J.p("Line \(i)")) }
        blocks.append(box("Bugs", "Description is okay"))
        for i in 0..<30 { blocks.append(J.p("After \(i)")) }
        let view = try makeView(blocks, animates: true, width: 1191, height: 1060)
        let clip = try XCTUnwrap(view.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: 165)); view.enclosingScrollView?.reflectScrolledClipView(clip)
        settle()
        select(view, try boxTextEnd(view))
        view.chromeState.snap()
        view.applyChromeFrame()
        settle()
        key(view, 36, "\r")
        XCTAssertEqual(view.state.selection.fromPos.node(view.state.selection.fromPos.depth - 1).type.name, "blockquote")
        // Leave the box and come back, so it closes and opens again, frame by frame.
        select(view, 1)
        view.chromeState.snap()
        view.applyChromeFrame()
        settle()
        select(view, try boxTextEnd(view))
        let window = try XCTUnwrap(view.window)
        let tlm = try XCTUnwrap(view.textLayoutManager)
        let tcs = try XCTUnwrap(view.textContentStorage)
        // As on screen: each frame the text above the box has been laid out afresh (here:
        // invalidated) before the frame re-places the caret; the display that follows lays the
        // viewport out again.
        let above = try XCTUnwrap(NSTextRange(location: tcs.documentRange.location,
                                              end: try XCTUnwrap(tcs.location(tcs.documentRange.location, offsetBy: view.selectedRange().location - 1))))
        var frames = 0
        while !view.chromeState.settled, frames < 60 {
            frames += 1
            tlm.invalidateLayout(for: above)
            view.chromeState.step(1.0 / 60)
            view.applyChromeFrame()
            window.displayIfNeeded()
            let drawn = view.caretState.layer.frame
            let line = try XCTUnwrap(view.caretRect(layingOut: false))
            XCTAssertEqual(drawn.minY, line.minY, accuracy: 0.5, "frame \(frames)")
            XCTAssertEqual(drawn.minX, line.minX, accuracy: 0.5, "frame \(frames)")
        }
        XCTAssertGreaterThan(frames, 3, "the chrome animated")
        tlm.invalidateLayout(for: above)
        view.updateInsertionPointStateAndRestartTimer(true)
        window.displayIfNeeded()
        settle()
        let final = view.caretState.layer.frame
        let settled = try XCTUnwrap(view.caretRect(layingOut: false))
        XCTAssertEqual(final.minY, settled.minY, accuracy: 0.5, "after the last frame")
        XCTAssertEqual(final.minX, settled.minX, accuracy: 0.5, "after the last frame")
    }

    /// While a box opens or closes, every animation frame restyles it: the caret follows.
    func testCaretFollowsTheChromeAnimation() throws {
        let view = try makeView([J.p("Intro"), box("Call the plumber"), J.p("After")], animates: true)
        select(view, try boxTextEnd(view))
        view.chromeState.snap()
        view.applyChromeFrame()
        try assertCaretPlaced(view, "in the box")
        key(view, 36, "\r")
        try stepChrome(view, "after Enter")
        select(view, 1)
        try stepChrome(view, "closing the box")
        select(view, try boxTextEnd(view))
        try stepChrome(view, "opening the box")
    }

    /// Run the chrome animation by hand (no display link fires in tests), checking every frame.
    private func stepChrome(_ view: ProseTextView, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var frame = 0
        while !view.chromeState.settled, frame < 40 {
            frame += 1
            view.chromeState.step(1.0 / 60)
            view.applyChromeFrame()
            let drawn = view.caretState.layer.frame
            let expected = try expectedCaret(view, file: file, line: line)
            XCTAssertEqual(drawn.minX, expected.minX, accuracy: 0.5, "\(what), frame \(frame): x", file: file, line: line)
            XCTAssertEqual(drawn.minY, expected.minY, accuracy: 0.5, "\(what), frame \(frame): y", file: file, line: line)
        }
        XCTAssertTrue(view.chromeState.settled, "\(what): animation settles", file: file, line: line)
    }

    /// Tab and Shift-Tab sink and lift a list item inside a box.
    func testTabSinksAndLiftsAListItemInABox() throws {
        let view = try makeView([J.p("Intro"), J.quote([J.ul(["One", "Two"])]), J.p("After")])
        select(view, try pos(view, endOf: "paragraph", index: 2))
        XCTAssertEqual(view.state.selection.fromPos.parent.textContent, "Two")
        try assertCaretPlaced(view, "item")
        key(view, 48, "\t")
        XCTAssertEqual(view.state.selection.fromPos.depth, 6, "sunk into a nested list")
        try assertCaretPlaced(view, "nested item")
        key(view, 48, "\u{19}", [.shift])
        XCTAssertEqual(view.state.selection.fromPos.depth, 4, "lifted back")
        try assertCaretPlaced(view, "lifted item")
    }

    func testClickIntoAnEmptyParagraphInABox() throws {
        let view = try makeView([J.p("Intro"), box("Call the plumber", ""), J.p("After")])
        select(view, 1)
        try assertCaretPlaced(view, "intro")
        // Where a click lands: the empty paragraph's (only) position.
        select(view, try pos(view, endOf: "paragraph", index: 2))
        XCTAssertEqual(view.state.selection.fromPos.parent.content.size, 0)
        try assertCaretPlaced(view, "empty paragraph in the box")
    }

    // MARK: Other blocks

    func testEnterInAListItem() throws {
        let view = try makeView([J.p("Intro"), J.ul(["One"])])
        select(view, try pos(view, endOf: "paragraph", index: 1))
        try assertCaretPlaced(view, "list item")
        key(view, 36, "\r")
        try assertCaretPlaced(view, "new list item")
    }

    func testEmptyParagraphAfterAHeading() throws {
        let view = try makeView([J.h(1, "Title"), J.p("Body")])
        select(view, try pos(view, endOf: "heading"))
        key(view, 36, "\r")
        XCTAssertEqual(view.state.selection.fromPos.parent.content.size, 0)
        try assertCaretPlaced(view, "empty paragraph after a heading")
    }

    /// A code block draws a box behind its text (textblock chrome) with padding inside.
    func testEnterInACodeBlock() throws {
        let view = try makeView([J.p("Intro"), J.code("let x = 1"), J.p("After")])
        select(view, try pos(view, endOf: "code_block"))
        try assertCaretPlaced(view, "code block")
        key(view, 36, "\r")
        XCTAssertEqual(view.state.doc.child(1).textContent, "let x = 1\n")
        try assertCaretPlaced(view, "new line in the code block")
    }

    func testAfterUndo() throws {
        let view = try makeView([J.p("Intro"), box("Call the plumber"), J.p("After")])
        select(view, try boxTextEnd(view))
        key(view, 36, "\r")
        settle()
        view.undo(nil)
        XCTAssertEqual(view.state.doc.child(1).childCount, 1)
        try assertCaretPlaced(view, "after undo")
    }

    /// A narrower window rewraps the text: the caret moves with it, though the selection doesn't.
    func testAfterTheWidthChanges() throws {
        let long = String(repeating: "A long line that wraps once the window is narrow. ", count: 3)
        let view = try makeView([J.p(long), box("Call the plumber"), J.p("After")])
        select(view, try boxTextEnd(view))
        try assertCaretPlaced(view, "wide")
        view.enclosingScrollView?.frame.size.width = 320
        view.frame.size.width = 320
        view.window?.layoutIfNeeded()
        try assertCaretPlaced(view, "narrow")
    }

    func testAfterTheStyleChanges() throws {
        let view = try makeView([J.p("Intro"), box("Call the plumber"), J.p("After")])
        select(view, try boxTextEnd(view))
        try assertCaretPlaced(view, "14pt")
        for size: CGFloat in [20, 11, 14] {
            var style = BoxedQuoteStyle()
            style.base = BasicStyle(fontSize: size)
            view.setStyle(style)
            try assertCaretPlaced(view, "\(size)pt")
        }
        view.caret = .block(widthEm: 0.55)
        try assertCaretPlaced(view, "block caret")
    }
}
#endif
