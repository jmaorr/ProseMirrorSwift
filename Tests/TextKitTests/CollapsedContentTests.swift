#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
@testable import PMTextKit
import PMExampleSetup

/// A collapsed stand-in, so tests can tell a card from a chip.
final class CollapsedTestAttachment: NSTextAttachment {
    enum Form { case node, card, chip }
    let form: Form
    init(_ form: Form) {
        self.form = form
        super.init(data: nil, ofType: nil)
        bounds = CGRect(x: 0, y: 0, width: form == .chip ? 60 : 200, height: form == .chip ? 16 : 40)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// BasicStyle plus the two kinds of collapsing PMTextKit offers:
/// - a block quote is a collapsible chrome box: one attachment while the selection is outside;
/// - a link whose text is its address is a collapsed run: a paragraph of just that link is a
///   card (opens with the caret at its edges), one inside a sentence a chip (opens only inside).
struct CollapsingTestStyle: DocStyle {
    var base = BasicStyle()

    func paragraph(_ textblock: Node, ancestors: [Node], marker: BlockMarker?) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
        base.paragraph(textblock, ancestors: ancestors, marker: marker)
    }
    func inline(_ marks: [Mark], base attrs: [NSAttributedString.Key: Any], textblock: Node, ancestors: [Node]) -> [NSAttributedString.Key: Any] {
        base.inline(marks, base: attrs, textblock: textblock, ancestors: ancestors)
    }
    func leafBlock(_ node: Node, ancestors: [Node]) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
        base.leafBlock(node, ancestors: ancestors)
    }
    func inlineLeaf(_ node: Node, base attrs: [NSAttributedString.Key: Any]) -> NSAttributedString { base.inlineLeaf(node, base: attrs) }
    func marker(for child: Node, in parent: Node, index: Int) -> BlockMarker? { base.marker(for: child, in: parent, index: index) }
    func chrome(forTextblock node: Node, ancestors: [Node]) -> ChromeBox? { base.chrome(forTextblock: node, ancestors: ancestors) }

    func chrome(for node: Node) -> ChromeBox? {
        guard node.type.name == "blockquote" else { return nil }
        var box = ChromeBox()
        box.fill = .controlBackgroundColor
        box.border = .separatorColor
        box.collapsible = true
        return box
    }

    func collapsed(_ node: Node, at pos: Int, ancestors: [Node]) -> [NSAttributedString.Key: Any]? {
        guard node.type.name == "blockquote" else { return nil }
        return [.font: base.bodyFont, .paragraphStyle: NSParagraphStyle.default, .attachment: CollapsedTestAttachment(.node)]
    }

    func collapsedRuns(in textblock: Node, at pos: Int, ancestors: [Node]) -> [CollapsedRun] {
        guard textblock.type.name == "paragraph" else { return [] }
        var runs: [(Range<Int>, String)] = []
        textblock.forEach { child, offset, _ in
            if let text = child.text, let link = child.marks.first(where: { $0.type.name == "link" }),
               link.attrs["href"]?.stringValue == text {
                runs.append((offset..<(offset + child.nodeSize), text))
            }
        }
        if runs.count == 1, runs[0].0 == 0..<textblock.content.size {
            return [CollapsedRun(range: runs[0].0, opensAtEdges: true) { [.attachment: CollapsedTestAttachment(.card)] }]
        }
        return runs.map { range, _ in CollapsedRun(range: range, opensAtEdges: false) { [.attachment: CollapsedTestAttachment(.chip)] } }
    }
}

/// Content shown as an attachment while the selection isn't in it: a collapsible node and
/// collapsed runs. The document never changes; positions keep mapping 1:1 (runs) or around
/// the attachment (a node); Find sees the text.
@MainActor
final class CollapsedContentTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for w in windows { w.close() }
        windows = []
        super.tearDown()
    }

    private let url = "https://example.com/a"
    private func link(_ s: String) -> JSONValue { J.text(s, [J.mark("link", ["href": .string(s)])]) }

    private func makeView(_ blocks: [JSONValue], selection: Int = 1) throws -> ProseTextView {
        let doc = try TestDocs.doc(blocks)
        let view = ProseTextView(state: TestDocs.state(doc, selection: selection), style: CollapsingTestStyle())
        view.animatesChrome = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = window.contentLayoutRect
        windows.append(window)
        layout(view)
        return view
    }

    private func layout(_ view: ProseTextView) {
        if let tlm = view.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange); tlm.textViewportLayoutController.layoutViewport() }
        view.layoutChromeControls()
    }

    private func select(_ view: ProseTextView, _ from: Int, _ to: Int? = nil) {
        view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, from, to ?? from)))
        layout(view)
    }

    private func attachment(_ view: ProseTextView, at offset: Int) -> CollapsedTestAttachment? {
        view.textStorage?.attribute(.attachment, at: offset, effectiveRange: nil) as? CollapsedTestAttachment
    }

    // MARK: A collapsible node

    /// "Before", then a quote at 8 (its first paragraph's text runs 10...16).
    private func quoteView(selection: Int = 1) throws -> ProseTextView {
        try makeView([J.p("Before"), J.quote([J.p("Review"), J.p("Check it")])], selection: selection)
    }

    func testCollapsedUntilTheCaretIsIn() throws {
        let view = try quoteView()
        XCTAssertEqual(view.textStorage?.string, "Before\n\u{FFFC}\n", "one attachment stands in for the quote")
        XCTAssertEqual(attachment(view, at: 7)?.form, .node)
        XCTAssertNotNil(view.chromeFrame(at: 8), "the collapsed node still gets its box")

        select(view, 16)
        XCTAssertEqual(view.textStorage?.string, "Before\nReview\nCheck it\n")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 13, length: 0), "the caret is at the first line's end")
        XCTAssertNotNil(view.activeChrome)

        select(view, 3)
        XCTAssertEqual(view.textStorage?.string, "Before\n\u{FFFC}\n")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertNil(view.activeChrome)
    }

    /// Find sees a collapsed node's text: it shows while the find bar is open.
    func testFindBarShowsCollapsedText() throws {
        let view = try quoteView()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = view.window!
        window.contentView = scroll
        scroll.documentView = view
        view.viewDidMoveToWindow()
        XCTAssertEqual(view.textStorage?.string, "Before\n\u{FFFC}\n")
        let show = NSMenuItem(title: "Find", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "")
        show.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(show)
        XCTAssertTrue(scroll.isFindBarVisible)
        XCTAssertEqual(view.textStorage?.string, "Before\nReview\nCheck it\n")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0), "the caret stays put")
        // Closed by the bar itself (Done, Escape): the node collapses again.
        scroll.isFindBarVisible = false
        let end = Date().addingTimeInterval(1)
        while view.showsCollapsedText && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(view.textStorage?.string, "Before\n\u{FFFC}\n")
    }

    // MARK: Collapsed runs

    func testCardShowsWhileTheCaretIsOutside() throws {
        let view = try makeView([J.p("Before"), J.p([link(url)]), J.p("After")])
        let doc = view.state.doc
        let storage = try XCTUnwrap(view.textStorage)
        XCTAssertEqual(storage.length, ("Before\n" + url + "\nAfter\n").utf16.count, "the text stays 1:1")
        XCTAssertEqual((storage.string as NSString).character(at: 7), 0xFFFC)
        XCTAssertEqual(attachment(view, at: 7)?.form, .card)
        XCTAssertEqual(view.renderer.runs.first?.collapsed, true)

        // The caret at the card's end (an arrow key from the next line lands here): raw text.
        select(view, 9 + url.utf16.count)
        XCTAssertEqual(storage.string, "Before\n" + url + "\nAfter\n")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 7 + url.utf16.count, length: 0))
        select(view, 9)
        XCTAssertEqual(storage.string, "Before\n" + url + "\nAfter\n", "the start opens it too")

        select(view, 2)
        XCTAssertEqual((storage.string as NSString).character(at: 7), 0xFFFC, "collapses again")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertTrue(view.state.doc === doc, "the document never changes")
    }

    func testChipShowsUntilTheCaretIsInIt() throws {
        let view = try makeView([J.p([J.text("Read "), link(url), J.text(" today")])])
        let storage = try XCTUnwrap(view.textStorage)
        let raw = "Read " + url + " today\n"
        XCTAssertEqual((storage.string as NSString).character(at: 5), 0xFFFC)
        XCTAssertEqual(attachment(view, at: 5)?.form, .chip)
        XCTAssertEqual(storage.length, raw.utf16.count)

        let start = 6, end = 6 + url.utf16.count
        select(view, start)
        XCTAssertEqual(attachment(view, at: 5)?.form, .chip, "a caret just before stays a chip")
        select(view, end)
        XCTAssertEqual(attachment(view, at: 5)?.form, .chip, "a caret just after stays a chip")
        select(view, start + 4)
        XCTAssertEqual(storage.string, raw, "inside: the URL's text")
        select(view, 1)
        XCTAssertNotNil(attachment(view, at: 5))
        select(view, start, end)
        XCTAssertEqual(storage.string, raw, "selecting exactly the chip opens it")

        // Composing right after the chip: the marked text gets the paragraph's look, not the
        // hidden characters'.
        select(view, end)
        XCTAssertNotNil(attachment(view, at: 5))
        XCTAssertGreaterThan((view.typingAttributes[.font] as? NSFont)?.pointSize ?? 0, 10)
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = view.markedRange()
        XCTAssertEqual(marked.length, 1)
        XCTAssertGreaterThan((storage.attribute(.font, at: marked.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, 10)
        view.unmarkText()
    }

    func testShowsCollapsedTextShowsTheRuns() throws {
        let view = try makeView([J.p("x"), J.p([link(url)])])
        XCTAssertNotNil(attachment(view, at: 2))
        view.setShowsCollapsedText(true)
        XCTAssertEqual(view.textStorage?.string, "x\n" + url + "\n")
        view.setShowsCollapsedText(false)
        XCTAssertNotNil(attachment(view, at: 2))
    }

    // MARK: Editing at a chip's edge

    func testBackspaceAfterAChipRemovesIt() throws {
        let view = try makeView([J.p([J.text("Read "), link(url), J.text(" today")])])
        select(view, 6 + url.utf16.count)
        XCTAssertNotNil(attachment(view, at: 5), "a chip, the caret just after it")
        view.deleteBackward(nil)
        XCTAssertEqual(view.state.doc.textContent, "Read  today", "the whole chip goes, as an attachment would")
        XCTAssertEqual(view.state.selection.from, 6)
    }

    func testDeleteBeforeAChipRemovesIt() throws {
        let view = try makeView([J.p([J.text("Read "), link(url), J.text(" today")])])
        select(view, 6)
        XCTAssertNotNil(attachment(view, at: 5))
        view.deleteForward(nil)
        XCTAssertEqual(view.state.doc.textContent, "Read  today")
    }

    func testWordDeleteAfterAChipRemovesIt() throws {
        let view = try makeView([J.p([J.text("Read "), link(url)]), J.p("x")])
        select(view, 6 + url.utf16.count)
        XCTAssertNotNil(attachment(view, at: 5))
        view.deleteWordBackward(nil)
        XCTAssertFalse(view.state.doc.textContent.contains("example"), "no fragment of the hidden URL is left")
    }
}
#endif
