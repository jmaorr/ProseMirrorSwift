#if os(iOS)
import XCTest
import UIKit
import PMModel
import PMState
import PMTransform
import PMCommands
import PMTextKit
import PMExampleSetup

/// UIKit text input the way the keyboard sends it, straight to the iOS ProseTextView, which
/// sits in a window as first responder, on BasicSchema with exampleSetup's plugins.
@MainActor
final class IOSTextInputTests: XCTestCase {
    private var hosts: [HostedTextView] = []

    override func tearDown() {
        for host in hosts { host.window.isHidden = true }
        hosts = []
        super.tearDown()
    }

    private func view(_ text: String) throws -> ProseTextView {
        try view([J.p(text)])
    }

    private func view(_ blocks: [JSONValue], style: DocStyle? = nil, caretAtEnd: Bool = true) throws -> ProseTextView {
        try view(TestDocs.doc(blocks), style: style, caretAtEnd: caretAtEnd)
    }

    private func view(_ doc: Node, style: DocStyle? = nil, caretAtEnd: Bool = true) throws -> ProseTextView {
        let host = inputHost(doc, style: style, caretAtEnd: caretAtEnd)
        hosts.append(host)
        return host.view
    }

    // MARK: Typing and deleting

    func testTypingInsertsThroughUIKit() throws {
        let v = try view("Hello")
        XCTAssertTrue(v.isFirstResponder)
        v.typeKeys(" world")
        XCTAssertEqual(v.state.doc.textContent, "Hello world")
        XCTAssertEqual(v.textStorage.string, "Hello world\n")
        XCTAssertEqual(v.state.selection.from, 12)
        XCTAssertEqual(v.selectedRange, NSRange(location: 11, length: 0))
    }

    func testTypingInTheMiddleSettlesAmbiguousDiffs() throws {
        let v = try view("Hello world")
        v.selectedRange = NSRange(location: 5, length: 0)
        XCTAssertEqual(v.state.selection.from, 6)
        v.insertText("o")
        XCTAssertEqual(v.state.doc.textContent, "Helloo world")
        XCTAssertEqual(v.state.selection.from, 7)
    }

    func testDeleteBackwardInsideAParagraph() throws {
        let v = try view("Hello world")
        v.deleteBackward()
        v.deleteBackward()
        XCTAssertEqual(v.state.doc.textContent, "Hello wor")
        XCTAssertEqual(v.textStorage.string, "Hello wor\n")
        XCTAssertEqual(v.state.selection.from, 10)
    }

    func testDeleteBackwardAtParagraphStartJoins() throws {
        let v = try view([J.p("One"), J.p("Two")])
        // Start of "Two": doc(0) p "One" ends at 4, second p content starts at 6.
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 6)))
        v.deleteBackward()
        XCTAssertEqual(v.state.doc.childCount, 1)
        XCTAssertEqual(v.state.doc.textContent, "OneTwo")
        XCTAssertEqual(v.textStorage.string, "OneTwo\n")
        XCTAssertEqual(v.state.selection.from, 4)
    }

    func testDeletingASelectionAcrossParagraphs() throws {
        let v = try view([J.p("One"), J.p("Two")])
        v.selectedRange = NSRange(location: 2, length: 3)
        XCTAssertEqual(v.state.selection.from, 3)
        XCTAssertEqual(v.state.selection.to, 7)
        v.deleteBackward()
        XCTAssertEqual(v.state.doc.textContent, "Onwo")
        XCTAssertEqual(v.state.doc.childCount, 1)
    }

    /// UIKit's gate refuses an edit across paragraphs and it becomes a transaction.
    func testEditAcrossParagraphsIsATransaction() throws {
        let v = try view([J.p("One"), J.p("Two")])
        XCTAssertFalse(v.textView(v, shouldChangeTextIn: NSRange(location: 2, length: 3), replacementText: "x"))
        XCTAssertEqual(v.state.doc.textContent, "Onxwo")
        XCTAssertEqual(v.textStorage.string, "Onxwo\n")
    }

    /// What UIKit does for an edit of its own (autocorrect, a tapped suggestion, dictation):
    /// asks the gate, edits the storage, reports the change.
    func testCorrectionKeepsMarksAndUndoesAlone() throws {
        let v = try view([J.p([J.text("I saw "), J.text("teh", [J.mark("strong")])])])
        v.insertText(" ")
        let range = NSRange(location: 6, length: 3)
        XCTAssertTrue(v.textView(v, shouldChangeTextIn: range, replacementText: "the"))
        v.textStorage.replaceCharacters(in: range, with: "the")
        v.selectedRange = NSRange(location: 10, length: 0)
        v.textViewDidChange(v)
        XCTAssertEqual(v.state.doc.textContent, "I saw the ")
        let corrected = v.state.doc.firstChild!.child(1)
        XCTAssertEqual(corrected.text, "the ")
        XCTAssertEqual(corrected.marks.map(\.type.name), ["strong"])
        XCTAssertTrue(v.undoManager!.canUndo)
        v.undoManager!.undo()
        XCTAssertEqual(v.state.doc.textContent, "I saw teh ")
    }

    /// UITextInput's replace(_:withText:), which autocorrect and tapped suggestions use.
    func testReplaceWithTextIsReadBack() throws {
        let v = try view("Plant teh beans")
        let start = try XCTUnwrap(v.position(from: v.beginningOfDocument, offset: 6))
        let end = try XCTUnwrap(v.position(from: start, offset: 3))
        v.replace(try XCTUnwrap(v.textRange(from: start, to: end)), withText: "the")
        XCTAssertEqual(v.state.doc.textContent, "Plant the beans")
        XCTAssertEqual(v.textStorage.string, "Plant the beans\n")
        XCTAssertEqual(v.untrackedEdits, 0)
        // A replacement across paragraphs is a transaction.
        v.dispatch(v.state.tr.setSelection(TextSelection.atEnd(v.state.doc)))
        v.typeKeys("!")
        v.insertText("\n")
        v.typeKeys("Rows")
        let a = try XCTUnwrap(v.position(from: v.beginningOfDocument, offset: 14))
        let b = try XCTUnwrap(v.position(from: a, offset: 4))
        v.replace(try XCTUnwrap(v.textRange(from: a, to: b)), withText: "-")
        XCTAssertEqual(v.state.doc.childCount, 1)
        XCTAssertEqual(v.state.doc.textContent, "Plant the bean-ows")
    }

    /// The safety net: text UIKit changed behind the gate's back is put back from the document.
    func testUntrackedStorageEditIsUndoneFromTheDocument() throws {
        let v = try view("Kept")
        v.textStorage.replaceCharacters(in: NSRange(location: 0, length: 4), with: "Lost")
        v.textViewDidChange(v)
        XCTAssertEqual(v.untrackedEdits, 1)
        XCTAssertEqual(v.textStorage.string, "Kept\n")
        XCTAssertEqual(v.state.doc.textContent, "Kept")
    }

    // MARK: Return through the keymap

    func testReturnSplitsAListItem() throws {
        let v = try view([J.ul(["Apples"])])
        v.insertText("\n")
        v.typeKeys("Pears")
        let bullets = v.state.doc.firstChild!
        XCTAssertEqual(bullets.type.name, "bullet_list")
        XCTAssertEqual(bullets.childCount, 2)
        XCTAssertEqual(bullets.child(1).textContent, "Pears")
        XCTAssertEqual(v.textStorage.string, "Apples\nPears\n")
        // Return on the empty item after it leaves the list.
        v.insertText("\n")
        v.insertText("\n")
        XCTAssertEqual(v.state.doc.childCount, 2)
        XCTAssertEqual(v.state.doc.child(1).type.name, "paragraph")
    }

    func testReturnAfterAHeadingStartsAParagraph() throws {
        let v = try view([J.h(1, "Title")])
        v.insertText("\n")
        v.typeKeys("Body")
        XCTAssertEqual(v.blockTypes, ["heading", "paragraph"])
        XCTAssertEqual(v.state.doc.child(1).textContent, "Body")
    }

    func testNewlinesNeverLandAsCharacters() throws {
        let v = try view("Line")
        v.insertText("\n")
        XCTAssertFalse(v.state.doc.textContent.contains("\n"))
        XCTAssertEqual(v.state.doc.childCount, 2)
    }

    // MARK: Text with line breaks (dictation, text replacement, a keyboard's multi-line insert)

    /// Text that arrives with line breaks in it splits blocks where they are, as Return would,
    /// through each way UIKit hands text over; it never lands as spaces.
    func testMultiLineTextSplitsBlocks() throws {
        // insertText: at the end of a paragraph.
        var v = try view("Seeds")
        v.insertText(" to buy\nCompost\n\nHose")
        // A blank line is one break, not an empty paragraph made by a second Enter.
        XCTAssertEqual(v.blockTexts, ["Seeds to buy", "Compost", "Hose"])
        XCTAssertEqual(v.state.selection.fromPos.parent.textContent, "Hose")
        XCTAssertEqual(v.state.selection.fromPos.parentOffset, 4)
        XCTAssertEqual(v.textStorage.string, "Seeds to buy\nCompost\nHose\n")

        // The gate (dictation and the keyboard ask it before inserting), over a selection.
        v = try view("Plant the beans")
        v.selectedRange = NSRange(location: 6, length: 3)
        XCTAssertFalse(v.textView(v, shouldChangeTextIn: v.selectedRange, replacementText: "the\r\nrunner"))
        XCTAssertEqual(v.blockTexts, ["Plant the", "runner beans"])

        // replace(_:withText:), with the other paragraph separators UIKit uses.
        v = try view("Water ferns")
        let start = try XCTUnwrap(v.position(from: v.beginningOfDocument, offset: 6))
        v.replace(try XCTUnwrap(v.textRange(from: start, to: start)), withText: "the\u{2029}big\u{2028}")
        XCTAssertEqual(v.blockTexts, ["Water the", "big", "ferns"])
        XCTAssertFalse(v.state.doc.textContent.contains(" big"))
    }

    /// In a list, each line is an item (Return splits the item).
    func testMultiLineTextInAList() throws {
        let v = try view([J.ul(["Apples"])])
        v.insertText("\nPears\nPlums")
        let bullets = v.state.doc.firstChild!
        XCTAssertEqual(bullets.type.name, "bullet_list")
        XCTAssertEqual((0..<bullets.childCount).map { bullets.child($0).textContent }, ["Apples", "Pears", "Plums"])
    }

    /// A blank line in a list doesn't leave the list: the run of breaks is one Enter. In a code
    /// block the text goes in as it is.
    func testMultiLineTextWithBlankLines() throws {
        var v = try view([J.ul(["Apples"])])
        v.insertText("\nPears\n\nPlums")
        let bullets = v.state.doc.firstChild!
        XCTAssertEqual(v.state.doc.childCount, 1)
        XCTAssertEqual((0..<bullets.childCount).map { bullets.child($0).textContent }, ["Apples", "Pears", "Plums"])

        v = try view([J.code("let a = 1")])
        v.insertText("\n\n\nlet b = 2")
        XCTAssertEqual(v.state.doc.childCount, 1)
        XCTAssertEqual(v.state.doc.firstChild?.type.name, "code_block")
        XCTAssertEqual(v.state.doc.firstChild?.textContent, "let a = 1\n\n\nlet b = 2")
    }

    /// One undo takes back the whole multi-line insert.
    func testMultiLineTextUndoesAsOne() throws {
        let v = try view("Note")
        v.insertText("\nOne\nTwo")
        XCTAssertEqual(v.state.doc.childCount, 3)
        v.undoManager!.undo()
        XCTAssertEqual(v.state.doc.childCount, 1)
        XCTAssertEqual(v.state.doc.textContent, "Note")
    }

    // MARK: Return from the on-screen keyboard

    /// The on-screen keyboard's Return, as UIKit sends it: the keyboard asks the delegate first,
    /// and only calls `insertText("\n")` if that says yes.
    private func softwareReturn(_ v: ProseTextView) {
        if v.textView(v, shouldChangeTextIn: v.selectedRange, replacementText: "\n") { v.insertText("\n") }
    }

    func testSoftwareReturnAfterAHeadingStartsAParagraph() throws {
        let v = try view([J.h(1, "Garden plan")])
        softwareReturn(v)
        v.typeKeys("Body")
        XCTAssertEqual(v.blockTypes, ["heading", "paragraph"])
        XCTAssertEqual(v.blockTexts, ["Garden plan", "Body"])
        XCTAssertEqual(v.textStorage.string, "Garden plan\nBody\n")
    }

    func testSoftwareReturnSplitsAParagraph() throws {
        let v = try view("Line one")
        softwareReturn(v)
        v.typeKeys("two")
        XCTAssertEqual(v.blockTexts, ["Line one", "two"])
    }

    func testSoftwareReturnSplitsAListItem() throws {
        let v = try view([J.ul(["Apples"])])
        softwareReturn(v)
        v.typeKeys("Pears")
        let bullets = v.state.doc.firstChild!
        XCTAssertEqual(bullets.childCount, 2)
        XCTAssertEqual(bullets.child(1).textContent, "Pears")
        // Return on the empty item after it leaves the list.
        softwareReturn(v)
        softwareReturn(v)
        XCTAssertEqual(v.state.doc.childCount, 2)
        XCTAssertEqual(v.state.doc.child(1).type.name, "paragraph")
    }

    /// Return right after an autocorrection (the keyboard replaces the word, then sends Return):
    /// one new block, and the corrected word stays as corrected.
    func testSoftwareReturnAfterAutocorrect() throws {
        let v = try view("We plant dont")
        XCTAssertEqual(v.selectedRange, NSRange(location: 13, length: 0))
        let start = try XCTUnwrap(v.position(from: v.beginningOfDocument, offset: 9))
        let end = try XCTUnwrap(v.position(from: start, offset: 4))
        v.replace(try XCTUnwrap(v.textRange(from: start, to: end)), withText: "don\u{2019}t")
        XCTAssertEqual(v.state.doc.textContent, "We plant don\u{2019}t")
        softwareReturn(v)
        v.typeKeys("Beans")
        XCTAssertEqual(v.state.doc.childCount, 2, "one new block")
        XCTAssertEqual(v.state.doc.child(0).textContent, "We plant don\u{2019}t", "the correction intact")
        XCTAssertEqual(v.state.doc.child(1).textContent, "Beans")
        XCTAssertEqual(v.textStorage.string, "We plant don\u{2019}t\nBeans\n")
        XCTAssertEqual(v.untrackedEdits, 0)

        // The same through UIKit's own edit path (gate, storage edit, change report).
        let w = try view("Sow the seads")
        let range = NSRange(location: 8, length: 5)
        XCTAssertTrue(w.textView(w, shouldChangeTextIn: range, replacementText: "seeds"))
        w.textStorage.replaceCharacters(in: range, with: "seeds")
        w.selectedRange = NSRange(location: 13, length: 0)
        w.textViewDidChange(w)
        softwareReturn(w)
        XCTAssertEqual(w.state.doc.childCount, 2, "one new block")
        XCTAssertEqual(w.blockTexts, ["Sow the seeds", ""])
    }

    /// Return over a selection replaces it, as the keymap's Enter does: no space in its place.
    func testSoftwareReturnOverASelection() throws {
        let v = try view("Keep cut rest")
        v.selectedRange = NSRange(location: 4, length: 5)
        softwareReturn(v)
        XCTAssertEqual(v.blockTexts, ["Keep", "rest"])
    }

    // MARK: Input rules

    /// exampleSetup's input rules run as the keyboard types: `# ` makes a heading, `- ` a
    /// bullet list, `> ` a block quote.
    func testMarkdownShortcutsAsYouType() throws {
        let v = try view([J.p("")])
        v.typeKeys("# ")
        XCTAssertEqual(v.state.doc.firstChild!.type.name, "heading")
        v.typeKeys("Plan")
        v.insertText("\n")
        v.typeKeys("- ")
        XCTAssertEqual(v.state.doc.child(1).type.name, "bullet_list")
        v.typeKeys("Item")
        XCTAssertEqual(v.state.doc.child(1).firstChild!.firstChild!.textContent, "Item")
        v.insertText("\n")
        v.insertText("\n")
        v.typeKeys("> Quoted")
        XCTAssertEqual(v.blockTypes, ["heading", "bullet_list", "blockquote"])
        XCTAssertEqual(v.state.doc.child(2).textContent, "Quoted")
        XCTAssertEqual(v.textStorage.string, "Plan\nItem\nQuoted\n")
    }

    // MARK: Marked text

    func testMarkedTextStaysOutUntilCommitted() throws {
        let v = try view("Note ")
        v.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(v.composing)
        XCTAssertEqual(v.state.doc.textContent, "Note ")
        XCTAssertEqual(v.textStorage.string, "Note か\n")
        v.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(v.state.doc.textContent, "Note ")
        v.unmarkText()
        XCTAssertFalse(v.composing)
        XCTAssertEqual(v.state.doc.textContent, "Note かな")
        XCTAssertEqual(v.state.selection.from, 8)
        // One undo step takes the committed composition away.
        v.undoManager!.undo()
        XCTAssertEqual(v.state.doc.textContent, "Note ")
    }

    func testInsertingOverMarkedTextCommitsIt() throws {
        let v = try view("Kan")
        v.setMarkedText("じ", selectedRange: NSRange(location: 1, length: 0))
        v.insertText("字")
        XCTAssertFalse(v.composing)
        XCTAssertEqual(v.state.doc.textContent, "Kan字")
    }

    func testCommandsCommitAnOpenComposition() throws {
        let v = try view("Word ")
        v.setMarkedText("abc", selectedRange: NSRange(location: 3, length: 0))
        let heading = try XCTUnwrap(v.state.schema.nodes["heading"])
        XCTAssertTrue(v.run(setBlockType(heading, Attrs([("level", .number(1))]))))
        XCTAssertFalse(v.composing)
        XCTAssertEqual(v.state.doc.firstChild!.type.name, "heading")
        XCTAssertEqual(v.state.doc.textContent, "Word abc")
    }

    // MARK: Selection

    func testSelectionRoundTrip() throws {
        let v = try view([J.h(2, "Plan"), J.ul(["Dig", "Sow"]), J.p("Done")])
        let doc = v.state.doc
        // State → view: every text position lands on the matching string offset and back.
        var checked = 0
        for pos in 0...doc.content.size {
            let rpos = doc.resolve(pos)
            guard rpos.parent.inlineContent else { continue }
            v.dispatch(v.state.tr.setSelection(TextSelection.create(doc, pos)))
            let offset = v.selectedRange.location
            v.selectedRange = NSRange(location: 0, length: 0)
            v.selectedRange = NSRange(location: offset, length: 0)
            XCTAssertEqual(v.state.selection.from, pos, "position \(pos) via offset \(offset)")
            checked += 1
        }
        XCTAssertEqual(checked, 4 + 1 + 3 + 1 + 3 + 1 + 4 + 1)
        // A range across blocks, view → state → view.
        v.selectedRange = NSRange(location: 2, length: 8)
        let sel = v.state.selection
        XCTAssertEqual(v.state.doc.textBetween(sel.from, sel.to, blockSeparator: "|"), "an|Dig|S")
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 1)))
        v.dispatch(v.state.tr.setSelection(sel))
        XCTAssertEqual(v.selectedRange, NSRange(location: 2, length: 8))
    }

    // MARK: Undo and formatting

    func testUndoRedoThroughUIKitsUndoManager() throws {
        let v = try view("Seed")
        v.typeKeys("s")
        v.insertText("\n")
        v.typeKeys("Water")
        XCTAssertEqual(v.state.doc.childCount, 2)
        let manager = try XCTUnwrap(v.undoManager)
        XCTAssertTrue(manager.canUndo)
        while manager.canUndo { manager.undo() }
        XCTAssertEqual(v.state.doc.textContent, "Seed")
        XCTAssertEqual(v.textStorage.string, "Seed\n")
        XCTAssertTrue(manager.canRedo)
        while manager.canRedo { manager.redo() }
        XCTAssertEqual(v.state.doc.childCount, 2)
        XCTAssertEqual(v.textStorage.string, "Seeds\nWater\n")
    }

    func testToggleBoldAndItalicFromTheEditMenu() throws {
        let v = try view("Plant beans")
        v.selectedRange = NSRange(location: 6, length: 5)
        XCTAssertTrue(v.canPerformAction(#selector(UIResponder.toggleBoldface(_:)), withSender: nil))
        v.toggleBoldface(nil)
        v.toggleItalics(nil)
        let beans = v.state.doc.firstChild!.lastChild!
        XCTAssertEqual(beans.text, "beans")
        XCTAssertEqual(Set(beans.marks.map(\.type.name)), ["strong", "em"])
        // The storage shows it.
        let font = try XCTUnwrap(v.textStorage.attribute(.font, at: 7, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
        v.toggleBoldface(nil)
        XCTAssertEqual(v.state.doc.firstChild!.lastChild!.marks.map(\.type.name), ["em"])
    }

    func testBoldWithACaretAppliesToWhatIsTypedNext() throws {
        let v = try view("Plain ")
        // ⌘B with an empty selection sets a stored mark (the keymap's toggleMark).
        XCTAssertTrue(v.run(buildKeymap(schema: v.state.schema)["Mod-b"]!))
        v.typeKeys("loud")
        let loud = v.state.doc.firstChild!.lastChild!
        XCTAssertEqual(loud.text, "loud")
        XCTAssertEqual(loud.marks.map(\.type.name), ["strong"])
    }

    // MARK: Blocks

    /// A checkbox marker (a test style's `task_item`) is drawn and a tap on it runs `onMarkerClick`.
    func testCheckboxTapTogglesTheItem() throws {
        let doc = try InputTestSchema.doc([InputTestSchema.taskList([("Seeds", false)])])
        let v = try view(doc, style: InputTestStyle())
        v.onMarkerClick = { [weak v] pos in v?.run(InputTestSchema.toggleChecked(at: pos)) ?? false }
        let rect = try XCTUnwrap(v.checkboxRect(atString: 0))
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertTrue(v.tapMarker(atString: 0))
        XCTAssertEqual(v.state.doc.firstChild!.firstChild!.attrs["checked"]?.boolValue, true)
    }

    /// Typing inside a node with a chrome box (a boxed block quote) edits its paragraphs, and the
    /// box is laid out around them.
    func testTypingInABoxedNode() throws {
        var style = InputTestStyle()
        style.quoteBox = ChromeBox()
        let v = try view([J.quote([J.p("Buy"), J.p("From")])], style: style)
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 5)))
        v.typeKeys(" mulch")
        v.dispatch(v.state.tr.setSelection(TextSelection.atEnd(v.state.doc)))
        v.typeKeys(" the yard")
        let quote = v.state.doc.firstChild!
        XCTAssertEqual(quote.child(0).textContent, "Buy mulch")
        XCTAssertEqual(quote.child(1).textContent, "From the yard")
        XCTAssertNotNil(v.chromeFrame(at: 0))
    }

    /// An active boxed node shows its control buttons (with footer room for them); pressing one
    /// runs its command as its own undo step.
    func testActiveBoxShowsItsButtons() throws {
        var style = InputTestStyle()
        var box = ChromeBox()
        box.footer = 36
        style.quoteBox = box
        style.quoteControls = [
            ChromeControl(title: "Add Paragraph") { pos in
                return { state, dispatch, _ in
                    guard let quote = state.doc.nodeAt(pos), let p = state.schema.nodes["paragraph"]?.createAndFill(),
                          let tr = try? state.tr.insert(pos + quote.nodeSize - 1, p) else { return false }
                    dispatch?(tr)
                    return true
                }
            },
            ChromeControl(title: "Delete", trailing: true, destructive: true) { pos in
                return { state, dispatch, _ in
                    guard let quote = state.doc.nodeAt(pos), let tr = try? state.tr.delete(pos, pos + quote.nodeSize) else { return false }
                    dispatch?(tr)
                    return true
                }
            },
        ]
        let v = try view([J.p("Intro"), J.quote([J.p("Mulch")])], style: style, caretAtEnd: false)
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 3)))
        XCTAssertNil(v.activeChrome)
        // Into the quote ("Intro" is 0..7; quote 7, paragraph 8, text from 9).
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 11)))
        let active = try XCTUnwrap(v.activeChrome)
        XCTAssertEqual(active.pos, 7)
        XCTAssertEqual(active.progress, 1)
        XCTAssertEqual(active.buttons, ["Add Paragraph", "Delete"])
        let open = try XCTUnwrap(v.chromeFrame(at: 7))
        XCTAssertGreaterThan(open.height, 36, "footer room for the buttons")
        v.pressChromeControl("Add Paragraph")
        XCTAssertEqual(v.state.doc.child(1).childCount, 2)
        v.undoManager!.undo()
        XCTAssertEqual(v.state.doc.child(1).childCount, 1)
        XCTAssertEqual(v.state.doc.child(1).textContent, "Mulch")
    }

    func testPasteSeveralLinesMakesParagraphs() throws {
        let v = try view("Start")
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        v.pasteboard = board
        board.string = "one\ntwo"
        v.paste(nil)
        XCTAssertEqual(v.blockTexts, ["Startone", "two"])
        // Copy and paste within the app keeps the structure.
        v.selectedRange = NSRange(location: 0, length: (v.textStorage.string as NSString).length - 1)
        v.copy(nil)
        v.dispatch(v.state.tr.setSelection(TextSelection.atEnd(v.state.doc)))
        v.paste(nil)
        XCTAssertEqual(v.state.doc.childCount, 3)
    }
}
#endif
