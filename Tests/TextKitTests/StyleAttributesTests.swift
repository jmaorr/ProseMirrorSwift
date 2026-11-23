#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMTextKit
import PMExampleSetup

/// What a style's marks and headings come out as in the text storage, through the renderer.
@MainActor
final class StyleAttributesTests: XCTestCase {
    private func storage(_ blocks: [JSONValue], style: BasicStyle = BasicStyle()) throws -> NSTextStorage {
        let view = ProseTextView(state: TestDocs.state(try TestDocs.doc(blocks)), style: style)
        return view.textStorage!
    }

    private func font(_ s: NSTextStorage, at offset: Int) -> NSFont { s.attribute(.font, at: offset, effectiveRange: nil) as! NSFont }

    /// strong and em resolve to bold and italic faces of the body font, together too; code is
    /// monospaced on a tint; a link is coloured, underlined and carries its address.
    func testInlineMarksResolveFaces() throws {
        let s = try storage([J.p([J.text("b", [J.mark("strong")]), J.text("i", [J.mark("em")]),
                                  J.text("x", [J.mark("strong"), J.mark("em")]), J.text("c", [J.mark("code")]),
                                  J.text("l", [J.mark("link", ["href": "https://example.com"])]), J.text("p")])])
        let traits = { (i: Int) in self.font(s, at: i).fontDescriptor.symbolicTraits }
        XCTAssertTrue(traits(0).contains(.bold))
        XCTAssertFalse(traits(0).contains(.italic))
        XCTAssertTrue(traits(1).contains(.italic) || font(s, at: 1).matrix[2] != 0, font(s, at: 1).description)
        XCTAssertTrue(traits(2).contains(.bold))
        XCTAssertTrue(traits(2).contains(.italic) || font(s, at: 2).matrix[2] != 0, font(s, at: 2).description)
        XCTAssertTrue(traits(3).contains(.monoSpace), font(s, at: 3).description)
        XCTAssertNotNil(s.attribute(.backgroundColor, at: 3, effectiveRange: nil))
        XCTAssertEqual(s.attribute(.underlineStyle, at: 4, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(s.attribute(.pmToolTip, at: 4, effectiveRange: nil) as? String, "https://example.com")
        XCTAssertEqual(s.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor, .linkColor)
        XCTAssertFalse(traits(5).contains(.bold))
        XCTAssertNil(s.attribute(.backgroundColor, at: 5, effectiveRange: nil))
    }

    /// Headings step down in size from level 1 and scale with the style's font size.
    func testHeadingsScaleWithTheFontSize() throws {
        let blocks = (1...6).map { J.h($0, "H\($0)") } + [J.p("Body")]
        let s = try storage(blocks)
        let sizes = (0..<7).map { font(s, at: $0 * 3).pointSize }
        XCTAssertEqual(sizes.last, 14)
        for i in 1..<6 { XCTAssertGreaterThanOrEqual(sizes[i - 1], sizes[i], "level \(i) vs \(i + 1)") }
        XCTAssertGreaterThan(sizes[0], sizes[6] * 1.5)
        let big = try storage(blocks, style: BasicStyle(fontSize: 20))
        XCTAssertEqual(font(big, at: 0).pointSize, (20 * 1.9).rounded())
        XCTAssertEqual(font(big, at: 18).pointSize, 20)
    }
}
#endif
