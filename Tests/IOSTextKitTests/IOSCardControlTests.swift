#if os(iOS)
import XCTest
import UIKit
import PMModel
import PMState
@testable import PMTextKit
import UIKit.UIGestureRecognizerSubclass

/// A touch at a chosen point, for gesture delegates' `shouldReceive`.
private final class CardFakeTouch: UITouch {
    var point = CGPoint.zero
    override func location(in view: UIView?) -> CGPoint { point }
}

/// A tap at a chosen point and state, for gesture delegates and the view's tap action.
private final class CardFakeTap: UITapGestureRecognizer {
    var point = CGPoint.zero
    var fakeState: UIGestureRecognizer.State = .ended
    override func location(in view: UIView?) -> CGPoint { point }
    override var state: UIGestureRecognizer.State {
        get { fakeState }
        set { fakeState = newValue }
    }
}

/// Chrome controls on the iOS text view, on `CheckCardStyle`'s cards: the checkbox's touch
/// target, the footer buttons, the long-press card menu, the tick animation and pointer hover.
@MainActor
final class IOSCardControlTests: XCTestCase {
    private var hosts: [HostedTextView] = []
    private var toggles: [(Int, Bool)] = []

    override func tearDown() {
        for host in hosts { host.window.isHidden = true }
        hosts = []
        toggles = []
        super.tearDown()
    }

    /// "Plan the garden", then a card "Water the ferns", then "Later".
    private func textView(style: CheckCardStyle = CheckCardStyle()) throws -> ProseTextView {
        let doc = try CheckCard.doc([J.h(1, "Plan the garden"), CheckCard.json("Water the ferns"), J.p("Later")])
        let host = CheckCard.host(doc, style: style) { [weak self] pos, checked in self?.toggles.append((pos, checked)) }
        hosts.append(host)
        return host.view
    }

    private func cardPos(_ tv: ProseTextView) throws -> Int {
        try XCTUnwrap(CheckCard.positions(tv.state.doc).first, "a card")
    }

    private func card(_ tv: ProseTextView) throws -> Node { try XCTUnwrap(tv.state.doc.nodeAt(try cardPos(tv))) }

    /// The drawn checkbox of the card's title, in content coordinates.
    private func checkbox(_ tv: ProseTextView) throws -> CGRect {
        let offset = tv.renderer.stringOffset(try cardPos(tv) + 2)
        return try XCTUnwrap(tv.checkboxRect(atString: offset), "the card's checkbox")
    }

    private func checkboxCentre(_ tv: ProseTextView) throws -> CGPoint {
        let frame = try XCTUnwrap(tv.chromeFrame(at: try cardPos(tv)), "the card's box")
        let box = try checkbox(tv)
        XCTAssertTrue(frame.contains(box), "the checkbox is in the card")
        return CGPoint(x: box.midX, y: box.midY)
    }

    /// UIKit's caret rect before the character at string offset `offset`.
    private func caret(_ tv: ProseTextView, _ offset: Int) throws -> CGRect {
        let position = try XCTUnwrap(tv.position(from: tv.beginningOfDocument, offset: offset))
        return tv.caretRect(for: position)
    }

    /// Put the caret in the "Later" paragraph.
    private func caretInLastParagraph(_ tv: ProseTextView) {
        tv.dispatch(tv.state.tr.setSelection(TextSelection.atEnd(tv.state.doc)))
    }

    // MARK: Checkbox

    /// A tap on the checkbox ticks the card, runs the handler once, and leaves the caret and the
    /// keyboard alone.
    func testTapCheckboxTogglesTheCard() throws {
        let tv = try textView()
        caretInLastParagraph(tv)
        let selection = tv.state.selection
        XCTAssertFalse(tv.isFirstResponder)

        XCTAssertTrue(tv.tapMarker(at: try checkboxCentre(tv)))

        XCTAssertEqual(try card(tv).attrs["checked"]?.boolValue, true)
        XCTAssertEqual(toggles.count, 1, "the handler once per tap")
        XCTAssertEqual(toggles.first?.0, try cardPos(tv))
        XCTAssertEqual(toggles.first?.1, true)
        XCTAssertTrue(tv.state.selection.eq(selection), "the caret stays where it was")
        XCTAssertFalse(tv.isFirstResponder, "no keyboard")

        XCTAssertTrue(tv.tapMarker(at: try checkboxCentre(tv)))
        XCTAssertEqual(try card(tv).attrs["checked"]?.boolValue, false)
        XCTAssertEqual(toggles.map(\.1), [true, false])
    }

    /// UIKit's own taps on the text (caret placement, word selection) wait for the checkbox
    /// tap to fail, so a tap on a checkbox never also moves the caret.
    func testTextTapsWaitForTheCheckboxTap() throws {
        let tv = try textView()
        let markerTap = tv.markerTap
        XCTAssertTrue(tv.gestureRecognizers?.contains(markerTap) == true)
        let others = (tv.gestureRecognizers ?? []).filter { $0 !== markerTap && $0 is UITapGestureRecognizer }
        XCTAssertFalse(others.isEmpty, "UIKit's text taps")
        for other in others {
            XCTAssertEqual(markerTap.delegate?.gestureRecognizer?(markerTap, shouldBeRequiredToFailBy: other), true,
                           "\(type(of: other)) waits for the checkbox tap")
        }
    }

    /// The checkbox tap's gate takes only touches on a checkbox, so away from one UIKit's taps
    /// (and its long presses, anywhere) never wait for it; the card long press likewise.
    func testCheckboxGatesTakeOnlyCheckboxTouches() throws {
        let tv = try textView()
        let on = try checkboxCentre(tv)
        let title = try caret(tv, tv.renderer.stringOffset(try cardPos(tv) + 2))
        let offTitle = CGPoint(x: title.minX + 20, y: title.midY)
        let offParagraph = try caret(tv, tv.renderer.stringOffset(tv.state.doc.content.size - 2))
        let gate = try XCTUnwrap(tv.markerTap.delegate)
        for (point, expected) in [(on, true), (offTitle, false), (CGPoint(x: offParagraph.midX, y: offParagraph.midY), false)] {
            let touch = CardFakeTouch()
            touch.point = point
            XCTAssertEqual(gate.gestureRecognizer?(tv.markerTap, shouldReceive: touch), expected, "checkbox tap receives at \(point)")
            let tap = CardFakeTap(target: nil, action: nil)
            tap.point = point
            XCTAssertEqual(gate.gestureRecognizerShouldBegin?(tap), expected, "checkbox tap begins at \(point)")
            XCTAssertEqual(tv.cardLongPress.delegate?.gestureRecognizer?(tv.cardLongPress, shouldReceive: touch), expected,
                           "card long press receives at \(point)")
        }
        // UIKit's long presses (loupe, selection) never wait for the checkbox tap.
        let press = UILongPressGestureRecognizer()
        tv.addGestureRecognizer(press)
        XCTAssertEqual(gate.gestureRecognizer?(tv.markerTap, shouldBeRequiredToFailBy: press), false)
        // The view keeps its own single taps off a checkbox.
        let tap = CardFakeTap(target: nil, action: nil)
        tap.point = on
        XCTAssertFalse(tv.gestureRecognizerShouldBegin(tap), "UIKit's caret tap doesn't begin on a checkbox")
    }

    /// Without a marker handler, or away from a marker, the marker tap doesn't begin: if it did,
    /// UIKit's text single-tap would fail and a tap would never place the caret.
    func testMarkerTapOnlyBeginsOnAMarker() throws {
        let tv = try textView()
        let markerTap = tv.markerTap
        XCTAssertNotNil(tv.onMarkerClick)
        let tap = CardFakeTap(target: nil, action: nil)
        tap.point = CGPoint(x: 200, y: 600)
        XCTAssertEqual(markerTap.delegate?.gestureRecognizerShouldBegin?(tap), false, "no marker under the touch")
        tap.point = try checkboxCentre(tv)
        XCTAssertEqual(markerTap.delegate?.gestureRecognizerShouldBegin?(tap), true)
        tv.onMarkerClick = nil
        XCTAssertEqual(markerTap.delegate?.gestureRecognizerShouldBegin?(tap), false, "no handler")
    }

    /// The checkbox tap recognizer ending on a checkbox toggles it once, leaving the caret and
    /// the keyboard alone; ending elsewhere does nothing.
    func testCheckboxTapRecognizerTogglesWithoutCaretOrKeyboard() throws {
        let tv = try textView()
        caretInLastParagraph(tv)
        let selection = tv.state.selection
        let tap = CardFakeTap(target: nil, action: nil)
        tap.point = try checkboxCentre(tv)
        tap.fakeState = .changed
        tv.markerTapped(tap)
        XCTAssertEqual(toggles.count, 0, "only when the tap ends")
        tap.fakeState = .ended
        tv.markerTapped(tap)
        XCTAssertEqual(try card(tv).attrs["checked"]?.boolValue, true)
        XCTAssertEqual(toggles.count, 1)
        XCTAssertTrue(tv.state.selection.eq(selection), "the caret stays where it was")
        XCTAssertFalse(tv.isFirstResponder, "no keyboard")
        let title = try caret(tv, tv.renderer.stringOffset(try cardPos(tv) + 2))
        tap.point = CGPoint(x: title.minX + 20, y: title.midY)
        tv.markerTapped(tap)
        XCTAssertEqual(toggles.count, 1, "not on the title text")
    }

    /// The checkbox's touch target is at least 44 × 44 pt around the drawn box, and stops short
    /// of the title text.
    func testCheckboxTargetIsAtLeast44pt() throws {
        let tv = try textView()
        let offset = tv.renderer.stringOffset(try cardPos(tv) + 2)
        let box = try checkbox(tv)
        let target = try XCTUnwrap(tv.checkboxHitRect(atString: offset))
        XCTAssertGreaterThanOrEqual(target.width, 44)
        XCTAssertGreaterThanOrEqual(target.height, 44)
        XCTAssertTrue(target.contains(box))
        let inner = target.insetBy(dx: 1, dy: 1)
        for corner in [CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
                       CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY)] {
            XCTAssertTrue(tv.tapMarker(at: corner), "a tap at \(corner) ticks")
        }
        XCTAssertEqual(toggles.count, 4)
        // The title's first character is the caret's, not the checkbox's.
        let titleStart = try caret(tv, offset)
        XCTAssertGreaterThan(titleStart.minX, target.maxX, "the target ends before the title")
        XCTAssertFalse(tv.tapMarker(at: CGPoint(x: titleStart.minX + 2, y: titleStart.midY)))
    }

    // MARK: Buttons

    /// The active card's buttons are at least 44 × 44 pt to touch.
    func testCardButtonsAreAtLeast44pt() throws {
        let tv = try textView()
        tv.dispatch(tv.state.tr.setSelection(TextSelection.create(tv.state.doc, try cardPos(tv) + 4)))
        XCTAssertEqual(tv.activeChrome?.buttons, CheckCard.controlTitles)
        let card = try XCTUnwrap(tv.chromeFrame(at: try cardPos(tv)))
        for title in CheckCard.controlTitles {
            let frame = try XCTUnwrap(tv.chromeControlFrame(title), title)
            XCTAssertGreaterThanOrEqual(frame.width, 44, title)
            XCTAssertGreaterThanOrEqual(frame.height, 44, title)
            XCTAssertLessThanOrEqual(frame.maxY, card.maxY + 0.5, "\(title) stays in the card")
        }
    }

    /// The footer's buttons run the card's commands, each its own step.
    func testCardButtonsRunTheirCommands() throws {
        let tv = try textView()
        tv.dispatch(tv.state.tr.setSelection(TextSelection.create(tv.state.doc, try cardPos(tv) + 4)))
        tv.pressChromeControl("Note")
        XCTAssertEqual(try card(tv).childCount, 2, "a paragraph added to the card")
        tv.pressChromeControl("New Card")
        XCTAssertEqual(CheckCard.positions(tv.state.doc).count, 2, "a second card")
        tv.pressChromeControl("Delete")
        XCTAssertEqual(CheckCard.positions(tv.state.doc).count, 1)
    }

    /// At every text size a button's 44 pt touch area takes no touch outside its card: where it
    /// would reach past the card's edge (onto the next paragraph's first line), a tap there is the
    /// text's (the caret), not the button's.
    func testCardButtonsTakeNoTouchesOutsideTheCard() throws {
        let tv = try textView()
        var overflowed = false
        for size in stride(from: CGFloat(12), through: 28, by: 2) {
            var style = CheckCardStyle()
            style.base.fontSize = size
            tv.setStyle(style)
            tv.dispatch(tv.state.tr.setSelection(TextSelection.create(tv.state.doc, try cardPos(tv) + 4)))
            tv.layoutIfNeeded()
            let card = try XCTUnwrap(tv.chromeFrame(at: try cardPos(tv)))
            for button in tv.chromeControls.buttons where !button.isHidden {
                let frame = button.frame
                if frame.maxY > card.maxY + 0.5 || frame.minY < card.minY - 0.5 { overflowed = true }
                let inside = CGPoint(x: frame.midX, y: max(frame.minY, card.minY) + 2)
                XCTAssertTrue(tv.hitTest(inside, with: nil) === button, "size \(size): the button takes a touch in the card")
                for y in [frame.maxY - 1, card.maxY + 1, frame.minY + 1, card.minY - 1]
                where !card.contains(CGPoint(x: frame.midX, y: y)) && frame.contains(CGPoint(x: frame.midX, y: y)) {
                    XCTAssertFalse(tv.hitTest(CGPoint(x: frame.midX, y: y), with: nil) === button,
                                   "size \(size): the button took a touch outside its card at y \(y) (card \(card), button \(frame))")
                }
            }
        }
        // Settled, no text size puts a button past its card (footer and bottom padding make 44 pt).
        XCTAssertFalse(overflowed)

        // While the footer is still opening (buttons enabled past half way) the row is shorter
        // than 44 pt, so the buttons reach past the card: there the touch isn't theirs.
        let pos = try cardPos(tv)
        var region = try XCTUnwrap(tv.renderer.chromes.first { $0.pos == pos })
        region.progress = 0.7
        tv.chromeControls.update(in: tv, pos: pos, region: region, controls: tv.chromeControls.controls)
        let card = try XCTUnwrap(tv.chromeRect(region))
        let button = try XCTUnwrap(tv.chromeControls.buttons.first)
        XCTAssertTrue(button.isEnabled)
        XCTAssertGreaterThan(button.frame.maxY, card.maxY + 2, "the button reaches past the card")
        XCTAssertFalse(tv.hitTest(CGPoint(x: button.frame.midX, y: card.maxY + 1), with: nil) === button,
                       "the button took a touch below its card")
        XCTAssertTrue(tv.hitTest(CGPoint(x: button.frame.midX, y: card.maxY - 2), with: nil) === button)
    }

    // MARK: Card menu

    /// A long press on the card's control area (its checkbox, or the button row while active)
    /// shows the card's menu: its controls, by title, Delete destructive.
    func testLongPressShowsCardMenu() throws {
        let tv = try textView()
        let titles = tv.renderer.style.controls(for: try card(tv)).map(\.title)
        XCTAssertEqual(titles, CheckCard.controlTitles)

        let menu = try XCTUnwrap(tv.cardMenu(at: try checkboxCentre(tv)), "the checkbox shows the card menu")
        let actions = menu.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(actions.map(\.title), titles)
        XCTAssertEqual(actions.last?.attributes.contains(.destructive), true)
        XCTAssertTrue(tv.presentCardMenu(at: try checkboxCentre(tv)))

        // Not on the card's text, nor on another paragraph.
        let offset = tv.renderer.stringOffset(try cardPos(tv) + 2)
        let titleStart = try caret(tv, offset)
        XCTAssertNil(tv.cardMenu(at: CGPoint(x: titleStart.minX + 20, y: titleStart.midY)))
        XCTAssertNil(tv.cardMenu(at: CGPoint(x: 40, y: 30)))

        // The active card's button row.
        tv.dispatch(tv.state.tr.setSelection(TextSelection.create(tv.state.doc, try cardPos(tv) + 4)))
        let first = try XCTUnwrap(tv.chromeControlFrame("New Card"))
        XCTAssertNotNil(tv.cardMenu(at: CGPoint(x: first.midX, y: first.midY)))
    }

    /// The menu's items run the card's commands.
    func testCardMenuItemsRunTheCardsCommands() throws {
        let tv = try textView()
        caretInLastParagraph(tv)
        let point = try checkboxCentre(tv)
        XCTAssertTrue(tv.performCardMenuItem("New Card", at: point))
        XCTAssertEqual(CheckCard.positions(tv.state.doc).count, 2, "a second card")
        XCTAssertTrue(tv.performCardMenuItem("Delete", at: try checkboxCentre(tv)))
        XCTAssertEqual(CheckCard.positions(tv.state.doc).count, 1)
        XCTAssertFalse(tv.performCardMenuItem("Delete", at: CGPoint(x: 40, y: 30)), "not on a card")
    }

    // MARK: Tick and hover

    /// Ticking runs the tick animation (box spring, strike-through sweep), which then settles.
    func testTickAnimationRunsThenSettles() throws {
        let tv = try textView()
        tv.animatesChecks = true
        let offset = tv.renderer.stringOffset(try cardPos(tv) + 2)
        XCTAssertTrue(tv.tapMarker(at: try checkboxCentre(tv)))
        let tick = try XCTUnwrap(tv.checkAnimation(atString: offset), "ticking")
        XCTAssertLessThan(tick.strike, 1)
        XCTAssertLessThan(tick.scale, 1)
        tv.advanceCheckAnimations(by: 1)
        XCTAssertNil(tv.checkAnimation(atString: offset), "settled")
    }

    /// A tick animates once: later updates (a selection change, an unrelated edit) neither
    /// restart it while it runs nor start it again once it has settled.
    func testTickDoesNotRestartOnLaterUpdates() throws {
        let tv = try textView()
        tv.animatesChecks = true
        let offset = tv.renderer.stringOffset(try cardPos(tv) + 2)
        XCTAssertTrue(tv.tapMarker(at: try checkboxCentre(tv)))
        tv.advanceCheckAnimations(by: 0.3)
        let running = try XCTUnwrap(tv.checkAnimation(atString: offset))
        XCTAssertEqual(running.strike, 1, accuracy: 0.001, "the strike has swept in")
        tv.dispatch(tv.state.tr.setSelection(TextSelection.atStart(tv.state.doc)))
        XCTAssertEqual(tv.checkAnimation(atString: offset)?.strike ?? 0, 1, accuracy: 0.001, "not restarted by a selection change")
        tv.advanceCheckAnimations(by: 1)
        XCTAssertNil(tv.checkAnimation(atString: offset))
        caretInLastParagraph(tv)
        XCTAssertNil(tv.checkAnimation(atString: offset), "not started again by a selection change")
        tv.dispatch(try tv.state.tr.insertText("!", tv.state.selection.from))
        XCTAssertNil(tv.checkAnimation(atString: offset), "nor by an edit elsewhere")
    }

    /// An iPad pointer over a card lights its border, and over the checkbox the checkbox too.
    func testPointerHoverLightsCardAndCheckbox() throws {
        let tv = try textView()
        let pos = try cardPos(tv)
        let offset = tv.renderer.stringOffset(pos + 2)
        XCTAssertEqual(tv.chromeHoverLevel(at: pos), 0)
        tv.pointerMoved(to: try checkboxCentre(tv))
        XCTAssertEqual(tv.chromeHoverLevel(at: pos), 1)
        XCTAssertEqual(tv.markerHoverLevel(atString: offset), 1)
        let frame = try XCTUnwrap(tv.chromeFrame(at: pos))
        tv.pointerMoved(to: CGPoint(x: frame.maxX - 20, y: frame.midY))
        XCTAssertEqual(tv.chromeHoverLevel(at: pos), 1)
        XCTAssertEqual(tv.markerHoverLevel(atString: offset), 0)
        tv.pointerMoved(to: nil)
        XCTAssertEqual(tv.chromeHoverLevel(at: pos), 0)
        let hover = tv.gestureRecognizers?.contains { $0 is UIHoverGestureRecognizer } ?? false
        XCTAssertTrue(hover, "a hover recognizer follows the pointer")
    }
}
#endif
