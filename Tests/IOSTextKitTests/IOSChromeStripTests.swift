#if os(iOS)
import XCTest
import UIKit
import PMModel
import PMState
@testable import PMTextKit

/// A touch at a chosen point, for the pill tap's gate.
private final class StripTouch: UITouch {
    var point = CGPoint.zero
    override func location(in view: UIView?) -> CGPoint { point }
}

/// A tap at a chosen point and state.
private final class StripTapFake: UITapGestureRecognizer {
    var point = CGPoint.zero
    var fakeState: UIGestureRecognizer.State = .ended
    override func location(in view: UIView?) -> CGPoint { point }
    override var state: UIGestureRecognizer.State {
        get { fakeState }
        set { fakeState = newValue }
    }
}

/// A long press at a chosen point.
private final class StripPressFake: UILongPressGestureRecognizer {
    var point = CGPoint.zero
    override func location(in view: UIView?) -> CGPoint { point }
}

/// A chrome box's strip of pills on iOS (`CheckCardStyle`'s cards with status, duration, due
/// and scheduled set): layout and wrapping on a phone, taps on pills (which never move the
/// caret), pills turned off, VoiceOver, menus, and scrolling a document of such cards.
@MainActor
final class IOSChromeStripTests: XCTestCase {
    private var hosts: [HostedTextView] = []

    override func tearDown() {
        for host in hosts { host.window.isHidden = true }
        hosts = []
        super.tearDown()
    }

    private func textView(_ blocks: [JSONValue]? = nil, width: CGFloat = 402) throws -> ProseTextView {
        let doc = try CheckCard.doc(blocks ?? [CheckCard.json("Water the ferns", strip: true), J.p("Later")])
        let host = CheckCard.host(doc, width: width)
        hosts.append(host)
        return host.view
    }

    private func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    private let labels = ["Status: In Progress", "Duration: 30m", "Due Nov 21", "Scheduled Nov 22, 2:00 PM"]

    // MARK: Layout

    func testStripWrapsOnAPhoneAndTakesOneRowWhenWide() throws {
        let phone = try textView()
        let pos = try XCTUnwrap(CheckCard.positions(phone.state.doc).first)
        let pills = phone.chromePills(at: pos)
        XCTAssertEqual(pills.map(\.id), ["status", "duration", "dueDate", "scheduled"])
        XCTAssertGreaterThan(Set(pills.map(\.rect.minY)).count, 1, "four pills wrap on a 402 pt phone")
        let box = try XCTUnwrap(phone.chromeFrame(at: pos))
        for p in pills { XCTAssertTrue(box.contains(p.rect), "\(p.id) inside the card") }
        XCTAssertEqual(try XCTUnwrap(pills.first).rect.minX - box.minX, CheckCardStyle.textInset, accuracy: 0.5, "at the strip's inset")

        let wide = try textView(width: 1000)
        let widePills = wide.chromePills(at: pos)
        XCTAssertEqual(Set(widePills.map(\.rect.minY)).count, 1)
        XCTAssertLessThan(try XCTUnwrap(wide.chromeFrame(at: pos)).height, box.height - 10, "fewer rows, shorter card")
    }

    func testBoxWithoutPillsHasNoStrip() throws {
        let tv = try textView([CheckCard.json("Water the ferns"), J.p("Later")])
        let pos = try XCTUnwrap(CheckCard.positions(tv.state.doc).first)
        XCTAssertTrue(tv.chromePills(at: pos).isEmpty)
        XCTAssertNil(tv.renderer.chromes.first?.strip)
    }

    func testPillsAreDrawnInTheDecorations() throws {
        let tv = try textView()
        let pos = try XCTUnwrap(CheckCard.positions(tv.state.doc).first)
        let pill = try XCTUnwrap(tv.chromePills(at: pos).first).rect
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        func brightness(at p: CGPoint) -> CGFloat {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
                ctx.cgContext.translateBy(x: -p.x, y: -p.y)
                tv.drawDecorations(in: CGRect(x: p.x, y: p.y, width: 1, height: 1))
            }
            let data = image.cgImage!.dataProvider!.data! as Data
            return CGFloat(data[0]) / 255
        }
        XCTAssertLessThan(brightness(at: CGPoint(x: pill.minX + 3, y: pill.midY)),
                          brightness(at: CGPoint(x: pill.minX - 3, y: pill.midY)) - 0.02, "the pill's fill")
    }

    // MARK: Taps

    func testTapOnAPillReportsItAndKeepsTheCaret() throws {
        let tv = try textView()
        var got: [ChromePillHit] = []
        tv.onChromePillTap = { got.append($0) }
        tv.dispatch(tv.state.tr.setSelection(TextSelection.atEnd(tv.state.doc)))
        let selection = tv.state.selection
        let pos = try XCTUnwrap(CheckCard.positions(tv.state.doc).first)
        let pills = tv.chromePills(at: pos)
        for p in pills {
            let tap = StripTapFake()
            tap.point = center(p.rect)
            tv.pillTapped(tap)
        }
        XCTAssertEqual(got.map(\.id), ["status", "duration", "dueDate", "scheduled"])
        XCTAssertEqual(Set(got.map(\.pos)), [pos])
        XCTAssertEqual(got.map(\.rect), pills.map(\.rect), "anchored at the pill, content coordinates")
        XCTAssertTrue(tv.state.selection.eq(selection), "the caret stays where it was")
        XCTAssertFalse(tv.isFirstResponder, "no keyboard")
        XCTAssertNil(tv.chromeState.activePos, "the card doesn't open")
        // Away from the pills: nothing.
        let box = try XCTUnwrap(tv.chromeFrame(at: pos))
        XCTAssertFalse(tv.tapChromePill(at: CGPoint(x: box.maxX - 4, y: box.minY + 10)))
        XCTAssertEqual(got.count, 4)
    }

    /// On a pill only the pill tap takes the touch, and UIKit's text taps wait for it (and don't
    /// begin there), so the caret never moves; elsewhere the pill tap stays out of the way.
    func testPillGateTakesOnlyPillTouches() throws {
        let tv = try textView()
        tv.onChromePillTap = { _ in }
        let pillTap = tv.pillTap
        XCTAssertTrue(tv.gestureRecognizers?.contains(pillTap) == true)
        let pos = try XCTUnwrap(CheckCard.positions(tv.state.doc).first)
        let on = center(try XCTUnwrap(tv.chromePills(at: pos).first).rect)
        let box = try XCTUnwrap(tv.chromeFrame(at: pos))
        let off = CGPoint(x: box.minX + 80, y: box.minY + 24)
        let touch = StripTouch()
        touch.point = on
        XCTAssertEqual(pillTap.delegate?.gestureRecognizer?(pillTap, shouldReceive: touch), true)
        touch.point = off
        XCTAssertEqual(pillTap.delegate?.gestureRecognizer?(pillTap, shouldReceive: touch), false)
        let others = (tv.gestureRecognizers ?? []).filter { $0 !== pillTap && $0 is UITapGestureRecognizer }
        for other in others {
            XCTAssertEqual(pillTap.delegate?.gestureRecognizer?(pillTap, shouldBeRequiredToFailBy: other), true)
        }
        let text = StripTapFake()
        text.point = on
        XCTAssertFalse(tv.gestureRecognizerShouldBegin(text), "a text tap doesn't begin on a pill")
        XCTAssertFalse(tv.isOnMarker(on))
        XCTAssertFalse(tv.isOnCardControl(on), "nor the card's long press")
        let press = StripPressFake()
        press.point = on
        XCTAssertFalse(tv.gestureRecognizerShouldBegin(press), "no loupe or selection on a pill")
        press.point = off
        XCTAssertTrue(tv.gestureRecognizerShouldBegin(press), "the text's long press elsewhere")
        // The card is open (caret in it): still no card menu over its strip.
        tv.dispatch(tv.state.tr.setSelection(TextSelection.create(tv.state.doc, pos + 3)))
        tv.layoutIfNeeded()
        let openPill = center(try XCTUnwrap(tv.chromePills(at: pos).first).rect)
        XCTAssertNil(tv.cardMenuTarget(at: openPill))
    }

    /// With pills turned off (a read-only document), taps on them aren't reported and are the
    /// text's again; the pills are still drawn.
    func testDisabledPillsAreNotTapped() throws {
        let tv = try textView()
        var got = 0
        tv.onChromePillTap = { _ in got += 1 }
        let pos = try XCTUnwrap(CheckCard.positions(tv.state.doc).first)
        let on = center(try XCTUnwrap(tv.chromePills(at: pos).first).rect)
        tv.chromePillsEnabled = { false }
        XCTAssertFalse(tv.tapChromePill(at: on))
        let touch = StripTouch()
        touch.point = on
        XCTAssertEqual(tv.pillTap.delegate?.gestureRecognizer?(tv.pillTap, shouldReceive: touch), false, "the tap is the text's again")
        XCTAssertEqual(got, 0)
        XCTAssertFalse(tv.chromePills(at: pos).isEmpty, "still drawn")
    }

    /// The strip follows the node: changing one card's attributes restyles its pills, and the
    /// other card keeps its own.
    func testStripFollowsTheNodesAttributes() throws {
        let tv = try textView([CheckCard.json("First", strip: true), J.p("Later"), CheckCard.json("Second", strip: true)])
        let positions = CheckCard.positions(tv.state.doc)
        func setAttrs(_ pos: Int, _ values: [String: String]) throws {
            var attrs = try XCTUnwrap(tv.state.doc.nodeAt(pos)).attrs
            for (k, v) in values { attrs[k] = .string(v) }
            tv.dispatch(try tv.state.tr.setNodeMarkup(pos, nil, attrs))
        }
        try setAttrs(positions[0], ["status": "Done", "duration": "", "due": "", "scheduled": ""])
        tv.layoutIfNeeded()
        XCTAssertEqual(tv.chromePills(at: positions[0]).map(\.id), ["status"])
        XCTAssertEqual(tv.chromePills(at: positions[1]).count, 4, "the other card keeps its strip")
        try setAttrs(positions[0], ["status": ""])
        XCTAssertTrue(tv.chromePills(at: positions[0]).isEmpty)
    }

    // MARK: VoiceOver

    func testVoiceOverOffersThePillsOfTheCardAtTheCaret() throws {
        let tv = try textView()
        var got: [String] = []
        tv.onChromePillTap = { got.append($0.id) }
        let pos = try XCTUnwrap(CheckCard.positions(tv.state.doc).first)
        tv.dispatch(tv.state.tr.setSelection(Selection.atEnd(tv.state.doc)))
        XCTAssertFalse((tv.accessibilityCustomActions ?? []).contains { $0.name.hasPrefix("Status") })
        tv.dispatch(tv.state.tr.setSelection(TextSelection.create(tv.state.doc, pos + 3)))
        let actions = tv.accessibilityCustomActions ?? []
        let names = actions.map(\.name)
        for name in labels { XCTAssertTrue(names.contains(name), "\(name) in \(names)") }
        let status = try XCTUnwrap(actions.first { $0.name == "Status: In Progress" })
        XCTAssertEqual(status.actionHandler?(status), true)
        XCTAssertEqual(got, ["status"])
    }

    /// Each pill on screen is its own VoiceOver button (in the decorations view, wherever the
    /// caret is); activating one presses it. With pills off they are static text.
    func testEachPillIsAnAccessibilityButton() throws {
        let tv = try textView()
        var got: [String] = []
        tv.onChromePillTap = { got.append($0.id) }
        let pos = try XCTUnwrap(CheckCard.positions(tv.state.doc).first)
        XCTAssertFalse(tv.decorations.isAccessibilityElement)
        let elements = (tv.decorations.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
        XCTAssertEqual(elements.compactMap(\.accessibilityLabel), labels)
        XCTAssertTrue(elements.allSatisfy { $0.accessibilityTraits.contains(.button) })
        XCTAssertEqual(elements[1].accessibilityFrameInContainerSpace, tv.chromePills(at: pos)[1].rect)
        XCTAssertTrue(elements[1].accessibilityActivate())
        XCTAssertEqual(got, ["duration"])
        tv.chromePillsEnabled = { false }
        let readOnly = (tv.decorations.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
        XCTAssertFalse(readOnly.contains { $0.accessibilityTraits.contains(.button) })
        XCTAssertFalse(readOnly[0].accessibilityActivate())
        XCTAssertEqual(got, ["duration"])
    }

    /// Pills with a menu (`chromePillMenu`) get a menu button over each on screen, following the
    /// text as it scrolls and relays; the other pills keep the pill tap. UIKit's text taps don't
    /// begin there, pills turned off get no buttons, and VoiceOver finds the button rather than a
    /// second element.
    func testMenuPillsAreMenuButtons() throws {
        let tv = try textView([J.p("Later"), CheckCard.json("Water the ferns", strip: true)]
                              + Array(repeating: J.p("Later"), count: 80))
        var taps: [String] = []
        tv.onChromePillTap = { taps.append($0.id) }
        tv.chromePillMenu = { hit in
            hit.id == "status" || hit.id == "duration" ? UIMenu(children: [UIAction(title: "\(hit.pos) \(hit.id)") { _ in }]) : nil
        }
        tv.layoutIfNeeded()
        let pos = try XCTUnwrap(CheckCard.positions(tv.state.doc).first)
        let pills = tv.chromePills(at: pos)
        var buttons = tv.pillMenuButtons
        XCTAssertEqual(buttons.map(\.hit.id), ["status", "duration"])
        XCTAssertEqual(buttons.map(\.button.frame), [pills[0].rect, pills[1].rect])
        XCTAssertTrue(buttons.allSatisfy { $0.button.showsMenuAsPrimaryAction && $0.button.superview === tv })
        XCTAssertEqual(buttons.map(\.button.accessibilityLabel), ["Status: In Progress", "Duration: 30m"])
        XCTAssertEqual(tv.pillMenu(for: buttons[0].hit)?.children.first?.title, "\(pos) status")
        // On a menu pill: no text tap, no pill tap. On the due pill: the pill tap.
        let touch = StripTouch()
        touch.point = center(pills[0].rect)
        XCTAssertEqual(tv.pillTap.delegate?.gestureRecognizer?(tv.pillTap, shouldReceive: touch), false)
        let text = StripTapFake()
        text.point = center(pills[0].rect)
        XCTAssertFalse(tv.gestureRecognizerShouldBegin(text))
        touch.point = center(pills[2].rect)
        XCTAssertEqual(tv.pillTap.delegate?.gestureRecognizer?(tv.pillTap, shouldReceive: touch), true)
        XCTAssertEqual((tv.decorations.accessibilityElements ?? []).compactMap { ($0 as? UIAccessibilityElement)?.accessibilityLabel },
                       ["Due Nov 21", "Scheduled Nov 22, 2:00 PM"])
        // A relayout: the buttons move with their pills.
        var attrs = try XCTUnwrap(tv.state.doc.nodeAt(pos)).attrs
        attrs["status"] = "A much longer status"
        attrs["duration"] = "2h"
        attrs["scheduled"] = ""
        tv.dispatch(try tv.state.tr.setNodeMarkup(pos, nil, attrs))
        tv.layoutIfNeeded()
        buttons = tv.pillMenuButtons
        let moved = tv.chromePills(at: pos)
        XCTAssertEqual(buttons.map(\.button.frame), [moved[0].rect, moved[1].rect])
        // Scrolled away and back: gone, then there again at the pill.
        tv.contentOffset = CGPoint(x: 0, y: max(0, tv.contentSize.height - tv.bounds.height))
        tv.layoutIfNeeded()
        XCTAssertTrue(tv.pillMenuButtons.isEmpty, "off screen")
        tv.contentOffset = .zero
        tv.layoutIfNeeded()
        XCTAssertEqual(tv.pillMenuButtons.map(\.button.frame), [moved[0].rect, moved[1].rect])
        // Pills turned off: no buttons (once the menus are laid out again).
        tv.chromePillsEnabled = { false }
        let menu = tv.chromePillMenu
        tv.chromePillMenu = menu
        tv.layoutIfNeeded()
        XCTAssertTrue(tv.pillMenuButtons.isEmpty)
        XCTAssertTrue(taps.isEmpty)
    }

    // MARK: Scrolling

    /// Scrolling a document of cards with strips draws (almost) nothing, as for plain cards: the
    /// strips are part of the decoration tiles.
    func testScrollStepsStayCheapWithStrips() throws {
        var blocks: [JSONValue] = []
        for i in 0..<300 {
            blocks.append(J.p("Paragraph \(i) with some words in it to fill a line."))
            blocks.append(CheckCard.json("Task \(i)", strip: true))
        }
        let tv = try textView(blocks)
        tv.onChromePillTap = { _ in }
        tv.chromePillMenu = { hit in hit.id == "status" ? UIMenu(children: []) : nil }
        for t in tv.decorations.subviews { t.layer.displayIfNeeded() }
        let draws0 = tv.decorations.drawCount
        for i in 1...60 {
            tv.contentOffset = CGPoint(x: 0, y: CGFloat(i) * 12)
            tv.layoutIfNeeded()
            for t in tv.decorations.subviews { t.layer.displayIfNeeded() }
        }
        XCTAssertLessThanOrEqual(tv.decorations.drawCount - draws0, 3, "tile draws in 60 steps of 12 pt")
    }
}
#endif
