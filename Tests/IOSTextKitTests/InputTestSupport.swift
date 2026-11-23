// Helpers for the iOS input, paste, key command, accessibility and suggestion tests: a focused
// text view with undo wired to the history plugin, and a test-only schema and style for what
// BasicSchema and BasicStyle don't have (checkbox items, a box around block quotes, collapsed
// quotes, link chips).
#if os(iOS)
import XCTest
import UIKit
import PMModel
import PMState
import PMTransform
import PMCommands
import PMHistory
import PMTextKit
import PMExampleSetup

/// BasicSchema plus `task_list` / `task_item` (a list of items with a `checked` attribute), for
/// checkbox markers.
enum InputTestSchema {
    static let schema: Schema = {
        let nodes = BasicSchema.nodes + [
            ("task_list", NodeSpec(content: "task_item+", group: "block")),
            ("task_item", NodeSpec(content: "paragraph block*", attrs: [("checked", AttributeSpec(default: false))], defining: true)),
        ]
        return try! Schema(SchemaSpec(nodes: nodes, marks: BasicSchema.marks))
    }()

    static func doc(_ blocks: [JSONValue]) throws -> Node { try schema.nodeFromJSON(J.doc(blocks)) }

    static func taskList(_ items: [(String, Bool)]) -> JSONValue {
        J.node("task_list", nil, items.map { text, checked in J.node("task_item", ["checked": .bool(checked)], [J.p(text)]) })
    }

    /// Flips `checked` on the task item holding position `pos`.
    static func toggleChecked(at pos: Int) -> Command {
        return { state, dispatch, _ in
            let rpos = state.doc.resolve(min(pos, state.doc.content.size))
            guard let depth = (0...rpos.depth).reversed().first(where: { rpos.node($0).type.name == "task_item" }) else { return false }
            let item = rpos.node(depth)
            let checked = item.attrs["checked"]?.boolValue == true
            guard let tr = try? state.tr.setNodeMarkup(rpos.before(depth), nil, Attrs([("checked", .bool(!checked))])) else { return false }
            dispatch?(tr)
            return true
        }
    }
}

/// BasicStyle with extras switched on per test: checkbox markers for `task_list` items, a box
/// (chrome) around block quotes that can collapse to one attachment, and link chips (a link
/// whose text is its address shown as one attachment while the caret is outside it).
struct InputTestStyle: DocStyle {
    var base = BasicStyle()
    /// A chrome box around each block quote.
    var quoteBox: ChromeBox?
    /// With `quoteBox.collapsible`: the attachment a collapsed quote shows.
    var collapsedQuote: (() -> [NSAttributedString.Key: Any])?
    /// Buttons in an active quote's footer (give `quoteBox` a `footer` for them).
    var quoteControls: [ChromeControl] = []
    /// Show bare links (text == href) as chips.
    var chips = false

    static let checkboxIndent: CGFloat = 24

    func paragraph(_ textblock: Node, ancestors: [Node], marker: BlockMarker?) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
        var (attrs, deco) = base.paragraph(textblock, ancestors: ancestors, marker: marker)
        let depth = ancestors.filter { $0.type.name == "task_list" }.count
        if depth > 0, let ps = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            let extra = CGFloat(depth) * Self.checkboxIndent
            ps.firstLineHeadIndent += extra
            ps.headIndent += extra
            attrs[.paragraphStyle] = ps
            deco?.markerRight += extra
        }
        return (attrs, deco)
    }

    func inline(_ marks: [Mark], base attrs: [NSAttributedString.Key: Any], textblock: Node, ancestors: [Node]) -> [NSAttributedString.Key: Any] {
        base.inline(marks, base: attrs, textblock: textblock, ancestors: ancestors)
    }

    func leafBlock(_ node: Node, ancestors: [Node]) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
        base.leafBlock(node, ancestors: ancestors)
    }

    func inlineLeaf(_ node: Node, base attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        base.inlineLeaf(node, base: attrs)
    }

    func marker(for child: Node, in parent: Node, index: Int) -> BlockMarker? {
        if parent.type.name == "task_list" { return .checkbox(checked: child.attrs["checked"]?.boolValue == true) }
        return base.marker(for: child, in: parent, index: index)
    }

    func chrome(for node: Node) -> ChromeBox? {
        node.type.name == "blockquote" ? quoteBox : nil
    }

    func controls(for node: Node) -> [ChromeControl] {
        node.type.name == "blockquote" ? quoteControls : []
    }

    func chrome(forTextblock node: Node, ancestors: [Node]) -> ChromeBox? {
        base.chrome(forTextblock: node, ancestors: ancestors)
    }

    func collapsed(_ node: Node, at pos: Int, ancestors: [Node]) -> [NSAttributedString.Key: Any]? {
        node.type.name == "blockquote" ? collapsedQuote?() : nil
    }

    func collapsedRuns(in textblock: Node, at pos: Int, ancestors: [Node]) -> [CollapsedRun] {
        guard chips else { return [] }
        var runs: [CollapsedRun] = []
        textblock.forEach { child, offset, _ in
            guard let text = child.text, let link = child.marks.first(where: { $0.type.name == "link" }),
                  link.attrs["href"]?.stringValue == text else { return }
            let length = text.utf16.count
            runs.append(CollapsedRun(range: offset..<(offset + length), opensAtEdges: false) {
                let attachment = NSTextAttachment()
                attachment.image = UIImage(systemName: "link")
                attachment.bounds = CGRect(x: 0, y: 0, width: 80, height: 18)
                return [.attachment: attachment]
            })
        }
        return runs
    }
}

/// A text view in a window, first responder, undo and redo wired to the history plugin, the
/// caret at the end (unless `caretAtEnd` is false). Keep the returned host alive for the test.
@MainActor
func inputHost(_ doc: Node, style: DocStyle? = nil, plugins: [Plugin]? = nil, caretAtEnd: Bool = true,
               width: CGFloat = 402) -> HostedTextView {
    let host = HostedTextView(doc, style: style, plugins: plugins ?? exampleSetup(schema: doc.type.schema), width: width)
    let v = host.view
    v.undoCommand = undo
    v.redoCommand = redo
    v.separateUndoStep = closeHistory
    _ = v.becomeFirstResponder()
    if caretAtEnd { v.dispatch(v.state.tr.setSelection(TextSelection.atEnd(v.state.doc))) }
    return host
}

extension ProseTextView {
    /// Types `text` one character at a time, as the keyboard does.
    func typeKeys(_ text: String) {
        for ch in text { insertText(String(ch)) }
    }

    /// Text of each top-level block.
    var blockTexts: [String] { (0..<state.doc.childCount).map { state.doc.child($0).textContent } }

    /// Type names of each top-level block.
    var blockTypes: [String] { (0..<state.doc.childCount).map { state.doc.child($0).type.name } }
}
#endif
