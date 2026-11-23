#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
@testable import PMTextKit
import PMExampleSetup

/// BasicSchema plus a `card` block (paragraphs in a box) whose attributes a strip shows: a
/// status, a duration and two dates, while `managed` is true.
enum StripTestSchema {
    static let schema: Schema = {
        let card = NodeSpec(content: "paragraph+", group: "block",
                            attrs: [("managed", AttributeSpec(default: false)), ("status", AttributeSpec(default: .null)),
                                    ("duration", AttributeSpec(default: .null)), ("due", AttributeSpec(default: .null)),
                                    ("scheduled", AttributeSpec(default: .null))],
                            defining: true)
        return try! Schema(SchemaSpec(nodes: BasicSchema.nodes + [("card", card)], marks: BasicSchema.marks))
    }()
}

/// BasicStyle, with each `card` in a chrome box (its text at `textInset`) and, when managed, a
/// strip of pills under its content.
struct StripTestStyle: DocStyle {
    var base = BasicStyle()
    static let textInset: CGFloat = 46
    static let paddingBottom: CGFloat = 18

    func paragraph(_ textblock: Node, ancestors: [Node], marker: BlockMarker?) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
        var (attrs, deco) = base.paragraph(textblock, ancestors: ancestors, marker: marker)
        if ancestors.contains(where: { $0.type.name == "card" }), let ps = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            ps.firstLineHeadIndent += Self.textInset
            ps.headIndent += Self.textInset
            ps.tailIndent = -16
            attrs[.paragraphStyle] = ps
        }
        return (attrs, deco)
    }
    func inline(_ marks: [Mark], base attrs: [NSAttributedString.Key: Any], textblock: Node, ancestors: [Node]) -> [NSAttributedString.Key: Any] {
        base.inline(marks, base: attrs, textblock: textblock, ancestors: ancestors)
    }
    func leafBlock(_ node: Node, ancestors: [Node]) -> ([NSAttributedString.Key: Any], BlockDecoration?) { base.leafBlock(node, ancestors: ancestors) }
    func inlineLeaf(_ node: Node, base attrs: [NSAttributedString.Key: Any]) -> NSAttributedString { base.inlineLeaf(node, base: attrs) }
    func marker(for child: Node, in parent: Node, index: Int) -> BlockMarker? { base.marker(for: child, in: parent, index: index) }

    func chrome(for node: Node) -> ChromeBox? {
        guard node.type.name == "card" else { return nil }
        var box = ChromeBox()
        box.margin = 6
        box.paddingTop = 12
        box.paddingBottom = Self.paddingBottom
        box.fill = NSColor(white: 1, alpha: 1)
        box.border = NSColor(white: 0.8, alpha: 1)
        return box
    }

    func strip(for node: Node) -> ChromeStrip? {
        guard node.type.name == "card", node.attrs["managed"]?.boolValue == true else { return nil }
        func value(_ key: String) -> String? {
            guard let s = node.attrs[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        var pills: [ChromePill] = []
        if let s = value("status") { pills.append(ChromePill(id: "status", text: s, dot: .systemBlue, accessibilityLabel: "Status: \(s)")) }
        if let s = value("duration") { pills.append(ChromePill(id: "duration", text: s, symbol: "clock", accessibilityLabel: "Duration: \(s)")) }
        if let s = value("due") { pills.append(ChromePill(id: "dueDate", text: s, symbol: "calendar", accessibilityLabel: "Due \(s)")) }
        if let s = value("scheduled") {
            pills.append(ChromePill(id: "scheduled", text: s, symbol: "calendar.badge.clock", accessibilityLabel: "Scheduled \(s)"))
        }
        guard !pills.isEmpty else { return nil }
        return ChromeStrip(pills: pills, font: .systemFont(ofSize: 11, weight: .medium), textColor: .secondaryLabelColor,
                           iconColor: .tertiaryLabelColor, fill: NSColor(white: 0, alpha: 0.12), hoverFill: NSColor(white: 0, alpha: 0.2),
                           inset: Self.textInset, trailingInset: 16)
    }
}

/// A chrome box's strip of pills on the Mac: its layout inside the box, wrapping, when it
/// shows, clicks and hover, VoiceOver, and the cost of drawing a document full of strips.
@MainActor
final class ChromeStripTests: XCTestCase {
    private var windows: [NSWindow] = []
    override func tearDown() {
        for w in windows { w.close() }
        windows = []
        super.tearDown()
    }

    static let managed: JSONValue = ["managed": true, "status": "In Progress", "duration": "30m", "due": "Nov 21",
                                     "scheduled": "Nov 22, 2:00 PM"]

    private func card(_ title: String, _ attrs: JSONValue) -> JSONValue { J.node("card", attrs, [J.p(title)]) }
    private func attrs(_ changes: [String: JSONValue]) -> JSONValue {
        guard case .object(var o) = Self.managed else { return Self.managed }
        for (k, v) in changes { o[k] = v }
        return .object(o)
    }

    private func makeView(_ blocks: [JSONValue], width: CGFloat = 600, caretInCard: Bool = false) throws -> ProseTextView {
        let schema = StripTestSchema.schema
        let doc = try schema.nodeFromJSON(J.doc(blocks))
        var state = EditorState.create(EditorStateConfig(doc: doc, selection: Selection.atStart(doc), plugins: exampleSetup(schema: schema)))
        if caretInCard {
            var title: Int?
            doc.descendants { node, pos, _, _ in
                if title == nil, node.type.name == "card" { title = pos + 2 }
                return title == nil
            }
            state = state.apply(state.tr.setSelection(TextSelection.create(state.doc, try XCTUnwrap(title))))
        }
        let tv = ProseTextView(state: state, style: StripTestStyle())
        tv.animatesChrome = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tv
        windows.append(window)
        settle(tv)
        return tv
    }

    private func settle(_ tv: ProseTextView) {
        tv.window?.layoutIfNeeded()
        tv.layoutSubtreeIfNeeded()
        if let tlm = tv.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
    }

    private func cardPositions(_ tv: ProseTextView) -> [Int] {
        var out: [Int] = []
        tv.state.doc.descendants { node, pos, _, _ in
            if node.type.name == "card" { out.append(pos) }
            return true
        }
        return out
    }

    private func region(_ tv: ProseTextView, _ pos: Int) throws -> ChromeRegion {
        try XCTUnwrap(tv.renderer.chromes.first { $0.pos == pos })
    }

    private func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    // MARK: Layout

    func testStripRowsWrapAtNarrowWidths() {
        let pills = (0..<4).map { ChromePill(id: "p\($0)", text: "Pill number \($0)", symbol: "clock", accessibilityLabel: "") }
        let strip = ChromeStrip(pills: pills, font: .systemFont(ofSize: 11), textColor: .labelColor, iconColor: .labelColor,
                                fill: .gray, hoverFill: .gray, inset: 46, trailingInset: 16)
        let wide = strip.frames(width: 2000)
        XCTAssertEqual(Set(wide.map(\.minY)), [strip.topGap], "one row when there's room")
        XCTAssertEqual(strip.height(width: 2000), strip.topGap + strip.pillHeight)
        XCTAssertEqual(strip.frames(width: 0).map(\.minY), wide.map(\.minY), "no width yet: one row")
        let narrow = strip.frames(width: strip.widths[0] + strip.widths[1] + strip.gap + 1)
        XCTAssertEqual(narrow.map(\.minY), [4, 4, 4 + strip.pillHeight + strip.gap, 4 + strip.pillHeight + strip.gap])
        XCTAssertEqual(strip.height(width: 10), strip.topGap + 4 * strip.pillHeight + 3 * strip.gap, "a pill per row, none clipped")
        for (a, b) in zip(narrow, narrow.dropFirst()) where a.minY == b.minY {
            XCTAssertEqual(b.minX - a.maxX, strip.gap, accuracy: 0.01)
        }
    }

    func testBoxGrowsByItsStrip() throws {
        let plain = try makeView([J.p("Before"), card("Water the ferns", ["managed": false])])
        let managed = try makeView([J.p("Before"), card("Water the ferns", Self.managed)])
        let plainPos = try XCTUnwrap(cardPositions(plain).first), pos = try XCTUnwrap(cardPositions(managed).first)
        let r = try region(managed, pos)
        XCTAssertGreaterThan(r.stripHeight, 15)
        XCTAssertNil(try region(plain, plainPos).strip)
        let grown = try XCTUnwrap(managed.chromeFrame(at: pos)).height - (try XCTUnwrap(plain.chromeFrame(at: plainPos)).height)
        XCTAssertEqual(grown, r.stripHeight, accuracy: 0.5, "the box grows by the strip, nothing else moves")
        // The pills sit at the text column, under the content, above the bottom padding.
        let box = try XCTUnwrap(managed.chromeFrame(at: pos))
        let pills = managed.chromePills(at: pos)
        XCTAssertEqual(pills.map(\.id), ["status", "duration", "dueDate", "scheduled"], "the strip's order")
        XCTAssertEqual(try XCTUnwrap(pills.first).rect.minX - box.minX, StripTestStyle.textInset, accuracy: 0.5)
        XCTAssertEqual(box.maxY - (try XCTUnwrap(pills.map(\.rect.maxY).max())), StripTestStyle.paddingBottom, accuracy: 0.5)
        for p in pills { XCTAssertTrue(box.contains(p.rect), "\(p.id) inside the box") }
    }

    func testStripWrapsInANarrowViewAndFollowsTheWidth() throws {
        let wide = try makeView([J.p("Before"), card("Water the ferns", Self.managed)], width: 700)
        let pos = try XCTUnwrap(cardPositions(wide).first)
        let oneRow = try region(wide, pos).stripHeight
        XCTAssertEqual(Set(wide.chromePills(at: pos).map(\.rect.minY)).count, 1)
        let narrow = try makeView([J.p("Before"), card("Water the ferns", Self.managed)], width: 260)
        XCTAssertGreaterThan(try region(narrow, pos).stripHeight, oneRow + 10, "rows added")
        XCTAssertGreaterThan(Set(narrow.chromePills(at: pos).map(\.rect.minY)).count, 1)
        // Resizing the window relays the strip: the same view, back to one row.
        narrow.window?.setContentSize(NSSize(width: 700, height: 700))
        settle(narrow)
        XCTAssertEqual(try region(narrow, pos).stripHeight, oneRow, accuracy: 0.01)
        let box = try XCTUnwrap(narrow.chromeFrame(at: pos))
        for p in narrow.chromePills(at: pos) { XCTAssertTrue(box.contains(p.rect)) }
    }

    func testNoStripWhenTheStyleGivesNone() throws {
        let unmanaged = try makeView([card("A", attrs(["managed": false]))])
        XCTAssertNil(try region(unmanaged, 0).strip, "values but no strip")
        let empty = try makeView([card("A", attrs(["status": .null, "duration": .null, "due": "", "scheduled": "  "]))])
        XCTAssertNil(try region(empty, 0).strip)
        XCTAssertEqual(try XCTUnwrap(empty.chromeFrame(at: 0)).height, try XCTUnwrap(unmanaged.chromeFrame(at: 0)).height, accuracy: 0.5)
        let dueOnly = try makeView([card("A", attrs(["status": .null, "duration": .null, "scheduled": .null]))])
        XCTAssertEqual(dueOnly.chromePills(at: 0).map(\.id), ["dueDate"])
    }

    // MARK: Clicks

    func testPillTapFiresWithItsIdAndNowhereElse() throws {
        let tv = try makeView([J.p("Before"), card("Water the ferns", Self.managed)])
        var got: [ChromePillHit] = []
        tv.onChromePillTap = { got.append($0) }
        let pos = try XCTUnwrap(cardPositions(tv).first)
        let pills = tv.chromePills(at: pos)
        for p in pills { XCTAssertTrue(tv.tapChromePill(at: center(p.rect))) }
        XCTAssertEqual(got.map(\.id), ["status", "duration", "dueDate", "scheduled"])
        XCTAssertEqual(got.map(\.pos), Array(repeating: pos, count: 4))
        XCTAssertEqual(got.map(\.rect), pills.map(\.rect))
        got = []
        let box = try XCTUnwrap(tv.chromeFrame(at: pos))
        // The title, the gap between two pills, the box's empty right side: no pill.
        let between = CGPoint(x: pills[0].rect.maxX + 2, y: pills[0].rect.midY)
        for point in [CGPoint(x: box.minX + 60, y: box.minY + 20), between, CGPoint(x: box.maxX - 4, y: pills[0].rect.midY)] {
            XCTAssertFalse(tv.tapChromePill(at: point), "\(point)")
        }
        XCTAssertTrue(got.isEmpty)
        tv.chromePillsEnabled = { false }
        XCTAssertFalse(tv.tapChromePill(at: center(pills[0].rect)), "disabled (read-only)")
        tv.chromePillsEnabled = { true }
        tv.onChromePillTap = nil
        XCTAssertFalse(tv.tapChromePill(at: center(pills[0].rect)), "no handler: pills are only drawn")
    }

    func testClickOnAPillKeepsTheCaretAndTheBoxClosed() throws {
        let tv = try makeView([J.p("Before"), card("Water the ferns", Self.managed)])
        var got: [String] = []
        tv.onChromePillTap = { got.append($0.id) }
        let pos = try XCTUnwrap(cardPositions(tv).first)
        let pill = try XCTUnwrap(tv.chromePills(at: pos).dropFirst(2).first)
        let selection = tv.state.selection
        let window = try XCTUnwrap(tv.window)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: tv.convert(center(pill.rect), to: nil), modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
        tv.mouseDown(with: event)
        XCTAssertEqual(got, ["dueDate"])
        XCTAssertTrue(tv.state.selection.eq(selection), "the caret stays where it was")
        XCTAssertNil(tv.activeChrome, "the box doesn't activate")
    }

    func testPointerOverAPillHighlightsIt() throws {
        let tv = try makeView([J.p("Before"), card("Water the ferns", Self.managed)])
        tv.onChromePillTap = { _ in }
        let pos = try XCTUnwrap(cardPositions(tv).first)
        let pill = try XCTUnwrap(tv.chromePills(at: pos).dropFirst().first)
        let window = try XCTUnwrap(tv.window)
        func move(to point: CGPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: tv.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            tv.mouseMoved(with: event)
        }
        try move(to: center(pill.rect))
        XCTAssertEqual(tv.hoveredPill(pos), 1)
        try move(to: CGPoint(x: 5, y: 5))
        XCTAssertNil(tv.hoveredPill(pos))
    }

    /// A document set into a view that is already laid out renders its strips at the view's
    /// width at once: they don't move at the first layout.
    func testStripsRenderAtTheViewsWidthFromTheStart() throws {
        let tv = try makeView([J.p("x")], width: 260)
        let doc = try StripTestSchema.schema.nodeFromJSON(J.doc([J.p("Before"), card("Water the ferns", Self.managed)]))
        tv.setState(EditorState.create(EditorStateConfig(doc: doc, plugins: tv.state.plugins)))
        let r = try XCTUnwrap(tv.renderer.chromes.first)
        let strip = try XCTUnwrap(r.strip)
        XCTAssertGreaterThan(r.stripHeight, strip.height(width: 0) + 10, "wrapped before any layout")
        settle(tv)
        XCTAssertEqual(try XCTUnwrap(tv.renderer.chromes.first).stripHeight, r.stripHeight, "and it stays")
    }

    /// The highlighted pill follows the text: after the box changes under a still pointer, the
    /// highlight is the pill now there (or none).
    func testHoverFollowsARelayout() throws {
        let tv = try makeView([J.p("Before"), card("Water the ferns", Self.managed)])
        tv.onChromePillTap = { _ in }
        let pos = try XCTUnwrap(cardPositions(tv).first)
        let pills = tv.chromePills(at: pos)
        let point = center(pills[0].rect)
        tv.refreshPillHover(at: point)
        XCTAssertEqual(tv.hoveredPill(pos), 0)
        let node = try XCTUnwrap(tv.state.doc.nodeAt(pos))
        var attrs = node.attrs
        attrs["status"] = .string("A much longer status than before")
        tv.dispatch(try tv.state.tr.setNodeMarkup(pos, nil, attrs))
        settle(tv)
        tv.refreshPillHover(at: point)
        XCTAssertEqual(tv.hoveredPillHit?.rect, tv.chromePills(at: pos).first?.rect, "the new frame")
        attrs["managed"] = .bool(false)
        tv.dispatch(try tv.state.tr.setNodeMarkup(pos, nil, attrs))
        settle(tv)
        tv.refreshPillHover(at: point)
        XCTAssertNil(tv.hoveredPillHit, "no strip, no highlight")
    }

    /// Changing one box's attributes restyles only that box; dropping its strip shrinks it back.
    func testAttributeChangeRestylesOnlyThatBox() throws {
        let tv = try makeView([card("First", attrs(["managed": false])), J.p("Between"), card("Second", Self.managed)])
        let storage = try XCTUnwrap(tv.textStorage)
        let positions = cardPositions(tv)
        let secondTitle = tv.renderer.stringOffset(positions[1] + 2)
        let before = storage.attribute(.paragraphStyle, at: secondTitle, effectiveRange: nil) as AnyObject?
        var first = try XCTUnwrap(tv.state.doc.nodeAt(positions[0])).attrs
        first["managed"] = .bool(true)
        first["status"] = .string("Done")
        first["duration"] = .string("2h")
        first["due"] = .null
        first["scheduled"] = .null
        tv.dispatch(try tv.state.tr.setNodeMarkup(positions[0], nil, first))
        settle(tv)
        let after = storage.attribute(.paragraphStyle, at: secondTitle, effectiveRange: nil) as AnyObject?
        XCTAssertTrue(before === after, "the other box's text is untouched")
        XCTAssertEqual(tv.renderer.chromes.first { $0.pos == positions[0] }?.strip?.pills.map(\.text), ["Done", "2h"])
        XCTAssertEqual(tv.renderer.chromes.first { $0.pos == positions[1] }?.strip?.pills.count, 4)
        let managedHeight = try XCTUnwrap(tv.chromeFrame(at: positions[0])).height
        first["managed"] = .bool(false)
        tv.dispatch(try tv.state.tr.setNodeMarkup(positions[0], nil, first))
        settle(tv)
        XCTAssertNil(tv.renderer.chromes.first { $0.pos == positions[0] }?.strip)
        XCTAssertLessThan(try XCTUnwrap(tv.chromeFrame(at: positions[0])).height, managedHeight - 15)
    }

    // MARK: VoiceOver

    func testVoiceOverOffersThePillsOfTheBoxAtTheCaret() throws {
        let away = try makeView([J.p("Before"), card("Water the ferns", Self.managed)])
        away.onChromePillTap = { _ in }
        XCTAssertFalse((away.accessibilityCustomActions() ?? []).contains { $0.name.hasPrefix("Status") }, "caret outside the box")
        let tv = try makeView([J.p("Before"), card("Water the ferns", Self.managed)], caretInCard: true)
        var got: [String] = []
        tv.onChromePillTap = { got.append($0.id) }
        let actions = tv.accessibilityCustomActions() ?? []
        let names = actions.map(\.name)
        for name in ["Status: In Progress", "Duration: 30m", "Due Nov 21", "Scheduled Nov 22, 2:00 PM"] {
            XCTAssertTrue(names.contains(name), "\(name) in \(names)")
        }
        let due = try XCTUnwrap(actions.first { $0.name == "Due Nov 21" })
        XCTAssertEqual(due.handler?(), true)
        XCTAssertEqual(got, ["dueDate"])
    }

    /// Each pill on screen is its own VoiceOver button, wherever the caret is; pressing one
    /// presses the pill. Read-only: still read out, not buttons.
    func testEachPillIsAnAccessibilityButton() throws {
        let tv = try makeView([J.p("Before"), card("Water the ferns", Self.managed)])
        var got: [String] = []
        tv.onChromePillTap = { got.append($0.id) }
        let pills = (tv.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }.filter { $0 is PillAccessibilityElement }
        XCTAssertEqual(pills.compactMap { $0.accessibilityLabel() },
                       ["Status: In Progress", "Duration: 30m", "Due Nov 21", "Scheduled Nov 22, 2:00 PM"])
        XCTAssertTrue(pills.allSatisfy { $0.accessibilityRole() == .button })
        let pos = try XCTUnwrap(cardPositions(tv).first)
        XCTAssertEqual(pills[2].accessibilityFrameInParentSpace(), tv.chromePills(at: pos)[2].rect)
        XCTAssertTrue(pills[2].accessibilityPerformPress())
        XCTAssertEqual(got, ["dueDate"])
        // The same objects while the pills stay.
        let again = (tv.accessibilityChildren() ?? []).compactMap { $0 as? PillAccessibilityElement }
        XCTAssertTrue(again.first === pills.first)
        tv.chromePillsEnabled = { false }
        let readOnly = (tv.accessibilityChildren() ?? []).compactMap { $0 as? PillAccessibilityElement }
        XCTAssertEqual(readOnly.count, 4)
        XCTAssertTrue(readOnly.allSatisfy { $0.accessibilityRole() == .staticText })
        XCTAssertFalse(readOnly[0].accessibilityPerformPress())
        XCTAssertEqual(got, ["dueDate"])
    }

    // MARK: Drawing

    /// Drawing a band of a document with many strips looks only at the boxes near it.
    func testDrawCostWithManyStrips() throws {
        func regions(_ cards: Int, managed: Bool = true) throws -> Int {
            var blocks: [JSONValue] = []
            for i in 0..<cards {
                blocks.append(J.p("Paragraph \(i) with some words in it to fill a line."))
                blocks.append(card("Task \(i)", attrs(["managed": .bool(managed)])))
            }
            let tv = try makeView(blocks, width: 700)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
            tv.window?.contentView = scroll
            scroll.documentView = tv
            tv.frame = NSRect(x: 0, y: 0, width: 700, height: 700)
            settle(tv)
            let mid = tv.frame.height / 2
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 700, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let ctx = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            func draw(_ rect: NSRect) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                ctx.cgContext.translateBy(x: 0, y: -rect.minY)
                tv.drawBackground(in: rect)
                ctx.cgContext.translateBy(x: 0, y: rect.minY)
                NSGraphicsContext.restoreGraphicsState()
            }
            draw(NSRect(x: 0, y: mid, width: 700, height: 60))
            ChromeDrawStats.regionsExamined = 0
            for i in 0..<10 { draw(NSRect(x: 0, y: mid + CGFloat(i * 20), width: 700, height: 60)) }
            return Int((Double(ChromeDrawStats.regionsExamined) / 10).rounded(.up))
        }
        let few = try regions(10)
        let many = try regions(400)
        XCTAssertGreaterThan(few, 0)
        XCTAssertLessThanOrEqual(many, few + 2)
    }

    func testStripPillsAreDrawn() throws {
        let tv = try makeView([J.p("Before"), card("Water the ferns", Self.managed)])
        tv.window?.appearance = NSAppearance(named: .aqua)
        settle(tv)
        let pos = try XCTUnwrap(cardPositions(tv).first)
        let pill = try XCTUnwrap(tv.chromePills(at: pos).first).rect
        // A pixel inside the first pill, left of its dot: the fill, darker than the box around it.
        func pixel(at p: CGPoint) -> CGFloat {
            let rect = NSRect(x: p.x, y: p.y, width: 1, height: 1)
            let rep = tv.bitmapImageRepForCachingDisplay(in: rect)!
            tv.cacheDisplay(in: rect, to: rep)
            return rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)?.brightnessComponent ?? -1
        }
        let inside = pixel(at: CGPoint(x: pill.minX + 3, y: pill.midY))
        let outside = pixel(at: CGPoint(x: pill.minX - 3, y: pill.midY))
        XCTAssertLessThan(inside, outside - 0.02, "pill fill drawn (inside \(inside), outside \(outside))")
    }
}
#endif
