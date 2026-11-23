#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMCommands
import PMHistory
@testable import PMTextKit
import PMExampleSetup

/// What a slash menu's Image and File items do in these tests: the app shows its picker and
/// inserts at the position given (where the `/` was). Without a handler the item isn't offered.
@MainActor
final class SlashMenuHooks {
    var pickImage: ((_ pos: Int) -> Void)?
    var pickFile: ((_ pos: Int) -> Void)?
}

/// A slash command menu for BasicSchema, built on PMTextKit's SuggestionTrigger: `/` at the
/// start of a textblock or after a space, not in code.
@MainActor
enum SlashMenuItems {
    static func trigger(schema: Schema, hooks: SlashMenuHooks? = nil) -> SuggestionTrigger {
        SuggestionTrigger(character: "/", isAllowed: { !$0.parent.type.spec.code }) { _ in items(schema: schema, hooks: hooks) }
    }

    static func items(schema: Schema, hooks: SlashMenuHooks?) -> [SuggestionItem] {
        typealias Item = SuggestionItem
        let heading = schema.nodes["heading"]!
        func level(_ n: Int) -> Command { setBlockType(heading, Attrs([("level", .number(Double(n)))])) }
        var items: [Item] = [
            Item(id: "heading1", title: "Heading 1", icon: .text("H1"), keywords: ["h1", "title"], command: level(1)),
            Item(id: "heading2", title: "Heading 2", icon: .text("H2"), keywords: ["h2", "subtitle"], command: level(2)),
            Item(id: "heading3", title: "Heading 3", icon: .text("H3"), keywords: ["h3"], command: level(3)),
            Item(id: "bulletList", title: "Bullet List", icon: .symbol("list.bullet"), keywords: ["ul"],
                 command: wrapInList(schema.nodes["bullet_list"]!)),
            Item(id: "orderedList", title: "Numbered List", icon: .symbol("list.number"), keywords: ["ol", "ordered"],
                 command: wrapInList(schema.nodes["ordered_list"]!)),
            Item(id: "blockquote", title: "Quote", icon: .symbol("text.quote"), command: wrapIn(schema.nodes["blockquote"]!)),
            Item(id: "codeBlock", title: "Code Block", icon: .symbol("chevron.left.forwardslash.chevron.right"),
                 command: setBlockType(schema.nodes["code_block"]!)),
            Item(id: "table", title: "Table", icon: .symbol("tablecells"), command: insertTable(schema: schema)),
        ]
        if let hooks {
            if hooks.pickImage != nil {
                items.append(Item(id: "image", title: "Image", icon: .symbol("photo"), keywords: ["picture", "photo"],
                                  command: hook { hooks.pickImage }))
            }
            if hooks.pickFile != nil {
                items.append(Item(id: "file", title: "File", icon: .symbol("paperclip"), keywords: ["attachment"],
                                  command: hook { hooks.pickFile }))
            }
        }
        items.append(Item(id: "horizontalRule", title: "Divider", icon: .symbol("minus"), keywords: ["hr", "rule", "line"],
                          command: insertNode(schema.nodes["horizontal_rule"]!)))
        return items
    }

    /// An item that hands the caret position to the app (after the `/query` is removed).
    private static func hook(_ handler: @escaping () -> ((Int) -> Void)?) -> Command {
        { state, dispatch, _ in
            guard let pick = handler() else { return false }
            guard dispatch != nil else { return true }
            let pos = state.selection.from
            // After the menu's change is applied (a run loop turn, not the main queue: the tests
            // already run on it).
            RunLoop.main.perform { pick(pos) }
            return true
        }
    }
}

/// The slash command menu, driven the way AppKit drives the text view: typed text through
/// insertText, keys through keyDown.
@MainActor
final class SlashMenuTests: XCTestCase {
    private var windows: [NSWindow] = []
    private let none = NSRange(location: NSNotFound, length: 0)

    override func tearDown() {
        for w in windows { w.close() }
        windows = []
        super.tearDown()
    }

    /// A document with the given blocks (an empty paragraph by default), the caret at its end.
    private func makeView(_ blocks: [JSONValue]? = nil, hooks: SlashMenuHooks? = nil) throws -> ProseTextView {
        let schema = TestDocs.schema
        let doc = try TestDocs.doc(blocks ?? [J.p("")])
        let state = EditorState.create(EditorStateConfig(doc: doc, selection: Selection.atEnd(doc), plugins: exampleSetup(schema: schema)))
        let view = ProseTextView(state: state, style: BasicStyle())
        view.animatesChrome = false
        view.undoCommand = undo
        view.separateUndoStep = closeHistory
        view.suggestionTriggers = [SlashMenuItems.trigger(schema: schema, hooks: hooks)]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        windows.append(window)
        if let tlm = view.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        return view
    }

    private func type(_ v: ProseTextView, _ s: String) {
        for ch in s { v.insertText(String(ch), replacementRange: none) }
    }

    private enum Key: UInt16 {
        case enter = 36, tab = 48, escape = 53, backspace = 51, down = 125, up = 126, left = 123
        var chars: String {
            switch self {
            case .enter: return "\r"
            case .tab: return "\t"
            case .escape: return "\u{1b}"
            case .backspace: return "\u{7f}"
            case .down: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
            case .up: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case .left: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            }
        }
    }

    private func press(_ v: ProseTextView, _ key: Key, _ mods: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: v.window?.windowNumber ?? 0,
                                 context: nil, characters: key.chars, charactersIgnoringModifiers: key.chars, isARepeat: false, keyCode: key.rawValue)!
        v.keyDown(with: e)
    }

    private func menu(_ v: ProseTextView) -> SuggestionController? { v.activeSuggestion }
    private func titles(_ v: ProseTextView) -> [String] { menu(v)?.items.map(\.title) ?? [] }

    // MARK: Opening

    func testSlashOpensInAnEmptyParagraphWithEveryCommand() throws {
        let v = try makeView()
        XCTAssertNil(menu(v))
        type(v, "/")
        XCTAssertEqual(menu(v)?.query, "")
        XCTAssertEqual(menu(v)?.selectedIndex, 0)
        XCTAssertEqual(titles(v), ["Heading 1", "Heading 2", "Heading 3", "Bullet List", "Numbered List", "Quote", "Code Block",
                                   "Table", "Divider"])
        XCTAssertTrue(menu(v)!.menu.isVisible, "the menu is placed (its panel orders in once the window is on screen)")
    }

    func testSlashAfterASpaceOpensButNotMidWord() throws {
        let v = try makeView([J.p("")])
        type(v, "and/")
        XCTAssertNil(menu(v), "a slash inside a word is just a slash")
        type(v, "or /")
        XCTAssertNotNil(menu(v), "after a space it opens")
        XCTAssertEqual(v.state.doc.textContent, "and/or /")
    }

    func testMovingTheCaretNextToASlashDoesNotOpen() throws {
        let v = try makeView([J.p("see /usr")])
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 7)))
        XCTAssertNil(menu(v), "only a typed slash opens the menu")
    }

    func testNotInsideCode() throws {
        let v = try makeView([J.code("cd ")])
        type(v, "/")
        XCTAssertNil(menu(v))
    }

    // MARK: Filtering

    func testTypingFiltersCaseInsensitively() throws {
        let v = try makeView()
        type(v, "/HEA")
        XCTAssertEqual(menu(v)?.query, "HEA")
        XCTAssertEqual(titles(v), ["Heading 1", "Heading 2", "Heading 3"])
        type(v, "ding2")
        XCTAssertEqual(titles(v), ["Heading 2"], "matches the id too")
        press(v, .backspace)
        type(v, "s")
        XCTAssertEqual(titles(v), [])
        press(v, .backspace)
        press(v, .backspace)
        press(v, .backspace)
        XCTAssertEqual(titles(v), ["Heading 1", "Heading 2", "Heading 3"])
    }

    func testBetterMatchesComeFirst() throws {
        let v = try makeView(hooks: { let h = SlashMenuHooks(); h.pickFile = { _ in }; return h }())
        type(v, "/li")
        // Title words starting "li" (Bullet List, Numbered List) before a keyword (Divider's "line").
        XCTAssertEqual(titles(v), ["Bullet List", "Numbered List", "Divider"])
        press(v, .backspace)
        press(v, .backspace)
        type(v, "ta")
        // Not File ("attachment") or Divider ("horizontalRule"): inside a keyword or id isn't a match.
        XCTAssertEqual(titles(v), ["Table"])
        press(v, .backspace)
        press(v, .backspace)
        type(v, "li")
        type(v, "s")
        XCTAssertEqual(titles(v), ["Bullet List", "Numbered List"])
        XCTAssertEqual(menu(v)?.selectedIndex, 0)
    }

    func testNoResultsStaysOpenAndReturnFallsThrough() throws {
        let v = try makeView()
        type(v, "/zzz")
        XCTAssertNotNil(menu(v))
        XCTAssertEqual(titles(v), [])
        press(v, .enter)
        XCTAssertNil(menu(v), "Return with nothing to choose closes the menu")
        XCTAssertEqual(v.state.doc.childCount, 2, "and makes its new line as usual")
        XCTAssertEqual(v.state.doc.firstChild?.textContent, "/zzz")
    }

    func testItemsThatCannotRunHereAreHidden() throws {
        // A list item's first child must stay a paragraph: it can't become a heading or a code block.
        let v = try makeView([J.ul([""])])
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 3)))
        type(v, "/")
        XCTAssertNotNil(menu(v))
        XCTAssertFalse(titles(v).contains("Heading 1"))
        XCTAssertFalse(titles(v).contains("Code Block"))
        XCTAssertTrue(titles(v).contains("Divider"))
    }

    // MARK: Choosing

    func testArrowAndReturnRunTheCommandAndRemoveTheQuery() throws {
        let v = try makeView()
        type(v, "/head")
        press(v, .down)
        XCTAssertEqual(menu(v)?.selectedIndex, 1)
        press(v, .down)
        press(v, .up)
        XCTAssertEqual(menu(v)?.selectedIndex, 1)
        press(v, .enter)
        XCTAssertNil(menu(v))
        let block = v.state.doc.firstChild!
        XCTAssertEqual(block.type.name, "heading")
        XCTAssertEqual(block.attrs["level"]?.intValue, 2)
        XCTAssertEqual(block.textContent, "", "the /query is gone")
        XCTAssertEqual(v.state.doc.childCount, 1, "Return didn't also split the block")
        // Choosing is its own undo step: undo gives the typed query back.
        XCTAssertTrue(v.run(undo))
        XCTAssertEqual(v.state.doc.firstChild?.type.name, "paragraph")
        XCTAssertEqual(v.state.doc.firstChild?.textContent, "/head")
        XCTAssertNil(menu(v), "undo doesn't reopen the menu")
    }

    func testArrowsWrapAround() throws {
        let v = try makeView()
        type(v, "/")
        press(v, .up)
        XCTAssertEqual(menu(v)?.selectedIndex, menu(v)!.items.count - 1)
        press(v, .down)
        XCTAssertEqual(menu(v)?.selectedIndex, 0)
    }

    func testTabChoosesAfterText() throws {
        let v = try makeView([J.p("Intro")])
        type(v, " /quo")
        press(v, .tab)
        XCTAssertNil(menu(v))
        XCTAssertEqual(v.state.doc.firstChild?.type.name, "blockquote")
        XCTAssertEqual(v.state.doc.textContent, "Intro ")
    }

    func testTable() throws {
        let v = try makeView()
        type(v, "/table")
        press(v, .enter)
        XCTAssertEqual(v.state.doc.firstChild?.type.name, "table")
        XCTAssertEqual(v.state.doc.firstChild?.childCount, 3)
        XCTAssertEqual(v.state.doc.firstChild?.firstChild?.childCount, 3)
        XCTAssertEqual(v.state.selection.fromPos.parent.textContent, "")
        XCTAssertFalse(v.state.doc.textContent.contains("/"))
    }

    func testClickingARowChoosesIt() throws {
        let v = try makeView()
        type(v, "/")
        let list = menu(v)!.menu.list
        let index = titles(v).firstIndex(of: "Divider")!
        menu(v)!.select(index)
        let row = list.rowRect(index)
        let p = list.convert(CGPoint(x: row.midX, y: row.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: list.window?.windowNumber ?? 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { list.mouseDown(with: e) } else { list.mouseUp(with: e) }
        }
        XCTAssertNil(menu(v))
        XCTAssertEqual(v.state.doc.firstChild?.type.name, "horizontal_rule")
        XCTAssertFalse(v.state.doc.textContent.contains("/"))
    }

    // MARK: Closing

    func testEscapeClosesAndKeepsTheText() throws {
        let v = try makeView()
        type(v, "/hea")
        press(v, .escape)
        XCTAssertNil(menu(v))
        XCTAssertEqual(v.state.doc.textContent, "/hea")
        type(v, "d")
        XCTAssertNil(menu(v), "it stays closed for this slash")
        XCTAssertEqual(v.state.doc.firstChild?.type.name, "paragraph")
    }

    func testBackspacePastTheSlashCloses() throws {
        let v = try makeView()
        type(v, "/h")
        press(v, .backspace)
        XCTAssertEqual(menu(v)?.query, "")
        press(v, .backspace)
        XCTAssertNil(menu(v))
        XCTAssertEqual(v.state.doc.textContent, "")
    }

    func testSpaceOrCaretLeavingCloses() throws {
        let v = try makeView([J.p("Hello")])
        type(v, " /bul")
        type(v, " ")
        XCTAssertNil(menu(v), "a space ends the query")

        let w = try makeView([J.p("Hello")])
        type(w, " /bul")
        press(w, .left)
        XCTAssertNotNil(menu(w), "still inside /bul")
        XCTAssertEqual(menu(w)?.query, "bu")
        w.dispatch(w.state.tr.setSelection(TextSelection.create(w.state.doc, 1)))
        XCTAssertNil(menu(w))
    }

    func testLosingFocusCloses() throws {
        let v = try makeView()
        type(v, "/")
        XCTAssertNotNil(menu(v))
        v.window?.makeFirstResponder(nil)
        XCTAssertNil(menu(v))
    }

    // MARK: App hooks

    func testImageAndFileOnlyWithAHandler() throws {
        let hooks = SlashMenuHooks()
        let v = try makeView(hooks: hooks)
        type(v, "/")
        XCTAssertFalse(titles(v).contains("Image"))
        press(v, .escape)

        var picked: [String] = []
        hooks.pickImage = { picked.append("image \($0)") }
        hooks.pickFile = { picked.append("file \($0)") }
        let w = try makeView([J.p("See")], hooks: hooks)
        type(w, " /")
        XCTAssertEqual(Array(titles(w)[8...9]), ["Image", "File"], "in the trigger's order, before Divider")
        type(w, "ima")
        press(w, .enter)
        XCTAssertEqual(w.state.doc.textContent, "See ")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(picked, ["image 5"], "the app is asked to insert where the slash was")
    }

    // MARK: Placement

    func testPlacementFlipsAboveAndStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 256, height: 300)
        var above: Bool?
        // Room below: under the line, icons lined up under the slash.
        let below = SuggestionMenu.place(size, line: CGRect(x: 100, y: 600, width: 8, height: 20), screen: screen, above: &above)
        XCTAssertEqual(above, false)
        XCTAssertEqual(below.maxY, 596)
        XCTAssertEqual(below.minX, 88)
        // Near the bottom: above the line.
        above = nil
        let flipped = SuggestionMenu.place(size, line: CGRect(x: 100, y: 120, width: 8, height: 20), screen: screen, above: &above)
        XCTAssertEqual(above, true)
        XCTAssertEqual(flipped.minY, 144)
        // Near the right edge: pulled back onto the screen.
        above = nil
        let right = SuggestionMenu.place(size, line: CGRect(x: 980, y: 600, width: 8, height: 20), screen: screen, above: &above)
        XCTAssertEqual(right.maxX, 996)
        // Once above, a shorter list stays above rather than jumping.
        above = true
        let shorter = SuggestionMenu.place(CGSize(width: 256, height: 48), line: CGRect(x: 100, y: 120, width: 8, height: 20), screen: screen, above: &above)
        XCTAssertEqual(above, true)
        XCTAssertEqual(shorter.minY, 144)
    }
}
#endif
