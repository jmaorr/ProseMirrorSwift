#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMCommands
import PMKeymap
import PMTextKit
import PMHistory
import PMExampleSetup

/// AppKit text input the way macOS sends it, straight to the text view.
@MainActor
final class TextInputTests: XCTestCase {
    private func view(_ text: String) throws -> ProseTextView {
        try view(J.doc([J.p(text)]))
    }

    private func view(_ json: JSONValue, plugins: [Plugin]? = nil) throws -> ProseTextView {
        let doc = try TestDocs.doc(json)
        let view = ProseTextView(state: TestDocs.state(doc, plugins: plugins), style: BasicStyle())
        view.undoCommand = undo
        view.separateUndoStep = closeHistory
        view.dispatch(view.state.tr.setSelection(TextSelection.atEnd(view.state.doc)))
        return view
    }

    private let none = NSRange(location: NSNotFound, length: 0)

    private func texts(_ node: Node) -> [String] { (0..<node.childCount).map { node.child($0).textContent } }

    private func board() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("prosemirror-swift-tests-\(UUID().uuidString)"))
    }

    /// Accepting an inline prediction commits the whole word over the typed prefix.
    func testAcceptedPredictionReplacesTypedPrefix() throws {
        let v = try view("Nah it's alri")
        let caret = v.selectedRange().location
        v.setMarkedText("ght", selectedRange: NSRange(location: 0, length: 0), replacementRange: none)
        XCTAssertTrue(v.composing)
        v.insertText("alright", replacementRange: NSRange(location: caret - 4, length: 7))
        XCTAssertFalse(v.composing)
        XCTAssertEqual(v.state.doc.textContent, "Nah it's alright")
    }

    /// A prediction that marks text over the prefix from the start.
    func testMarkedTextReplacingTypedPrefix() throws {
        let v = try view("can I keep trying without much iss")
        let caret = v.selectedRange().location
        v.setMarkedText("issues", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: caret - 3, length: 3))
        v.insertText("issues", replacementRange: none)
        XCTAssertEqual(v.state.doc.textContent, "can I keep trying without much issues")
    }

    /// Typing through a shown prediction commits just the typed text.
    func testTypingThroughPrediction() throws {
        let v = try view("alri")
        v.setMarkedText("ght", selectedRange: NSRange(location: 0, length: 0), replacementRange: none)
        v.insertText("g", replacementRange: none)
        XCTAssertEqual(v.state.doc.textContent, "alrig")
    }

    // MARK: Native editing read back

    /// What NSTextView does for an edit of its own (autocorrect, text replacement, Writing Tools).
    private func nativeReplace(_ v: ProseTextView, _ range: NSRange, _ text: String) {
        XCTAssertTrue(v.shouldChangeText(in: range, replacementString: text), "edit refused")
        v.textStorage!.replaceCharacters(in: range, with: text)
        v.setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        v.didChangeText()
    }

    func testTypingAndDeletingInsideAParagraph() throws {
        let v = try view("Hello")
        for ch in " world" { v.insertText(String(ch), replacementRange: none) }
        XCTAssertEqual(v.state.doc.textContent, "Hello world")
        XCTAssertEqual(v.state.selection.from, 12)
        v.deleteBackward(nil)
        v.deleteBackward(nil)
        XCTAssertEqual(v.state.doc.textContent, "Hello wor")
        XCTAssertEqual(v.textStorage!.string, "Hello wor\n")
        // In the middle, where the diff alone is ambiguous ("o" next to "o").
        v.setSelectedRange(NSRange(location: 5, length: 0))
        v.insertText("o", replacementRange: none)
        XCTAssertEqual(v.state.doc.textContent, "Helloo wor")
        XCTAssertEqual(v.state.selection.from, 7)
    }

    /// A correction keeps the corrected word's formatting and is its own undo step.
    func testCorrectionKeepsMarksAndUndoesAlone() throws {
        let v = try view(J.doc([J.p([J.text("I saw "), J.text("teh", [J.mark("strong")])])]))
        v.insertText(" ", replacementRange: none)
        nativeReplace(v, NSRange(location: 6, length: 3), "the")
        XCTAssertEqual(v.state.doc.textContent, "I saw the ")
        // The space typed after the bold word is bold too, as in ProseMirror.
        let corrected = v.state.doc.firstChild!.child(1)
        XCTAssertEqual(corrected.text, "the ")
        XCTAssertEqual(corrected.marks.map(\.type.name), ["strong"])
        XCTAssertTrue(v.run(undo))
        XCTAssertEqual(v.state.doc.textContent, "I saw teh ")
    }

    /// Edits that leave the paragraph go through transactions instead.
    func testEditsAcrossParagraphsAreTransactions() throws {
        let v = try view(J.doc([J.p("One"), J.p("Two")]))
        XCTAssertFalse(v.shouldChangeText(in: NSRange(location: 2, length: 3), replacementString: "x"))
        XCTAssertEqual(v.state.doc.textContent, "Onxwo")
        XCTAssertEqual(v.state.doc.childCount, 1)
    }

    /// Typing in a nested textblock (a list item inside a quote) is the same native path.
    func testTypingInANestedBlock() throws {
        let v = try view(J.doc([J.quote([J.ul(["Buy"])]), J.p("From")]))
        // doc(0) quote(1) list(2) item(3) para(4) "Buy" ends at 7.
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 7)))
        for ch in " milk" { v.insertText(String(ch), replacementRange: none) }
        v.dispatch(v.state.tr.setSelection(TextSelection.atEnd(v.state.doc)))
        for ch in " the shop" { v.insertText(String(ch), replacementRange: none) }
        XCTAssertEqual(v.state.doc.child(0).textContent, "Buy milk")
        XCTAssertEqual(v.state.doc.child(1).textContent, "From the shop")
        XCTAssertEqual(v.textStorage!.string, "Buy milk\nFrom the shop\n")
    }

    /// Text arriving with line breaks (dictation's "new line", a text replacement) splits blocks
    /// where they are, as Return would, instead of landing as spaces. A lone newline is Return.
    func testMultiLineTextSplitsBlocks() throws {
        var v = try view("Seeds")
        v.insertText(" to buy\nCompost\r\n\nHose", replacementRange: none)
        XCTAssertEqual(texts(v.state.doc), ["Seeds to buy", "Compost", "Hose"])
        XCTAssertEqual(v.state.selection.fromPos.parent.textContent, "Hose")
        XCTAssertEqual(v.state.selection.fromPos.parentOffset, 4)

        // Over a selection, through the replacement range.
        v = try view("Plant the beans")
        v.insertText("the\u{2029}runner", replacementRange: NSRange(location: 6, length: 3))
        XCTAssertEqual(texts(v.state.doc), ["Plant the", "runner beans"])

        // A lone newline: Return.
        v = try view(J.doc([J.ul(["Apples"])]))
        v.insertText("\n", replacementRange: none)
        v.insertText("Pears\nPlums", replacementRange: none)
        let list = v.state.doc.firstChild!
        XCTAssertEqual(list.type.name, "bullet_list")
        XCTAssertEqual(texts(list), ["Apples", "Pears", "Plums"])
    }

    /// A blank line in a list is one break (it doesn't leave the list); in a code block text goes
    /// in as it is, Enter's exit-on-blank-lines untouched.
    func testMultiLineTextWithBlankLines() throws {
        var v = try view(J.doc([J.ul(["Apples"])]))
        v.insertText("\nPears\n\nPlums", replacementRange: none)
        XCTAssertEqual(v.state.doc.childCount, 1)
        XCTAssertEqual(texts(v.state.doc.firstChild!), ["Apples", "Pears", "Plums"])

        v = try view(J.doc([J.code("let a = 1")]))
        v.insertText("\n\n\nlet b = 2", replacementRange: none)
        XCTAssertEqual(v.state.doc.childCount, 1)
        XCTAssertEqual(v.state.doc.firstChild?.textContent, "let a = 1\n\n\nlet b = 2")
    }

    /// With no keymap (a bare view), a break still splits the block (splitBlock).
    func testMultiLineTextFallbacks() throws {
        let doc = try TestDocs.paragraphs(["One"])
        let v = ProseTextView(state: EditorState.create(EditorStateConfig(doc: doc)), style: BasicStyle())
        v.dispatch(v.state.tr.setSelection(TextSelection.atEnd(v.state.doc)))
        v.insertText("\nTwo", replacementRange: none)
        XCTAssertEqual(texts(v.state.doc), ["One", "Two"])
    }

    /// IME: marked text stays out of the document until it's committed.
    func testCompositionCommitsOnce() throws {
        let v = try view("Say ")
        v.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        v.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        XCTAssertEqual(v.state.doc.textContent, "Say ")
        v.insertText("日本", replacementRange: none)
        XCTAssertEqual(v.state.doc.textContent, "Say 日本")
        XCTAssertEqual(v.textStorage!.string, "Say 日本\n")
    }

    private func press(_ v: ProseTextView, _ chars: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 11) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
        XCTAssertTrue(v.performKeyEquivalent(with: e) || { v.keyDown(with: e); return true }())
    }

    /// ⌘⇧B reaches a `Shift-Mod-b` binding (installed ahead of exampleSetup, whose `Mod-B` Bold
    /// alias would otherwise take it, as in prosemirror-keymap); ⌘B still bolds, and so does ⌘B
    /// with Caps Lock (the alias's job).
    func testCommandShiftBQuotesAndCommandBBolds() throws {
        let quote = keymap(["Shift-Mod-b": wrapIn(TestDocs.schema.nodes["blockquote"]!)])
        let v = try view(J.doc([J.p("Quote me")]), plugins: [quote] + exampleSetup(schema: TestDocs.schema))
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 1, 6)))
        press(v, "B", [.command, .shift])
        XCTAssertEqual(v.state.doc.firstChild?.type.name, "blockquote", v.state.doc.toJSON().description)
        XCTAssertFalse(v.state.doc.toJSON().description.contains("strong"), "⌘⇧B did not bold")

        let b = try view("Bold me")
        b.dispatch(b.state.tr.setSelection(TextSelection.create(b.state.doc, 1, 5)))
        press(b, "b", .command)
        XCTAssertTrue(b.state.doc.toJSON().description.contains("strong"), "⌘B bolds")
        press(b, "B", [.command, .capsLock])
        XCTAssertFalse(b.state.doc.toJSON().description.contains("strong"), "⌘B with Caps Lock toggles Bold back")
    }

    /// A command run mid-composition (a toolbar button, a shortcut) commits it first.
    func testCommandCommitsComposition() throws {
        let v = try view("Hi ")
        v.setMarkedText("wor", selectedRange: NSRange(location: 3, length: 0), replacementRange: none)
        XCTAssertTrue(v.run { state, dispatch, _ in
            dispatch?(try! state.tr.insertText("!"))
            return true
        })
        XCTAssertFalse(v.composing)
        XCTAssertEqual(v.state.doc.textContent, "Hi wor!")
        XCTAssertEqual(v.textStorage!.string, "Hi wor!\n")
    }

    /// Copying blocks and pasting them back keeps them blocks (the slice, not the plain text);
    /// the plain text on the pasteboard is what `clipboardText` makes of the slice.
    func testCopyPasteKeepsBlocks() throws {
        let v = try view(J.doc([J.ul(["Item"]), J.p("")]))
        v.pasteboard = board()
        defer { v.pasteboard.releaseGlobally() }
        v.clipboardText = { slice in "- " + slice.content.textBetween(0, slice.content.size, blockSeparator: "\n") }
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 0, v.state.doc.child(0).nodeSize)))
        v.copy(nil)
        XCTAssertEqual(v.pasteboard.string(forType: .string), "- Item")
        v.dispatch(v.state.tr.setSelection(Selection.atEnd(v.state.doc)))
        v.paste(nil)
        var items = 0
        v.state.doc.descendants { node, _, _, _ in if node.type.name == "list_item" { items += 1 }; return true }
        XCTAssertEqual(items, 2)
    }

    /// Dragging out and Services get plain text and the slice, not RTF with the style's
    /// attributes; a pasted slice goes through `transformPasted`.
    func testDragWritesNoRTFAndPasteTransforms() throws {
        let v = try view(J.doc([J.p([J.text("Red", [J.mark("strong")])])]))
        let board = board()
        defer { board.releaseGlobally() }
        v.pasteboard = board
        XCTAssertFalse(v.writablePasteboardTypes.contains(.rtf))
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 1, 4)))
        board.clearContents()
        XCTAssertTrue(v.writeSelection(to: board, types: [.rtf, .string]))
        XCTAssertNil(board.data(forType: .rtf))
        XCTAssertEqual(board.string(forType: .string), "Red")
        // A transform that swaps strong for em on the way in.
        let schema = v.state.schema
        func swap(_ fragment: Fragment) -> Fragment {
            var nodes: [Node] = []
            fragment.forEach { node, _, _ in
                if node.isText {
                    let marks = node.marks.map { $0.type.name == "strong" ? try! schema.marks["em"]!.create() : $0 }
                    nodes.append(node.mark(marks))
                } else {
                    nodes.append(node.copy(swap(node.content)))
                }
            }
            return Fragment.from(nodes)
        }
        v.transformPasted = { Slice(swap($0.content), $0.openStart, $0.openEnd) }
        v.dispatch(v.state.tr.setSelection(Selection.atEnd(v.state.doc)))
        v.paste(nil)
        var marks: [String] = []
        v.state.doc.descendants { node, _, _, _ in
            if node.isText { marks.append(node.marks.map(\.type.name).joined(separator: ",")) }
            return true
        }
        XCTAssertEqual(marks, ["strong", "em"])
    }

    /// Dragging a selection within the document moves it through the doc; Option-drag copies;
    /// dropping onto the selection itself does nothing; text from elsewhere drops as text.
    func testDragTextWithinDocument() throws {
        let v = try view("one two three")
        let board = board()
        defer { board.releaseGlobally() }
        // Select "two " (positions 5..9) and drag it to the start.
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 5, 9)))
        board.clearContents()
        XCTAssertTrue(v.writeSelection(to: board, types: [.string]))
        XCTAssertTrue(v.drop(from: board, at: 1, move: true))
        XCTAssertEqual(v.state.doc.textContent, "two one three")
        XCTAssertEqual(v.state.selection.from, 1)
        XCTAssertEqual(v.state.selection.to, 5)
        XCTAssertEqual(v.textStorage!.string, "two one three\n")
        // Onto itself: nothing.
        XCTAssertFalse(v.drop(from: board, at: 3, move: true))
        XCTAssertEqual(v.state.doc.textContent, "two one three")
        // Copy to the end.
        XCTAssertTrue(v.drop(from: board, at: v.state.doc.content.size - 1, move: false))
        XCTAssertEqual(v.state.doc.textContent, "two one threetwo ")
        // Plain text from another app, two lines.
        board.clearContents()
        board.setString("a\nb", forType: .string)
        XCTAssertTrue(v.drop(from: board, at: 1, move: false))
        XCTAssertEqual(v.state.doc.childCount, 2)
        XCTAssertEqual(v.state.doc.child(0).textContent, "a")
        XCTAssertEqual(v.state.doc.child(1).textContent, "btwo one threetwo ")
    }

    /// Accepting a prediction the way macOS 26 does: the marked word is cleared, then the whole
    /// word is inserted where it was, then the composition ends.
    func testAcceptedPredictionClearedThenInserted() throws {
        let v = try view("I mean that is ")
        for ch in "ama" { v.insertText(String(ch), replacementRange: none) }
        let caret = v.selectedRange().location
        let start = caret - 3
        v.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: caret, length: 0))
        v.setMarkedText("amazing", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: start, length: 3))
        v.setMarkedText("amazing", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: start, length: 7))
        v.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: start, length: 7))
        v.insertText("amazing", replacementRange: NSRange(location: start, length: 0))
        v.unmarkText()
        XCTAssertEqual(v.state.doc.textContent, "I mean that is amazing")
        XCTAssertEqual(v.textStorage!.string, "I mean that is amazing\n")
    }
}
#endif
