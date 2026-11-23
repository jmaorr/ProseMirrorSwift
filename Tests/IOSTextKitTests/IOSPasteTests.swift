#if os(iOS)
import XCTest
import UIKit
import UniformTypeIdentifiers
import PMModel
import PMState
import PMCommands
@testable import PMTextKit
import PMExampleSetup

/// Copy, paste (a document's own slice, plain text, images, the app's `onPaste` hook), drop and
/// the edit menu on the iOS ProseTextView, on BasicSchema. HTML and Markdown parsing are an
/// app's (through `onPaste`); here only the view's own clipboard paths are checked.
@MainActor
final class IOSPasteTests: XCTestCase {
    private var hosts: [HostedTextView] = []
    private var boards: [UIPasteboard] = []

    override func tearDown() {
        for host in hosts { host.window.isHidden = true }
        hosts = []
        for board in boards { UIPasteboard.remove(withName: board.name) }
        boards = []
        super.tearDown()
    }

    private func board() -> UIPasteboard {
        let board = UIPasteboard.withUniqueName()
        boards.append(board)
        return board
    }

    /// A focused view on its own pasteboard, the caret at the end.
    private func view(_ blocks: JSONValue...) throws -> ProseTextView {
        let host = inputHost(try TestDocs.doc(blocks))
        hosts.append(host)
        host.view.pasteboard = board()
        return host.view
    }

    private func pngData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    // MARK: Copy

    /// Copy writes the slice (pasted back exactly in the app) and plain text for other apps: the
    /// blocks' text a blank line apart, or whatever `clipboardText` makes of the slice.
    func testCopyWritesSliceAndPlainText() throws {
        let v = try view(J.h(1, "Seed swap"), J.p("Bring tomato seeds"))
        v.selectedRange = NSRange(location: 0, length: (v.textStorage.string as NSString).length)
        v.copy(nil)
        let board = v.pasteboard
        XCTAssertEqual(board.string, "Seed swap\n\nBring tomato seeds")
        let data = try XCTUnwrap(board.data(forPasteboardType: ProseTextView.sliceType))
        let slice = try Slice.fromJSON(v.state.schema, JSONValue.parse(try XCTUnwrap(String(data: data, encoding: .utf8))))
        XCTAssertEqual((0..<slice.content.childCount).map { slice.content.child($0).type.name }, ["heading", "paragraph"])

        v.clipboardText = { slice in "\(slice.content.childCount) blocks" }
        v.copy(nil)
        XCTAssertEqual(board.string, "2 blocks")
    }

    // MARK: Paste

    /// A copied block pastes back as the block, even with HTML and text beside the slice.
    func testPasteSliceRestoresStructure() throws {
        let v = try view(J.quote([J.p("Mulch the beds")]), J.p("After"))
        v.dispatch(v.state.tr.setSelection(NodeSelection.create(v.state.doc, 0)))
        v.copy(nil)
        v.dispatch(v.state.tr.setSelection(TextSelection.atEnd(v.state.doc)))
        v.pasteboard.items[0]["public.html"] = "<p>Mulch the beds</p>"
        v.paste(nil)
        let quotes = (0..<v.state.doc.childCount).map { v.state.doc.child($0) }.filter { $0.type.name == "blockquote" }
        XCTAssertEqual(quotes.count, 2, v.blockTypes.description)
        XCTAssertEqual(quotes.last?.textContent, "Mulch the beds")
    }

    /// `onPaste` (an app's HTML or Markdown import) sees the pasteboard first; when it declines,
    /// the paste falls through to plain text.
    func testOnPasteGoesFirstAndCanDecline() throws {
        let v = try view(J.p("Shopping "))
        var asked = 0
        v.onPaste = { board in
            asked += 1
            return board.contains(pasteboardTypes: ["public.html"])
        }
        v.pasteboard.items = [["public.html": "<ul><li>Seeds</li></ul>", UTType.utf8PlainText.identifier: "Seeds"]]
        v.paste(nil)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(v.state.doc.textContent, "Shopping ", "the hook took it")
        v.pasteboard.string = "list"
        v.paste(nil)
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(v.state.doc.textContent, "Shopping list", "declined: pasted as text")
    }

    /// Without an import hook, HTML pastes as its plain text; in a code block it stays in it.
    func testPasteIntoACodeBlockStaysPlain() throws {
        let v = try view(J.code("let a = 1"))
        v.pasteboard.items = [["public.html": "<h1>Big</h1>", UTType.utf8PlainText.identifier: "Big"]]
        v.paste(nil)
        XCTAssertEqual(v.blockTypes, ["code_block"])
        XCTAssertEqual(v.state.doc.textContent, "let a = 1Big")
    }

    func testPasteImageGoesToIncomingFiles() throws {
        let v = try view(J.p("Photo:"))
        var received: [ProseTextView.IncomingFile] = []
        var at: Int?
        v.onIncomingFiles = { files, pos in received = files; at = pos; return true }
        v.pasteboard.items = [[UTType.png.identifier: pngData()]]
        XCTAssertTrue(v.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        v.paste(nil)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.mimeType, "image/png")
        XCTAssertTrue(received.first?.isImage == true)
        XCTAssertEqual(at, v.state.selection.from)
        XCTAssertEqual(v.state.doc.textContent, "Photo:")
    }

    /// Safari's Copy Image: the image's bytes plus HTML that is only the <img>. The bytes go to
    /// `onIncomingFiles`, before `onPaste` is asked.
    func testPasteCopiedImageWithImageOnlyHTMLUploadsTheBytes() throws {
        let v = try view(J.p("Photo:"))
        var received: [ProseTextView.IncomingFile] = []
        var asked = 0
        v.onIncomingFiles = { files, _ in received = files; return true }
        v.onPaste = { _ in asked += 1; return true }
        let png = pngData()
        v.pasteboard.items = [["public.html": #"<meta charset="utf-8"><img src="https://example.com/x.png" alt="a > b">"#,
                               UTType.png.identifier: png]]
        v.paste(nil)
        XCTAssertEqual(received.map(\.data), [png])
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(v.state.doc.textContent, "Photo:")
        XCTAssertEqual(v.blockTypes, ["paragraph"])
    }

    /// HTML with text beside an image is content, for `onPaste`: the bytes aren't uploaded.
    func testPasteHTMLWithTextAndImageGoesToOnPaste() throws {
        let v = try view(J.p(""))
        var received = 0, asked = 0
        v.onIncomingFiles = { _, _ in received += 1; return true }
        v.onPaste = { _ in asked += 1; return true }
        v.pasteboard.items = [["public.html": #"<p>Beans</p><img src="https://example.com/x.png">"#,
                               UTType.png.identifier: pngData()]]
        v.paste(nil)
        XCTAssertEqual(received, 0)
        XCTAssertEqual(asked, 1)
    }

    /// Copy Image with its URL (no HTML) pastes the image, not the URL.
    func testCopiedImageWithURLPastesTheImage() throws {
        let v = try view(J.p("Photo:"))
        var received = 0
        v.onIncomingFiles = { _, _ in received += 1; return true }
        v.pasteboard.items = [[UTType.png.identifier: pngData(), UTType.url.identifier: URL(string: "https://example.com/x.png")!]]
        v.paste(nil)
        XCTAssertEqual(received, 1, "the image went to incoming files")
        XCTAssertEqual(v.state.doc.textContent, "Photo:")
    }

    /// `adoptPasted` learns where pasted content comes from: a copy is a copy every time; a
    /// cut's first paste is a move and later ones copies; a drop is always a copy here.
    func testPasteOriginReachesAdoptPasted() throws {
        let v = try view(J.quote([J.p("Mulch")]), J.p(""))
        var origins: [PasteOrigin] = []
        v.adoptPasted = { slice, origin in origins.append(origin); return slice }
        v.dispatch(v.state.tr.setSelection(NodeSelection.create(v.state.doc, 0)))
        v.copy(nil)
        v.dispatch(v.state.tr.setSelection(TextSelection.atEnd(v.state.doc)))
        v.paste(nil)
        v.paste(nil)
        XCTAssertEqual(origins, [.copy, .copy])

        origins = []
        v.dispatch(v.state.tr.setSelection(NodeSelection.create(v.state.doc, 0)))
        let quotes = v.blockTypes.filter { $0 == "blockquote" }.count
        v.cut(nil)
        XCTAssertEqual(v.blockTypes.filter { $0 == "blockquote" }.count, quotes - 1, "the cut took it out")
        v.dispatch(v.state.tr.setSelection(TextSelection.atEnd(v.state.doc)))
        v.paste(nil)
        v.paste(nil)
        XCTAssertEqual(origins, [.move, .copy])

        origins = []
        let json = try XCTUnwrap(v.pasteboard.value(forPasteboardType: ProseTextView.sliceType) as? String
                                 ?? v.pasteboard.data(forPasteboardType: ProseTextView.sliceType).flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(v.drop(sliceJSON: json, text: nil, at: v.state.doc.content.size))
        XCTAssertEqual(origins, [.copy])
    }

    // MARK: Drop

    func testDropInsertsAtThePosition() throws {
        let v = try view(J.p("Plant beans"))
        // UIKit's own text drop is replaced by the view's.
        XCTAssertFalse(v.interactions.contains { $0 === v.textDropInteraction })
        XCTAssertTrue(v.interactions.contains { $0 is UIDropInteraction })
        XCTAssertTrue(v.drop(sliceJSON: nil, text: "green ", at: 7))
        XCTAssertEqual(v.state.doc.textContent, "Plant green beans")
        XCTAssertEqual(v.state.selection.from, 7)
        XCTAssertEqual(v.state.selection.to, 13, "the dropped text ends up selected")
        // The document's own content drops whole.
        let slice = Slice(Fragment.from(try v.state.schema.nodeFromJSON(J.p("Second"))), 0, 0)
        XCTAssertTrue(v.drop(sliceJSON: slice.toJSON().description, text: "Second", at: v.state.doc.content.size))
        XCTAssertEqual(v.blockTypes, ["paragraph", "paragraph"])
    }

    /// Dropped files are read from the provider's file, in order, a large one too (mapped, not
    /// copied into memory).
    func testDroppedFilesLoadFromTheirFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("Allotment survey.pdf")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 11 * 1024 * 1024)
        try handle.close()
        let pdf = NSItemProvider()
        pdf.suggestedName = "Allotment survey"
        pdf.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) { done in
            done(big, false, nil)
            return nil
        }
        let png = pngData()
        let image = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        var loaded: [ProseTextView.IncomingFile]?
        ProseTextView.loadFiles([image, pdf]) { loaded = $0 }
        let deadline = Date().addingTimeInterval(5)
        while loaded == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let files = try XCTUnwrap(loaded)
        XCTAssertEqual(files.map(\.mimeType), ["image/png", "application/pdf"])
        XCTAssertEqual(files[0].data, png)
        XCTAssertEqual(files[1].filename, "Allotment survey.pdf")
        XCTAssertEqual(files[1].data.count, 11 * 1024 * 1024)
    }

    // MARK: Edit menu

    private func titles(_ menu: UIMenu) -> [String] { menu.children.map(\.title) }

    private func flat(_ menu: UIMenu) -> [UIMenuElement] {
        menu.children.flatMap { ($0 as? UIMenu).map(\.children) ?? [$0] }
    }

    private func perform(_ element: UIMenuElement?) throws {
        let action = try XCTUnwrap(element as? UIAction)
        // UIAction has no public way to run its handler; this is what UIKit itself calls.
        action.perform(NSSelectorFromString("performWithSender:target:"), with: nil, with: nil)
    }

    /// An app's "Turn Into" submenu, as `extraMenuItems` would give it.
    private func turnIntoMenu(_ v: ProseTextView) -> UIMenu {
        let schema = v.state.schema
        let current = v.state.selection.fromPos.parent
        func item(_ title: String, _ type: NodeType, _ attrs: Attrs?) -> UIAction {
            let on = current.type === type && (attrs == nil || current.attrs["level"] == attrs?["level"])
            return UIAction(title: title, state: on ? .on : .off) { [weak v] _ in _ = v?.run(setBlockType(type, attrs)) }
        }
        let heading = schema.nodes["heading"]!
        return UIMenu(title: "Turn Into", children: [
            item("Paragraph", schema.nodes["paragraph"]!, nil),
            item("Heading 1", heading, Attrs([("level", .number(1))])),
            item("Heading 2", heading, Attrs([("level", .number(2))])),
        ])
    }

    func testEditMenuContainsFormattingItems() throws {
        let v = try view(J.p("Plant beans"))
        var linkAsked = 0
        v.onEditLink = { linkAsked += 1 }
        v.extraMenuItems = { [weak self, weak v] _ in
            guard let self, let v else { return [] }
            return [self.turnIntoMenu(v)]
        }
        v.selectedRange = NSRange(location: 6, length: 5)
        let suggested = [UIAction(title: "Copy") { _ in }]
        let menu = try XCTUnwrap(v.textView(v, editMenuForTextIn: v.selectedRange, suggestedActions: suggested))
        let all = menu.children.flatMap { ($0 as? UIMenu).map(titles) ?? [$0.title] }
        XCTAssertEqual(all.first, "Copy", "the system's actions come first")
        XCTAssertEqual(Array(all.dropFirst()), ["Bold", "Italic", "Link…", "Turn Into"])

        let items = flat(menu)
        try perform(items.first { $0.title == "Bold" })
        XCTAssertEqual(v.state.doc.firstChild!.lastChild!.marks.map(\.type.name), ["strong"])
        try perform(items.first { $0.title == "Italic" })
        XCTAssertEqual(Set(v.state.doc.firstChild!.lastChild!.marks.map(\.type.name)), ["strong", "em"])
        try perform(items.first { $0.title == "Link…" })
        XCTAssertEqual(linkAsked, 1)

        let turnInto = try XCTUnwrap(items.first { $0.title == "Turn Into" } as? UIMenu)
        XCTAssertEqual(titles(turnInto), ["Paragraph", "Heading 1", "Heading 2"])
        XCTAssertEqual((turnInto.children[0] as? UIAction)?.state, .on, "the current block is checked")
        try perform(turnInto.children[2])
        XCTAssertEqual(v.state.doc.firstChild?.type.name, "heading")
        XCTAssertEqual(v.state.doc.firstChild?.attrs["level"]?.intValue, 2)
    }

    func testEditMenuWithACaretHasNoMarkItems() throws {
        let v = try view(J.p("Plant beans"))
        let none = try XCTUnwrap(v.textView(v, editMenuForTextIn: v.selectedRange, suggestedActions: []))
        XCTAssertTrue(none.children.isEmpty, "no link handler, no app items: nothing to add")
        v.onEditLink = {}
        let menu = try XCTUnwrap(v.textView(v, editMenuForTextIn: v.selectedRange, suggestedActions: []))
        let all = menu.children.flatMap { ($0 as? UIMenu).map(titles) ?? [$0.title] }
        XCTAssertFalse(all.contains("Bold"))
        XCTAssertFalse(all.contains("Italic"))
        XCTAssertTrue(all.contains("Link…"))
        XCTAssertFalse(v.canPerformAction(#selector(UIResponderStandardEditActions.toggleBoldface(_:)), withSender: nil))
    }
}
#endif
