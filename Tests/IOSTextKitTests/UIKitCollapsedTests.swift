#if os(iOS)
import XCTest
import UIKit
import PMModel
import PMState
import PMTextKit
import PMExampleSetup

/// Collapsing in the iOS text view, through a test style: a collapsible chrome node (a block
/// quote) shows as one attachment while the caret is elsewhere and as its text once the caret is
/// in it; a collapsed run (a bare link drawn as a chip) leaves typing after it visible.
@MainActor
final class UIKitCollapsedTests: XCTestCase {
    private var hosts: [HostedTextView] = []

    override func tearDown() {
        for host in hosts { host.window.isHidden = true }
        hosts = []
        super.tearDown()
    }

    private func layout(_ view: ProseTextView) {
        let tlm = view.textLayoutManager!
        tlm.ensureLayout(for: tlm.documentRange)
        view.layoutIfNeeded()
    }

    /// "Before", then a quote at 8 (its text from 10), collapsed to one attachment while inactive.
    private func quoteView(selection: Int = 1) throws -> ProseTextView {
        var style = InputTestStyle()
        var box = ChromeBox()
        box.collapsible = true
        style.quoteBox = box
        style.collapsedQuote = {
            let attachment = NSTextAttachment()
            attachment.image = UIImage(systemName: "text.quote")
            attachment.bounds = CGRect(x: 0, y: 0, width: 300, height: 44)
            return [.attachment: attachment]
        }
        let long = String(repeating: "Check the tone, the facts and the length of the draft. ", count: 6)
        let doc = try TestDocs.doc([J.p("Before"), J.quote([J.p("Review"), J.p(long)])])
        let host = HostedTextView(doc, selection: selection, style: style)
        hosts.append(host)
        layout(host.view)
        return host.view
    }

    /// With the caret elsewhere the quote is one attachment; with the caret in it, its text.
    func testCollapsedNodeShowsOneAttachmentUntilTheCaretIsIn() throws {
        let view = try quoteView()
        XCTAssertEqual(view.textStorage.string, "Before\n\u{FFFC}\n", "one attachment stands in for the quote")
        let region = try XCTUnwrap(view.renderer.chromes.first { $0.pos == 8 })
        XCTAssertTrue(region.collapsed)

        view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, 12)))
        layout(view)
        XCTAssertTrue(view.textStorage.string.hasPrefix("Before\nReview\nCheck the tone"), view.textStorage.string)
        XCTAssertEqual(view.renderer.chromes.first { $0.pos == 8 }?.collapsed, false)
        XCTAssertEqual(view.selectedRange, NSRange(location: 9, length: 0), "the caret lands in the shown text")

        // Leaving collapses it again.
        view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, 3)))
        layout(view)
        XCTAssertEqual(view.textStorage.string, "Before\n\u{FFFC}\n")
    }

    /// "See https://example.org/beds for beds": the bare link is a chip while the caret is out of
    /// it; typing just after the chip takes the paragraph's look, not the chip's hidden characters'.
    func testTypingAfterAChipIsVisible() throws {
        var style = InputTestStyle()
        style.chips = true
        let url = "https://example.org/beds"
        let doc = try TestDocs.doc([J.p([J.text("See "), J.text(url, [J.mark("link", ["href": .string(url)])]), J.text(" for beds")]),
                                    J.p("Later")])
        let host = inputHost(doc, style: style)
        hosts.append(host)
        let tv = host.view
        XCTAssertEqual((tv.textStorage.string as NSString).character(at: 4), 0xFFFC, "a chip while the caret is in Later")
        XCTAssertEqual(tv.textStorage.length, tv.state.doc.child(0).content.size + 1 + 6, "the run's text stays 1:1")

        let chipEnd = 1 + "See ".count + url.count
        tv.dispatch(tv.state.tr.setSelection(TextSelection.create(tv.state.doc, chipEnd)))
        XCTAssertEqual((tv.textStorage.string as NSString).character(at: 4), 0xFFFC, "still a chip with the caret beside it")
        let color = tv.typingAttributes[.foregroundColor] as? UIColor
        XCTAssertNotEqual(color, .clear)
        let font = try XCTUnwrap(tv.typingAttributes[.font] as? UIFont)
        XCTAssertGreaterThan(font.pointSize, 4)

        // Inside the run it opens into its text.
        tv.dispatch(tv.state.tr.setSelection(TextSelection.create(tv.state.doc, chipEnd - 3)))
        XCTAssertEqual((tv.textStorage.string as NSString).substring(with: NSRange(location: 4, length: url.utf16.count)), url)
    }
}
#endif
