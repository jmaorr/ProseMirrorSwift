#if os(iOS)
import XCTest
import UIKit
import PMModel
import PMState
@testable import PMTextKit

/// The decorations behind the text (card boxes and shadows, checkboxes, list markers) are drawn
/// in fixed tiles that scrolling reuses: a scroll redraws only tiles coming into view, and every
/// change of content or look still redraws what is shown. Cards come from `CheckCardStyle`.
@MainActor
final class IOSDecorationTileTests: XCTestCase {
    private var windows: [UIWindow] = []
    override func tearDown() {
        for w in windows { w.isHidden = true }
        windows = []
        super.tearDown()
    }

    /// `before`, then `cards` times: a paragraph, a card with a description, a bullet list.
    private func makeView(cards: Int, before: [JSONValue] = [], style: CheckCardStyle = CheckCardStyle()) throws -> ProseTextView {
        var content = before
        for i in 0..<cards {
            content.append(J.p("Paragraph \(i) with some words in it to fill a line."))
            content.append(CheckCard.json("Task \(i)", description: ["Description \(i)"]))
            content.append(J.ul(["Item \(i)"]))
        }
        let doc = try CheckCard.doc(content)
        let view = ProseTextView(state: CheckCard.state(doc), style: style)
        view.animatesChrome = false
        view.onMarkerClick = { [weak view] pos in view?.run(CheckCard.toggle(at: pos)) ?? false }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        windows.append(window)
        let controller = UIViewController()
        controller.view = view
        window.rootViewController = controller
        window.isHidden = false
        view.frame = window.bounds
        view.layoutIfNeeded()
        displayTiles(view)
        return view
    }

    private func displayTiles(_ view: ProseTextView) {
        view.layoutIfNeeded()
        for tile in view.decorations.subviews { tile.layer.displayIfNeeded() }
    }

    /// What the tiles show over the visible area, as drawn (stale or not).
    private func shown(_ view: ProseTextView) -> [UInt8] {
        displayTiles(view)
        let size = view.bounds.size
        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -view.contentOffset.x, y: -view.contentOffset.y)
        view.decorations.layer.render(in: ctx)
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
    }

    /// The tiles as shown must equal the tiles drawn afresh.
    private func assertTilesFresh(_ view: ProseTextView, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let before = shown(view)
        for tile in view.decorations.subviews { tile.setNeedsDisplay() }
        let fresh = shown(view)
        XCTAssertGreaterThan(fresh.max() ?? 0, 0, "nothing drawn: \(message)", file: file, line: line)
        let diff = zip(before, fresh).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
        XCTAssertEqual(diff, 0, "stale decorations after \(message)", file: file, line: line)
    }

    private func firstCard(_ view: ProseTextView) throws -> Int {
        try XCTUnwrap(CheckCard.positions(view.state.doc).first, "a card")
    }

    private func tick(_ view: ProseTextView) throws {
        let pos = try firstCard(view)
        let node = try XCTUnwrap(view.state.doc.nodeAt(pos))
        var attrs = node.attrs
        attrs["checked"] = .bool(true)
        view.dispatch(try view.state.tr.setNodeMarkup(pos, nil, attrs))
    }

    /// 60 steps of 12 pt (720 pt, under one tile) redraw at most the tiles scrolled into the margin.
    func testScrollingReusesTiles() throws {
        let view = try makeView(cards: 400)
        let drawsBefore = view.decorations.drawCount
        for i in 1...60 {
            view.contentOffset = CGPoint(x: 0, y: CGFloat(i) * 12)
            displayTiles(view)
        }
        let draws = view.decorations.drawCount - drawsBefore
        XCTAssertLessThanOrEqual(draws, 3, "tile draws while scrolling 720 pt")
        assertTilesFresh(view, "scrolling down")
        // Back up again: no tile comes into the area, but TextKit may move text it laid out
        // from estimates on the way down, and the tiles holding it draw again.
        let drawsBack = view.decorations.drawCount
        for i in (0..<60).reversed() {
            view.contentOffset = CGPoint(x: 0, y: CGFloat(i) * 12)
            displayTiles(view)
        }
        XCTAssertLessThanOrEqual(view.decorations.drawCount - drawsBack, 5, "tile draws scrolling back up 720 pt")
        // Standing still draws nothing.
        let idle = view.decorations.drawCount
        for _ in 0..<5 { view.setNeedsLayout(); displayTiles(view) }
        XCTAssertEqual(view.decorations.drawCount, idle, "tile draws while not scrolling")
        assertTilesFresh(view, "scrolling back up")
    }

    func testEditRedrawsTiles() throws {
        let view = try makeView(cards: 20)
        // A new paragraph at the top moves every box below it down.
        view.dispatch(try view.state.tr.insertText("A new first line.", 1))
        view.dispatch(try view.state.tr.split(18))
        assertTilesFresh(view, "an edit")
    }

    func testStyleChangeRedrawsTiles() throws {
        let view = try makeView(cards: 20)
        var style = CheckCardStyle()
        style.shadow = false
        view.setStyle(style)
        assertTilesFresh(view, "a style change")
    }

    func testTickAnimationRedrawsTiles() throws {
        let view = try makeView(cards: 20)
        view.animatesChecks = true
        try tick(view)
        assertTilesFresh(view, "a tick")
        view.advanceCheckAnimations(by: 0.08)
        assertTilesFresh(view, "a tick animation step")
        view.advanceCheckAnimations(by: 5)
        assertTilesFresh(view, "a tick animation's end")
    }

    func testAppearanceChangeRedrawsTiles() throws {
        let view = try makeView(cards: 20)
        let window = try XCTUnwrap(view.window)
        window.overrideUserInterfaceStyle = .dark
        view.layoutIfNeeded()
        assertTilesFresh(view, "dark mode")
        window.overrideUserInterfaceStyle = .light
        view.layoutIfNeeded()
        assertTilesFresh(view, "light mode")
    }

    /// A tick redraws only the tile(s) under the ticking checkbox, and they come out right.
    func testTickRedrawsOnlyTheTileUnderIt() throws {
        let view = try makeView(cards: 20)
        view.animatesChecks = true
        try tick(view)
        displayTiles(view)
        let shownTiles = view.decorations.subviews.filter { !$0.isHidden }.count
        XCTAssertGreaterThan(shownTiles, 1)
        let before = view.decorations.drawCount
        view.advanceCheckAnimations(by: 0.08)
        displayTiles(view)
        XCTAssertEqual(view.decorations.drawCount - before, 1, "tiles drawn for one tick step (of \(shownTiles) shown)")
        assertTilesFresh(view, "a partial tick redraw")
    }

    /// A card at the end of a document whose last paragraph grows without an edit (as when an
    /// image's size arrives): the tile past the end has only that paragraph to go by, and its
    /// top doesn't move, only its bottom (and the box's).
    func testLastParagraphGrowingAtTheEnd() throws {
        let view = try makeView(cards: 0, before: [J.p("Before the card."), CheckCard.json("A card", description: ["Short."])])
        let pos = try XCTUnwrap(view.renderer.chromes.first?.pos)
        let box = try XCTUnwrap(view.chromeFrame(at: pos))
        grow(view, paragraphAt: (view.textStorage.string as NSString).range(of: "Short.").location)
        XCTAssertGreaterThan(try XCTUnwrap(view.chromeFrame(at: pos)).height, box.height + 5, "the box grew")
        assertTilesFresh(view, "the last paragraph growing")
    }

    /// One paragraph taller than a tile, in a card at the end, grows: the tiles it spans have it
    /// at both edges, and only its bottom moves.
    func testTallParagraphGrowing() throws {
        let long = (0..<80).map { "Line \($0) of a very long paragraph." }.joined(separator: " ")
        let view = try makeView(cards: 0, before: [J.p("Before the card."), CheckCard.json("A card", description: [long])])
        let pos = try XCTUnwrap(view.renderer.chromes.first?.pos)
        let box = try XCTUnwrap(view.chromeFrame(at: pos))
        XCTAssertGreaterThan(box.height, DecorationView.tileHeight, "the card is taller than a tile")
        // The end of the card in view.
        view.contentOffset = CGPoint(x: 0, y: max(0, box.maxY - 600))
        displayTiles(view)
        grow(view, paragraphAt: (view.textStorage.string as NSString).range(of: "Line 0 ").location, to: 18)
        XCTAssertGreaterThan(try XCTUnwrap(view.chromeFrame(at: pos)).height, box.height + 5, "the box grew")
        assertTilesFresh(view, "a tall paragraph growing")
    }

    /// Layout changed without an edit (an attachment's size arriving, say): the view is told so
    /// and redraws every tile shown.
    func testLayoutChangedOutsideEditsRedrawsTiles() throws {
        let view = try makeView(cards: 4)
        let before = view.decorations.drawCount
        view.layoutChangedOutsideEdits()
        displayTiles(view)
        XCTAssertEqual(view.decorations.drawCount - before, view.decorations.subviews.filter { !$0.isHidden }.count)
    }

    /// Make the paragraph at string offset `offset` taller without a transaction (a bigger font),
    /// and let TextKit lay it out again.
    private func grow(_ view: ProseTextView, paragraphAt offset: Int, to size: CGFloat = 40) {
        let storage = view.textStorage
        let range = (storage.string as NSString).paragraphRange(for: NSRange(location: offset, length: 0))
        storage.beginEditing()
        storage.addAttribute(.font, value: UIFont.systemFont(ofSize: size), range: range)
        storage.endEditing()
        if let tlm = view.textLayoutManager { tlm.invalidateLayout(for: tlm.documentRange) }
        view.setNeedsLayout()
        displayTiles(view)
    }

    func testWidthChangeRetilesAndRedraws() throws {
        let view = try makeView(cards: 20)
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 874)
        view.layoutIfNeeded()
        XCTAssertTrue(view.decorations.subviews.allSatisfy { $0.isHidden || $0.frame.width == 600 })
        assertTilesFresh(view, "a width change")
    }
}
#endif
