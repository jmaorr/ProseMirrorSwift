#if os(iOS)
import XCTest
import UIKit
import PMModel
import PMState
@testable import PMTextKit
import PMExampleSetup

/// VoiceOver and the accessibility settings in the iOS text view: image descriptions, the
/// editor's custom actions for the selection, and Reduce Motion on checkbox ticks.
@MainActor
final class UIKitAccessibilityTests: XCTestCase {
    private var hosts: [HostedTextView] = []

    override func tearDown() {
        reduceMotionOverride = nil
        for host in hosts { host.window.isHidden = true }
        hosts = []
        super.tearDown()
    }

    /// A heading, a checkbox item and "Later", in the test style, with "Mark done" / "Mark not
    /// done" offered while the caret is in the item.
    private func taskView() throws -> ProseTextView {
        let doc = try InputTestSchema.doc([J.h(1, "Plan the garden"), InputTestSchema.taskList([("Water the ferns", false)]), J.p("Later")])
        let host = inputHost(doc, style: InputTestStyle(), caretAtEnd: false)
        hosts.append(host)
        let v = host.view
        v.accessibilityActionsProvider = { state in
            let rpos = state.selection.fromPos
            guard let depth = (0...rpos.depth).reversed().first(where: { rpos.node($0).type.name == "task_item" }) else { return [] }
            let checked = rpos.node(depth).attrs["checked"]?.boolValue == true
            return [EditorAccessibilityAction(name: checked ? "Mark not done" : "Mark done",
                                              command: InputTestSchema.toggleChecked(at: rpos.pos))]
        }
        return v
    }

    /// Position before the task item (inside the list after the heading).
    private func itemPos(_ v: ProseTextView) -> Int { v.state.doc.child(0).nodeSize + 1 }

    private func actionNames(_ tv: ProseTextView) -> [String] { (tv.accessibilityCustomActions ?? []).map(\.name) }

    private func perform(_ name: String, _ tv: ProseTextView) throws {
        let action = try XCTUnwrap((tv.accessibilityCustomActions ?? []).first { $0.name == name }, "the \(name) action")
        _ = action.actionHandler?(action)
    }

    /// An image with no alt text is described by its node name; with alt text, by that text.
    func testImageAccessibilityLabel() throws {
        let image: (String?) -> JSONValue = { alt in
            J.node("image", ["src": "https://example.com/none.png", "alt": alt.map { .string($0) } ?? .null])
        }
        let doc = try TestDocs.doc([J.p([J.text("Beds "), image(nil), J.text(" and "), image("Raised beds in spring")])])
        let host = HostedTextView(doc)
        hosts.append(host)
        var labels: [String?] = []
        host.view.textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: host.view.textStorage.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { labels.append(attachment.image?.accessibilityLabel) }
        }
        XCTAssertEqual(labels.count, 2)
        XCTAssertEqual(labels, ["image", "Raised beds in spring"])
    }

    /// With the caret in a checkbox item the text view offers "Mark done"; running it ticks the
    /// item and the offer turns into "Mark not done"; outside an item there is neither.
    func testCustomActionTogglesTheItem() throws {
        let tv = try taskView()
        tv.animatesChecks = false
        let pos = itemPos(tv)
        tv.dispatch(tv.state.tr.setSelection(TextSelection.create(tv.state.doc, pos + 3)))
        XCTAssertEqual(actionNames(tv).filter { $0.hasPrefix("Mark") }, ["Mark done"])

        try perform("Mark done", tv)
        XCTAssertEqual(tv.state.doc.nodeAt(pos)?.attrs["checked"]?.boolValue, true, "ticked")
        XCTAssertEqual(actionNames(tv).filter { $0.hasPrefix("Mark") }, ["Mark not done"])

        try perform("Mark not done", tv)
        XCTAssertEqual(tv.state.doc.nodeAt(pos)?.attrs["checked"]?.boolValue, false, "unticked")

        tv.dispatch(tv.state.tr.setSelection(TextSelection.atStart(tv.state.doc)))
        XCTAssertTrue(actionNames(tv).filter { $0.hasPrefix("Mark") }.isEmpty, "not in an item")
    }

    /// Reduce Motion turns the tick animation off: the box is simply ticked.
    func testReduceMotionSkipsTickAnimation() throws {
        let tv = try taskView()
        tv.animatesChecks = true
        let pos = itemPos(tv)
        let offset = tv.renderer.stringOffset(pos + 2)
        tv.dispatch(tv.state.tr.setSelection(TextSelection.create(tv.state.doc, pos + 3)))

        reduceMotionOverride = true
        try perform("Mark done", tv)
        XCTAssertNil(tv.checkAnimation(atString: offset), "no animation with Reduce Motion")

        reduceMotionOverride = false
        try perform("Mark not done", tv)
        XCTAssertNotNil(tv.checkAnimation(atString: offset), "animates without it")
    }
}
#endif
