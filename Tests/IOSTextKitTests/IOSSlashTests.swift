#if os(iOS)
import XCTest
import UIKit
import PMModel
import PMState
import PMCommands
import PMTextKit
import PMExampleSetup

/// A slash menu on iOS: a `SuggestionTrigger` for "/" with test items for BasicSchema's blocks,
/// read through the view's `SuggestionState` (what an app shows as a list above the keyboard).
@MainActor
final class IOSSlashTests: XCTestCase {
    private var hosts: [HostedTextView] = []
    /// What the Image item's hook got (the caret position), once the app sets one.
    private var pickImage: ((Int) -> Void)?

    override func tearDown() {
        for host in hosts { host.window.isHidden = true }
        hosts = []
        pickImage = nil
        super.tearDown()
    }

    /// The items: blocks in BasicSchema, then Image only while the app handles it.
    private func items(_ state: EditorState) -> [SuggestionItem] {
        let schema = state.schema
        let heading = schema.nodes["heading"]!
        var items: [SuggestionItem] = (1...3).map { level in
            SuggestionItem(id: "heading\(level)", title: "Heading \(level)", icon: .text("H\(level)"), keywords: ["h\(level)"],
                           command: setBlockType(heading, Attrs([("level", .number(Double(level)))])))
        }
        items += [
            SuggestionItem(id: "bulletList", title: "Bullet List", keywords: ["ul"], command: wrapInList(schema.nodes["bullet_list"]!)),
            SuggestionItem(id: "orderedList", title: "Numbered List", keywords: ["ol"], command: wrapInList(schema.nodes["ordered_list"]!)),
            SuggestionItem(id: "quote", title: "Quote", keywords: ["blockquote"], command: wrapIn(schema.nodes["blockquote"]!)),
            SuggestionItem(id: "codeBlock", title: "Code Block", command: setBlockType(schema.nodes["code_block"]!)),
            SuggestionItem(id: "divider", title: "Divider", keywords: ["hr"], command: insertNode(schema.nodes["horizontal_rule"]!)),
        ]
        if let pick = pickImage {
            items.append(SuggestionItem(id: "image", title: "Image") { state, dispatch, _ in
                guard let dispatch else { return true }
                let at = state.selection.from
                DispatchQueue.main.async { pick(at) }
                dispatch(state.tr)
                return true
            })
        }
        return items
    }

    /// A focused view with a title and the caret in an empty paragraph below it.
    private func makeView() throws -> ProseTextView {
        let host = inputHost(try TestDocs.doc([J.p("")]))
        hosts.append(host)
        let v = host.view
        v.suggestionTriggers = [SuggestionTrigger(character: "/", isAllowed: { !$0.parent.type.spec.code }) { [weak self] state in
            self?.items(state) ?? []
        }]
        v.typeKeys("Garden plan\n")
        return v
    }

    /// The paragraph the caret is in.
    private func caretBlock(_ v: ProseTextView) -> Node { v.state.selection.headPos.parent }

    func testSlashActivatesSuggestions() throws {
        let v = try makeView()
        let state = v.suggestionState
        XCTAssertFalse(state.isActive)
        v.typeKeys("/")
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.highlighted, 0)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.items.map(\.title),
                       ["Heading 1", "Heading 2", "Heading 3", "Bullet List", "Numbered List", "Quote", "Code Block", "Divider"])
        XCTAssertEqual(state.emptyText, "No results")
    }

    func testFilterNarrowsItems() throws {
        let v = try makeView()
        v.typeKeys("/quo")
        XCTAssertTrue(v.suggestionState.isActive)
        XCTAssertEqual(v.suggestionState.query, "quo")
        XCTAssertEqual(v.suggestionState.items.first?.title, "Quote")
        v.typeKeys(" ")
        XCTAssertFalse(v.suggestionState.isActive, "a space closes it")
        XCTAssertTrue(v.suggestionState.items.isEmpty)
    }

    /// Choosing (no SwiftUI involved) runs the command and removes the typed "/query".
    func testChooseRunsCommandAndRemovesQuery() throws {
        let v = try makeView()
        v.typeKeys("/h1")
        let index = try XCTUnwrap(v.suggestionState.items.firstIndex { $0.id == "heading1" })
        v.suggestionState.choose(index)
        XCTAssertFalse(v.suggestionState.isActive)
        let block = caretBlock(v)
        XCTAssertEqual(block.type.name, "heading")
        XCTAssertEqual(block.attrs["level"]?.intValue, 1)
        XCTAssertEqual(block.textContent, "", "the /query is gone")
        XCTAssertFalse(v.state.doc.textContent.contains("/"))
        XCTAssertFalse(v.textStorage.string.contains("/"), "and from the view")
        // One undo gives the typed query back.
        v.undoManager?.undo()
        XCTAssertEqual(caretBlock(v).textContent, "/h1")
    }

    /// An item that inserts a node: the divider goes in where the query was.
    func testChooseDivider() throws {
        let v = try makeView()
        v.typeKeys("/div")
        let index = try XCTUnwrap(v.suggestionState.items.firstIndex { $0.id == "divider" })
        v.suggestionState.choose(index)
        XCTAssertFalse(v.suggestionState.isActive)
        XCTAssertFalse(v.state.doc.textContent.contains("/div"))
        XCTAssertTrue(v.blockTypes.contains("horizontal_rule"), v.blockTypes.description)
    }

    func testKeyboardHideDismissesSuggestions() throws {
        let v = try makeView()
        v.typeKeys("/he")
        XCTAssertTrue(v.suggestionState.isActive)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        XCTAssertFalse(v.suggestionState.isActive)
        XCTAssertEqual(caretBlock(v).textContent, "/he", "the text stays")
        // Typing on doesn't reopen it; a new "/" does.
        v.typeKeys("a")
        XCTAssertFalse(v.suggestionState.isActive)
        v.typeKeys(" /")
        XCTAssertTrue(v.suggestionState.isActive)
    }

    func testDismissKeepsTheText() throws {
        let v = try makeView()
        v.typeKeys("/quo")
        v.suggestionState.dismiss()
        XCTAssertFalse(v.suggestionState.isActive)
        XCTAssertEqual(caretBlock(v).textContent, "/quo")
    }

    /// Not in code: `isAllowed` keeps the trigger shut in a code block.
    func testNotInsideCode() throws {
        let v = try makeView()
        XCTAssertTrue(v.run(setBlockType(v.state.schema.nodes["code_block"]!)))
        v.typeKeys("/")
        XCTAssertFalse(v.suggestionState.isActive)
    }

    /// Hardware keys go to the open menu before the keymaps: ↑/↓ move `highlighted` (wrapping),
    /// Return chooses (without also splitting the block), Esc dismisses.
    func testKeysMoveChooseAndDismiss() throws {
        let v = try makeView()
        v.typeKeys("/head")
        XCTAssertEqual(v.suggestionState.items.prefix(3).map(\.id), ["heading1", "heading2", "heading3"])
        XCTAssertTrue(v.handleKey(KeyEvent(key: "ArrowDown", keyCode: 40)))
        XCTAssertEqual(v.suggestionState.highlighted, 1)
        XCTAssertTrue(v.handleKey(KeyEvent(key: "ArrowDown", keyCode: 40)))
        XCTAssertTrue(v.handleKey(KeyEvent(key: "ArrowUp", keyCode: 38)))
        XCTAssertEqual(v.suggestionState.highlighted, 1)
        let blocks = v.state.doc.childCount
        // The software keyboard's Return takes the same path as the hardware key.
        v.insertText("\n")
        XCTAssertFalse(v.suggestionState.isActive)
        XCTAssertEqual(caretBlock(v).type.name, "heading")
        XCTAssertEqual(caretBlock(v).attrs["level"]?.intValue, 2)
        XCTAssertEqual(caretBlock(v).textContent, "")
        XCTAssertEqual(v.state.doc.childCount, blocks, "Return didn't also split the block")

        v.typeKeys("/")
        XCTAssertTrue(v.handleKey(KeyEvent(key: "ArrowUp", keyCode: 38)))
        XCTAssertEqual(v.suggestionState.highlighted, v.suggestionState.items.count - 1, "wraps around")
        XCTAssertTrue(v.handleKey(KeyEvent(key: "Escape", keyCode: 27)))
        XCTAssertFalse(v.suggestionState.isActive)
        // Closed: the keymaps have it (exampleSetup's Escape selects the parent node).
        XCTAssertTrue(v.handleKey(KeyEvent(key: "Escape", keyCode: 27)))
        XCTAssertTrue(v.state.selection is NodeSelection, "Escape reached the keymap")
        XCTAssertEqual((v.state.selection as? NodeSelection)?.node.textContent, "/", "the paragraph, with its text")
    }

    /// Setting `highlighted` (a tap-and-hold, or the app's own keys) selects in the controller.
    func testSettingHighlightedSelects() throws {
        let v = try makeView()
        v.typeKeys("/")
        v.suggestionState.highlighted = 2
        v.insertText("\n")
        XCTAssertEqual(caretBlock(v).attrs["level"]?.intValue, 3)
    }

    /// An item the app adds (Image) appears once its hook is set; choosing it hands the caret
    /// position to the hook, with the "/query" already gone.
    func testImageItemCallsTheAppHook() throws {
        let v = try makeView()
        v.typeKeys("/ima")
        XCTAssertFalse(v.suggestionState.items.contains { $0.id == "image" })
        v.suggestionState.dismiss()

        var picked: Int?
        pickImage = { picked = $0 }
        v.typeKeys(" /ima")
        let index = try XCTUnwrap(v.suggestionState.items.firstIndex { $0.id == "image" })
        v.suggestionState.choose(index)
        let done = expectation(description: "hook called")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(picked, v.state.selection.from)
        XCTAssertEqual(caretBlock(v).textContent, "/ima ", "the last /query is gone; the earlier, dismissed one stays")
    }
}
#endif
