#if os(iOS)
import XCTest
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PMModel
import PMState
import PMCommands
import PMKeymap
@testable import PMTextKit
import PMExampleSetup

/// A pointer at a chosen point and state, for the view's hover recognizer action.
private final class FakeHover: UIHoverGestureRecognizer {
    var point = CGPoint.zero
    var fakeState: UIGestureRecognizer.State = .changed
    override func location(in view: UIView?) -> CGPoint { point }
    override var state: UIGestureRecognizer.State {
        get { fakeState }
        set { fakeState = newValue }
    }
}

/// A hardware key with chosen characters and modifiers, for `pressesBegan`.
private final class FakeKey: UIKey {
    var chars = "", mods: UIKeyModifierFlags = [], code: UIKeyboardHIDUsage = .keyboardB
    override var characters: String { chars }
    override var charactersIgnoringModifiers: String { chars }
    override var modifierFlags: UIKeyModifierFlags { mods }
    override var keyCode: UIKeyboardHIDUsage { code }
}

private final class FakePress: UIPress {
    let fake: FakeKey
    init(_ key: FakeKey) { fake = key; super.init() }
    override var key: UIKey? { fake }
}

/// Hardware-keyboard commands (the ⌘-hold overlay, the iPadOS menu bar) for exampleSetup's
/// bindings, and the pointer over a boxed node.
@MainActor
final class UIKitKeyCommandTests: XCTestCase {
    private var hosts: [HostedTextView] = []

    override func tearDown() {
        for host in hosts { host.window.isHidden = true }
        hosts = []
        super.tearDown()
    }

    /// exampleSetup's formatting bindings an app might list, by title. Italic is left off so a
    /// chord without a command can be tried. The Quote key is an app's own (Mod-Shift-b).
    private static let shortcuts: [ShortcutCommand] = [
        ShortcutCommand(title: "Bold", binding: "Mod-b"),
        ShortcutCommand(title: "Code", binding: "Mod-`"),
        ShortcutCommand(title: "Paragraph", binding: "Shift-Ctrl-0"),
        ShortcutCommand(title: "Heading 1", binding: "Shift-Ctrl-1"),
        ShortcutCommand(title: "Heading 2", binding: "Shift-Ctrl-2"),
        ShortcutCommand(title: "Heading 3", binding: "Shift-Ctrl-3"),
        ShortcutCommand(title: "Bullet List", binding: "Shift-Ctrl-8"),
        ShortcutCommand(title: "Numbered List", binding: "Shift-Ctrl-9"),
        ShortcutCommand(title: "Code Block", binding: "Shift-Ctrl-\\"),
        ShortcutCommand(title: "Quote", binding: "Mod-Shift-b"),
    ]

    /// "Plain words" selected (1..12), then a quote and "Later"; the app's Quote key before
    /// exampleSetup's keymaps (whose Mod-B bold alias would also take ⌘⇧B).
    private func view(width: CGFloat = 820, style: DocStyle? = nil) throws -> ProseTextView {
        let schema = TestDocs.schema
        let doc = try TestDocs.doc([J.p("Plain words"), J.quote([J.p("Water the ferns")]), J.p("Later")])
        let plugins = [keymap(["Mod-Shift-b": wrapIn(schema.nodes["blockquote"]!)])] + exampleSetup(schema: schema)
        let host = inputHost(doc, style: style, plugins: plugins, caretAtEnd: false, width: width)
        hosts.append(host)
        let v = host.view
        v.shortcutCommands = Self.shortcuts
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 1, 12)))
        return v
    }

    private func firstMarks(_ v: ProseTextView) -> [String] {
        v.state.doc.child(0).firstChild?.marks.map(\.type.name) ?? []
    }

    /// Every listed binding is a `UIKeyCommand` with a discoverability title and the right key
    /// and modifiers; every one is a real binding; and running one runs the keymap.
    func testKeyCommandsCoverTheListedBindings() throws {
        let tv = try view()
        let commands = try XCTUnwrap(tv.keyCommands).filter { $0.discoverabilityTitle != nil }
        XCTAssertEqual(commands.count, Self.shortcuts.count)
        let keymap = buildKeymap(schema: tv.state.schema)
        for entry in Self.shortcuts where entry.title != "Quote" {
            XCTAssertNotNil(keymap[entry.binding], "\(entry.binding) is bound")
        }
        XCTAssertEqual(Set(commands.map { $0.discoverabilityTitle }).count, commands.count, "titles are distinct")

        func command(_ title: String) throws -> UIKeyCommand {
            try XCTUnwrap(commands.first { $0.discoverabilityTitle == title }, title)
        }
        let bold = try command("Bold")
        XCTAssertEqual(bold.input, "b")
        XCTAssertEqual(bold.modifierFlags, .command)
        let bullets = try command("Bullet List")
        XCTAssertEqual(bullets.input, "8")
        XCTAssertEqual(bullets.modifierFlags, [.control, .shift])
        let heading = try command("Heading 2")
        XCTAssertEqual(heading.input, "2")
        XCTAssertEqual(heading.modifierFlags, [.control, .shift])

        tv.performShortcut(bold)
        XCTAssertTrue(firstMarks(tv).contains("strong"), "Bold toggled the mark: \(firstMarks(tv))")
        tv.performShortcut(heading)
        XCTAssertEqual(tv.state.doc.child(0).type.name, "heading")
        XCTAssertEqual(tv.state.doc.child(0).attrs["level"]?.intValue, 2)
        XCTAssertTrue(tv.canPerformAction(#selector(ProseTextView.performShortcut(_:)), withSender: nil))
    }

    /// The pointer over a boxed node fades its hover look in, driven by the view's hover
    /// recognizer; leaving fades it out.
    func testHoverLightsABox() throws {
        var style = InputTestStyle()
        style.quoteBox = ChromeBox()
        let tv = try view(style: style)
        let pos = tv.state.doc.child(0).nodeSize
        XCTAssertEqual(tv.state.doc.nodeAt(pos)?.type.name, "blockquote")
        let frame = try XCTUnwrap(tv.chromeFrame(at: pos))
        XCTAssertEqual(tv.chromeHoverLevel(at: pos), 0)
        let hover = FakeHover()
        hover.point = CGPoint(x: frame.midX, y: frame.midY)
        hover.fakeState = .began
        tv.pointerHovered(hover)
        XCTAssertEqual(tv.chromeHoverLevel(at: pos), 1, "the box lights under the pointer")
        hover.fakeState = .ended
        tv.pointerHovered(hover)
        XCTAssertEqual(tv.chromeHoverLevel(at: pos), 0, "and fades when it leaves")
        XCTAssertTrue(tv.gestureRecognizers?.contains { $0 is UIHoverGestureRecognizer } ?? false)
    }

    /// A press of a chord with a registered command is left to UIKit (so the command is the one
    /// path), while other keys are still handled by the press.
    func testChordHandledOnce() throws {
        let tv = try view()
        let bold = try XCTUnwrap(tv.keyCommands?.first { $0.discoverabilityTitle == "Bold" })
        let key = FakeKey()
        key.chars = "b"; key.mods = .command
        let before = tv.state.doc.toJSON().description
        tv.pressesBegan([FakePress(key)], with: nil)
        XCTAssertEqual(tv.state.doc.toJSON().description, before, "the press leaves ⌘B to its key command")
        tv.performShortcut(bold)
        XCTAssertTrue(firstMarks(tv).contains("strong"), "the command toggled once")
        // A chord with no command (⌘I is off the list) still reaches the keymap from the press.
        let i = FakeKey()
        i.chars = "i"; i.mods = .command; i.code = .keyboardI
        tv.pressesBegan([FakePress(i)], with: nil)
        XCTAssertTrue(firstMarks(tv).contains("em"), "unlisted chords still handled by the press")
    }

    /// Two deliberate presses of the same chord, 30 ms apart, both take effect.
    func testRepeatedChordBothTakeEffect() throws {
        let tv = try view()
        let bold = try XCTUnwrap(tv.keyCommands?.first { $0.discoverabilityTitle == "Bold" })
        tv.performShortcut(bold)
        XCTAssertTrue(firstMarks(tv).contains("strong"))
        Thread.sleep(forTimeInterval: 0.03)
        tv.performShortcut(bold)
        XCTAssertFalse(firstMarks(tv).contains("strong"), "the second press toggled it back")
    }

    /// Every listed binding, run through its key command, has its effect.
    func testEveryShortcutHasItsEffect() throws {
        let expected: [String: String] = [
            "Bold": "strong", "Code": "\"code\"", "Paragraph": "paragraph",
            "Heading 1": "heading", "Heading 2": "heading", "Heading 3": "heading",
            "Bullet List": "bullet_list", "Numbered List": "ordered_list", "Code Block": "code_block", "Quote": "blockquote",
        ]
        XCTAssertEqual(Set(Self.shortcuts.map(\.title)), Set(expected.keys))
        for entry in Self.shortcuts {
            let tv = try view()
            // Paragraph needs something else to turn back from.
            if entry.title == "Paragraph" { XCTAssertTrue(tv.runShortcut(binding: "Shift-Ctrl-1")) }
            let before = tv.state.doc.toJSON().description
            let command = try XCTUnwrap(tv.keyCommands?.first { $0.discoverabilityTitle == entry.title }, entry.title)
            tv.performShortcut(command)
            let after = tv.state.doc.toJSON().description
            XCTAssertNotEqual(before, after, "\(entry.title) changed the document")
            if entry.title == "Paragraph" {
                XCTAssertEqual(tv.state.doc.child(0).type.name, "paragraph")
            } else {
                XCTAssertTrue(after.contains(expected[entry.title]!), "\(entry.title): \(after)")
            }
        }
        let tv = try view()
        XCTAssertFalse(tv.runShortcut(binding: "Mod-i"), "Italic is off the list")
        XCTAssertTrue(tv.runShortcut(binding: "Mod-b"))
    }

    /// ⌘⇧B is the app's Quote key command, and it quotes the paragraph rather than bolding it
    /// (exampleSetup's `Mod-B` alias would take ⌘⇧B too). The hardware press is left to the command.
    func testCommandShiftBQuotes() throws {
        let tv = try view()
        let quote = try XCTUnwrap(tv.keyCommands?.first { $0.discoverabilityTitle == "Quote" })
        XCTAssertEqual(quote.input, "b")
        XCTAssertEqual(quote.modifierFlags, [.command, .shift])
        let key = FakeKey()
        key.chars = "b"; key.mods = [.command, .shift]; key.code = .keyboardB
        let before = tv.state.doc.toJSON().description
        tv.pressesBegan([FakePress(key)], with: nil)
        XCTAssertEqual(tv.state.doc.toJSON().description, before, "the press leaves ⌘⇧B to its key command")
        tv.performShortcut(quote)
        XCTAssertEqual(tv.state.doc.child(0).type.name, "blockquote", tv.state.doc.toJSON().description)
        XCTAssertFalse(tv.state.doc.toJSON().description.contains("strong"), "⌘⇧B did not bold")
    }

    /// Only the standard format chords take priority over the system's.
    func testOnlyBIUTakePriority() throws {
        let tv = try view()
        for command in tv.keyCommands ?? [] where command.discoverabilityTitle != nil {
            let standard = ["Bold", "Italic", "Underline"].contains(command.discoverabilityTitle!)
            XCTAssertEqual(command.wantsPriorityOverSystemBehavior, standard, command.discoverabilityTitle!)
        }
    }
}
#endif
