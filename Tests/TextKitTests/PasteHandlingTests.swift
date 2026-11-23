#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
@testable import PMTextKit
import PMExampleSetup

/// The text view's own clipboard handling, without an app's paste parser: plain text, the
/// `onPaste` hook, images to `onIncomingFiles`, the view's own slices, and the origin
/// (`PasteOrigin`) it reports for a copy, a cut and a drag.
@MainActor
final class PasteHandlingTests: XCTestCase {
    private var boards: [NSPasteboard] = []

    override func tearDown() {
        for b in boards { b.releaseGlobally() }
        boards = []
        super.tearDown()
    }

    private func board() -> NSPasteboard {
        let b = NSPasteboard(name: NSPasteboard.Name("prosemirror-swift-tests-\(UUID().uuidString)"))
        boards.append(b)
        return b
    }

    /// A view on `blocks` (one paragraph of `text` by default), the caret at the end.
    private func view(_ text: String = "", blocks: [JSONValue]? = nil) throws -> ProseTextView {
        let doc = try TestDocs.doc(blocks ?? [J.p(text)])
        let state = EditorState.create(EditorStateConfig(doc: doc, selection: Selection.atEnd(doc), plugins: exampleSetup(schema: TestDocs.schema)))
        let v = ProseTextView(state: state, style: BasicStyle())
        v.pasteboard = board()
        return v
    }

    private func outline(_ doc: Node) -> [String] {
        var out: [String] = []
        doc.forEach { node, _, _ in out.append("\(node.type.name):\(node.textContent)") }
        return out
    }

    private func marks(_ doc: Node, of text: String) -> [String] {
        var found: [String] = []
        doc.descendants { node, _, _, _ in
            if node.isText, node.text == text { found = node.marks.map(\.type.name) }
            return found.isEmpty
        }
        return found
    }

    // MARK: Text from other apps

    /// Plain text is one paragraph per line.
    func testPlainTextStaysPlain() throws {
        let v = try view()
        v.pasteboard.clearContents()
        v.pasteboard.setString("first line\nsecond line", forType: .string)
        v.paste(nil)
        XCTAssertEqual(outline(v.state.doc), ["paragraph:first line", "paragraph:second line"])
    }

    /// One line goes into the paragraph at the caret.
    func testOneLinePastesInline() throws {
        let v = try view("Note: ")
        v.pasteboard.clearContents()
        v.pasteboard.setString("a line", forType: .string)
        v.paste(nil)
        XCTAssertEqual(outline(v.state.doc), ["paragraph:Note: a line"])
    }

    /// `onPaste` sees the pasteboard first and can take the paste (an app's HTML parser);
    /// Paste and Match Style stays plain text and skips it.
    func testOnPasteGoesFirstAndPlainVariantSkipsIt() throws {
        let v = try view("Note: ")
        let strong = TestDocs.schema.marks["strong"]!
        var asked = 0
        v.onPaste = { [weak v] board in
            asked += 1
            guard let v, let html = board.string(forType: .html), html.contains("<b>") else { return false }
            guard let mark = try? strong.create(), let tr = try? v.state.tr.replaceSelectionWith(TestDocs.schema.text("bold", [mark]), inheritMarks: false) else { return false }
            v.dispatch(tr)
            return true
        }
        v.pasteboard.clearContents()
        v.pasteboard.declareTypes([.html, .string], owner: nil)
        v.pasteboard.setString("<p><b>bold</b></p>", forType: .html)
        v.pasteboard.setString("bold", forType: .string)
        v.paste(nil)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(outline(v.state.doc), ["paragraph:Note: bold"])
        XCTAssertEqual(marks(v.state.doc, of: "bold"), ["strong"])
        v.pasteAsPlainText(nil)
        XCTAssertEqual(asked, 1, "Paste and Match Style doesn't ask")
        XCTAssertEqual(outline(v.state.doc), ["paragraph:Note: boldbold"])

        // Declined: the view's own plain-text paste.
        v.pasteboard.clearContents()
        v.pasteboard.setString(" plain", forType: .string)
        v.paste(nil)
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(outline(v.state.doc), ["paragraph:Note: boldbold plain"])
    }

    /// A copied image (TIFF and the image's URL, no plain text, as Safari's Copy Image) goes to
    /// the app as an incoming file at the caret, not as a link.
    func testCopiedImageGoesToIncomingFiles() throws {
        let v = try view("Photo: ")
        var received: [(files: [ProseTextView.IncomingFile], pos: Int)] = []
        v.onIncomingFiles = { files, pos in received.append((files, pos)); return true }
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        v.pasteboard.clearContents()
        v.pasteboard.declareTypes([.tiff, .URL], owner: nil)
        v.pasteboard.setData(try XCTUnwrap(image.tiffRepresentation), forType: .tiff)
        v.pasteboard.setString("https://example.com/photo.png", forType: .URL)
        v.paste(nil)
        XCTAssertEqual(received.count, 1, "the image went to incoming files")
        XCTAssertEqual(received.first?.pos, 8)
        XCTAssertEqual(received.first?.files.first?.mimeType, "image/png")
        XCTAssertEqual(received.first?.files.first?.isImage, true)
        XCTAssertEqual(outline(v.state.doc), ["paragraph:Photo: "])
    }

    // MARK: The view's own content

    /// Copy writes the slice and its plain text; paste puts back the exact blocks and marks.
    func testCopyAndPasteKeepBlocksAndMarks() throws {
        let v = try view(blocks: [J.ul(["one", "two"]), J.p([J.text("bold", [J.mark("strong")])]), J.p("")])
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 0, v.state.doc.content.size - 2)))
        v.copy(nil)
        XCTAssertEqual(v.pasteboard.string(forType: .string), "one\n\ntwo\n\nbold")
        XCTAssertNotNil(v.pasteboard.string(forType: ProseTextView.sliceType))
        v.dispatch(v.state.tr.setSelection(Selection.atEnd(v.state.doc)))
        v.paste(nil)
        let names = outline(v.state.doc).map { $0.split(separator: ":").first.map(String.init) ?? "" }
        XCTAssertEqual(names.filter { $0 == "bullet_list" }.count, 2, "\(outline(v.state.doc))")
        XCTAssertEqual(v.state.doc.textContent, "onetwoboldonetwobold")
        var strongRuns = 0
        v.state.doc.descendants { node, _, _, _ in
            if node.isText, node.marks.contains(where: { $0.type.name == "strong" }) { strongRuns += 1 }
            return true
        }
        XCTAssertEqual(strongRuns, 2)
    }

    /// `clipboardText` decides the plain text a copy writes; `transformPasted` rewrites a slice
    /// before it goes in.
    func testClipboardTextAndTransformPasted() throws {
        let v = try view("Hello world")
        v.clipboardText = { slice in "<" + slice.content.textBetween(0, slice.content.size) + ">" }
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 1, 6)))
        v.copy(nil)
        XCTAssertEqual(v.pasteboard.string(forType: .string), "<Hello>")
        let schema = TestDocs.schema
        v.transformPasted = { _ in Slice(Fragment.from(schema.text("HELLO")), 0, 0) }
        v.dispatch(v.state.tr.setSelection(Selection.atEnd(v.state.doc)))
        v.paste(nil)
        XCTAssertEqual(v.state.doc.textContent, "Hello worldHELLO")
    }

    /// `adoptPasted` hears whether content is moved or copied: a cut's first paste is a move,
    /// a second paste of it a copy, a copy always a copy; a drag within the view moves, an
    /// Option-drag (move: false) copies.
    func testPasteOriginOfCopyCutAndDrag() throws {
        let v = try view(blocks: [J.p("Seeds"), J.p("")])
        var origins: [PasteOrigin] = []
        v.adoptPasted = { slice, origin in origins.append(origin); return slice }
        func selectFirst() { v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 0, v.state.doc.child(0).nodeSize))) }
        func toEnd() { v.dispatch(v.state.tr.setSelection(Selection.atEnd(v.state.doc))) }

        selectFirst()
        v.copy(nil)
        toEnd()
        v.paste(nil)
        v.paste(nil)
        XCTAssertEqual(origins, [.copy, .copy])

        origins = []
        let before = v.state.doc.childCount
        selectFirst()
        v.cut(nil)
        XCTAssertEqual(v.state.doc.childCount, before - 1, "cut removed it")
        toEnd()
        v.paste(nil)
        v.paste(nil)
        XCTAssertEqual(origins, [.move, .copy], "a cut moves once")

        origins = []
        let drag = board()
        selectFirst()
        _ = v.writeSelection(to: drag, types: [ProseTextView.sliceType])
        XCTAssertTrue(v.drop(from: drag, at: v.state.doc.content.size - 1, move: true))
        selectFirst()
        _ = v.writeSelection(to: drag, types: [ProseTextView.sliceType])
        XCTAssertTrue(v.drop(from: drag, at: v.state.doc.content.size, move: false))
        XCTAssertEqual(origins, [.move, .copy])
        // Dropping a selection onto itself does nothing.
        selectFirst()
        _ = v.writeSelection(to: drag, types: [ProseTextView.sliceType])
        XCTAssertFalse(v.drop(from: drag, at: 1, move: true))
    }

    /// A drag writes the slice and plain text, never the storage's RTF (the style's fonts and colours).
    func testDragWritesNoRTF() throws {
        let v = try view("Some text")
        XCTAssertEqual(v.writablePasteboardTypes, [.string, ProseTextView.sliceType])
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 1, 5)))
        let drag = board()
        XCTAssertTrue(v.writeSelection(to: drag, type: .rtf))
        XCTAssertNil(drag.data(forType: .rtf))
        XCTAssertEqual(drag.string(forType: .string), "Some")
    }
}
#endif
