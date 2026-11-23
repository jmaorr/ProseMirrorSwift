#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMTextKit
@testable import PMExampleSetup

/// A node-selected leaf block (a rule, an image, a file card) draws no text highlight: the
/// highlight would only show as a band around or behind the block, which shows its selection
/// itself (or through the app's chrome).
@MainActor
final class NodeSelectionHighlightTests: XCTestCase {
    /// BasicStyle, but the rule is an attachment 200 × 60 (as an app draws an image block).
    private struct AttachedRuleStyle: DocStyle {
        var base = BasicStyle()
        func paragraph(_ textblock: Node, ancestors: [Node], marker: BlockMarker?) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
            base.paragraph(textblock, ancestors: ancestors, marker: marker)
        }
        func inline(_ marks: [Mark], base attrs: [NSAttributedString.Key: Any], textblock: Node, ancestors: [Node]) -> [NSAttributedString.Key: Any] {
            base.inline(marks, base: attrs, textblock: textblock, ancestors: ancestors)
        }
        func leafBlock(_ node: Node, ancestors: [Node]) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
            let attachment = NSTextAttachment()
            attachment.bounds = CGRect(x: 0, y: 0, width: 200, height: 60)
            attachment.image = NSImage(size: NSSize(width: 200, height: 60))
            return ([.attachment: attachment, .font: base.bodyFont], nil)
        }
        func inlineLeaf(_ node: Node, base attrs: [NSAttributedString.Key: Any]) -> NSAttributedString { base.inlineLeaf(node, base: attrs) }
        func marker(for child: Node, in parent: Node, index: Int) -> BlockMarker? { base.marker(for: child, in: parent, index: index) }
    }

    /// The text view's selection highlight: AppKit draws it as line views in its selection view.
    private func highlightLines(_ view: NSView) -> [NSView] {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        return all(view).filter { String(describing: type(of: $0)).contains("SelectionLineView") && !$0.isHidden && $0.frame.width > 0 }
    }

    private func hosted(selecting select: (Node) -> Selection) throws -> HostedTextView {
        let doc = try TestDocs.doc([J.p("Above"), J.node("horizontal_rule"), J.p("Below")])
        let host = HostedTextView(doc, style: AttachedRuleStyle())
        host.window.orderFrontRegardless()
        host.window.makeKey()
        host.window.makeFirstResponder(host.view)
        host.view.dispatch(host.state.tr.setSelection(select(host.state.doc)))
        host.settle()
        return host
    }

    func testNodeSelectedLeafBlockHasNoTextHighlight() throws {
        let host = try hosted { NodeSelection.create($0, 7) }
        XCTAssertTrue(host.state.selection is NodeSelection)
        XCTAssertEqual(highlightLines(host.view).count, 0)
        XCTAssertTrue(host.view.selectsLeafBlock)
        XCTAssertNil(host.view.caretRect)
        // Copy still takes the rule (the editor's selection, not AppKit's empty range).
        XCTAssertEqual(host.state.selection.content().content.firstChild?.type.name, "horizontal_rule")
    }

    func testTextSelectionsStillHighlight() throws {
        let host = try hosted { TextSelection.create($0, 1, 6) }
        XCTAssertGreaterThan(highlightLines(host.view).count, 0)
        XCTAssertFalse(host.view.selectsLeafBlock)
    }
}
#endif

#if os(macOS)
/// An overhanging view that sets no cursor of its own (NSView's cursorUpdate passes it up the
/// responder chain, back to the text view) mustn't send the two asking each other forever.
@MainActor
final class OverhangingCursorTests: XCTestCase {
    func testOverhangingViewWithoutACursorDoesNotRecurse() throws {
        let host = HostedTextView(try TestDocs.paragraphs(["One", "Two"]))
        let plain = NSView(frame: NSRect(x: 20, y: 5, width: 100, height: 40))
        host.view.addSubview(plain)
        host.view.overhangingViews.add(plain)
        let point = plain.convert(CGPoint(x: 50, y: 20), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                     windowNumber: host.window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 0, pressure: 0))
        host.view.cursorUpdate(with: event)  // a stack overflow before
        host.view.mouseMoved(with: event)
    }
}
#endif
