#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMHistory
@testable import PMTextKit
import PMExampleSetup

/// Restyling, appearance, focus dimming, custom carets and checkbox ticks in the macOS text view.
@MainActor
final class TextViewThemingTests: XCTestCase {
    private func view(_ paragraphs: [String], style: DocStyle = BasicStyle()) throws -> ProseTextView {
        let doc = try TestDocs.paragraphs(paragraphs)
        let v = ProseTextView(state: TestDocs.state(doc), style: style)
        v.animatesChrome = false
        return v
    }

    private func checklistView(checked: Bool) throws -> ProseTextView {
        let doc = try ChecklistFixture.doc([("Buy milk", checked)])
        let state = EditorState.create(EditorStateConfig(doc: doc, plugins: exampleSetup(schema: ChecklistFixture.schema)))
        let v = ProseTextView(state: state, style: ChecklistFixture.Style())
        v.undoCommand = undo
        return v
    }

    /// The decoration on the `index`th paragraph of the view's text.
    private func decoration(_ v: ProseTextView, atBlock index: Int) -> BlockDecoration? {
        let span = v.renderer.spans[index]
        return v.textStorage!.attribute(.pmBlock, at: span.strStart, effectiveRange: nil) as? BlockDecoration
    }

    private func font(_ v: ProseTextView, at offset: Int = 0) -> NSFont {
        v.textStorage!.attribute(.font, at: offset, effectiveRange: nil) as! NSFont
    }

    // MARK: Decorations

    func testDecorationDefaults() {
        let d = BlockDecoration()
        XCTAssertEqual(d.quoteBarColor, .tertiaryLabelColor)
        XCTAssertEqual(d.quoteBarWidth, 3)
        XCTAssertEqual(d.ruleColor, .separatorColor)
        XCTAssertNil(d.checkFill)
        XCTAssertEqual(d.checkMark, .white)
        XCTAssertEqual(d.checkStroke, .tertiaryLabelColor)
        XCTAssertNil(d.checkRadius)
        XCTAssertEqual(d.backgroundRadius, 0)
        XCTAssertNil(d.strikeProgress)
    }

    func testDecorationsDifferingOnlyInColourAreUnequal() {
        let a = BlockDecoration(), b = BlockDecoration()
        b.quoteBarColor = .red
        XCTAssertNotEqual(a, b)
        let c = BlockDecoration()
        c.checkRadius = 2
        XCTAssertNotEqual(a, c)
    }

    func testLabelMarker() {
        XCTAssertNotEqual(BlockMarker.label("##"), .label("#"))
    }

    // MARK: Restyling

    func testSetStyleRestylesInPlace() throws {
        let v = try view(["Hello"])
        XCTAssertEqual(font(v).pointSize, 14)
        v.setStyle(BasicStyle(fontSize: 20))
        XCTAssertEqual(font(v).pointSize, 20)
        XCTAssertEqual(v.state.doc.textContent, "Hello")
        XCTAssertEqual(v.textStorage!.string, "Hello\n")
    }

    func testSetStyleWaitsForComposition() throws {
        let v = try view(["Hello"])
        v.dispatch(v.state.tr.setSelection(TextSelection.atEnd(v.state.doc)))
        v.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        v.setStyle(BasicStyle(fontSize: 20))
        XCTAssertTrue(v.hasMarkedText())
        XCTAssertEqual(font(v).pointSize, 14, "restyled under the marked text")
        v.unmarkText()
        XCTAssertEqual(font(v).pointSize, 20)
        XCTAssertEqual(v.state.doc.textContent, "Helloか")
    }

    /// BasicStyle's colours are dynamic: switching appearance needs no re-render.
    func testAppearanceFlipNeedsNoRerender() throws {
        let doc = try TestDocs.doc([J.code("let x = 1")])
        let v = ProseTextView(state: TestDocs.state(doc), style: BasicStyle())
        func resolved(_ c: NSColor, _ name: NSAppearance.Name) -> CGFloat {
            var white: CGFloat = 0
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                white = c.usingColorSpace(.genericGray)!.whiteComponent
            }
            return white
        }
        let text = v.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor
        XCTAssertLessThan(resolved(text, .aqua), 0.3, "dark text in light mode")
        XCTAssertGreaterThan(resolved(text, .darkAqua), 0.7, "light text in dark mode")
        let box = try XCTUnwrap(BasicStyle().chrome(forTextblock: doc.child(0), ancestors: [])?.fill)
        XCTAssertNotEqual(resolved(box, .aqua), resolved(box, .darkAqua))
    }

    // MARK: Focus dimming

    func testFocusRangeFollowsSelection() throws {
        let v = try view(["One", "Two", "Three"])
        v.focusDimming = 0.38
        v.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertEqual(v.focusedBlockRange, NSRange(location: 4, length: 4))
        v.setSelectedRange(NSRange(location: 0, length: 6))
        XCTAssertEqual(v.focusedBlockRange, NSRange(location: 0, length: 8))
        XCTAssertEqual(v.focusAlpha(atString: 10), 0.38)
        XCTAssertEqual(v.focusAlpha(atString: 1), 1)
    }

    func testNoDimmingWhenOff() throws {
        let v = try view(["One", "Two"])
        XCTAssertNil(v.focusDimming)
        XCTAssertNil(v.focusedBlockRange)
        XCTAssertEqual(v.focusAlpha(atString: 5), 1)
    }

    /// Working out the focused block stays cheap on long documents.
    func testFocusRangeIsFastOnLongDocuments() throws {
        let v = try view((0..<4000).map { "Paragraph \($0)" })
        v.focusDimming = 0.38
        let start = CACurrentMediaTime()
        for i in 0..<40 {
            v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 1 + i * 97)))
        }
        XCTAssertNotNil(v.focusedBlockRange)
        XCTAssertLessThan(CACurrentMediaTime() - start, 1.0)
    }

    // MARK: Carets

    /// A custom caret is drawn by the view in `caretColor`; AppKit's insertion point is cleared.
    func testCustomCaretHidesTheSystemOne() throws {
        let v = try view(["Hi"])
        XCTAssertEqual(v.caret, .system)
        v.caret = .bar(width: 2)
        v.caretColor = .systemPink
        XCTAssertEqual(v.caretColor, .systemPink)
        XCTAssertEqual(v.insertionPointColor, .clear)
    }

    func testBlockCaretRect() throws {
        let v = try view(["Hello"])
        v.caret = .block(widthEm: 0.55)
        v.setSelectedRange(NSRange(location: 2, length: 0))
        let r = try XCTUnwrap(v.caretRect)
        let font = font(v, at: 2)
        XCTAssertEqual(r.width, 0.55 * font.pointSize, accuracy: 0.5)
        // The glyph box, not the line box: about ascender to descender, sitting on the baseline.
        XCTAssertEqual(r.height, font.ascender - font.descender, accuracy: 1)
        let line = try XCTUnwrap(v.lineRect(atString: 2))
        XCTAssertLessThan(r.height, line.height)
        XCTAssertGreaterThanOrEqual(r.minY, line.minY - 0.5)
        XCTAssertLessThanOrEqual(r.maxY, line.maxY + 0.5)
    }

    /// A bar caret is the glyph's height too, not the (taller) line box.
    func testBarCaretIsGlyphHeight() throws {
        let v = try view(["Hello"])
        v.caret = .bar(width: 2)
        v.setSelectedRange(NSRange(location: 2, length: 0))
        let r = try XCTUnwrap(v.caretRect)
        XCTAssertEqual(r.width, 2, accuracy: 0.01)
        XCTAssertLessThan(r.height, try XCTUnwrap(v.lineRect(atString: 2)).height, "glyph height, not the line box")
    }

    func testCaretHiddenWithSelection() throws {
        let v = try view(["Hello"])
        v.caret = .block(widthEm: 0.5)
        v.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertNil(v.caretRect)
    }

    func testSystemCaretHasNoCustomRect() throws {
        XCTAssertNil(try view(["Hi"]).caretRect)
    }

    // MARK: Checkboxes

    func testToggleIsDetected() throws {
        let v = try checklistView(checked: false)
        let pos = v.renderer.spans[0].pmStart
        XCTAssertTrue(v.run(ChecklistFixture.toggle(at: pos)))
        XCTAssertEqual(v.renderer.toggledChecks, [pos])
        v.dispatch(try v.state.tr.insertText("!", pos))
        XCTAssertEqual(v.renderer.toggledChecks, [])
    }

    func testCheckedItemHasFullStrike() throws {
        let v = try checklistView(checked: true)
        XCTAssertEqual(decoration(v, atBlock: 0)?.strikeProgress, 1)
        XCTAssertEqual(decoration(v, atBlock: 0)?.marker, .checkbox(checked: true))
        // The strike is drawn by the fragment, not as a text attribute.
        XCTAssertNil(v.textStorage!.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
    }

    func testUncheckedItemHasNoStrike() throws {
        let v = try checklistView(checked: false)
        XCTAssertEqual(decoration(v, atBlock: 0)?.strikeProgress, 0)
    }

    /// The tick's spring: starts small, overshoots, settles at exactly 1.
    func testCheckSpring() {
        XCTAssertEqual(ProseTextView.checkSpring(0, checking: true), 0.6, accuracy: 0.001)
        XCTAssertGreaterThan((1...9).map { ProseTextView.checkSpring(CGFloat($0) / 10, checking: true) }.max()!, 1.04)
        XCTAssertEqual(ProseTextView.checkSpring(1, checking: true), 1)
        XCTAssertLessThan(ProseTextView.checkSpring(0.05, checking: false), 1)
    }

    func testTickAnimationRunsThenSettles() throws {
        let v = try checklistView(checked: false)
        let pos = v.renderer.spans[0].pmStart
        v.animatesChecks = true
        _ = v.run(ChecklistFixture.toggle(at: pos))
        let start = v.renderer.spans[0].strStart
        XCTAssertLessThan(v.checkAnimation(atString: start)?.strike ?? 1, 1)
        v.advanceCheckAnimations(by: 1)
        XCTAssertNil(v.checkAnimation(atString: start))
    }

    /// A finished tick doesn't play again on later updates: a selection-only change (the
    /// renderer keeps the last flips while the document is unchanged) or an edit elsewhere.
    func testTickDoesNotRestartOnLaterUpdates() throws {
        let v = try checklistView(checked: false)
        let pos = v.renderer.spans[0].pmStart
        v.animatesChecks = true
        _ = v.run(ChecklistFixture.toggle(at: pos))
        let start = v.renderer.spans[0].strStart
        XCTAssertNotNil(v.checkAnimation(atString: start))
        v.advanceCheckAnimations(by: 1)
        XCTAssertNil(v.checkAnimation(atString: start))
        v.dispatch(v.state.tr.setSelection(TextSelection.atStart(v.state.doc)))
        XCTAssertNil(v.checkAnimation(atString: start), "a selection change restarted the tick")
        v.dispatch(v.state.tr.setSelection(TextSelection.atEnd(v.state.doc)))
        XCTAssertNil(v.checkAnimation(atString: start), "a second selection change restarted the tick")
        v.dispatch(try v.state.tr.insertText("!", v.state.doc.content.size - 3))
        XCTAssertNil(v.checkAnimation(atString: start), "an edit restarted the tick")
        // The next tick still animates.
        _ = v.run(ChecklistFixture.toggle(at: pos))
        XCTAssertNotNil(v.checkAnimation(atString: start), "a later tick animates")
        v.advanceCheckAnimations(by: 1)
        // (That second toggle unticked it.) Undoing it plays the reverse flip, a tick, once; a
        // selection change after doesn't replay it.
        XCTAssertTrue(v.run(undo))
        XCTAssertEqual(v.checkAnimation(atString: start)?.strike, 0, "the undone untick animates as a tick, from no strike")
        v.advanceCheckAnimations(by: 1)
        XCTAssertNil(v.checkAnimation(atString: start))
        v.dispatch(v.state.tr.setSelection(TextSelection.atStart(v.state.doc)))
        XCTAssertNil(v.checkAnimation(atString: start), "a selection change after the undo replayed the untick")
    }
}
#endif
